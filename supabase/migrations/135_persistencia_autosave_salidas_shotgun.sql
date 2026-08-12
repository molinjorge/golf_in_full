-- =====================================================================
-- MIGRACIÓN 135 — PERSISTENCIA / AUTOSAVE DE SALIDAS SHOTGUN
-- GOLF IN FULL
--
-- OBJETIVOS
-- 1. Materializar una sola vez la propuesta inicial de grupos Shotgun.
-- 2. Después, persistir cada movimiento de jugador/equipo de forma
--    transaccional e incremental.
-- 3. No redistribuir terceros.
-- 4. Crear/reactivar el grupo destino cuando la posición no tenga grupo.
-- 5. Dar de baja lógica al grupo origen cuando quede vacío.
-- 6. Permitir sacar una unidad de un grupo para la futura bandeja virtual.
-- 7. Cargar la conformación persistida al volver a entrar.
-- 8. Proteger concurrencia por configuración con advisory lock.
--
-- NO toca el motor de propuesta automática del frontend.
-- =====================================================================

BEGIN;

-- =====================================================================
-- 0. GUARDAS E ÍNDICES DE INTEGRIDAD / RENDIMIENTO
-- =====================================================================

DO $$
DECLARE
    v_duplicados integer;
BEGIN
    SELECT count(*)
      INTO v_duplicados
      FROM (
          SELECT
              tournament_group_id,
              tournament_registration_id
          FROM public.tournament_group_players
          GROUP BY
              tournament_group_id,
              tournament_registration_id
          HAVING count(*) > 1
      ) d;

    IF v_duplicados > 0 THEN
        RAISE EXCEPTION
            'Migración 135 abortada: existen % pares duplicados grupo/inscripción en tournament_group_players.',
            v_duplicados;
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_tournament_group_players_group
    ON public.tournament_group_players (tournament_group_id);

