-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 265
-- Resultados -> Cierre de categoría -> Publicación -> Cierre de ronda
-- ============================================================
--
-- DIAGNÓSTICO
-- El backend ya tenía:
--   - resultados operativos;
--   - cierre competitivo por categoría;
--   - publicación inmutable de resultados de categoría;
--   - cierre competitivo de ronda.
--
-- Pero el contrato no era uniforme:
--   - A-Go-Go TEAM sí obligaba cierres de categoría antes del cierre de ronda;
--   - Stroke Play / Stableford podían cerrar ronda sin formalizar categorías;
--   - ninguna modalidad exigía publicación antes del cierre de ronda;
--   - el Asistente seguía mostrando un único ROUND_COMPETITIVE_CLOSE.
--
-- OBJETIVO
-- Formalizar la secuencia:
--
--   RESULTADOS
--      ->
--   CIERRE DE CATEGORÍA
--      ->
--   PUBLICAR RESULTADOS
--      ->
--   CIERRE DE RONDA
--
-- para Stroke Play individual, Stableford individual y A-Go-Go TEAM.
--
-- COMPATIBILIDAD HISTÓRICA
-- Si una ronda YA tiene cierre competitivo formal, no se crea deuda
-- retroactiva aunque su arquitectura histórica no tenga cierres/publicaciones
-- por categoría. No se modifica ningún dato histórico.
-- ============================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- A. Estado general de formalización de resultados por ronda
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._estado_formalizacion_resultados_ronda_265(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_round record;
    v_operational jsonb;
    v_base_state jsonb;

    v_supported boolean := false;
    v_round_closed boolean := false;

    v_total_categories integer := 0;
    v_ready_categories integer := 0;
    v_closed_categories integer := 0;
    v_published_categories integer := 0;

    v_all_ready boolean := false;
    v_all_closed boolean := false;
    v_all_published boolean := false;

    v_categories jsonb := '[]'::jsonb;
BEGIN
    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION
            'tournament_round_id es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    SELECT
        tr.id,
        tr.tournament_id,
        tr.numero_ronda,
        tr.fecha
      INTO v_round
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id
       AND tr.activo=true;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La ronda indicada no existe o no está activa.'
            USING ERRCODE='22023';
    END IF;

    SELECT EXISTS(
        SELECT 1
        FROM public.tournament_round_competitive_closures rc
        WHERE rc.tournament_round_id=p_tournament_round_id
          AND rc.competitive_status='FINAL'
    )
    INTO v_round_closed;

    v_operational :=
        public.obtener_leaderboard_operativo_ronda(
            p_tournament_round_id
        );

    v_supported :=
        COALESCE(
            (v_operational->>'supported')::boolean,
            false
        );

    IF NOT v_supported THEN
        RETURN jsonb_build_object(
            'applicable',false,
            'supported',false,
            'roundClosed',v_round_closed,
            'tournamentRoundId',p_tournament_round_id,
            'roundNumber',v_round.numero_ronda,
            'scoringEngine',
                v_operational#>>'{round,scoringEngine}',
            'participationType',
                v_operational#>>'{round,participationType}',
            'totalCategories',0,
            'readyCategories',0,
            'closedCategories',0,
            'publishedCategories',0,
            'allCategoriesReady',false,
            'allCategoriesClosed',false,
            'allCategoriesPublished',false,
            'categories','[]'::jsonb
        );
    END IF;

    -- Estado competitivo previo a formalización.
    -- Se usa directamente el pre249 para evitar dependencia circular con
    -- obtener_estado_cierre_competitivo_ronda().
    v_base_state :=
        public._obtener_estado_cierre_competitivo_ronda_pre249(
            p_tournament_round_id
        );

    -- Ronda históricamente cerrada: la etapa completa no debe reabrirse
    -- por requisitos introducidos posteriormente.
    IF v_round_closed THEN
        SELECT
            count(*)::integer,
            count(*)::integer,
            count(*)::integer,
            count(*)::integer,
            COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'tournamentCategoryId',
                            NULLIF(c->>'tournamentCategoryId','')::uuid,
                        'categoryCode',c->>'categoryCode',
                        'categoryName',c->>'categoryName',
                        'competitiveReady',true,
                        'formallyClosed',true,
                        'published',true,
                        'grandfatheredByRoundClosure',true
                    )
                    ORDER BY
                        NULLIF(c->>'categoryDisplayOrder','')::integer
                            NULLS LAST,
                        c->>'categoryName'
                ),
                '[]'::jsonb
            )
        INTO
            v_total_categories,
            v_ready_categories,
            v_closed_categories,
            v_published_categories,
            v_categories
        FROM jsonb_array_elements(
            COALESCE(v_operational->'categories','[]'::jsonb)
        ) c;

        RETURN jsonb_build_object(
            'applicable',true,
            'supported',true,
            'roundClosed',true,
            'grandfatheredByRoundClosure',true,
            'tournamentRoundId',p_tournament_round_id,
            'roundNumber',v_round.numero_ronda,
            'scoringEngine',
                v_operational#>>'{round,scoringEngine}',
            'participationType',
                v_operational#>>'{round,participationType}',
            'baseCompetitiveStatus',
                v_base_state#>>'{status,competitiveStatus}',
            'totalCategories',v_total_categories,
            'readyCategories',v_ready_categories,
            'closedCategories',v_closed_categories,
            'publishedCategories',v_published_categories,
            'allCategoriesReady',true,
            'allCategoriesClosed',true,
            'allCategoriesPublished',true,
            'categories',v_categories
        );
    END IF;

    WITH category_base AS (
        SELECT
            NULLIF(c->>'tournamentCategoryId','')::uuid
                AS tournament_category_id,
            c->>'categoryCode' AS category_code,
            c->>'categoryName' AS category_name,
            NULLIF(c->>'categoryDisplayOrder','')::integer
                AS category_display_order,

            COALESCE(
                NULLIF(c#>>'{summary,totalParticipants}','')::integer,
                0
            ) AS total_participants,

            COALESCE(
                NULLIF(c#>>'{summary,unresolvedParticipants}','')::integer,
                0
            ) AS unresolved_participants

        FROM jsonb_array_elements(
            COALESCE(v_operational->'categories','[]'::jsonb)
        ) c
    ),
    pending_ties AS (
        SELECT
            NULLIF(g->>'tournamentCategoryId','')::uuid
                AS tournament_category_id,
            count(*)::integer AS pending_tie_groups
        FROM jsonb_array_elements(
            COALESCE(v_base_state->'pendingTiebreaks','[]'::jsonb)
        ) g
        GROUP BY
            NULLIF(g->>'tournamentCategoryId','')::uuid
    ),
    state AS (
        SELECT
            cb.*,
            COALESCE(pt.pending_tie_groups,0)
                AS pending_tie_groups,

            cl.id AS closure_id,
            cl.competitive_status AS closure_status,
            cl.closed_at,

            pub.id AS publication_id,
            pub.publication_status,
            pub.published_at,

            (
                cb.total_participants>0
                AND cb.unresolved_participants=0
                AND COALESCE(pt.pending_tie_groups,0)=0
            ) AS competitive_ready,

            (
                cl.id IS NOT NULL
                AND cl.competitive_status='FINAL'
            ) AS formally_closed,

            (
                pub.id IS NOT NULL
                AND pub.publication_status='PUBLISHED'
            ) AS published

        FROM category_base cb

        LEFT JOIN pending_ties pt
          ON pt.tournament_category_id
             IS NOT DISTINCT FROM cb.tournament_category_id

        LEFT JOIN public.tournament_round_category_competitive_closures cl
          ON cl.tournament_round_id=p_tournament_round_id
         AND cl.tournament_category_id
             IS NOT DISTINCT FROM cb.tournament_category_id

        LEFT JOIN public.tournament_round_category_publications pub
          ON pub.tournament_round_id=p_tournament_round_id
         AND pub.tournament_category_id
             IS NOT DISTINCT FROM cb.tournament_category_id
         AND pub.publication_status='PUBLISHED'
    )
    SELECT
        count(*)::integer,
        count(*) FILTER(
            WHERE competitive_ready
        )::integer,
        count(*) FILTER(
            WHERE formally_closed
        )::integer,
        count(*) FILTER(
            WHERE published
        )::integer,
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'tournamentCategoryId',tournament_category_id,
                    'categoryCode',category_code,
                    'categoryName',category_name,
                    'totalParticipants',total_participants,
                    'unresolvedParticipants',unresolved_participants,
                    'pendingTieGroups',pending_tie_groups,
                    'competitiveReady',competitive_ready,
                    'formallyClosed',formally_closed,
                    'closureId',closure_id,
                    'closureStatus',closure_status,
                    'closedAt',closed_at,
                    'published',published,
                    'publicationId',publication_id,
                    'publicationStatus',publication_status,
                    'publishedAt',published_at
                )
                ORDER BY
                    category_display_order NULLS LAST,
                    category_name NULLS LAST
            ),
            '[]'::jsonb
        )
    INTO
        v_total_categories,
        v_ready_categories,
        v_closed_categories,
        v_published_categories,
        v_categories
    FROM state;

    v_all_ready :=
        v_total_categories>0
        AND v_ready_categories=v_total_categories;

    v_all_closed :=
        v_total_categories>0
        AND v_closed_categories=v_total_categories;

    v_all_published :=
        v_total_categories>0
        AND v_published_categories=v_total_categories;

    RETURN jsonb_build_object(
        'applicable',true,
        'supported',true,
        'roundClosed',false,
        'grandfatheredByRoundClosure',false,
        'tournamentRoundId',p_tournament_round_id,
        'roundNumber',v_round.numero_ronda,
        'scoringEngine',
            v_operational#>>'{round,scoringEngine}',
        'participationType',
            v_operational#>>'{round,participationType}',
        'baseCompetitiveStatus',
            v_base_state#>>'{status,competitiveStatus}',
        'totalCategories',v_total_categories,
        'readyCategories',v_ready_categories,
        'closedCategories',v_closed_categories,
        'publishedCategories',v_published_categories,
        'allCategoriesReady',v_all_ready,
        'allCategoriesClosed',v_all_closed,
        'allCategoriesPublished',v_all_published,
        'categories',v_categories
    );
