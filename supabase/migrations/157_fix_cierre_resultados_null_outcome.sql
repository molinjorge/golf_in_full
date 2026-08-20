-- ============================================================================
-- 157_fix_cierre_resultados_null_outcome.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 157 — FIX DE CIERRE DE RESULTADOS CON outcome NULL
--
-- PROBLEMA DETECTADO EN PRUEBA REAL DE LA MIGRACIÓN 156
--
-- La expresión:
--
--   official_ready OR outcome_code IN ('WD','DNF','DQ','DNS','NO_CARD')
--
-- devuelve NULL cuando outcome_code es NULL y official_ready=false.
--
-- Posteriormente:
--
--   count(*) FILTER (WHERE NOT resolved_for_round)
--
-- NO cuenta esos NULL, por lo que podía reportar:
--   unresolvedCards = 0
--   readyToCloseResults = true
--
-- aunque existieran tarjetas pendientes.
--
-- CORRECCIÓN
-- La ausencia de outcome excepcional debe equivaler siempre a FALSE:
--
--   COALESCE(outcome_code IN (...), false)
--
-- Esta migración reemplaza únicamente validar_cierre_resultados_ronda(uuid).
-- NO modifica tablas ni datos.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.validar_cierre_resultados_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_massive jsonb;
    v_tournament_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds
     WHERE id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para validar esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    v_massive := public.obtener_resultados_oficiales_ronda(
        p_tournament_round_id
    );

    RETURN (
        WITH cards AS (
            SELECT
                (c->>'scoreCardId')::uuid AS score_card_id,
                c->>'playerName' AS player_name,
                c->>'cardFolio' AS card_folio,
                COALESCE((c->>'ready')::boolean,false) AS official_ready,
                c->>'resultStatus' AS pipeline_status
            FROM jsonb_array_elements(v_massive->'cards') c
        ),
        resolved AS (
            SELECT
                c.*,
                o.outcome_code,
                o.reason AS outcome_reason,

                COALESCE(
                    c.official_ready
                    OR COALESCE(
                        o.outcome_code IN ('WD','DNF','DQ','DNS','NO_CARD'),
                        false
                    ),
                    false
                ) AS resolved_for_round

            FROM cards c
            LEFT JOIN public.tournament_scorecard_round_outcomes o
              ON o.score_card_id = c.score_card_id
        ),
        counts AS (
            SELECT
                count(*) AS total_cards,

                count(*) FILTER (
                    WHERE official_ready
                ) AS official_cards,

                count(*) FILTER (
                    WHERE outcome_code='WD'
                ) AS wd,

                count(*) FILTER (
                    WHERE outcome_code='DNF'
                ) AS dnf,

                count(*) FILTER (
                    WHERE outcome_code='DQ'
                ) AS dq,

                count(*) FILTER (
                    WHERE outcome_code='DNS'
                ) AS dns,

                count(*) FILTER (
                    WHERE outcome_code='NO_CARD'
                ) AS no_card,

                count(*) FILTER (
                    WHERE resolved_for_round IS TRUE
                ) AS resolved_cards,

                count(*) FILTER (
                    WHERE resolved_for_round IS NOT TRUE
                ) AS unresolved_cards

            FROM resolved
        )
        SELECT jsonb_build_object(
            'tournamentId', v_tournament_id,
            'tournamentRoundId', p_tournament_round_id,

            'readyToCloseResults',
                (
                    SELECT
                        total_cards > 0
                        AND unresolved_cards = 0
                    FROM counts
                ),

            'summary', (
                SELECT jsonb_build_object(
                    'totalCards', total_cards,
                    'officialCards', official_cards,
                    'WD', wd,
                    'DNF', dnf,
                    'DQ', dq,
                    'DNS', dns,
                    'NO_CARD', no_card,
                    'resolvedCards', resolved_cards,
                    'unresolvedCards', unresolved_cards
                )
                FROM counts
            ),

            'unresolved', COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'scoreCardId', score_card_id,
                        'cardFolio', card_folio,
                        'playerName', player_name,
                        'pipelineStatus', pipeline_status
                    )
                    ORDER BY card_folio
                )
                FROM resolved
                WHERE resolved_for_round IS NOT TRUE
            ), '[]'::jsonb)
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.validar_cierre_resultados_ronda(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.validar_cierre_resultados_ronda(uuid)
TO authenticated;

COMMIT;
