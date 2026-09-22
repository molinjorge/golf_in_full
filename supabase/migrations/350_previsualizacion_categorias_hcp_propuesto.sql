-- MIGRACIÓN 350 — PREVISUALIZACIÓN DE CATEGORÍAS PARA HCP PROPUESTO
-- TEE CENTRAL / GOLF IN FULL
--
-- Objetivo:
-- Permitir al frontend previsualizar, SIN persistir cambios, las categorías elegibles
-- para un HCP torneo propuesto. Corrige el flujo posterior a la Migración 349:
-- si la RPC 349 rechaza la categoría actual, su transacción hace rollback y una consulta
-- normal volvería a ver el HCP anterior.
--
-- Esta migración:
--   * NO modifica datos de inscripciones.
--   * NO modifica public.players.
--   * NO cambia categorías ni marcas.
--   * Centraliza la regla de elegibilidad en un helper parametrizado por HCP.
--   * Mantiene _categorias_elegibles_jugador con el comportamiento efectivo de 349.
--   * Agrega una RPC de previsualización que devuelve categorías y la marca estándar
--     activa que correspondería a cada una en el campo del torneo.
--
-- IMPORTANTE: ejecutar manualmente. ChatGPT no ejecuta esta migración.

BEGIN;

-- ============================================================================
-- 01. HELPER CANÓNICO DE ELEGIBILIDAD PARA UN HCP DADO
-- ============================================================================

