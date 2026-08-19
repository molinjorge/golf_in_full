-- ============================================================================
-- 151_lectura_conciliacion_scorecard.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 151 — LECTURA CONSOLIDADA PARA CONCILIACIÓN
--
-- OBJETIVO
-- Exponer, en una sola RPC administrativa y SOLO DESPUÉS de que la captura
-- física esté finalizada (CAPTURED), las tres evidencias relevantes por hoyo:
--
--   A) DIGITAL actual del marcador
--   B) INCONFORMIDAD del jugador (activa e histórica)
--   C) FÍSICO transcrito desde la tarjeta en papel
--
-- Esta migración NO resuelve diferencias.
-- NO crea official_gross_score.
-- NO modifica captura digital.
-- NO modifica captura física.
-- NO crea tabla de resoluciones.
--
-- PRINCIPIO
-- La captura física permanece ciega hasta CAPTURED.
-- Esta RPC rechaza la lectura comparativa si la tarjeta física todavía está
-- RECEIVED o IN_CAPTURE.
--
-- CLASIFICACIÓN EN DOS EJES
--
-- comparisonStatus:
--   COINCIDE
--   DIFERENCIA
--   SIN_CAPTURA_DIGITAL
--   PENDIENTE_CAPTURA_FISICA   (defensivo; no debería existir tras CAPTURED)
--
-- disputeStatus:
--   NONE
--   ACTIVE
--   HISTORICAL_PENDING
--   HISTORICAL_RESOLVED
--
-- needsReview = true cuando:
--   - DIGITAL != FÍSICO
--   - existe inconformidad ACTIVE
--   - existe inconformidad histórica no reconfirmada (HISTORICAL_PENDING)
--   - falta captura física (defensivo)
--
-- SIN_CAPTURA_DIGITAL NO se considera por sí mismo una inconsistencia.
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
       OR to_regclass('public.tournament_round_hole_snapshots') IS NULL
    THEN
        RAISE EXCEPTION
            'Migración 151 requiere núcleo digital, eventos y Migración 149.';
    END IF;

    IF to_regprocedure('public.puede_administrar_congelamiento_torneo(uuid)') IS NULL THEN
        RAISE EXCEPTION
            'Migración 151 requiere public.puede_administrar_congelamiento_torneo(uuid).';
    END IF;
END;
$$;

