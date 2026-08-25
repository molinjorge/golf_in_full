-- ============================================================================
-- MIGRACION 185 FASE 1F
-- EDICION PERSISTENTE DE CONFORMACION TEE TIMES ANTES DE VALIDAR
-- TEE CENTRAL
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. INTEGRIDAD NATIVA DE tournament_group_players PARA TEE TIMES
-- ============================================================================

CREATE OR REPLACE FUNCTION public.validar_grupo_individual()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_round_id              uuid;
    v_tournament_id         uuid;
    v_tipo_participacion    formato_juego_torneo;
    v_formato_salida        formato_salida_ronda;
    v_shotgun_hole_id       uuid;
    v_categoria_grupo       uuid;
    v_maximo                integer;
    v_total_en_grupo        integer;
    v_conflicto_ronda       integer;
    v_reg_tournament_id     uuid;
    v_reg_category_id       uuid;
BEGIN
    SELECT
        tr.id,
        tr.tournament_id,
        tf.tipo_participacion,
        tr.formato_salida,
        g.tournament_shotgun_category_hole_id
    INTO
        v_round_id,
        v_tournament_id,
        v_tipo_participacion,
        v_formato_salida,
        v_shotgun_hole_id
    FROM public.tournament_groups g
    JOIN public.tournament_round_shifts trs
      ON trs.id = g.tournament_round_shift_id
    JOIN public.tournament_rounds tr
      ON tr.id = trs.tournament_round_id
    JOIN public.tournaments t
      ON t.id = tr.tournament_id
    JOIN public.tournament_formats tf
      ON tf.id = t.tournament_format_id
    WHERE g.id = NEW.tournament_group_id;

    IF v_round_id IS NULL THEN
        RAISE EXCEPTION 'El grupo indicado no existe.';
    END IF;

    SELECT
        reg.tournament_id,
        reg.tournament_category_id
    INTO
        v_reg_tournament_id,
        v_reg_category_id
    FROM public.tournament_registrations reg
    WHERE reg.id = NEW.tournament_registration_id
      AND reg.activo = true;

    IF v_reg_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La inscripción indicada no existe o no está activa.';
    END IF;

    IF v_reg_tournament_id IS DISTINCT FROM v_tournament_id THEN
        RAISE EXCEPTION
            'La inscripción y el grupo pertenecen a torneos diferentes.';
    END IF;

    IF v_formato_salida = 'shotgun'::formato_salida_ronda
       AND v_shotgun_hole_id IS NOT NULL
    THEN
        IF v_tipo_participacion IS DISTINCT FROM 'individual' THEN
            RAISE EXCEPTION
                'Este torneo es por equipos. Los equipos deben asignarse mediante tournament_group_teams.';
        END IF;

        SELECT
            cfg.tamano_grupo_maximo,
            sc.tournament_category_id
        INTO
            v_maximo,
            v_categoria_grupo
        FROM public.tournament_shotgun_category_holes sh
        JOIN public.tournament_shotgun_category_configs cfg
          ON cfg.id = sh.tournament_shotgun_category_config_id
        JOIN public.tournament_round_shift_categories sc
          ON sc.id = cfg.tournament_round_shift_category_id
        WHERE sh.id = v_shotgun_hole_id
          AND sh.activo = true
          AND cfg.activo = true
          AND sc.activo = true;

        IF v_maximo IS NULL THEN
            RAISE EXCEPTION
                'No existe una configuración Shotgun activa para este grupo.';
        END IF;

        IF v_reg_category_id IS DISTINCT FROM v_categoria_grupo THEN
            RAISE EXCEPTION
                'El jugador no pertenece a la categoría configurada para este grupo.';
        END IF;

    ELSIF v_formato_salida = 'tee_times'::formato_salida_ronda THEN
        IF v_tipo_participacion IS DISTINCT FROM 'individual' THEN
            RAISE EXCEPTION
                'Esta fase de Tee Times sólo admite participación individual.';
        END IF;

        SELECT
            cfg.tamano_grupo_maximo,
            sc.tournament_category_id
        INTO
            v_maximo,
            v_categoria_grupo
        FROM public.tournament_tee_time_groups ttg
        JOIN public.tournament_tee_time_category_configs cfg
          ON cfg.id = ttg.tournament_tee_time_category_config_id
        JOIN public.tournament_round_shift_categories sc
          ON sc.id = cfg.tournament_round_shift_category_id
        WHERE ttg.tournament_group_id = NEW.tournament_group_id
          AND ttg.activo = true
          AND cfg.activo = true
          AND sc.activo = true
        LIMIT 1;

        IF v_maximo IS NULL THEN
            RAISE EXCEPTION
                'No existe una configuración Tee Times activa para este grupo.';
        END IF;

        IF v_reg_category_id IS DISTINCT FROM v_categoria_grupo THEN
            RAISE EXCEPTION
                'El jugador no pertenece a la categoría configurada para este grupo Tee Times.';
        END IF;

    ELSE
        SELECT t.jugadores_por_grupo
        INTO v_maximo
        FROM public.tournament_rounds tr
        JOIN public.tournaments t
          ON t.id = tr.tournament_id
        WHERE tr.id = v_round_id;
    END IF;

    SELECT count(*)
    INTO v_total_en_grupo
    FROM public.tournament_group_players gp
    WHERE gp.tournament_group_id = NEW.tournament_group_id
      AND gp.id IS DISTINCT FROM NEW.id;

    IF v_total_en_grupo >= v_maximo THEN
        RAISE EXCEPTION
            'Este grupo ya alcanzó su máximo de % jugadores.',
            v_maximo;
    END IF;

    SELECT count(*)
    INTO v_conflicto_ronda
    FROM public.tournament_group_players gp
    JOIN public.tournament_groups g
      ON g.id = gp.tournament_group_id
    JOIN public.tournament_round_shifts trs
      ON trs.id = g.tournament_round_shift_id
    JOIN public.tournament_rounds tr
      ON tr.id = trs.tournament_round_id
    WHERE tr.id = v_round_id
      AND g.activo = true
      AND gp.tournament_registration_id =
          NEW.tournament_registration_id
      AND gp.id IS DISTINCT FROM NEW.id;

    IF v_conflicto_ronda > 0 THEN
        RAISE EXCEPTION
            'Este jugador ya está asignado a otro grupo activo en esta ronda.';
    END IF;

    RETURN NEW;
