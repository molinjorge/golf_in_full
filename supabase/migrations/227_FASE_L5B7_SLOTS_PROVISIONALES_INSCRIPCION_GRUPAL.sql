-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 227 — FASE L5B7
-- SLOTS PROVISIONALES PARA INSCRIPCIÓN GRUPAL SIN CAPITÁN
-- ============================================================
-- OBJETIVO
-- Crear el contrato backend mínimo para persistir, dentro de un
-- equipo grupal ya creado por la Migración 226, plazas provisionales
-- de terceros de los tipos funcionales:
--   - available_player: jugador existente sin inscripción activa.
--   - new_person: correo que todavía no corresponde a un player.
--
-- EXCLUSIONES INTENCIONALES
-- - NO procesa paid_unassigned: ese caso pertenece a Migración 225.
-- - NO crea tournament_registration.
-- - NO crea payment_attempts ni coberturas económicas.
-- - NO envía correo.
-- - NO requiere capitán.
-- - NO modifica contratos históricos 199/223/225/226.
-- ============================================================

CREATE OR REPLACE FUNCTION public.agregar_slot_provisional_inscripcion_grupal(
    p_team_id uuid,
    p_nombre_completo text,
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
    v_validation jsonb;
    v_player_id uuid;
    v_player public.players%ROWTYPE;
    v_nombre_final text;
    v_email_final public.citext;
    v_current_occupancy integer;
    v_slot_id uuid;
BEGIN
    -- --------------------------------------------------------
    -- 1. Sesión / actor
    -- --------------------------------------------------------
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión.'
            USING ERRCODE = '42501';
    END IF;

    v_actor_player_id := public._current_player_id_199();

    IF v_actor_player_id IS NULL THEN
        RAISE EXCEPTION 'No se encontró un perfil de jugador activo para esta sesión.'
            USING ERRCODE = '42501';
    END IF;

    IF NULLIF(btrim(p_nombre_completo), '') IS NULL THEN
        RAISE EXCEPTION 'Debes indicar el nombre del integrante.'
            USING ERRCODE = '22023';
    END IF;

    IF NULLIF(btrim(p_email::text), '') IS NULL THEN
        RAISE EXCEPTION 'Debes indicar el correo del integrante.'
            USING ERRCODE = '22023';
    END IF;

    -- --------------------------------------------------------
    -- 2. Equipo / torneo
    -- --------------------------------------------------------
    SELECT *
      INTO v_team
      FROM public.tournament_teams
     WHERE id = p_team_id
       AND activo = true;

    IF v_team.id IS NULL THEN
        RAISE EXCEPTION 'El equipo indicado no existe o está inactivo.'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
      INTO v_tournament
      FROM public.tournaments
     WHERE id = v_team.tournament_id
       AND activo = true;

    IF v_tournament.id IS NULL THEN
        RAISE EXCEPTION 'El torneo no existe o está inactivo.'
            USING ERRCODE = '22023';
    END IF;

    IF v_tournament.estatus <> 'inscripciones_abiertas'::public.estatus_torneo THEN
        RAISE EXCEPTION 'Las inscripciones del torneo no están abiertas.'
            USING ERRCODE = '55000';
    END IF;

    IF v_tournament.jugadores_por_equipo IS NULL
       OR v_tournament.jugadores_por_equipo <= 0
    THEN
        RAISE EXCEPTION 'El torneo no tiene configurado correctamente el número de jugadores por equipo.'
            USING ERRCODE = '23514';
    END IF;

    -- El iniciador de la inscripción grupal quedó como miembro confirmado
    -- en la Migración 226. Reutilizamos la autorización amplia de 223,
    -- que NO exige captain_player_id.
    IF NOT public._puede_pagar_equipo_grupal_223(
        p_team_id,
        v_actor_player_id
    ) THEN
        RAISE EXCEPTION 'No tienes permiso para incorporar jugadores a este equipo.'
            USING ERRCODE = '42501';
    END IF;

    -- --------------------------------------------------------
    -- 3. Serialización
    -- --------------------------------------------------------
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            v_team.tournament_id::text || ':group-slot-email:' ||
            lower(btrim(p_email::text)),
            227
        )
    );

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            p_team_id::text || ':group-slot-team',
            227
        )
    );

    -- --------------------------------------------------------
    -- 4. Revalidación de disponibilidad
    -- --------------------------------------------------------
    v_validation := public._validar_disponibilidad_integrante_199(
        v_team.tournament_id,
        p_team_id,
        p_email
    );

    IF NOT COALESCE((v_validation->>'available')::boolean, false) THEN
        RAISE EXCEPTION '%', v_validation->>'message'
            USING ERRCODE = '23505',
                  DETAIL = COALESCE(
                      v_validation->>'code',
                      'GROUP_SLOT_NOT_AVAILABLE'
                  );
    END IF;

    v_player_id := NULLIF(v_validation->>'playerId', '')::uuid;

    -- paid_unassigned NO debe entrar por este contrato. La validación 199
    -- ya bloquea cualquier inscripción activa; se mantiene como defensa
    -- explícita adicional para preservar el contrato de Migración 225.
    IF v_player_id IS NOT NULL
       AND EXISTS (
            SELECT 1
              FROM public.tournament_registrations tr
             WHERE tr.tournament_id = v_team.tournament_id
               AND tr.player_id = v_player_id
               AND tr.activo = true
       )
    THEN
        RAISE EXCEPTION
            'Este jugador ya tiene una inscripción activa. Usa el flujo para incorporar una inscripción pagada sin equipo.'
            USING ERRCODE = '23505',
                  DETAIL = 'GROUP_SLOT_PAID_UNASSIGNED_REQUIRES_225';
    END IF;

    -- --------------------------------------------------------
    -- 5. Cupo real del equipo
    -- --------------------------------------------------------
    v_current_occupancy := public.ocupacion_actual_equipo(p_team_id);

    IF v_current_occupancy >= v_tournament.jugadores_por_equipo THEN
        RAISE EXCEPTION
            'El equipo ya alcanzó su máximo de % integrantes.',
            v_tournament.jugadores_por_equipo
            USING ERRCODE = '23514';
    END IF;

    -- --------------------------------------------------------
    -- 6. Identidad final
    -- --------------------------------------------------------
    IF v_player_id IS NOT NULL THEN
        SELECT *
          INTO v_player
          FROM public.players
         WHERE id = v_player_id
           AND activo = true;

        IF v_player.id IS NULL THEN
            RAISE EXCEPTION 'El jugador localizado dejó de estar activo.'
                USING ERRCODE = '55000';
        END IF;

        -- Jugador existente: nunca sobrescribir su identidad canónica con
        -- el texto capturado por quien arma el equipo.
        v_nombre_final := btrim(concat_ws(' ', v_player.nombres, v_player.apellidos));
        v_email_final := v_player.email;
    ELSE
        -- Persona nueva: aún no existe player; conservar identidad provisional.
        v_nombre_final := btrim(p_nombre_completo);
        v_email_final := btrim(p_email::text)::public.citext;
    END IF;

    -- --------------------------------------------------------
    -- 7. Crear UNA plaza provisional
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
        v_team.tournament_id,
        p_team_id,
        'member',
        v_nombre_final,
        v_email_final,
        v_player_id,
        'pending_confirmation',
        NULL,
        v_actor_player_id,
        NULL,
        NULL,
        NULL,
        NULL
    )
    RETURNING id INTO v_slot_id;

    RETURN jsonb_build_object(
        'slotId', v_slot_id,
        'teamId', p_team_id,
        'tournamentId', v_team.tournament_id,
        'status', 'pending_confirmation',
        'playerExists', v_player_id IS NOT NULL,
        'playerId', v_player_id,
        'playerName', v_nombre_final,
        'email', v_email_final,
        'requiresConfirmation', true,
        'economicallyCovered', false
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.agregar_slot_provisional_inscripcion_grupal(
    uuid,
    text,
    public.citext
) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.agregar_slot_provisional_inscripcion_grupal(
    uuid,
    text,
    public.citext
) FROM anon;

GRANT EXECUTE ON FUNCTION public.agregar_slot_provisional_inscripcion_grupal(
    uuid,
    text,
    public.citext
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.agregar_slot_provisional_inscripcion_grupal(
    uuid,
    text,
    public.citext
) TO service_role;