-- ============================================================================
-- 1. RPC — LECTURA CONSOLIDADA DE CONCILIACIÓN DE UNA TARJETA
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_conciliacion_tarjeta_score(
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
            'No tienes permiso administrativo para consultar la conciliación de esta tarjeta.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        pr.id,
        pr.status,
        pr.player_signature_present,
        pr.marker_signature_present,
        pr.received_at,
        pr.capture_completed_at
      INTO v_reception
      FROM public.tournament_scorecard_physical_receptions pr
     WHERE pr.score_card_id = v_card.id
     LIMIT 1;

    IF v_reception.id IS NULL THEN
        RAISE EXCEPTION
            'La tarjeta física todavía no ha sido recibida.'
            USING ERRCODE = '55000';
    END IF;

    IF v_reception.status <> 'CAPTURED' THEN
        RAISE EXCEPTION
            'La comparación DIGITAL vs FÍSICO sólo está disponible después de finalizar la captura física.'
            USING ERRCODE = '55000',
                  DETAIL = format('physical_status=%s', v_reception.status),
                  HINT = 'Finaliza primero la captura física ciega.';
    END IF;

    RETURN (
        WITH hole_evidence AS (
            SELECT
                hs.id AS hole_score_id,
                hs.round_hole_snapshot_id,
                hs.hole_number,
                hs.play_sequence,
                rh.par,
                rh.stroke_index,

                hs.gross_score AS digital_gross_score,
                hs.status AS digital_status,

                hs.player_claimed_gross_score AS active_claimed_gross_score,
                hs.dispute_note AS active_dispute_note,
                hs.disputed_at AS active_disputed_at,

                phs.physical_gross_score,
                phs.updated_at AS physical_updated_at,

                ld.claimed_gross_score AS last_dispute_claimed_gross_score,
                ld.reason AS last_dispute_reason,
                ld.created_at AS last_disputed_at,

                lc.created_at AS last_confirmed_at,

                CASE
                    WHEN ld.created_at IS NULL THEN 'NONE'
                    WHEN hs.status = 'disputed' THEN 'ACTIVE'
                    WHEN lc.created_at IS NULL
                         OR lc.created_at < ld.created_at
                    THEN 'HISTORICAL_PENDING'
                    ELSE 'HISTORICAL_RESOLVED'
                END AS dispute_status,

                CASE
                    WHEN phs.physical_gross_score IS NULL
                    THEN 'PENDIENTE_CAPTURA_FISICA'
                    WHEN hs.gross_score IS NULL
                    THEN 'SIN_CAPTURA_DIGITAL'
                    WHEN hs.gross_score = phs.physical_gross_score
                    THEN 'COINCIDE'
                    ELSE 'DIFERENCIA'
                END AS comparison_status

            FROM public.tournament_scorecard_hole_scores hs

            JOIN public.tournament_round_hole_snapshots rh
              ON rh.id = hs.round_hole_snapshot_id

            LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
              ON phs.score_card_id = hs.score_card_id
             AND phs.round_hole_snapshot_id = hs.round_hole_snapshot_id

            LEFT JOIN LATERAL (
                SELECT
                    e.claimed_gross_score,
                    e.reason,
                    e.created_at
                FROM public.tournament_scorecard_events e
                WHERE e.hole_score_id = hs.id
                  AND e.event_type = 'player_disputed'
                ORDER BY e.created_at DESC, e.id DESC
                LIMIT 1
            ) ld ON true

            LEFT JOIN LATERAL (
                SELECT
                    e.created_at
                FROM public.tournament_scorecard_events e
                WHERE e.hole_score_id = hs.id
                  AND e.event_type = 'player_confirmed'
                ORDER BY e.created_at DESC, e.id DESC
                LIMIT 1
            ) lc ON true

            WHERE hs.score_card_id = v_card.id
        ),
        enriched AS (
            SELECT
                he.*,
                (
                    he.comparison_status = 'DIFERENCIA'
                    OR he.dispute_status IN ('ACTIVE', 'HISTORICAL_PENDING')
                    OR he.comparison_status = 'PENDIENTE_CAPTURA_FISICA'
                ) AS needs_review
            FROM hole_evidence he
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

            'physicalCapture',
            jsonb_build_object(
                'physicalReceptionId', v_reception.id,
                'status', v_reception.status,
                'playerSignaturePresent', v_reception.player_signature_present,
                'markerSignaturePresent', v_reception.marker_signature_present,
                'receivedAt', v_reception.received_at,
                'captureCompletedAt', v_reception.capture_completed_at
            ),

            'summary',
            jsonb_build_object(
                'holesTotal', count(*),
                'coinciden',
                    count(*) FILTER (
                        WHERE comparison_status = 'COINCIDE'
                    ),
                'diferencias',
                    count(*) FILTER (
                        WHERE comparison_status = 'DIFERENCIA'
                    ),
                'sinCapturaDigital',
                    count(*) FILTER (
                        WHERE comparison_status = 'SIN_CAPTURA_DIGITAL'
                    ),
                'pendientesFisicos',
                    count(*) FILTER (
                        WHERE comparison_status = 'PENDIENTE_CAPTURA_FISICA'
                    ),
                'inconformidadesActivas',
                    count(*) FILTER (
                        WHERE dispute_status = 'ACTIVE'
                    ),
                'inconformidadesHistoricasPendientes',
                    count(*) FILTER (
                        WHERE dispute_status = 'HISTORICAL_PENDING'
                    ),
                'inconformidadesHistoricasResueltas',
                    count(*) FILTER (
                        WHERE dispute_status = 'HISTORICAL_RESOLVED'
                    ),
                'requierenRevision',
                    count(*) FILTER (
                        WHERE needs_review
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

                        'activeClaimedGrossScore', active_claimed_gross_score,
                        'activeDisputeNote', active_dispute_note,
                        'activeDisputedAt', active_disputed_at,

                        'lastDisputeClaimedGrossScore',
                            last_dispute_claimed_gross_score,
                        'lastDisputeReason', last_dispute_reason,
                        'lastDisputedAt', last_disputed_at,
                        'lastConfirmedAt', last_confirmed_at,

                        'physicalGrossScore', physical_gross_score,
                        'physicalUpdatedAt', physical_updated_at,

                        'comparisonStatus', comparison_status,
                        'disputeStatus', dispute_status,
                        'hadDisputeHistory', (last_disputed_at IS NOT NULL),
                        'needsReview', needs_review
                    )
                    ORDER BY play_sequence
                ),
                '[]'::jsonb
            )
        )
        FROM enriched
    );
END;
$$;

-- ============================================================================
-- 2. PRIVILEGIOS
-- ============================================================================

REVOKE ALL ON FUNCTION public.obtener_conciliacion_tarjeta_score(uuid)
    FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.obtener_conciliacion_tarjeta_score(uuid)
    TO authenticated;

COMMIT;
