-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 225 - FASE L5A2
-- Incorporar a equipo una inscripción individual ya pagada y aún sin equipo
-- ============================================================================
-- Objetivo:
--   1) Permitir que un integrante autorizado de un equipo invite por correo a
--      un jugador que YA tiene una tournament_registration activa en el mismo
--      torneo, pero con tournament_team_id IS NULL.
--   2) Reservar una plaza del equipo mediante el roster existente.
--   3) Exigir confirmación personal del jugador invitado.
--   4) Al confirmar, mover LA MISMA inscripción existente al equipo, sin crear
--      una segunda inscripción y sin generar un segundo cobro.
--
-- Alcance:
--   - No modifica inscripción individual.
--   - No modifica pagos 200 / 223 / 224.
--   - No crea cobertura económica de equipo artificial para un pago individual.
--   - No permite incorporación si el jugador ya pertenece a otro equipo.
--   - No relaja congelamiento ni validaciones existentes.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1. RPC específico para invitar a un jugador YA INSCRITO/PAGADO sin equipo.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.invitar_inscripcion_pagada_sin_equipo_a_equipo(
    p_team_id uuid,
    p_email public.citext
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_actor_player_id uuid;
    v_team public.tournament_teams%ROWTYPE;
    v_tournament public.tournaments%ROWTYPE;
    v_player public.players%ROWTYPE;
    v_registration public.tournament_registrations%ROWTYPE;
    v_current_occupancy integer;
    v_slot_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión.' USING ERRCODE = '42501';
    END IF;

    IF NULLIF(btrim(p_email::text), '') IS NULL THEN
        RAISE EXCEPTION 'Debes indicar el correo del jugador.' USING ERRCODE = '22023';
    END IF;

    v_actor_player_id := public._current_player_id_199();

    IF v_actor_player_id IS NULL THEN
        RAISE EXCEPTION 'No se encontró un perfil de jugador activo para esta sesión.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_team
      FROM public.tournament_teams
     WHERE id = p_team_id
       AND activo = true;

    IF v_team.id IS NULL THEN
        RAISE EXCEPTION 'El equipo no existe o está inactivo.' USING ERRCODE = '22023';
    END IF;

    SELECT *
      INTO v_tournament
      FROM public.tournaments
     WHERE id = v_team.tournament_id
       AND activo = true;

    IF v_tournament.id IS NULL THEN
        RAISE EXCEPTION 'El torneo no existe o está inactivo.' USING ERRCODE = '22023';
    END IF;

    IF v_tournament.estatus <> 'inscripciones_abiertas'::public.estatus_torneo THEN
        RAISE EXCEPTION 'Las inscripciones del torneo no están abiertas.' USING ERRCODE = '55000';
    END IF;

    -- Reutiliza la autorización de pago grupal 223: capitán/admin del roster o
    -- integrante real/activo del equipo. No convierte al pagador en capitán.
    IF NOT public._puede_pagar_equipo_grupal_223(p_team_id, v_actor_player_id) THEN
        RAISE EXCEPTION 'No tienes permiso para incorporar jugadores a este equipo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_player
      FROM public.players p
     WHERE p.email = btrim(p_email::text)::public.citext
       AND p.activo = true
     LIMIT 1;

    IF v_player.id IS NULL THEN
        RAISE EXCEPTION
            'No existe un jugador activo con ese correo. Usa el flujo normal de invitación del roster.'
            USING ERRCODE = '22023';
    END IF;

    -- Serializar por torneo/jugador para evitar dos invitaciones simultáneas.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            v_team.tournament_id::text || ':paid-unassigned:' || v_player.id::text,
            225
        )
    );

    SELECT *
      INTO v_registration
      FROM public.tournament_registrations tr
     WHERE tr.tournament_id = v_team.tournament_id
       AND tr.player_id = v_player.id
       AND tr.activo = true
     LIMIT 1
     FOR UPDATE;

    IF v_registration.id IS NULL THEN
        RAISE EXCEPTION
            'El jugador no tiene una inscripción activa en este torneo. Usa el flujo normal de invitación.'
            USING ERRCODE = '22023';
    END IF;

    IF v_registration.tournament_team_id IS NOT NULL THEN
        IF v_registration.tournament_team_id = p_team_id THEN
            RAISE EXCEPTION 'Este jugador ya pertenece a este equipo.' USING ERRCODE = '23505';
        ELSE
            RAISE EXCEPTION 'Este jugador ya pertenece a otro equipo en este torneo.' USING ERRCODE = '23505';
        END IF;
    END IF;

    -- No crear un segundo roster activo por correo/player.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_team_roster_slots rs
         WHERE rs.tournament_id = v_team.tournament_id
           AND rs.status IN ('pending_confirmation','confirmed')
           AND (
                rs.player_id = v_player.id
                OR lower(rs.email::text) = lower(v_player.email::text)
           )
    ) THEN
        RAISE EXCEPTION
            'Este jugador ya tiene una invitación activa de equipo en este torneo.'
            USING ERRCODE = '23505';
    END IF;

    v_current_occupancy := public.ocupacion_actual_equipo(p_team_id);

    IF v_tournament.jugadores_por_equipo IS NOT NULL
       AND v_current_occupancy >= v_tournament.jugadores_por_equipo
    THEN
        RAISE EXCEPTION
            'El equipo ya alcanzó su máximo de % integrantes.',
            v_tournament.jugadores_por_equipo
            USING ERRCODE = '23514';
    END IF;

    INSERT INTO public.tournament_team_roster_slots (
        tournament_id,
        tournament_team_id,
        role,
        nombre_completo,
        email,
        player_id,
        status,
        invited_by_player_id
    )
    VALUES (
        v_team.tournament_id,
        p_team_id,
        'member',
        btrim(concat_ws(' ', v_player.nombres, v_player.apellidos)),
        v_player.email,
        v_player.id,
        'pending_confirmation',
        v_actor_player_id
    )
    RETURNING id INTO v_slot_id;

    RETURN jsonb_build_object(
        'slotId', v_slot_id,
        'teamId', p_team_id,
        'tournamentId', v_team.tournament_id,
        'playerId', v_player.id,
        'playerName', btrim(concat_ws(' ', v_player.nombres, v_player.apellidos)),
        'email', v_player.email,
        'existingRegistrationId', v_registration.id,
        'alreadyPaid', true,
        'additionalCharge', 0,
        'status', 'pending_confirmation',
        'requiresConfirmation', true
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.invitar_inscripcion_pagada_sin_equipo_a_equipo(uuid, public.citext) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.invitar_inscripcion_pagada_sin_equipo_a_equipo(uuid, public.citext) FROM anon;
GRANT EXECUTE ON FUNCTION public.invitar_inscripcion_pagada_sin_equipo_a_equipo(uuid, public.citext) TO authenticated;
GRANT EXECUTE ON FUNCTION public.invitar_inscripcion_pagada_sin_equipo_a_equipo(uuid, public.citext) TO service_role;

-- --------------------------------------------------------------------------
-- 2. Extender confirmación de invitación:
--    si el jugador ya tiene una inscripción activa SIN equipo, no crear otra;
--    asignar esa inscripción al equipo del slot y convertir el slot.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.confirmar_invitacion_equipo(p_slot_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_current_player_id uuid;
    v_current_email public.citext;
    v_slot public.tournament_team_roster_slots%ROWTYPE;
    v_existing_reg public.tournament_registrations%ROWTYPE;
    v_reg public.tournament_registrations;
BEGIN
    v_current_player_id := public._current_player_id_199();

    IF v_current_player_id IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión como jugador.';
    END IF;

    SELECT p.email
      INTO v_current_email
      FROM public.players p
     WHERE p.id = v_current_player_id
       AND p.activo = true;

    SELECT *
      INTO v_slot
      FROM public.tournament_team_roster_slots
     WHERE id = p_slot_id
     FOR UPDATE;

    IF v_slot.id IS NULL THEN
        RAISE EXCEPTION 'La invitación no existe.';
    END IF;

    IF v_slot.status <> 'pending_confirmation' THEN
        RAISE EXCEPTION 'La invitación ya no está pendiente de confirmación.';
    END IF;

    IF lower(v_slot.email::text) <> lower(v_current_email::text) THEN
        RAISE EXCEPTION 'Esta invitación pertenece a otro correo.';
    END IF;

    -- Serializar la confirmación contra cambios concurrentes de la inscripción.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            v_slot.tournament_id::text || ':confirm-team:' || v_current_player_id::text,
            225
        )
    );

    SELECT *
      INTO v_existing_reg
      FROM public.tournament_registrations tr
     WHERE tr.tournament_id = v_slot.tournament_id
       AND tr.player_id = v_current_player_id
       AND tr.activo = true
     LIMIT 1
     FOR UPDATE;

    -- Si ya existe inscripción, sólo es válida si todavía NO tiene equipo.
    IF v_existing_reg.id IS NOT NULL
       AND v_existing_reg.tournament_team_id IS NOT NULL
    THEN
        IF v_existing_reg.tournament_team_id = v_slot.tournament_team_id THEN
            RAISE EXCEPTION 'Ya perteneces a este equipo.';
        ELSE
            RAISE EXCEPTION 'Ya perteneces a otro equipo en este torneo.';
        END IF;
    END IF;

    IF EXISTS (
        SELECT 1
          FROM public.tournament_team_roster_slots rs
         WHERE rs.tournament_id = v_slot.tournament_id
           AND rs.id <> v_slot.id
           AND rs.status IN ('pending_confirmation','confirmed')
           AND (
               lower(rs.email::text) = lower(v_current_email::text)
               OR rs.player_id = v_current_player_id
           )
    ) THEN
        RAISE EXCEPTION
            'Este correo ya está reservado como integrante de otro equipo en este torneo.';
    END IF;

    -- CASO 225: inscripción ya pagada/formalizada pero aún sin equipo.
    IF v_existing_reg.id IS NOT NULL
       AND v_existing_reg.tournament_team_id IS NULL
    THEN
        -- El UPDATE conserva monto, fecha, medio y referencia de pago originales.
        -- Los triggers comunes siguen validando categoría, freeze y HCP TEAM.
        UPDATE public.tournament_registrations
           SET tournament_team_id = v_slot.tournament_team_id
         WHERE id = v_existing_reg.id
        RETURNING * INTO v_reg;

        UPDATE public.tournament_team_roster_slots
           SET player_id = v_current_player_id,
               status = 'converted',
               tournament_registration_id = v_reg.id,
               confirmed_at = now(),
               updated_at = now()
         WHERE id = v_slot.id
        RETURNING * INTO v_slot;

        RETURN jsonb_build_object(
            'slotId', v_slot.id,
            'status', 'converted',
            'teamId', v_slot.tournament_team_id,
            'playerId', v_current_player_id,
            'registrationId', v_reg.id,
            'existingRegistrationReused', true,
            'alreadyPaid', true,
            'additionalCharge', 0,
            'economicallyCovered', true
        );
    END IF;

    -- CASO EXISTENTE 199/200/223: todavía no hay inscripción formal.
    UPDATE public.tournament_team_roster_slots
       SET player_id = v_current_player_id,
           status = 'confirmed',
           confirmed_at = now(),
           updated_at = now()
     WHERE id = v_slot.id
     RETURNING * INTO v_slot;

    IF v_slot.payment_coverage_id IS NOT NULL THEN
        v_reg := public._convertir_slot_cubierto_a_inscripcion_200(v_slot.id);
    END IF;

    RETURN jsonb_build_object(
        'slotId', v_slot.id,
        'status', CASE WHEN v_reg.id IS NULL THEN 'confirmed' ELSE 'converted' END,
        'teamId', v_slot.tournament_team_id,
        'playerId', v_current_player_id,
        'registrationId', v_reg.id,
        'existingRegistrationReused', false,
        'economicallyCovered', v_slot.payment_coverage_id IS NOT NULL
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.confirmar_invitacion_equipo(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.confirmar_invitacion_equipo(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.confirmar_invitacion_equipo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirmar_invitacion_equipo(uuid) TO service_role;

COMMIT;