END;
$function$;

-- ============================================================================
-- 02. RPC TRANSACCIONAL DE EDICION
-- ============================================================================

CREATE OR REPLACE FUNCTION public.actualizar_conformacion_tee_times(
    p_shift_config_id uuid,
    p_grupos jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_auth_uid uuid;
    v_actor_admin_id uuid;
    v_shift_id uuid;
    v_round_id uuid;
    v_tournament_id uuid;
    v_status text;
    v_format_type text;
    v_scoring_engine text;
    v_freeze_id uuid;
    v_round_condition_snapshot_id uuid;
    v_existing_group_ids uuid[];
    v_group jsonb;
    v_group_id uuid;
    v_tt_group_id uuid;
    v_category_config_id uuid;
    v_start_hole_id uuid;
    v_sequence integer;
    v_category_id uuid;
    v_maximo integer;
    v_hoyo_id uuid;
    v_hora timestamptz;
    v_unit_text text;
    v_unit_id uuid;
    v_orden integer;
    v_total_slots integer;
    v_distinct_slots integer;
    v_total_units integer;
    v_distinct_units integer;
    v_expected_units integer;
    v_groups_updated integer := 0;
    v_groups_created integer := 0;
    v_groups_deactivated integer := 0;
    v_players_inserted integer := 0;
    v_conformation jsonb;
BEGIN
    v_auth_uid := auth.uid();

    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        cfg.tournament_round_shift_id,
        rs.tournament_round_id,
        tr.tournament_id,
        t.estatus::text,
        tf.tipo_participacion::text,
        tf.scoring_engine::text
    INTO
        v_shift_id,
        v_round_id,
        v_tournament_id,
        v_status,
        v_format_type,
        v_scoring_engine
    FROM public.tournament_tee_time_shift_configs cfg
    JOIN public.tournament_round_shifts rs
      ON rs.id = cfg.tournament_round_shift_id
     AND rs.activo
    JOIN public.tournament_rounds tr
      ON tr.id = rs.tournament_round_id
     AND tr.activo
    JOIN public.tournaments t
      ON t.id = tr.tournament_id
    JOIN public.tournament_formats tf
      ON tf.id = COALESCE(
          tr.tournament_format_id,
          t.tournament_format_id
      )
    WHERE cfg.id = p_shift_config_id
      AND cfg.activo
      AND tr.formato_salida =
          'tee_times'::public.formato_salida_ronda;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No existe una configuración Tee Times activa y válida para este turno.'
            USING ERRCODE = '22023';
    END IF;

    IF v_format_type <> 'individual'
       OR v_scoring_engine <> 'stroke'
    THEN
        RAISE EXCEPTION
            'Esta fase de Tee Times sólo modifica Stroke Play individual.'
            USING ERRCODE = '0A000';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para modificar esta conformación Tee Times.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(v_round_id);

    IF v_status NOT IN ('inscripcion_cerrada', 'en_curso') THEN
        RAISE EXCEPTION
            'Las inscripciones deben estar cerradas para modificar las salidas Tee Times.'
            USING ERRCODE = '55000';
    END IF;

    SELECT f.id
    INTO v_freeze_id
    FROM public.tournament_condition_freezes f
    WHERE f.tournament_id = v_tournament_id
    ORDER BY f.frozen_at DESC
    LIMIT 1;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION
            'El torneo debe estar congelado para modificar las salidas Tee Times.'
            USING ERRCODE = '55000';
    END IF;

    SELECT rcs.id
    INTO v_round_condition_snapshot_id
    FROM public.tournament_round_condition_snapshots rcs
    WHERE rcs.freeze_id = v_freeze_id
      AND rcs.tournament_round_id = v_round_id
    LIMIT 1;

    IF v_round_condition_snapshot_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda no forma parte del congelamiento vigente.'
            USING ERRCODE = '55000';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.tournament_round_handicap_snapshots rhs
        WHERE rhs.tournament_round_id = v_round_id
          AND rhs.freeze_id = v_freeze_id
    ) THEN
        RAISE EXCEPTION
            'La ronda no tiene snapshots de hándicap congelados.'
            USING ERRCODE = '55000';
    END IF;

    IF public._salida_ronda_esta_validada(v_round_id) THEN
        RAISE EXCEPTION
            'Las salidas de la ronda están validadas y no pueden modificarse.'
            USING ERRCODE = '55000';
    END IF;

    IF public._ronda_tiene_tarjetas_emitidas(v_round_id) THEN
        RAISE EXCEPTION
            'La ronda ya tiene tarjetas oficiales emitidas y las salidas no pueden modificarse.'
            USING ERRCODE = '55000';
    END IF;

    SELECT au.id
    INTO v_actor_admin_id
    FROM public.admin_users au
    WHERE au.auth_user_id = v_auth_uid
      AND au.activo
    ORDER BY au.id
    LIMIT 1;

    IF v_actor_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT array_agg(DISTINCT g.id)
    INTO v_existing_group_ids
    FROM public.tournament_tee_time_groups ttg
    JOIN public.tournament_tee_time_shift_start_holes sh
      ON sh.id = ttg.tournament_tee_time_start_hole_id
    JOIN public.tournament_groups g
      ON g.id = ttg.tournament_group_id
     AND g.activo
    WHERE sh.tournament_tee_time_shift_config_id = p_shift_config_id
      AND ttg.activo;

    IF v_existing_group_ids IS NULL
       OR cardinality(v_existing_group_ids) = 0
    THEN
        RAISE EXCEPTION
            'Este turno Tee Times no tiene una conformación materializada para modificar.'
            USING ERRCODE = '55000',
                  HINT = 'Utiliza primero PREPARAR SALIDAS y CONFIRMAR SALIDAS.';
    END IF;

    PERFORM 1
    FROM public.tournament_groups g
    WHERE g.id = ANY(v_existing_group_ids)
    FOR UPDATE;

    PERFORM 1
    FROM public.tournament_tee_time_groups ttg
    WHERE ttg.tournament_group_id = ANY(v_existing_group_ids)
    FOR UPDATE;

    IF jsonb_typeof(p_grupos) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION
            'p_grupos debe ser un arreglo JSON.'
            USING ERRCODE = '22023';
    END IF;

    IF jsonb_array_length(p_grupos) = 0 THEN
        RAISE EXCEPTION
            'La conformación Tee Times debe contener al menos un grupo.'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_grupos) e(value)
        WHERE jsonb_typeof(e.value->'unidades') IS DISTINCT FROM 'array'
    ) THEN
        RAISE EXCEPTION
            'Cada grupo debe contener un arreglo unidades.'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_grupos) e(value)
        WHERE jsonb_array_length(e.value->'unidades') = 0
    ) THEN
        RAISE EXCEPTION
            'No se pueden guardar grupos vacíos.'
            USING ERRCODE = '23514';
    END IF;

    SELECT
        count(*),
        count(DISTINCT (
            (e.value->>'startHoleId')
            || ':'
            || (e.value->>'sequenceNumber')
        ))
    INTO
        v_total_slots,
        v_distinct_slots
    FROM jsonb_array_elements(p_grupos) e(value);

    IF v_total_slots <> v_distinct_slots THEN
        RAISE EXCEPTION
            'El payload contiene posiciones Tee Times repetidas.'
            USING ERRCODE = '23514';
    END IF;

    SELECT
        count(*),
        count(DISTINCT u.value)
    INTO
        v_total_units,
        v_distinct_units
    FROM jsonb_array_elements(p_grupos) e(value)
    CROSS JOIN LATERAL
        jsonb_array_elements_text(e.value->'unidades') u(value);

    IF v_total_units <> v_distinct_units THEN
        RAISE EXCEPTION
            'Una misma inscripción aparece más de una vez en la conformación Tee Times.'
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM (
            SELECT
                nullif(e.value->>'groupId','')::uuid AS group_id,
                count(*) AS n
            FROM jsonb_array_elements(p_grupos) e(value)
            WHERE nullif(e.value->>'groupId','') IS NOT NULL
            GROUP BY nullif(e.value->>'groupId','')::uuid
            HAVING count(*) > 1
        ) d
    ) THEN
        RAISE EXCEPTION
            'Un groupId existente aparece más de una vez en el payload.'
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_grupos) e(value)
        WHERE nullif(e.value->>'groupId','') IS NOT NULL
          AND NOT (
              nullif(e.value->>'groupId','')::uuid =
              ANY(v_existing_group_ids)
          )
    ) THEN
        RAISE EXCEPTION
            'El payload contiene un groupId que no pertenece a la conformación Tee Times activa.'
            USING ERRCODE = '23514';
    END IF;

    SELECT count(*)
    INTO v_expected_units
    FROM public.tournament_round_handicap_snapshots rhs
    JOIN public.tournament_handicap_snapshots hs
      ON hs.id = rhs.handicap_snapshot_id
    JOIN public.tournament_round_shift_categories sc
      ON sc.tournament_round_shift_id = v_shift_id
     AND sc.tournament_category_id = hs.tournament_category_id
     AND sc.activo
    WHERE rhs.tournament_round_id = v_round_id
      AND rhs.freeze_id = v_freeze_id;

    IF v_total_units <> v_expected_units THEN
        RAISE EXCEPTION
            'La conformación debe incluir exactamente los % participantes congelados asignados a este turno; el payload contiene %.',
            v_expected_units,
            v_total_units
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_grupos) e(value)
        CROSS JOIN LATERAL
            jsonb_array_elements_text(e.value->'unidades') u(value)
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.tournament_round_handicap_snapshots rhs
            JOIN public.tournament_handicap_snapshots hs
              ON hs.id = rhs.handicap_snapshot_id
            JOIN public.tournament_round_shift_categories sc
              ON sc.tournament_round_shift_id = v_shift_id
             AND sc.tournament_category_id = hs.tournament_category_id
             AND sc.activo
            WHERE rhs.tournament_round_id = v_round_id
              AND rhs.freeze_id = v_freeze_id
              AND rhs.tournament_registration_id = u.value::uuid
        )
    ) THEN
        RAISE EXCEPTION
            'El payload contiene una inscripción que no pertenece a los participantes congelados de este turno.'
            USING ERRCODE = '23514';
    END IF;

    FOR v_group IN
        SELECT value
        FROM jsonb_array_elements(p_grupos)
    LOOP
        v_category_config_id :=
            (v_group->>'categoryConfigId')::uuid;
        v_start_hole_id :=
            (v_group->>'startHoleId')::uuid;
        v_sequence :=
            (v_group->>'sequenceNumber')::integer;

        IF v_sequence < 1 THEN
            RAISE EXCEPTION
                'La secuencia Tee Times debe ser mayor o igual a 1.'
                USING ERRCODE = '22023';
        END IF;

        SELECT
            cfg.tamano_grupo_maximo,
            sc.tournament_category_id
        INTO
            v_maximo,
            v_category_id
        FROM public.tournament_tee_time_category_configs cfg
        JOIN public.tournament_round_shift_categories sc
          ON sc.id = cfg.tournament_round_shift_category_id
         AND sc.activo
        WHERE cfg.id = v_category_config_id
          AND cfg.activo
          AND sc.tournament_round_shift_id = v_shift_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Una configuración de categoría Tee Times no pertenece al turno activo.'
                USING ERRCODE = '23514';
        END IF;

        IF jsonb_array_length(v_group->'unidades') > v_maximo THEN
            RAISE EXCEPTION
                'Un grupo excede el máximo permitido de % jugadores.',
                v_maximo
                USING ERRCODE = '23514';
        END IF;

        PERFORM 1
        FROM public.tournament_tee_time_shift_start_holes sh
        WHERE sh.id = v_start_hole_id
          AND sh.tournament_tee_time_shift_config_id = p_shift_config_id
          AND sh.activo;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Un tee/hoyo de inicio indicado no pertenece a la configuración Tee Times activa.'
                USING ERRCODE = '23514';
        END IF;

        IF EXISTS (
            SELECT 1
            FROM jsonb_array_elements_text(
                v_group->'unidades'
            ) u(value)
            WHERE NOT EXISTS (
                SELECT 1
                FROM public.tournament_round_handicap_snapshots rhs
                JOIN public.tournament_handicap_snapshots hs
                  ON hs.id = rhs.handicap_snapshot_id
                WHERE rhs.tournament_round_id = v_round_id
                  AND rhs.freeze_id = v_freeze_id
                  AND rhs.tournament_registration_id = u.value::uuid
                  AND hs.tournament_category_id = v_category_id
            )
        ) THEN
            RAISE EXCEPTION
                'Un jugador no pertenece a la categoría congelada del grupo Tee Times.'
                USING ERRCODE = '23514';
        END IF;
    END LOOP;

    UPDATE public.tournament_tee_time_groups ttg
       SET activo = false,
           fecha_baja = now(),
           dado_de_baja_por = v_actor_admin_id,
           motivo_baja =
               'Neutralización transaccional para modificar conformación Tee Times'
     WHERE ttg.tournament_group_id = ANY(v_existing_group_ids)
       AND ttg.activo = true;

    DELETE FROM public.tournament_group_players gp
     WHERE gp.tournament_group_id = ANY(v_existing_group_ids);

    FOR v_group IN
        SELECT value
        FROM jsonb_array_elements(p_grupos)
    LOOP
        v_group_id :=
            nullif(v_group->>'groupId','')::uuid;
        v_category_config_id :=
            (v_group->>'categoryConfigId')::uuid;
        v_start_hole_id :=
            (v_group->>'startHoleId')::uuid;
        v_sequence :=
            (v_group->>'sequenceNumber')::integer;

        SELECT sh.hoyo_id
        INTO v_hoyo_id
        FROM public.tournament_tee_time_shift_start_holes sh
        WHERE sh.id = v_start_hole_id
          AND sh.tournament_tee_time_shift_config_id = p_shift_config_id
          AND sh.activo;

        v_hora := public.hora_salida_tee_time(
            v_start_hole_id,
            v_sequence
        );

        IF v_group_id IS NOT NULL THEN
            SELECT ttg.id
            INTO v_tt_group_id
            FROM public.tournament_tee_time_groups ttg
            JOIN public.tournament_tee_time_shift_start_holes sh
              ON sh.id = ttg.tournament_tee_time_start_hole_id
            WHERE ttg.tournament_group_id = v_group_id
              AND sh.tournament_tee_time_shift_config_id =
                  p_shift_config_id
            ORDER BY ttg.created_at DESC, ttg.id
            LIMIT 1;

            IF v_tt_group_id IS NULL THEN
                RAISE EXCEPTION
                    'No se encontró metadata Tee Times para un groupId existente.'
                    USING ERRCODE = '23514';
            END IF;

            UPDATE public.tournament_groups
               SET hoyo_id = v_hoyo_id,
                   hora_salida = v_hora,
                   etiqueta = format(
                       'TEE %s · %s',
                       (
                           SELECT h.numero_hoyo
                           FROM public.hoyos h
                           WHERE h.id = v_hoyo_id
                       ),
                       to_char(
                           v_hora AT TIME ZONE (
                               SELECT cg.timezone_id
                               FROM public.tournament_rounds tr
                               JOIN public.campos_golf cg
                                 ON cg.id = tr.campo_golf_id
                               WHERE tr.id = v_round_id
                           ),
                           'HH24:MI'
                       )
                   ),
                   activo = true,
                   fecha_baja = NULL,
                   dado_de_baja_por = NULL,
                   motivo_baja = NULL
             WHERE id = v_group_id;

            UPDATE public.tournament_tee_time_groups
               SET tournament_tee_time_category_config_id =
                       v_category_config_id,
                   tournament_tee_time_start_hole_id =
                       v_start_hole_id,
                   sequence_number = v_sequence,
                   activo = true,
                   fecha_baja = NULL,
                   dado_de_baja_por = NULL,
                   motivo_baja = NULL
             WHERE id = v_tt_group_id;

            v_groups_updated := v_groups_updated + 1;

        ELSE
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
                format(
                    'TEE %s · %s',
                    (
                        SELECT h.numero_hoyo
                        FROM public.hoyos h
                        WHERE h.id = v_hoyo_id
                    ),
                    to_char(
                        v_hora AT TIME ZONE (
                            SELECT cg.timezone_id
                            FROM public.tournament_rounds tr
                            JOIN public.campos_golf cg
                              ON cg.id = tr.campo_golf_id
                            WHERE tr.id = v_round_id
                        ),
                        'HH24:MI'
                    )
                ),
                NULL,
                true,
                v_actor_admin_id,
                NULL,
                NULL
            )
            RETURNING id INTO v_group_id;

            INSERT INTO public.tournament_tee_time_groups (
                tournament_group_id,
                tournament_tee_time_category_config_id,
                tournament_tee_time_start_hole_id,
                sequence_number,
                activo,
                created_by
            )
            VALUES (
                v_group_id,
                v_category_config_id,
                v_start_hole_id,
                v_sequence,
                true,
                v_actor_admin_id
            );

            v_groups_created := v_groups_created + 1;
        END IF;

        v_orden := 0;

        FOR v_unit_text IN
            SELECT value
            FROM jsonb_array_elements_text(
                v_group->'unidades'
            )
        LOOP
            v_unit_id := v_unit_text::uuid;
            v_orden := v_orden + 1;

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

            v_players_inserted := v_players_inserted + 1;
        END LOOP;
    END LOOP;

    UPDATE public.tournament_groups g
       SET activo = false,
           fecha_baja = now(),
           dado_de_baja_por = v_actor_admin_id,
           motivo_baja =
               'Grupo retirado durante modificación de conformación Tee Times'
     WHERE g.id = ANY(v_existing_group_ids)
       AND NOT EXISTS (
           SELECT 1
           FROM jsonb_array_elements(p_grupos) e(value)
           WHERE nullif(e.value->>'groupId','')::uuid = g.id
       )
       AND g.activo = true;

    GET DIAGNOSTICS v_groups_deactivated = ROW_COUNT;

    v_conformation :=
        public.obtener_conformacion_tee_times(
            p_shift_config_id
        );

    RETURN jsonb_build_object(
        'success', true,
        'updated', true,
        'roundId', v_round_id,
        'shiftConfigId', p_shift_config_id,
        'groupsUpdated', v_groups_updated,
        'groupsCreated', v_groups_created,
        'groupsDeactivated', v_groups_deactivated,
        'playersAssigned', v_players_inserted,
        'conformation', v_conformation
    );
END;
$function$;

REVOKE ALL
ON FUNCTION public.actualizar_conformacion_tee_times(uuid,jsonb)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.actualizar_conformacion_tee_times(uuid,jsonb)
TO authenticated, service_role;

COMMIT;
