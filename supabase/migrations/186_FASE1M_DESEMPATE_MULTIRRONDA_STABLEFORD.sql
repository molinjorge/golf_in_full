-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 186 Fase 1M
-- Desempate automático multirronda Stableford Individual
--
-- REGLA DE DISEÑO
--   - Reutiliza tournament_tiebreak_rules / tiebreak_methods.
--   - Agrega ULTIMA_RONDA como método configurable.
--   - Para ULTIMA_RONDA compara los puntos de la última ronda completa.
--   - Si la secuencia continúa con 9/6/3/18, aplica esos métodos sobre
--     los hoyos de ESA misma última ronda.
--   - Más puntos = mejor; las claves automáticas se normalizan negándolas.
--   - Métodos manuales quedan pendientes para una fase posterior.
--
-- NO HACE
--   - No crea todavía persistencia manual a nivel torneo.
--   - No altera el motor por ronda.
--   - No altera Stroke Play.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Catálogo: método "Última ronda".
-- ----------------------------------------------------------------------------

INSERT INTO public.tiebreak_methods(
    id,
    code,
    name,
    description,
    activo,
    display_order
)
SELECT
    gen_random_uuid(),
    'ULTIMA_RONDA',
    'Última ronda',
    'En competencias multirronda compara primero el total de puntos de la última ronda.',
    true,
    9
WHERE NOT EXISTS (
    SELECT 1
    FROM public.tiebreak_methods
    WHERE code='ULTIMA_RONDA'
);

-- ----------------------------------------------------------------------------
-- 2. Clave de método multirronda Stableford.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.calcular_clave_metodo_desempate_stableford_multirronda(
    p_method_code text,
    p_tipo_resultado public.tipo_resultado_desempate,
    p_last_round jsonb,
    p_last_round_holes jsonb
)
RETURNS integer[]
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
AS $function$
DECLARE
    v_code text := upper(btrim(COALESCE(p_method_code,'')));
    v_points integer;
