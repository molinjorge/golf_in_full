BEGIN;

-- 431: La preparación grupal previa al pago es un BORRADOR recuperable.
-- Ninguna inscripción formal se crea aquí; tournament_registrations continúa
-- naciendo exclusivamente después de pago aprobado.

CREATE OR REPLACE FUNCTION public.obtener_borrador_inscripcion_grupal_431(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_player_id uuid;
    v_player public.players%ROWTYPE;
    v_team public.tournament_teams%ROWTYPE;
    v_initial_slot public.tournament_team_roster_slots%ROWTYPE;
    v_slots jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión.' USING ERRCODE = '42501';
    END IF;

    v_player_id := public._current_player_id_199();
    IF v_player_id IS NULL THEN
        RAISE EXCEPTION 'No se encontró un perfil de jugador activo para esta sesión.'
            USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_player
      FROM public.players
     WHERE id = v_player_id AND activo = true;

    -- Un borrador grupal 226/227 se reconoce por:
    -- equipo activo sin capitán + slot del iniciador member/confirmed,
    -- todavía sin inscripción y sin cobertura económica aprobada.
    SELECT tt.*
      INTO v_team
      FROM public.tournament_teams tt
      JOIN public.tournament_team_roster_slots rs
        ON rs.tournament_team_id = tt.id
       AND rs.tournament_id = tt.tournament_id
     WHERE tt.tournament_id = p_tournament_id
       AND tt.activo = true
       AND tt.captain_player_id IS NULL
       AND rs.player_id = v_player_id
       AND lower(rs.email::text) = lower(v_player.email::text)
       AND rs.role = 'member'
       AND rs.status = 'confirmed'
       AND rs.tournament_registration_id IS NULL
       AND rs.payment_coverage_id IS NULL
       AND NOT EXISTS (
            SELECT 1 FROM public.tournament_registrations tr
             WHERE tr.tournament_team_id = tt.id AND tr.activo = true
       )
       AND NOT EXISTS (
            SELECT 1 FROM public.tournament_team_payment_coverages c
             WHERE c.tournament_team_id = tt.id AND c.status = 'paid'
       )
     ORDER BY tt.created_at DESC, tt.id DESC
     LIMIT 1;

    IF v_team.id IS NULL THEN
        RETURN jsonb_build_object('found', false, 'status', 'none');
    END IF;

    SELECT * INTO v_initial_slot
      FROM public.tournament_team_roster_slots rs
     WHERE rs.tournament_team_id = v_team.id
       AND rs.player_id = v_player_id
       AND rs.status = 'confirmed'
       AND rs.tournament_registration_id IS NULL
       AND rs.payment_coverage_id IS NULL
     ORDER BY rs.created_at, rs.id
     LIMIT 1;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'slotId', rs.id,
        'role', rs.role,
        'playerId', rs.player_id,
        'playerName', rs.nombre_completo,
        'email', rs.email,
        'slotStatus', rs.status,
        'requiresConfirmation', rs.status = 'pending_confirmation',
        'economicallyCovered', rs.payment_coverage_id IS NOT NULL,
        'registrationId', rs.tournament_registration_id
    ) ORDER BY rs.created_at, rs.id), '[]'::jsonb)
      INTO v_slots
      FROM public.tournament_team_roster_slots rs
     WHERE rs.tournament_team_id = v_team.id
       AND rs.status IN ('pending_confirmation','confirmed');

    RETURN jsonb_build_object(
        'found', true,
        'status', 'prepared',
        'teamId', v_team.id,
        'teamName', v_team.nombre_equipo,
        'slotId', v_initial_slot.id,
        'playerId', v_player_id,
        'slots', v_slots
    );
