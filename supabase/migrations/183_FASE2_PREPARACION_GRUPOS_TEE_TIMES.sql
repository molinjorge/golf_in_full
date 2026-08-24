-- ============================================================================
-- 183_FASE2_PREPARACION_GRUPOS_TEE_TIMES.sql
-- TEE CENTRAL
--
-- OBJETIVO
-- Materializar grupos Tee Times sobre las tablas comunes existentes:
--   tournament_groups
--   tournament_group_players
--
-- sin poblar campos Shotgun ficticios.
--
-- PRINCIPIOS
-- - tournament_groups sigue siendo la entidad común de grupo.
-- - tournament_shotgun_category_hole_id y posicion_salida quedan NULL.
-- - hoyo_id y hora_salida se reutilizan como datos comunes.
-- - La metadata específica Tee Times vive en tournament_tee_time_groups.
-- - La hora se calcula desde:
--     tournament_round_shifts.hora_salida
--     + offset del stream
--     + (sequence_number - 1) * intervalo.
-- - La preparación se hace por TURNO completo para evitar colisiones entre
--   categorías que comparten los mismos streams/horarios.
-- - Sólo se habilita individual + stroke + tee_times en esta fase.
-- - NO se habilita todavía validación definitiva ni emisión de tarjetas.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. VÍNCULO ESPECÍFICO TEE TIMES -> GRUPO COMÚN
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.tournament_tee_time_groups (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_group_id uuid NOT NULL
        REFERENCES public.tournament_groups(id)
        ON DELETE RESTRICT,

    tournament_tee_time_category_config_id uuid NOT NULL
        REFERENCES public.tournament_tee_time_category_configs(id)
        ON DELETE RESTRICT,

    tournament_tee_time_start_hole_id uuid NOT NULL
        REFERENCES public.tournament_tee_time_shift_start_holes(id)
        ON DELETE RESTRICT,

    sequence_number integer NOT NULL,

    activo boolean NOT NULL DEFAULT true,
    fecha_baja timestamptz,
    dado_de_baja_por uuid
        REFERENCES public.admin_users(id)
        ON DELETE RESTRICT,
    motivo_baja text,

    created_by uuid
        REFERENCES public.admin_users(id)
        ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT chk_tee_time_group_sequence
        CHECK (sequence_number >= 1)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_tee_time_group_group_activo
ON public.tournament_tee_time_groups(tournament_group_id)
WHERE activo = true;

CREATE UNIQUE INDEX IF NOT EXISTS uq_tee_time_group_slot_activo
ON public.tournament_tee_time_groups(
    tournament_tee_time_start_hole_id,
    sequence_number
)
WHERE activo = true;

CREATE INDEX IF NOT EXISTS idx_tee_time_groups_category_config
ON public.tournament_tee_time_groups(
    tournament_tee_time_category_config_id
);

CREATE INDEX IF NOT EXISTS idx_tee_time_groups_start_hole
ON public.tournament_tee_time_groups(
    tournament_tee_time_start_hole_id
);

COMMENT ON TABLE public.tournament_tee_time_groups IS
'Metadata específica de un grupo común cuando su formato de salida es Tee Times.';

COMMENT ON COLUMN public.tournament_tee_time_groups.sequence_number IS
'Secuencia temporal del grupo dentro de su stream/tee. La hora se deriva del turno, offset e intervalo.';


-- ============================================================================
-- 02. TRIGGER UPDATED_AT
-- ============================================================================
DROP TRIGGER IF EXISTS trg_tee_time_groups_updated_at
ON public.tournament_tee_time_groups;

CREATE TRIGGER trg_tee_time_groups_updated_at
BEFORE UPDATE ON public.tournament_tee_time_groups
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();


-- ============================================================================
-- 03. VALIDAR VÍNCULO TEE TIMES
-- ============================================================================
CREATE OR REPLACE FUNCTION public.validar_vinculo_grupo_tee_times()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_group record;
    v_cfg record;
    v_start record;
BEGIN
    SELECT
        g.tournament_round_shift_id,
        g.hoyo_id,
        g.hora_salida,
        g.tournament_shotgun_category_hole_id,
        g.posicion_salida
      INTO v_group
      FROM public.tournament_groups g
     WHERE g.id = NEW.tournament_group_id;

    IF v_group.tournament_round_shift_id IS NULL THEN
        RAISE EXCEPTION
            'El grupo Tee Times indicado no existe.'
            USING ERRCODE = '23503';
    END IF;

    SELECT
        sc.tournament_round_shift_id,
        cfg.activo AS cfg_activo,
        sc.activo AS sc_activo
      INTO v_cfg
      FROM public.tournament_tee_time_category_configs cfg
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id
     WHERE cfg.id = NEW.tournament_tee_time_category_config_id;

    IF NOT FOUND OR NOT COALESCE(v_cfg.cfg_activo,false)
       OR NOT COALESCE(v_cfg.sc_activo,false)
    THEN
        RAISE EXCEPTION
            'La configuración Tee Times de categoría no existe o no está activa.'
            USING ERRCODE = '23514';
    END IF;

    SELECT
        s.hoyo_id,
        c.tournament_round_shift_id,
        s.activo AS start_activo,
        c.activo AS shift_cfg_activo
      INTO v_start
      FROM public.tournament_tee_time_shift_start_holes s
      JOIN public.tournament_tee_time_shift_configs c
        ON c.id = s.tournament_tee_time_shift_config_id
     WHERE s.id = NEW.tournament_tee_time_start_hole_id;

    IF NOT FOUND OR NOT COALESCE(v_start.start_activo,false)
       OR NOT COALESCE(v_start.shift_cfg_activo,false)
    THEN
        RAISE EXCEPTION
            'El tee/hoyo de inicio Tee Times no existe o no está activo.'
            USING ERRCODE = '23514';
    END IF;

    IF v_group.tournament_round_shift_id IS DISTINCT FROM
       v_cfg.tournament_round_shift_id
       OR v_group.tournament_round_shift_id IS DISTINCT FROM
       v_start.tournament_round_shift_id
    THEN
        RAISE EXCEPTION
            'Grupo, categoría y tee de inicio Tee Times pertenecen a turnos diferentes.'
            USING ERRCODE = '23514';
    END IF;

    IF v_group.hoyo_id IS DISTINCT FROM v_start.hoyo_id THEN
        RAISE EXCEPTION
            'El hoyo del grupo no coincide con el tee/hoyo de inicio Tee Times.'
            USING ERRCODE = '23514';
    END IF;

    IF v_group.tournament_shotgun_category_hole_id IS NOT NULL
       OR v_group.posicion_salida IS NOT NULL
    THEN
        RAISE EXCEPTION
            'Un grupo Tee Times no debe contener campos específicos de Shotgun.'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_validar_vinculo_grupo_tee_times
ON public.tournament_tee_time_groups;

CREATE TRIGGER trg_validar_vinculo_grupo_tee_times
BEFORE INSERT OR UPDATE
ON public.tournament_tee_time_groups
FOR EACH ROW
EXECUTE FUNCTION public.validar_vinculo_grupo_tee_times();


-- ============================================================================
-- 04. PROTEGER METADATA TEE TIMES DESPUÉS DE VALIDAR SALIDAS
-- ============================================================================
DROP TRIGGER IF EXISTS trg_proteger_cierre_salidas_tee_times
ON public.tournament_tee_time_groups;

CREATE TRIGGER trg_proteger_cierre_salidas_tee_times
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_tee_time_groups
FOR EACH ROW
EXECUTE FUNCTION public._proteger_objeto_salida_ronda_validada();


-- ============================================================================
-- 05. RLS
-- ============================================================================
ALTER TABLE public.tournament_tee_time_groups
ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tee_time_groups_select
ON public.tournament_tee_time_groups;

CREATE POLICY tee_time_groups_select
ON public.tournament_tee_time_groups
FOR SELECT
USING (
    public.is_superadmin(auth.uid())
    OR EXISTS (
        SELECT 1
        FROM public.tournament_groups g
        JOIN public.tournament_round_shifts rs
          ON rs.id = g.tournament_round_shift_id
        JOIN public.tournament_rounds tr
          ON tr.id = rs.tournament_round_id
        JOIN public.tournaments t
          ON t.id = tr.tournament_id
        WHERE g.id = tournament_tee_time_groups.tournament_group_id
          AND (
              public.is_tournament_organizer(auth.uid(), t.id)
              OR public.is_club_admin(auth.uid(), t.club_id)
          )
    )
);

DROP POLICY IF EXISTS tee_time_groups_write
ON public.tournament_tee_time_groups;

CREATE POLICY tee_time_groups_write
ON public.tournament_tee_time_groups
FOR ALL
TO authenticated
USING (
    public.is_superadmin(auth.uid())
    OR EXISTS (
        SELECT 1
        FROM public.tournament_groups g
        JOIN public.tournament_round_shifts rs
          ON rs.id = g.tournament_round_shift_id
        JOIN public.tournament_rounds tr
          ON tr.id = rs.tournament_round_id
        JOIN public.tournaments t
          ON t.id = tr.tournament_id
        WHERE g.id = tournament_tee_time_groups.tournament_group_id
          AND (
              public.is_tournament_organizer(auth.uid(), t.id)
              OR public.is_club_admin(auth.uid(), t.club_id)
          )
    )
)
WITH CHECK (
    public.is_superadmin(auth.uid())
    OR EXISTS (
        SELECT 1
        FROM public.tournament_groups g
        JOIN public.tournament_round_shifts rs
          ON rs.id = g.tournament_round_shift_id
        JOIN public.tournament_rounds tr
          ON tr.id = rs.tournament_round_id
        JOIN public.tournaments t
          ON t.id = tr.tournament_id
        WHERE g.id = tournament_tee_time_groups.tournament_group_id
          AND (
              public.is_tournament_organizer(auth.uid(), t.id)
              OR public.is_club_admin(auth.uid(), t.club_id)
          )
    )
);


-- ============================================================================
-- 06. HELPERS DE HORARIO
-- ============================================================================
CREATE OR REPLACE FUNCTION public.hora_salida_tee_time(
    p_start_hole_id uuid,
    p_sequence_number integer
)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_fecha date;
    v_hora time;
    v_intervalo integer;
    v_offset integer;
    v_tz text;
BEGIN
    IF p_sequence_number IS NULL OR p_sequence_number < 1 THEN
        RAISE EXCEPTION
            'La secuencia Tee Times debe ser mayor o igual a 1.'
            USING ERRCODE = '22023';
    END IF;

    SELECT
        tr.fecha,
        rs.hora_salida,
        cfg.intervalo_grupos_minutos,
        sh.offset_inicio_minutos,
        COALESCE(c.timezone, 'America/Mexico_City')
      INTO
        v_fecha,
        v_hora,
        v_intervalo,
        v_offset,
        v_tz
      FROM public.tournament_tee_time_shift_start_holes sh
      JOIN public.tournament_tee_time_shift_configs cfg
        ON cfg.id = sh.tournament_tee_time_shift_config_id
       AND cfg.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = cfg.tournament_round_shift_id
       AND rs.activo
      JOIN public.tournament_rounds tr
        ON tr.id = rs.tournament_round_id
       AND tr.activo
      JOIN public.tournaments t
        ON t.id = tr.tournament_id
      JOIN public.clubs c
        ON c.id = t.club_id
     WHERE sh.id = p_start_hole_id
       AND sh.activo;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No existe un tee/hoyo de inicio Tee Times activo.'
            USING ERRCODE = '22023';
    END IF;

    RETURN (
        (
            v_fecha::timestamp
            + v_hora
            + make_interval(
                mins => v_offset
                    + ((p_sequence_number - 1) * v_intervalo)
            )
        ) AT TIME ZONE v_tz
    );
END;
$function$;


-- ============================================================================
-- 07. OBTENER PREPARACIÓN TEE TIMES DE UN TURNO
-- ============================================================================
CREATE OR REPLACE FUNCTION public.obtener_conformacion_tee_times(
    p_shift_config_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_shift_id uuid;
    v_round_id uuid;
    v_tournament_id uuid;
    v_result jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        cfg.tournament_round_shift_id,
        rs.tournament_round_id,
        tr.tournament_id
      INTO
        v_shift_id,
        v_round_id,
        v_tournament_id
      FROM public.tournament_tee_time_shift_configs cfg
      JOIN public.tournament_round_shifts rs
        ON rs.id = cfg.tournament_round_shift_id
      JOIN public.tournament_rounds tr
        ON tr.id = rs.tournament_round_id
     WHERE cfg.id = p_shift_config_id
       AND cfg.activo;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La configuración Tee Times del turno no existe o está inactiva.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar esta conformación Tee Times.'
            USING ERRCODE = '42501';
    END IF;

    SELECT jsonb_build_object(
        'shiftConfigId', p_shift_config_id,
        'tournamentRoundShiftId', v_shift_id,
        'roundId', v_round_id,

        'groups', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'groupId', g.id,
                    'teeTimeGroupId', ttg.id,
                    'categoryConfigId',
                        ttg.tournament_tee_time_category_config_id,
                    'startHoleId',
                        ttg.tournament_tee_time_start_hole_id,
                    'hoyoId', g.hoyo_id,
                    'numeroHoyo', h.numero_hoyo,
                    'sequenceNumber', ttg.sequence_number,
                    'horaSalida', g.hora_salida,
                    'etiqueta', g.etiqueta,
                    'unidades', COALESCE((
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'id',
                                    gp.tournament_registration_id,
                                'orden',
                                    gp.orden_en_grupo
                            )
                            ORDER BY
                                gp.orden_en_grupo NULLS LAST,
                                gp.created_at,
                                gp.id
                        )
                        FROM public.tournament_group_players gp
                        WHERE gp.tournament_group_id = g.id
                    ), '[]'::jsonb)
                )
                ORDER BY
                    sh.lane_order,
                    ttg.sequence_number,
                    g.id
            )
            FROM public.tournament_tee_time_groups ttg
            JOIN public.tournament_groups g
              ON g.id = ttg.tournament_group_id
             AND g.activo
            JOIN public.tournament_tee_time_shift_start_holes sh
              ON sh.id = ttg.tournament_tee_time_start_hole_id
            JOIN public.hoyos h
              ON h.id = g.hoyo_id
            WHERE sh.tournament_tee_time_shift_config_id =
                p_shift_config_id
              AND ttg.activo
        ), '[]'::jsonb),

        'materialized', EXISTS (
            SELECT 1
            FROM public.tournament_tee_time_groups ttg
            JOIN public.tournament_tee_time_shift_start_holes sh
              ON sh.id = ttg.tournament_tee_time_start_hole_id
            WHERE sh.tournament_tee_time_shift_config_id =
                p_shift_config_id
              AND ttg.activo
        )
    )
    INTO v_result;

    RETURN v_result;
