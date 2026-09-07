-- TEE CENTRAL / GOLF IN FULL
-- Migración 266
-- Asistente v19: dependencias seguras de inicio/resultados y evaluación competitiva diferida
-- IMPORTANTE: ejecutar manualmente en Supabase SQL Editor.

BEGIN;

CREATE OR REPLACE FUNCTION public._obtener_asistente_operativo_torneo_v19_266(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_result jsonb;
    v_source_steps jsonb := '[]'::jsonb;
    v_normalized_steps jsonb := '[]'::jsonb;
    v_final_steps jsonb := '[]'::jsonb;

    v_elem jsonb;
    v_rec_elem jsonb;

    v_round_id uuid;
    v_round_number integer;

    v_start_details jsonb;
    v_waiting_for text;
    v_start_normal_wait boolean := false;

    v_reconciliation_complete boolean := false;
    v_round_closed boolean := false;
    v_can_evaluate_competitive boolean := false;

    v_state jsonb;
    v_formal jsonb;
    v_competitive_status text;

    v_results_complete boolean := false;
    v_categories_closed boolean := false;
    v_publications_complete boolean := false;

    v_original_actionable boolean := true;
    v_original_waiting_for text;

    v_total_categories integer := 0;
    v_closed_categories integer := 0;
    v_published_categories integer := 0;

    v_results_step jsonb;
    v_categories_step jsonb;
    v_publication_step jsonb;
    v_round_close_step jsonb;

    v_blockers jsonb := '[]'::jsonb;
    v_next_action jsonb := NULL;
    v_total integer := 0;
    v_completed integer := 0;
BEGIN
    -- Partimos de v17, que ya contiene:
    --   START_TOURNAMENT correctamente posicionado,
    --   ROUND_PHYSICAL_CAPTURE,
    --   ROUND_RECONCILIATION,
    -- y todo el contrato previo hasta migración 264.
    --
    -- No llamamos a v18 directamente porque v18 evalúa el estado competitivo
    -- profundo de todas las rondas aun cuando la conciliación todavía no ha
    -- terminado, lo que puede invocar motores que aún no son consultables.
    v_result :=
        public._obtener_asistente_operativo_torneo_v17_264(
            p_tournament_id
        );

    v_source_steps := COALESCE(v_result->'steps','[]'::jsonb);

    ---------------------------------------------------------------------------
    -- 1. NORMALIZAR START_TOURNAMENT
    --
    -- Faltar congelado, salidas, tarjetas o inicialización de captura son
    -- esperas normales del flujo; no son una anomalía BLOCKED.
    ---------------------------------------------------------------------------
    FOR v_elem IN
        SELECT elem
        FROM jsonb_array_elements(v_source_steps) x(elem)
    LOOP
        IF v_elem->>'code'='START_TOURNAMENT'
           AND v_elem->>'status'='BLOCKED'
        THEN
            v_start_details := COALESCE(v_elem->'details','{}'::jsonb);
            v_waiting_for := NULL;
            v_start_normal_wait := false;

            IF NOT COALESCE((v_start_details->>'alreadyStarted')::boolean,false)
            THEN
                IF NOT COALESCE((v_start_details->>'conditionsFrozen')::boolean,false)
                THEN
                    v_waiting_for := 'FREEZE';
                    v_start_normal_wait := true;
                ELSIF NOT COALESCE((v_start_details->>'startsValidated')::boolean,false)
                THEN
                    v_waiting_for := 'ROUND_STARTS';
                    v_start_normal_wait := true;
                ELSIF NOT COALESCE((v_start_details->>'cardsIssued')::boolean,false)
                   OR NOT COALESCE((v_start_details->>'captureReady')::boolean,false)
                THEN
                    v_waiting_for := 'SCORECARD_EMISSION';
                    v_start_normal_wait := true;
                END IF;
            END IF;

            IF v_start_normal_wait THEN
                v_elem := jsonb_set(
                    v_elem,
                    '{status}',
                    to_jsonb('PENDING'::text),
                    true
                );

                v_elem := jsonb_set(
                    v_elem,
                    '{availability}',
                    jsonb_build_object(
                        'actionable',false,
                        'state','WAITING',
                        'waitingFor',v_waiting_for
                    ),
                    true
                );

                v_elem := jsonb_set(
                    v_elem,
                    '{action}',
                    'null'::jsonb,
                    true
                );

                v_elem := jsonb_set(
                    v_elem,
                    '{message}',
                    to_jsonb('El torneo espera completar el requisito operativo anterior antes de poder iniciar.'::text),
                    true
                );

                v_elem := jsonb_set(
                    v_elem,
                    '{recommendation}',
                    to_jsonb(
                        CASE v_waiting_for
                            WHEN 'FREEZE' THEN 'Completa primero el congelamiento de condiciones y hándicaps.'
                            WHEN 'ROUND_STARTS' THEN 'Completa primero la validación de salidas de la primera ronda.'
                            WHEN 'SCORECARD_EMISSION' THEN 'Emite las tarjetas oficiales; la inicialización de captura forma parte de ese flujo.'
                            ELSE 'Completa primero el requisito operativo anterior.'
                        END
                    ),
                    true
                );
            END IF;
        END IF;

        v_normalized_steps :=
            v_normalized_steps || jsonb_build_array(v_elem);
    END LOOP;

    ---------------------------------------------------------------------------
    -- 2. FORMALIZACIÓN DE RESULTADOS CON EVALUACIÓN DIFERIDA
    --
    -- Reemplaza cada ROUND_COMPETITIVE_CLOSE heredado por las cuatro etapas
    -- explícitas de 265, pero sólo consulta el motor competitivo profundo cuando
    -- la conciliación de ESA ronda está completa.
    --
    -- Antes de eso, las etapas se modelan como WAITING y nunca invocan motores
    -- que todavía no disponen de snapshots/validaciones/tarjetas suficientes.
    ---------------------------------------------------------------------------
    FOR v_elem IN
        SELECT elem
        FROM jsonb_array_elements(v_normalized_steps) x(elem)
    LOOP
        IF v_elem->>'code'<>'ROUND_COMPETITIVE_CLOSE' THEN
            v_final_steps :=
                v_final_steps || jsonb_build_array(v_elem);
            CONTINUE;
        END IF;

        v_round_id := NULLIF(v_elem->>'roundId','')::uuid;
        v_round_number := NULLIF(v_elem->>'roundNumber','')::integer;

        v_original_actionable := COALESCE(
            (v_elem#>>'{availability,actionable}')::boolean,
            true
        );
        v_original_waiting_for := NULLIF(
            v_elem#>>'{availability,waitingFor}',
            ''
        );

        -- La reconciliación explícita de v17 es la frontera segura para empezar
        -- a evaluar resultados competitivos.
        v_reconciliation_complete := false;
        FOR v_rec_elem IN
            SELECT elem
            FROM jsonb_array_elements(v_normalized_steps) r(elem)
            WHERE elem->>'code'='ROUND_RECONCILIATION'
              AND NULLIF(elem->>'roundId','')::uuid = v_round_id
            LIMIT 1
        LOOP
            v_reconciliation_complete :=
                v_rec_elem->>'status'='COMPLETE';
        END LOOP;

        SELECT EXISTS(
            SELECT 1
            FROM public.tournament_round_competitive_closures rc
            WHERE rc.tournament_round_id=v_round_id
              AND rc.competitive_status='FINAL'
        )
        INTO v_round_closed;

        v_can_evaluate_competitive :=
            v_reconciliation_complete OR v_round_closed;

        v_state := NULL;
        v_formal := NULL;
        v_competitive_status := NULL;
        v_results_complete := false;
        v_categories_closed := false;
        v_publications_complete := false;
        v_total_categories := 0;
        v_closed_categories := 0;
        v_published_categories := 0;

        IF v_round_closed THEN
            -- Cierre histórico ya existente: no crear deuda retroactiva ni
            -- reabrir motores competitivos para completar el Asistente.
            v_results_complete := true;
            v_categories_closed := true;
            v_publications_complete := true;

        ELSIF v_can_evaluate_competitive THEN
            v_state :=
                public.obtener_estado_cierre_competitivo_ronda(
                    v_round_id
                );

            v_formal := COALESCE(
                v_state->'formalization',
                public._estado_formalizacion_resultados_ronda_265(
                    v_round_id
                )
            );

            v_competitive_status :=
                v_state#>>'{status,competitiveStatus}';

            v_categories_closed := COALESCE(
                (v_formal->>'allCategoriesClosed')::boolean,
                false
            );

            v_publications_complete := COALESCE(
                (v_formal->>'allCategoriesPublished')::boolean,
                false
            );

            v_total_categories := COALESCE(
                (v_formal->>'totalCategories')::integer,
                0
            );

            v_closed_categories := COALESCE(
                (v_formal->>'closedCategories')::integer,
                0
            );

            v_published_categories := COALESCE(
                (v_formal->>'publishedCategories')::integer,
                0
            );

            v_results_complete :=
                v_competitive_status IN(
                    'FINAL',
                    'CATEGORIES_PENDING',
                    'PUBLICATIONS_PENDING'
                );
        END IF;

        -----------------------------------------------------------------------
        -- 2.1 RESULTADOS
        -----------------------------------------------------------------------
        v_results_step := jsonb_build_object(
            'code','ROUND_RESULTS',
            'scope','ROUND',
            'roundId',v_round_id,
            'roundNumber',v_round_number,
            'title',format('Ronda %s · Resultados',v_round_number),
            'status',CASE WHEN v_results_complete THEN 'COMPLETE' ELSE 'PENDING' END,
            'message',
                CASE
                    WHEN v_round_closed THEN
                        format('Los resultados de la ronda %s ya forman parte de una ronda cerrada formalmente.',v_round_number)
                    WHEN NOT v_reconciliation_complete THEN
                        format('Los resultados de la ronda %s esperan a que termine la conciliación.',v_round_number)
                    WHEN v_results_complete THEN
                        format('Los resultados y desempates de la ronda %s están resueltos.',v_round_number)
                    ELSE
                        format('Los resultados de la ronda %s todavía son provisionales o tienen desempates pendientes.',v_round_number)
                END,
            'recommendation',
                CASE
                    WHEN v_results_complete THEN NULL
                    WHEN NOT v_reconciliation_complete THEN 'Completa primero la conciliación de la ronda.'
                    WHEN NOT v_original_actionable THEN 'Completa primero el requisito operativo anterior.'
                    ELSE 'Revisa resultados, participantes no resueltos y desempates pendientes.'
                END,
            'details',
                CASE
                    WHEN v_round_closed THEN jsonb_build_object(
                        'deferredCompetitiveEvaluation',false,
                        'grandfatheredByRoundClosure',true
                    )
                    WHEN NOT v_reconciliation_complete THEN jsonb_build_object(
                        'deferredCompetitiveEvaluation',true,
                        'reason','WAITING_RECONCILIATION'
                    )
                    ELSE jsonb_build_object(
                        'deferredCompetitiveEvaluation',false,
                        'competitiveState',v_state
                    )
                END,
            'action',
                CASE
                    WHEN v_results_complete
                      OR NOT v_reconciliation_complete
                      OR NOT v_original_actionable
                        THEN NULL
                    ELSE jsonb_build_object(
                        'label','Revisar resultados',
                        'target','resultados',
                        'roundId',v_round_id
                    )
                END,
            'requiredRole','TOURNAMENT_OPERATOR',
            'availability',
                CASE
                    WHEN v_results_complete THEN jsonb_build_object(
                        'actionable',false,
                        'state','COMPLETE',
                        'waitingFor',NULL
                    )
                    WHEN NOT v_reconciliation_complete THEN jsonb_build_object(
                        'actionable',false,
                        'state','WAITING',
                        'waitingFor','ROUND_RECONCILIATION'
                    )
                    WHEN NOT v_original_actionable THEN jsonb_build_object(
                        'actionable',false,
                        'state','WAITING',
                        'waitingFor',
                            CASE
                                WHEN v_original_waiting_for='ROUND_SCORING'
                                    THEN 'ROUND_RECONCILIATION'
                                ELSE COALESCE(v_original_waiting_for,'PREVIOUS_REQUIREMENT')
                            END
                    )
                    ELSE jsonb_build_object(
                        'actionable',true,
                        'state','AVAILABLE',
                        'waitingFor',NULL
                    )
                END
        );

        -----------------------------------------------------------------------
        -- 2.2 CIERRE DE CATEGORÍA
        -----------------------------------------------------------------------
        v_categories_step := jsonb_build_object(
            'code','ROUND_CATEGORY_CLOSURE',
            'scope','ROUND',
            'roundId',v_round_id,
            'roundNumber',v_round_number,
            'title',format('Ronda %s · Cierre de categoría',v_round_number),
            'status',CASE WHEN v_round_closed OR v_categories_closed THEN 'COMPLETE' ELSE 'PENDING' END,
            'message',
                CASE
                    WHEN v_round_closed THEN
                        format('La etapa de cierre por categoría de la ronda %s ya fue superada históricamente.',v_round_number)
                    WHEN v_categories_closed THEN
                        format('Las %s categoría(s) de la ronda %s están cerradas formalmente.',v_total_categories,v_round_number)
                    WHEN NOT v_results_complete THEN
                        format('El cierre de categorías de la ronda %s espera a que los resultados queden resueltos.',v_round_number)
                    ELSE
                        format('La ronda %s tiene %s de %s categoría(s) cerradas formalmente.',v_round_number,v_closed_categories,v_total_categories)
                END,
            'recommendation',
                CASE
                    WHEN v_round_closed OR v_categories_closed THEN NULL
                    WHEN NOT v_results_complete THEN 'Completa primero los resultados y desempates.'
                    ELSE 'Cierra formalmente cada categoría que esté lista.'
                END,
            'details',
                CASE
                    WHEN v_formal IS NOT NULL THEN v_formal
                    ELSE jsonb_build_object(
                        'deferredCompetitiveEvaluation',true,
                        'reason','WAITING_RESULTS'
                    )
                END,
            'action',
                CASE
                    WHEN v_round_closed OR v_categories_closed OR NOT v_results_complete THEN NULL
                    ELSE jsonb_build_object(
                        'label',CASE WHEN v_total_categories-v_closed_categories=1 THEN 'Cerrar categoría' ELSE 'Cerrar categorías' END,
                        'target','resultados',
                        'roundId',v_round_id
                    )
                END,
            'requiredRole','TOURNAMENT_OPERATOR',
            'availability',
                CASE
                    WHEN v_round_closed OR v_categories_closed THEN jsonb_build_object(
                        'actionable',false,'state','COMPLETE','waitingFor',NULL
                    )
                    WHEN NOT v_results_complete THEN jsonb_build_object(
                        'actionable',false,'state','WAITING','waitingFor','ROUND_RESULTS'
                    )
                    ELSE jsonb_build_object(
                        'actionable',true,'state','AVAILABLE','waitingFor',NULL
                    )
                END
        );

        -----------------------------------------------------------------------
        -- 2.3 PUBLICACIÓN
        -----------------------------------------------------------------------
        v_publication_step := jsonb_build_object(
            'code','ROUND_RESULTS_PUBLICATION',
            'scope','ROUND',
            'roundId',v_round_id,
            'roundNumber',v_round_number,
            'title',format('Ronda %s · Publicar resultados',v_round_number),
            'status',CASE WHEN v_round_closed OR v_publications_complete THEN 'COMPLETE' ELSE 'PENDING' END,
            'message',
                CASE
                    WHEN v_round_closed THEN
                        format('La etapa de publicación de la ronda %s ya fue superada históricamente.',v_round_number)
                    WHEN v_publications_complete THEN
                        format('Los resultados de las %s categoría(s) de la ronda %s están publicados.',v_total_categories,v_round_number)
                    WHEN NOT v_categories_closed THEN
                        format('La publicación de la ronda %s espera al cierre formal de categorías.',v_round_number)
                    ELSE
                        format('La ronda %s tiene %s de %s categoría(s) publicadas.',v_round_number,v_published_categories,v_total_categories)
                END,
            'recommendation',
                CASE
                    WHEN v_round_closed OR v_publications_complete THEN NULL
                    WHEN NOT v_categories_closed THEN 'Completa primero los cierres formales de categoría.'
                    ELSE 'Publica los resultados cerrados de cada categoría.'
                END,
            'details',
                CASE
                    WHEN v_formal IS NOT NULL THEN v_formal
                    ELSE jsonb_build_object(
                        'deferredCompetitiveEvaluation',true,
                        'reason','WAITING_CATEGORY_CLOSURE'
                    )
                END,
            'action',
                CASE
                    WHEN v_round_closed OR v_publications_complete OR NOT v_categories_closed THEN NULL
                    ELSE jsonb_build_object(
                        'label','Publicar resultados',
                        'target','resultados',
                        'roundId',v_round_id
                    )
                END,
            'requiredRole','TOURNAMENT_OPERATOR',
            'availability',
                CASE
                    WHEN v_round_closed OR v_publications_complete THEN jsonb_build_object(
                        'actionable',false,'state','COMPLETE','waitingFor',NULL
                    )
                    WHEN NOT v_categories_closed THEN jsonb_build_object(
                        'actionable',false,'state','WAITING','waitingFor','ROUND_CATEGORY_CLOSURE'
                    )
                    ELSE jsonb_build_object(
                        'actionable',true,'state','AVAILABLE','waitingFor',NULL
                    )
                END
        );

        -----------------------------------------------------------------------
        -- 2.4 CIERRE DE RONDA
        -----------------------------------------------------------------------
        v_round_close_step := jsonb_build_object(
            'code','ROUND_COMPETITIVE_CLOSE',
            'scope','ROUND',
            'roundId',v_round_id,
            'roundNumber',v_round_number,
            'title',format('Ronda %s · Cierre de ronda',v_round_number),
            'status',CASE WHEN v_round_closed THEN 'COMPLETE' ELSE 'PENDING' END,
            'message',
                CASE
                    WHEN v_round_closed THEN
                        format('La ronda %s está cerrada competitivamente.',v_round_number)
                    WHEN v_publications_complete THEN
                        format('La ronda %s está lista para su cierre competitivo.',v_round_number)
                    ELSE
                        format('El cierre de la ronda %s espera a la publicación completa de resultados.',v_round_number)
                END,
            'recommendation',
                CASE
                    WHEN v_round_closed THEN NULL
                    WHEN NOT v_publications_complete THEN 'Completa primero la publicación de resultados de todas las categorías.'
                    ELSE 'Cierra formalmente la ronda.'
                END,
            'details',jsonb_build_object(
                'deferredCompetitiveEvaluation',NOT v_can_evaluate_competitive,
                'competitiveState',v_state,
                'formalization',v_formal
            ),
            'action',
                CASE
                    WHEN v_round_closed OR NOT v_publications_complete THEN NULL
                    ELSE jsonb_build_object(
                        'label','Cerrar ronda',
                        'target','cierre-ronda',
                        'roundId',v_round_id
                    )
                END,
            'requiredRole','TOURNAMENT_OPERATOR',
            'availability',
                CASE
                    WHEN v_round_closed THEN jsonb_build_object(
                        'actionable',false,'state','COMPLETE','waitingFor',NULL
                    )
                    WHEN NOT v_publications_complete THEN jsonb_build_object(
                        'actionable',false,'state','WAITING','waitingFor','ROUND_RESULTS_PUBLICATION'
                    )
                    ELSE jsonb_build_object(
                        'actionable',true,'state','AVAILABLE','waitingFor',NULL
                    )
                END
        );

        v_final_steps :=
            v_final_steps
            || jsonb_build_array(v_results_step)
            || jsonb_build_array(v_categories_step)
            || jsonb_build_array(v_publication_step)
            || jsonb_build_array(v_round_close_step);
    END LOOP;

    ---------------------------------------------------------------------------
    -- 3. Recalcular blockers, nextAction y progreso sobre el contrato v19.
    ---------------------------------------------------------------------------
    SELECT COALESCE(
        jsonb_agg(s.elem ORDER BY s.ord),
        '[]'::jsonb
    )
      INTO v_blockers
      FROM jsonb_array_elements(v_final_steps)
           WITH ORDINALITY AS s(elem,ord)
     WHERE s.elem->>'status'='BLOCKED'
       AND COALESCE(
           (s.elem#>>'{availability,actionable}')::boolean,
           true
       );

    SELECT s.elem->'action'
      INTO v_next_action
      FROM jsonb_array_elements(v_final_steps)
           WITH ORDINALITY AS s(elem,ord)
     WHERE s.elem->>'status' IN('BLOCKED','PENDING')
       AND s.elem->'action' IS NOT NULL
       AND s.elem->'action'<>'null'::jsonb
       AND COALESCE(
           (s.elem#>>'{availability,actionable}')::boolean,
           true
       )
     ORDER BY s.ord
     LIMIT 1;

    SELECT
        count(*)::integer,
        count(*) FILTER(
            WHERE elem->>'status'='COMPLETE'
        )::integer
      INTO v_total,v_completed
      FROM jsonb_array_elements(v_final_steps) x(elem);

    v_result := jsonb_set(v_result,'{steps}',v_final_steps,true);
    v_result := jsonb_set(v_result,'{blockers}',v_blockers,true);
    v_result := jsonb_set(
        v_result,
        '{summary,blockingIssues}',
        to_jsonb(jsonb_array_length(v_blockers)),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{progress,completed}',
        to_jsonb(v_completed),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{progress,total}',
        to_jsonb(v_total),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{progress,percent}',
        to_jsonb(
            CASE
                WHEN v_total=0 THEN 0
                ELSE round(100.0*v_completed/v_total,0)
            END
        ),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{nextAction}',
        COALESCE(v_next_action,'null'::jsonb),
        true
    );

    RETURN v_result || jsonb_build_object('schemaVersion',19);
END;
$function$;

CREATE OR REPLACE FUNCTION public.obtener_asistente_operativo_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RETURN
        public._obtener_asistente_operativo_torneo_v19_266(
            p_tournament_id
        );
END;
$function$;

-- El helper versionado es interno.
REVOKE ALL ON FUNCTION public._obtener_asistente_operativo_torneo_v19_266(uuid)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._obtener_asistente_operativo_torneo_v19_266(uuid)
FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public._obtener_asistente_operativo_torneo_v19_266(uuid)
TO postgres, service_role;

-- Mantener el RPC público sólo para usuarios autenticados / service role.
REVOKE ALL ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
TO authenticated, service_role;

COMMIT;