CREATE OR REPLACE FUNCTION public._categorias_elegibles_jugador_hcp_350(
    p_tournament_id uuid,
    p_player_id uuid,
    p_handicap numeric
)
RETURNS TABLE(
    tournament_category_id uuid,
    category_id uuid,
    codigo text,
    nombre text,
    genero text,
    handicap_minimo numeric,
    handicap_maximo numeric,
    edad_minima integer,
    edad_maxima integer,
    categoria_estandar_marca categoria_marca_salida,
    display_order integer,
    tipo_elegibilidad text,
    es_categoria_natural boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_sexo text;
    v_edad integer;
    v_fecha_inicio date;
BEGIN
    SELECT p.sexo::text, t.fecha_inicio
      INTO v_sexo, v_fecha_inicio
      FROM public.players p
      CROSS JOIN public.tournaments t
     WHERE p.id = p_player_id
       AND t.id = p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el jugador o el torneo indicado.'
            USING ERRCODE = '22023';
    END IF;

    SELECT date_part('year', age(v_fecha_inicio, p.fecha_nacimiento))::integer
      INTO v_edad
      FROM public.players p
     WHERE p.id = p_player_id;

    RETURN QUERY
    WITH categorias AS (
        SELECT
            tc.id AS tournament_category_id,
            c.id AS category_id,
            c.codigo,
            c.nombre,
            c.genero,
            COALESCE(tc.handicap_minimo, c.handicap_minimo) AS hcp_min,
            COALESCE(tc.handicap_maximo, c.handicap_maximo) AS hcp_max,
            c.edad_minima,
            c.edad_maxima,
            c.categoria_estandar_marca,
            c.display_order,
            (
                COALESCE(tc.handicap_minimo, c.handicap_minimo) IS NOT NULL
                OR COALESCE(tc.handicap_maximo, c.handicap_maximo) IS NOT NULL
            ) AS tiene_rango_hcp,
            (
                c.edad_minima IS NOT NULL
                OR c.edad_maxima IS NOT NULL
            ) AS tiene_rango_edad
        FROM public.tournament_categories tc
        JOIN public.categories c
          ON c.id = tc.category_id
        WHERE tc.tournament_id = p_tournament_id
          AND (
                c.genero IS NULL
                OR c.genero = v_sexo
          )
    ),
    categoria_natural AS (
        SELECT
            c.tournament_category_id,
            c.hcp_min,
            c.hcp_max
        FROM categorias c
        WHERE c.tiene_rango_hcp
          AND p_handicap IS NOT NULL
          AND (c.hcp_min IS NULL OR p_handicap >= c.hcp_min)
          AND (c.hcp_max IS NULL OR p_handicap <= c.hcp_max)
        ORDER BY
            CASE WHEN c.genero = v_sexo THEN 0 ELSE 1 END,
            COALESCE(c.hcp_min, -9999::numeric),
            COALESCE(c.hcp_max, 9999::numeric),
            c.display_order NULLS LAST,
            c.nombre
        LIMIT 1
    )
    SELECT
        c.tournament_category_id,
        c.category_id,
        c.codigo,
        c.nombre,
        c.genero,
        c.hcp_min,
        c.hcp_max,
        c.edad_minima,
        c.edad_maxima,
        c.categoria_estandar_marca,
        c.display_order,
        CASE
            WHEN c.tiene_rango_hcp
                 AND c.tournament_category_id = n.tournament_category_id
                THEN 'NATURAL'
            WHEN c.tiene_rango_hcp THEN 'SUPERIOR'
            WHEN c.tiene_rango_edad THEN 'EDAD'
            ELSE 'ABIERTA'
        END AS tipo_elegibilidad,
        (c.tournament_category_id = n.tournament_category_id) AS es_categoria_natural
    FROM categorias c
    LEFT JOIN categoria_natural n ON true
    WHERE
        (
            -- Categoría natural + categorías superiores permitidas.
            c.tiene_rango_hcp
            AND n.tournament_category_id IS NOT NULL
            AND COALESCE(c.hcp_min, -9999::numeric)
                <= COALESCE(n.hcp_min, -9999::numeric)
        )
        OR
        (
            -- Categorías por edad.
            NOT c.tiene_rango_hcp
            AND c.tiene_rango_edad
            AND v_edad IS NOT NULL
            AND (c.edad_minima IS NULL OR v_edad >= c.edad_minima)
            AND (c.edad_maxima IS NULL OR v_edad <= c.edad_maxima)
        )
        OR
        (
            -- Categorías abiertas.
            NOT c.tiene_rango_hcp
            AND NOT c.tiene_rango_edad
        )
    ORDER BY
        c.display_order NULLS LAST,
        CASE
            WHEN c.tiene_rango_hcp THEN 0
            WHEN c.tiene_rango_edad THEN 1
            ELSE 2
        END,
        COALESCE(c.hcp_min, -9999::numeric),
        c.nombre;
END;
$function$;

REVOKE ALL ON FUNCTION public._categorias_elegibles_jugador_hcp_350(uuid,uuid,numeric)
FROM PUBLIC;

-- ============================================================================
-- 02. MANTENER EL HELPER HISTÓRICO USANDO EL HCP EFECTIVO DE LA 349
--     Se preservan firma, permisos y semántica pública.
-- ============================================================================

CREATE OR REPLACE FUNCTION public._categorias_elegibles_jugador(
    p_tournament_id uuid,
    p_player_id uuid
)
RETURNS TABLE(
    tournament_category_id uuid,
    category_id uuid,
    codigo text,
    nombre text,
    genero text,
    handicap_minimo numeric,
    handicap_maximo numeric,
    edad_minima integer,
    edad_maxima integer,
    categoria_estandar_marca categoria_marca_salida,
    display_order integer,
    tipo_elegibilidad text,
    es_categoria_natural boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_auth_user_id uuid;
    v_player_auth_user_id uuid;
    v_handicap numeric;
    v_role text;
BEGIN
    v_auth_user_id := auth.uid();
    v_role := auth.role();

    SELECT
        p.auth_user_id,
        COALESCE(
            (
                SELECT tr.handicap_torneo
                FROM public.tournament_registrations tr
                WHERE tr.tournament_id = p_tournament_id
                  AND tr.player_id = p_player_id
                  AND tr.activo = true
                ORDER BY tr.created_at DESC, tr.id
                LIMIT 1
            ),
            p.handicap_verificado,
            p.handicap_declarado
        )
    INTO
        v_player_auth_user_id,
        v_handicap
    FROM public.players p
    CROSS JOIN public.tournaments t
    WHERE p.id = p_player_id
      AND t.id = p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el jugador o el torneo indicado.'
            USING ERRCODE = '22023';
    END IF;

    -- Misma protección histórica.
    IF v_role IS NOT NULL
       AND v_role <> 'service_role'
       AND (
            v_auth_user_id IS NULL
            OR v_player_auth_user_id IS DISTINCT FROM v_auth_user_id
       )
       AND NOT COALESCE(public.is_active_admin(v_auth_user_id), false)
    THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar las categorías elegibles de este jugador.'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT *
    FROM public._categorias_elegibles_jugador_hcp_350(
        p_tournament_id,
        p_player_id,
        v_handicap
    );
END;
$function$;

-- ============================================================================
-- 03. RPC DE PREVISUALIZACIÓN SIN PERSISTENCIA
--
-- Devuelve:
--   - HCP perfil y HCP propuesto
--   - categoría/marca actuales
--   - si la categoría actual sigue siendo elegible
--   - categorías elegibles para EL HCP PROPUESTO
--   - marca estándar activa que correspondería a cada categoría
--
-- No ejecuta UPDATE/INSERT/DELETE.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.previsualizar_categorias_hcp_torneo_350(
    p_tournament_registration_id uuid,
    p_handicap_propuesto numeric
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_reg public.tournament_registrations%ROWTYPE;
    v_handicap_perfil numeric;
    v_campo_id uuid;
    v_categoria_actual_nombre text;
    v_marca_actual_nombre text;
    v_categoria_actual_elegible boolean;
    v_categories jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_reg
      FROM public.tournament_registrations
     WHERE id = p_tournament_registration_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe esa inscripción.' USING ERRCODE = '22023';
    END IF;

    IF NOT v_reg.activo THEN
        RAISE EXCEPTION 'La inscripción no está activa.' USING ERRCODE = '22023';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(), v_reg.tournament_id)
        OR EXISTS (
            SELECT 1
            FROM public.tournaments t
            WHERE t.id = v_reg.tournament_id
              AND public.is_club_admin(auth.uid(), t.club_id)
        )
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para previsualizar el HCP competitivo de este torneo.'
            USING ERRCODE = '42501';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = v_reg.tournament_id
    ) THEN
        RAISE EXCEPTION
            'No se puede previsualizar un nuevo HCP competitivo después del Freeze.'
            USING ERRCODE = '55000';
    END IF;

    IF p_handicap_propuesto IS NULL
       OR p_handicap_propuesto < -10.0
       OR p_handicap_propuesto > 54.0
    THEN
        RAISE EXCEPTION
            'El HCP torneo debe estar entre -10.0 y 54.0.'
            USING ERRCODE = '22023';
    END IF;

    SELECT
        COALESCE(p.handicap_verificado, p.handicap_declarado),
        t.campo_golf_id
      INTO
        v_handicap_perfil,
        v_campo_id
      FROM public.players p
      JOIN public.tournaments t ON t.id = v_reg.tournament_id
     WHERE p.id = v_reg.player_id;

    SELECT c.nombre
      INTO v_categoria_actual_nombre
      FROM public.tournament_categories tc
      JOIN public.categories c ON c.id = tc.category_id
     WHERE tc.id = v_reg.tournament_category_id;

    SELECT ms.nombre
      INTO v_marca_actual_nombre
      FROM public.marcas_salida ms
     WHERE ms.id = v_reg.marca_salida_id;

    SELECT EXISTS (
        SELECT 1
        FROM public._categorias_elegibles_jugador_hcp_350(
            v_reg.tournament_id,
            v_reg.player_id,
            p_handicap_propuesto
        ) e
        WHERE e.tournament_category_id = v_reg.tournament_category_id
    )
    INTO v_categoria_actual_elegible;

    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'tournamentCategoryId', e.tournament_category_id,
                'categoryId', e.category_id,
                'codigo', e.codigo,
                'nombre', e.nombre,
                'genero', e.genero,
                'handicapMinimo', e.handicap_minimo,
                'handicapMaximo', e.handicap_maximo,
                'edadMinima', e.edad_minima,
                'edadMaxima', e.edad_maxima,
                'tipoElegibilidad', e.tipo_elegibilidad,
                'esCategoriaNatural', e.es_categoria_natural,
                'categoriaEstandarMarca', e.categoria_estandar_marca::text,
                'marcaSalidaId', tee.id,
                'marcaSalidaNombre', tee.nombre,
                'marcaSalidaValida', (tee.id IS NOT NULL),
                'esCategoriaActual', (e.tournament_category_id = v_reg.tournament_category_id)
            )
            ORDER BY e.display_order NULLS LAST, e.nombre
        ),
        '[]'::jsonb
    )
    INTO v_categories
    FROM public._categorias_elegibles_jugador_hcp_350(
        v_reg.tournament_id,
        v_reg.player_id,
        p_handicap_propuesto
    ) e
    LEFT JOIN LATERAL (
        SELECT ms.id, ms.nombre
        FROM public.marcas_salida ms
        WHERE ms.campo_golf_id = v_campo_id
          AND ms.categoria_estandar = e.categoria_estandar_marca
          AND ms.activo = true
        ORDER BY ms.id
        LIMIT 1
    ) tee ON true;

    RETURN jsonb_build_object(
        'ok', true,
        'tournamentRegistrationId', v_reg.id,
        'tournamentId', v_reg.tournament_id,
        'playerId', v_reg.player_id,
        'handicapPerfil', v_handicap_perfil,
        'handicapTorneoActual', v_reg.handicap_torneo,
        'handicapPropuesto', p_handicap_propuesto,
        'categoriaActualId', v_reg.tournament_category_id,
        'categoriaActualNombre', v_categoria_actual_nombre,
        'marcaActualId', v_reg.marca_salida_id,
        'marcaActualNombre', v_marca_actual_nombre,
        'categoriaActualElegible', v_categoria_actual_elegible,
        'categories', v_categories
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.previsualizar_categorias_hcp_torneo_350(uuid,numeric)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.previsualizar_categorias_hcp_torneo_350(uuid,numeric)
TO authenticated;

COMMIT;
