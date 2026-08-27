-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 192 Fase 1A
-- Corrección de alias de scoring engine Stroke en cierre de resultados
--
-- OBJETIVO
--   Corregir una inconsistencia de nomenclatura ya existente:
--   algunos snapshots reales almacenan scoring_engine = 'stroke', mientras
--   validar_cierre_resultados_ronda(uuid) sólo aceptaba 'stroke_play'.
--
-- EFECTO
--   - Stroke individual acepta 'stroke' y 'stroke_play' como equivalentes.
--   - Stableford individual permanece sin cambios.
--   - No modifica resultados, rankings, desempates, freeze ni snapshots.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.validar_cierre_resultados_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_massive jsonb;
    v_tournament_id uuid;
    v_scoring_engine text;
    v_participation_type text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    SELECT
        tr.tournament_id,
        rcs.scoring_engine,
        rcs.participation_type
      INTO
        v_tournament_id,
        v_scoring_engine,
        v_participation_type
      FROM public.tournament_rounds tr
      LEFT JOIN LATERAL (
          SELECT s.scoring_engine,s.participation_type
          FROM public.tournament_round_condition_snapshots s
          WHERE s.tournament_round_id=tr.id
          ORDER BY s.created_at DESC,s.id DESC
          LIMIT 1
      ) rcs ON true
     WHERE tr.id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF v_scoring_engine IS NULL THEN
        RAISE EXCEPTION
            'La ronda no tiene snapshot congelado de scoring.'
            USING ERRCODE='55000';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para validar esta ronda.'
            USING ERRCODE='42501';
    END IF;

    -- Compatibilidad explícita para alias reales de Stroke Play.
    IF v_scoring_engine IN ('stroke','stroke_play')
       AND v_participation_type='individual'
    THEN
        v_massive :=
            public.obtener_resultados_oficiales_ronda(
                p_tournament_round_id
            );

    ELSIF v_scoring_engine='stableford'
          AND v_participation_type='individual'
    THEN
        v_massive :=
            public.obtener_resultados_stableford_oficiales_ronda(
                p_tournament_round_id
            );

    ELSE
        RAISE EXCEPTION
            'El cierre competitivo todavía no soporta scoring_engine=% / participation_type=%.',
            v_scoring_engine,
            COALESCE(v_participation_type,'NULL')
            USING ERRCODE='0A000';
    END IF;

    RETURN (
        WITH cards AS (
            SELECT
                (c->>'scoreCardId')::uuid
                    AS score_card_id,

                c->>'playerName'
                    AS player_name,

                c->>'cardFolio'
                    AS card_folio,

                COALESCE(
                    (c->>'ready')::boolean,
                    false
                )
                    AS official_ready,

                CASE
                    WHEN v_scoring_engine='stableford'
                        THEN c->>'competitionStatus'
                    ELSE c->>'resultStatus'
                END
                    AS pipeline_status

            FROM jsonb_array_elements(
                COALESCE(v_massive->'cards','[]'::jsonb)
            ) c
        ),

        resolved AS (
            SELECT
                c.*,

                o.outcome_code,
                o.reason
                    AS outcome_reason,

                COALESCE(
                    c.official_ready
                    OR COALESCE(
                        o.outcome_code IN (
                            'WD',
                            'DNF',
                            'DQ',
                            'DNS',
                            'NO_CARD'
                        ),
                        false
                    ),
                    false
                )
                    AS resolved_for_round

            FROM cards c

            LEFT JOIN public.tournament_scorecard_round_outcomes o
              ON o.score_card_id=c.score_card_id
        ),

        counts AS (
            SELECT
                count(*)
                    AS total_cards,

                count(*) FILTER (
                    WHERE official_ready
                )
                    AS official_cards,

                count(*) FILTER (
                    WHERE outcome_code='WD'
                )
                    AS wd,

                count(*) FILTER (
                    WHERE outcome_code='DNF'
                )
                    AS dnf,

                count(*) FILTER (
                    WHERE outcome_code='DQ'
                )
                    AS dq,

                count(*) FILTER (
                    WHERE outcome_code='DNS'
                )
                    AS dns,

                count(*) FILTER (
                    WHERE outcome_code='NO_CARD'
                )
                    AS no_card,

                count(*) FILTER (
                    WHERE resolved_for_round IS TRUE
                )
                    AS resolved_cards,

                count(*) FILTER (
                    WHERE resolved_for_round IS NOT TRUE
                )
                    AS unresolved_cards

            FROM resolved
        )

        SELECT jsonb_build_object(
            'tournamentId',
                v_tournament_id,

            'tournamentRoundId',
                p_tournament_round_id,

            'scoringEngine',
                v_scoring_engine,

            'participationType',
                v_participation_type,

            'readyToCloseResults',
                (
                    SELECT
                        total_cards>0
                        AND unresolved_cards=0
                    FROM counts
                ),

            'summary',(
                SELECT jsonb_build_object(
                    'totalCards',
                        total_cards,
                    'officialCards',
                        official_cards,
                    'WD',
                        wd,
                    'DNF',
                        dnf,
                    'DQ',
                        dq,
                    'DNS',
                        dns,
                    'NO_CARD',
                        no_card,
                    'resolvedCards',
                        resolved_cards,
                    'unresolvedCards',
                        unresolved_cards
                )
                FROM counts
            ),

            'unresolved',
                COALESCE((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'scoreCardId',
                                score_card_id,
                            'cardFolio',
                                card_folio,
                            'playerName',
                                player_name,
                            'pipelineStatus',
                                pipeline_status
                        )
                        ORDER BY card_folio
                    )
                    FROM resolved
                    WHERE resolved_for_round IS NOT TRUE
                ),'[]'::jsonb)
        )
    );
END;
$function$;

COMMENT ON FUNCTION public.validar_cierre_resultados_ronda(uuid)
IS
'Valida cierre competitivo de resultados por ronda. Soporta Stroke Play '
'individual con scoring_engine stroke o stroke_play, y Stableford individual.';

