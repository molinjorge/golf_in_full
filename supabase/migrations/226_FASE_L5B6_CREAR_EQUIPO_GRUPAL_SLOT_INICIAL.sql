-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 226 — FASE L5B6
-- Crear equipo grupal sin capitán + slot inicial del jugador
-- ============================================================
-- Objetivo:
--   Crear de forma ATÓMICA, en una sola llamada SQL:
--     1) tournament_team sin capitán obligatorio
--     2) roster slot inicial "TÚ" como member/confirmed
--
-- No crea tournament_registration.
-- No crea payment_attempt.
-- No crea payment coverage.
-- No crea slots de terceros.
-- No modifica contratos 199/223/225.
-- ============================================================

CREATE OR REPLACE FUNCTION public.crear_equipo_grupal_con_slot_inicial(
    p_tournament_id uuid,
    p_nombre_equipo text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_player_id uuid;
    v_player public.players%ROWTYPE;
    v_tipo_participacion public.formato_juego_torneo;
    v_estatus public.estatus_torneo;
    v_jugadores_por_equipo integer;
    v_team_id uuid;
    v_slot_id uuid;
    v_nombre_equipo text;
    v_nombre_completo text;
BEGIN
    -- --------------------------------------------------------
    -- 1. Sesión y jugador autenticado
    -- --------------------------------------------------------
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión.'
            USING ERRCODE = '42501';
    END IF;

    v_player_id := public._current_player_id_199();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION 'No se encontró un perfil de jugador activo para esta sesión.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_player
      FROM public.players
     WHERE id = v_player_id
       AND activo = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró un perfil de jugador activo para esta sesión.'
            USING ERRCODE = '42501';
    END IF;

    -- --------------------------------------------------------
    -- 2. Validar torneo por equipos y abierto a inscripciones
    -- --------------------------------------------------------
    SELECT tf.tipo_participacion,
           t.estatus,
           t.jugadores_por_equipo
      INTO v_tipo_participacion,
           v_estatus,
           v_jugadores_por_equipo
      FROM public.tournaments t
      JOIN public.tournament_formats tf
        ON tf.id = t.tournament_format_id
       AND tf.activo = true
     WHERE t.id = p_tournament_id
       AND t.activo = true
     FOR SHARE OF t;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe o está inactivo.'
            USING ERRCODE = '22023';
    END IF;

    IF v_tipo_participacion <> 'equipo'::public.formato_juego_torneo THEN
        RAISE EXCEPTION 'La inscripción grupal sólo aplica a torneos por equipos.'
            USING ERRCODE = '22023';
    END IF;

    IF v_estatus <> 'inscripciones_abiertas'::public.estatus_torneo THEN
        RAISE EXCEPTION 'Las inscripciones del torneo no están abiertas.'
            USING ERRCODE = '55000';
    END IF;

    IF v_jugadores_por_equipo IS NULL OR v_jugadores_por_equipo <= 0 THEN
        RAISE EXCEPTION 'El torneo no tiene configurado correctamente el número de jugadores por equipo.'
            USING ERRCODE = '23514';
    END IF;

    -- --------------------------------------------------------
    -- 3. Nombre del equipo
    -- --------------------------------------------------------
    v_nombre_equipo := NULLIF(btrim(p_nombre_equipo), '');

    IF v_nombre_equipo IS NULL THEN
        RAISE EXCEPTION 'Debes indicar el nombre del equipo.'
            USING ERRCODE = '22023';
    END IF;

    -- --------------------------------------------------------
    -- 4. Serializar por torneo + jugador
    -- --------------------------------------------------------
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            p_tournament_id::text || ':group-registration-player:' || v_player_id::text,
            226
        )
    );

    -- --------------------------------------------------------
    -- 5. Evitar ocupación/participación previa del iniciador
    -- --------------------------------------------------------
    IF EXISTS (
        SELECT 1
          FROM public.tournament_registrations tr
         WHERE tr.tournament_id = p_tournament_id
           AND tr.player_id = v_player_id
           AND tr.activo = true
    ) THEN
        RAISE EXCEPTION 'Ya tienes una inscripción activa en este torneo.'
            USING ERRCODE = '23505',
                  DETAIL = 'GROUP_REGISTRATION_ACTIVE_REGISTRATION';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM public.tournament_team_roster_slots rs
         WHERE rs.tournament_id = p_tournament_id
           AND rs.status IN ('pending_confirmation', 'confirmed')
           AND (
               rs.player_id = v_player_id
               OR lower(rs.email::text) = lower(v_player.email::text)
           )
    ) THEN
        RAISE EXCEPTION 'Ya formas parte de un equipo o tienes una invitación activa en este torneo.'
            USING ERRCODE = '23505',
                  DETAIL = 'GROUP_REGISTRATION_ACTIVE_ROSTER';
    END IF;

    -- Mantener consistencia con la ocupación que ya protege el roster 199.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_pre_reservations pr
         WHERE pr.tournament_id = p_tournament_id
           AND pr.player_id = v_player_id
           AND pr.activo = true
           AND pr.tournament_registration_id IS NULL
    ) THEN
        RAISE EXCEPTION 'Ya tienes una pre-reserva activa en este torneo. Debe resolverse antes de crear un equipo.'
            USING ERRCODE = '23505',
                  DETAIL = 'GROUP_REGISTRATION_ACTIVE_PRERESERVATION';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM public.phone_reservations ph
         WHERE ph.tournament_id = p_tournament_id
           AND ph.correo = v_player.email
           AND ph.activo = true
    ) THEN
        RAISE EXCEPTION 'Ya existe una reserva activa para tu correo en este torneo. Debe resolverse antes de crear un equipo.'
            USING ERRCODE = '23505',
                  DETAIL = 'GROUP_REGISTRATION_ACTIVE_PHONE_RESERVATION';
    END IF;

    -- --------------------------------------------------------
    -- 6. Identidad canónica del jugador
    -- --------------------------------------------------------
    v_nombre_completo := btrim(concat_ws(' ', v_player.nombres, v_player.apellidos));

    IF v_nombre_completo = '' THEN
        RAISE EXCEPTION 'El perfil del jugador no tiene un nombre válido.'
            USING ERRCODE = '23514';
    END IF;

    -- --------------------------------------------------------
    -- 7. Crear team SIN capitán
    --    tournament_category_id queda NULL; el trigger existente
    --    puede resolver categoría única cuando corresponda.
    -- --------------------------------------------------------
    INSERT INTO public.tournament_teams (
        tournament_id,
        nombre_equipo,
        tournament_category_id,
        captain_player_id
    )
    VALUES (
        p_tournament_id,
        v_nombre_equipo,
        NULL,
        NULL
    )
    RETURNING id
      INTO v_team_id;

    -- --------------------------------------------------------
    -- 8. Crear slot inicial "TÚ" como miembro confirmado
    --    Esta inserción forma parte de la MISMA transacción del RPC.
    --    Si falla, también revierte el INSERT del team.
    -- --------------------------------------------------------
    INSERT INTO public.tournament_team_roster_slots (
        tournament_id,
        tournament_team_id,
        role,
        nombre_completo,
        email,
        player_id,
        status,
        tournament_registration_id,
        invited_by_player_id,
        confirmed_at,
        payment_coverage_id,
        economically_covered_at,
        economically_covered_amount
    )
    VALUES (
        p_tournament_id,
        v_team_id,
        'member',
        v_nombre_completo,
        v_player.email,
        v_player_id,
        'confirmed',
        NULL,
        v_player_id,
        now(),
        NULL,
        NULL,
        NULL
    )
    RETURNING id
      INTO v_slot_id;

    RETURN jsonb_build_object(
        'teamId', v_team_id,
        'slotId', v_slot_id,
        'teamName', v_nombre_equipo,
        'playerId', v_player_id,
        'playerName', v_nombre_completo,
        'email', v_player.email,
        'role', 'member',
        'slotStatus', 'confirmed',
        'captainPlayerId', NULL,
        'status', 'prepared'
    );
END;
$function$;

-- RPC público sólo para jugador autenticado / service role.
REVOKE ALL
ON FUNCTION public.crear_equipo_grupal_con_slot_inicial(uuid, text)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.crear_equipo_grupal_con_slot_inicial(uuid, text)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.crear_equipo_grupal_con_slot_inicial(uuid, text)
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.crear_equipo_grupal_con_slot_inicial(uuid, text)
TO service_role;
