-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 186 Fase 1J
-- Motor automático de desempates Stableford Individual
--
-- PRINCIPIOS
--   - Reutiliza tournament_tiebreak_rules y tiebreak_methods.
--   - NO modifica el motor de desempate Stroke Play.
--   - Stableford compara PUNTOS; más puntos = mejor.
--   - Para countback usa hoyos del campo:
--       últimos 9 = 10..18
--       últimos 6 = 13..18
--       últimos 3 = 16..18
--       último hoyo = 18
--     Esto evita que un Shotgun use "los últimos hoyos jugados" por cada jugador.
--   - HOYO_POR_HOYO_HANDICAP se conserva como método local configurable:
--     compara puntos hoyo por hoyo ordenados por Stroke Index.
--   - MUERTE_SUBITA y SORTEO continúan siendo métodos manuales.
--
-- NOTA DE IMPLEMENTACIÓN
--   Las claves automáticas se devuelven negadas para que el orden lexicográfico
--   ASC existente represente correctamente "más puntos = mejor".
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Clave automática Stableford por método.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.calcular_clave_metodo_desempate_stableford(
    p_method_code text,
    p_tipo_resultado public.tipo_resultado_desempate,
    p_holes jsonb
)
RETURNS integer[]
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
AS $function$
DECLARE
    v_code text := upper(btrim(COALESCE(p_method_code,'')));
    v_key integer[];
    v_start_hole integer;
    v_end_hole integer;
    v_expected_count integer;
    v_actual_count integer;
