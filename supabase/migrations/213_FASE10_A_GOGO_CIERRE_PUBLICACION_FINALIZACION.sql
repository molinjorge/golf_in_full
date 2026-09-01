-- ============================================================================
-- MIGRACIÓN 213 FASE 10
-- A-Go-Go — cierre competitivo, publicación y finalización
-- Proyecto: Tee Central / GOLF IN FULL
--
-- Alcance:
-- 1) Extiende validar_cierre_resultados_ronda() para equipo/team_stroke.
-- 2) Extiende obtener_estado_cierre_competitivo_ronda() para A-Go-Go.
-- 3) Reutiliza SIN CAMBIOS las tablas/RPCs comunes de:
--      - cierre por categoría,
--      - cierre de ronda,
--      - publicación por categoría,
--      - lectura de resultados publicados,
--      - previsualización/finalización de torneo.
-- 4) Preserva Stroke Play y Stableford mediante wrappers sobre las versiones previas.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Preservar validación de cierre existente
-- ----------------------------------------------------------------------------

ALTER FUNCTION public.validar_cierre_resultados_ronda(uuid)
RENAME TO _validar_cierre_resultados_ronda_pre213;


CREATE OR REPLACE FUNCTION public.validar_cierre_resultados_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_tournament_id uuid;
    v_scoring_engine text;
    v_participation_type text;
    v_massive jsonb;
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
        s.scoring_engine,
        s.participation_type
      INTO
        v_tournament_id,
        v_scoring_engine,
        v_participation_type
      FROM public.tournament_rounds tr
      LEFT JOIN LATERAL (
          SELECT
              rcs.scoring_engine,
              rcs.participation_type
          FROM public.tournament_round_condition_snapshots rcs
          WHERE rcs.tournament_round_id=tr.id
          ORDER BY rcs.created_at DESC,rcs.id DESC
          LIMIT 1
      ) s ON true
     WHERE tr.id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    -- Todo lo previamente soportado conserva exactamente su implementación.
    IF NOT (
        v_scoring_engine='team_stroke'
        AND v_participation_type='equipo'
    ) THEN
        RETURN public._validar_cierre_resultados_ronda_pre213(
            p_tournament_round_id
        );
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para validar esta ronda.'
            USING ERRCODE='42501';
    END IF;

    v_massive :=
        public.obtener_resultados_a_gogo_oficiales_ronda(
            p_tournament_round_id
        );

    RETURN (
        WITH cards AS (
            SELECT
                (t->>'scoreCardId')::uuid AS score_card_id,
                t->>'teamId' AS team_id,
                t->>'teamName' AS team_name,
                t->>'resultStatus' AS pipeline_status,
                COALESCE(
                    (t->>'ready')::boolean,
                    false
                ) AS official_ready
            FROM jsonb_array_elements(
                COALESCE(v_massive->'teams','[]'::jsonb)
            ) t
        ),

        resolved AS (
            SELECT
                c.*,
                o.outcome_code,
                o.reason AS outcome_reason,

                COALESCE(
                    c.official_ready
                    OR COALESCE(
                        o.outcome_code IN (
                            'WD','DNF','DQ','DNS','NO_CARD'
                        ),
                        false
                    ),
                    false
                ) AS resolved_for_round

            FROM cards c

            LEFT JOIN public.tournament_scorecard_round_outcomes o
              ON o.score_card_id=c.score_card_id
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
                    WHERE resolved_for_round
                ) AS resolved_cards,

                count(*) FILTER (
                    WHERE NOT resolved_for_round
                ) AS unresolved_cards

            FROM resolved
        )

        SELECT jsonb_build_object(
            'tournamentId',
                v_tournament_id,

            'tournamentRoundId',
                p_tournament_round_id,

            'scoringEngine',
                'team_stroke',

            'participationType',
                'equipo',

            'competitiveUnit',
                'TEAM',

            'readyToCloseResults',
                (
                    SELECT
                        total_cards>0
                        AND unresolved_cards=0
                    FROM counts
                ),

            'summary',
                (
                    SELECT jsonb_build_object(
                        'totalCards',total_cards,
                        'officialCards',official_cards,
                        'WD',wd,
                        'DNF',dnf,
                        'DQ',dq,
                        'DNS',dns,
                        'NO_CARD',no_card,
                        'resolvedCards',resolved_cards,
                        'unresolvedCards',unresolved_cards,

                        'totalTeams',total_cards,
                        'officialTeams',official_cards,
                        'resolvedTeams',resolved_cards,
                        'unresolvedTeams',unresolved_cards
                    )
                    FROM counts
                ),

            'unresolved',
                COALESCE((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'competitiveUnit','TEAM',
                            'scoreCardId',score_card_id,
                            'teamId',team_id,
                            'teamName',team_name,
                            'pipelineStatus',pipeline_status
                        )
                        ORDER BY team_name,score_card_id
                    )
                    FROM resolved
                    WHERE NOT resolved_for_round
                ),'[]'::jsonb)
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.validar_cierre_resultados_ronda(uuid)
FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.validar_cierre_resultados_ronda(uuid)
TO authenticated,service_role;


