-- ============================================================================
-- 175_categorias_elegibles_inscripcion.sql
-- TEE CENTRAL / GOLF IN FULL
--
-- REGLA:
--   - En inscripción individual, el jugador puede elegir:
--       a) su categoría regular natural por hándicap;
--       b) cualquier categoría regular superior (menor hándicap);
--       c) la categoría por edad que le corresponda (ej. Senior), si existe;
--       d) categorías abiertas sin restricción de género/criterio.
--   - Nunca puede elegir una categoría regular inferior.
--   - Nunca puede elegir una categoría de género incompatible.
--   - Se respetan overrides de hándicap de tournament_categories.
--   - Una selección superior válida NO se reasigna a la categoría natural.
--
-- ALCANCE:
--   - Inscripción individual.
--   - Torneos multicategoría sin tournament_franjas_handicap.
--   - Torneos por equipos conservan su lógica actual.
--   - Torneos de categoría única con franjas conservan su lógica actual.
--
-- NO MODIFICA:
--   - inscripciones históricas;
--   - categorías existentes;
--   - rangos;
--   - snapshots;
--   - resultados;
--   - leaderboard.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. FUNCIÓN BASE DE ELEGIBILIDAD
-- ============================================================================

CREATE OR REPLACE FUNCTION public._categorias_elegibles_jugador(
    p_tournament_id uuid,
    p_player_id uuid
)
RETURNS TABLE (
    tournament_category_id uuid,
    category_id uuid,
    codigo text,
    nombre text,
    genero text,
    handicap_minimo numeric,
    handicap_maximo numeric,
    edad_minima integer,
    edad_maxima integer,
    categoria_estandar_marca public.categoria_marca_salida,
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
    v_handicap numeric(4,1);
    v_sexo text;
    v_edad integer;
    v_fecha_inicio date;
    v_role text;
BEGIN
    v_auth_user_id := auth.uid();
    v_role := auth.role();

    SELECT
        p.auth_user_id,
        COALESCE(p.handicap_verificado, p.handicap_declarado),
        p.sexo::text,
        t.fecha_inicio
    INTO
        v_player_auth_user_id,
        v_handicap,
        v_sexo,
        v_fecha_inicio
    FROM public.players p
    CROSS JOIN public.tournaments t
    WHERE p.id = p_player_id
      AND t.id = p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No existe el jugador o el torneo indicado.'
            USING ERRCODE = '22023';
    END IF;

    -- Protege el helper frente a consultas arbitrarias desde cliente.
    -- Se permite:
    --   - el propio jugador;
    --   - un administrador activo;
    --   - service_role;
    --   - ejecución directa desde SQL Editor (sin JWT).
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

    SELECT
        date_part(
            'year',
            age(v_fecha_inicio, p.fecha_nacimiento)
        )::integer
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
          AND v_handicap IS NOT NULL
          AND (
                c.hcp_min IS NULL
                OR v_handicap >= c.hcp_min
          )
          AND (
                c.hcp_max IS NULL
                OR v_handicap <= c.hcp_max
          )
        ORDER BY
            CASE
                WHEN c.genero = v_sexo THEN 0
                ELSE 1
            END,
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
            WHEN c.tiene_rango_hcp
                THEN 'SUPERIOR'
            WHEN c.tiene_rango_edad
                THEN 'EDAD'
            ELSE 'ABIERTA'
        END AS tipo_elegibilidad,
        (
            c.tournament_category_id = n.tournament_category_id
        ) AS es_categoria_natural
    FROM categorias c
    LEFT JOIN categoria_natural n
      ON true
    WHERE
        (
            -- Categorías regulares:
            -- natural + las que comienzan en un hándicap menor.
            c.tiene_rango_hcp
            AND n.tournament_category_id IS NOT NULL
            AND COALESCE(c.hcp_min, -9999::numeric)
                <= COALESCE(n.hcp_min, -9999::numeric)
        )
        OR
        (
            -- Categorías por edad (Senior u otras):
            -- solo si la edad del jugador cae en el rango.
            NOT c.tiene_rango_hcp
            AND c.tiene_rango_edad
            AND v_edad IS NOT NULL
            AND (
                c.edad_minima IS NULL
                OR v_edad >= c.edad_minima
            )
            AND (
                c.edad_maxima IS NULL
                OR v_edad <= c.edad_maxima
            )
        )
        OR
        (
            -- Categoría abierta sin rango de hándicap ni edad.
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

REVOKE ALL
ON FUNCTION public._categorias_elegibles_jugador(uuid, uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public._categorias_elegibles_jugador(uuid, uuid)
TO authenticated, service_role;


-- ============================================================================
-- 02. RPC PARA EL JUGADOR AUTENTICADO
--     El frontend no envía player_id.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_mis_categorias_elegibles_inscripcion(
    p_tournament_id uuid
)
RETURNS TABLE (
    tournament_category_id uuid,
    category_id uuid,
    codigo text,
    nombre text,
    genero text,
    handicap_minimo numeric,
    handicap_maximo numeric,
    edad_minima integer,
    edad_maxima integer,
    categoria_estandar_marca public.categoria_marca_salida,
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
    v_player_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Debes iniciar sesión para consultar tus categorías disponibles.'
            USING ERRCODE = '42501';
    END IF;

    SELECT p.id
      INTO v_player_id
      FROM public.players p
     WHERE p.auth_user_id = auth.uid()
       AND p.activo = true
     LIMIT 1;

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION
            'No existe un perfil de jugador activo vinculado a tu cuenta.'
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    SELECT *
    FROM public._categorias_elegibles_jugador(
        p_tournament_id,
        v_player_id
    );
END;
$function$;

REVOKE ALL
ON FUNCTION public.obtener_mis_categorias_elegibles_inscripcion(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.obtener_mis_categorias_elegibles_inscripcion(uuid)
TO authenticated;


-- ============================================================================
-- 03. ACTUALIZAR RESOLUCIÓN DE CATEGORÍA Y MARCA
--
-- Cambio principal:
--   - si el jugador selecciona una categoría individual válida,
--     SE RESPETA;
--   - ya no se fuerza de regreso a la categoría natural;
--   - una categoría inferior / género incompatible / Senior fuera de edad
--     se rechaza.
--
-- Se conserva:
--   - lógica de equipos;
--   - categoría única con franjas;
--   - Damas rojas en categoría única;
--   - Senior doradas en categoría única;
--   - asignación de marca desde categoría elegida;
--   - asignación automática si llega sin categoría.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.resolver_categoria_y_marca()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_handicap_jugador numeric(4,1);
    v_edad_jugador integer;
    v_sexo_jugador text;
    v_edad_senior integer;
    v_campo_id uuid;
    v_hay_franjas boolean;
    v_categoria_correcta_id uuid;
    v_categoria_estandar public.categoria_marca_salida;
    v_categoria_unica_id uuid;

    v_categoria_elegida_nombre text;
    v_categoria_elegida_genero text;
    v_categoria_elegida_hcp_min numeric;
    v_categoria_elegida_hcp_max numeric;
    v_categoria_elegida_edad_min integer;
    v_categoria_elegida_edad_max integer;

    v_categoria_natural_id uuid;
    v_categoria_natural_nombre text;
BEGIN
    SELECT t.campo_golf_id
      INTO v_campo_id
      FROM public.tournaments t
     WHERE t.id = NEW.tournament_id;

    -- --------------------------------------------------------
    -- EQUIPOS
    -- La categoría viene del equipo por trigger anterior.
    -- No se valida contra el hándicap individual.
    -- --------------------------------------------------------
    IF NEW.tournament_team_id IS NOT NULL
       AND NEW.tournament_category_id IS NOT NULL
    THEN
        SELECT c.categoria_estandar_marca
          INTO v_categoria_estandar
          FROM public.tournament_categories tc
          JOIN public.categories c
            ON c.id = tc.category_id
         WHERE tc.id = NEW.tournament_category_id;
    END IF;

    IF NEW.tournament_team_id IS NULL
       OR v_categoria_estandar IS NULL
    THEN
        SELECT
            COALESCE(
                p.handicap_verificado,
                p.handicap_declarado
            ),
            p.sexo::text
        INTO
            v_handicap_jugador,
            v_sexo_jugador
        FROM public.players p
        WHERE p.id = NEW.player_id;

        SELECT
            date_part(
                'year',
                age(t.fecha_inicio, p.fecha_nacimiento)
            )::integer
        INTO v_edad_jugador
        FROM public.players p
        CROSS JOIN public.tournaments t
        WHERE p.id = NEW.player_id
          AND t.id = NEW.tournament_id;

        SELECT EXISTS (
            SELECT 1
            FROM public.tournament_franjas_handicap fh
            WHERE fh.tournament_id = NEW.tournament_id
        )
        INTO v_hay_franjas;

        -- ----------------------------------------------------
        -- CATEGORÍA ÚNICA / FRANJAS
        -- Se conserva sin cambios conceptuales.
        -- ----------------------------------------------------
        IF v_hay_franjas THEN

            IF v_sexo_jugador = 'F' THEN
                v_categoria_estandar := 'rojo';

            ELSE
                SELECT COALESCE(
                    (
                        SELECT t.edad_senior_categoria_unica
                        FROM public.tournaments t
                        WHERE t.id = NEW.tournament_id
                    ),
                    (
                        SELECT min(c.edad_minima)::integer
                        FROM public.categories c
                        WHERE c.codigo LIKE 'SENIOR%'
                    )
                )
                INTO v_edad_senior;

                IF v_edad_senior IS NOT NULL
                   AND v_edad_jugador IS NOT NULL
                   AND v_edad_jugador >= v_edad_senior
                THEN
                    v_categoria_estandar := 'dorado';

                ELSE
                    IF v_handicap_jugador IS NULL THEN
                        RAISE EXCEPTION
                            'No se puede asignar marca de salida: el jugador no tiene hándicap capturado.';
                    END IF;

                    SELECT fh.categoria_estandar
                      INTO v_categoria_estandar
                      FROM public.tournament_franjas_handicap fh
                     WHERE fh.tournament_id = NEW.tournament_id
                       AND fh.handicap_desde <= v_handicap_jugador
                       AND (
                            fh.handicap_hasta IS NULL
                            OR v_handicap_jugador <= fh.handicap_hasta
                       )
                     LIMIT 1;

                    IF v_categoria_estandar IS NULL THEN
                        RAISE EXCEPTION
                            'El hándicap del jugador (%) no cae en ninguna franja definida para este torneo.',
                            v_handicap_jugador;
                    END IF;
                END IF;
            END IF;

            IF NEW.tournament_category_id IS NULL THEN
                SELECT tc.id
                  INTO v_categoria_unica_id
                  FROM public.tournament_categories tc
                 WHERE tc.tournament_id = NEW.tournament_id
                 LIMIT 1;

                IF v_categoria_unica_id IS NOT NULL THEN
                    NEW.tournament_category_id := v_categoria_unica_id;
                END IF;
            END IF;

        -- ----------------------------------------------------
        -- SIN CATEGORÍA DE PARTIDA
        -- Conserva la asignación automática de categoría natural.
        -- ----------------------------------------------------
        ELSIF NEW.tournament_category_id IS NULL THEN

            IF v_handicap_jugador IS NULL THEN
                RAISE EXCEPTION
                    'No se puede asignar categoría: el jugador no tiene hándicap capturado.';
            END IF;

            SELECT
                tc.id,
                c.categoria_estandar_marca
            INTO
                v_categoria_correcta_id,
                v_categoria_estandar
            FROM public.tournament_categories tc
            JOIN public.categories c
              ON c.id = tc.category_id
            WHERE tc.tournament_id = NEW.tournament_id
              AND (
                    c.genero IS NULL
                    OR c.genero = v_sexo_jugador
              )
              AND (
                    COALESCE(tc.handicap_minimo, c.handicap_minimo) IS NOT NULL
                    OR COALESCE(tc.handicap_maximo, c.handicap_maximo) IS NOT NULL
              )
              AND (
                    COALESCE(tc.handicap_minimo, c.handicap_minimo) IS NULL
                    OR v_handicap_jugador >= COALESCE(tc.handicap_minimo, c.handicap_minimo)
              )
              AND (
                    COALESCE(tc.handicap_maximo, c.handicap_maximo) IS NULL
                    OR v_handicap_jugador <= COALESCE(tc.handicap_maximo, c.handicap_maximo)
              )
            ORDER BY
                CASE
                    WHEN c.genero = v_sexo_jugador THEN 0
                    ELSE 1
                END,
                COALESCE(tc.handicap_minimo, c.handicap_minimo) NULLS FIRST,
                c.display_order NULLS LAST,
                c.nombre
            LIMIT 1;

            IF v_categoria_correcta_id IS NULL THEN
                RAISE EXCEPTION
                    'El hándicap del jugador (%) no corresponde a ninguna categoría configurada en este torneo. Avisa al organizador antes de continuar.',
                    v_handicap_jugador;
            END IF;

            NEW.tournament_category_id := v_categoria_correcta_id;
            NEW.categoria_reasignada := true;

        -- ----------------------------------------------------
        -- INSCRIPCIÓN INDIVIDUAL CON CATEGORÍA ELEGIDA
        -- NUEVA REGLA DE LA MIGRACIÓN 175
        -- ----------------------------------------------------
        ELSIF NEW.tournament_team_id IS NULL THEN

            SELECT
                c.nombre,
                c.genero,
                COALESCE(tc.handicap_minimo, c.handicap_minimo),
                COALESCE(tc.handicap_maximo, c.handicap_maximo),
                c.edad_minima,
                c.edad_maxima
            INTO
                v_categoria_elegida_nombre,
                v_categoria_elegida_genero,
                v_categoria_elegida_hcp_min,
                v_categoria_elegida_hcp_max,
                v_categoria_elegida_edad_min,
                v_categoria_elegida_edad_max
            FROM public.tournament_categories tc
            JOIN public.categories c
              ON c.id = tc.category_id
            WHERE tc.id = NEW.tournament_category_id
              AND tc.tournament_id = NEW.tournament_id;

            IF NOT FOUND THEN
                RAISE EXCEPTION
                    'La categoría elegida no pertenece a este torneo.';
            END IF;

            -- Género incompatible.
            IF v_categoria_elegida_genero IS NOT NULL
               AND v_categoria_elegida_genero <> v_sexo_jugador
            THEN
                RAISE EXCEPTION
                    'La categoría "%" no está disponible para el sexo del jugador.',
                    v_categoria_elegida_nombre;
            END IF;

            -- Valida contra la misma fuente que consumirá el frontend.
            IF NOT EXISTS (
                SELECT 1
                FROM public._categorias_elegibles_jugador(
                    NEW.tournament_id,
                    NEW.player_id
                ) e
                WHERE e.tournament_category_id = NEW.tournament_category_id
            )
            THEN
                -- Categoría por edad fuera del rango.
                IF v_categoria_elegida_hcp_min IS NULL
                   AND v_categoria_elegida_hcp_max IS NULL
                   AND (
                        v_categoria_elegida_edad_min IS NOT NULL
                        OR v_categoria_elegida_edad_max IS NOT NULL
                   )
                THEN
                    RAISE EXCEPTION
                        'La edad del jugador (%) no corresponde a la categoría "%".',
                        v_edad_jugador,
                        v_categoria_elegida_nombre;
                END IF;

                -- Categoría regular inferior.
                IF v_handicap_jugador IS NULL THEN
                    RAISE EXCEPTION
                        'No se puede validar la categoría: el jugador no tiene hándicap capturado.';
                END IF;

                SELECT
                    tc.id,
                    c.nombre
                INTO
                    v_categoria_natural_id,
                    v_categoria_natural_nombre
                FROM public.tournament_categories tc
                JOIN public.categories c
                  ON c.id = tc.category_id
                WHERE tc.tournament_id = NEW.tournament_id
                  AND (
                        c.genero IS NULL
                        OR c.genero = v_sexo_jugador
                  )
                  AND (
                        COALESCE(tc.handicap_minimo, c.handicap_minimo) IS NOT NULL
                        OR COALESCE(tc.handicap_maximo, c.handicap_maximo) IS NOT NULL
                  )
                  AND (
                        COALESCE(tc.handicap_minimo, c.handicap_minimo) IS NULL
                        OR v_handicap_jugador >= COALESCE(tc.handicap_minimo, c.handicap_minimo)
                  )
                  AND (
                        COALESCE(tc.handicap_maximo, c.handicap_maximo) IS NULL
                        OR v_handicap_jugador <= COALESCE(tc.handicap_maximo, c.handicap_maximo)
                  )
                ORDER BY
                    CASE
                        WHEN c.genero = v_sexo_jugador THEN 0
                        ELSE 1
                    END,
                    COALESCE(tc.handicap_minimo, c.handicap_minimo) NULLS FIRST,
                    c.display_order NULLS LAST,
                    c.nombre
                LIMIT 1;

                IF v_categoria_natural_id IS NULL THEN
                    RAISE EXCEPTION
                        'El hándicap del jugador (%) no corresponde a ninguna categoría regular configurada para su sexo en este torneo.',
                        v_handicap_jugador;
                END IF;

                RAISE EXCEPTION
                    'No puedes seleccionar una categoría inferior. Con hándicap %, tu categoría regular es "%" y solo puedes elegir esa categoría o una superior (de menor hándicap).',
                    v_handicap_jugador,
                    v_categoria_natural_nombre;
            END IF;

            -- La selección es válida: se respeta exactamente.
            NEW.categoria_reasignada := false;

            SELECT c.categoria_estandar_marca
              INTO v_categoria_estandar
              FROM public.tournament_categories tc
              JOIN public.categories c
                ON c.id = tc.category_id
             WHERE tc.id = NEW.tournament_category_id;
        END IF;
    END IF;

    -- --------------------------------------------------------
    -- ASIGNACIÓN DE MARCA DE SALIDA
    -- --------------------------------------------------------
    IF v_categoria_estandar IS NOT NULL THEN
        SELECT ms.id
          INTO NEW.marca_salida_id
          FROM public.marcas_salida ms
         WHERE ms.campo_golf_id = v_campo_id
           AND ms.categoria_estandar = v_categoria_estandar
           AND ms.activo = true
         LIMIT 1;

        IF NEW.marca_salida_id IS NULL THEN
            RAISE EXCEPTION
                'El campo de este torneo no tiene una marca de salida configurada para la categoría "%". Complétala en el catálogo de campos antes de continuar.',
                v_categoria_estandar;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

COMMIT;
