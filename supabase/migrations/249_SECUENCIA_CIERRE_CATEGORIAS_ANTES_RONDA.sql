-- TEE CENTRAL / GOLF IN FULL
-- Migración 249
-- A-Go-Go TEAM: exigir cierre formal de todas las categorías antes del cierre formal de ronda
-- y alinear el Asistente Operativo con esa secuencia.
--
-- IMPORTANTE: esta migración NO se ejecuta automáticamente.
-- El usuario debe ejecutarla manualmente en Supabase.

BEGIN;

-------------------------------------------------------------------------------
-- 1) Preservar exactamente la implementación vigente del estado de cierre
--    competitivo de ronda antes de envolverla con la regla 249.
-------------------------------------------------------------------------------
DO $do$
DECLARE
    v_definition text;
BEGIN
    IF to_regprocedure('public._obtener_estado_cierre_competitivo_ronda_pre249(uuid)') IS NULL THEN
        SELECT pg_get_functiondef(
            'public.obtener_estado_cierre_competitivo_ronda(uuid)'::regprocedure
        )
        INTO v_definition;

        v_definition := replace(
            v_definition,
            'CREATE OR REPLACE FUNCTION public.obtener_estado_cierre_competitivo_ronda(p_tournament_round_id uuid)',
            'CREATE OR REPLACE FUNCTION public._obtener_estado_cierre_competitivo_ronda_pre249(p_tournament_round_id uuid)'
        );

        EXECUTE v_definition;
    END IF;
END
$do$;

REVOKE ALL ON FUNCTION public._obtener_estado_cierre_competitivo_ronda_pre249(uuid)
FROM PUBLIC, anon, authenticated;

-------------------------------------------------------------------------------
-- 2) Helper interno: estado de cierres formales de categoría para A-Go-Go TEAM.
--    La fuente de categorías es la evidencia oficial emitida de la ronda
--    (tarjetas TEAM + validation units), no el catálogo completo del torneo.
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._estado_cierres_formales_categorias_team_249(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_scoring_engine text;
    v_participation_type text;
BEGIN
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

    IF NOT (
        v_scoring_engine='team_stroke'
        AND v_participation_type='equipo'
    ) THEN
        RETURN jsonb_build_object(
            'applicable', false,
            'scoringEngine', v_scoring_engine,
            'participationType', v_participation_type,
            'totalCategories', 0,
            'closedCategories', 0,
            'pendingCategories', 0,
            'allCategoriesClosed', false,
            'categories', '[]'::jsonb
        );
    END IF;

    RETURN (
        WITH round_categories AS (
            SELECT DISTINCT
                u.tournament_category_id,
                c.codigo AS category_code,
                c.nombre AS category_name,
                c.display_order AS category_display_order
            FROM public.tournament_score_cards sc
            JOIN public.tournament_round_start_validation_units u
              ON u.id=sc.validation_unit_id
             AND u.validation_id=sc.validation_id
            LEFT JOIN public.tournament_categories tc
              ON tc.id=u.tournament_category_id
            LEFT JOIN public.categories c
              ON c.id=tc.category_id
            WHERE sc.tournament_round_id=p_tournament_round_id
              AND sc.status='issued'
              AND sc.unit_type='team'
              AND u.tournament_category_id IS NOT NULL
        ),
        category_state AS (
            SELECT
                rc.*,
                cl.id AS closure_id,
                cl.competitive_status AS closure_status,
                cl.closed_at,
                (cl.id IS NOT NULL) AS formally_closed
            FROM round_categories rc
            LEFT JOIN public.tournament_round_category_competitive_closures cl
              ON cl.tournament_round_id=p_tournament_round_id
             AND cl.tournament_category_id=rc.tournament_category_id
        ),
        summary AS (
            SELECT
                count(*)::integer AS total_categories,
                count(*) FILTER (WHERE formally_closed)::integer AS closed_categories,
                count(*) FILTER (WHERE NOT formally_closed)::integer AS pending_categories
            FROM category_state
        )
        SELECT jsonb_build_object(
            'applicable', true,
            'scoringEngine', 'team_stroke',
            'participationType', 'equipo',
            'totalCategories', s.total_categories,
            'closedCategories', s.closed_categories,
            'pendingCategories', s.pending_categories,
            'allCategoriesClosed',
                (s.total_categories>0 AND s.pending_categories=0),
            'categories', COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'tournamentCategoryId', cs.tournament_category_id,
                        'categoryCode', cs.category_code,
                        'categoryName', cs.category_name,
                        'formallyClosed', cs.formally_closed,
                        'closureId', cs.closure_id,
                        'closureStatus', cs.closure_status,
                        'closedAt', cs.closed_at
                    )
                    ORDER BY cs.category_display_order NULLS LAST,
                             cs.category_name NULLS LAST
                )
                FROM category_state cs
            ), '[]'::jsonb)
        )
        FROM summary s
    );
END;
$function$;

