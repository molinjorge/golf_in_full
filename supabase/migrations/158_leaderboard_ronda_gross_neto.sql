-- ============================================================================
-- 158_leaderboard_ronda_gross_neto.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 158 — LEADERBOARD DE RONDA GROSS + NETO
--
-- OBJETIVO
-- Construir una única fuente administrativa de leaderboard por ronda,
-- consumiendo:
--
-- - Migración 155: resultados oficiales masivos por ronda.
-- - Migración 156/157: outcomes terminales y cierre de resultados.
--
-- PRINCIPIOS
-- - Calcula SIEMPRE ambas clasificaciones: GROSS y NETO.
-- - NO decide todavía cuál categoría premia GROSS o NETO.
-- - NO aplica todavía reglas de desempate.
-- - NO aplica cortes.
-- - NO materializa posiciones.
-- - Una ronda abierta/incompleta produce leaderboard PROVISIONAL.
-- - Una ronda totalmente resuelta puede quedar:
--      READY_FOR_TIEBREAK      si existen empates;
--      READY_FOR_PUBLICATION   si no existen empates.
--
-- ELEGIBILIDAD PARA RANKING
-- - Sólo tarjetas OFFICIAL_READY entran a posiciones numéricas.
-- - WD / DNF / DQ / DNS / NO_CARD aparecen en la salida pero SIN posición.
-- - DNF conserva información parcial en su outcome, pero no se convierte
--   artificialmente en resultado individual oficial completo.
--
-- EMPATES
-- - Se usa RANK() únicamente para identificar posiciones provisionales.
-- - Si dos o más jugadores comparten total GROSS/NETO en la misma categoría,
--   se marca tiebreakPending=true.
-- - Esta migración NO rompe el empate; eso queda para la siguiente fase.
-- ============================================================================

BEGIN;