END;
$function$;


-- ============================================================================
-- 08. MATERIALIZAR CONFORMACIÓN TEE TIMES — TURNO COMPLETO
--
-- Payload esperado:
-- [
--   {
--     "categoryConfigId": "<uuid>",
--     "startHoleId": "<uuid>",
--     "sequenceNumber": 1,
--     "unidades": ["<registration uuid>", ...]
--   }
-- ]
--
-- No calcula automáticamente quién juega con quién.
-- La UI/preparador decide la conformación y esta RPC la valida/materializa.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.materializar_conformacion_tee_times(
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
    v_format_type text;
    v_scoring_engine text;

    v_group jsonb;
    v_category_config_id uuid;
    v_start_hole_id uuid;
    v_sequence integer;
    v_maximo integer;
    v_category_id uuid;
    v_hoyo_id uuid;
    v_hora timestamptz;

    v_group_id uuid;
    v_unit_text text;
    v_unit_id uuid;
    v_orden integer;

    v_num_grupos integer := 0;
    v_result jsonb := '[]'::jsonb;
    v_total_slots integer;
    v_distinct_slots integer;
    v_total_units integer;
    v_distinct_units integer;
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
        tf.tipo_participacion::text,
        tf.scoring_engine::text
      INTO
        v_shift_id,
        v_round_id,
        v_tournament_id,
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
            'Esta fase de Tee Times sólo prepara Stroke Play individual.'
            USING ERRCODE = '0A000';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para materializar esta conformación Tee Times.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(v_round_id);

    IF jsonb_typeof(p_grupos) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION
            'p_grupos debe ser un arreglo JSON.'
            USING ERRCODE = '22023';
    END IF;

    IF jsonb_array_length(p_grupos) = 0 THEN
        RAISE EXCEPTION
            'Debe existir al menos un grupo Tee Times para materializar.'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_tee_time_groups ttg
        JOIN public.tournament_tee_time_shift_start_holes sh
          ON sh.id = ttg.tournament_tee_time_start_hole_id
        WHERE sh.tournament_tee_time_shift_config_id =
            p_shift_config_id
    ) THEN
        RAISE EXCEPTION
            'Este turno Tee Times ya tiene una conformación persistida.'
            USING ERRCODE = '23505';
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

    -- Ningún slot stream/secuencia puede repetirse.
    SELECT
        count(*),
        count(
            DISTINCT (
                (e.value->>'startHoleId')
                || ':'
                || (e.value->>'sequenceNumber')
            )
        )
      INTO
        v_total_slots,
        v_distinct_slots
      FROM jsonb_array_elements(p_grupos) e(value);

    IF v_total_slots <> v_distinct_slots THEN
        RAISE EXCEPTION
            'El payload contiene posiciones Tee Times repetidas.'
            USING ERRCODE = '23514';
    END IF;

    -- Ninguna inscripción puede aparecer dos veces en el turno.
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

    SELECT au.id
      INTO v_actor_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = v_auth_uid
       AND au.activo
     LIMIT 1;

    IF v_actor_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    FOR v_group IN
        SELECT value
        FROM jsonb_array_elements(p_grupos)
    LOOP
        IF jsonb_array_length(v_group->'unidades') = 0 THEN
            CONTINUE;
        END IF;

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
                'La configuración de categoría Tee Times no pertenece al turno activo.'
                USING ERRCODE = '23514';
        END IF;

        IF jsonb_array_length(v_group->'unidades') > v_maximo THEN
            RAISE EXCEPTION
                'Un grupo excede el máximo permitido de % jugadores.',
                v_maximo
                USING ERRCODE = '23514';
        END IF;

        SELECT sh.hoyo_id
          INTO v_hoyo_id
          FROM public.tournament_tee_time_shift_start_holes sh
         WHERE sh.id = v_start_hole_id
           AND sh.tournament_tee_time_shift_config_id =
               p_shift_config_id
           AND sh.activo;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'El tee/hoyo de inicio indicado no pertenece a la configuración Tee Times activa.'
                USING ERRCODE = '23514';
        END IF;

        v_hora :=
            public.hora_salida_tee_time(
                v_start_hole_id,
                v_sequence
            );

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
                to_char(v_hora AT TIME ZONE 'America/Mexico_City', 'HH24:MI')
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

        v_orden := 0;

        FOR v_unit_text IN
            SELECT value
            FROM jsonb_array_elements_text(
                v_group->'unidades'
            )
        LOOP
            v_unit_id := v_unit_text::uuid;
            v_orden := v_orden + 1;

            PERFORM 1
            FROM public.tournament_registrations reg
            WHERE reg.id = v_unit_id
              AND reg.tournament_id = v_tournament_id
              AND reg.tournament_category_id = v_category_id
              AND reg.activo;

            IF NOT FOUND THEN
                RAISE EXCEPTION
                    'La inscripción % no está activa o no pertenece a la categoría del grupo Tee Times.',
                    v_unit_id
                    USING ERRCODE = '23514';
            END IF;

            -- No permitir que esté ya asignada en otro grupo de la ronda.
            IF EXISTS (
                SELECT 1
                FROM public.tournament_group_players gp
                JOIN public.tournament_groups g
                  ON g.id = gp.tournament_group_id
                 AND g.activo
                JOIN public.tournament_round_shifts rs
                  ON rs.id = g.tournament_round_shift_id
                WHERE gp.tournament_registration_id =
                    v_unit_id
                  AND rs.tournament_round_id = v_round_id
            ) THEN
                RAISE EXCEPTION
                    'La inscripción % ya está asignada a otro grupo de la ronda.',
                    v_unit_id
                    USING ERRCODE = '23514';
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
        END LOOP;

        v_result :=
            v_result || jsonb_build_array(
                jsonb_build_object(
                    'groupId', v_group_id,
                    'categoryConfigId',
                        v_category_config_id,
                    'startHoleId',
                        v_start_hole_id,
                    'sequenceNumber',
                        v_sequence,
                    'hoyoId',
                        v_hoyo_id,
                    'horaSalida',
                        v_hora
                )
            );

        v_num_grupos := v_num_grupos + 1;
    END LOOP;

    IF v_num_grupos = 0 THEN
        RAISE EXCEPTION
            'No hay grupos con jugadores para materializar.'
            USING ERRCODE = '22023';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'materialized', true,
        'groupsCreated', v_num_grupos,
        'groups', v_result
    );