-- ----------------------------------------------------------------------------
-- 2. Preservar estado competitivo existente
-- ----------------------------------------------------------------------------

ALTER FUNCTION public.obtener_estado_cierre_competitivo_ronda(uuid)
RENAME TO _obtener_estado_cierre_competitivo_ronda_pre213;


CREATE OR REPLACE FUNCTION public.obtener_estado_cierre_competitivo_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_tournament_id uuid;
    v_round_number integer;
    v_round_date date;
    v_scoring_engine text;
    v_participation_type text;

    v_results_close jsonb;
    v_tiebreak_engine jsonb;
    v_manual_resolutions jsonb;

    v_cards_ready boolean;
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
        tr.numero_ronda,
        tr.fecha,
        s.scoring_engine,
        s.participation_type
      INTO
        v_tournament_id,
        v_round_number,
        v_round_date,
        v_scoring_engine,
        v_participation_type
      FROM public.tournament_rounds tr
      LEFT JOIN LATERAL (
          SELECT
              rcs.scoring_engine,
              rcs.participation_type
          FROM public.tournament_round_condition_snapshots rcs
          WHERE rcs.tournament_round_id=tr.id
          ORDER BY rcs.created_at DESC,rcs.id DESC
          LIMIT 1
      ) s ON true
     WHERE tr.id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    -- Stroke/Stableford conservan exactamente la lógica previa.
    IF NOT (
        v_scoring_engine='team_stroke'
        AND v_participation_type='equipo'
    ) THEN
        RETURN public._obtener_estado_cierre_competitivo_ronda_pre213(
            p_tournament_round_id
        );
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar el cierre competitivo.'
            USING ERRCODE='42501';
    END IF;

    v_results_close :=
        public.validar_cierre_resultados_ronda(
            p_tournament_round_id
        );

    v_tiebreak_engine :=
        public.obtener_desempates_a_gogo_ronda(
            p_tournament_round_id
        );

    v_manual_resolutions :=
        public.obtener_resoluciones_desempate_ronda(
            p_tournament_round_id
        );

    v_cards_ready :=
        COALESCE(
            (v_results_close->>'readyToCloseResults')::boolean,
            false
        );

    RETURN (
        WITH tie_groups AS (
            SELECT
                g,

                NULLIF(
                    g->>'tournamentCategoryId',
                    ''
                )::uuid AS tournament_category_id,

                g->>'resultType' AS result_type,

                NULLIF(
                    g->>'baseRank',
                    ''
                )::integer AS base_rank,

                NULLIF(
                    g->>'tiedTotal',
                    ''
                )::integer AS tied_total,

                NULLIF(
                    g->>'tieSize',
                    ''
                )::integer AS tie_size,

                g->>'status' AS engine_status,

                g->>'categoryName' AS category_name

            FROM jsonb_array_elements(
                COALESCE(
                    v_tiebreak_engine->'tieGroups',
                    '[]'::jsonb
                )
            ) g
        ),

        manual_active AS (
            SELECT
                NULLIF(
                    r->>'resolutionId',
                    ''
                )::uuid AS resolution_id,

                NULLIF(
                    r->>'tournamentCategoryId',
                    ''
                )::uuid AS tournament_category_id,

                r->>'resultType' AS result_type,

                NULLIF(
                    r->>'baseRank',
                    ''
                )::integer AS base_rank,

                NULLIF(
                    r->>'tiedTotal',
                    ''
                )::integer AS tied_total,

                r->>'methodCode' AS method_code,
                r->>'methodName' AS method_name,
                r->>'resolutionMode' AS resolution_mode,
                r->>'resolvedAt' AS resolved_at

            FROM jsonb_array_elements(
                COALESCE(
                    v_manual_resolutions->'resolutions',
                    '[]'::jsonb
                )
            ) r

            WHERE r->>'status'='COMPLETED'
        ),

        effective_groups AS (
            SELECT
                tg.*,
                ma.resolution_id,
                ma.method_code AS manual_method_code,
                ma.method_name AS manual_method_name,
                ma.resolution_mode,
                ma.resolved_at,

                CASE
                    WHEN tg.engine_status='RESOLVED_AUTOMATIC'
                        THEN true
                    WHEN ma.resolution_id IS NOT NULL
                        THEN true
                    ELSE false
                END AS resolved_effectively,

                CASE
                    WHEN tg.engine_status='RESOLVED_AUTOMATIC'
                        THEN 'AUTOMATIC'
                    WHEN ma.resolution_id IS NOT NULL
                        THEN 'MANUAL'
                    ELSE 'PENDING'
                END AS resolution_source

            FROM tie_groups tg

            LEFT JOIN manual_active ma
              ON ma.tournament_category_id=tg.tournament_category_id
             AND ma.result_type=tg.result_type
             AND ma.base_rank=tg.base_rank
             AND ma.tied_total=tg.tied_total
        ),

        tie_summary AS (
            SELECT
                count(*)::integer AS tie_groups,

                count(*) FILTER (
                    WHERE resolved_effectively
                )::integer AS resolved_groups,

                count(*) FILTER (
                    WHERE engine_status='RESOLVED_AUTOMATIC'
                )::integer AS automatic_resolved,

                count(*) FILTER (
                    WHERE resolution_source='MANUAL'
                )::integer AS manual_resolved,

                count(*) FILTER (
                    WHERE NOT resolved_effectively
                )::integer AS pending_groups,

                count(*) FILTER (
                    WHERE NOT resolved_effectively
                      AND engine_status='CONFIG_MISSING'
                )::integer AS config_missing,

                count(*) FILTER (
                    WHERE NOT resolved_effectively
                      AND engine_status='MANUAL_PENDING'
                )::integer AS manual_pending,

                count(*) FILTER (
                    WHERE NOT resolved_effectively
                      AND engine_status='TIE_PERSISTS_AFTER_RULES'
                )::integer AS persists_after_rules

            FROM effective_groups
        ),

        final_state AS (
            SELECT
                ts.*,

                (ts.pending_groups=0)
                    AS tiebreaks_ready,

                (
                    v_cards_ready
                    AND ts.pending_groups=0
                ) AS competitively_closed,

                CASE
                    WHEN NOT v_cards_ready
                        THEN 'PROVISIONAL'
                    WHEN ts.pending_groups>0
                        THEN 'TIEBREAKS_PENDING'
                    ELSE 'FINAL'
                END AS competitive_status

            FROM tie_summary ts
        )

        SELECT jsonb_build_object(
            'round',
                jsonb_build_object(
                    'tournamentId',
                        v_tournament_id,

                    'tournamentRoundId',
                        p_tournament_round_id,

                    'roundNumber',
                        v_round_number,

                    'roundDate',
                        v_round_date,

                    'scoringEngine',
                        'team_stroke',

                    'participationType',
                        'equipo',

                    'competitiveUnit',
                        'TEAM'
                ),

            'status',
                (
                    SELECT jsonb_build_object(
                        'cardsReady',
                            v_cards_ready,

                        'tiebreaksReady',
                            tiebreaks_ready,

                        'competitivelyClosed',
                            competitively_closed,

                        'competitiveStatus',
                            competitive_status
                    )
                    FROM final_state
                ),

            'resultsClosure',
                v_results_close,

            'tiebreakSummary',
                (
                    SELECT jsonb_build_object(
                        'tieGroups',
                            tie_groups,

                        'resolvedGroups',
                            resolved_groups,

                        'automaticResolved',
                            automatic_resolved,

                        'manualResolved',
                            manual_resolved,

                        'pendingGroups',
                            pending_groups,

                        'configMissing',
                            config_missing,

                        'manualPending',
                            manual_pending,

                        'persistsAfterRules',
                            persists_after_rules
                    )
                    FROM final_state
                ),

            'pendingTiebreaks',
                COALESCE((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'competitiveUnit',
                                'TEAM',

                            'tournamentCategoryId',
                                eg.tournament_category_id,

                            'categoryName',
                                eg.category_name,

                            'resultType',
                                eg.result_type,

                            'baseRank',
                                eg.base_rank,

                            'tiedTotal',
                                eg.tied_total,

                            'tieSize',
                                eg.tie_size,

                            'engineStatus',
                                eg.engine_status
                        )
                        ORDER BY
                            eg.category_name,
                            eg.result_type,
                            eg.base_rank
                    )
                    FROM effective_groups eg
                    WHERE NOT eg.resolved_effectively
                ),'[]'::jsonb),

            'resolvedTiebreaks',
                COALESCE((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'competitiveUnit',
                                'TEAM',

                            'tournamentCategoryId',
                                eg.tournament_category_id,

                            'categoryName',
                                eg.category_name,

                            'resultType',
                                eg.result_type,

                            'baseRank',
                                eg.base_rank,

                            'tiedTotal',
                                eg.tied_total,

                            'tieSize',
                                eg.tie_size,

                            'resolutionSource',
                                eg.resolution_source,

                            'engineStatus',
                                eg.engine_status,

                            'manualResolutionId',
                                eg.resolution_id,

                            'manualResolutionMode',
                                eg.resolution_mode,

                            'manualMethodCode',
                                eg.manual_method_code,

                            'manualMethodName',
                                eg.manual_method_name,

                            'manualResolvedAt',
                                eg.resolved_at
                        )
                        ORDER BY
                            eg.category_name,
                            eg.result_type,
                            eg.base_rank
                    )
                    FROM effective_groups eg
                    WHERE eg.resolved_effectively
                ),'[]'::jsonb)
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_estado_cierre_competitivo_ronda(uuid)
FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.obtener_estado_cierre_competitivo_ronda(uuid)
TO authenticated,service_role;


-- ----------------------------------------------------------------------------
-- 3. No se duplican cierres/publicaciones/finalización.
--    Las funciones comunes existentes ya consumen:
--       obtener_estado_cierre_competitivo_ronda()
--       obtener_estado_competitivo_categorias_ronda()
--       obtener_leaderboard_operativo_ronda()
--
--    Por lo tanto, después de los dos dispatchers anteriores, A-Go-Go entra
--    naturalmente al mismo pipeline:
--
--    cerrar_categoria_competitiva_ronda()
--      -> cerrar_ronda_competitiva()
--      -> publicar_resultados_categoria_ronda()
--      -> obtener_resultados_publicados_categoria_ronda()
--      -> previsualizar_finalizacion_torneo()
--      -> finalizar_torneo()
--
--    previsualizar_finalizacion_torneo() clasifica team_stroke como
--    non-Stableford, donde el acumulado global no es obligatorio y el gate
--    histórico sigue siendo: todas las rondas activas deben estar FINAL.
-- ----------------------------------------------------------------------------

COMMIT;
