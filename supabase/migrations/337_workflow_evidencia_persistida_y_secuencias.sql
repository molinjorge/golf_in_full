-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 337
-- Workflow operativo: evidencia persistida + corrección de secuencias
--
-- OBJETIVO
-- 1) Evitar que la reconstrucción materializada del workflow invoque motores
--    profundos de resultados/desempates que dependen de auth.uid().
-- 2) Mantener al motor deportivo como autoridad para validar/cerrar resultados.
-- 3) Corregir las secuencias introducidas por 335.
-- 4) Conservar intactas las protecciones de las RPC deportivas públicas.
--
-- IMPORTANTE
-- - No modifica motores deportivos.
-- - No modifica datos deportivos.
-- - No reconstruye torneos automáticamente.
-- - El usuario ejecuta esta migración manualmente.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.reconstruir_workflow_extendido_337(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r public.tournament_rounds%ROWTYPE;
    v_base jsonb;
    v_hcp_ranges jsonb;
    v_tiebreak jsonb;
    v_team_hcp jsonb;
    v_capture jsonb;

    v_status text;
    v_block text;
    v_applicable boolean;
    v_physical_complete boolean;
    v_reconciliation_complete boolean;

    v_expected_categories integer;
    v_closed_categories integer;
    v_published_categories integer;
    v_round_closed boolean;
    v_all_categories_closed boolean;
    v_all_categories_published boolean;

    v_nodes integer;
BEGIN
    -- Conserva la proyección base 332/333.
    v_base := public.reconstruir_workflow_torneo_332(p_tournament_id);

    -- ------------------------------------------------------------------------
    -- CONFIGURACIÓN
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
        -- --------------------------------------------------------------------
        -- HCP TEAM
        -- Corrección de secuencia 335:
        -- ronda 1 = 205, ronda 2 = 305, etc.
        -- --------------------------------------------------------------------
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
                105+r.numero_ronda*100,v_status,
                'ROUND_CONFIGURATION','ROUND_GROUPS',
                CASE WHEN v_status='BLOCKED' THEN 'ROUND_TEAM_HCP' ELSE NULL END,
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

            UPDATE public.tournament_workflow_nodes
               SET next_code='ROUND_GROUPS', updated_at=now()
             WHERE tournament_id=p_tournament_id
               AND tournament_round_id=r.id
               AND scope='ROUND'
               AND code='ROUND_CONFIGURATION';

            UPDATE public.tournament_workflow_nodes
               SET previous_code='ROUND_CONFIGURATION', updated_at=now()
             WHERE tournament_id=p_tournament_id
               AND tournament_round_id=r.id
               AND scope='ROUND'
               AND code='ROUND_GROUPS';
        END IF;

        -- --------------------------------------------------------------------
        -- CAPTURA FÍSICA / CONCILIACIÓN
        -- Secuencias correctas para ronda 1: 252 / 254.
        -- --------------------------------------------------------------------
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
            152+r.numero_ronda*100,v_status,
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
            154+r.numero_ronda*100,v_status,
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
        -- RESULTADOS / CIERRES / PUBLICACIÓN
        --
        -- 337 NO ejecuta:
        --   obtener_estado_cierre_competitivo_ronda()
        --   _estado_formalizacion_resultados_ronda_265()
        --   leaderboards ni motores de desempate.
        --
        -- El workflow sólo usa:
        --   a) conciliación materializada;
        --   b) cierres de categoría persistidos;
        --   c) publicaciones persistidas;
        --   d) cierre competitivo de ronda persistido.
        --
        -- El motor deportivo sigue siendo la autoridad que permite o rechaza
        -- los cierres cuando el administrador entra al flujo de Resultados.
        -- --------------------------------------------------------------------
        SELECT count(DISTINCT tcc.tournament_category_id)::integer
          INTO v_expected_categories
          FROM public.tournament_category_classifications tcc
         WHERE tcc.tournament_id=p_tournament_id;

        SELECT count(DISTINCT c.tournament_category_id)::integer
          INTO v_closed_categories
          FROM public.tournament_round_category_competitive_closures c
         WHERE c.tournament_round_id=r.id
           AND c.competitive_status='FINAL';

        SELECT count(DISTINCT p.tournament_category_id)::integer
          INTO v_published_categories
          FROM public.tournament_round_category_publications p
         WHERE p.tournament_round_id=r.id
           AND p.publication_status='PUBLISHED';

        SELECT EXISTS (
            SELECT 1
              FROM public.tournament_round_competitive_closures rc
             WHERE rc.tournament_round_id=r.id
               AND rc.competitive_status='FINAL'
        )
        INTO v_round_closed;

        v_all_categories_closed :=
            v_expected_categories>0
            AND v_closed_categories>=v_expected_categories;

        v_all_categories_published :=
            v_expected_categories>0
            AND v_published_categories>=v_expected_categories;

        -- RESULTADOS:
        -- Disponible al completar conciliación. No se autodeclara COMPLETE
        -- por inferencia deportiva. Sólo un cierre formal ya persistido permite
        -- considerar superada históricamente la etapa.
        v_status := CASE
            WHEN v_round_closed THEN 'COMPLETE'
            WHEN v_reconciliation_complete THEN 'AVAILABLE'
            ELSE 'BLOCKED'
        END;

        PERFORM public._upsert_workflow_node_332(
            p_tournament_id,r.id,'ROUND','ROUND_RESULTS',
            156+r.numero_ronda*100,v_status,
            'ROUND_RECONCILIATION',
            CASE
                WHEN v_expected_categories>0
                    THEN 'ROUND_CATEGORY_CLOSURE'
                ELSE 'ROUND_COMPETITIVE_CLOSE'
            END,
            CASE
                WHEN NOT v_reconciliation_complete
                    THEN 'ROUND_RECONCILIATION'
                ELSE NULL
            END,
            jsonb_build_object(
                'source','PERSISTED_EVIDENCE_337',
                'reconciliationComplete',v_reconciliation_complete,
                'roundClosed',v_round_closed,
                'sportsValidationDeferred',NOT v_round_closed
            ),
            CASE
                WHEN v_round_closed
                    THEN 'Resultados superados por cierre competitivo formal de la ronda.'
                WHEN v_reconciliation_complete
                    THEN 'Resultados disponibles; la validación deportiva se realiza en el flujo de Resultados.'
                ELSE 'Resultados diferidos hasta completar conciliación.'
            END,
            CASE WHEN v_round_closed THEN
                (SELECT max(rc.closed_at)
                   FROM public.tournament_round_competitive_closures rc
                  WHERE rc.tournament_round_id=r.id
                    AND rc.competitive_status='FINAL')
                 ELSE NULL END
        );

        IF v_expected_categories>0 THEN
            -- CIERRE DE CATEGORÍAS:
            -- La disponibilidad NO significa que los resultados estén validados.
            -- La RPC deportiva de cierre conserva esa decisión.
            v_status := CASE
                WHEN v_round_closed OR v_all_categories_closed THEN 'COMPLETE'
                WHEN v_reconciliation_complete THEN 'AVAILABLE'
                ELSE 'BLOCKED'
            END;

            PERFORM public._upsert_workflow_node_332(
                p_tournament_id,r.id,'ROUND','ROUND_CATEGORY_CLOSURE',
                158+r.numero_ronda*100,v_status,
                'ROUND_RESULTS','ROUND_RESULTS_PUBLICATION',
                CASE
                    WHEN NOT v_reconciliation_complete THEN 'ROUND_RECONCILIATION'
                    ELSE NULL
                END,
                jsonb_build_object(
                    'source','PERSISTED_EVIDENCE_337',
                    'expectedCategories',v_expected_categories,
                    'closedCategories',v_closed_categories,
                    'allCategoriesClosed',v_all_categories_closed,
                    'roundClosed',v_round_closed,
                    'sportsValidationDeferred',NOT (v_round_closed OR v_all_categories_closed)
                ),
                CASE
                    WHEN v_round_closed
                        THEN 'Categorías superadas por cierre competitivo formal de la ronda.'
                    WHEN v_all_categories_closed
                        THEN 'Todas las categorías tienen cierre competitivo persistido.'
                    WHEN v_reconciliation_complete
                        THEN 'Cierre por categoría disponible; la RPC deportiva validará resultados y desempates.'
                    ELSE 'Cierre de categorías diferido hasta completar conciliación.'
                END,
                CASE WHEN v_round_closed OR v_all_categories_closed THEN
                    (SELECT max(c.closed_at)
                       FROM public.tournament_round_category_competitive_closures c
                      WHERE c.tournament_round_id=r.id
                        AND c.competitive_status='FINAL')
                     ELSE NULL END
            );

            -- PUBLICACIÓN:
            -- Sólo se habilita cuando todos los cierres de categoría ya existen.
            v_status := CASE
                WHEN v_round_closed OR v_all_categories_published THEN 'COMPLETE'
                WHEN NOT v_all_categories_closed THEN 'BLOCKED'
                ELSE 'AVAILABLE'
            END;

            PERFORM public._upsert_workflow_node_332(
                p_tournament_id,r.id,'ROUND','ROUND_RESULTS_PUBLICATION',
                159+r.numero_ronda*100,v_status,
                'ROUND_CATEGORY_CLOSURE','ROUND_COMPETITIVE_CLOSE',
                CASE
                    WHEN NOT v_all_categories_closed AND NOT v_round_closed
                        THEN 'ROUND_CATEGORY_CLOSURE'
                    ELSE NULL
                END,
                jsonb_build_object(
                    'source','PERSISTED_EVIDENCE_337',
                    'expectedCategories',v_expected_categories,
                    'closedCategories',v_closed_categories,
                    'publishedCategories',v_published_categories,
                    'allCategoriesClosed',v_all_categories_closed,
                    'allCategoriesPublished',v_all_categories_published,
                    'roundClosed',v_round_closed
                ),
                CASE
                    WHEN v_round_closed
                        THEN 'Publicación superada por cierre competitivo formal de la ronda.'
                    WHEN v_all_categories_published
                        THEN 'Resultados publicados para todas las categorías.'
                    WHEN NOT v_all_categories_closed
                        THEN 'Requiere cerrar todas las categorías.'
                    ELSE 'Publicación de resultados disponible.'
                END,
                CASE WHEN v_round_closed OR v_all_categories_published THEN
                    (SELECT max(p.published_at)
                       FROM public.tournament_round_category_publications p
                      WHERE p.tournament_round_id=r.id
                        AND p.publication_status='PUBLISHED')
                     ELSE NULL END
            );

            UPDATE public.tournament_workflow_nodes
               SET previous_code='ROUND_RESULTS_PUBLICATION',
                   updated_at=now()
             WHERE tournament_id=p_tournament_id
               AND tournament_round_id=r.id
               AND scope='ROUND'
               AND code='ROUND_COMPETITIVE_CLOSE';
        ELSE
            -- Si el torneo no tiene formalización por categoría configurada,
            -- no se inventan pasos intermedios.
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
    END LOOP;

    SELECT count(*) INTO v_nodes
      FROM public.tournament_workflow_nodes
     WHERE tournament_id=p_tournament_id;

    RETURN jsonb_build_object(
        'ok',true,
        'tournament_id',p_tournament_id,
        'node_count',v_nodes,
        'base',v_base,
        'extended_version',337,
        'results_state_source','PERSISTED_EVIDENCE',
        'reconciled_at',now()
    );
END;
$function$;

COMMENT ON FUNCTION public.reconstruir_workflow_extendido_337(uuid)
IS 'Migración 337: workflow extendido sin ejecutar motores profundos de resultados. Usa evidencia persistida para cierres/publicaciones, corrige secuencias de 335 y deja la validación deportiva en sus RPC existentes.';

-- El contrato público de reconciliación conserva autenticación y permisos.
CREATE OR REPLACE FUNCTION public.reconciliar_workflow_torneo_332(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'Sin permisos para administrar este torneo';
    END IF;

    RETURN public.reconstruir_workflow_extendido_337(p_tournament_id);
END;
$function$;

COMMENT ON FUNCTION public.reconciliar_workflow_torneo_332(uuid)
IS 'Migración 337: conserva autenticación/autorización y delega la reconstrucción materializada al workflow extendido 337.';

COMMIT;
