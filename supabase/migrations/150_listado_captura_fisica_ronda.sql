-- ============================================================================
-- 150_listado_captura_fisica_ronda.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 150 — LISTADO OPERATIVO DE CAPTURA FÍSICA POR RONDA
--
-- OBJETIVO
-- Eliminar el patrón N+1 del listado administrativo de CAPTURA TARJETAS FÍSICAS.
--
-- Antes:
--   1 consulta/listado de tarjetas
--   + lecturas auxiliares
--   + 1 llamada a obtener_captura_fisica_tarjeta() POR CADA TARJETA
--
-- Después:
--   1 RPC por ronda:
--     obtener_tarjetas_captura_fisica_ronda(p_tournament_round_id)
--
-- La RPC devuelve únicamente metadatos necesarios para el LISTADO:
-- - identidad/folio de tarjeta
-- - jugador/unidad
-- - categoría
-- - marcador vigente
-- - estado físico
-- - firmas
-- - fecha de recepción
-- - hoyos esperados
-- - hoyos físicos capturados
--
-- NO devuelve scores DIGITAL ni FÍSICO por hoyo.
-- NO modifica captura digital ni física.
-- NO implementa conciliación.
-- NO usa QR.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 0. GUARDAS
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('public.tournament_score_cards') IS NULL
       OR to_regclass('public.tournament_round_start_validation_units') IS NULL
       OR to_regclass('public.tournament_round_start_validation_groups') IS NULL
       OR to_regclass('public.tournament_scorecard_marker_assignments') IS NULL
       OR to_regclass('public.tournament_scorecard_capture_sessions') IS NULL
       OR to_regclass('public.tournament_scorecard_physical_receptions') IS NULL
       OR to_regclass('public.tournament_scorecard_physical_hole_scores') IS NULL
    THEN
        RAISE EXCEPTION
            'Migración 150 requiere emisión de tarjetas, núcleo digital y Migración 149.';
    END IF;

    IF to_regprocedure('public.puede_administrar_congelamiento_torneo(uuid)') IS NULL THEN
        RAISE EXCEPTION
            'Migración 150 requiere public.puede_administrar_congelamiento_torneo(uuid).';
    END IF;
END;
$$;

-- ============================================================================
-- 1. RPC — LISTADO OPERATIVO COMPLETO POR RONDA
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_tarjetas_captura_fisica_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tournament_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id es obligatorio.'
            USING ERRCODE = '22023';
    END IF;

    -- La tarjeta oficial es la fuente canónica para relacionar ronda↔torneo.
    SELECT sc.tournament_id
      INTO v_tournament_id
      FROM public.tournament_score_cards sc
     WHERE sc.tournament_round_id = p_tournament_round_id
       AND sc.status = 'issued'
     ORDER BY sc.card_number NULLS LAST, sc.id
     LIMIT 1;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda no tiene tarjetas oficiales emitidas.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar la captura física de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    RETURN jsonb_build_object(
        'tournamentRoundId', p_tournament_round_id,
        'tournamentId', v_tournament_id,
        'cards',
        COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'scoreCardId', q.score_card_id,
                    'cardNumber', q.card_number,
                    'cardFolio', q.card_folio,

                    'player', jsonb_build_object(
                        'playerId', q.player_id,
                        'displayName', q.unit_name
                    ),

                    'category', jsonb_build_object(
                        'tournamentCategoryId', q.tournament_category_id,
                        'name', q.category_name
                    ),

                    'marker', CASE
                        WHEN q.marker_player_id IS NULL THEN NULL
                        ELSE jsonb_build_object(
                            'playerId', q.marker_player_id,
                            'displayName', q.marker_name
                        )
                    END,

                    -- NOT_RECEIVED es DERIVADO: no existe fila física todavía.
                    'physical', jsonb_build_object(
                        'received', (q.physical_reception_id IS NOT NULL),
                        'physicalReceptionId', q.physical_reception_id,
                        'status', COALESCE(q.physical_status, 'NOT_RECEIVED'),
                        'playerSignaturePresent',
                            COALESCE(q.player_signature_present, false),
                        'markerSignaturePresent',
                            COALESCE(q.marker_signature_present, false),
                        'receivedAt', q.received_at,
                        'captureStartedAt', q.capture_started_at,
                        'captureCompletedAt', q.capture_completed_at,
                        'holesExpected', q.holes_expected,
                        'physicalHolesCaptured', q.physical_holes_captured
                    )
                )
                ORDER BY q.card_number NULLS LAST, q.score_card_id
            )
            FROM (
                SELECT
                    sc.id AS score_card_id,
                    sc.card_number,
                    sc.card_folio,

                    u.player_id,
                    u.unit_name,
                    u.tournament_category_id,
                    g.category_name,

                    ma.marker_player_id,
                    mu.unit_name AS marker_name,

                    pr.id AS physical_reception_id,
                    pr.status AS physical_status,
                    pr.player_signature_present,
                    pr.marker_signature_present,
                    pr.received_at,
                    pr.capture_started_at,
                    pr.capture_completed_at,

                    cs.holes_expected,

                    COALESCE(ph.physical_holes_captured, 0) AS physical_holes_captured

                FROM public.tournament_score_cards sc

                JOIN public.tournament_round_start_validation_units u
                  ON u.id = sc.validation_unit_id
                 AND u.validation_id = sc.validation_id

                JOIN public.tournament_round_start_validation_groups g
                  ON g.id = sc.validation_group_id
                 AND g.validation_id = sc.validation_id

                LEFT JOIN public.tournament_scorecard_capture_sessions cs
                  ON cs.score_card_id = sc.id

                LEFT JOIN public.tournament_scorecard_physical_receptions pr
                  ON pr.score_card_id = sc.id

                LEFT JOIN LATERAL (
                    SELECT count(*)::integer AS physical_holes_captured
                    FROM public.tournament_scorecard_physical_hole_scores phs
                    WHERE phs.score_card_id = sc.id
                ) ph ON true

                LEFT JOIN public.tournament_scorecard_marker_assignments ma
                  ON ma.score_card_id = sc.id
                 AND ma.status = 'active'

                LEFT JOIN public.tournament_score_cards msc
                  ON msc.id = ma.marker_score_card_id
                 AND msc.status = 'issued'

                LEFT JOIN public.tournament_round_start_validation_units mu
                  ON mu.id = msc.validation_unit_id
                 AND mu.validation_id = msc.validation_id

                WHERE sc.tournament_round_id = p_tournament_round_id
                  AND sc.status = 'issued'
            ) q
        ), '[]'::jsonb)
    );
END;
$$;

-- ============================================================================
-- 2. PRIVILEGIOS
-- ============================================================================

REVOKE ALL ON FUNCTION public.obtener_tarjetas_captura_fisica_ronda(uuid)
    FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.obtener_tarjetas_captura_fisica_ronda(uuid)
    TO authenticated;

COMMIT;