END;
$function$;

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
    v_existing_team public.tournament_teams%ROWTYPE;
    v_existing_slot public.tournament_team_roster_slots%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión.' USING ERRCODE = '42501';
    END IF;

    v_player_id := public._current_player_id_199();
    IF v_player_id IS NULL THEN
        RAISE EXCEPTION 'No se encontró un perfil de jugador activo para esta sesión.' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_player FROM public.players WHERE id=v_player_id AND activo=true;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró un perfil de jugador activo para esta sesión.' USING ERRCODE='42501';
    END IF;

    SELECT tf.tipo_participacion,t.estatus,t.jugadores_por_equipo
      INTO v_tipo_participacion,v_estatus,v_jugadores_por_equipo
      FROM public.tournaments t
      JOIN public.tournament_formats tf ON tf.id=t.tournament_format_id AND tf.activo=true
     WHERE t.id=p_tournament_id AND t.activo=true
     FOR SHARE OF t;

    IF NOT FOUND THEN RAISE EXCEPTION 'El torneo indicado no existe o está inactivo.' USING ERRCODE='22023'; END IF;
    IF v_tipo_participacion <> 'equipo'::public.formato_juego_torneo THEN
        RAISE EXCEPTION 'La inscripción grupal sólo aplica a torneos por equipos.' USING ERRCODE='22023';
    END IF;
    IF v_estatus <> 'inscripciones_abiertas'::public.estatus_torneo THEN
        RAISE EXCEPTION 'Las inscripciones del torneo no están abiertas.' USING ERRCODE='55000';
    END IF;
    IF v_jugadores_por_equipo IS NULL OR v_jugadores_por_equipo <= 0 THEN
        RAISE EXCEPTION 'El torneo no tiene configurado correctamente el número de jugadores por equipo.' USING ERRCODE='23514';
    END IF;

    v_nombre_equipo := NULLIF(btrim(p_nombre_equipo),'');
    IF v_nombre_equipo IS NULL THEN RAISE EXCEPTION 'Debes indicar el nombre del equipo.' USING ERRCODE='22023'; END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(p_tournament_id::text || ':group-registration-player:' || v_player_id::text,226));

    -- 431: si el mismo jugador ya tiene SU borrador grupal no pagado,
    -- la operación es idempotente y devuelve el mismo team/slot.
    SELECT tt.*
      INTO v_existing_team
      FROM public.tournament_teams tt
      JOIN public.tournament_team_roster_slots rs ON rs.tournament_team_id=tt.id
     WHERE tt.tournament_id=p_tournament_id
       AND tt.activo=true
       AND tt.captain_player_id IS NULL
       AND rs.player_id=v_player_id
       AND lower(rs.email::text)=lower(v_player.email::text)
       AND rs.role='member'
       AND rs.status='confirmed'
       AND rs.tournament_registration_id IS NULL
       AND rs.payment_coverage_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.tournament_registrations tr WHERE tr.tournament_team_id=tt.id AND tr.activo=true)
       AND NOT EXISTS (SELECT 1 FROM public.tournament_team_payment_coverages c WHERE c.tournament_team_id=tt.id AND c.status='paid')
     ORDER BY tt.created_at DESC,tt.id DESC
     LIMIT 1;

    IF v_existing_team.id IS NOT NULL THEN
        SELECT * INTO v_existing_slot
          FROM public.tournament_team_roster_slots rs
         WHERE rs.tournament_team_id=v_existing_team.id
           AND rs.player_id=v_player_id
           AND rs.status='confirmed'
           AND rs.tournament_registration_id IS NULL
           AND rs.payment_coverage_id IS NULL
         ORDER BY rs.created_at,rs.id LIMIT 1;

        RETURN jsonb_build_object(
            'teamId',v_existing_team.id,'slotId',v_existing_slot.id,
            'teamName',v_existing_team.nombre_equipo,'playerId',v_player_id,
            'playerName',btrim(concat_ws(' ',v_player.nombres,v_player.apellidos)),
            'email',v_player.email,'role','member','slotStatus','confirmed',
            'captainPlayerId',NULL,'status','recovered','recoveredDraft',true
        );
    END IF;

    -- Conflictos reales distintos del propio borrador recuperable.
    IF EXISTS (SELECT 1 FROM public.tournament_registrations tr WHERE tr.tournament_id=p_tournament_id AND tr.player_id=v_player_id AND tr.activo=true) THEN
        RAISE EXCEPTION 'Ya tienes una inscripción activa en este torneo.' USING ERRCODE='23505', DETAIL='GROUP_REGISTRATION_ACTIVE_REGISTRATION';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.tournament_team_roster_slots rs
         WHERE rs.tournament_id=p_tournament_id
           AND rs.status IN ('pending_confirmation','confirmed')
           AND (rs.player_id=v_player_id OR lower(rs.email::text)=lower(v_player.email::text))
    ) THEN
        RAISE EXCEPTION 'Ya formas parte de otro equipo o tienes una invitación activa en este torneo.' USING ERRCODE='23505', DETAIL='GROUP_REGISTRATION_ACTIVE_ROSTER';
    END IF;

    IF EXISTS (SELECT 1 FROM public.tournament_pre_reservations pr WHERE pr.tournament_id=p_tournament_id AND pr.player_id=v_player_id AND pr.activo=true AND pr.tournament_registration_id IS NULL) THEN
        RAISE EXCEPTION 'Ya tienes una pre-reserva activa en este torneo. Debe resolverse antes de crear un equipo.' USING ERRCODE='23505', DETAIL='GROUP_REGISTRATION_ACTIVE_PRERESERVATION';
    END IF;
    IF EXISTS (SELECT 1 FROM public.phone_reservations ph WHERE ph.tournament_id=p_tournament_id AND ph.correo=v_player.email AND ph.activo=true) THEN
        RAISE EXCEPTION 'Ya existe una reserva activa para tu correo en este torneo. Debe resolverse antes de crear un equipo.' USING ERRCODE='23505', DETAIL='GROUP_REGISTRATION_ACTIVE_PHONE_RESERVATION';
    END IF;

    v_nombre_completo := btrim(concat_ws(' ',v_player.nombres,v_player.apellidos));
    IF v_nombre_completo='' THEN RAISE EXCEPTION 'El perfil del jugador no tiene un nombre válido.' USING ERRCODE='23514'; END IF;

    INSERT INTO public.tournament_teams(tournament_id,nombre_equipo,tournament_category_id,captain_player_id)
    VALUES(p_tournament_id,v_nombre_equipo,NULL,NULL) RETURNING id INTO v_team_id;

    INSERT INTO public.tournament_team_roster_slots(
        tournament_id,tournament_team_id,role,nombre_completo,email,player_id,status,
        tournament_registration_id,invited_by_player_id,confirmed_at,payment_coverage_id,
        economically_covered_at,economically_covered_amount)
    VALUES(p_tournament_id,v_team_id,'member',v_nombre_completo,v_player.email,v_player_id,'confirmed',
           NULL,v_player_id,now(),NULL,NULL,NULL)
    RETURNING id INTO v_slot_id;

    RETURN jsonb_build_object(
        'teamId',v_team_id,'slotId',v_slot_id,'teamName',v_nombre_equipo,'playerId',v_player_id,
        'playerName',v_nombre_completo,'email',v_player.email,'role','member','slotStatus','confirmed',
        'captainPlayerId',NULL,'status','prepared','recoveredDraft',false
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.cancelar_borrador_inscripcion_grupal_431(p_team_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_player_id uuid;
    v_team public.tournament_teams%ROWTYPE;
    v_cancelled_slots integer := 0;
    v_cancelled_attempts integer := 0;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Debes iniciar sesión.' USING ERRCODE='42501'; END IF;
    v_player_id := public._current_player_id_199();
    IF v_player_id IS NULL THEN RAISE EXCEPTION 'No se encontró un perfil de jugador activo para esta sesión.' USING ERRCODE='42501'; END IF;

    SELECT * INTO v_team FROM public.tournament_teams WHERE id=p_team_id FOR UPDATE;
    IF v_team.id IS NULL OR NOT v_team.activo THEN RAISE EXCEPTION 'El borrador indicado no existe o ya no está activo.' USING ERRCODE='22023'; END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(v_team.tournament_id::text || ':group-registration-player:' || v_player_id::text,226));

    IF NOT EXISTS (
        SELECT 1 FROM public.tournament_team_roster_slots rs
         WHERE rs.tournament_team_id=p_team_id AND rs.player_id=v_player_id
           AND rs.role='member' AND rs.status='confirmed'
           AND rs.tournament_registration_id IS NULL AND rs.payment_coverage_id IS NULL
    ) THEN
        RAISE EXCEPTION 'Este borrador no pertenece al jugador actual.' USING ERRCODE='42501';
    END IF;

    IF EXISTS (SELECT 1 FROM public.tournament_registrations tr WHERE tr.tournament_team_id=p_team_id AND tr.activo=true) THEN
        RAISE EXCEPTION 'El equipo ya tiene inscripciones formales y no puede cancelarse como borrador.' USING ERRCODE='55000';
    END IF;
    IF EXISTS (SELECT 1 FROM public.tournament_team_payment_coverages c WHERE c.tournament_team_id=p_team_id AND c.status='paid') THEN
        RAISE EXCEPTION 'El equipo ya tiene un pago aprobado y no puede cancelarse como borrador.' USING ERRCODE='55000';
    END IF;

    UPDATE public.payment_attempts
       SET resultado=false, procesado_at=now(), referencia_pago=COALESCE(referencia_pago,'BORRADOR-CANCELADO-431')
     WHERE tournament_team_id=p_team_id AND resultado IS NULL;
    GET DIAGNOSTICS v_cancelled_attempts = ROW_COUNT;

    UPDATE public.tournament_team_roster_slots
       SET status='cancelled', cancelled_at=COALESCE(cancelled_at,now()), updated_at=now()
     WHERE tournament_team_id=p_team_id
       AND status IN ('pending_confirmation','confirmed')
       AND tournament_registration_id IS NULL
       AND payment_coverage_id IS NULL;
    GET DIAGNOSTICS v_cancelled_slots = ROW_COUNT;

    UPDATE public.tournament_teams
       SET activo=false, fecha_baja=now(), motivo_baja='BORRADOR_INSCRIPCION_GRUPAL_CANCELADO_431', updated_at=now()
     WHERE id=p_team_id;

    RETURN jsonb_build_object('cancelled',true,'teamId',p_team_id,'cancelledSlots',v_cancelled_slots,'cancelledPendingAttempts',v_cancelled_attempts);
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_borrador_inscripcion_grupal_431(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancelar_borrador_inscripcion_grupal_431(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_borrador_inscripcion_grupal_431(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancelar_borrador_inscripcion_grupal_431(uuid) TO authenticated;

COMMIT;
