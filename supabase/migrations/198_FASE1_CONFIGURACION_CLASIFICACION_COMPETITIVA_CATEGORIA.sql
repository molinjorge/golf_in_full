-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 198 FASE 1
-- CONFIGURACIÓN EXPLÍCITA DE CLASIFICACIÓN COMPETITIVA POR CATEGORÍA
-- ============================================================================
-- Objetivo
--   1) Dejar de crear automáticamente GROSS + NETO para cada nueva categoría.
--   2) Permitir que el organizador defina por categoría: GROSS, NETO o AMBOS.
--   3) Mantener la clasificación como condición competitiva congelable.
--   4) No modificar torneos ya congelados ni sus snapshots históricos.
--
-- Esta fase NO cambia todavía leaderboard/desempates/cierre/publicación.
-- Ese consumo corresponde a la fase siguiente.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 01. Retirar la inicialización automática GROSS + NETO
-- --------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_inicializar_clasificaciones_categoria_torneo
ON public.tournament_categories;

DROP FUNCTION IF EXISTS public.inicializar_clasificaciones_categoria_torneo();

-- --------------------------------------------------------------------------
-- 02. Lectura de clasificación configurada por categoría
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_clasificaciones_categorias_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid;
    v_club_id uuid;
    v_allowed boolean := false;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT t.club_id
      INTO v_club_id
      FROM public.tournaments t
     WHERE t.id = p_tournament_id;

    IF v_club_id IS NULL THEN
        RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='P0002';
    END IF;

    v_allowed :=
           public.is_superadmin(v_user_id)
        OR public.is_tournament_organizer(v_user_id, p_tournament_id)
        OR public.is_club_admin(v_user_id, v_club_id);

    IF NOT v_allowed THEN
        RAISE EXCEPTION 'No tienes permisos para consultar esta configuración.'
            USING ERRCODE='42501';
    END IF;

    RETURN jsonb_build_object(
        'schemaVersion', 1,
        'tournamentId', p_tournament_id,
        'frozen', EXISTS (
            SELECT 1
              FROM public.tournament_condition_freezes f
             WHERE f.tournament_id = p_tournament_id
        ),
        'categories', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'tournamentCategoryId', tc.id,
                    'categoryId', c.id,
                    'code', c.codigo,
                    'name', c.nombre,
                    'displayOrder', c.display_order,
                    'resultTypes', COALESCE(x.result_types, '[]'::jsonb),
                    'classificationMode',
                        CASE
                            WHEN x.has_gross AND x.has_neto THEN 'BOTH'
                            WHEN x.has_gross THEN 'GROSS'
                            WHEN x.has_neto THEN 'NET'
                            ELSE 'UNCONFIGURED'
                        END,
                    'configured', COALESCE(x.count_types, 0) > 0
                )
                ORDER BY c.display_order NULLS LAST, c.nombre, tc.id
            )
            FROM public.tournament_categories tc
            JOIN public.categories c
              ON c.id = tc.category_id
            LEFT JOIN LATERAL (
                SELECT
                    jsonb_agg(cc.tipo_resultado::text ORDER BY cc.tipo_resultado::text)
                        AS result_types,
                    bool_or(cc.tipo_resultado='gross'::public.tipo_resultado_desempate)
                        AS has_gross,
                    bool_or(cc.tipo_resultado='neto'::public.tipo_resultado_desempate)
                        AS has_neto,
                    count(*)::integer AS count_types
                FROM public.tournament_category_classifications cc
                WHERE cc.tournament_id = tc.tournament_id
                  AND cc.tournament_category_id = tc.id
            ) x ON true
            WHERE tc.tournament_id = p_tournament_id
        ), '[]'::jsonb)
    );
END;
$function$;

