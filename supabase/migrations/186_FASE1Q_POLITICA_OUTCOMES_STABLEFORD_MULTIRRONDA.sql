-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 186 Fase 1Q
-- Política global de outcomes Stableford multirronda
--
-- POLÍTICA V1
--   - Todas las rondas Stableford del torneo cuentan para el acumulado.
--   - Para ser elegible al ranking acumulado, el jugador debe tener resultado
--     oficial en TODAS las rondas y no tener outcomes terminales.
--   - DQ / WD / DNF / DNS / NO_CARD son estados terminales de la participación
--     acumulada: no rankean, pero tampoco mantienen el torneo "pendiente".
--   - No se inventan puntos 0 ni scores para esas rondas.
--   - Se conserva la evidencia de cada outcome por ronda.
--
-- FUNDAMENTO
--   Rule 21.1: gana quien completa todas las rondas con más puntos.
--   La excepción "una DQ de una ronda no elimina del torneo" sólo aplica cuando
--   las Condiciones de la Competición establecen que no todas las rondas cuentan.
--
-- FUTURO
--   Un formato "mejores N de M rondas" requerirá otra política/versionado.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Resultados acumulados: separar "resuelto competitivamente" de
--    "elegible para ranking".
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_resultados_stableford_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_round record;
    v_round_results jsonb;
    v_rounds jsonb := '[]'::jsonb;
    v_required_rounds integer := 0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_tournament_id IS NULL THEN
        RAISE EXCEPTION 'tournament_id es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.tournaments t
        WHERE t.id=p_tournament_id
    ) THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar resultados acumulados.'
            USING ERRCODE='42501';
    END IF;

    FOR v_round IN
        SELECT
            tr.id,
            tr.numero_ronda,
            tr.fecha
        FROM public.tournament_rounds tr
        JOIN public.tournament_round_condition_snapshots rcs
          ON rcs.tournament_round_id=tr.id
         AND rcs.tournament_id=tr.tournament_id
        WHERE tr.tournament_id=p_tournament_id
          AND tr.activo=true
          AND rcs.scoring_engine='stableford'
          AND rcs.participation_type='individual'
        ORDER BY
            tr.numero_ronda,
            tr.fecha,
            tr.id
    LOOP
        v_required_rounds := v_required_rounds + 1;

        v_round_results :=
            public.obtener_resultados_stableford_oficiales_ronda(
                v_round.id
            );

        v_rounds :=
            v_rounds
            || jsonb_build_array(
                jsonb_build_object(
                    'tournamentRoundId',
                        v_round.id,
                    'roundNumber',
                        v_round.numero_ronda,
                    'roundDate',
                        v_round.fecha,
                    'results',
                        v_round_results
                )
            );
    END LOOP;

    IF v_required_rounds=0 THEN
        RAISE EXCEPTION
            'El torneo no tiene rondas Stableford Individual activas y congeladas.'
            USING ERRCODE='55000';
    END IF;

    RETURN (
        WITH round_cards AS (
            SELECT
                (r->>'tournamentRoundId')::uuid
                    AS tournament_round_id,

                (r->>'roundNumber')::integer
                    AS round_number,

                (r->>'roundDate')::date
                    AS round_date,

                NULLIF(
                    c->>'tournamentRegistrationId',
                    ''
                )::uuid
                    AS tournament_registration_id,

                NULLIF(c->>'playerId','')::uuid
                    AS player_id,

                c->>'playerName'
                    AS player_name,

                NULLIF(
                    c->>'tournamentCategoryId',
                    ''
                )::uuid
                    AS tournament_category_id,

                c->>'categoryCode'
                    AS category_code,

                c->>'categoryName'
                    AS category_name,

                NULLIF(
                    c->>'categoryDisplayOrder',
                    ''
                )::integer
                    AS category_display_order,

                COALESCE(
                    (c->>'ready')::boolean,
                    false
                )
                    AS official_ready,

                c->>'competitionStatus'
                    AS competition_status,

                c->>'outcomeReason'
                    AS outcome_reason,

                COALESCE(
                    (c->>'grossEnabled')::boolean,
                    false
                )
                    AS gross_enabled,

                COALESCE(
                    (c->>'netEnabled')::boolean,
                    false
                )
                    AS net_enabled,

                NULLIF(
                    c->>'grossPointsTotal',
                    ''
                )::integer
                    AS gross_points,

                NULLIF(
                    c->>'netPointsTotal',
                    ''
                )::integer
                    AS net_points

            FROM jsonb_array_elements(v_rounds) r

            CROSS JOIN LATERAL jsonb_array_elements(
                COALESCE(
                    r->'results'->'cards',
                    '[]'::jsonb
                )
            ) c
        ),

        registrations AS (
            SELECT
                tr.id
                    AS tournament_registration_id,

                tr.player_id,

                tr.tournament_category_id,

                p.nombre
                    AS player_name,

                c.codigo
                    AS category_code,

                c.nombre
                    AS category_name,

                c.display_order
                    AS category_display_order

            FROM public.tournament_registrations tr

            LEFT JOIN public.players p
              ON p.id=tr.player_id

            LEFT JOIN public.tournament_categories tc
              ON tc.id=tr.tournament_category_id

            LEFT JOIN public.categories c
              ON c.id=tc.category_id

            WHERE tr.tournament_id=p_tournament_id
              AND tr.activo=true
        ),

        per_registration AS (
            SELECT
                r.tournament_registration_id,
                r.player_id,

                COALESCE(
                    max(rc.player_name),
                    r.player_name
                )
                    AS player_name,

                r.tournament_category_id,

                COALESCE(
                    max(rc.category_code),
                    r.category_code
                )
                    AS category_code,

                COALESCE(
                    max(rc.category_name),
                    r.category_name
                )
                    AS category_name,

                COALESCE(
                    max(rc.category_display_order),
                    r.category_display_order
                )
                    AS category_display_order,

                count(DISTINCT rc.tournament_round_id)
                    AS rounds_with_card,

                count(DISTINCT rc.tournament_round_id)
                    FILTER (
                        WHERE rc.official_ready
                    )
                    AS official_rounds,

                count(DISTINCT rc.tournament_round_id)
                    FILTER (
                        WHERE rc.competition_status
                              IN (
                                  'WD',
                                  'DNF',
                                  'DQ',
                                  'DNS',
                                  'NO_CARD'
                              )
                    )
                    AS exceptional_rounds,

                bool_and(rc.gross_enabled)
                    FILTER (
                        WHERE rc.tournament_round_id IS NOT NULL
                    )
                    AS gross_enabled_all,

                bool_and(rc.net_enabled)
                    FILTER (
                        WHERE rc.tournament_round_id IS NOT NULL
                    )
                    AS net_enabled_all,

                sum(rc.gross_points)
                    FILTER (
                        WHERE rc.official_ready
                    )::integer
                    AS gross_points_partial,

                sum(rc.net_points)
                    FILTER (
                        WHERE rc.official_ready
                    )::integer
                    AS net_points_partial,

                COALESCE(
                    jsonb_agg(
                        jsonb_build_object(
                            'tournamentRoundId',
                                rc.tournament_round_id,
                            'roundNumber',
                                rc.round_number,
                            'roundDate',
                                rc.round_date,
                            'competitionStatus',
                                rc.competition_status,
                            'outcomeReason',
                                rc.outcome_reason,
                            'ready',
                                rc.official_ready,
                            'grossEnabled',
                                rc.gross_enabled,
                            'netEnabled',
                                rc.net_enabled,
                            'grossPoints',
                                rc.gross_points,
                            'netPoints',
                                rc.net_points
                        )
                        ORDER BY
                            rc.round_number,
                            rc.round_date,
                            rc.tournament_round_id
                    )
                    FILTER (
                        WHERE rc.tournament_round_id IS NOT NULL
                    ),
                    '[]'::jsonb
                )
                    AS rounds,

                COALESCE(
                    jsonb_agg(
                        jsonb_build_object(
                            'tournamentRoundId',
                                rc.tournament_round_id,
                            'roundNumber',
                                rc.round_number,
                            'roundDate',
                                rc.round_date,
                            'outcomeCode',
                                rc.competition_status,
                            'reason',
                                rc.outcome_reason
                        )
                        ORDER BY
                            rc.round_number,
                            rc.round_date,
                            rc.tournament_round_id
                    )
                    FILTER (
                        WHERE rc.competition_status
                              IN (
                                  'WD',
                                  'DNF',
                                  'DQ',
                                  'DNS',
                                  'NO_CARD'
                              )
                    ),
                    '[]'::jsonb
                )
                    AS terminal_outcomes

            FROM registrations r

            LEFT JOIN round_cards rc
              ON rc.tournament_registration_id
                    =r.tournament_registration_id

            GROUP BY
                r.tournament_registration_id,
                r.player_id,
                r.player_name,
                r.tournament_category_id,
                r.category_code,
                r.category_name,
                r.category_display_order
        ),

        final AS (
            SELECT
                pr.*,

                (
                    pr.official_rounds=v_required_rounds
                    AND pr.exceptional_rounds=0
                )
                    AS eligible_for_ranking,

                (
                    (
                        pr.official_rounds=v_required_rounds
                        AND pr.exceptional_rounds=0
                    )
                    OR
                    pr.exceptional_rounds>0
                )
                    AS competition_resolved,

                CASE
                    WHEN pr.exceptional_rounds>0
                        THEN 'TERMINAL_EXCEPTION'

                    WHEN pr.rounds_with_card<v_required_rounds
                        THEN 'ROUND_CARD_MISSING'

                    WHEN pr.official_rounds<v_required_rounds
                        THEN 'ROUND_RESULT_PENDING'

                    ELSE 'OFFICIAL'
                END
                    AS accumulation_status,

                CASE
                    WHEN pr.official_rounds=v_required_rounds
                     AND pr.exceptional_rounds=0
                     AND COALESCE(
                         pr.gross_enabled_all,
                         false
                     )
                    THEN pr.gross_points_partial

                    ELSE NULL
                END
                    AS gross_points_total,

                CASE
                    WHEN pr.official_rounds=v_required_rounds
                     AND pr.exceptional_rounds=0
                     AND COALESCE(
                         pr.net_enabled_all,
                         false
                     )
                    THEN pr.net_points_partial

                    ELSE NULL
                END
                    AS net_points_total

            FROM per_registration pr
        ),

        summary AS (
            SELECT
                count(*)
                    AS registrations,

                count(*) FILTER (
                    WHERE competition_resolved
                )
                    AS resolved_participations,

                count(*) FILTER (
                    WHERE NOT competition_resolved
                )
                    AS pending_participations,

                count(*) FILTER (
                    WHERE eligible_for_ranking
                )
                    AS ranking_eligible,

                count(*) FILTER (
                    WHERE exceptional_rounds>0
                )
                    AS terminal_exceptions

            FROM final
        )

        SELECT jsonb_build_object(
            'schemaVersion',
                2,

            'tournamentId',
                p_tournament_id,

            'accumulationPolicy',
                jsonb_build_object(
                    'code',
                        'ALL_ROUNDS_REQUIRED_V1',

                    'allRoundsCount',
                        true,

                    'terminalOutcomeCodes',
                        jsonb_build_array(
                            'DQ',
                            'WD',
                            'DNF',
                            'DNS',
                            'NO_CARD'
                        ),

                    'terminalOutcomeEffect',
                        'NOT_ELIGIBLE_FOR_AGGREGATE_RANKING'
                ),

            'roundsRequired',
                v_required_rounds,

            'summary',(
                SELECT jsonb_build_object(
                    'registrations',
                        registrations,

                    'resolvedParticipations',
                        resolved_participations,

                    'pendingParticipations',
                        pending_participations,

                    'rankingEligible',
                        ranking_eligible,

                    'terminalExceptions',
                        terminal_exceptions
                )
                FROM summary
            ),

            'players',
                COALESCE((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'tournamentRegistrationId',
                                f.tournament_registration_id,

                            'playerId',
                                f.player_id,

                            'playerName',
                                f.player_name,

                            'tournamentCategoryId',
                                f.tournament_category_id,

                            'categoryCode',
                                f.category_code,

                            'categoryName',
                                f.category_name,

                            'categoryDisplayOrder',
                                f.category_display_order,

                            'roundsRequired',
                                v_required_rounds,

                            'roundsWithCard',
                                f.rounds_with_card,

                            'officialRounds',
                                f.official_rounds,

                            'exceptionalRounds',
                                f.exceptional_rounds,

                            'competitionResolved',
                                f.competition_resolved,

                            'eligibleForRanking',
                                f.eligible_for_ranking,

                            -- Compatibilidad: ready continúa significando
                            -- "listo/elegible para ranking", no sólo resuelto.
                            'ready',
                                f.eligible_for_ranking,

                            'accumulationStatus',
                                f.accumulation_status,

                            'grossEnabled',
                                COALESCE(
                                    f.gross_enabled_all,
                                    false
                                ),

                            'netEnabled',
                                COALESCE(
                                    f.net_enabled_all,
                                    false
                                ),

                            'grossPointsPartial',
                                f.gross_points_partial,

                            'netPointsPartial',
                                f.net_points_partial,

                            'grossPointsTotal',
                                f.gross_points_total,

                            'netPointsTotal',
                                f.net_points_total,

                            'terminalOutcomes',
                                f.terminal_outcomes,

                            'rounds',
                                f.rounds
                        )

                        ORDER BY
                            f.category_display_order NULLS LAST,
                            f.category_name NULLS LAST,
                            f.player_name
                    )

                    FROM final f
                ),'[]'::jsonb)
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.obtener_resultados_stableford_torneo(uuid)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    public.obtener_resultados_stableford_torneo(uuid)
TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 2. Leaderboard acumulado:
--    - rankea sólo elegibles;
--    - pendingPlayers cuenta sólo participaciones NO resueltas;
--    - terminales se muestran pero no bloquean publicación.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_leaderboard_stableford_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_results jsonb;
    v_ties jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    v_results :=
        public.obtener_resultados_stableford_torneo(
            p_tournament_id
        );

    v_ties :=
        public.obtener_desempates_stableford_torneo(
            p_tournament_id
        );

    RETURN (
        WITH raw AS (
            SELECT
                NULLIF(
                    p->>'tournamentRegistrationId',
                    ''
                )::uuid
                    AS tournament_registration_id,

                NULLIF(
                    p->>'playerId',
                    ''
                )::uuid
                    AS player_id,

                p->>'playerName'
                    AS player_name,

                NULLIF(
                    p->>'tournamentCategoryId',
                    ''
                )::uuid
                    AS tournament_category_id,

                p->>'categoryCode'
                    AS category_code,

                p->>'categoryName'
                    AS category_name,

                NULLIF(
                    p->>'categoryDisplayOrder',
                    ''
                )::integer
                    AS category_display_order,

                COALESCE(
                    (p->>'competitionResolved')::boolean,
                    false
                )
                    AS competition_resolved,

                COALESCE(
                    (p->>'eligibleForRanking')::boolean,
                    false
                )
                    AS eligible_for_ranking,

                p->>'accumulationStatus'
                    AS accumulation_status,

                COALESCE(
                    (p->>'grossEnabled')::boolean,
                    false
                )
                    AS gross_enabled,

                COALESCE(
                    (p->>'netEnabled')::boolean,
                    false
                )
                    AS net_enabled,

                NULLIF(
                    p->>'grossPointsTotal',
                    ''
                )::integer
                    AS gross_points_total,

                NULLIF(
                    p->>'netPointsTotal',
                    ''
                )::integer
                    AS net_points_total,

                COALESCE(
                    p->'terminalOutcomes',
                    '[]'::jsonb
                )
                    AS terminal_outcomes,

                p->'rounds'
                    AS rounds

            FROM jsonb_array_elements(
                v_results->'players'
            ) p
        ),

        gross_base AS (
            SELECT
                r.tournament_registration_id,

                rank() OVER (
                    PARTITION BY
                        r.tournament_category_id
                    ORDER BY
                        r.gross_points_total DESC
                )::integer
                    AS base_rank,

                count(*) OVER (
                    PARTITION BY
                        r.tournament_category_id,
                        r.gross_points_total
                )::integer
                    AS tie_size

            FROM raw r

            WHERE r.eligible_for_ranking
              AND r.gross_enabled
        ),

        net_base AS (
            SELECT
                r.tournament_registration_id,

                rank() OVER (
                    PARTITION BY
                        r.tournament_category_id
                    ORDER BY
                        r.net_points_total DESC
                )::integer
                    AS base_rank,

                count(*) OVER (
                    PARTITION BY
                        r.tournament_category_id,
                        r.net_points_total
                )::integer
                    AS tie_size

            FROM raw r

            WHERE r.eligible_for_ranking
              AND r.net_enabled
        ),

        automatic_players AS (
            SELECT
                NULLIF(
                    g->>'tournamentCategoryId',
                    ''
                )::uuid
                    AS tournament_category_id,

                g->>'resultType'
                    AS result_type,

                (g->>'tiedPoints')::integer
                    AS tied_points,

                (g->>'baseRank')::integer
                    AS base_rank,

                g->>'status'
                    AS group_status,

                NULLIF(
                    p->>'tournamentRegistrationId',
                    ''
                )::uuid
                    AS tournament_registration_id,

                NULLIF(
                    p->>'finalRank',
                    ''
                )::integer
                    AS final_rank,

                NULLIF(
                    p->>'tiebreakOrder',
                    ''
                )::integer
                    AS tiebreak_order,

                g->>'resolvedByMethodCode'
                    AS method_code,

                g->>'resolvedByMethodName'
                    AS method_name,

                NULL::uuid
                    AS resolution_id

            FROM jsonb_array_elements(
                COALESCE(
                    v_ties->'tieGroups',
                    '[]'::jsonb
                )
            ) g

            CROSS JOIN LATERAL
            jsonb_array_elements(
                COALESCE(
                    g->'players',
                    '[]'::jsonb
                )
            ) p

            WHERE g->>'status'='RESOLVED_AUTOMATIC'
        ),

        manual_players AS (
            SELECT
                r.tournament_category_id,

                r.tipo_resultado::text
                    AS result_type,

                r.tied_total
                    AS tied_points,

                r.base_rank,

                'RESOLVED_MANUAL'::text
                    AS group_status,

                p.tournament_registration_id,

                p.final_rank,

                p.order_in_tiebreak
                    AS tiebreak_order,

                r.method_code,

                r.method_name,

                r.id
                    AS resolution_id

            FROM public.tournament_aggregate_tiebreak_resolutions r

            JOIN public.tournament_aggregate_tiebreak_resolution_players p
              ON p.resolution_id=r.id

            WHERE r.tournament_id=p_tournament_id
              AND r.scoring_engine='stableford'
              AND r.status='COMPLETED'
        ),

        resolved_players AS (
            SELECT * FROM automatic_players
            UNION ALL
            SELECT * FROM manual_players
        ),

        combined AS (
            SELECT
                r.*,

                gb.base_rank
                    AS gross_base_rank,

                gb.tie_size
                    AS gross_tie_size,

                nb.base_rank
                    AS net_base_rank,

                nb.tie_size
                    AS net_tie_size,

                grp.final_rank
                    AS gross_resolved_rank,

                grp.group_status
                    AS gross_tiebreak_status,

                grp.method_code
                    AS gross_tiebreak_method_code,

                grp.method_name
                    AS gross_tiebreak_method_name,

                grp.resolution_id
                    AS gross_resolution_id,

                nrp.final_rank
                    AS net_resolved_rank,

                nrp.group_status
                    AS net_tiebreak_status,

                nrp.method_code
                    AS net_tiebreak_method_code,

                nrp.method_name
                    AS net_tiebreak_method_name,

                nrp.resolution_id
                    AS net_resolution_id,

                CASE
                    WHEN NOT r.gross_enabled
                        THEN NULL

                    WHEN NOT r.eligible_for_ranking
                        THEN NULL

                    WHEN COALESCE(
                        gb.tie_size,
                        0
                    )<=1
                        THEN gb.base_rank

                    ELSE grp.final_rank
                END
                    AS gross_final_rank,

                CASE
                    WHEN NOT r.net_enabled
                        THEN NULL

                    WHEN NOT r.eligible_for_ranking
                        THEN NULL

                    WHEN COALESCE(
                        nb.tie_size,
                        0
                    )<=1
                        THEN nb.base_rank

                    ELSE nrp.final_rank
                END
                    AS net_final_rank

            FROM raw r

            LEFT JOIN gross_base gb
              ON gb.tournament_registration_id
                    =r.tournament_registration_id

            LEFT JOIN net_base nb
              ON nb.tournament_registration_id
                    =r.tournament_registration_id

            LEFT JOIN resolved_players grp
              ON grp.tournament_registration_id
                    =r.tournament_registration_id
             AND grp.tournament_category_id
                    IS NOT DISTINCT FROM
                    r.tournament_category_id
             AND grp.result_type='gross'
             AND grp.base_rank=gb.base_rank
             AND grp.tied_points
                    =r.gross_points_total

            LEFT JOIN resolved_players nrp
              ON nrp.tournament_registration_id
                    =r.tournament_registration_id
             AND nrp.tournament_category_id
                    IS NOT DISTINCT FROM
                    r.tournament_category_id
             AND nrp.result_type='neto'
             AND nrp.base_rank=nb.base_rank
             AND nrp.tied_points
                    =r.net_points_total
        ),

        categories AS (
            SELECT
                tournament_category_id,
                category_code,
                category_name,
                category_display_order,

                count(*)
                    AS total_players,

                count(*) FILTER (
                    WHERE eligible_for_ranking
                )
                    AS ranking_eligible,

                count(*) FILTER (
                    WHERE competition_resolved
                      AND NOT eligible_for_ranking
                )
                    AS terminal_players,

                bool_or(
                    gross_enabled
                    AND eligible_for_ranking
                    AND COALESCE(
                        gross_tie_size,
                        0
                    )>1
                    AND gross_final_rank IS NULL
                )
                    AS gross_tiebreak_pending,

                bool_or(
                    net_enabled
                    AND eligible_for_ranking
                    AND COALESCE(
                        net_tie_size,
                        0
                    )>1
                    AND net_final_rank IS NULL
                )
                    AS net_tiebreak_pending

            FROM combined

            GROUP BY
                tournament_category_id,
                category_code,
                category_name,
                category_display_order
        ),

        global_state AS (
            SELECT
                count(*) FILTER (
                    WHERE NOT competition_resolved
                )
                    AS pending_players,

                count(*) FILTER (
                    WHERE competition_resolved
                      AND NOT eligible_for_ranking
                )
                    AS terminal_players,

                count(*) FILTER (
                    WHERE gross_enabled
                      AND eligible_for_ranking
                      AND COALESCE(
                          gross_tie_size,
                          0
                      )>1
                      AND gross_final_rank IS NULL
                )
                +
                count(*) FILTER (
                    WHERE net_enabled
                      AND eligible_for_ranking
                      AND COALESCE(
                          net_tie_size,
                          0
                      )>1
                      AND net_final_rank IS NULL
                )
                    AS unresolved_tie_entries

            FROM combined
        )

        SELECT jsonb_build_object(
            'schemaVersion',
                2,

            'tournamentId',
                p_tournament_id,

            'accumulationPolicy',
                v_results->'accumulationPolicy',

            'roundsRequired',
                v_results->'roundsRequired',

            'status',(
                SELECT jsonb_build_object(
                    'pendingPlayers',
                        pending_players,

                    'terminalPlayers',
                        terminal_players,

                    'unresolvedTieEntries',
                        unresolved_tie_entries,

                    'leaderboardStatus',
                        CASE
                            WHEN pending_players>0
                                THEN 'PROVISIONAL'

                            WHEN unresolved_tie_entries>0
                                THEN 'READY_FOR_TIEBREAK'

                            ELSE 'READY_FOR_PUBLICATION'
                        END
                )
                FROM global_state
            ),

            'categories',
                COALESCE((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'tournamentCategoryId',
                                c.tournament_category_id,

                            'categoryCode',
                                c.category_code,

                            'categoryName',
                                c.category_name,

                            'categoryDisplayOrder',
                                c.category_display_order,

                            'summary',
                                jsonb_build_object(
                                    'totalPlayers',
                                        c.total_players,

                                    'rankingEligible',
                                        c.ranking_eligible,

                                    'terminalPlayers',
                                        c.terminal_players,

                                    'grossTiebreakPending',
                                        COALESCE(
                                            c.gross_tiebreak_pending,
                                            false
                                        ),

                                    'netTiebreakPending',
                                        COALESCE(
                                            c.net_tiebreak_pending,
                                            false
                                        )
                                ),

                            'players',
                                COALESCE((
                                    SELECT jsonb_agg(
                                        jsonb_build_object(
                                            'tournamentRegistrationId',
                                                p.tournament_registration_id,

                                            'playerId',
                                                p.player_id,

                                            'playerName',
                                                p.player_name,

                                            'competitionResolved',
                                                p.competition_resolved,

                                            'accumulationStatus',
                                                p.accumulation_status,

                                            'eligibleForRanking',
                                                p.eligible_for_ranking,

                                            'terminalOutcomes',
                                                p.terminal_outcomes,

                                            'gross',
                                                jsonb_build_object(
                                                    'enabled',
                                                        p.gross_enabled,

                                                    'points',
                                                        p.gross_points_total,

                                                    'baseRank',
                                                        p.gross_base_rank,

                                                    'tieSize',
                                                        p.gross_tie_size,

                                                    'finalRank',
                                                        p.gross_final_rank,

                                                    'tiebreakStatus',
                                                        CASE
                                                            WHEN NOT p.gross_enabled
                                                                THEN NULL

                                                            WHEN NOT p.eligible_for_ranking
                                                                THEN 'NOT_ELIGIBLE'

                                                            WHEN COALESCE(
                                                                p.gross_tie_size,
                                                                0
                                                            )<=1
                                                                THEN 'NOT_NEEDED'

                                                            WHEN p.gross_final_rank IS NOT NULL
                                                                THEN COALESCE(
                                                                    p.gross_tiebreak_status,
                                                                    'RESOLVED'
                                                                )

                                                            ELSE 'PENDING'
                                                        END,

                                                    'tiebreakMethodCode',
                                                        p.gross_tiebreak_method_code,

                                                    'tiebreakMethodName',
                                                        p.gross_tiebreak_method_name,

                                                    'resolutionId',
                                                        p.gross_resolution_id
                                                ),

                                            'net',
                                                jsonb_build_object(
                                                    'enabled',
                                                        p.net_enabled,

                                                    'points',
                                                        p.net_points_total,

                                                    'baseRank',
                                                        p.net_base_rank,

                                                    'tieSize',
                                                        p.net_tie_size,

                                                    'finalRank',
                                                        p.net_final_rank,

                                                    'tiebreakStatus',
                                                        CASE
                                                            WHEN NOT p.net_enabled
                                                                THEN NULL

                                                            WHEN NOT p.eligible_for_ranking
                                                                THEN 'NOT_ELIGIBLE'

                                                            WHEN COALESCE(
                                                                p.net_tie_size,
                                                                0
                                                            )<=1
                                                                THEN 'NOT_NEEDED'

                                                            WHEN p.net_final_rank IS NOT NULL
                                                                THEN COALESCE(
                                                                    p.net_tiebreak_status,
                                                                    'RESOLVED'
                                                                )

                                                            ELSE 'PENDING'
                                                        END,

                                                    'tiebreakMethodCode',
                                                        p.net_tiebreak_method_code,

                                                    'tiebreakMethodName',
                                                        p.net_tiebreak_method_name,

                                                    'resolutionId',
                                                        p.net_resolution_id
                                                ),

                                            'rounds',
                                                p.rounds
                                        )

                                        ORDER BY
                                            CASE
                                                WHEN p.eligible_for_ranking
                                                    THEN 0

                                                WHEN p.competition_resolved
                                                    THEN 1

                                                ELSE 2
                                            END,

                                            COALESCE(
                                                p.net_final_rank,
                                                p.gross_final_rank,
                                                p.net_base_rank,
                                                p.gross_base_rank
                                            ) NULLS LAST,

                                            p.player_name
                                    )

                                    FROM combined p

                                    WHERE
                                        p.tournament_category_id
                                        IS NOT DISTINCT FROM
                                        c.tournament_category_id
                                ),'[]'::jsonb)
                        )

                        ORDER BY
                            c.category_display_order NULLS LAST,
                            c.category_name NULLS LAST
                    )

                    FROM categories c
                ),'[]'::jsonb)
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.obtener_leaderboard_stableford_torneo(uuid)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    public.obtener_leaderboard_stableford_torneo(uuid)
TO authenticated,service_role;

COMMIT;

-- ============================================================================
-- FIN MIGRACIÓN 186 FASE 1Q
-- ============================================================================
