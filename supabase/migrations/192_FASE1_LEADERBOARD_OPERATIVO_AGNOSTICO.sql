-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 192 Fase 1
-- Leaderboard operativo agnóstico por ronda
--
-- OBJETIVO
--   Exponer un contrato único de lectura para resultados preliminares por
--   categoría sin obligar al frontend a conocer la estructura particular de
--   cada motor de puntuación.
--
-- PRINCIPIOS
--   - No calcula scores, puntos ni desempates.
--   - Hace dispatch al leaderboard oficial ya existente del motor.
--   - Normaliza únicamente presentación/estado operativo.
--   - No exige cierre de ronda.
--   - Las posiciones sólo provienen del backend de resultados existente.
--   - Las modalidades sin motor de leaderboard implementado quedan
--     explícitamente UNSUPPORTED (fail-closed), nunca con datos inventados.
--
-- SOPORTE ACTUAL
--   - Stroke Play individual: scoring_engine = stroke | stroke_play
--   - Stableford individual: scoring_engine = stableford
--
-- NO MODIFICA
--   captura, conciliación, outcomes, scoring, desempates, cierres,
--   finalización, freeze, snapshots, datos históricos ni RLS de tablas.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_leaderboard_operativo_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_round_number integer;
    v_round_date date;
    v_scoring_engine text;
    v_participation_type text;
    v_source jsonb;
    v_supported boolean := false;
    v_source_rpc text;
    v_metric_unit text;
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
        tr.tournament_id,
        tr.numero_ronda,
        tr.fecha,
        rcs.scoring_engine,
        rcs.participation_type
    INTO
        v_tournament_id,
        v_round_number,
        v_round_date,
        v_scoring_engine,
        v_participation_type
    FROM public.tournament_rounds tr
    LEFT JOIN LATERAL (
        SELECT
            s.scoring_engine,
            s.participation_type
        FROM public.tournament_round_condition_snapshots s
        WHERE s.tournament_round_id = tr.id
        ORDER BY s.created_at DESC, s.id DESC
        LIMIT 1
    ) rcs ON true
    WHERE tr.id = p_tournament_round_id
      AND tr.activo = true;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe o no está activa.'
            USING ERRCODE = '22023';
    END IF;

    IF v_scoring_engine IS NULL THEN
        RAISE EXCEPTION
            'La ronda no tiene snapshot congelado de scoring.'
            USING ERRCODE = '55000';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar este leaderboard.'
            USING ERRCODE = '42501';
    END IF;

    -- Dispatch exclusivamente a motores ya existentes.
    IF v_participation_type = 'individual'
       AND v_scoring_engine IN ('stroke', 'stroke_play')
    THEN
        v_supported := true;
        v_source_rpc := 'obtener_leaderboard_ronda';
        v_metric_unit := 'STROKES';
        v_source := public.obtener_leaderboard_ronda(
            p_tournament_round_id
        );

    ELSIF v_participation_type = 'individual'
          AND v_scoring_engine = 'stableford'
    THEN
        v_supported := true;
        v_source_rpc := 'obtener_leaderboard_stableford_ronda';
        v_metric_unit := 'POINTS';
        v_source := public.obtener_leaderboard_stableford_ronda(
            p_tournament_round_id
        );
    END IF;

    -- Fail-closed para motores aún no implementados.
    IF NOT v_supported THEN
        RETURN jsonb_build_object(
            'schemaVersion', 1,
            'supported', false,
            'unsupportedReason', 'LEADERBOARD_ENGINE_NOT_IMPLEMENTED',
            'round', jsonb_build_object(
                'tournamentId', v_tournament_id,
                'tournamentRoundId', p_tournament_round_id,
                'roundNumber', v_round_number,
                'roundDate', v_round_date,
                'scoringEngine', v_scoring_engine,
                'participationType', v_participation_type
            ),
            'source', jsonb_build_object(
                'rpc', NULL,
                'metricUnit', NULL
            ),
            'status', jsonb_build_object(
                'leaderboardStatus', 'UNSUPPORTED'
            ),
            'summary', jsonb_build_object(
                'totalParticipants', 0,
                'resolvedParticipants', 0,
                'unresolvedParticipants', 0,
                'terminalExceptions', 0
            ),
            'categories', '[]'::jsonb
        );
    END IF;

    RETURN (
        WITH source_categories AS (
            SELECT
                c,
                NULLIF(c->>'tournamentCategoryId', '')::uuid
                    AS tournament_category_id,
                c->>'categoryCode' AS category_code,
                c->>'categoryName' AS category_name,
                NULLIF(c->>'categoryDisplayOrder', '')::integer
                    AS category_display_order
            FROM jsonb_array_elements(
                COALESCE(v_source->'categories', '[]'::jsonb)
            ) c
        ),

        normalized_players AS (
            SELECT
                sc.tournament_category_id,
                sc.category_code,
                sc.category_name,
                sc.category_display_order,
                p,
                NULLIF(p->>'scoreCardId', '')::uuid AS score_card_id,
                NULLIF(p->>'playerId', '')::uuid AS player_id,
                p->>'playerName' AS player_name,
                p->>'competitionStatus' AS competition_status,
                p->>'outcomeReason' AS outcome_reason,
                COALESCE(
                    (p->>'eligibleForRanking')::boolean,
                    false
                ) AS eligible_for_ranking,

                CASE
                    WHEN v_metric_unit = 'STROKES'
                        THEN NULLIF(p#>>'{gross,total}', '')::integer
                    ELSE NULLIF(p#>>'{gross,points}', '')::integer
                END AS gross_value,

                CASE
                    WHEN v_metric_unit = 'STROKES'
                        THEN NULLIF(p#>>'{gross,rank}', '')::integer
                    ELSE COALESCE(
                        NULLIF(p#>>'{gross,finalRank}', '')::integer,
                        NULLIF(p#>>'{gross,baseRank}', '')::integer
                    )
                END AS gross_rank,

                CASE
                    WHEN v_metric_unit = 'STROKES'
                        THEN COALESCE(
                            (p#>>'{gross,tiebreakPending}')::boolean,
                            false
                        )
                    ELSE COALESCE(
                        p#>>'{gross,tiebreakStatus}' = 'PENDING',
                        false
                    )
                END AS gross_tiebreak_pending,

                CASE
                    WHEN v_metric_unit = 'STROKES'
                        THEN NULLIF(p#>>'{net,total}', '')::integer
                    ELSE NULLIF(p#>>'{net,points}', '')::integer
                END AS net_value,

                CASE
                    WHEN v_metric_unit = 'STROKES'
                        THEN NULLIF(p#>>'{net,rank}', '')::integer
                    ELSE COALESCE(
                        NULLIF(p#>>'{net,finalRank}', '')::integer,
                        NULLIF(p#>>'{net,baseRank}', '')::integer
                    )
                END AS net_rank,

                CASE
                    WHEN v_metric_unit = 'STROKES'
                        THEN COALESCE(
                            (p#>>'{net,tiebreakPending}')::boolean,
                            false
                        )
                    ELSE COALESCE(
                        p#>>'{net,tiebreakStatus}' = 'PENDING',
                        false
                    )
                END AS net_tiebreak_pending,

                CASE
                    WHEN v_metric_unit = 'STROKES'
                        THEN NULLIF(p#>>'{gross,tieSize}', '')::integer
                    ELSE NULLIF(p#>>'{gross,tieSize}', '')::integer
                END AS gross_tie_size,

                CASE
                    WHEN v_metric_unit = 'STROKES'
                        THEN NULLIF(p#>>'{net,tieSize}', '')::integer
                    ELSE NULLIF(p#>>'{net,tieSize}', '')::integer
                END AS net_tie_size

            FROM source_categories sc
            CROSS JOIN LATERAL jsonb_array_elements(
                COALESCE(sc.c->'players', '[]'::jsonb)
            ) p
        ),

        category_counts AS (
            SELECT
                np.tournament_category_id,
                np.category_code,
                np.category_name,
                np.category_display_order,

                count(*)::integer AS total_participants,

                count(*) FILTER (
                    WHERE np.eligible_for_ranking
                )::integer AS ranked_participants,

                count(*) FILTER (
                    WHERE np.competition_status IN (
                        'WD','DNF','DQ','DNS','NO_CARD'
                    )
                )::integer AS terminal_exceptions,

                count(*) FILTER (
                    WHERE np.eligible_for_ranking
                       OR np.competition_status IN (
                            'WD','DNF','DQ','DNS','NO_CARD'
                       )
                )::integer AS resolved_participants,

                count(*) FILTER (
                    WHERE NOT (
                        np.eligible_for_ranking
                        OR np.competition_status IN (
                            'WD','DNF','DQ','DNS','NO_CARD'
                        )
                    )
                )::integer AS unresolved_participants,

                bool_or(np.gross_tiebreak_pending)
                    FILTER (WHERE np.eligible_for_ranking)
                    AS gross_tiebreak_pending,

                bool_or(np.net_tiebreak_pending)
                    FILTER (WHERE np.eligible_for_ranking)
                    AS net_tiebreak_pending

            FROM normalized_players np
            GROUP BY
                np.tournament_category_id,
                np.category_code,
                np.category_name,
                np.category_display_order
        ),

        normalized_categories AS (
            SELECT
                cc.*,
                CASE
                    WHEN cc.unresolved_participants > 0
                        THEN 'PROVISIONAL'
                    WHEN COALESCE(cc.gross_tiebreak_pending, false)
                      OR COALESCE(cc.net_tiebreak_pending, false)
                        THEN 'READY_FOR_TIEBREAK'
                    ELSE 'READY_FOR_PUBLICATION'
                END AS category_status
            FROM category_counts cc
        ),

        global_counts AS (
            SELECT
                COALESCE(sum(total_participants), 0)::integer
                    AS total_participants,
                COALESCE(sum(resolved_participants), 0)::integer
                    AS resolved_participants,
                COALESCE(sum(unresolved_participants), 0)::integer
                    AS unresolved_participants,
                COALESCE(sum(terminal_exceptions), 0)::integer
                    AS terminal_exceptions
            FROM normalized_categories
        )

        SELECT jsonb_build_object(
            'schemaVersion', 1,
            'supported', true,
            'unsupportedReason', NULL,

            'round', jsonb_build_object(
                'tournamentId', v_tournament_id,
                'tournamentRoundId', p_tournament_round_id,
                'roundNumber', v_round_number,
                'roundDate', v_round_date,
                'scoringEngine', v_scoring_engine,
                'participationType', v_participation_type
            ),

            'source', jsonb_build_object(
                'rpc', v_source_rpc,
                'metricUnit', v_metric_unit
            ),

            'status', jsonb_build_object(
                'leaderboardStatus',
                    COALESCE(
                        v_source#>>'{status,leaderboardStatus}',
                        'PROVISIONAL'
                    )
            ),

            'summary', (
                SELECT jsonb_build_object(
                    'totalParticipants', total_participants,
                    'resolvedParticipants', resolved_participants,
                    'unresolvedParticipants', unresolved_participants,
                    'terminalExceptions', terminal_exceptions
                )
                FROM global_counts
            ),

            'categories', COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'tournamentCategoryId',
                            nc.tournament_category_id,
                        'categoryCode',
                            nc.category_code,
                        'categoryName',
                            nc.category_name,
                        'categoryDisplayOrder',
                            nc.category_display_order,

                        'status',
                            nc.category_status,

                        'summary', jsonb_build_object(
                            'totalParticipants',
                                nc.total_participants,
                            'rankedParticipants',
                                nc.ranked_participants,
                            'resolvedParticipants',
                                nc.resolved_participants,
                            'unresolvedParticipants',
                                nc.unresolved_participants,
                            'terminalExceptions',
                                nc.terminal_exceptions,
                            'grossTiebreakPending',
                                COALESCE(
                                    nc.gross_tiebreak_pending,
                                    false
                                ),
                            'netTiebreakPending',
                                COALESCE(
                                    nc.net_tiebreak_pending,
                                    false
                                )
                        ),

                        'players', COALESCE((
                            SELECT jsonb_agg(
                                jsonb_build_object(
                                    'scoreCardId',
                                        np.score_card_id,
                                    'playerId',
                                        np.player_id,
                                    'playerName',
                                        np.player_name,
                                    'competitionStatus',
                                        np.competition_status,
                                    'outcomeReason',
                                        np.outcome_reason,
                                    'eligibleForRanking',
                                        np.eligible_for_ranking,

                                    'metrics', jsonb_strip_nulls(
                                        jsonb_build_object(
                                            'gross',
                                            CASE
                                                WHEN np.gross_value IS NULL
                                                THEN NULL
                                                ELSE jsonb_build_object(
                                                    'code', 'gross',
                                                    'label', 'Gross',
                                                    'value', np.gross_value,
                                                    'unit', v_metric_unit,
                                                    'rank', np.gross_rank,
                                                    'tieSize',
                                                        np.gross_tie_size,
                                                    'tiebreakPending',
                                                        np.gross_tiebreak_pending
                                                )
                                            END,

                                            'net',
                                            CASE
                                                WHEN np.net_value IS NULL
                                                THEN NULL
                                                ELSE jsonb_build_object(
                                                    'code', 'net',
                                                    'label', 'Neto',
                                                    'value', np.net_value,
                                                    'unit', v_metric_unit,
                                                    'rank', np.net_rank,
                                                    'tieSize',
                                                        np.net_tie_size,
                                                    'tiebreakPending',
                                                        np.net_tiebreak_pending
                                                )
                                            END
                                        )
                                    )
                                )
                                ORDER BY
                                    CASE
                                        WHEN np.eligible_for_ranking THEN 0
                                        WHEN np.competition_status IN (
                                            'WD','DNF','DQ','DNS','NO_CARD'
                                        ) THEN 1
                                        ELSE 2
                                    END,
                                    COALESCE(
                                        np.net_rank,
                                        np.gross_rank
                                    ) NULLS LAST,
                                    np.player_name
                            )
                            FROM normalized_players np
                            WHERE np.tournament_category_id
                                  IS NOT DISTINCT FROM
                                  nc.tournament_category_id
                        ), '[]'::jsonb)
                    )
                    ORDER BY
                        nc.category_display_order NULLS LAST,
                        nc.category_name NULLS LAST
                )
                FROM normalized_categories nc
            ), '[]'::jsonb)
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.obtener_leaderboard_operativo_ronda(uuid)
FROM PUBLIC;

REVOKE ALL ON FUNCTION
    public.obtener_leaderboard_operativo_ronda(uuid)
FROM anon;

GRANT EXECUTE ON FUNCTION
    public.obtener_leaderboard_operativo_ronda(uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION
    public.obtener_leaderboard_operativo_ronda(uuid)
TO service_role;

COMMENT ON FUNCTION public.obtener_leaderboard_operativo_ronda(uuid)
IS
'Contrato operativo agnóstico para leaderboard preliminar por categoría. '
'Despacha al motor oficial existente y normaliza presentación; no calcula '
'scores ni exige cierre de ronda. Soporte inicial: Stroke Play individual '
'y Stableford individual. Motores no implementados responden supported=false.';