CREATE INDEX IF NOT EXISTS idx_tournament_group_players_registration
    ON public.tournament_group_players (tournament_registration_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_tournament_group_player
    ON public.tournament_group_players (
        tournament_group_id,
        tournament_registration_id
    );


-- =====================================================================
-- 1. HELPER INTERNO — HORA REAL DE SALIDA SHOTGUN
-- =====================================================================

CREATE OR REPLACE FUNCTION public.hora_salida_shotgun(
    p_shotgun_category_hole_id uuid,
    p_posicion text
)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_fecha date;
    v_hora time without time zone;
    v_timezone text;
    v_intervalo_b integer;
    v_salida_doble boolean;
    v_hora_base timestamptz;
    v_posicion text;
BEGIN
    v_posicion := upper(trim(p_posicion));

    IF v_posicion NOT IN ('A', 'B') THEN
        RAISE EXCEPTION 'La posición Shotgun debe ser A o B.';
    END IF;

    SELECT
        tr.fecha,
        trs.hora_salida,
        cg.timezone_id,
        cfg.intervalo_salida_b_minutos,
        sh.salida_doble
      INTO
        v_fecha,
        v_hora,
        v_timezone,
        v_intervalo_b,
        v_salida_doble
      FROM public.tournament_shotgun_category_holes sh
      JOIN public.tournament_shotgun_category_configs cfg
        ON cfg.id = sh.tournament_shotgun_category_config_id
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id
      JOIN public.tournament_round_shifts trs
        ON trs.id = sc.tournament_round_shift_id
      JOIN public.tournament_rounds tr
        ON tr.id = trs.tournament_round_id
      JOIN public.campos_golf cg
        ON cg.id = tr.campo_golf_id
      JOIN public.timezones tz
        ON tz.iana_id = cg.timezone_id
     WHERE sh.id = p_shotgun_category_hole_id
       AND sh.activo = true
       AND cfg.activo = true
       AND sc.activo = true
       AND trs.activo = true
       AND tr.activo = true
       AND cg.activo = true
       AND tz.activo = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No se pudo resolver la fecha, hora o zona horaria de la posición Shotgun.';
    END IF;

    IF v_posicion = 'B' AND v_salida_doble = false THEN
        RAISE EXCEPTION
            'Este hoyo no tiene habilitada salida doble.';
    END IF;

    v_hora_base :=
        (v_fecha + v_hora) AT TIME ZONE v_timezone;

    IF v_posicion = 'B' THEN
        v_hora_base :=
            v_hora_base + make_interval(mins => v_intervalo_b);
    END IF;

    RETURN v_hora_base;
END;
$function$;


-- =====================================================================
-- 2. HELPER INTERNO — OBTENER / REACTIVAR / CREAR GRUPO DESTINO
-- =====================================================================

CREATE OR REPLACE FUNCTION public._grupo_shotgun_destino(
    p_config_id uuid,
    p_shotgun_category_hole_id uuid,
    p_posicion text,
    p_actor_admin_id uuid
)
RETURNS TABLE (
    group_id uuid,
    accion text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_posicion text;
    v_shift_id uuid;
    v_hoyo_id uuid;
    v_numero_hoyo integer;
    v_group_id uuid;
    v_hora timestamptz;
BEGIN
    v_posicion := upper(trim(p_posicion));

    IF v_posicion NOT IN ('A', 'B') THEN
        RAISE EXCEPTION 'La posición Shotgun debe ser A o B.';
    END IF;

    SELECT
        sc.tournament_round_shift_id,
        sh.hoyo_id,
        h.numero_hoyo
      INTO
        v_shift_id,
        v_hoyo_id,
        v_numero_hoyo
      FROM public.tournament_shotgun_category_holes sh
      JOIN public.tournament_shotgun_category_configs cfg
        ON cfg.id = sh.tournament_shotgun_category_config_id
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id
      JOIN public.hoyos h
        ON h.id = sh.hoyo_id
     WHERE sh.id = p_shotgun_category_hole_id
       AND sh.tournament_shotgun_category_config_id = p_config_id
       AND sh.activo = true
       AND cfg.activo = true
       AND sc.activo = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La posición destino no pertenece a la configuración Shotgun activa.';
    END IF;

    -- El helper de hora también valida B/salida_doble.
    v_hora :=
        public.hora_salida_shotgun(
            p_shotgun_category_hole_id,
            v_posicion
        );

    -- 1. Reutilizar grupo activo existente.
    SELECT g.id
      INTO v_group_id
      FROM public.tournament_groups g
     WHERE g.tournament_shotgun_category_hole_id =
           p_shotgun_category_hole_id
       AND g.posicion_salida = v_posicion
       AND g.activo = true
     LIMIT 1;

    IF v_group_id IS NOT NULL THEN
        RETURN QUERY
        SELECT v_group_id, 'existente'::text;
        RETURN;
    END IF;

    -- 2. Reactivar la fila histórica más reciente de esa misma posición,
    --    pero únicamente si está vacía.
    SELECT g.id
      INTO v_group_id
      FROM public.tournament_groups g
     WHERE g.tournament_shotgun_category_hole_id =
           p_shotgun_category_hole_id
       AND g.posicion_salida = v_posicion
       AND g.activo = false
       AND NOT EXISTS (
           SELECT 1
           FROM public.tournament_group_players gp
           WHERE gp.tournament_group_id = g.id
       )
       AND NOT EXISTS (
           SELECT 1
           FROM public.tournament_group_teams gt
           WHERE gt.tournament_group_id = g.id
             AND gt.activo = true
       )
     ORDER BY g.updated_at DESC, g.created_at DESC
     LIMIT 1;

    IF v_group_id IS NOT NULL THEN
        UPDATE public.tournament_groups
           SET activo = true,
               hora_salida = v_hora,
               etiqueta = 'Hoyo ' || v_numero_hoyo::text || '-' || v_posicion,
               fecha_baja = NULL,
               dado_de_baja_por = NULL,
               motivo_baja = NULL
         WHERE id = v_group_id;

        RETURN QUERY
        SELECT v_group_id, 'reactivado'::text;
        RETURN;
    END IF;

    -- 3. Crear un grupo nuevo.
    INSERT INTO public.tournament_groups (
        tournament_round_shift_id,
        hoyo_id,
        hora_salida,
        etiqueta,
        tournament_team_id,
        activo,
        created_by,
        tournament_shotgun_category_hole_id,
        posicion_salida
    )
    VALUES (
        v_shift_id,
        v_hoyo_id,
        v_hora,
        'Hoyo ' || v_numero_hoyo::text || '-' || v_posicion,
        NULL,
        true,
        p_actor_admin_id,
        p_shotgun_category_hole_id,
        v_posicion
    )
    RETURNING id
      INTO v_group_id;

    RETURN QUERY
    SELECT v_group_id, 'creado'::text;
END;
$function$;


-- =====================================================================
-- 3. ESTADO DE LA CONFORMACIÓN
-- =====================================================================

CREATE OR REPLACE FUNCTION public.estado_conformacion_shotgun(
    p_config_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_auth_uid uuid;
    v_tipo text;
    v_tournament_id uuid;
    v_round_id uuid;
    v_category_id uuid;
    v_materializado boolean;
    v_grupos_activos integer;
    v_asignadas integer;
    v_sin_grupo integer;
    v_ultima timestamptz;
BEGIN
    v_auth_uid := auth.uid();

    IF NOT public.can_manage_tournament_shotgun_config(
        v_auth_uid,
        p_config_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permisos para administrar esta configuración Shotgun.';
    END IF;

    SELECT
        tf.tipo_participacion::text,
        tr.tournament_id,
        tr.id,
        sc.tournament_category_id
      INTO
        v_tipo,
        v_tournament_id,
        v_round_id,
        v_category_id
      FROM public.tournament_shotgun_category_configs cfg
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id
      JOIN public.tournament_round_shifts trs
        ON trs.id = sc.tournament_round_shift_id
      JOIN public.tournament_rounds tr
        ON tr.id = trs.tournament_round_id
      JOIN public.tournaments t
        ON t.id = tr.tournament_id
      JOIN public.tournament_formats tf
        ON tf.id = t.tournament_format_id
     WHERE cfg.id = p_config_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La configuración Shotgun no existe.';
    END IF;

    SELECT
        EXISTS (
            SELECT 1
            FROM public.tournament_groups g
            JOIN public.tournament_shotgun_category_holes sh
              ON sh.id = g.tournament_shotgun_category_hole_id
            WHERE sh.tournament_shotgun_category_config_id = p_config_id
        ),
        count(*) FILTER (WHERE g.activo = true),
        max(g.updated_at)
      INTO
        v_materializado,
        v_grupos_activos,
        v_ultima
      FROM public.tournament_groups g
      JOIN public.tournament_shotgun_category_holes sh
        ON sh.id = g.tournament_shotgun_category_hole_id
     WHERE sh.tournament_shotgun_category_config_id = p_config_id;

    IF v_tipo = 'individual' THEN
        SELECT count(*)
          INTO v_asignadas
          FROM public.tournament_group_players gp
          JOIN public.tournament_groups g
            ON g.id = gp.tournament_group_id
          JOIN public.tournament_shotgun_category_holes sh
            ON sh.id = g.tournament_shotgun_category_hole_id
         WHERE sh.tournament_shotgun_category_config_id = p_config_id
           AND g.activo = true;

        SELECT count(*)
          INTO v_sin_grupo
          FROM public.tournament_registrations reg
         WHERE reg.tournament_id = v_tournament_id
           AND reg.tournament_category_id = v_category_id
           AND reg.activo = true
           AND NOT EXISTS (
               SELECT 1
               FROM public.tournament_group_players gp
               JOIN public.tournament_groups g
                 ON g.id = gp.tournament_group_id
               JOIN public.tournament_round_shifts trs
                 ON trs.id = g.tournament_round_shift_id
               WHERE gp.tournament_registration_id = reg.id
                 AND g.activo = true
                 AND trs.tournament_round_id = v_round_id
           );
    ELSE
        SELECT count(*)
          INTO v_asignadas
          FROM public.tournament_group_teams gt
          JOIN public.tournament_groups g
            ON g.id = gt.tournament_group_id
          JOIN public.tournament_shotgun_category_holes sh
            ON sh.id = g.tournament_shotgun_category_hole_id
         WHERE sh.tournament_shotgun_category_config_id = p_config_id
           AND g.activo = true
           AND gt.activo = true;

        SELECT count(*)
          INTO v_sin_grupo
          FROM public.tournament_teams tt
         WHERE tt.tournament_id = v_tournament_id
           AND tt.tournament_category_id = v_category_id
           AND tt.activo = true
           AND NOT EXISTS (
               SELECT 1
               FROM public.tournament_group_teams gt
               JOIN public.tournament_groups g
                 ON g.id = gt.tournament_group_id
               JOIN public.tournament_round_shifts trs
                 ON trs.id = g.tournament_round_shift_id
               WHERE gt.tournament_team_id = tt.id
                 AND gt.activo = true
                 AND g.activo = true
                 AND trs.tournament_round_id = v_round_id
           );
    END IF;

    RETURN jsonb_build_object(
        'materializado', coalesce(v_materializado, false),
        'tipoParticipacion', v_tipo,
        'gruposActivos', coalesce(v_grupos_activos, 0),
        'unidadesAsignadas', coalesce(v_asignadas, 0),
        'unidadesSinGrupo', coalesce(v_sin_grupo, 0),
        'ultimaActualizacion', v_ultima
    );
END;
$function$;


-- =====================================================================
-- 4. OBTENER CONFORMACIÓN PERSISTIDA
-- =====================================================================

CREATE OR REPLACE FUNCTION public.obtener_conformacion_shotgun(
    p_config_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_auth_uid uuid;
    v_tipo text;
    v_tournament_id uuid;
    v_round_id uuid;
    v_category_id uuid;
    v_materializado boolean;
    v_grupos jsonb;
    v_sin_asignar jsonb;
BEGIN
    v_auth_uid := auth.uid();

    IF NOT public.can_manage_tournament_shotgun_config(
        v_auth_uid,
        p_config_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permisos para consultar esta configuración Shotgun.';
    END IF;

    SELECT
        tf.tipo_participacion::text,
        tr.tournament_id,
        tr.id,
        sc.tournament_category_id
      INTO
        v_tipo,
        v_tournament_id,
        v_round_id,
        v_category_id
      FROM public.tournament_shotgun_category_configs cfg
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id
      JOIN public.tournament_round_shifts trs
        ON trs.id = sc.tournament_round_shift_id
      JOIN public.tournament_rounds tr
        ON tr.id = trs.tournament_round_id
      JOIN public.tournaments t
        ON t.id = tr.tournament_id
      JOIN public.tournament_formats tf
        ON tf.id = t.tournament_format_id
     WHERE cfg.id = p_config_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La configuración Shotgun no existe.';
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM public.tournament_groups g
        JOIN public.tournament_shotgun_category_holes sh
          ON sh.id = g.tournament_shotgun_category_hole_id
        WHERE sh.tournament_shotgun_category_config_id = p_config_id
    )
    INTO v_materializado;

    SELECT coalesce(
        jsonb_agg(
            jsonb_build_object(
                'groupId', z.group_id,
                'shotgunCategoryHoleId', z.shotgun_hole_id,
                'hoyoId', z.hoyo_id,
                'numeroHoyo', z.numero_hoyo,
                'posicion', z.posicion,
                'horaSalida', z.hora_salida,
                'etiqueta', z.etiqueta,
                'updatedAt', z.updated_at,
                'unidades', z.unidades
            )
            ORDER BY z.numero_hoyo, z.posicion
        ),
        '[]'::jsonb
    )
    INTO v_grupos
    FROM (
        SELECT
            g.id AS group_id,
            g.tournament_shotgun_category_hole_id AS shotgun_hole_id,
            g.hoyo_id,
            h.numero_hoyo,
            g.posicion_salida AS posicion,
            g.hora_salida,
            g.etiqueta,
            g.updated_at,
            CASE
                WHEN v_tipo = 'individual' THEN
                    (
                        SELECT coalesce(
                            jsonb_agg(
                                jsonb_build_object(
                                    'id', gp.tournament_registration_id,
                                    'orden', gp.orden_en_grupo
                                )
                                ORDER BY
                                    gp.orden_en_grupo NULLS LAST,
                                    gp.created_at,
                                    gp.id
                            ),
                            '[]'::jsonb
                        )
                        FROM public.tournament_group_players gp
                        WHERE gp.tournament_group_id = g.id
                    )
                ELSE
                    (
                        SELECT coalesce(
                            jsonb_agg(
                                jsonb_build_object(
                                    'id', gt.tournament_team_id,
                                    'orden', gt.orden_en_grupo
                                )
                                ORDER BY
                                    gt.orden_en_grupo NULLS LAST,
                                    gt.created_at,
                                    gt.id
                            ),
                            '[]'::jsonb
                        )
                        FROM public.tournament_group_teams gt
                        WHERE gt.tournament_group_id = g.id
                          AND gt.activo = true
                    )
            END AS unidades
        FROM public.tournament_groups g
        JOIN public.tournament_shotgun_category_holes sh
          ON sh.id = g.tournament_shotgun_category_hole_id
        JOIN public.hoyos h
          ON h.id = g.hoyo_id
        WHERE sh.tournament_shotgun_category_config_id = p_config_id
          AND g.activo = true
    ) z;

    IF v_tipo = 'individual' THEN
        SELECT coalesce(jsonb_agg(reg.id ORDER BY reg.id), '[]'::jsonb)
          INTO v_sin_asignar
          FROM public.tournament_registrations reg
         WHERE reg.tournament_id = v_tournament_id
           AND reg.tournament_category_id = v_category_id
           AND reg.activo = true
           AND NOT EXISTS (
               SELECT 1
               FROM public.tournament_group_players gp
               JOIN public.tournament_groups g
                 ON g.id = gp.tournament_group_id
               JOIN public.tournament_round_shifts trs
                 ON trs.id = g.tournament_round_shift_id
               WHERE gp.tournament_registration_id = reg.id
                 AND g.activo = true
                 AND trs.tournament_round_id = v_round_id
           );
    ELSE
        SELECT coalesce(jsonb_agg(tt.id ORDER BY tt.id), '[]'::jsonb)
          INTO v_sin_asignar
          FROM public.tournament_teams tt
         WHERE tt.tournament_id = v_tournament_id
           AND tt.tournament_category_id = v_category_id
           AND tt.activo = true
           AND NOT EXISTS (
               SELECT 1
               FROM public.tournament_group_teams gt
               JOIN public.tournament_groups g
                 ON g.id = gt.tournament_group_id
               JOIN public.tournament_round_shifts trs
                 ON trs.id = g.tournament_round_shift_id
               WHERE gt.tournament_team_id = tt.id
                 AND gt.activo = true
                 AND g.activo = true
                 AND trs.tournament_round_id = v_round_id
           );
    END IF;

    RETURN jsonb_build_object(
        'materializado', coalesce(v_materializado, false),
        'tipoParticipacion', v_tipo,
        'grupos', coalesce(v_grupos, '[]'::jsonb),
        'sinAsignar', coalesce(v_sin_asignar, '[]'::jsonb)
    );
END;
$function$;


-- =====================================================================
-- 5. MATERIALIZAR PROPUESTA INICIAL
-- =====================================================================

CREATE OR REPLACE FUNCTION public.materializar_conformacion_shotgun(
    p_config_id uuid,
    p_grupos jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_auth_uid uuid;
    v_actor_admin_id uuid;
    v_tipo text;
    v_tournament_id uuid;
    v_round_id uuid;
    v_category_id uuid;
    v_maximo integer;
    v_group jsonb;
    v_hole_id uuid;
    v_posicion text;
    v_unit_text text;
    v_unit_id uuid;
    v_orden integer;
    v_group_id uuid;
    v_accion text;
    v_result jsonb := '[]'::jsonb;
    v_num_grupos integer := 0;
    v_total_posiciones integer;
    v_distintas_posiciones integer;
    v_total_unidades integer;
    v_distintas_unidades integer;
BEGIN
    v_auth_uid := auth.uid();

    IF NOT public.can_manage_tournament_shotgun_config(
        v_auth_uid,
        p_config_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permisos para materializar esta configuración Shotgun.';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_config_id::text, 0)
    );

    SELECT
        tf.tipo_participacion::text,
        tr.tournament_id,
        tr.id,
        sc.tournament_category_id,
        cfg.tamano_grupo_maximo
      INTO
        v_tipo,
        v_tournament_id,
        v_round_id,
        v_category_id,
        v_maximo
      FROM public.tournament_shotgun_category_configs cfg
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id
      JOIN public.tournament_round_shifts trs
        ON trs.id = sc.tournament_round_shift_id
      JOIN public.tournament_rounds tr
        ON tr.id = trs.tournament_round_id
      JOIN public.tournaments t
        ON t.id = tr.tournament_id
      JOIN public.tournament_formats tf
        ON tf.id = t.tournament_format_id
     WHERE cfg.id = p_config_id
       AND cfg.activo = true
       AND sc.activo = true
       AND trs.activo = true
       AND tr.activo = true
       AND tr.formato_salida = 'shotgun'::formato_salida_ronda;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No existe una configuración Shotgun activa y válida.';
    END IF;

    IF jsonb_typeof(p_grupos) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'p_grupos debe ser un arreglo JSON.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_groups g
        JOIN public.tournament_shotgun_category_holes sh
          ON sh.id = g.tournament_shotgun_category_hole_id
        WHERE sh.tournament_shotgun_category_config_id = p_config_id
    ) THEN
        RAISE EXCEPTION
            'Esta categoría-turno ya tiene una conformación persistida.';
    END IF;

    -- Todos los elementos deben traer un arreglo "unidades".
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_grupos) e(value)
        WHERE jsonb_typeof(e.value->'unidades') IS DISTINCT FROM 'array'
    ) THEN
        RAISE EXCEPTION
            'Cada grupo debe contener un arreglo unidades.';
    END IF;

    -- Posiciones repetidas.
    SELECT
        count(*),
        count(
            DISTINCT (
                (e.value->>'shotgunCategoryHoleId')
                || ':'
                || upper(e.value->>'posicion')
            )
        )
      INTO
        v_total_posiciones,
        v_distintas_posiciones
      FROM jsonb_array_elements(p_grupos) e(value);

    IF v_total_posiciones <> v_distintas_posiciones THEN
        RAISE EXCEPTION
            'El payload contiene posiciones Shotgun repetidas.';
    END IF;

    -- Unidades repetidas entre grupos.
    SELECT
        count(*),
        count(DISTINCT u.value)
      INTO
        v_total_unidades,
        v_distintas_unidades
      FROM jsonb_array_elements(p_grupos) e(value)
      CROSS JOIN LATERAL
           jsonb_array_elements_text(e.value->'unidades') u(value);

    IF v_total_unidades <> v_distintas_unidades THEN
        RAISE EXCEPTION
            'Una misma unidad aparece más de una vez en la conformación.';
    END IF;

    SELECT au.id
      INTO v_actor_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = v_auth_uid
       AND au.activo = true
     LIMIT 1;

    FOR v_group IN
        SELECT value
        FROM jsonb_array_elements(p_grupos)
    LOOP
        IF jsonb_array_length(v_group->'unidades') = 0 THEN
            CONTINUE;
        END IF;

        v_hole_id :=
            (v_group->>'shotgunCategoryHoleId')::uuid;

        v_posicion :=
            upper(trim(v_group->>'posicion'));

        IF v_posicion NOT IN ('A', 'B') THEN
            RAISE EXCEPTION
                'La posición Shotgun debe ser A o B.';
        END IF;

        IF jsonb_array_length(v_group->'unidades') > v_maximo THEN
            RAISE EXCEPTION
                'Un grupo excede el máximo permitido de % unidades.',
                v_maximo;
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM public.tournament_shotgun_category_holes sh
            WHERE sh.id = v_hole_id
              AND sh.tournament_shotgun_category_config_id = p_config_id
              AND sh.activo = true
              AND (
                  v_posicion = 'A'
                  OR (v_posicion = 'B' AND sh.salida_doble = true)
              )
        ) THEN
            RAISE EXCEPTION
                'El hoyo/posición indicado no pertenece a la configuración Shotgun activa.';
        END IF;

        SELECT d.group_id, d.accion
          INTO v_group_id, v_accion
          FROM public._grupo_shotgun_destino(
              p_config_id,
              v_hole_id,
              v_posicion,
              v_actor_admin_id
          ) d;

        v_orden := 0;

        FOR v_unit_text IN
            SELECT value
            FROM jsonb_array_elements_text(v_group->'unidades')
        LOOP
            v_unit_id := v_unit_text::uuid;
            v_orden := v_orden + 1;

            IF v_tipo = 'individual' THEN
                PERFORM 1
                FROM public.tournament_registrations reg
                WHERE reg.id = v_unit_id
                  AND reg.tournament_id = v_tournament_id
                  AND reg.tournament_category_id = v_category_id
                  AND reg.activo = true;

                IF NOT FOUND THEN
                    RAISE EXCEPTION
                        'La inscripción % no está activa o no pertenece a la categoría del grupo.',
                        v_unit_id;
                END IF;

                INSERT INTO public.tournament_group_players (
                    tournament_group_id,
                    tournament_registration_id,
                    orden_en_grupo
                )
                VALUES (
                    v_group_id,
                    v_unit_id,
                    v_orden::smallint
                );

            ELSIF v_tipo = 'equipo' THEN
                PERFORM 1
                FROM public.tournament_teams tt
                WHERE tt.id = v_unit_id
                  AND tt.tournament_id = v_tournament_id
                  AND tt.tournament_category_id = v_category_id
                  AND tt.activo = true;

                IF NOT FOUND THEN
                    RAISE EXCEPTION
                        'El equipo % no está activo o no pertenece a la categoría del grupo.',
                        v_unit_id;
                END IF;

                INSERT INTO public.tournament_group_teams (
                    tournament_group_id,
                    tournament_team_id,
                    orden_en_grupo,
                    activo,
                    created_by
                )
                VALUES (
                    v_group_id,
                    v_unit_id,
                    v_orden::smallint,
                    true,
                    v_actor_admin_id
                );

            ELSE
                RAISE EXCEPTION
                    'Tipo de participación no soportado: %.',
                    v_tipo;
            END IF;
        END LOOP;

        v_result :=
            v_result || jsonb_build_array(
                jsonb_build_object(
                    'groupId', v_group_id,
                    'shotgunCategoryHoleId', v_hole_id,
                    'posicion', v_posicion
                )
            );

        v_num_grupos := v_num_grupos + 1;
    END LOOP;

    IF v_num_grupos = 0 THEN
        RAISE EXCEPTION
            'No hay grupos con unidades para materializar.';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'materializado', true,
        'gruposCreados', v_num_grupos,
        'grupos', v_result
    );
END;
$function$;


-- =====================================================================
-- 6. MOVER UNA UNIDAD — AUTOSAVE TRANSACCIONAL
-- =====================================================================

CREATE OR REPLACE FUNCTION public.mover_unidad_shotgun(
    p_config_id uuid,
    p_unidad_id uuid,
    p_tipo text,
    p_destino_hole_id uuid,
    p_destino_posicion text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_auth_uid uuid;
    v_actor_admin_id uuid;
    v_tipo_real text;
    v_round_id uuid;
    v_tournament_id uuid;
    v_category_id uuid;

    v_origen_group_id uuid;
    v_origen_assoc_id uuid;
    v_origen_config_id uuid;
    v_origen_posicion text;

    v_dest_group_id uuid;
    v_dest_accion text;
    v_dest_orden integer;

    v_restantes integer;
    v_origen_desactivado boolean := false;
    v_dest_total integer;
    v_updated_at timestamptz;
BEGIN
    v_auth_uid := auth.uid();

    IF NOT public.can_manage_tournament_shotgun_config(
        v_auth_uid,
        p_config_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permisos para modificar esta configuración Shotgun.';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_config_id::text, 0)
    );

    SELECT
        tf.tipo_participacion::text,
        tr.id,
        tr.tournament_id,
        sc.tournament_category_id
      INTO
        v_tipo_real,
        v_round_id,
        v_tournament_id,
        v_category_id
      FROM public.tournament_shotgun_category_configs cfg
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id
      JOIN public.tournament_round_shifts trs
        ON trs.id = sc.tournament_round_shift_id
      JOIN public.tournament_rounds tr
        ON tr.id = trs.tournament_round_id
      JOIN public.tournaments t
        ON t.id = tr.tournament_id
      JOIN public.tournament_formats tf
        ON tf.id = t.tournament_format_id
     WHERE cfg.id = p_config_id
       AND cfg.activo = true
       AND sc.activo = true
       AND trs.activo = true
       AND tr.activo = true
       AND tr.formato_salida = 'shotgun'::formato_salida_ronda;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No existe una configuración Shotgun activa y válida.';
    END IF;

    IF lower(trim(p_tipo)) IS DISTINCT FROM v_tipo_real THEN
        RAISE EXCEPTION
            'El tipo de unidad no coincide con el formato del torneo.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.tournament_groups g
        JOIN public.tournament_shotgun_category_holes sh
          ON sh.id = g.tournament_shotgun_category_hole_id
        WHERE sh.tournament_shotgun_category_config_id = p_config_id
    ) THEN
        RAISE EXCEPTION
            'La conformación todavía no ha sido materializada.';
    END IF;

    SELECT au.id
      INTO v_actor_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = v_auth_uid
       AND au.activo = true
     LIMIT 1;

    -- Validar la unidad antes de tocar nada.
    IF v_tipo_real = 'individual' THEN
        PERFORM 1
        FROM public.tournament_registrations reg
        WHERE reg.id = p_unidad_id
          AND reg.tournament_id = v_tournament_id
          AND reg.tournament_category_id = v_category_id
          AND reg.activo = true;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'La inscripción no está activa o no pertenece a esta categoría.';
        END IF;

        SELECT
            gp.id,
            g.id,
            sh.tournament_shotgun_category_config_id,
            g.posicion_salida
          INTO
            v_origen_assoc_id,
            v_origen_group_id,
            v_origen_config_id,
            v_origen_posicion
          FROM public.tournament_group_players gp
          JOIN public.tournament_groups g
            ON g.id = gp.tournament_group_id
          JOIN public.tournament_round_shifts trs
            ON trs.id = g.tournament_round_shift_id
          LEFT JOIN public.tournament_shotgun_category_holes sh
            ON sh.id = g.tournament_shotgun_category_hole_id
         WHERE gp.tournament_registration_id = p_unidad_id
           AND g.activo = true
           AND trs.tournament_round_id = v_round_id
         LIMIT 1;

    ELSE
        PERFORM 1
        FROM public.tournament_teams tt
        WHERE tt.id = p_unidad_id
          AND tt.tournament_id = v_tournament_id
          AND tt.tournament_category_id = v_category_id
          AND tt.activo = true;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'El equipo no está activo o no pertenece a esta categoría.';
        END IF;

        SELECT
            gt.id,
            g.id,
            sh.tournament_shotgun_category_config_id,
            g.posicion_salida
          INTO
            v_origen_assoc_id,
            v_origen_group_id,
            v_origen_config_id,
            v_origen_posicion
          FROM public.tournament_group_teams gt
          JOIN public.tournament_groups g
            ON g.id = gt.tournament_group_id
          JOIN public.tournament_round_shifts trs
            ON trs.id = g.tournament_round_shift_id
          LEFT JOIN public.tournament_shotgun_category_holes sh
            ON sh.id = g.tournament_shotgun_category_hole_id
         WHERE gt.tournament_team_id = p_unidad_id
           AND gt.activo = true
           AND g.activo = true
           AND trs.tournament_round_id = v_round_id
         LIMIT 1;
    END IF;

    IF v_origen_group_id IS NOT NULL
       AND v_origen_config_id IS DISTINCT FROM p_config_id
    THEN
        RAISE EXCEPTION
            'La unidad está asignada a otra configuración/turno de esta ronda.';
    END IF;

    SELECT d.group_id, d.accion
      INTO v_dest_group_id, v_dest_accion
      FROM public._grupo_shotgun_destino(
          p_config_id,
          p_destino_hole_id,
          p_destino_posicion,
          v_actor_admin_id
      ) d;

    -- Mover a la misma posición es no-op.
    IF v_origen_group_id IS NOT NULL
       AND v_origen_group_id = v_dest_group_id
    THEN
        RETURN jsonb_build_object(
            'success', true,
            'sinCambios', true,
            'unidadId', p_unidad_id,
            'groupId', v_dest_group_id
        );
    END IF;

    -- QUITAR DEL ORIGEN PRIMERO.
    IF v_origen_group_id IS NOT NULL THEN

        IF v_tipo_real = 'individual' THEN
            DELETE FROM public.tournament_group_players
             WHERE id = v_origen_assoc_id;

            WITH ranked AS (
                SELECT
                    gp.id,
                    row_number() OVER (
                        ORDER BY
                            gp.orden_en_grupo NULLS LAST,
                            gp.created_at,
                            gp.id
                    )::smallint AS nuevo_orden
                FROM public.tournament_group_players gp
                WHERE gp.tournament_group_id = v_origen_group_id
            )
            UPDATE public.tournament_group_players gp
               SET orden_en_grupo = r.nuevo_orden
              FROM ranked r
             WHERE gp.id = r.id
               AND gp.orden_en_grupo IS DISTINCT FROM r.nuevo_orden;

            SELECT count(*)
              INTO v_restantes
              FROM public.tournament_group_players gp
             WHERE gp.tournament_group_id = v_origen_group_id;

        ELSE
            UPDATE public.tournament_group_teams
               SET activo = false,
                   motivo_baja = 'movimiento_shotgun'
             WHERE id = v_origen_assoc_id;

            WITH ranked AS (
                SELECT
                    gt.id,
                    row_number() OVER (
                        ORDER BY
                            gt.orden_en_grupo NULLS LAST,
                            gt.created_at,
                            gt.id
                    )::smallint AS nuevo_orden
                FROM public.tournament_group_teams gt
                WHERE gt.tournament_group_id = v_origen_group_id
                  AND gt.activo = true
            )
            UPDATE public.tournament_group_teams gt
               SET orden_en_grupo = r.nuevo_orden
              FROM ranked r
             WHERE gt.id = r.id
               AND gt.orden_en_grupo IS DISTINCT FROM r.nuevo_orden;

            SELECT count(*)
              INTO v_restantes
              FROM public.tournament_group_teams gt
             WHERE gt.tournament_group_id = v_origen_group_id
               AND gt.activo = true;
        END IF;

        IF v_restantes = 0 THEN
            UPDATE public.tournament_groups
               SET activo = false,
                   fecha_baja = now(),
                   dado_de_baja_por = v_actor_admin_id,
                   motivo_baja = 'grupo_vacio_por_movimiento'
             WHERE id = v_origen_group_id;

            v_origen_desactivado := true;
        END IF;
    ELSE
        v_restantes := NULL;
    END IF;

    -- AGREGAR AL DESTINO.
    IF v_tipo_real = 'individual' THEN
        SELECT coalesce(max(gp.orden_en_grupo), 0) + 1
          INTO v_dest_orden
          FROM public.tournament_group_players gp
         WHERE gp.tournament_group_id = v_dest_group_id;

        INSERT INTO public.tournament_group_players (
            tournament_group_id,
            tournament_registration_id,
            orden_en_grupo
        )
        VALUES (
            v_dest_group_id,
            p_unidad_id,
            v_dest_orden::smallint
        );

        SELECT count(*)
          INTO v_dest_total
          FROM public.tournament_group_players gp
         WHERE gp.tournament_group_id = v_dest_group_id;

    ELSE
        SELECT coalesce(max(gt.orden_en_grupo), 0) + 1
          INTO v_dest_orden
          FROM public.tournament_group_teams gt
         WHERE gt.tournament_group_id = v_dest_group_id
           AND gt.activo = true;

        -- Reutilizar una relación histórica inactiva si existe.
        SELECT gt.id
          INTO v_origen_assoc_id
          FROM public.tournament_group_teams gt
         WHERE gt.tournament_group_id = v_dest_group_id
           AND gt.tournament_team_id = p_unidad_id
           AND gt.activo = false
         ORDER BY gt.updated_at DESC, gt.created_at DESC
         LIMIT 1;

        IF v_origen_assoc_id IS NOT NULL THEN
            UPDATE public.tournament_group_teams
               SET activo = true,
                   fecha_baja = NULL,
                   dado_de_baja_por = NULL,
                   motivo_baja = NULL,
                   orden_en_grupo = v_dest_orden::smallint
             WHERE id = v_origen_assoc_id;
        ELSE
            INSERT INTO public.tournament_group_teams (
                tournament_group_id,
                tournament_team_id,
                orden_en_grupo,
                activo,
                created_by
            )
            VALUES (
                v_dest_group_id,
                p_unidad_id,
                v_dest_orden::smallint,
                true,
                v_actor_admin_id
            );
        END IF;

        SELECT count(*)
          INTO v_dest_total
          FROM public.tournament_group_teams gt
         WHERE gt.tournament_group_id = v_dest_group_id
           AND gt.activo = true;
    END IF;

    SELECT g.updated_at
      INTO v_updated_at
      FROM public.tournament_groups g
     WHERE g.id = v_dest_group_id;

    RETURN jsonb_build_object(
        'success', true,
        'unidadId', p_unidad_id,
        'tipo', v_tipo_real,
        'origen', jsonb_build_object(
            'groupId', v_origen_group_id,
            'restantes', v_restantes,
            'desactivado', v_origen_desactivado
        ),
        'destino', jsonb_build_object(
            'groupId', v_dest_group_id,
            'accion', v_dest_accion,
            'total', v_dest_total,
            'orden', v_dest_orden,
            'updatedAt', v_updated_at
        )
    );
END;
$function$;


-- =====================================================================
-- 7. SACAR UNIDAD DEL GRUPO — FUTURA BANDEJA VIRTUAL
-- =====================================================================

CREATE OR REPLACE FUNCTION public.sacar_unidad_grupo_shotgun(
    p_config_id uuid,
    p_unidad_id uuid,
    p_tipo text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_auth_uid uuid;
    v_actor_admin_id uuid;
    v_tipo_real text;
    v_round_id uuid;
    v_origen_group_id uuid;
    v_origen_assoc_id uuid;
    v_origen_config_id uuid;
    v_restantes integer;
    v_desactivado boolean := false;
BEGIN
    v_auth_uid := auth.uid();

    IF NOT public.can_manage_tournament_shotgun_config(
        v_auth_uid,
        p_config_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permisos para modificar esta configuración Shotgun.';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_config_id::text, 0)
    );

    SELECT
        tf.tipo_participacion::text,
        tr.id
      INTO
        v_tipo_real,
        v_round_id
      FROM public.tournament_shotgun_category_configs cfg
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id
      JOIN public.tournament_round_shifts trs
        ON trs.id = sc.tournament_round_shift_id
      JOIN public.tournament_rounds tr
        ON tr.id = trs.tournament_round_id
      JOIN public.tournaments t
        ON t.id = tr.tournament_id
      JOIN public.tournament_formats tf
        ON tf.id = t.tournament_format_id
     WHERE cfg.id = p_config_id
       AND cfg.activo = true
       AND sc.activo = true
       AND trs.activo = true
       AND tr.activo = true
       AND tr.formato_salida = 'shotgun'::formato_salida_ronda;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No existe una configuración Shotgun activa y válida.';
    END IF;

    IF lower(trim(p_tipo)) IS DISTINCT FROM v_tipo_real THEN
        RAISE EXCEPTION
            'El tipo de unidad no coincide con el formato del torneo.';
    END IF;

    SELECT au.id
      INTO v_actor_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = v_auth_uid
       AND au.activo = true
     LIMIT 1;

    IF v_tipo_real = 'individual' THEN
        SELECT
            gp.id,
            g.id,
            sh.tournament_shotgun_category_config_id
          INTO
            v_origen_assoc_id,
            v_origen_group_id,
            v_origen_config_id
          FROM public.tournament_group_players gp
          JOIN public.tournament_groups g
            ON g.id = gp.tournament_group_id
          JOIN public.tournament_round_shifts trs
            ON trs.id = g.tournament_round_shift_id
          LEFT JOIN public.tournament_shotgun_category_holes sh
            ON sh.id = g.tournament_shotgun_category_hole_id
         WHERE gp.tournament_registration_id = p_unidad_id
           AND g.activo = true
           AND trs.tournament_round_id = v_round_id
         LIMIT 1;
    ELSE
        SELECT
            gt.id,
            g.id,
            sh.tournament_shotgun_category_config_id
          INTO
            v_origen_assoc_id,
            v_origen_group_id,
            v_origen_config_id
          FROM public.tournament_group_teams gt
          JOIN public.tournament_groups g
            ON g.id = gt.tournament_group_id
          JOIN public.tournament_round_shifts trs
            ON trs.id = g.tournament_round_shift_id
          LEFT JOIN public.tournament_shotgun_category_holes sh
            ON sh.id = g.tournament_shotgun_category_hole_id
         WHERE gt.tournament_team_id = p_unidad_id
           AND gt.activo = true
           AND g.activo = true
           AND trs.tournament_round_id = v_round_id
         LIMIT 1;
    END IF;

    IF v_origen_group_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', true,
            'sinCambios', true,
            'unidadId', p_unidad_id,
            'estado', 'sin_grupo'
        );
    END IF;

    IF v_origen_config_id IS DISTINCT FROM p_config_id THEN
        RAISE EXCEPTION
            'La unidad está asignada a otra configuración/turno de esta ronda.';
    END IF;

    IF v_tipo_real = 'individual' THEN
        DELETE FROM public.tournament_group_players
         WHERE id = v_origen_assoc_id;

        WITH ranked AS (
            SELECT
                gp.id,
                row_number() OVER (
                    ORDER BY
                        gp.orden_en_grupo NULLS LAST,
                        gp.created_at,
                        gp.id
                )::smallint AS nuevo_orden
            FROM public.tournament_group_players gp
            WHERE gp.tournament_group_id = v_origen_group_id
        )
        UPDATE public.tournament_group_players gp
           SET orden_en_grupo = r.nuevo_orden
          FROM ranked r
         WHERE gp.id = r.id
           AND gp.orden_en_grupo IS DISTINCT FROM r.nuevo_orden;

        SELECT count(*)
          INTO v_restantes
          FROM public.tournament_group_players gp
         WHERE gp.tournament_group_id = v_origen_group_id;

    ELSE
        UPDATE public.tournament_group_teams
           SET activo = false,
               motivo_baja = 'pendiente_shotgun'
         WHERE id = v_origen_assoc_id;

        WITH ranked AS (
            SELECT
                gt.id,
                row_number() OVER (
                    ORDER BY
                        gt.orden_en_grupo NULLS LAST,
                        gt.created_at,
                        gt.id
                )::smallint AS nuevo_orden
            FROM public.tournament_group_teams gt
            WHERE gt.tournament_group_id = v_origen_group_id
              AND gt.activo = true
        )
        UPDATE public.tournament_group_teams gt
           SET orden_en_grupo = r.nuevo_orden
          FROM ranked r
         WHERE gt.id = r.id
           AND gt.orden_en_grupo IS DISTINCT FROM r.nuevo_orden;

        SELECT count(*)
          INTO v_restantes
          FROM public.tournament_group_teams gt
         WHERE gt.tournament_group_id = v_origen_group_id
           AND gt.activo = true;
    END IF;

    IF v_restantes = 0 THEN
        UPDATE public.tournament_groups
           SET activo = false,
               fecha_baja = now(),
               dado_de_baja_por = v_actor_admin_id,
               motivo_baja = 'grupo_vacio_por_pendientes'
         WHERE id = v_origen_group_id;

        v_desactivado := true;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'unidadId', p_unidad_id,
        'tipo', v_tipo_real,
        'origen', jsonb_build_object(
            'groupId', v_origen_group_id,
            'restantes', v_restantes,
            'desactivado', v_desactivado
        ),
        'estado', 'sin_grupo'
    );
END;
$function$;


-- =====================================================================
-- 8. PERMISOS
-- =====================================================================

REVOKE ALL ON FUNCTION public.hora_salida_shotgun(uuid, text)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public._grupo_shotgun_destino(uuid, uuid, text, uuid)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.estado_conformacion_shotgun(uuid)
FROM PUBLIC, anon;

REVOKE ALL ON FUNCTION public.obtener_conformacion_shotgun(uuid)
FROM PUBLIC, anon;

REVOKE ALL ON FUNCTION public.materializar_conformacion_shotgun(uuid, jsonb)
FROM PUBLIC, anon;

REVOKE ALL ON FUNCTION public.mover_unidad_shotgun(uuid, uuid, text, uuid, text)
FROM PUBLIC, anon;

REVOKE ALL ON FUNCTION public.sacar_unidad_grupo_shotgun(uuid, uuid, text)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.estado_conformacion_shotgun(uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.obtener_conformacion_shotgun(uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.materializar_conformacion_shotgun(uuid, jsonb)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.mover_unidad_shotgun(uuid, uuid, text, uuid, text)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.sacar_unidad_grupo_shotgun(uuid, uuid, text)
TO authenticated;


COMMIT;