BEGIN
    IF p_holes IS NULL
       OR jsonb_typeof(p_holes)<>'array'
       OR jsonb_array_length(p_holes)=0
    THEN
        RETURN NULL;
    END IF;

    -- Countback estándar de tarjeta sobre hoyos del campo.
    IF v_code IN (
        'TARJETA_ULTIMOS_9',
        'TARJETA_ULTIMOS_6',
        'TARJETA_ULTIMOS_3',
        'TARJETA_ULTIMO_HOYO'
    ) THEN
        CASE v_code
            WHEN 'TARJETA_ULTIMOS_9' THEN
                v_start_hole := 10; v_end_hole := 18; v_expected_count := 9;
            WHEN 'TARJETA_ULTIMOS_6' THEN
                v_start_hole := 13; v_end_hole := 18; v_expected_count := 6;
            WHEN 'TARJETA_ULTIMOS_3' THEN
                v_start_hole := 16; v_end_hole := 18; v_expected_count := 3;
            ELSE
                v_start_hole := 18; v_end_hole := 18; v_expected_count := 1;
        END CASE;

        SELECT
            count(*)::integer,
            ARRAY[
                -sum(
                    CASE
                        WHEN p_tipo_resultado='gross'::public.tipo_resultado_desempate
                            THEN (h->>'grossPoints')::integer
                        ELSE (h->>'netPoints')::integer
                    END
                )::integer
            ]
          INTO v_actual_count,v_key
          FROM jsonb_array_elements(p_holes) h
         WHERE (h->>'holeNumber')::integer BETWEEN v_start_hole AND v_end_hole
           AND (
                CASE
                    WHEN p_tipo_resultado='gross'::public.tipo_resultado_desempate
                        THEN h->>'grossPoints'
                    ELSE h->>'netPoints'
                END
               ) IS NOT NULL;

        IF v_actual_count<>v_expected_count
           OR v_key IS NULL
           OR v_key[1] IS NULL
        THEN
            RETURN NULL;
        END IF;

        RETURN v_key;
    END IF;

    -- Tarjeta completa: normalmente no rompe un empate de total, pero se soporta
    -- por compatibilidad con secuencias configurables existentes.
    IF v_code='TARJETA_18' THEN
        SELECT
            count(*)::integer,
            ARRAY[
                -sum(
                    CASE
                        WHEN p_tipo_resultado='gross'::public.tipo_resultado_desempate
                            THEN (h->>'grossPoints')::integer
                        ELSE (h->>'netPoints')::integer
                    END
                )::integer
            ]
          INTO v_actual_count,v_key
          FROM jsonb_array_elements(p_holes) h
         WHERE (
                CASE
                    WHEN p_tipo_resultado='gross'::public.tipo_resultado_desempate
                        THEN h->>'grossPoints'
                    ELSE h->>'netPoints'
                END
               ) IS NOT NULL;

        IF v_actual_count<>jsonb_array_length(p_holes)
           OR v_key IS NULL
           OR v_key[1] IS NULL
        THEN
            RETURN NULL;
        END IF;

        RETURN v_key;
    END IF;

    -- Regla local configurable: compara puntos en orden de Stroke Index.
    IF v_code='HOYO_POR_HOYO_HANDICAP' THEN
        SELECT
            count(*)::integer,
            array_agg(
                -(
                    CASE
                        WHEN p_tipo_resultado='gross'::public.tipo_resultado_desempate
                            THEN (h->>'grossPoints')::integer
                        ELSE (h->>'netPoints')::integer
                    END
                )
                ORDER BY (h->>'strokeIndex')::integer
            )
          INTO v_actual_count,v_key
          FROM jsonb_array_elements(p_holes) h
         WHERE (h->>'strokeIndex') IS NOT NULL
           AND (
                CASE
                    WHEN p_tipo_resultado='gross'::public.tipo_resultado_desempate
                        THEN h->>'grossPoints'
                    ELSE h->>'netPoints'
                END
               ) IS NOT NULL;

        IF v_actual_count<>jsonb_array_length(p_holes)
           OR v_key IS NULL
        THEN
            RETURN NULL;
        END IF;

        RETURN v_key;
    END IF;

    -- MUERTE_SUBITA, SORTEO y cualquier método desconocido son manuales.
    RETURN NULL;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 2. Evaluador de secuencia Stableford.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.evaluar_secuencia_desempate_stableford(
    p_rules jsonb,
    p_tipo_resultado public.tipo_resultado_desempate,
    p_holes jsonb
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

        v_key := public.calcular_clave_metodo_desempate_stableford(
            v_method_code,
            p_tipo_resultado,
            p_holes
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
-- 3. Motor de desempates Stableford por ronda.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_desempates_stableford_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_results jsonb;
    v_leaderboard jsonb;
    v_tournament_id uuid;
    v_round_number integer;
    v_round_date date;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    SELECT tournament_id,numero_ronda,fecha
      INTO v_tournament_id,v_round_number,v_round_date
      FROM public.tournament_rounds
     WHERE id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para consultar desempates Stableford.'
            USING ERRCODE='42501';
    END IF;

    v_results := public.obtener_resultados_stableford_oficiales_ronda(
        p_tournament_round_id
    );

    v_leaderboard := public.obtener_leaderboard_stableford_ronda(
        p_tournament_round_id
    );

    RETURN (
        WITH official_cards AS (
            SELECT
                (c->>'scoreCardId')::uuid AS score_card_id,
                (c->>'cardNumber')::integer AS card_number,
                c->>'cardFolio' AS card_folio,
                NULLIF(c->>'playerId','')::uuid AS player_id,
                c->>'playerName' AS player_name,
                NULLIF(c->>'tournamentCategoryId','')::uuid AS tournament_category_id,
                c->>'categoryCode' AS category_code,
                c->>'categoryName' AS category_name,
                NULLIF(c->>'categoryDisplayOrder','')::integer AS category_display_order,
                COALESCE((c->>'grossEnabled')::boolean,false) AS gross_enabled,
                COALESCE((c->>'netEnabled')::boolean,false) AS net_enabled,
                NULLIF(c->>'grossPointsTotal','')::integer AS gross_points_total,
                NULLIF(c->>'netPointsTotal','')::integer AS net_points_total,
                c->'holes' AS holes
            FROM jsonb_array_elements(v_results->'cards') c
            WHERE COALESCE((c->>'ready')::boolean,false)=true
        ),

        metric_rows AS (
            SELECT
                oc.*,
                'gross'::public.tipo_resultado_desempate AS result_type,
                oc.gross_points_total AS metric_total
            FROM official_cards oc
            WHERE oc.gross_enabled

            UNION ALL

            SELECT
                oc.*,
                'neto'::public.tipo_resultado_desempate AS result_type,
                oc.net_points_total AS metric_total
            FROM official_cards oc
            WHERE oc.net_enabled
        ),

        ranked AS (
            SELECT
                mr.*,
                rank() OVER (
                    PARTITION BY mr.tournament_category_id,mr.result_type
                    ORDER BY mr.metric_total DESC
                )::integer AS base_rank,
                count(*) OVER (
                    PARTITION BY mr.tournament_category_id,mr.result_type,mr.metric_total
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
                        WHERE r.tournament_id=v_tournament_id
                          AND r.activo=true
                          AND r.tipo_resultado=g.result_type
                          AND r.tournament_category_id=g.tournament_category_id
                          AND r.alcance=g.scope
                    ) THEN 'CATEGORY_SCOPE'

                    WHEN EXISTS (
                        SELECT 1
                        FROM public.tournament_tiebreak_rules r
                        WHERE r.tournament_id=v_tournament_id
                          AND r.activo=true
                          AND r.tipo_resultado=g.result_type
                          AND r.tournament_category_id=g.tournament_category_id
                          AND r.alcance='todos'::public.alcance_desempate
                    ) THEN 'CATEGORY_ALL'

                    WHEN EXISTS (
                        SELECT 1
                        FROM public.tournament_tiebreak_rules r
                        WHERE r.tournament_id=v_tournament_id
                          AND r.activo=true
                          AND r.tipo_resultado=g.result_type
                          AND r.tournament_category_id IS NULL
                          AND r.alcance=g.scope
                    ) THEN 'TOURNAMENT_SCOPE'

                    WHEN EXISTS (
                        SELECT 1
                        FROM public.tournament_tiebreak_rules r
                        WHERE r.tournament_id=v_tournament_id
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
                    WHERE r.tournament_id=v_tournament_id
                      AND r.activo=true
                      AND r.tipo_resultado=cg.result_type
                      AND (
                          (cg.rule_source='CATEGORY_SCOPE'
                           AND r.tournament_category_id=cg.tournament_category_id
                           AND r.alcance=cg.scope)
                          OR
                          (cg.rule_source='CATEGORY_ALL'
                           AND r.tournament_category_id=cg.tournament_category_id
                           AND r.alcance='todos'::public.alcance_desempate)
                          OR
                          (cg.rule_source='TOURNAMENT_SCOPE'
                           AND r.tournament_category_id IS NULL
                           AND r.alcance=cg.scope)
                          OR
                          (cg.rule_source='TOURNAMENT_ALL'
                           AND r.tournament_category_id IS NULL
                           AND r.alcance='todos'::public.alcance_desempate)
                      )
                ),'[]'::jsonb) AS rules
            FROM configured_groups cg
        ),

        player_eval AS (
            SELECT
                t.score_card_id,
                t.card_number,
                t.card_folio,
                t.player_id,
                t.player_name,
                t.tournament_category_id,
                t.category_code,
                t.category_name,
                t.category_display_order,
                t.result_type,
                t.metric_total,
                t.base_rank,
                t.tie_size,
                t.scope,
                gr.rule_source,
                gr.rules,
                public.evaluar_secuencia_desempate_stableford(
                    gr.rules,
                    t.result_type,
                    t.holes
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
                pe.score_card_id,
                (s->>'order')::integer AS step_order,
                s->>'methodCode' AS method_code,
                s->>'methodName' AS method_name,
                s->'cumulativeKey' AS cumulative_key_json,
                ARRAY(
                    SELECT value::integer
                    FROM jsonb_array_elements_text(s->'cumulativeKey')
                ) AS cumulative_key
            FROM player_eval pe
            CROSS JOIN LATERAL jsonb_array_elements(
                pe.evaluation->'steps'
            ) s
            WHERE COALESCE((s->>'automatic')::boolean,false)=true
        ),

        step_uniqueness AS (
            SELECT
                tournament_category_id,
                result_type,
                metric_total,
                base_rank,
                step_order,
                min(method_code) AS method_code,
                min(method_name) AS method_name,
                count(DISTINCT cumulative_key_json::text) AS unique_keys,
                max(tie_size) AS group_size
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
                COALESCE(bool_or(
                    COALESCE(
                        (pe.evaluation->>'stoppedAtManual')::boolean,
                        false
                    )
                ),false) AS stopped_at_manual,

                max(pe.evaluation->>'manualMethodCode')
                    FILTER (
                        WHERE COALESCE(
                            (pe.evaluation->>'stoppedAtManual')::boolean,
                            false
                        )
                    ) AS manual_method_code,

                max(pe.evaluation->>'manualMethodName')
                    FILTER (
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
                su.method_code AS resolved_method_code,
                su.method_name AS resolved_method_name,
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
                step_at_resolution.cumulative_key AS resolution_key,

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
                            pe.card_number ASC
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
                  AND COALESCE((s->>'automatic')::boolean,false)=true
                LIMIT 1
            ) step_at_resolution ON true
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
            'round',jsonb_build_object(
                'tournamentId',v_tournament_id,
                'tournamentRoundId',p_tournament_round_id,
                'roundNumber',v_round_number,
                'roundDate',v_round_date,
                'scoringEngine','stableford'
            ),

            'summary',(
                SELECT jsonb_build_object(
                    'tieGroups',tie_groups,
                    'automaticResolved',automatic_resolved,
                    'manualPending',manual_pending,
                    'configMissing',config_missing,
                    'persistsAfterRules',persists_after_rules,
                    'engineStatus',
                        CASE
                            WHEN tie_groups=0 THEN 'NO_TIES'
                            WHEN config_missing>0 THEN 'CONFIGURATION_REQUIRED'
                            WHEN manual_pending>0
                              OR persists_after_rules>0 THEN 'ACTION_REQUIRED'
                            ELSE 'RESOLVED'
                        END
                )
                FROM group_counts
            ),

            'tieGroups',COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'tournamentCategoryId',gf.tournament_category_id,
                        'categoryCode',gf.category_code,
                        'categoryName',gf.category_name,
                        'resultType',gf.result_type,
                        'tiedPoints',gf.metric_total,
                        'baseRank',gf.base_rank,
                        'tieSize',gf.tie_size,
                        'scope',gf.scope,
                        'ruleSource',gf.rule_source,
                        'rules',gf.rules,
                        'status',gf.tiebreak_status,
                        'resolvedAtStep',gf.resolved_at_step,
                        'resolvedByMethodCode',gf.resolved_method_code,
                        'resolvedByMethodName',gf.resolved_method_name,
                        'manualMethodCode',gf.manual_method_code,
                        'manualMethodName',gf.manual_method_name,
                        'players',COALESCE((
                            SELECT jsonb_agg(
                                jsonb_build_object(
                                    'scoreCardId',pr.score_card_id,
                                    'cardFolio',pr.card_folio,
                                    'playerId',pr.player_id,
                                    'playerName',pr.player_name,
                                    'baseRank',pr.base_rank,
                                    'tiebreakOrder',pr.tiebreak_order,
                                    'finalRank',
                                        CASE
                                            WHEN pr.tiebreak_order IS NOT NULL
                                            THEN pr.base_rank+pr.tiebreak_order-1
                                            ELSE NULL
                                        END,
                                    'comparisonKey',
                                        to_jsonb(pr.resolution_key),
                                    'evidence',
                                        pr.evaluation->'steps'
                                )
                                ORDER BY
                                    pr.tiebreak_order NULLS LAST,
                                    pr.card_number,
                                    pr.player_name
                            )
                            FROM player_resolution pr
                            WHERE pr.tournament_category_id=gf.tournament_category_id
                              AND pr.result_type=gf.result_type
                              AND pr.metric_total=gf.metric_total
                              AND pr.base_rank=gf.base_rank
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
    public.obtener_desempates_stableford_ronda(uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    public.obtener_desempates_stableford_ronda(uuid)
TO authenticated,service_role;

COMMIT;

-- ============================================================================
-- FIN MIGRACIÓN 186 FASE 1J
-- ============================================================================
