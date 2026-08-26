-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 186 Fase 1L
-- Acumulación multirronda Stableford Individual
--
-- OBJETIVO
--   1) Acumular puntos por tournament_registration_id.
--   2) Considerar únicamente rondas congeladas Stableford Individual.
--   3) Sumar Gross/Net sólo cuando TODAS las rondas requeridas estén oficiales.
--   4) Mantener outcomes excepcionales como estados por ronda; no convertirlos
--      automáticamente en sanción global del torneo.
--   5) Crear leaderboard acumulado por categoría con puntos DESCENDENTE.
--
-- NO HACE
--   - No implementa todavía desempate multirronda.
--   - No define todavía propagación global de WD/DNF/DQ/DNS/NO_CARD.
--   - No modifica resultados ni leaderboards por ronda.
-- ============================================================================

BEGIN;

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

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar resultados acumulados.'
            USING ERRCODE='42501';
    END IF;

    FOR v_round IN
        SELECT
            tr.id,
            tr.numero_ronda,
            tr.fecha,
            rcs.id AS round_condition_snapshot_id
        FROM public.tournament_rounds tr
        JOIN public.tournament_round_condition_snapshots rcs
          ON rcs.tournament_round_id=tr.id
         AND rcs.tournament_id=tr.tournament_id
        WHERE tr.tournament_id=p_tournament_id
          AND rcs.scoring_engine='stableford'
          AND rcs.participation_type='individual'
        ORDER BY tr.numero_ronda,tr.fecha,tr.id
    LOOP
        v_required_rounds := v_required_rounds + 1;

        v_round_results :=
            public.obtener_resultados_stableford_oficiales_ronda(
                v_round.id
            );

        v_rounds := v_rounds || jsonb_build_array(
            jsonb_build_object(
                'tournamentRoundId',v_round.id,
                'roundNumber',v_round.numero_ronda,
                'roundDate',v_round.fecha,
                'results',v_round_results
            )
        );
    END LOOP;

    IF v_required_rounds=0 THEN
        RAISE EXCEPTION
            'El torneo no tiene rondas Stableford Individual congeladas.'
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

                NULLIF(c->>'tournamentRegistrationId','')::uuid
                    AS tournament_registration_id,
                NULLIF(c->>'playerId','')::uuid
                    AS player_id,
                c->>'playerName'
                    AS player_name,

                NULLIF(c->>'tournamentCategoryId','')::uuid
                    AS tournament_category_id,
                c->>'categoryCode'
                    AS category_code,
                c->>'categoryName'
                    AS category_name,
                NULLIF(c->>'categoryDisplayOrder','')::integer
                    AS category_display_order,

                COALESCE((c->>'ready')::boolean,false)
                    AS official_ready,
                c->>'competitionStatus'
                    AS competition_status,
                c->>'outcomeReason'
                    AS outcome_reason,

                COALESCE((c->>'grossEnabled')::boolean,false)
                    AS gross_enabled,
                COALESCE((c->>'netEnabled')::boolean,false)
                    AS net_enabled,

                NULLIF(c->>'grossPointsTotal','')::integer
                    AS gross_points,
                NULLIF(c->>'netPointsTotal','')::integer
                    AS net_points

            FROM jsonb_array_elements(v_rounds) r
            CROSS JOIN LATERAL jsonb_array_elements(
                COALESCE(r->'results'->'cards','[]'::jsonb)
            ) c
        ),

        registrations AS (
            SELECT
                tr.id AS tournament_registration_id,
                tr.player_id,
                tr.tournament_category_id,
                p.nombre AS player_name,
                c.codigo AS category_code,
                c.nombre AS category_name,
                c.display_order AS category_display_order
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
                ) AS player_name,

                r.tournament_category_id,
                COALESCE(
                    max(rc.category_code),
                    r.category_code
                ) AS category_code,
                COALESCE(
                    max(rc.category_name),
                    r.category_name
                ) AS category_name,
                COALESCE(
                    max(rc.category_display_order),
                    r.category_display_order
                ) AS category_display_order,

                count(DISTINCT rc.tournament_round_id)
                    AS rounds_with_card,

                count(DISTINCT rc.tournament_round_id)
                    FILTER (
                        WHERE rc.official_ready
                    ) AS official_rounds,

                count(DISTINCT rc.tournament_round_id)
                    FILTER (
                        WHERE rc.competition_status
                              IN ('WD','DNF','DQ','DNS','NO_CARD')
                    ) AS exceptional_rounds,

                bool_and(rc.gross_enabled)
                    FILTER (
                        WHERE rc.tournament_round_id IS NOT NULL
                    ) AS gross_enabled_all,

                bool_and(rc.net_enabled)
                    FILTER (
                        WHERE rc.tournament_round_id IS NOT NULL
                    ) AS net_enabled_all,

                sum(rc.gross_points)
                    FILTER (
                        WHERE rc.official_ready
                    )::integer AS gross_points_partial,

                sum(rc.net_points)
                    FILTER (
                        WHERE rc.official_ready
                    )::integer AS net_points_partial,

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
                    ) FILTER (
                        WHERE rc.tournament_round_id IS NOT NULL
                    ),
                    '[]'::jsonb
                ) AS rounds

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
                ) AS accumulation_ready,

                CASE
                    WHEN pr.exceptional_rounds>0
                        THEN 'ROUND_EXCEPTION'
                    WHEN pr.rounds_with_card<v_required_rounds
                        THEN 'ROUND_CARD_MISSING'
                    WHEN pr.official_rounds<v_required_rounds
                        THEN 'ROUND_RESULT_PENDING'
                    ELSE 'OFFICIAL'
                END AS accumulation_status,

                CASE
                    WHEN pr.official_rounds=v_required_rounds
                     AND pr.exceptional_rounds=0
                     AND COALESCE(pr.gross_enabled_all,false)
                    THEN pr.gross_points_partial
                    ELSE NULL
                END AS gross_points_total,

                CASE
                    WHEN pr.official_rounds=v_required_rounds
                     AND pr.exceptional_rounds=0
                     AND COALESCE(pr.net_enabled_all,false)
                    THEN pr.net_points_partial
                    ELSE NULL
                END AS net_points_total

            FROM per_registration pr
        ),

        summary AS (
            SELECT
                count(*) AS registrations,
                count(*) FILTER (
                    WHERE accumulation_ready
                ) AS official_accumulations,
                count(*) FILTER (
                    WHERE NOT accumulation_ready
                ) AS pending_accumulations,
                count(*) FILTER (
                    WHERE exceptional_rounds>0
                ) AS registrations_with_round_exception
            FROM final
        )

        SELECT jsonb_build_object(
            'tournamentId',p_tournament_id,

            'roundsRequired',
                v_required_rounds,

            'summary',(
                SELECT jsonb_build_object(
                    'registrations',
                        registrations,
                    'officialAccumulations',
                        official_accumulations,
                    'pendingAccumulations',
                        pending_accumulations,
                    'registrationsWithRoundException',
                        registrations_with_round_exception
                )
                FROM summary
            ),

            'players',COALESCE((
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

                        'accumulationStatus',
                            f.accumulation_status,
                        'ready',
                            f.accumulation_ready,

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
-- 2. Leaderboard acumulado del torneo.
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
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    v_results :=
        public.obtener_resultados_stableford_torneo(
            p_tournament_id
        );

    RETURN (
        WITH raw AS (
            SELECT
                NULLIF(
                    p->>'tournamentRegistrationId',
                    ''
                )::uuid AS tournament_registration_id,

                NULLIF(p->>'playerId','')::uuid
                    AS player_id,
                p->>'playerName'
                    AS player_name,

                NULLIF(
                    p->>'tournamentCategoryId',
                    ''
                )::uuid AS tournament_category_id,

                p->>'categoryCode'
                    AS category_code,
                p->>'categoryName'
                    AS category_name,
                NULLIF(
                    p->>'categoryDisplayOrder',
                    ''
                )::integer AS category_display_order,

                COALESCE(
                    (p->>'ready')::boolean,
                    false
                ) AS accumulation_ready,

                p->>'accumulationStatus'
                    AS accumulation_status,

                COALESCE(
                    (p->>'grossEnabled')::boolean,
                    false
                ) AS gross_enabled,

                COALESCE(
                    (p->>'netEnabled')::boolean,
                    false
                ) AS net_enabled,

                NULLIF(
                    p->>'grossPointsTotal',
                    ''
                )::integer AS gross_points_total,

                NULLIF(
                    p->>'netPointsTotal',
                    ''
                )::integer AS net_points_total,

                p->'rounds'
                    AS rounds

            FROM jsonb_array_elements(
                v_results->'players'
            ) p
        ),

        gross_ranked AS (
            SELECT
                r.tournament_registration_id,

                rank() OVER (
                    PARTITION BY r.tournament_category_id
                    ORDER BY r.gross_points_total DESC
                )::integer AS gross_rank,

                count(*) OVER (
                    PARTITION BY
                        r.tournament_category_id,
                        r.gross_points_total
                )::integer AS gross_tie_size

            FROM raw r
            WHERE r.accumulation_ready
              AND r.gross_enabled
        ),

        net_ranked AS (
            SELECT
                r.tournament_registration_id,

                rank() OVER (
                    PARTITION BY r.tournament_category_id
                    ORDER BY r.net_points_total DESC
                )::integer AS net_rank,

                count(*) OVER (
                    PARTITION BY
                        r.tournament_category_id,
                        r.net_points_total
                )::integer AS net_tie_size

            FROM raw r
            WHERE r.accumulation_ready
              AND r.net_enabled
        ),

        combined AS (
            SELECT
                r.*,
                g.gross_rank,
                g.gross_tie_size,
                n.net_rank,
                n.net_tie_size,

                (
                    r.gross_enabled
                    AND COALESCE(g.gross_tie_size,0)>1
                ) AS gross_tiebreak_pending,

                (
                    r.net_enabled
                    AND COALESCE(n.net_tie_size,0)>1
                ) AS net_tiebreak_pending

            FROM raw r
            LEFT JOIN gross_ranked g
              ON g.tournament_registration_id
                    =r.tournament_registration_id
            LEFT JOIN net_ranked n
              ON n.tournament_registration_id
                    =r.tournament_registration_id
        ),

        categories AS (
            SELECT
                tournament_category_id,
                category_code,
                category_name,
                category_display_order,

                count(*) AS total_players,
                count(*) FILTER (
                    WHERE accumulation_ready
                ) AS official_players,

                bool_or(gross_tiebreak_pending)
                    FILTER (
                        WHERE accumulation_ready
                    ) AS has_gross_ties,

                bool_or(net_tiebreak_pending)
                    FILTER (
                        WHERE accumulation_ready
                    ) AS has_net_ties

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
                    WHERE NOT accumulation_ready
                ) AS pending_players,

                bool_or(
                    gross_tiebreak_pending
                    OR net_tiebreak_pending
                ) FILTER (
                    WHERE accumulation_ready
                ) AS has_any_ties
            FROM combined
        )

        SELECT jsonb_build_object(
            'tournamentId',
                p_tournament_id,

            'roundsRequired',
                v_results->'roundsRequired',

            'status',(
                SELECT jsonb_build_object(
                    'pendingPlayers',
                        pending_players,
                    'hasAnyTies',
                        COALESCE(has_any_ties,false),

                    'leaderboardStatus',
                        CASE
                            WHEN pending_players>0
                                THEN 'PROVISIONAL'
                            WHEN COALESCE(
                                has_any_ties,
                                false
                            )
                                THEN 'READY_FOR_TIEBREAK'
                            ELSE 'READY_FOR_PUBLICATION'
                        END
                )
                FROM global_state
            ),

            'categories',COALESCE((
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
                                'officialPlayers',
                                    c.official_players,
                                'hasGrossTies',
                                    COALESCE(
                                        c.has_gross_ties,
                                        false
                                    ),
                                'hasNetTies',
                                    COALESCE(
                                        c.has_net_ties,
                                        false
                                    )
                            ),

                        'players',COALESCE((
                            SELECT jsonb_agg(
                                jsonb_build_object(
                                    'tournamentRegistrationId',
                                        p.tournament_registration_id,
                                    'playerId',
                                        p.player_id,
                                    'playerName',
                                        p.player_name,

                                    'accumulationStatus',
                                        p.accumulation_status,
                                    'eligibleForRanking',
                                        p.accumulation_ready,

                                    'gross',
                                        jsonb_build_object(
                                            'enabled',
                                                p.gross_enabled,
                                            'points',
                                                p.gross_points_total,
                                            'rank',
                                                p.gross_rank,
                                            'tieSize',
                                                p.gross_tie_size,
                                            'tiebreakPending',
                                                p.gross_tiebreak_pending
                                        ),

                                    'net',
                                        jsonb_build_object(
                                            'enabled',
                                                p.net_enabled,
                                            'points',
                                                p.net_points_total,
                                            'rank',
                                                p.net_rank,
                                            'tieSize',
                                                p.net_tie_size,
                                            'tiebreakPending',
                                                p.net_tiebreak_pending
                                        ),

                                    'rounds',
                                        p.rounds
                                )
                                ORDER BY
                                    CASE
                                        WHEN p.accumulation_ready
                                            THEN 0
                                        ELSE 1
                                    END,
                                    p.net_rank NULLS LAST,
                                    p.gross_rank NULLS LAST,
                                    p.player_name
                            )
                            FROM combined p
                            WHERE p.tournament_category_id
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
-- FIN MIGRACIÓN 186 FASE 1L
-- ============================================================================