END;
$function$;


-- ============================================================================
-- 09. CONSTRUCTOR DE CONTRATO COMÚN TEE TIMES V2
--
-- Ya puede producir el contrato común a partir de los grupos preparados,
-- pero todavía NO se registra como validable/emisible.
-- ============================================================================
CREATE OR REPLACE FUNCTION public._construir_contrato_salida_tee_times_v1(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH ctx AS (
        SELECT
            tr.id AS round_id,
            tr.tournament_id,
            f.id AS freeze_id,
            rcs.id AS round_condition_snapshot_id,
            tr.numero_ronda,
            tr.fecha,
            tr.formato_salida::text AS start_format,
            rcs.format_code,
            rcs.format_name,
            rcs.participation_type,
            rcs.scoring_engine
        FROM public.tournament_rounds tr
        JOIN public.tournament_condition_freezes f
          ON f.tournament_id = tr.tournament_id
        JOIN public.tournament_round_condition_snapshots rcs
          ON rcs.freeze_id = f.id
         AND rcs.tournament_round_id = tr.id
        WHERE tr.id = p_tournament_round_id
    ),
    group_rows AS (
        SELECT
            g.id AS group_id,
            ttg.tournament_tee_time_category_config_id AS config_id,
            rs.id AS shift_id,
            sc.id AS shift_category_id,
            sc.tournament_category_id,
            ttg.tournament_tee_time_start_hole_id AS format_slot_id,
            g.hoyo_id,
            hole.hole_number,
            g.hora_salida,
            rs.numero_turno,
            rs.hora_salida AS shift_time,
            g.etiqueta,
            cfg.tamano_grupo_normal,
            cfg.tamano_grupo_maximo,
            ttg.sequence_number,
            sh.lane_order
        FROM ctx
        JOIN public.tournament_round_shifts rs
          ON rs.tournament_round_id = ctx.round_id
         AND rs.activo
        JOIN public.tournament_groups g
          ON g.tournament_round_shift_id = rs.id
         AND g.activo
        JOIN public.tournament_tee_time_groups ttg
          ON ttg.tournament_group_id = g.id
         AND ttg.activo
        JOIN public.tournament_tee_time_category_configs cfg
          ON cfg.id = ttg.tournament_tee_time_category_config_id
         AND cfg.activo
        JOIN public.tournament_round_shift_categories sc
          ON sc.id = cfg.tournament_round_shift_category_id
         AND sc.activo
        JOIN public.tournament_tee_time_shift_start_holes sh
          ON sh.id = ttg.tournament_tee_time_start_hole_id
         AND sh.activo
        JOIN public.tournament_round_hole_snapshots hole
          ON hole.tournament_round_id = ctx.round_id
         AND hole.source_hole_id = g.hoyo_id
    ),
    groups_json AS (
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'sourceGroupId', gr.group_id,
                    'sourceConfigId', gr.config_id,
                    'sourceShiftId', gr.shift_id,
                    'sourceShiftCategoryId',
                        gr.shift_category_id,
                    'tournamentCategoryId',
                        gr.tournament_category_id,

                    'sourceFormatSlotId',
                        gr.format_slot_id,
                    'sourceHoleId',
                        gr.hoyo_id,
                    'holeNumber',
                        gr.hole_number,
                    'startAt',
                        gr.hora_salida,
                    'startPosition',
                        NULL,

                    'shiftNumber',
                        gr.numero_turno,
                    'shiftTime',
                        gr.shift_time,
                    'groupLabel',
                        gr.etiqueta,
                    'normalSize',
                        gr.tamano_grupo_normal,
                    'maximumSize',
                        gr.tamano_grupo_maximo,

                    'units', COALESCE((
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'unitType',
                                    'registration',
                                'registrationId',
                                    gp.tournament_registration_id,
                                'teamId',
                                    NULL,
                                'playerId',
                                    hs.player_id,
                                'name',
                                    hs.player_name,
                                'folio',
                                    hs.registration_folio,
                                'orderInGroup',
                                    gp.orden_en_grupo,
                                'handicapSnapshotId',
                                    hs.id,
                                'roundHandicapSnapshotId',
                                    rhs.id,
                                'teeId',
                                    rhs.tee_id,
                                'handicapIndex',
                                    hs.handicap_index,
                                'courseHandicap',
                                    rhs.course_handicap,
                                'playingHandicap',
                                    rhs.playing_handicap
                            )
                            ORDER BY
                                gp.orden_en_grupo,
                                gp.id
                        )
                        FROM public.tournament_group_players gp
                        JOIN public.tournament_round_handicap_snapshots rhs
                          ON rhs.tournament_round_id =
                             p_tournament_round_id
                         AND rhs.tournament_registration_id =
                             gp.tournament_registration_id
                        JOIN public.tournament_handicap_snapshots hs
                          ON hs.id = rhs.handicap_snapshot_id
                        WHERE gp.tournament_group_id =
                            gr.group_id
                    ), '[]'::jsonb),

                    'formatMetadata',
                        jsonb_build_object(
                            'startFormat',
                                'tee_times',
                            'sequenceNumber',
                                gr.sequence_number,
                            'laneOrder',
                                gr.lane_order
                        )
                )
                ORDER BY
                    gr.numero_turno,
                    gr.lane_order,
                    gr.sequence_number,
                    gr.group_id
            ),
            '[]'::jsonb
        ) AS data
        FROM group_rows gr
    )
    SELECT jsonb_build_object(
        'schemaVersion', 2,
        'contract', 'tee_central_round_start',
        'contractVersion', 2,

        'preparationEngine',
            'tee_times_v1',
        'validationEngine',
            'stroke_individual_tee_times_v1',

        'freezeId',
            ctx.freeze_id,
        'roundConditionSnapshotId',
            ctx.round_condition_snapshot_id,

        'tournament',
            jsonb_build_object(
                'id', ctx.tournament_id
            ),

        'round',
            jsonb_build_object(
                'id', ctx.round_id,
                'number', ctx.numero_ronda,
                'date', ctx.fecha,
                'startFormat', ctx.start_format
            ),

        'format',
            jsonb_build_object(
                'code', ctx.format_code,
                'name', ctx.format_name,
                'participationType',
                    ctx.participation_type,
                'scoringEngine',
                    ctx.scoring_engine
            ),

        'groups',
            gj.data
    )
    FROM ctx
    CROSS JOIN groups_json gj;