DO $$
BEGIN
    IF to_regprocedure('public.obtener_resultados_oficiales_ronda(uuid)') IS NULL THEN
        RAISE EXCEPTION
            'Migración 158 requiere public.obtener_resultados_oficiales_ronda(uuid) de la 155.';
    END IF;

    IF to_regprocedure('public.validar_cierre_resultados_ronda(uuid)') IS NULL THEN
        RAISE EXCEPTION
            'Migración 158 requiere public.validar_cierre_resultados_ronda(uuid) corregida por la 157.';
    END IF;

    IF to_regclass('public.tournament_scorecard_round_outcomes') IS NULL THEN
        RAISE EXCEPTION
            'Migración 158 requiere tournament_scorecard_round_outcomes de la 156.';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.obtener_leaderboard_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_results jsonb;
    v_close jsonb;
    v_tournament_id uuid;
    v_round_number integer;
    v_round_date date;
    v_round_resolved boolean;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id es obligatorio.'
            USING ERRCODE = '22023';
    END IF;

    SELECT
        tournament_id,
        numero_ronda,
        fecha
      INTO
        v_tournament_id,
        v_round_number,
        v_round_date
      FROM public.tournament_rounds
     WHERE id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar este leaderboard.'
            USING ERRCODE = '42501';
    END IF;

    v_results := public.obtener_resultados_oficiales_ronda(
        p_tournament_round_id
    );

    v_close := public.validar_cierre_resultados_ronda(
        p_tournament_round_id
    );

    v_round_resolved := COALESCE(
        (v_close->>'readyToCloseResults')::boolean,
        false
    );

    RETURN (
        WITH raw_cards AS (
            SELECT
                (c->>'scoreCardId')::uuid AS score_card_id,
                c->>'cardFolio' AS card_folio,
                (c->>'cardNumber')::integer AS card_number,

                (c->>'playerId')::uuid AS player_id,
                c->>'playerName' AS player_name,

                NULLIF(c->>'tournamentRegistrationId','')::uuid
                    AS tournament_registration_id,

                NULLIF(c->>'tournamentCategoryId','')::uuid
                    AS tournament_category_id,

                c->>'categoryCode' AS category_code,
                c->>'categoryName' AS category_name,
                NULLIF(c->>'categoryDisplayOrder','')::integer
                    AS category_display_order,

                NULLIF(c->>'teeId','')::uuid AS tee_id,
                c->>'teeName' AS tee_name,

                NULLIF(c->>'handicapIndex','')::numeric
                    AS handicap_index,
                NULLIF(c->>'courseHandicap','')::integer
                    AS course_handicap,
                NULLIF(c->>'playingHandicap','')::integer
                    AS playing_handicap,

                COALESCE((c->>'ready')::boolean,false) AS official_ready,
                c->>'resultStatus' AS pipeline_status,

                NULLIF(c->>'officialGrossTotal','')::integer
                    AS official_gross_total,
                NULLIF(c->>'officialNetTotal','')::integer
                    AS official_net_total,

                c->'holes' AS official_holes

            FROM jsonb_array_elements(v_results->'cards') c
        ),

        enriched AS (
            SELECT
                rc.*,
                o.outcome_code,
                o.reason AS outcome_reason,

                CASE
                    WHEN rc.official_ready THEN 'OFFICIAL'
                    WHEN o.outcome_code IS NOT NULL THEN o.outcome_code
                    ELSE rc.pipeline_status
                END AS competition_status,

                rc.official_ready AS eligible_for_ranking

            FROM raw_cards rc
            LEFT JOIN public.tournament_scorecard_round_outcomes o
              ON o.score_card_id = rc.score_card_id
        ),

        gross_ranked AS (
            SELECT
                e.score_card_id,
                CASE
                    WHEN e.eligible_for_ranking
                    THEN rank() OVER (
                        PARTITION BY e.tournament_category_id
                        ORDER BY e.official_gross_total ASC
                    )::integer
                    ELSE NULL
                END AS gross_rank,

                CASE
                    WHEN e.eligible_for_ranking
                    THEN count(*) OVER (
                        PARTITION BY
                            e.tournament_category_id,
                            e.official_gross_total
                    )::integer
                    ELSE NULL
                END AS gross_tie_size
            FROM enriched e
            WHERE e.eligible_for_ranking
        ),

        net_ranked AS (
            SELECT
                e.score_card_id,
                CASE
                    WHEN e.eligible_for_ranking
                    THEN rank() OVER (
                        PARTITION BY e.tournament_category_id
                        ORDER BY e.official_net_total ASC
                    )::integer
                    ELSE NULL
                END AS net_rank,

                CASE
                    WHEN e.eligible_for_ranking
                    THEN count(*) OVER (
                        PARTITION BY
                            e.tournament_category_id,
                            e.official_net_total
                    )::integer
                    ELSE NULL
                END AS net_tie_size
            FROM enriched e
            WHERE e.eligible_for_ranking
        ),

        combined AS (
            SELECT
                e.*,
                gr.gross_rank,
                nr.net_rank,
                COALESCE(gr.gross_tie_size,0) AS gross_tie_size,
                COALESCE(nr.net_tie_size,0) AS net_tie_size,

                (COALESCE(gr.gross_tie_size,0) > 1) AS gross_tiebreak_pending,
                (COALESCE(nr.net_tie_size,0) > 1) AS net_tiebreak_pending

            FROM enriched e
            LEFT JOIN gross_ranked gr
              ON gr.score_card_id=e.score_card_id
            LEFT JOIN net_ranked nr
              ON nr.score_card_id=e.score_card_id
        ),

        category_summary AS (
            SELECT
                tournament_category_id,
                category_code,
                category_name,
                category_display_order,

                count(*) AS total_players,

                count(*) FILTER (
                    WHERE competition_status='OFFICIAL'
                ) AS official_players,

                count(*) FILTER (
                    WHERE competition_status='WD'
                ) AS wd,

                count(*) FILTER (
                    WHERE competition_status='DNF'
                ) AS dnf,

                count(*) FILTER (
                    WHERE competition_status='DQ'
                ) AS dq,

                count(*) FILTER (
                    WHERE competition_status='DNS'
                ) AS dns,

                count(*) FILTER (
                    WHERE competition_status='NO_CARD'
                ) AS no_card,

                bool_or(gross_tiebreak_pending)
                    FILTER (WHERE eligible_for_ranking)
                    AS has_gross_ties,

                bool_or(net_tiebreak_pending)
                    FILTER (WHERE eligible_for_ranking)
                    AS has_net_ties

            FROM combined
            GROUP BY
                tournament_category_id,
                category_code,
                category_name,
                category_display_order
        ),

        global_summary AS (
            SELECT
                count(*) AS total_players,
                count(*) FILTER (
                    WHERE competition_status='OFFICIAL'
                ) AS official_players,
                count(*) FILTER (
                    WHERE competition_status IN ('WD','DNF','DQ','DNS','NO_CARD')
                ) AS terminal_exceptions,
                count(*) FILTER (
                    WHERE competition_status NOT IN (
                        'OFFICIAL','WD','DNF','DQ','DNS','NO_CARD'
                    )
                ) AS unresolved_players,
                bool_or(gross_tiebreak_pending)
                    FILTER (WHERE eligible_for_ranking)
                    AS has_gross_ties,
                bool_or(net_tiebreak_pending)
                    FILTER (WHERE eligible_for_ranking)
                    AS has_net_ties
            FROM combined
        ),

        publication AS (
            SELECT
                COALESCE(has_gross_ties,false)
                    OR COALESCE(has_net_ties,false)
                    AS has_any_ties
            FROM global_summary
        )

        SELECT jsonb_build_object(
            'round',
            jsonb_build_object(
                'tournamentId', v_tournament_id,
                'tournamentRoundId', p_tournament_round_id,
                'roundNumber', v_round_number,
                'roundDate', v_round_date
            ),

            'status',
            jsonb_build_object(
                'roundResolved', v_round_resolved,
                'hasAnyTies',
                    (SELECT has_any_ties FROM publication),
                'leaderboardStatus',
                    CASE
                        WHEN NOT v_round_resolved
                            THEN 'PROVISIONAL'
                        WHEN (SELECT has_any_ties FROM publication)
                            THEN 'READY_FOR_TIEBREAK'
                        ELSE 'READY_FOR_PUBLICATION'
                    END
            ),

            'summary',
            (
                SELECT jsonb_build_object(
                    'totalPlayers', total_players,
                    'officialPlayers', official_players,
                    'terminalExceptions', terminal_exceptions,
                    'unresolvedPlayers', unresolved_players,
                    'hasGrossTies', COALESCE(has_gross_ties,false),
                    'hasNetTies', COALESCE(has_net_ties,false)
                )
                FROM global_summary
            ),

            'categories',
            COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'tournamentCategoryId',
                            cs.tournament_category_id,
                        'categoryCode', cs.category_code,
                        'categoryName', cs.category_name,
                        'categoryDisplayOrder',
                            cs.category_display_order,

                        'summary',
                        jsonb_build_object(
                            'totalPlayers', cs.total_players,
                            'officialPlayers', cs.official_players,
                            'WD', cs.wd,
                            'DNF', cs.dnf,
                            'DQ', cs.dq,
                            'DNS', cs.dns,
                            'NO_CARD', cs.no_card,
                            'hasGrossTies',
                                COALESCE(cs.has_gross_ties,false),
                            'hasNetTies',
                                COALESCE(cs.has_net_ties,false)
                        ),

                        'players',
                        COALESCE((
                            SELECT jsonb_agg(
                                jsonb_build_object(
                                    'scoreCardId', c.score_card_id,
                                    'cardFolio', c.card_folio,
                                    'playerId', c.player_id,
                                    'playerName', c.player_name,
                                    'teeId', c.tee_id,
                                    'teeName', c.tee_name,

                                    'handicapIndex', c.handicap_index,
                                    'courseHandicap', c.course_handicap,
                                    'playingHandicap', c.playing_handicap,

                                    'competitionStatus',
                                        c.competition_status,
                                    'pipelineStatus',
                                        c.pipeline_status,
                                    'outcomeReason',
                                        c.outcome_reason,
                                    'eligibleForRanking',
                                        c.eligible_for_ranking,

                                    'gross',
                                    jsonb_build_object(
                                        'total',
                                            c.official_gross_total,
                                        'rank',
                                            c.gross_rank,
                                        'tieSize',
                                            NULLIF(c.gross_tie_size,0),
                                        'tiebreakPending',
                                            c.gross_tiebreak_pending
                                    ),

                                    'net',
                                    jsonb_build_object(
                                        'total',
                                            c.official_net_total,
                                        'rank',
                                            c.net_rank,
                                        'tieSize',
                                            NULLIF(c.net_tie_size,0),
                                        'tiebreakPending',
                                            c.net_tiebreak_pending
                                    )
                                )
                                ORDER BY
                                    CASE
                                        WHEN c.eligible_for_ranking THEN 0
                                        ELSE 1
                                    END,
                                    c.net_rank NULLS LAST,
                                    c.gross_rank NULLS LAST,
                                    c.card_number,
                                    c.player_name
                            )
                            FROM combined c
                            WHERE c.tournament_category_id
                                  IS NOT DISTINCT FROM
                                  cs.tournament_category_id
                        ), '[]'::jsonb)
                    )
                    ORDER BY
                        cs.category_display_order NULLS LAST,
                        cs.category_name NULLS LAST
                )
                FROM category_summary cs
            ), '[]'::jsonb)
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_leaderboard_ronda(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.obtener_leaderboard_ronda(uuid)
TO authenticated;

COMMIT;