END;
$function$;

COMMENT ON FUNCTION
public._estado_formalizacion_resultados_ronda_265(uuid)
IS
'M265: estado formal agregado de Resultados -> Cierre categoría -> Publicación -> Cierre ronda para motores soportados.';

REVOKE ALL
ON FUNCTION public._estado_formalizacion_resultados_ronda_265(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._estado_formalizacion_resultados_ronda_265(uuid)
TO postgres, service_role;

-- ---------------------------------------------------------------------------
-- B. Estado público del cierre competitivo
-- Generaliza cierres de categoría y agrega publicación como requisito.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_estado_cierre_competitivo_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base jsonb;
    v_formal jsonb;

    v_applicable boolean := false;
    v_round_closed boolean := false;

    v_all_closed boolean := false;
    v_all_published boolean := false;

    v_base_status text;
BEGIN
    v_base :=
        public._obtener_estado_cierre_competitivo_ronda_pre249(
            p_tournament_round_id
        );

    v_formal :=
        public._estado_formalizacion_resultados_ronda_265(
            p_tournament_round_id
        );

    v_applicable :=
        COALESCE(
            (v_formal->>'applicable')::boolean,
            false
        );

    IF NOT v_applicable THEN
        RETURN v_base;
    END IF;

    v_round_closed :=
        COALESCE(
            (v_formal->>'roundClosed')::boolean,
            false
        );

    v_all_closed :=
        COALESCE(
            (v_formal->>'allCategoriesClosed')::boolean,
            false
        );

    v_all_published :=
        COALESCE(
            (v_formal->>'allCategoriesPublished')::boolean,
            false
        );

    v_base_status :=
        v_base#>>'{status,competitiveStatus}';

    v_base :=
        jsonb_set(
            v_base,
            '{formalization}',
            v_formal,
            true
        );

    v_base :=
        jsonb_set(
            v_base,
            '{status,categoryClosuresReady}',
            to_jsonb(v_all_closed),
            true
        );

    v_base :=
        jsonb_set(
            v_base,
            '{status,publicationsReady}',
            to_jsonb(v_all_published),
            true
        );

    -- Una ronda que ya tiene cierre formal permanece FINAL.
    IF v_round_closed THEN
        v_base :=
            jsonb_set(
                v_base,
                '{status,competitiveStatus}',
                to_jsonb('FINAL'::text),
                true
            );

        v_base :=
            jsonb_set(
                v_base,
                '{status,competitivelyClosed}',
                'true'::jsonb,
                true
            );

        RETURN v_base;
    END IF;

    -- Resultados y desempates resueltos, pero faltan cierres por categoría.
    IF v_base_status='FINAL' AND NOT v_all_closed THEN
        v_base :=
            jsonb_set(
                v_base,
                '{status,competitiveStatus}',
                to_jsonb('CATEGORIES_PENDING'::text),
                true
            );

        v_base :=
            jsonb_set(
                v_base,
                '{status,competitivelyClosed}',
                'false'::jsonb,
                true
            );

        RETURN v_base;
    END IF;

    -- Categorías cerradas, pero falta publicar una o más.
    IF v_base_status='FINAL'
       AND v_all_closed
       AND NOT v_all_published
    THEN
        v_base :=
            jsonb_set(
                v_base,
                '{status,competitiveStatus}',
                to_jsonb('PUBLICATIONS_PENDING'::text),
                true
            );

        v_base :=
            jsonb_set(
                v_base,
                '{status,competitivelyClosed}',
                'false'::jsonb,
                true
            );

        RETURN v_base;
    END IF;

    RETURN v_base;
END;
$function$;

COMMENT ON FUNCTION public.obtener_estado_cierre_competitivo_ronda(uuid)
IS
'M265: cierre de ronda exige resultados resueltos, cierres formales de todas las categorías y publicación de todas las categorías.';

-- ---------------------------------------------------------------------------
-- C. Cierre de ronda: preservar operación existente y agregar gate publicación
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cerrar_ronda_competitiva(
    p_tournament_round_id uuid,
    p_notas text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_round_number integer;
    v_round_date date;
    v_tournament_status public.estatus_torneo;
    v_admin_id uuid;
    v_state jsonb;
    v_competitive_status text;
    v_closure_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    SELECT
        tr.tournament_id,
        tr.numero_ronda,
        tr.fecha,
        t.estatus
      INTO
        v_tournament_id,
        v_round_number,
        v_round_date,
        v_tournament_status
      FROM public.tournament_rounds tr
      JOIN public.tournaments t
        ON t.id=tr.tournament_id
     WHERE tr.id=p_tournament_round_id
       AND tr.activo=true
     FOR UPDATE OF tr,t;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda indicada no existe o no está activa.'
            USING ERRCODE='22023';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(
            auth.uid(),
            v_tournament_id
        )
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden cerrar competitivamente la ronda.'
            USING ERRCODE='42501';
    END IF;

    -- Idempotencia antes de exigir estado EN CURSO.
    SELECT c.id
      INTO v_closure_id
      FROM public.tournament_round_competitive_closures c
     WHERE c.tournament_round_id=p_tournament_round_id;

    IF v_closure_id IS NOT NULL THEN
        RETURN public.obtener_cierre_formal_ronda(
            p_tournament_round_id
        );
    END IF;

    IF v_tournament_status <> 'en_curso'::public.estatus_torneo THEN
        RAISE EXCEPTION
            'La ronda sólo puede cerrarse formalmente cuando el torneo está EN CURSO. Estado actual: %.',
            v_tournament_status
            USING ERRCODE='23514';
    END IF;

    PERFORM public._bloquear_salida_ronda(
        p_tournament_round_id
    );

    v_state :=
        public.obtener_estado_cierre_competitivo_ronda(
            p_tournament_round_id
        );

    v_competitive_status :=
        v_state#>>'{status,competitiveStatus}';

    IF v_competitive_status='CATEGORIES_PENDING' THEN
        RAISE EXCEPTION
            'La ronda todavía no puede cerrarse: faltan cierres formales de categoría.'
            USING ERRCODE='23514',
                  DETAIL=COALESCE(
                      (v_state->'formalization')::text,
                      v_state::text
                  ),
                  HINT=
                      'Cierra formalmente todas las categorías antes de cerrar la ronda.';
    END IF;

    IF v_competitive_status='PUBLICATIONS_PENDING' THEN
        RAISE EXCEPTION
            'La ronda todavía no puede cerrarse: faltan publicaciones de resultados por categoría.'
            USING ERRCODE='23514',
                  DETAIL=COALESCE(
                      (v_state->'formalization')::text,
                      v_state::text
                  ),
                  HINT=
                      'Publica los resultados de todas las categorías cerradas antes de cerrar la ronda.';
    END IF;

    IF v_competitive_status IS DISTINCT FROM 'FINAL' THEN
        RAISE EXCEPTION
            'La ronda todavía no puede cerrarse competitivamente.'
            USING ERRCODE='23514',
                  DETAIL=v_state::text,
                  HINT=
                      'Todas las tarjetas y desempates deben estar resueltos antes de formalizar resultados.';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id=auth.uid()
       AND au.activo=true
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No se encontró el usuario administrativo autenticado.'
            USING ERRCODE='42501';
    END IF;

    INSERT INTO public.tournament_round_competitive_closures(
        tournament_id,
        tournament_round_id,
        round_number,
        round_date,
        competitive_status,
        closure_snapshot,
        closed_by_admin_user_id,
        notes
    )
    VALUES(
        v_tournament_id,
        p_tournament_round_id,
        v_round_number,
        v_round_date,
        'FINAL',
        v_state,
        v_admin_id,
        NULLIF(btrim(COALESCE(p_notas,'')),'')
    )
    RETURNING id
    INTO v_closure_id;

    RETURN public.obtener_cierre_formal_ronda(
        p_tournament_round_id
    );
END;
$function$;

COMMENT ON FUNCTION public.cerrar_ronda_competitiva(uuid,text)
IS
'M265: cierre formal exige Resultados -> Cierres de categoría -> Publicaciones -> Cierre de ronda.';

-- ---------------------------------------------------------------------------
-- D. Asistente v18
-- Reemplaza ROUND_COMPETITIVE_CLOSE por cuatro etapas explícitas.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._obtener_asistente_operativo_torneo_v18_265(
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
    v_final_steps jsonb := '[]'::jsonb;

    v_elem jsonb;
    v_state jsonb;
    v_formal jsonb;

    v_round_id uuid;
    v_round_number integer;

    v_competitive_status text;
    v_round_closed boolean := false;

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
    v_result :=
        public._obtener_asistente_operativo_torneo_v17_264(
            p_tournament_id
        );

    v_source_steps :=
        COALESCE(v_result->'steps','[]'::jsonb);

    FOR v_elem IN
        SELECT elem
        FROM jsonb_array_elements(v_source_steps) x(elem)
    LOOP
        IF v_elem->>'code'<>'ROUND_COMPETITIVE_CLOSE' THEN
            v_final_steps :=
                v_final_steps || jsonb_build_array(v_elem);
            CONTINUE;
        END IF;

        v_round_id :=
            NULLIF(v_elem->>'roundId','')::uuid;

        v_round_number :=
            NULLIF(v_elem->>'roundNumber','')::integer;

        v_state :=
            public.obtener_estado_cierre_competitivo_ronda(
                v_round_id
            );

        v_formal :=
            COALESCE(
                v_state->'formalization',
                public._estado_formalizacion_resultados_ronda_265(
                    v_round_id
                )
            );

        v_competitive_status :=
            v_state#>>'{status,competitiveStatus}';

        v_round_closed :=
            COALESCE(
                (v_formal->>'roundClosed')::boolean,
                false
            );

        v_categories_closed :=
            COALESCE(
                (v_formal->>'allCategoriesClosed')::boolean,
                false
            );

        v_publications_complete :=
            COALESCE(
                (v_formal->>'allCategoriesPublished')::boolean,
                false
            );

        v_total_categories :=
            COALESCE(
                (v_formal->>'totalCategories')::integer,
                0
            );

        v_closed_categories :=
            COALESCE(
                (v_formal->>'closedCategories')::integer,
                0
            );

        v_published_categories :=
            COALESCE(
                (v_formal->>'publishedCategories')::integer,
                0
            );

        -- Si ya existe cierre formal de ronda, todas estas etapas son
        -- históricas COMPLETE y no se crea deuda retroactiva.
        v_results_complete :=
            v_round_closed
            OR v_competitive_status IN(
                'FINAL',
                'CATEGORIES_PENDING',
                'PUBLICATIONS_PENDING'
            );

        v_original_actionable :=
            COALESCE(
                (v_elem#>>'{availability,actionable}')::boolean,
                true
            );

        v_original_waiting_for :=
            NULLIF(
                v_elem#>>'{availability,waitingFor}',
                ''
            );

        -- ---------------------------------------------------------------
        -- 1. RESULTADOS
        -- ---------------------------------------------------------------
        v_results_step :=
            jsonb_build_object(
                'code','ROUND_RESULTS',
                'scope','ROUND',
                'roundId',v_round_id,
                'roundNumber',v_round_number,
                'title',format(
                    'Ronda %s · Resultados',
                    v_round_number
                ),
                'status',
                    CASE
                        WHEN v_results_complete THEN 'COMPLETE'
                        ELSE 'PENDING'
                    END,
                'message',
                    CASE
                        WHEN v_results_complete THEN
                            format(
                                'Los resultados y desempates de la ronda %s están resueltos.',
                                v_round_number
                            )
                        ELSE
                            format(
                                'Los resultados de la ronda %s todavía son provisionales o tienen desempates pendientes.',
                                v_round_number
                            )
                    END,
                'recommendation',
                    CASE
                        WHEN v_results_complete THEN NULL
                        WHEN NOT v_original_actionable THEN
                            'Completa primero el requisito operativo anterior.'
                        ELSE
                            'Revisa resultados, participantes no resueltos y desempates pendientes.'
                    END,
                'details',jsonb_build_object(
                    'competitiveState',v_state
                ),
                'action',
                    CASE
                        WHEN v_results_complete
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
                        WHEN v_results_complete THEN
                            jsonb_build_object(
                                'actionable',false,
                                'state','COMPLETE',
                                'waitingFor',NULL
                            )
                        WHEN NOT v_original_actionable THEN
                            jsonb_build_object(
                                'actionable',false,
                                'state','WAITING',
                                'waitingFor',
                                    COALESCE(
                                        v_original_waiting_for,
                                        'PREVIOUS_REQUIREMENT'
                                    )
                            )
                        ELSE
                            jsonb_build_object(
                                'actionable',true,
                                'state','AVAILABLE',
                                'waitingFor',NULL
                            )
                    END
            );

        -- ---------------------------------------------------------------
        -- 2. CIERRE DE CATEGORÍA
        -- ---------------------------------------------------------------
        v_categories_step :=
            jsonb_build_object(
                'code','ROUND_CATEGORY_CLOSURE',
                'scope','ROUND',
                'roundId',v_round_id,
                'roundNumber',v_round_number,
                'title',format(
                    'Ronda %s · Cierre de categoría',
                    v_round_number
                ),
                'status',
                    CASE
                        WHEN v_round_closed
                          OR v_categories_closed
                            THEN 'COMPLETE'
                        ELSE 'PENDING'
                    END,
                'message',
                    CASE
                        WHEN v_round_closed THEN
                            format(
                                'La etapa de cierre por categoría de la ronda %s ya fue superada históricamente.',
                                v_round_number
                            )
                        WHEN v_categories_closed THEN
                            format(
                                'Las %s categoría(s) de la ronda %s están cerradas formalmente.',
                                v_total_categories,
                                v_round_number
                            )
                        WHEN v_results_complete THEN
                            format(
                                'La ronda %s tiene %s de %s categoría(s) cerradas formalmente.',
                                v_round_number,
                                v_closed_categories,
                                v_total_categories
                            )
                        ELSE
                            format(
                                'El cierre de categorías de la ronda %s espera a que los resultados queden resueltos.',
                                v_round_number
                            )
                    END,
                'recommendation',
                    CASE
                        WHEN v_round_closed
                          OR v_categories_closed THEN NULL
                        WHEN NOT v_results_complete THEN
                            'Completa primero los resultados y desempates.'
                        ELSE
                            'Cierra formalmente cada categoría que esté lista.'
                    END,
                'details',v_formal,
                'action',
                    CASE
                        WHEN v_round_closed
                          OR v_categories_closed
                          OR NOT v_results_complete
                            THEN NULL
                        ELSE jsonb_build_object(
                            'label',
                                CASE
                                    WHEN v_total_categories-v_closed_categories=1
                                        THEN 'Cerrar categoría'
                                    ELSE 'Cerrar categorías'
                                END,
                            'target','resultados',
                            'roundId',v_round_id
                        )
                    END,
                'requiredRole','TOURNAMENT_OPERATOR',
                'availability',
                    CASE
                        WHEN v_round_closed
                          OR v_categories_closed THEN
                            jsonb_build_object(
                                'actionable',false,
                                'state','COMPLETE',
                                'waitingFor',NULL
                            )
                        WHEN NOT v_results_complete THEN
                            jsonb_build_object(
                                'actionable',false,
                                'state','WAITING',
                                'waitingFor','ROUND_RESULTS'
                            )
                        ELSE
                            jsonb_build_object(
                                'actionable',true,
                                'state','AVAILABLE',
                                'waitingFor',NULL
                            )
                    END
            );

        -- ---------------------------------------------------------------
        -- 3. PUBLICACIÓN
        -- ---------------------------------------------------------------
        v_publication_step :=
            jsonb_build_object(
                'code','ROUND_RESULTS_PUBLICATION',
                'scope','ROUND',
                'roundId',v_round_id,
                'roundNumber',v_round_number,
                'title',format(
                    'Ronda %s · Publicar resultados',
                    v_round_number
                ),
                'status',
                    CASE
                        WHEN v_round_closed
                          OR v_publications_complete
                            THEN 'COMPLETE'
                        ELSE 'PENDING'
                    END,
                'message',
                    CASE
                        WHEN v_round_closed THEN
                            format(
                                'La etapa de publicación de la ronda %s ya fue superada históricamente.',
                                v_round_number
                            )
                        WHEN v_publications_complete THEN
                            format(
                                'Los resultados de las %s categoría(s) de la ronda %s están publicados.',
                                v_total_categories,
                                v_round_number
                            )
                        WHEN v_categories_closed THEN
                            format(
                                'La ronda %s tiene %s de %s categoría(s) publicadas.',
                                v_round_number,
                                v_published_categories,
                                v_total_categories
                            )
                        ELSE
                            format(
                                'La publicación de la ronda %s espera al cierre formal de categorías.',
                                v_round_number
                            )
                    END,
                'recommendation',
                    CASE
                        WHEN v_round_closed
                          OR v_publications_complete THEN NULL
                        WHEN NOT v_categories_closed THEN
                            'Completa primero los cierres formales de categoría.'
                        ELSE
                            'Publica los resultados cerrados de cada categoría.'
                    END,
                'details',v_formal,
                'action',
                    CASE
                        WHEN v_round_closed
                          OR v_publications_complete
                          OR NOT v_categories_closed
                            THEN NULL
                        ELSE jsonb_build_object(
                            'label','Publicar resultados',
                            'target','resultados',
                            'roundId',v_round_id
                        )
                    END,
                'requiredRole','TOURNAMENT_OPERATOR',
                'availability',
                    CASE
                        WHEN v_round_closed
                          OR v_publications_complete THEN
                            jsonb_build_object(
                                'actionable',false,
                                'state','COMPLETE',
                                'waitingFor',NULL
                            )
                        WHEN NOT v_categories_closed THEN
                            jsonb_build_object(
                                'actionable',false,
                                'state','WAITING',
                                'waitingFor','ROUND_CATEGORY_CLOSURE'
                            )
                        ELSE
                            jsonb_build_object(
                                'actionable',true,
                                'state','AVAILABLE',
                                'waitingFor',NULL
                            )
                    END
            );

        -- ---------------------------------------------------------------
        -- 4. CIERRE DE RONDA
        -- ---------------------------------------------------------------
        v_round_close_step :=
            jsonb_build_object(
                'code','ROUND_COMPETITIVE_CLOSE',
                'scope','ROUND',
                'roundId',v_round_id,
                'roundNumber',v_round_number,
                'title',format(
                    'Ronda %s · Cierre de ronda',
                    v_round_number
                ),
                'status',
                    CASE
                        WHEN v_round_closed THEN 'COMPLETE'
                        ELSE 'PENDING'
                    END,
                'message',
                    CASE
                        WHEN v_round_closed THEN
                            format(
                                'La ronda %s está cerrada competitivamente.',
                                v_round_number
                            )
                        WHEN v_publications_complete THEN
                            format(
                                'La ronda %s está lista para su cierre competitivo.',
                                v_round_number
                            )
                        ELSE
                            format(
                                'El cierre de la ronda %s espera a la publicación completa de resultados.',
                                v_round_number
                            )
                    END,
                'recommendation',
                    CASE
                        WHEN v_round_closed THEN NULL
                        WHEN NOT v_publications_complete THEN
                            'Completa primero la publicación de resultados de todas las categorías.'
                        ELSE
                            'Cierra formalmente la ronda.'
                    END,
                'details',jsonb_build_object(
                    'competitiveState',v_state,
                    'formalization',v_formal
                ),
                'action',
                    CASE
                        WHEN v_round_closed
                          OR NOT v_publications_complete
                            THEN NULL
                        ELSE jsonb_build_object(
                            'label','Cerrar ronda',
                            'target','cierre-ronda',
                            'roundId',v_round_id
                        )
                    END,
                'requiredRole','TOURNAMENT_OPERATOR',
                'availability',
                    CASE
                        WHEN v_round_closed THEN
                            jsonb_build_object(
                                'actionable',false,
                                'state','COMPLETE',
                                'waitingFor',NULL
                            )
                        WHEN NOT v_publications_complete THEN
                            jsonb_build_object(
                                'actionable',false,
                                'state','WAITING',
                                'waitingFor','ROUND_RESULTS_PUBLICATION'
                            )
                        ELSE
                            jsonb_build_object(
                                'actionable',true,
                                'state','AVAILABLE',
                                'waitingFor',NULL
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

    v_result :=
        jsonb_set(
            v_result,
            '{steps}',
            v_final_steps,
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{blockers}',
            v_blockers,
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{summary,blockingIssues}',
            to_jsonb(jsonb_array_length(v_blockers)),
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{progress,completed}',
            to_jsonb(v_completed),
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{progress,total}',
            to_jsonb(v_total),
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{progress,percent}',
            to_jsonb(
                CASE
                    WHEN v_total=0 THEN 0
                    ELSE round(
                        100.0*v_completed/v_total,
                        0
                    )
                END
            ),
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{nextAction}',
            COALESCE(v_next_action,'null'::jsonb),
            true
        );

    RETURN
        v_result || jsonb_build_object(
            'schemaVersion',18
        );
END;
$function$;

COMMENT ON FUNCTION
public._obtener_asistente_operativo_torneo_v18_265(uuid)
IS
'M265: separa Resultados, Cierre de categoría, Publicación y Cierre de ronda para todas las modalidades competitivas soportadas.';

REVOKE ALL
ON FUNCTION public._obtener_asistente_operativo_torneo_v18_265(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._obtener_asistente_operativo_torneo_v18_265(uuid)
TO postgres, service_role;

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
        public._obtener_asistente_operativo_torneo_v18_265(
            p_tournament_id
        );
END;
$function$;

COMMENT ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
IS
'M265: Asistente schemaVersion 18; Resultados -> Cierre categoría -> Publicación -> Cierre ronda.';

COMMIT;
