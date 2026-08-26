-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 186 Fase 1K
-- Resoluciones manuales Stableford + leaderboard final
--
-- OBJETIVO
--   1) Reutilizar las tablas históricas de resolución manual de desempates.
--   2) Crear resolver_desempate_manual_stableford_ronda(...), validado contra
--      obtener_desempates_stableford_ronda().
--   3) Mantener anulación/bitácora comunes.
--   4) Hacer que obtener_leaderboard_stableford_ronda(...) aplique:
--        - desempates automáticos de 1J;
--        - resoluciones manuales COMPLETED;
--        - posición final sólo cuando el grupo está resuelto.
--
-- NO HACE
--   - No modifica el resolver manual Stroke Play.
--   - No modifica las tablas de resultados Stroke Play.
--   - No implementa todavía acumulación multirronda.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Resolver manual específico Stableford.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.resolver_desempate_manual_stableford_ronda(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid,
    p_tipo_resultado public.tipo_resultado_desempate,
    p_base_rank integer,
    p_tied_total integer,
    p_score_card_order uuid[],
    p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_admin_user_id uuid;

    v_engine jsonb;
    v_group jsonb;

    v_group_status text;
    v_manual_method_code text;
    v_manual_method_name text;

    v_resolution_mode text;
    v_method_code text;
    v_method_name text;

    v_group_size integer;
    v_order_size integer;
    v_distinct_order_size integer;
    v_group_player_match integer;

    v_resolution_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL
       OR p_tournament_category_id IS NULL
       OR p_tipo_resultado IS NULL
       OR p_base_rank IS NULL
       OR p_tied_total IS NULL
    THEN
        RAISE EXCEPTION
            'Ronda, categoría, tipo de resultado, posición base y puntos empatados son obligatorios.'
            USING ERRCODE='22023';
    END IF;

    SELECT tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds
     WHERE id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para resolver este desempate Stableford.'
            USING ERRCODE='42501';
    END IF;

    SELECT au.id
      INTO v_admin_user_id
      FROM public.admin_users au
     WHERE au.auth_user_id=auth.uid()
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_user_id IS NULL THEN
        RAISE EXCEPTION
            'No fue posible resolver el admin_user asociado al usuario autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_score_card_order IS NULL
       OR COALESCE(array_length(p_score_card_order,1),0)<2
    THEN
        RAISE EXCEPTION
            'Debe indicar el orden completo de al menos dos tarjetas empatadas.'
            USING ERRCODE='22023';
    END IF;

    v_engine := public.obtener_desempates_stableford_ronda(
        p_tournament_round_id
    );

    SELECT g
      INTO v_group
      FROM jsonb_array_elements(
          COALESCE(v_engine->'tieGroups','[]'::jsonb)
      ) g
     WHERE NULLIF(g->>'tournamentCategoryId','')::uuid
           =p_tournament_category_id
       AND g->>'resultType'=p_tipo_resultado::text
       AND (g->>'baseRank')::integer=p_base_rank
       AND (g->>'tiedPoints')::integer=p_tied_total
     LIMIT 1;

    IF v_group IS NULL THEN
        RAISE EXCEPTION
            'No existe actualmente ese grupo de empate en el motor Stableford.'
            USING ERRCODE='55000';
    END IF;

    v_group_status := v_group->>'status';
    v_group_size := COALESCE((v_group->>'tieSize')::integer,0);

    IF v_group_status NOT IN (
        'MANUAL_PENDING',
        'TIE_PERSISTS_AFTER_RULES'
    ) THEN
        RAISE EXCEPTION
            'El grupo no requiere resolución manual. Estado actual: %',
            COALESCE(v_group_status,'NULL')
            USING ERRCODE='55000';
    END IF;

    SELECT
        count(*)::integer,
        count(DISTINCT x)::integer
      INTO v_order_size,v_distinct_order_size
      FROM unnest(p_score_card_order) x;

    IF v_order_size<>v_group_size
       OR v_distinct_order_size<>v_group_size
    THEN
        RAISE EXCEPTION
            'El orden debe contener exactamente las % tarjetas del grupo, sin duplicados.',
            v_group_size
            USING ERRCODE='22023';
    END IF;

    SELECT count(*)::integer
      INTO v_group_player_match
      FROM unnest(p_score_card_order) x
     WHERE EXISTS (
        SELECT 1
        FROM jsonb_array_elements(
            COALESCE(v_group->'players','[]'::jsonb)
        ) gp
        WHERE (gp->>'scoreCardId')::uuid=x
     );

    IF v_group_player_match<>v_group_size THEN
        RAISE EXCEPTION
            'El orden contiene tarjetas que no pertenecen exactamente al grupo de empate.'
            USING ERRCODE='22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_tiebreak_resolutions r
        WHERE r.tournament_round_id=p_tournament_round_id
          AND r.tournament_category_id=p_tournament_category_id
          AND r.tipo_resultado=p_tipo_resultado
          AND r.base_rank=p_base_rank
          AND r.tied_total=p_tied_total
          AND r.status='COMPLETED'
    ) THEN
        RAISE EXCEPTION
            'Este grupo ya tiene una resolución manual activa. Debe anularla antes de registrar otra.'
            USING ERRCODE='55000';
    END IF;

    IF v_group_status='MANUAL_PENDING' THEN
        v_manual_method_code := v_group->>'manualMethodCode';
        v_manual_method_name := v_group->>'manualMethodName';

        IF v_manual_method_code IS NULL
           OR v_manual_method_name IS NULL
        THEN
            RAISE EXCEPTION
                'El motor reportó MANUAL_PENDING pero no devolvió el método manual configurado.'
                USING ERRCODE='55000';
        END IF;

        v_resolution_mode := 'CONFIGURED_MANUAL_METHOD';
        v_method_code := v_manual_method_code;
        v_method_name := v_manual_method_name;
    ELSE
        IF char_length(btrim(COALESCE(p_notes,'')))<10 THEN
            RAISE EXCEPTION
                'Cuando el empate persiste después de las reglas, la resolución administrativa requiere un motivo de al menos 10 caracteres.'
                USING ERRCODE='22023';
        END IF;

        v_resolution_mode := 'COMMITTEE_OVERRIDE';
        v_method_code := 'COMMITTEE_OVERRIDE';
        v_method_name := 'Resolución administrativa';
    END IF;

    INSERT INTO public.tournament_tiebreak_resolutions(
        tournament_id,
        tournament_round_id,
        tournament_category_id,
        tipo_resultado,
        base_rank,
        tied_total,
        tie_size,
        source_engine_status,
        resolution_mode,
        method_code,
        method_name,
        notes,
        status,
        resolved_by_admin_user_id,
        resolved_at
    )
    VALUES(
        v_tournament_id,
        p_tournament_round_id,
        p_tournament_category_id,
        p_tipo_resultado,
        p_base_rank,
        p_tied_total,
        v_group_size,
        v_group_status,
        v_resolution_mode,
        v_method_code,
        v_method_name,
        NULLIF(btrim(COALESCE(p_notes,'')),''),
        'COMPLETED',
        v_admin_user_id,
        now()
    )
    RETURNING id INTO v_resolution_id;

    INSERT INTO public.tournament_tiebreak_resolution_players(
        resolution_id,
        score_card_id,
        player_id,
        player_name_snapshot,
        order_in_tiebreak,
        final_rank
    )
    SELECT
        v_resolution_id,
        x.score_card_id,
        NULLIF(gp->>'playerId','')::uuid,
        COALESCE(gp->>'playerName','(SIN NOMBRE)'),
        x.ord::integer,
        p_base_rank+x.ord::integer-1
    FROM unnest(p_score_card_order)
         WITH ORDINALITY AS x(score_card_id,ord)
    JOIN LATERAL (
        SELECT gp
        FROM jsonb_array_elements(
            COALESCE(v_group->'players','[]'::jsonb)
        ) gp
        WHERE (gp->>'scoreCardId')::uuid=x.score_card_id
        LIMIT 1
    ) q(gp) ON true;

    INSERT INTO public.tournament_tiebreak_resolution_events(
        resolution_id,
        tournament_id,
        tournament_round_id,
        event_type,
        payload,
        actor_admin_user_id
    )
    VALUES(
        v_resolution_id,
        v_tournament_id,
        p_tournament_round_id,
        'MANUAL_TIEBREAK_RESOLVED',
        jsonb_build_object(
            'scoringEngine','stableford',
            'tournamentCategoryId',p_tournament_category_id,
            'resultType',p_tipo_resultado,
            'baseRank',p_base_rank,
            'tiedPoints',p_tied_total,
            'tieSize',v_group_size,
            'sourceEngineStatus',v_group_status,
            'resolutionMode',v_resolution_mode,
            'methodCode',v_method_code,
            'methodName',v_method_name,
            'scoreCardOrder',to_jsonb(p_score_card_order),
            'notes',NULLIF(btrim(COALESCE(p_notes,'')),'')
        ),
        v_admin_user_id
    );

    RETURN jsonb_build_object(
        'resolutionId',v_resolution_id,
        'scoringEngine','stableford',
        'status','COMPLETED',
        'sourceEngineStatus',v_group_status,
        'resolutionMode',v_resolution_mode,
        'methodCode',v_method_code,
        'methodName',v_method_name,
        'players',(
            SELECT jsonb_agg(
                jsonb_build_object(
                    'scoreCardId',p.score_card_id,
                    'playerId',p.player_id,
                    'playerName',p.player_name_snapshot,
                    'tiebreakOrder',p.order_in_tiebreak,
                    'finalRank',p.final_rank
                )
                ORDER BY p.order_in_tiebreak
            )
            FROM public.tournament_tiebreak_resolution_players p
            WHERE p.resolution_id=v_resolution_id
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.resolver_desempate_manual_stableford_ronda(
        uuid,uuid,public.tipo_resultado_desempate,integer,integer,uuid[],text
    )
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    public.resolver_desempate_manual_stableford_ronda(
        uuid,uuid,public.tipo_resultado_desempate,integer,integer,uuid[],text
    )
TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 2. Leaderboard Stableford final: integra automático + manual.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_leaderboard_stableford_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_results jsonb;
    v_ties jsonb;
    v_round jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    v_results :=
        public.obtener_resultados_stableford_oficiales_ronda(
            p_tournament_round_id
        );

    v_ties :=
        public.obtener_desempates_stableford_ronda(
            p_tournament_round_id
        );

    v_round := v_results->'round';

    RETURN (
        WITH raw AS (
            SELECT
                (c->>'scoreCardId')::uuid AS score_card_id,
                (c->>'cardNumber')::integer AS card_number,
                c->>'cardFolio' AS card_folio,
                NULLIF(c->>'playerId','')::uuid AS player_id,
                c->>'playerName' AS player_name,

                NULLIF(c->>'tournamentCategoryId','')::uuid
                    AS tournament_category_id,
                c->>'categoryCode' AS category_code,
                c->>'categoryName' AS category_name,
                NULLIF(c->>'categoryDisplayOrder','')::integer
                    AS category_display_order,

                NULLIF(c->>'teeId','')::uuid AS tee_id,
                c->>'teeName' AS tee_name,
                NULLIF(c->>'playingHandicap','')::integer
                    AS playing_handicap,

                c->>'competitionStatus' AS competition_status,
                c->>'outcomeReason' AS outcome_reason,

                COALESCE((c->>'ready')::boolean,false)
                    AS official_ready,
                COALESCE((c->>'grossEnabled')::boolean,false)
                    AS gross_enabled,
                COALESCE((c->>'netEnabled')::boolean,false)
                    AS net_enabled,

                NULLIF(c->>'grossPointsTotal','')::integer
                    AS gross_points_total,
                NULLIF(c->>'netPointsTotal','')::integer
                    AS net_points_total

            FROM jsonb_array_elements(v_results->'cards') c
        ),

        gross_base AS (
            SELECT
                r.score_card_id,
                rank() OVER (
                    PARTITION BY r.tournament_category_id
                    ORDER BY r.gross_points_total DESC
                )::integer AS base_rank,
                count(*) OVER (
                    PARTITION BY
                        r.tournament_category_id,
                        r.gross_points_total
                )::integer AS tie_size
            FROM raw r
            WHERE r.official_ready
              AND r.gross_enabled
        ),

        net_base AS (
            SELECT
                r.score_card_id,
                rank() OVER (
                    PARTITION BY r.tournament_category_id
                    ORDER BY r.net_points_total DESC
                )::integer AS base_rank,
                count(*) OVER (
                    PARTITION BY
                        r.tournament_category_id,
                        r.net_points_total
                )::integer AS tie_size
            FROM raw r
            WHERE r.official_ready
              AND r.net_enabled
        ),

        automatic_players AS (
            SELECT
                NULLIF(g->>'tournamentCategoryId','')::uuid
                    AS tournament_category_id,
                g->>'resultType' AS result_type,
                (g->>'tiedPoints')::integer AS tied_points,
                (g->>'baseRank')::integer AS base_rank,
                g->>'status' AS group_status,

                (p->>'scoreCardId')::uuid AS score_card_id,
                NULLIF(p->>'finalRank','')::integer AS final_rank,
                NULLIF(p->>'tiebreakOrder','')::integer
                    AS tiebreak_order,

                g->>'resolvedByMethodCode'
                    AS method_code,
                g->>'resolvedByMethodName'
                    AS method_name

            FROM jsonb_array_elements(
                COALESCE(v_ties->'tieGroups','[]'::jsonb)
            ) g
            CROSS JOIN LATERAL jsonb_array_elements(
                COALESCE(g->'players','[]'::jsonb)
            ) p
            WHERE g->>'status'='RESOLVED_AUTOMATIC'
        ),

        manual_players AS (
            SELECT
                r.tournament_category_id,
                r.tipo_resultado::text AS result_type,
                r.tied_total AS tied_points,
                r.base_rank,
                'RESOLVED_MANUAL'::text AS group_status,

                p.score_card_id,
                p.final_rank,
                p.order_in_tiebreak AS tiebreak_order,

                r.method_code,
                r.method_name,

                r.id AS resolution_id

            FROM public.tournament_tiebreak_resolutions r
            JOIN public.tournament_tiebreak_resolution_players p
              ON p.resolution_id=r.id
            WHERE r.tournament_round_id=p_tournament_round_id
              AND r.status='COMPLETED'
        ),

        resolved_players AS (
            SELECT
                tournament_category_id,
                result_type,
                tied_points,
                base_rank,
                group_status,
                score_card_id,
                final_rank,
                tiebreak_order,
                method_code,
                method_name,
                NULL::uuid AS resolution_id
            FROM automatic_players

            UNION ALL

            SELECT
                tournament_category_id,
                result_type,
                tied_points,
                base_rank,
                group_status,
                score_card_id,
                final_rank,
                tiebreak_order,
                method_code,
                method_name,
                resolution_id
            FROM manual_players
        ),

        combined AS (
            SELECT
                r.*,

                gb.base_rank AS gross_base_rank,
                gb.tie_size AS gross_tie_size,

                nb.base_rank AS net_base_rank,
                nb.tie_size AS net_tie_size,

                grp.final_rank AS gross_resolved_rank,
                grp.group_status AS gross_tiebreak_status,
                grp.method_code AS gross_tiebreak_method_code,
                grp.method_name AS gross_tiebreak_method_name,
                grp.resolution_id AS gross_resolution_id,

                nrp.final_rank AS net_resolved_rank,
                nrp.group_status AS net_tiebreak_status,
                nrp.method_code AS net_tiebreak_method_code,
                nrp.method_name AS net_tiebreak_method_name,
                nrp.resolution_id AS net_resolution_id,

                CASE
                    WHEN NOT r.gross_enabled
                        THEN NULL
                    WHEN NOT r.official_ready
                        THEN NULL
                    WHEN COALESCE(gb.tie_size,0)<=1
                        THEN gb.base_rank
                    ELSE grp.final_rank
                END AS gross_final_rank,

                CASE
                    WHEN NOT r.net_enabled
                        THEN NULL
                    WHEN NOT r.official_ready
                        THEN NULL
                    WHEN COALESCE(nb.tie_size,0)<=1
                        THEN nb.base_rank
                    ELSE nrp.final_rank
                END AS net_final_rank

            FROM raw r
            LEFT JOIN gross_base gb
              ON gb.score_card_id=r.score_card_id
            LEFT JOIN net_base nb
              ON nb.score_card_id=r.score_card_id

            LEFT JOIN resolved_players grp
              ON grp.score_card_id=r.score_card_id
             AND grp.tournament_category_id
                    IS NOT DISTINCT FROM r.tournament_category_id
             AND grp.result_type='gross'
             AND grp.base_rank=gb.base_rank
             AND grp.tied_points=r.gross_points_total

            LEFT JOIN resolved_players nrp
              ON nrp.score_card_id=r.score_card_id
             AND nrp.tournament_category_id
                    IS NOT DISTINCT FROM r.tournament_category_id
             AND nrp.result_type='neto'
             AND nrp.base_rank=nb.base_rank
             AND nrp.tied_points=r.net_points_total
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

                bool_or(
                    gross_enabled
                    AND official_ready
                    AND COALESCE(gross_tie_size,0)>1
                    AND gross_final_rank IS NULL
                ) AS gross_tiebreak_pending,

                bool_or(
                    net_enabled
                    AND official_ready
                    AND COALESCE(net_tie_size,0)>1
                    AND net_final_rank IS NULL
                ) AS net_tiebreak_pending

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
                    WHERE NOT official_ready
                      AND competition_status
                          NOT IN ('WD','DNF','DQ','DNS','NO_CARD')
                ) AS unresolved_players,

                count(*) FILTER (
                    WHERE gross_enabled
                      AND official_ready
                      AND COALESCE(gross_tie_size,0)>1
                      AND gross_final_rank IS NULL
                )
                +
                count(*) FILTER (
                    WHERE net_enabled
                      AND official_ready
                      AND COALESCE(net_tie_size,0)>1
                      AND net_final_rank IS NULL
                ) AS unresolved_tie_entries
            FROM combined
        )

        SELECT jsonb_build_object(
            'round',v_round,

            'status',(
                SELECT jsonb_build_object(
                    'hasAnyTies',
                        EXISTS (
                            SELECT 1
                            FROM combined
                            WHERE
                                (
                                    gross_enabled
                                    AND COALESCE(gross_tie_size,0)>1
                                )
                                OR
                                (
                                    net_enabled
                                    AND COALESCE(net_tie_size,0)>1
                                )
                        ),

                    'unresolvedPlayers',
                        unresolved_players,

                    'unresolvedTieEntries',
                        unresolved_tie_entries,

                    'leaderboardStatus',
                        CASE
                            WHEN unresolved_players>0
                                THEN 'PROVISIONAL'
                            WHEN unresolved_tie_entries>0
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
                            cs.tournament_category_id,
                        'categoryCode',
                            cs.category_code,
                        'categoryName',
                            cs.category_name,
                        'categoryDisplayOrder',
                            cs.category_display_order,

                        'summary',jsonb_build_object(
                            'totalPlayers',
                                cs.total_players,
                            'officialPlayers',
                                cs.official_players,
                            'grossTiebreakPending',
                                COALESCE(
                                    cs.gross_tiebreak_pending,
                                    false
                                ),
                            'netTiebreakPending',
                                COALESCE(
                                    cs.net_tiebreak_pending,
                                    false
                                )
                        ),

                        'players',COALESCE((
                            SELECT jsonb_agg(
                                jsonb_build_object(
                                    'scoreCardId',
                                        p.score_card_id,
                                    'cardFolio',
                                        p.card_folio,
                                    'playerId',
                                        p.player_id,
                                    'playerName',
                                        p.player_name,

                                    'teeId',
                                        p.tee_id,
                                    'teeName',
                                        p.tee_name,
                                    'playingHandicap',
                                        p.playing_handicap,

                                    'competitionStatus',
                                        p.competition_status,
                                    'outcomeReason',
                                        p.outcome_reason,
                                    'eligibleForRanking',
                                        p.official_ready,

                                    'gross',jsonb_build_object(
                                        'enabled',
                                            p.gross_enabled,
                                        'points',
                                            p.gross_points_total,
                                        'baseRank',
                                            p.gross_base_rank,
                                        'tieSize',
                                            CASE
                                                WHEN p.gross_enabled
                                                THEN p.gross_tie_size
                                                ELSE NULL
                                            END,
                                        'finalRank',
                                            p.gross_final_rank,
                                        'tiebreakStatus',
                                            CASE
                                                WHEN NOT p.gross_enabled
                                                    THEN NULL
                                                WHEN COALESCE(
                                                    p.gross_tie_size,
                                                    0
                                                )<=1
                                                    THEN 'NOT_NEEDED'
                                                WHEN p.gross_final_rank
                                                     IS NOT NULL
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

                                    'net',jsonb_build_object(
                                        'enabled',
                                            p.net_enabled,
                                        'points',
                                            p.net_points_total,
                                        'baseRank',
                                            p.net_base_rank,
                                        'tieSize',
                                            CASE
                                                WHEN p.net_enabled
                                                THEN p.net_tie_size
                                                ELSE NULL
                                            END,
                                        'finalRank',
                                            p.net_final_rank,
                                        'tiebreakStatus',
                                            CASE
                                                WHEN NOT p.net_enabled
                                                    THEN NULL
                                                WHEN COALESCE(
                                                    p.net_tie_size,
                                                    0
                                                )<=1
                                                    THEN 'NOT_NEEDED'
                                                WHEN p.net_final_rank
                                                     IS NOT NULL
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
                                    )
                                )
                                ORDER BY
                                    CASE
                                        WHEN p.official_ready THEN 0
                                        ELSE 1
                                    END,
                                    COALESCE(
                                        p.net_final_rank,
                                        p.gross_final_rank,
                                        p.net_base_rank,
                                        p.gross_base_rank
                                    ) NULLS LAST,
                                    p.card_number,
                                    p.player_name
                            )
                            FROM combined p
                            WHERE p.tournament_category_id
                                  IS NOT DISTINCT FROM
                                  cs.tournament_category_id
                        ),'[]'::jsonb)
                    )
                    ORDER BY
                        cs.category_display_order NULLS LAST,
                        cs.category_name NULLS LAST
                )
                FROM category_summary cs
            ),'[]'::jsonb)
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.obtener_leaderboard_stableford_ronda(uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    public.obtener_leaderboard_stableford_ronda(uuid)
TO authenticated,service_role;

COMMIT;

-- ============================================================================
-- FIN MIGRACIÓN 186 FASE 1K
-- ============================================================================