-- --------------------------------------------------------------------------
-- 03. Escritura controlada de la clasificación competitiva
--     p_classification_mode: GROSS | NET | BOTH
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.configurar_clasificacion_categoria_torneo(
    p_tournament_category_id uuid,
    p_classification_mode text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid;
    v_tournament_id uuid;
    v_club_id uuid;
    v_category_name text;
    v_mode text;
    v_allowed boolean := false;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    v_mode := upper(trim(COALESCE(p_classification_mode, '')));

    IF v_mode NOT IN ('GROSS', 'NET', 'BOTH') THEN
        RAISE EXCEPTION
            'Clasificación inválida. Usa GROSS, NET o BOTH.'
            USING ERRCODE='22023';
    END IF;

    SELECT tc.tournament_id, t.club_id, c.nombre
      INTO v_tournament_id, v_club_id, v_category_name
      FROM public.tournament_categories tc
      JOIN public.tournaments t
        ON t.id = tc.tournament_id
      JOIN public.categories c
        ON c.id = tc.category_id
     WHERE tc.id = p_tournament_category_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La categoría de torneo indicada no existe.'
            USING ERRCODE='P0002';
    END IF;

    v_allowed :=
           public.is_superadmin(v_user_id)
        OR public.is_tournament_organizer(v_user_id, v_tournament_id)
        OR public.is_club_admin(v_user_id, v_club_id);

    IF NOT v_allowed THEN
        RAISE EXCEPTION 'No tienes permisos para modificar esta configuración.'
            USING ERRCODE='42501';
    END IF;

    -- Bloqueo explícito. Además se conserva el trigger existente de protección
    -- sobre tournament_category_classifications como defensa adicional.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_condition_freezes f
         WHERE f.tournament_id = v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No se puede modificar la clasificación porque las condiciones del torneo ya fueron congeladas.'
            USING ERRCODE='55000';
    END IF;

    DELETE FROM public.tournament_category_classifications cc
     WHERE cc.tournament_id = v_tournament_id
       AND cc.tournament_category_id = p_tournament_category_id;

    IF v_mode IN ('GROSS', 'BOTH') THEN
        INSERT INTO public.tournament_category_classifications(
            tournament_id,
            tournament_category_id,
            tipo_resultado,
            created_by
        )
        VALUES (
            v_tournament_id,
            p_tournament_category_id,
            'gross'::public.tipo_resultado_desempate,
            v_user_id
        );
    END IF;

    IF v_mode IN ('NET', 'BOTH') THEN
        INSERT INTO public.tournament_category_classifications(
            tournament_id,
            tournament_category_id,
            tipo_resultado,
            created_by
        )
        VALUES (
            v_tournament_id,
            p_tournament_category_id,
            'neto'::public.tipo_resultado_desempate,
            v_user_id
        );
    END IF;

    RETURN jsonb_build_object(
        'schemaVersion', 1,
        'tournamentId', v_tournament_id,
        'tournamentCategoryId', p_tournament_category_id,
        'categoryName', v_category_name,
        'classificationMode', v_mode,
        'resultTypes',
            CASE v_mode
                WHEN 'GROSS' THEN jsonb_build_array('gross')
                WHEN 'NET' THEN jsonb_build_array('neto')
                ELSE jsonb_build_array('gross', 'neto')
            END,
        'configured', true
    );
END;
$function$;

-- --------------------------------------------------------------------------
-- 04. Mensaje de previsualización de congelamiento
--     La regla ya era correcta: exige al menos una clasificación por categoría.
--     Sólo se corrige la terminología para no implicar que ambas son obligatorias.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.previsualizar_congelamiento_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base jsonb;
    v_extra_errors jsonb;
    v_extra_count integer;
BEGIN
    v_base :=
        public._previsualizar_congelamiento_torneo_core_1861a(
            p_tournament_id
        );

    SELECT
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'code', 'category_classification_missing',
                    'message',
                        format(
                            'La categoría %s no tiene clasificación competitiva definida (Gross, Neto o ambas).',
                            c.nombre
                        ),
                    'tournamentCategoryId', tc.id
                )
                ORDER BY c.display_order NULLS LAST, c.nombre, tc.id
            ),
            '[]'::jsonb
        ),
        count(*)::integer
      INTO v_extra_errors, v_extra_count
      FROM public.tournament_categories tc
      JOIN public.categories c
        ON c.id = tc.category_id
     WHERE tc.tournament_id = p_tournament_id
       AND NOT EXISTS (
            SELECT 1
            FROM public.tournament_category_classifications cc
            WHERE cc.tournament_category_id = tc.id
              AND cc.tournament_id = tc.tournament_id
       );

    RETURN
        v_base
        || jsonb_build_object(
            'ready',
                COALESCE((v_base->>'ready')::boolean, false)
                AND v_extra_count = 0,
            'errors',
                COALESCE(v_base->'errors', '[]'::jsonb)
                || v_extra_errors,
            'counts',
                COALESCE(v_base->'counts', '{}'::jsonb)
                || jsonb_build_object(
                    'errors',
                        COALESCE(
                            (v_base #>> '{counts,errors}')::integer,
                            0
                        ) + v_extra_count
                )
        );
END;
$function$;

-- --------------------------------------------------------------------------
-- 05. Permisos de RPC
-- --------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.obtener_clasificaciones_categorias_torneo(uuid)
FROM PUBLIC;
REVOKE ALL ON FUNCTION public.configurar_clasificacion_categoria_torneo(uuid, text)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.obtener_clasificaciones_categorias_torneo(uuid)
TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.configurar_clasificacion_categoria_torneo(uuid, text)
TO authenticated, service_role;

COMMIT;
