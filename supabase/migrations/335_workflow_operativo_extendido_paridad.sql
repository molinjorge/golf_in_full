-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 335
-- Workflow operativo materializado — ampliación de paridad funcional
--
-- Requisito previo: 334 ejecutada y verificada.
--
-- OBJETIVO
-- Añadir al workflow materializado los estados operativos que todavía estaban
-- únicamente en la cadena histórica del Asistente, reutilizando las fuentes de
-- verdad existentes y SIN sustituir todavía obtener_asistente_operativo_torneo().
--
-- IMPORTANTE
-- - No modifica motores deportivos ni datos deportivos.
-- - No hace backfill/barrido masivo de torneos.
-- - La ampliación se materializa cuando se reconcilia UN torneo.
-- - Las consultas profundas de resultados/formalización sólo se ejecutan cuando
--   la conciliación de la ronda ya está completa.
-- - Conserva las funciones 332/333 y agrega una capa 335.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.reconstruir_workflow_extendido_335(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    r public.tournament_rounds%ROWTYPE;
    v_base jsonb;
    v_hcp_ranges jsonb;
    v_tiebreak jsonb;
    v_team_hcp jsonb;
    v_capture jsonb;
    v_close jsonb;
    v_formal jsonb;

    v_status text;
    v_block text;
    v_applicable boolean;
    v_physical_complete boolean;
    v_reconciliation_complete boolean;
    v_cards_ready boolean;
    v_tiebreaks_ready boolean;
    v_all_categories_ready boolean;
    v_all_categories_closed boolean;
    v_all_categories_published boolean;
    v_round_closed boolean;
    v_nodes integer;
BEGIN
    -- Primero conserva literalmente la proyección base 332/333.
    v_base := public.reconstruir_workflow_torneo_332(p_tournament_id);

    -- ------------------------------------------------------------------------
    -- CONFIGURACIÓN: evidencias explícitas que antes vivían sólo en el
    -- Asistente histórico.
    -- ------------------------------------------------------------------------
    v_hcp_ranges := public.validar_franjas_handicap_torneo(p_tournament_id);
    v_status := CASE
        WHEN COALESCE((v_hcp_ranges->>'valid')::boolean,false) THEN 'COMPLETE'
        ELSE 'AVAILABLE'
    END;

    PERFORM public._upsert_workflow_node_332(
        p_tournament_id,NULL,'TOURNAMENT','HANDICAP_RANGES',12,v_status,
        'CONFIGURATION','TIEBREAK_CONFIGURATION',NULL,
        v_hcp_ranges,
        CASE
            WHEN v_status='COMPLETE' THEN 'Franjas de hándicap válidas.'
            ELSE 'Franjas de hándicap pendientes o inválidas.'
        END,
        NULL
    );

    v_tiebreak := public.obtener_estado_configuracion_desempates_261(
        p_tournament_id
    );
    v_status := CASE
        WHEN COALESCE((v_tiebreak->>'complete')::boolean,false) THEN 'COMPLETE'
        ELSE 'AVAILABLE'
    END;

    PERFORM public._upsert_workflow_node_332(
        p_tournament_id,NULL,'TOURNAMENT','TIEBREAK_CONFIGURATION',14,v_status,
        'HANDICAP_RANGES','REGISTRATIONS',
        CASE
            WHEN NOT COALESCE((v_hcp_ranges->>'valid')::boolean,false)
            THEN 'HANDICAP_RANGES'
            ELSE NULL
        END,
        v_tiebreak,
        COALESCE(
            v_tiebreak->>'message',
            CASE WHEN v_status='COMPLETE'
                 THEN 'Desempates configurados.'
                 ELSE 'Configuración de desempates pendiente.'
            END
        ),
        NULL
    );

    -- Ajusta únicamente la navegación materializada de CONFIGURATION y
    -- REGISTRATIONS. No cambia sus estados ni reglas.
    UPDATE public.tournament_workflow_nodes
       SET next_code='HANDICAP_RANGES', updated_at=now()
     WHERE tournament_id=p_tournament_id
       AND scope='TOURNAMENT'
       AND tournament_round_id IS NULL
       AND code='CONFIGURATION';

    UPDATE public.tournament_workflow_nodes
       SET previous_code='TIEBREAK_CONFIGURATION', updated_at=now()
     WHERE tournament_id=p_tournament_id
       AND scope='TOURNAMENT'
       AND tournament_round_id IS NULL
       AND code='REGISTRATIONS';

    -- ------------------------------------------------------------------------
    -- RONDAS
    -- ------------------------------------------------------------------------
    FOR r IN
        SELECT *
          FROM public.tournament_rounds
         WHERE tournament_id=p_tournament_id
           AND activo=true
         ORDER BY numero_ronda,id
    LOOP
        -- HCP TEAM: sólo existe como nodo cuando realmente aplica.
        v_team_hcp := public._estado_hcp_team_ronda_244(r.id);
        v_applicable := COALESCE((v_team_hcp->>'applicable')::boolean,false);

        IF v_applicable THEN
            v_status := CASE COALESCE(v_team_hcp->>'status','PENDING')
                WHEN 'COMPLETE' THEN 'COMPLETE'
                WHEN 'BLOCKED' THEN 'BLOCKED'
                ELSE 'AVAILABLE'
            END;

            PERFORM public._upsert_workflow_node_332(
                p_tournament_id,r.id,'ROUND','ROUND_TEAM_HCP',
                205+r.numero_ronda*100,v_status,
                'ROUND_CONFIGURATION','ROUND_GROUPS',
                CASE WHEN v_status='BLOCKED'
                     THEN 'ROUND_TEAM_HCP'
                     ELSE NULL
                END,
                v_team_hcp,
                COALESCE(v_team_hcp->>'message','Estado HCP TEAM.'),
                NULL
            );

            UPDATE public.tournament_workflow_nodes
               SET next_code='ROUND_TEAM_HCP', updated_at=now()
             WHERE tournament_id=p_tournament_id
               AND tournament_round_id=r.id
               AND scope='ROUND'
               AND code='ROUND_CONFIGURATION';

            UPDATE public.tournament_workflow_nodes
               SET previous_code='ROUND_TEAM_HCP', updated_at=now()
             WHERE tournament_id=p_tournament_id
               AND tournament_round_id=r.id
               AND scope='ROUND'
               AND code='ROUND_GROUPS';
        ELSE
            DELETE FROM public.tournament_workflow_nodes
             WHERE tournament_id=p_tournament_id
               AND tournament_round_id=r.id
               AND scope='ROUND'
               AND code='ROUND_TEAM_HCP';
        END IF;

        -- Captura física y conciliación: agregados operativos livianos.
        v_capture := public.obtener_estado_captura_conciliacion_ronda_264(r.id);
        v_physical_complete :=
            COALESCE((v_capture#>>'{physicalCapture,complete}')::boolean,false);
        v_reconciliation_complete :=
            COALESCE((v_capture#>>'{reconciliation,complete}')::boolean,false);

        v_status := CASE
            WHEN v_physical_complete THEN 'COMPLETE'
            WHEN v_capture#>>'{physicalCapture,status}'='IN_PROGRESS'
                THEN 'IN_PROGRESS'
            WHEN EXISTS (
                SELECT 1
                  FROM public.tournament_round_lifecycle l
                 WHERE l.tournament_round_id=r.id
                   AND l.started_at IS NOT NULL
            ) THEN 'AVAILABLE'
            ELSE 'BLOCKED'
        END;
        v_block := CASE
            WHEN v_status='BLOCKED' THEN 'ROUND_PLAY'
            ELSE NULL
        END;

        PERFORM public._upsert_workflow_node_332(
            p_tournament_id,r.id,'ROUND','ROUND_PHYSICAL_CAPTURE',
            252+r.numero_ronda*100,v_status,
            'ROUND_PLAY','ROUND_RECONCILIATION',v_block,
            COALESCE(v_capture->'physicalCapture','{}'::jsonb),
            CASE
                WHEN v_physical_complete THEN 'Captura física completa.'
                WHEN v_status='IN_PROGRESS' THEN 'Captura física en proceso.'
                WHEN v_status='BLOCKED' THEN 'Requiere iniciar la ronda.'
                ELSE 'Captura física disponible.'
            END,
            NULL
        );

        v_status := CASE
            WHEN v_reconciliation_complete THEN 'COMPLETE'
            WHEN NOT v_physical_complete THEN 'BLOCKED'
            ELSE 'AVAILABLE'
        END;
        v_block := CASE
            WHEN NOT v_physical_complete THEN 'ROUND_PHYSICAL_CAPTURE'
            ELSE NULL
        END;

        PERFORM public._upsert_workflow_node_332(
            p_tournament_id,r.id,'ROUND','ROUND_RECONCILIATION',
            254+r.numero_ronda*100,v_status,
            'ROUND_PHYSICAL_CAPTURE','ROUND_RESULTS',v_block,
            COALESCE(v_capture->'reconciliation','{}'::jsonb),
            CASE
                WHEN v_reconciliation_complete THEN 'Conciliación completa.'
                WHEN v_status='BLOCKED' THEN 'Requiere captura física completa.'
                ELSE 'Conciliación pendiente.'
            END,
            NULL
        );

        UPDATE public.tournament_workflow_nodes
           SET next_code='ROUND_PHYSICAL_CAPTURE', updated_at=now()
         WHERE tournament_id=p_tournament_id
           AND tournament_round_id=r.id
           AND scope='ROUND'
           AND code='ROUND_PLAY';

        -- --------------------------------------------------------------------
        -- RESULTADOS / FORMALIZACIÓN
        -- Frontera de seguridad heredada de 266:
        -- NO consultar cierre/leaderboard/desempates mientras la conciliación
        -- no esté completa.
        -- --------------------------------------------------------------------
        IF v_reconciliation_complete THEN
            v_close := public.obtener_estado_cierre_competitivo_ronda(r.id);
            v_cards_ready :=
                COALESCE((v_close#>>'{status,cardsReady}')::boolean,false);
            v_tiebreaks_ready :=
                COALESCE((v_close#>>'{status,tiebreaksReady}')::boolean,false);

            v_status := CASE
                WHEN v_cards_ready AND v_tiebreaks_ready THEN 'COMPLETE'
                WHEN v_cards_ready THEN 'IN_PROGRESS'
                ELSE 'AVAILABLE'
            END;

            PERFORM public._upsert_workflow_node_332(
                p_tournament_id,r.id,'ROUND','ROUND_RESULTS',
                256+r.numero_ronda*100,v_status,
                'ROUND_RECONCILIATION','ROUND_CATEGORY_CLOSURE',NULL,
                jsonb_build_object(
                    'cardsReady',v_cards_ready,
                    'tiebreaksReady',v_tiebreaks_ready,
                    'competitiveStatus',
                        v_close#>>'{status,competitiveStatus}',
                    'tiebreakSummary',
                        COALESCE(v_close->'tiebreakSummary','{}'::jsonb)
                ),
                CASE
                    WHEN v_status='COMPLETE'
                        THEN 'Resultados competitivos listos.'
                    WHEN v_status='IN_PROGRESS'
                        THEN 'Resultados con desempates pendientes.'
                    ELSE 'Resultados pendientes.'
                END,
                NULL
            );

            v_formal := public._estado_formalizacion_resultados_ronda_265(r.id);
            v_applicable :=
                COALESCE((v_formal->>'applicable')::boolean,false);
            v_all_categories_ready :=
                COALESCE((v_formal->>'allCategoriesReady')::boolean,false);
            v_all_categories_closed :=
                COALESCE((v_formal->>'allCategoriesClosed')::boolean,false);
            v_all_categories_published :=
                COALESCE((v_formal->>'allCategoriesPublished')::boolean,false);
            v_round_closed :=
                COALESCE((v_formal->>'roundClosed')::boolean,false);

            IF v_applicable THEN
                v_status := CASE
                    WHEN v_all_categories_closed THEN 'COMPLETE'
                    WHEN NOT v_all_categories_ready THEN 'BLOCKED'
                    ELSE 'AVAILABLE'
                END;

                PERFORM public._upsert_workflow_node_332(
                    p_tournament_id,r.id,'ROUND','ROUND_CATEGORY_CLOSURE',
                    258+r.numero_ronda*100,v_status,
                    'ROUND_RESULTS','ROUND_RESULTS_PUBLICATION',
                    CASE WHEN NOT v_all_categories_ready
                         THEN 'ROUND_RESULTS'
                         ELSE NULL
                    END,
                    jsonb_build_object(
                        'totalCategories',v_formal->'totalCategories',
                        'readyCategories',v_formal->'readyCategories',
                        'closedCategories',v_formal->'closedCategories',
                        'allCategoriesReady',v_all_categories_ready,
                        'allCategoriesClosed',v_all_categories_closed
                    ),
                    CASE
                        WHEN v_all_categories_closed
                            THEN 'Categorías cerradas.'
                        WHEN NOT v_all_categories_ready
                            THEN 'Existen categorías todavía no listas.'
                        ELSE 'Cierre por categoría disponible.'
                    END,
                    NULL
                );

                v_status := CASE
                    WHEN v_all_categories_published THEN 'COMPLETE'
                    WHEN NOT v_all_categories_closed THEN 'BLOCKED'
                    ELSE 'AVAILABLE'
                END;

                PERFORM public._upsert_workflow_node_332(
                    p_tournament_id,r.id,'ROUND','ROUND_RESULTS_PUBLICATION',
                    260+r.numero_ronda*100,v_status,
                    'ROUND_CATEGORY_CLOSURE','ROUND_COMPETITIVE_CLOSE',
                    CASE WHEN NOT v_all_categories_closed
                         THEN 'ROUND_CATEGORY_CLOSURE'
                         ELSE NULL
                    END,
                    jsonb_build_object(
                        'totalCategories',v_formal->'totalCategories',
                        'publishedCategories',v_formal->'publishedCategories',
                        'allCategoriesPublished',v_all_categories_published,
                        'roundClosed',v_round_closed
                    ),
                    CASE
                        WHEN v_all_categories_published
                            THEN 'Resultados publicados por categoría.'
                        WHEN NOT v_all_categories_closed
                            THEN 'Requiere cierre de categorías.'
                        ELSE 'Publicación de resultados disponible.'
                    END,
                    NULL
                );

                UPDATE public.tournament_workflow_nodes
                   SET previous_code='ROUND_RESULTS_PUBLICATION',
                       updated_at=now()
                 WHERE tournament_id=p_tournament_id
                   AND tournament_round_id=r.id
                   AND scope='ROUND'
                   AND code='ROUND_COMPETITIVE_CLOSE';
            ELSE
                -- Modalidad sin formalización por categoría: no inventar pasos.
                DELETE FROM public.tournament_workflow_nodes
                 WHERE tournament_id=p_tournament_id
                   AND tournament_round_id=r.id
                   AND scope='ROUND'
                   AND code IN (
                       'ROUND_CATEGORY_CLOSURE',
                       'ROUND_RESULTS_PUBLICATION'
                   );

                UPDATE public.tournament_workflow_nodes
                   SET next_code='ROUND_COMPETITIVE_CLOSE', updated_at=now()
                 WHERE tournament_id=p_tournament_id
                   AND tournament_round_id=r.id
                   AND scope='ROUND'
                   AND code='ROUND_RESULTS';

                UPDATE public.tournament_workflow_nodes
                   SET previous_code='ROUND_RESULTS', updated_at=now()
                 WHERE tournament_id=p_tournament_id
                   AND tournament_round_id=r.id
                   AND scope='ROUND'
                   AND code='ROUND_COMPETITIVE_CLOSE';
            END IF;
        ELSE
            -- Mantener los nodos visibles pero sin ejecutar motores profundos.
            PERFORM public._upsert_workflow_node_332(
                p_tournament_id,r.id,'ROUND','ROUND_RESULTS',
                256+r.numero_ronda*100,'BLOCKED',
                'ROUND_RECONCILIATION','ROUND_CATEGORY_CLOSURE',
                'ROUND_RECONCILIATION',
                jsonb_build_object(
                    'deferred',true,
                    'reason','RECONCILIATION_INCOMPLETE'
                ),
                'Resultados diferidos hasta completar conciliación.',
                NULL
            );

            PERFORM public._upsert_workflow_node_332(
                p_tournament_id,r.id,'ROUND','ROUND_CATEGORY_CLOSURE',
                258+r.numero_ronda*100,'BLOCKED',
                'ROUND_RESULTS','ROUND_RESULTS_PUBLICATION','ROUND_RESULTS',
                jsonb_build_object(
                    'deferred',true,
                    'reason','RESULTS_NOT_READY'
                ),
                'Cierre de categorías diferido hasta completar resultados.',
                NULL
            );

            PERFORM public._upsert_workflow_node_332(
                p_tournament_id,r.id,'ROUND','ROUND_RESULTS_PUBLICATION',
                260+r.numero_ronda*100,'BLOCKED',
                'ROUND_CATEGORY_CLOSURE','ROUND_COMPETITIVE_CLOSE',
                'ROUND_CATEGORY_CLOSURE',
                jsonb_build_object(
                    'deferred',true,
                    'reason','CATEGORY_CLOSURE_NOT_READY'
                ),
                'Publicación diferida hasta cerrar categorías.',
                NULL
            );

            UPDATE public.tournament_workflow_nodes
               SET previous_code='ROUND_RESULTS_PUBLICATION',
                   updated_at=now()
             WHERE tournament_id=p_tournament_id
               AND tournament_round_id=r.id
               AND scope='ROUND'
               AND code='ROUND_COMPETITIVE_CLOSE';
        END IF;
    END LOOP;

    SELECT count(*) INTO v_nodes
      FROM public.tournament_workflow_nodes
     WHERE tournament_id=p_tournament_id;

    RETURN jsonb_build_object(
        'ok',true,
        'tournament_id',p_tournament_id,
        'node_count',v_nodes,
        'base',v_base,
        'extended_version',335,
        'reconciled_at',now()
    );
END;
$function$;

COMMENT ON FUNCTION public.reconstruir_workflow_extendido_335(uuid)
IS 'Migración 335: amplía la proyección 332/333 con HCP, desempates, HCP TEAM, captura física, conciliación, resultados, cierre por categoría y publicación; difiere motores profundos hasta conciliación completa.';

-- La RPC de reconciliación conserva su nombre público, autorización y contrato,
-- pero ahora materializa la proyección extendida.
CREATE OR REPLACE FUNCTION public.reconciliar_workflow_torneo_332(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'Sin permisos para administrar este torneo';
    END IF;

    RETURN public.reconstruir_workflow_extendido_335(p_tournament_id);
END;
$function$;

COMMENT ON FUNCTION public.reconciliar_workflow_torneo_332(uuid)
IS 'Migración 335: reconciliación autorizada del workflow materializado extendido. Conserva el nombre público 332 por compatibilidad.';

COMMIT;