REVOKE ALL ON FUNCTION public._estado_cierres_formales_categorias_team_249(uuid)
FROM PUBLIC, anon, authenticated;

-------------------------------------------------------------------------------
-- 3) Estado común de cierre de ronda.
--    Stroke/Stableford conservan el resultado pre-249 sin cambios.
--    A-Go-Go TEAM sólo llega a FINAL cuando además todas las categorías
--    participantes tienen cierre formal registrado.
-------------------------------------------------------------------------------
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
    v_formal_categories jsonb;
    v_applicable boolean;
    v_all_closed boolean;
    v_base_status text;
BEGIN
    v_base := public._obtener_estado_cierre_competitivo_ronda_pre249(
        p_tournament_round_id
    );

    v_formal_categories :=
        public._estado_cierres_formales_categorias_team_249(
            p_tournament_round_id
        );

    v_applicable := COALESCE(
        (v_formal_categories->>'applicable')::boolean,
        false
    );

    IF NOT v_applicable THEN
        RETURN v_base;
    END IF;

    v_all_closed := COALESCE(
        (v_formal_categories->>'allCategoriesClosed')::boolean,
        false
    );

    v_base_status := v_base #>> '{status,competitiveStatus}';

    v_base := jsonb_set(
        v_base,
        '{formalCategoryClosure}',
        v_formal_categories,
        true
    );

    v_base := jsonb_set(
        v_base,
        '{status,categoryClosuresReady}',
        to_jsonb(v_all_closed),
        true
    );

    -- Resultados/desempates ya están resueltos, pero todavía faltan los
    -- cierres formales por categoría: la ronda NO está lista para cierre.
    IF v_base_status='FINAL' AND NOT v_all_closed THEN
        v_base := jsonb_set(
            v_base,
            '{status,competitiveStatus}',
            to_jsonb('CATEGORIES_PENDING'::text),
            true
        );

        v_base := jsonb_set(
            v_base,
            '{status,competitivelyClosed}',
            'false'::jsonb,
            true
        );
    END IF;

    RETURN v_base;
END;
$function$;

-------------------------------------------------------------------------------
-- 4) Cierre formal de ronda: mensaje/guard explícito para categorías pendientes.
--    La regla general anterior se conserva para cualquier otro estado.
-------------------------------------------------------------------------------
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
            USING ERRCODE = '42501';
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
        ON t.id = tr.tournament_id
     WHERE tr.id = p_tournament_round_id
       AND tr.activo = true
     FOR UPDATE OF tr, t;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda indicada no existe o no está activa.'
            USING ERRCODE = '22023';
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
            USING ERRCODE = '42501';
    END IF;

    IF v_tournament_status <> 'en_curso'::public.estatus_torneo THEN
        RAISE EXCEPTION
            'La ronda sólo puede cerrarse formalmente cuando el torneo está EN CURSO. Estado actual: %.',
            v_tournament_status
            USING ERRCODE = '23514';
    END IF;

    PERFORM public._bloquear_salida_ronda(
        p_tournament_round_id
    );

    SELECT c.id
      INTO v_closure_id
      FROM public.tournament_round_competitive_closures c
     WHERE c.tournament_round_id = p_tournament_round_id;

    IF v_closure_id IS NOT NULL THEN
        RETURN public.obtener_cierre_formal_ronda(
            p_tournament_round_id
        );
    END IF;

    v_state :=
        public.obtener_estado_cierre_competitivo_ronda(
            p_tournament_round_id
        );

    v_competitive_status :=
        v_state #>> '{status,competitiveStatus}';

    IF v_competitive_status='CATEGORIES_PENDING' THEN
        RAISE EXCEPTION
            'La ronda todavía no puede cerrarse: faltan cierres formales de categoría.'
            USING ERRCODE = '23514',
                  DETAIL = COALESCE(
                      (v_state->'formalCategoryClosure')::text,
                      v_state::text
                  ),
                  HINT =
                      'Cierra formalmente todas las categorías de la ronda antes de cerrar la ronda.';
    END IF;

    IF v_competitive_status IS DISTINCT FROM 'FINAL' THEN
        RAISE EXCEPTION
            'La ronda todavía no puede cerrarse competitivamente.'
            USING ERRCODE = '23514',
                  DETAIL = v_state::text,
                  HINT =
                      'Todas las tarjetas deben estar resueltas y, si existen empates, todos los desempates deben estar resueltos.';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo = true
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No se encontró el usuario administrativo autenticado.'
            USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.tournament_round_competitive_closures (
        tournament_id,
        tournament_round_id,
        round_number,
        round_date,
        competitive_status,
        closure_snapshot,
        closed_by_admin_user_id,
        notes
    )
    VALUES (
        v_tournament_id,
        p_tournament_round_id,
        v_round_number,
        v_round_date,
        'FINAL',
        v_state,
        v_admin_id,
        NULLIF(btrim(COALESCE(p_notas, '')), '')
    )
    RETURNING id INTO v_closure_id;

    RETURN public.obtener_cierre_formal_ronda(
        p_tournament_round_id
    );