$function$;


-- ============================================================================
-- 10. CONECTAR CON EL DISPATCHER DEL CONTRATO COMÚN
--
-- Esto NO habilita validación: sólo permite construir el contrato Tee Times.
-- ============================================================================
CREATE OR REPLACE FUNCTION public._construir_contrato_salida_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_engine jsonb;
    v_start_format text;
    v_preparation_engine text;
BEGIN
    v_engine :=
        public.obtener_motor_salida_ronda(
            p_tournament_round_id
        );

    IF NOT COALESCE(
        (v_engine->>'supported')::boolean,
        false
    ) THEN
        RAISE EXCEPTION
            'No existe un motor de salida activo para esta combinación de formato, participación y puntuación.'
            USING ERRCODE = '0A000',
                  DETAIL = v_engine::text;
    END IF;

    v_start_format := v_engine->>'startFormat';
    v_preparation_engine :=
        v_engine #>> '{engine,preparationEngine}';

    IF v_start_format = 'shotgun'
       AND v_preparation_engine = 'shotgun_v1'
    THEN
        RETURN public._construir_contrato_salida_shotgun_v2(
            p_tournament_round_id
        );
    END IF;

    IF v_start_format = 'tee_times'
       AND v_preparation_engine = 'tee_times_v1'
    THEN
        RETURN public._construir_contrato_salida_tee_times_v1(
            p_tournament_round_id
        );
    END IF;

    RAISE EXCEPTION
        'El motor de preparación % para formato % todavía no tiene constructor de contrato implementado.',
        COALESCE(v_preparation_engine, 'NULL'),
        COALESCE(v_start_format, 'NULL')
        USING ERRCODE = '0A000',
              DETAIL = v_engine::text;
END;
$function$;


-- ============================================================================
-- 11. PRIVILEGIOS
-- ============================================================================
REVOKE ALL
ON TABLE public.tournament_tee_time_groups
FROM PUBLIC, anon;

GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLE public.tournament_tee_time_groups
TO authenticated;

GRANT ALL
ON TABLE public.tournament_tee_time_groups
TO service_role;

REVOKE ALL
ON FUNCTION public.hora_salida_tee_time(uuid,integer)
FROM PUBLIC, anon, authenticated;

REVOKE ALL
ON FUNCTION public._construir_contrato_salida_tee_times_v1(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.hora_salida_tee_time(uuid,integer)
TO service_role;

GRANT EXECUTE
ON FUNCTION public._construir_contrato_salida_tee_times_v1(uuid)
TO service_role;

REVOKE ALL
ON FUNCTION public.obtener_conformacion_tee_times(uuid)
FROM PUBLIC, anon;

REVOKE ALL
ON FUNCTION public.materializar_conformacion_tee_times(uuid,jsonb)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.obtener_conformacion_tee_times(uuid)
TO authenticated, service_role;

GRANT EXECUTE
ON FUNCTION public.materializar_conformacion_tee_times(uuid,jsonb)
TO authenticated, service_role;


COMMIT;