BEGIN
    IF v_code='ULTIMA_RONDA' THEN
        IF p_last_round IS NULL
           OR jsonb_typeof(p_last_round)<>'object'
        THEN
            RETURN NULL;
        END IF;

        v_points :=
            CASE
                WHEN p_tipo_resultado='gross'::public.tipo_resultado_desempate
                    THEN NULLIF(p_last_round->>'grossPoints','')::integer
                ELSE NULLIF(p_last_round->>'netPoints','')::integer
            END;

        IF v_points IS NULL THEN
            RETURN NULL;
        END IF;

        RETURN ARRAY[-v_points];
    END IF;

    RETURN public.calcular_clave_metodo_desempate_stableford(
        v_code,
        p_tipo_resultado,
        p_last_round_holes
    );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 3. Evaluador de secuencia multirronda.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.evaluar_secuencia_desempate_stableford_multirronda(
    p_rules jsonb,
    p_tipo_resultado public.tipo_resultado_desempate,
    p_last_round jsonb,
    p_last_round_holes jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
AS $function$
DECLARE
    v_rule jsonb;
    v_method_code text;
    v_method_name text;
    v_order integer;
    v_key integer[];
    v_cumulative integer[] := ARRAY[]::integer[];
    v_steps jsonb := '[]'::jsonb;
    v_automatic_steps integer := 0;
    v_stopped boolean := false;
    v_manual_code text := NULL;
    v_manual_name text := NULL;
BEGIN
    FOR v_rule IN
        SELECT value
        FROM jsonb_array_elements(COALESCE(p_rules,'[]'::jsonb))
        ORDER BY (value->>'order')::integer
    LOOP
        v_order := (v_rule->>'order')::integer;
        v_method_code := v_rule->>'methodCode';
        v_method_name := v_rule->>'methodName';

        v_key :=
            public.calcular_clave_metodo_desempate_stableford_multirronda(
                v_method_code,
                p_tipo_resultado,
                p_last_round,
                p_last_round_holes
            );

        IF v_key IS NULL THEN
            v_steps := v_steps || jsonb_build_array(
                jsonb_build_object(
                    'order',v_order,
                    'methodCode',v_method_code,
                    'methodName',v_method_name,
                    'automatic',false,
                    'key',NULL,
                    'cumulativeKey',to_jsonb(v_cumulative)
                )
            );

            v_stopped := true;
            v_manual_code := v_method_code;
            v_manual_name := v_method_name;
            EXIT;
        END IF;

        v_cumulative := v_cumulative || v_key;
        v_automatic_steps := v_automatic_steps + 1;

        v_steps := v_steps || jsonb_build_array(
            jsonb_build_object(
                'order',v_order,
                'methodCode',v_method_code,
                'methodName',v_method_name,
                'automatic',true,
                'key',to_jsonb(v_key),
                'cumulativeKey',to_jsonb(v_cumulative)
            )
        );
    END LOOP;

    RETURN jsonb_build_object(
        'steps',v_steps,
        'finalAutomaticKey',to_jsonb(v_cumulative),
        'automaticSteps',v_automatic_steps,
        'stoppedAtManual',v_stopped,
        'manualMethodCode',v_manual_code,
        'manualMethodName',v_manual_name
    );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. Motor de desempates acumulados.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_desempates_stableford_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_results jsonb;
    v_last_round_id uuid;
    v_last_round_number integer;
    v_last_round_date date;
    v_last_round_results jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_tournament_id IS NULL THEN
        RAISE EXCEPTION 'tournament_id es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar desempates acumulados.'
            USING ERRCODE='42501';
    END IF;

    v_results :=
        public.obtener_resultados_stableford_torneo(
            p_tournament_id
        );

    SELECT
        tr.id,
        tr.numero_ronda,
        tr.fecha
      INTO
        v_last_round_id,
        v_last_round_number,
        v_last_round_date
      FROM public.tournament_rounds tr
      JOIN public.tournament_round_condition_snapshots rcs
        ON rcs.tournament_round_id=tr.id
       AND rcs.tournament_id=tr.tournament_id
     WHERE tr.tournament_id=p_tournament_id
       AND rcs.scoring_engine='stableford'
       AND rcs.participation_type='individual'
     ORDER BY
        tr.numero_ronda DESC,
        tr.fecha DESC,
        tr.id DESC
     LIMIT 1;

    IF v_last_round_id IS NULL THEN
        RAISE EXCEPTION
            'El torneo no tiene una última ronda Stableford Individual congelada.'
            USING ERRCODE='55000';
    END IF;

    v_last_round_results :=
        public.obtener_resultados_stableford_oficiales_ronda(
            v_last_round_id
        );

    RETURN (
        WITH tournament_players AS (
            SELECT
                NULLIF(p->>'tournamentRegistrationId','')::uuid
                    AS tournament_registration_id,
                NULLIF(p->>'playerId','')::uuid
                    AS player_id,
                p->>'playerName'
                    AS player_name,

                NULLIF(p->>'tournamentCategoryId','')::uuid
                    AS tournament_category_id,
                p->>'categoryCode'
                    AS category_code,
                p->>'categoryName'
                    AS category_name,
                NULLIF(p->>'categoryDisplayOrder','')::integer
                    AS category_display_order,

                COALESCE((p->>'ready')::boolean,false)
                    AS accumulation_ready,

                COALESCE((p->>'grossEnabled')::boolean,false)
                    AS gross_enabled,
                COALESCE((p->>'netEnabled')::boolean,false)
                    AS net_enabled,

                NULLIF(p->>'grossPointsTotal','')::integer
                    AS gross_points_total,
                NULLIF(p->>'netPointsTotal','')::integer
                    AS net_points_total,

                p->'rounds'
                    AS rounds

            FROM jsonb_array_elements(
                v_results->'players'
            ) p
            WHERE COALESCE((p->>'ready')::boolean,false)=true
        ),

        last_round_cards AS (
            SELECT
                NULLIF(c->>'tournamentRegistrationId','')::uuid
                    AS tournament_registration_id,

                NULLIF(c->>'grossPointsTotal','')::integer
                    AS gross_points_last_round,
                NULLIF(c->>'netPointsTotal','')::integer
                    AS net_points_last_round,

                c->'holes'
                    AS holes

            FROM jsonb_array_elements(
                v_last_round_results->'cards'
            ) c
            WHERE COALESCE((c->>'ready')::boolean,false)=true
        ),

        joined AS (
            SELECT
                tp.*,
                lrc.gross_points_last_round,
                lrc.net_points_last_round,
                lrc.holes AS last_round_holes,

                jsonb_build_object(
                    'tournamentRoundId',v_last_round_id,
                    'roundNumber',v_last_round_number,
                    'roundDate',v_last_round_date,
                    'grossPoints',lrc.gross_points_last_round,
                    'netPoints',lrc.net_points_last_round
                ) AS last_round

            FROM tournament_players tp
            LEFT JOIN last_round_cards lrc
              ON lrc.tournament_registration_id
                    =tp.tournament_registration_id
        ),

        metric_rows AS (
            SELECT
                j.*,
                'gross'::public.tipo_resultado_desempate
                    AS result_type,
                j.gross_points_total
                    AS metric_total
            FROM joined j
            WHERE j.gross_enabled

            UNION ALL

            SELECT
                j.*,
                'neto'::public.tipo_resultado_desempate
                    AS result_type,
                j.net_points_total
                    AS metric_total
            FROM joined j
            WHERE j.net_enabled
        ),

        ranked AS (
            SELECT
                mr.*,

                rank() OVER (
                    PARTITION BY
                        mr.tournament_category_id,
                        mr.result_type
                    ORDER BY mr.metric_total DESC
                )::integer AS base_rank,

                count(*) OVER (
                    PARTITION BY
                        mr.tournament_category_id,
                        mr.result_type,
                        mr.metric_total
                )::integer AS tie_size

            FROM metric_rows mr
        ),

        tied AS (
            SELECT
                r.*,
                CASE
                    WHEN r.base_rank=1
                        THEN 'primer_lugar'::public.alcance_desempate
                    ELSE 'otros_lugares'::public.alcance_desempate
                END AS scope
            FROM ranked r
            WHERE r.tie_size>1
        ),

        tie_groups AS (
            SELECT DISTINCT
                tournament_category_id,
                category_code,
                category_name,
                category_display_order,
                result_type,
                metric_total,
                base_rank,
                tie_size,
                scope
            FROM tied
        ),

        configured_groups AS (
            SELECT
                g.*,

                CASE
                    WHEN EXISTS (
                        SELECT 1
                        FROM public.tournament_tiebreak_rules r
                        WHERE r.tournament_id=p_tournament_id
                          AND r.activo=true
                          AND r.tipo_resultado=g.result_type
                          AND r.tournament_category_id=g.tournament_category_id
                          AND r.alcance=g.scope
                    ) THEN 'CATEGORY_SCOPE'

                    WHEN EXISTS (
                        SELECT 1
                        FROM public.tournament_tiebreak_rules r
                        WHERE r.tournament_id=p_tournament_id
                          AND r.activo=true
                          AND r.tipo_resultado=g.result_type
                          AND r.tournament_category_id=g.tournament_category_id
                          AND r.alcance='todos'::public.alcance_desempate
                    ) THEN 'CATEGORY_ALL'

                    WHEN EXISTS (
                        SELECT 1
                        FROM public.tournament_tiebreak_rules r
                        WHERE r.tournament_id=p_tournament_id
                          AND r.activo=true
                          AND r.tipo_resultado=g.result_type
                          AND r.tournament_category_id IS NULL
                          AND r.alcance=g.scope
                    ) THEN 'TOURNAMENT_SCOPE'

                    WHEN EXISTS (
                        SELECT 1
                        FROM public.tournament_tiebreak_rules r
                        WHERE r.tournament_id=p_tournament_id
                          AND r.activo=true
                          AND r.tipo_resultado=g.result_type
                          AND r.tournament_category_id IS NULL
                          AND r.alcance='todos'::public.alcance_desempate
                    ) THEN 'TOURNAMENT_ALL'

                    ELSE 'NONE'
                END AS rule_source

            FROM tie_groups g
        ),

        group_rules AS (
            SELECT
                cg.*,

                COALESCE((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'ruleId',r.id,
                            'order',r.orden,
                            'methodId',r.tiebreak_method_id,
                            'methodCode',m.code,
                            'methodName',m.name
                        )
                        ORDER BY r.orden
                    )
                    FROM public.tournament_tiebreak_rules r
                    JOIN public.tiebreak_methods m
                      ON m.id=r.tiebreak_method_id
                    WHERE r.tournament_id=p_tournament_id
                      AND r.activo=true
                      AND r.tipo_resultado=cg.result_type
                      AND (
                          (
                              cg.rule_source='CATEGORY_SCOPE'
                              AND r.tournament_category_id=cg.tournament_category_id
                              AND r.alcance=cg.scope
                          )
                          OR
                          (
                              cg.rule_source='CATEGORY_ALL'
                              AND r.tournament_category_id=cg.tournament_category_id
                              AND r.alcance='todos'::public.alcance_desempate
                          )
                          OR
                          (
                              cg.rule_source='TOURNAMENT_SCOPE'
                              AND r.tournament_category_id IS NULL
                              AND r.alcance=cg.scope
                          )
                          OR
                          (
                              cg.rule_source='TOURNAMENT_ALL'
                              AND r.tournament_category_id IS NULL
                              AND r.alcance='todos'::public.alcance_desempate
                          )
                      )
                ),'[]'::jsonb) AS rules

            FROM configured_groups cg
        ),

        player_eval AS (
            SELECT
                t.*,
                gr.rule_source,
                gr.rules,

                public.evaluar_secuencia_desempate_stableford_multirronda(
                    gr.rules,
                    t.result_type,
                    t.last_round,
                    t.last_round_holes
                ) AS evaluation

            FROM tied t
            JOIN group_rules gr
              ON gr.tournament_category_id=t.tournament_category_id
             AND gr.result_type=t.result_type
             AND gr.metric_total=t.metric_total
             AND gr.base_rank=t.base_rank
        ),

        automatic_steps AS (
            SELECT
                pe.tournament_category_id,
                pe.result_type,
                pe.metric_total,
                pe.base_rank,
                pe.tie_size,
                pe.tournament_registration_id,

                (s->>'order')::integer
                    AS step_order,
                s->>'methodCode'
                    AS method_code,
                s->>'methodName'
                    AS method_name,

                s->'cumulativeKey'
                    AS cumulative_key_json,

                ARRAY(
                    SELECT value::integer
                    FROM jsonb_array_elements_text(
                        s->'cumulativeKey'
                    )
                ) AS cumulative_key

            FROM player_eval pe
            CROSS JOIN LATERAL jsonb_array_elements(
                pe.evaluation->'steps'
            ) s

            WHERE COALESCE(
                (s->>'automatic')::boolean,
                false
            )=true
        ),

        step_uniqueness AS (
            SELECT
                tournament_category_id,
                result_type,
                metric_total,
                base_rank,
                step_order,

                min(method_code)
                    AS method_code,
                min(method_name)
                    AS method_name,

                count(
                    DISTINCT cumulative_key_json::text
                ) AS unique_keys,

                max(tie_size)
                    AS group_size

            FROM automatic_steps

            GROUP BY
                tournament_category_id,
                result_type,
                metric_total,
                base_rank,
                step_order
        ),

        resolved_step AS (
            SELECT
                tournament_category_id,
                result_type,
                metric_total,
                base_rank,

                min(step_order) FILTER (
                    WHERE unique_keys=group_size
                ) AS resolved_at_step

            FROM step_uniqueness

            GROUP BY
                tournament_category_id,
                result_type,
                metric_total,
                base_rank
        ),

        group_state AS (
            SELECT
                gr.*,
                rs.resolved_at_step,

                COALESCE(
                    bool_or(
                        COALESCE(
                            (pe.evaluation->>'stoppedAtManual')::boolean,
                            false
                        )
                    ),
                    false
                ) AS stopped_at_manual,

                max(
                    pe.evaluation->>'manualMethodCode'
                ) FILTER (
                    WHERE COALESCE(
                        (pe.evaluation->>'stoppedAtManual')::boolean,
                        false
                    )
                ) AS manual_method_code,

                max(
                    pe.evaluation->>'manualMethodName'
                ) FILTER (
                    WHERE COALESCE(
                        (pe.evaluation->>'stoppedAtManual')::boolean,
                        false
                    )
                ) AS manual_method_name

            FROM group_rules gr

            LEFT JOIN resolved_step rs
              ON rs.tournament_category_id=gr.tournament_category_id
             AND rs.result_type=gr.result_type
             AND rs.metric_total=gr.metric_total
             AND rs.base_rank=gr.base_rank

            LEFT JOIN player_eval pe
              ON pe.tournament_category_id=gr.tournament_category_id
             AND pe.result_type=gr.result_type
             AND pe.metric_total=gr.metric_total
             AND pe.base_rank=gr.base_rank

            GROUP BY
                gr.tournament_category_id,
                gr.category_code,
                gr.category_name,
                gr.category_display_order,
                gr.result_type,
                gr.metric_total,
                gr.base_rank,
                gr.tie_size,
                gr.scope,
                gr.rule_source,
                gr.rules,
                rs.resolved_at_step
        ),

        group_final AS (
            SELECT
                gs.*,

                su.method_code
                    AS resolved_method_code,
                su.method_name
                    AS resolved_method_name,

                CASE
                    WHEN jsonb_array_length(gs.rules)=0
                        THEN 'CONFIG_MISSING'
                    WHEN gs.resolved_at_step IS NOT NULL
                        THEN 'RESOLVED_AUTOMATIC'
                    WHEN gs.stopped_at_manual
                        THEN 'MANUAL_PENDING'
                    ELSE 'TIE_PERSISTS_AFTER_RULES'
                END AS tiebreak_status

            FROM group_state gs

            LEFT JOIN step_uniqueness su
              ON su.tournament_category_id=gs.tournament_category_id
             AND su.result_type=gs.result_type
             AND su.metric_total=gs.metric_total
             AND su.base_rank=gs.base_rank
             AND su.step_order=gs.resolved_at_step
        ),

        player_resolution AS (
            SELECT
                pe.*,
                gf.tiebreak_status,
                gf.resolved_at_step,

                step_at_resolution.cumulative_key
                    AS resolution_key,

                CASE
                    WHEN gf.tiebreak_status='RESOLVED_AUTOMATIC'
                    THEN row_number() OVER (
                        PARTITION BY
                            pe.tournament_category_id,
                            pe.result_type,
                            pe.metric_total,
                            pe.base_rank
                        ORDER BY
                            step_at_resolution.cumulative_key ASC,
                            pe.player_name ASC,
                            pe.tournament_registration_id ASC
                    )::integer
                    ELSE NULL
                END AS tiebreak_order

            FROM player_eval pe

            JOIN group_final gf
              ON gf.tournament_category_id=pe.tournament_category_id
             AND gf.result_type=pe.result_type
             AND gf.metric_total=pe.metric_total
             AND gf.base_rank=pe.base_rank

            LEFT JOIN LATERAL (
                SELECT
                    ARRAY(
                        SELECT value::integer
                        FROM jsonb_array_elements_text(
                            s->'cumulativeKey'
                        )
                    ) AS cumulative_key
                FROM jsonb_array_elements(
                    pe.evaluation->'steps'
                ) s
                WHERE (s->>'order')::integer=gf.resolved_at_step
                  AND COALESCE(
                      (s->>'automatic')::boolean,
                      false
                  )=true
                LIMIT 1
            ) step_at_resolution
              ON true
        ),

        group_counts AS (
            SELECT
                count(*) AS tie_groups,

                count(*) FILTER (
                    WHERE tiebreak_status='RESOLVED_AUTOMATIC'
                ) AS automatic_resolved,

                count(*) FILTER (
                    WHERE tiebreak_status='MANUAL_PENDING'
                ) AS manual_pending,

                count(*) FILTER (
                    WHERE tiebreak_status='CONFIG_MISSING'
                ) AS config_missing,

                count(*) FILTER (
                    WHERE tiebreak_status='TIE_PERSISTS_AFTER_RULES'
                ) AS persists_after_rules

            FROM group_final
        )

        SELECT jsonb_build_object(
            'tournamentId',
                p_tournament_id,

            'lastRound',
                jsonb_build_object(
                    'tournamentRoundId',
                        v_last_round_id,
                    'roundNumber',
                        v_last_round_number,
                    'roundDate',
                        v_last_round_date
                ),

            'summary',(
                SELECT jsonb_build_object(
                    'tieGroups',
                        tie_groups,
                    'automaticResolved',
                        automatic_resolved,
                    'manualPending',
                        manual_pending,
                    'configMissing',
                        config_missing,
                    'persistsAfterRules',
                        persists_after_rules,

                    'engineStatus',
                        CASE
                            WHEN tie_groups=0
                                THEN 'NO_TIES'
                            WHEN config_missing>0
                                THEN 'CONFIGURATION_REQUIRED'
                            WHEN manual_pending>0
                              OR persists_after_rules>0
                                THEN 'ACTION_REQUIRED'
                            ELSE 'RESOLVED'
                        END
                )
                FROM group_counts
            ),

            'tieGroups',COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'tournamentCategoryId',
                            gf.tournament_category_id,
                        'categoryCode',
                            gf.category_code,
                        'categoryName',
                            gf.category_name,

                        'resultType',
                            gf.result_type,
                        'tiedPoints',
                            gf.metric_total,
                        'baseRank',
                            gf.base_rank,
                        'tieSize',
                            gf.tie_size,
                        'scope',
                            gf.scope,

                        'ruleSource',
                            gf.rule_source,
                        'rules',
                            gf.rules,

                        'status',
                            gf.tiebreak_status,

                        'resolvedAtStep',
                            gf.resolved_at_step,
                        'resolvedByMethodCode',
                            gf.resolved_method_code,
                        'resolvedByMethodName',
                            gf.resolved_method_name,

                        'manualMethodCode',
                            gf.manual_method_code,
                        'manualMethodName',
                            gf.manual_method_name,

                        'players',COALESCE((
                            SELECT jsonb_agg(
                                jsonb_build_object(
                                    'tournamentRegistrationId',
                                        pr.tournament_registration_id,
                                    'playerId',
                                        pr.player_id,
                                    'playerName',
                                        pr.player_name,

                                    'baseRank',
                                        pr.base_rank,
                                    'tiebreakOrder',
                                        pr.tiebreak_order,
                                    'finalRank',
                                        CASE
                                            WHEN pr.tiebreak_order
                                                 IS NOT NULL
                                            THEN
                                                pr.base_rank
                                                +pr.tiebreak_order
                                                -1
                                            ELSE NULL
                                        END,

                                    'comparisonKey',
                                        to_jsonb(
                                            pr.resolution_key
                                        ),

                                    'lastRound',
                                        pr.last_round,

                                    'evidence',
                                        pr.evaluation->'steps'
                                )
                                ORDER BY
                                    pr.tiebreak_order NULLS LAST,
                                    pr.player_name,
                                    pr.tournament_registration_id
                            )
                            FROM player_resolution pr
                            WHERE
                                pr.tournament_category_id
                                    =gf.tournament_category_id
                                AND pr.result_type
                                    =gf.result_type
                                AND pr.metric_total
                                    =gf.metric_total
                                AND pr.base_rank
                                    =gf.base_rank
                        ),'[]'::jsonb)
                    )
                    ORDER BY
                        gf.category_display_order NULLS LAST,
                        gf.category_name NULLS LAST,
                        gf.result_type,
                        gf.base_rank,
                        gf.metric_total DESC
                )
                FROM group_final gf
            ),'[]'::jsonb)
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.obtener_desempates_stableford_torneo(uuid)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    public.obtener_desempates_stableford_torneo(uuid)
TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 5. Leaderboard acumulado aplica desempates automáticos.
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

        gross_base AS (
            SELECT
                r.tournament_registration_id,

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
            WHERE r.accumulation_ready
              AND r.gross_enabled
        ),

        net_base AS (
            SELECT
                r.tournament_registration_id,

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
            WHERE r.accumulation_ready
              AND r.net_enabled
        ),

        automatic_players AS (
            SELECT
                NULLIF(
                    g->>'tournamentCategoryId',
                    ''
                )::uuid AS tournament_category_id,

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
                )::uuid AS tournament_registration_id,

                NULLIF(
                    p->>'finalRank',
                    ''
                )::integer AS final_rank,

                NULLIF(
                    p->>'tiebreakOrder',
                    ''
                )::integer AS tiebreak_order,

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

                gap.final_rank
                    AS gross_resolved_rank,
                gap.group_status
                    AS gross_tiebreak_status,
                gap.method_code
                    AS gross_tiebreak_method_code,
                gap.method_name
                    AS gross_tiebreak_method_name,

                nap.final_rank
                    AS net_resolved_rank,
                nap.group_status
                    AS net_tiebreak_status,
                nap.method_code
                    AS net_tiebreak_method_code,
                nap.method_name
                    AS net_tiebreak_method_name,

                CASE
                    WHEN NOT r.gross_enabled
                        THEN NULL
                    WHEN NOT r.accumulation_ready
                        THEN NULL
                    WHEN COALESCE(gb.tie_size,0)<=1
                        THEN gb.base_rank
                    ELSE gap.final_rank
                END AS gross_final_rank,

                CASE
                    WHEN NOT r.net_enabled
                        THEN NULL
                    WHEN NOT r.accumulation_ready
                        THEN NULL
                    WHEN COALESCE(nb.tie_size,0)<=1
                        THEN nb.base_rank
                    ELSE nap.final_rank
                END AS net_final_rank

            FROM raw r

            LEFT JOIN gross_base gb
              ON gb.tournament_registration_id
                    =r.tournament_registration_id

            LEFT JOIN net_base nb
              ON nb.tournament_registration_id
                    =r.tournament_registration_id

            LEFT JOIN automatic_players gap
              ON gap.tournament_registration_id
                    =r.tournament_registration_id
             AND gap.tournament_category_id
                    IS NOT DISTINCT FROM
                    r.tournament_category_id
             AND gap.result_type='gross'
             AND gap.base_rank=gb.base_rank
             AND gap.tied_points=r.gross_points_total

            LEFT JOIN automatic_players nap
              ON nap.tournament_registration_id
                    =r.tournament_registration_id
             AND nap.tournament_category_id
                    IS NOT DISTINCT FROM
                    r.tournament_category_id
             AND nap.result_type='neto'
             AND nap.base_rank=nb.base_rank
             AND nap.tied_points=r.net_points_total
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

                bool_or(
                    gross_enabled
                    AND accumulation_ready
                    AND COALESCE(
                        gross_tie_size,
                        0
                    )>1
                    AND gross_final_rank IS NULL
                ) AS gross_tiebreak_pending,

                bool_or(
                    net_enabled
                    AND accumulation_ready
                    AND COALESCE(
                        net_tie_size,
                        0
                    )>1
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
                    WHERE NOT accumulation_ready
                ) AS pending_players,

                count(*) FILTER (
                    WHERE gross_enabled
                      AND accumulation_ready
                      AND COALESCE(
                          gross_tie_size,
                          0
                      )>1
                      AND gross_final_rank IS NULL
                )
                +
                count(*) FILTER (
                    WHERE net_enabled
                      AND accumulation_ready
                      AND COALESCE(
                          net_tie_size,
                          0
                      )>1
                      AND net_final_rank IS NULL
                ) AS unresolved_tie_entries

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
                                                p.gross_tiebreak_method_name
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
                                                p.net_tiebreak_method_name
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
-- FIN MIGRACIÓN 186 FASE 1M
-- ============================================================================