END;
$function$;

-------------------------------------------------------------------------------
-- 5) Asistente Operativo v10: cuando A-Go-Go tiene resultados/desempates listos
--    pero faltan cierres formales de categoría, el siguiente paso es cerrar
--    categoría(s), no cerrar la ronda.
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._obtener_asistente_operativo_torneo_v10_249(
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
    v_blockers jsonb := '[]'::jsonb;
    v_next_action jsonb := NULL;
    v_elem jsonb;
    v_round_id uuid;
    v_formal_categories jsonb;
    v_pending integer;
    v_total integer;
    v_closed integer;
    v_actionable boolean;
BEGIN
    v_result := public._obtener_asistente_operativo_torneo_v9_246(
        p_tournament_id
    );

    v_source_steps := COALESCE(v_result->'steps','[]'::jsonb);

    FOR v_elem IN
        SELECT elem FROM jsonb_array_elements(v_source_steps) elem
    LOOP
        IF v_elem->>'code'='ROUND_COMPETITIVE_CLOSE'
           AND NULLIF(v_elem->>'roundId','') IS NOT NULL
        THEN
            v_round_id := (v_elem->>'roundId')::uuid;

            v_formal_categories :=
                public._estado_cierres_formales_categorias_team_249(
                    v_round_id
                );

            IF COALESCE(
                (v_formal_categories->>'applicable')::boolean,
                false
            ) THEN
                v_pending := COALESCE(
                    (v_formal_categories->>'pendingCategories')::integer,
                    0
                );
                v_total := COALESCE(
                    (v_formal_categories->>'totalCategories')::integer,
                    0
                );
                v_closed := COALESCE(
                    (v_formal_categories->>'closedCategories')::integer,
                    0
                );
                v_actionable := COALESCE(
                    (v_elem #>> '{availability,actionable}')::boolean,
                    true
                );

                v_elem := jsonb_set(
                    v_elem,
                    '{details}',
                    COALESCE(v_elem->'details','{}'::jsonb)
                    || jsonb_build_object(
                        'formalCategoryClosure',
                        v_formal_categories
                    ),
                    true
                );

                -- Sólo sustituir "Cerrar ronda" cuando competitivamente ya
                -- se llegó al punto de cierre pero faltan cierres formales de
                -- categoría. Si resultados/desempates siguen pendientes, se
                -- conserva el diagnóstico anterior del asistente.
                IF v_pending>0
                   AND (
                       v_elem #>> '{details,competitiveState,status,competitiveStatus}'
                   ) IN ('FINAL','CATEGORIES_PENDING')
                THEN
                    v_elem := v_elem || jsonb_build_object(
                        'status','PENDING',
                        'message',format(
                            'La ronda %s tiene resultados y desempates resueltos, pero faltan cierres formales de categoría.',
                            COALESCE(v_elem->>'roundNumber','?')
                        ),
                        'recommendation',format(
                            'Cierra primero %s de %s categoría(s) pendiente(s) antes de cerrar la ronda.',
                            v_pending,
                            v_total
                        ),
                        'action',CASE WHEN v_actionable THEN jsonb_build_object(
                            'label',CASE WHEN v_pending=1
                                THEN 'Cerrar categoría'
                                ELSE 'Cerrar categorías'
                            END,
                            'target','resultados',
                            'roundId',v_round_id
                        ) ELSE NULL END
                    );
                END IF;
            END IF;
        END IF;

        v_final_steps := v_final_steps || jsonb_build_array(v_elem);
    END LOOP;

    SELECT COALESCE(jsonb_agg(s.elem ORDER BY s.ord),'[]'::jsonb)
      INTO v_blockers
      FROM jsonb_array_elements(v_final_steps)
           WITH ORDINALITY AS s(elem,ord)
     WHERE s.elem->>'status'='BLOCKED'
       AND COALESCE(
           (s.elem #>> '{availability,actionable}')::boolean,
           false
       );

    SELECT s.elem->'action'
      INTO v_next_action
      FROM jsonb_array_elements(v_final_steps)
           WITH ORDINALITY AS s(elem,ord)
     WHERE s.elem->>'status' IN ('BLOCKED','PENDING')
       AND COALESCE(
           (s.elem #>> '{availability,actionable}')::boolean,
           false
       )
       AND s.elem->'action' IS NOT NULL
       AND s.elem->'action'<>'null'::jsonb
     ORDER BY s.ord
     LIMIT 1;

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
        '{nextAction}',
        COALESCE(v_next_action,'null'::jsonb),
        true
    );

    RETURN v_result || jsonb_build_object('schemaVersion',10);
END;
$function$;

REVOKE ALL ON FUNCTION public._obtener_asistente_operativo_torneo_v10_249(uuid)
FROM PUBLIC, anon, authenticated;

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
    RETURN public._obtener_asistente_operativo_torneo_v10_249(
        p_tournament_id
    );
END;
$function$;

COMMIT;
