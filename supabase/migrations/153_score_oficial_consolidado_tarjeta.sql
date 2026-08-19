-- ============================================================================
-- 153_score_oficial_consolidado_tarjeta.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 153 — LECTURA CONSOLIDADA DEL SCORE OFICIAL
--
-- OBJETIVO
-- Construir una ÚNICA lectura oficial por tarjeta, sin sobrescribir ninguna
-- evidencia original y sin materializar todavía resultados/NETO/leaderboard.
--
-- REGLA FUNCIONAL APROBADA
--
-- 1) Si un hoyo requirió revisión y fue conciliado:
--      officialGrossScore = resolved_gross_score
--      officialSource     = fuente de la resolución
--
-- 2) Si un hoyo NO requirió resolución:
--      - DIGITAL = FÍSICO  -> valor FÍSICO, fuente MATCHED
--      - DIGITAL NULL      -> valor FÍSICO, fuente PHYSICAL_ONLY
--
-- IMPORTANTE:
-- Para los hoyos no conflictivos usamos el valor FÍSICO como soporte
-- inmutable del número oficial. Si DIGITAL y FÍSICO coinciden, el número es
-- idéntico; usar FÍSICO evita que una modificación digital posterior altere
-- retroactivamente el score oficial.
--
-- La RPC sólo funciona cuando:
-- - la captura física está CAPTURED;
-- - la conciliación existe y está COMPLETED;
-- - todos los hoyos tienen valor físico;
-- - cualquier hoyo que requiere revisión tiene resolución registrada.
--
-- Esta migración NO:
-- - modifica gross_score digital;
-- - modifica physical_gross_score;
-- - modifica resoluciones;
-- - crea columna official_gross_score;
-- - calcula NETO;
-- - publica leaderboard;
-- - aplica cortes/desempates.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 0. GUARDAS
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('public.tournament_score_cards') IS NULL
       OR to_regclass('public.tournament_scorecard_hole_scores') IS NULL
       OR to_regclass('public.tournament_scorecard_events') IS NULL
       OR to_regclass('public.tournament_scorecard_physical_receptions') IS NULL
       OR to_regclass('public.tournament_scorecard_physical_hole_scores') IS NULL
       OR to_regclass('public.tournament_scorecard_reconciliations') IS NULL
       OR to_regclass('public.tournament_scorecard_hole_resolutions') IS NULL
       OR to_regclass('public.tournament_round_hole_snapshots') IS NULL
    THEN
        RAISE EXCEPTION
            'Migración 153 requiere captura digital, física y conciliación 149-152.';
    END IF;

    IF to_regprocedure('public.puede_administrar_congelamiento_torneo(uuid)') IS NULL THEN
        RAISE EXCEPTION
            'Migración 153 requiere public.puede_administrar_congelamiento_torneo(uuid).';
    END IF;
END;
$$;

-- ============================================================================
-- 1. RPC — SCORE OFICIAL CONSOLIDADO DE UNA TARJETA
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_score_oficial_tarjeta(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_card record;
    v_reception record;
    v_reconciliation record;
    v_expected integer;
    v_physical_count integer;
    v_unresolved integer;
    v_missing_official integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF p_score_card_id IS NULL THEN
        RAISE EXCEPTION 'score_card_id es obligatorio.'
            USING ERRCODE = '22023';
    END IF;

    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.card_number,
        sc.card_folio,
        sc.status,
        u.unit_name AS player_name,
        g.category_name
      INTO v_card
      FROM public.tournament_score_cards sc
      JOIN public.tournament_round_start_validation_units u
        ON u.id = sc.validation_unit_id
       AND u.validation_id = sc.validation_id
      JOIN public.tournament_round_start_validation_groups g
        ON g.id = sc.validation_group_id
       AND g.validation_id = sc.validation_id
     WHERE sc.id = p_score_card_id
       AND sc.status = 'issued'
     LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION
            'La tarjeta oficial indicada no existe o no está emitida.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_card.tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar el score oficial de esta tarjeta.'
            USING ERRCODE = '42501';
    END IF;

    SELECT pr.*
      INTO v_reception
      FROM public.tournament_scorecard_physical_receptions pr
     WHERE pr.score_card_id = v_card.id
     LIMIT 1;

    IF v_reception.id IS NULL OR v_reception.status <> 'CAPTURED' THEN
        RAISE EXCEPTION
            'El score oficial requiere captura física finalizada.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'physical_status=%s',
                      COALESCE(v_reception.status, 'NOT_RECEIVED')
                  );
    END IF;

    SELECT r.*
      INTO v_reconciliation
      FROM public.tournament_scorecard_reconciliations r
     WHERE r.score_card_id = v_card.id
     LIMIT 1;

    IF v_reconciliation.id IS NULL
       OR v_reconciliation.status <> 'COMPLETED'
    THEN
        RAISE EXCEPTION
            'El score oficial requiere conciliación COMPLETADA.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'reconciliation_status=%s',
                      COALESCE(v_reconciliation.status, 'NOT_STARTED')
                  );
    END IF;

    SELECT cs.holes_expected
      INTO v_expected
      FROM public.tournament_scorecard_capture_sessions cs
     WHERE cs.score_card_id = v_card.id
     LIMIT 1;

    IF v_expected IS NULL THEN
        SELECT count(*)
          INTO v_expected
          FROM public.tournament_scorecard_hole_scores hs
         WHERE hs.score_card_id = v_card.id;
    END IF;

    SELECT count(*)
      INTO v_physical_count
      FROM public.tournament_scorecard_physical_hole_scores phs
     WHERE phs.score_card_id = v_card.id;

    IF v_physical_count <> v_expected THEN
        RAISE EXCEPTION
            'El score oficial no puede construirse: captura física incompleta.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'physical_holes=%s; expected=%s',
                      v_physical_count,
                      v_expected
                  );
    END IF;

    -- Recalcula needsReview server-side con la misma regla de 151/152.
    WITH evidence AS (
        SELECT
            hs.id AS hole_score_id,
            hs.round_hole_snapshot_id,
            hs.gross_score AS digital_gross_score,
            hs.status AS digital_status,
            phs.physical_gross_score,
            ld.created_at AS last_disputed_at,
            lc.created_at AS last_confirmed_at,

            CASE
                WHEN phs.physical_gross_score IS NULL
                    THEN 'PENDIENTE_CAPTURA_FISICA'
                WHEN hs.gross_score IS NULL
                    THEN 'SIN_CAPTURA_DIGITAL'
                WHEN hs.gross_score = phs.physical_gross_score
                    THEN 'COINCIDE'
                ELSE 'DIFERENCIA'
            END AS comparison_status,

            CASE
                WHEN ld.created_at IS NULL
                    THEN 'NONE'
                WHEN hs.status = 'disputed'
                    THEN 'ACTIVE'
                WHEN lc.created_at IS NULL
                     OR lc.created_at < ld.created_at
                    THEN 'HISTORICAL_PENDING'
                ELSE 'HISTORICAL_RESOLVED'
            END AS dispute_status

        FROM public.tournament_scorecard_hole_scores hs

        LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
          ON phs.score_card_id = hs.score_card_id
         AND phs.round_hole_snapshot_id = hs.round_hole_snapshot_id

        LEFT JOIN LATERAL (
            SELECT e.created_at
            FROM public.tournament_scorecard_events e
            WHERE e.hole_score_id = hs.id
              AND e.event_type = 'player_disputed'
            ORDER BY e.created_at DESC, e.id DESC
            LIMIT 1
        ) ld ON true

        LEFT JOIN LATERAL (
            SELECT e.created_at
            FROM public.tournament_scorecard_events e
            WHERE e.hole_score_id = hs.id
              AND e.event_type = 'player_confirmed'
            ORDER BY e.created_at DESC, e.id DESC
            LIMIT 1
        ) lc ON true

        WHERE hs.score_card_id = v_card.id
    ),
    review_holes AS (
        SELECT e.round_hole_snapshot_id
        FROM evidence e
        WHERE
            e.comparison_status = 'DIFERENCIA'
            OR e.dispute_status IN ('ACTIVE', 'HISTORICAL_PENDING')
            OR e.comparison_status = 'PENDIENTE_CAPTURA_FISICA'
    )
    SELECT count(*) FILTER (WHERE r.id IS NULL)
      INTO v_unresolved
      FROM review_holes rh
      LEFT JOIN public.tournament_scorecard_hole_resolutions r
        ON r.score_card_id = v_card.id
       AND r.round_hole_snapshot_id = rh.round_hole_snapshot_id;

    IF v_unresolved > 0 THEN
        RAISE EXCEPTION
            'El score oficial no puede construirse: quedan hoyos por resolver.'
            USING ERRCODE = '55000',
                  DETAIL = format('unresolved_review_holes=%s', v_unresolved);
    END IF;

    -- Defensa adicional: todo hoyo debe producir exactamente un valor oficial.
    WITH official_rows AS (
        SELECT
            hs.round_hole_snapshot_id,
            CASE
                WHEN r.id IS NOT NULL
                    THEN r.resolved_gross_score
                ELSE phs.physical_gross_score
            END AS official_gross_score
        FROM public.tournament_scorecard_hole_scores hs
        LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
          ON phs.score_card_id = hs.score_card_id
         AND phs.round_hole_snapshot_id = hs.round_hole_snapshot_id
        LEFT JOIN public.tournament_scorecard_hole_resolutions r
          ON r.score_card_id = hs.score_card_id
         AND r.round_hole_snapshot_id = hs.round_hole_snapshot_id
        WHERE hs.score_card_id = v_card.id
    )
    SELECT count(*) FILTER (WHERE official_gross_score IS NULL)
      INTO v_missing_official
      FROM official_rows;

    IF v_missing_official > 0 THEN
        RAISE EXCEPTION
            'El score oficial no puede construirse: existen hoyos sin valor oficial.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'missing_official_holes=%s',
                      v_missing_official
                  );
    END IF;

    RETURN (
        WITH holes AS (
            SELECT
                hs.id AS hole_score_id,
                hs.round_hole_snapshot_id,
                hs.hole_number,
                hs.play_sequence,
                rh.par,
                rh.stroke_index,

                hs.gross_score AS digital_gross_score,
                hs.status AS digital_status,

                phs.physical_gross_score,

                r.id AS resolution_id,
                r.resolution_source,
                r.resolved_gross_score,
                r.reason AS resolution_reason,

                CASE
                    WHEN r.id IS NOT NULL
                        THEN r.resolved_gross_score
                    ELSE phs.physical_gross_score
                END AS official_gross_score,

                CASE
                    WHEN r.id IS NOT NULL
                        THEN r.resolution_source
                    WHEN hs.gross_score IS NULL
                        THEN 'PHYSICAL_ONLY'
                    WHEN hs.gross_score = phs.physical_gross_score
                        THEN 'MATCHED'
                    ELSE 'INVALID_UNRESOLVED'
                END AS official_source

            FROM public.tournament_scorecard_hole_scores hs

            JOIN public.tournament_round_hole_snapshots rh
              ON rh.id = hs.round_hole_snapshot_id

            LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
              ON phs.score_card_id = hs.score_card_id
             AND phs.round_hole_snapshot_id = hs.round_hole_snapshot_id

            LEFT JOIN public.tournament_scorecard_hole_resolutions r
              ON r.score_card_id = hs.score_card_id
             AND r.round_hole_snapshot_id = hs.round_hole_snapshot_id

            WHERE hs.score_card_id = v_card.id
        )
        SELECT jsonb_build_object(
            'scoreCard',
            jsonb_build_object(
                'scoreCardId', v_card.id,
                'cardNumber', v_card.card_number,
                'cardFolio', v_card.card_folio,
                'playerName', v_card.player_name,
                'categoryName', v_card.category_name,
                'tournamentId', v_card.tournament_id,
                'tournamentRoundId', v_card.tournament_round_id
            ),

            'official',
            jsonb_build_object(
                'ready', true,
                'physicalStatus', v_reception.status,
                'reconciliationStatus', v_reconciliation.status,
                'reconciliationCompletedAt',
                    v_reconciliation.completed_at,
                'holesExpected', v_expected,
                'holesOfficial', count(*),
                'totalOfficialGross',
                    sum(official_gross_score),
                'sources', jsonb_build_object(
                    'matched',
                        count(*) FILTER (
                            WHERE official_source = 'MATCHED'
                        ),
                    'physicalOnly',
                        count(*) FILTER (
                            WHERE official_source = 'PHYSICAL_ONLY'
                        ),
                    'digitalResolution',
                        count(*) FILTER (
                            WHERE official_source = 'DIGITAL'
                        ),
                    'physicalResolution',
                        count(*) FILTER (
                            WHERE official_source = 'PHYSICAL'
                        ),
                    'playerClaimResolution',
                        count(*) FILTER (
                            WHERE official_source = 'PLAYER_CLAIM'
                        ),
                    'manualResolution',
                        count(*) FILTER (
                            WHERE official_source = 'MANUAL'
                        )
                )
            ),

            'holes',
            COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'holeScoreId', hole_score_id,
                        'roundHoleSnapshotId', round_hole_snapshot_id,
                        'holeNumber', hole_number,
                        'playSequence', play_sequence,
                        'par', par,
                        'strokeIndex', stroke_index,

                        'digitalGrossScore', digital_gross_score,
                        'digitalStatus', digital_status,
                        'physicalGrossScore', physical_gross_score,

                        'resolutionId', resolution_id,
                        'resolutionSource', resolution_source,
                        'resolvedGrossScore', resolved_gross_score,
                        'resolutionReason', resolution_reason,

                        'officialGrossScore', official_gross_score,
                        'officialSource', official_source
                    )
                    ORDER BY play_sequence
                ),
                '[]'::jsonb
            )
        )
        FROM holes
    );
END;
$$;

-- ============================================================================
-- 2. PRIVILEGIOS
-- ============================================================================

REVOKE ALL ON FUNCTION public.obtener_score_oficial_tarjeta(uuid)
    FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.obtener_score_oficial_tarjeta(uuid)
    TO authenticated;

COMMIT;
