-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 199 FASE 1B
-- A-GO-GO — Roster provisional e invitaciones por capitán
-- ============================================================
-- Objetivo:
--   Permitir que un jugador autenticado cree un equipo como capitán
--   y declare integrantes mediante nombre + correo sin crear perfiles
--   ficticios en players.
--
-- Reglas:
--   - El correo identifica de forma única al invitado dentro del torneo.
--   - Un mismo player_id no puede ocupar dos equipos del mismo torneo.
--   - Antes de reservar una plaza se revisan inscripciones,
--     pre-reservas, reservas telefónicas y otros rosters.
--   - Si el correo ya existe en players, se vincula el player_id,
--     pero la participación NO queda confirmada hasta que el jugador
--     confirme personalmente.
--   - Si el correo aún no existe en players, la plaza queda pendiente.
--   - El roster provisional reserva cupo de equipo.
--   - No se implementa todavía el pago de equipo completo.
--     Eso corresponde a Fase 1C.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1. Capitán explícito del equipo
-- ------------------------------------------------------------
ALTER TABLE public.tournament_teams
    ADD COLUMN IF NOT EXISTS captain_player_id uuid NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'tournament_teams_captain_player_id_fkey'
          AND conrelid = 'public.tournament_teams'::regclass
    ) THEN
        ALTER TABLE public.tournament_teams
            ADD CONSTRAINT tournament_teams_captain_player_id_fkey
            FOREIGN KEY (captain_player_id)
            REFERENCES public.players(id)
            ON DELETE RESTRICT;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_tournament_teams_captain_player
    ON public.tournament_teams(captain_player_id)
    WHERE captain_player_id IS NOT NULL;

-- ------------------------------------------------------------
-- 2. Roster provisional
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tournament_team_roster_slots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    tournament_team_id uuid NOT NULL
        REFERENCES public.tournament_teams(id) ON DELETE RESTRICT,

    role text NOT NULL DEFAULT 'member'
        CHECK (role IN ('captain', 'member')),

    nombre_completo text NOT NULL,
    email citext NOT NULL,

    -- Se llena inmediatamente si el correo ya pertenece a un player.
    -- Si no, se completa cuando ese correo cree/vincule su perfil.
    player_id uuid NULL
        REFERENCES public.players(id) ON DELETE RESTRICT,

    -- pending_confirmation:
    --   invitado declarado por capitán, aún no aceptado.
    -- confirmed:
    --   jugador aceptó personalmente.
    -- rejected/cancelled:
    --   plaza liberada.
    -- converted:
    --   ya existe tournament_registration definitiva vinculada.
    status text NOT NULL DEFAULT 'pending_confirmation'
        CHECK (
            status IN (
                'pending_confirmation',
                'confirmed',
                'rejected',
                'cancelled',
                'converted'
            )
        ),

    tournament_registration_id uuid NULL
        REFERENCES public.tournament_registrations(id) ON DELETE RESTRICT,

    invited_by_player_id uuid NOT NULL
        REFERENCES public.players(id) ON DELETE RESTRICT,

    confirmed_at timestamptz NULL,
    rejected_at timestamptz NULL,
    cancelled_at timestamptz NULL,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_team_roster_slots_nombre_no_vacio
        CHECK (btrim(nombre_completo) <> ''),
    CONSTRAINT tournament_team_roster_slots_email_no_vacio
        CHECK (btrim(email::text) <> '')
);

CREATE INDEX IF NOT EXISTS idx_team_roster_slots_team
    ON public.tournament_team_roster_slots(tournament_team_id);

CREATE INDEX IF NOT EXISTS idx_team_roster_slots_tournament
    ON public.tournament_team_roster_slots(tournament_id);

CREATE INDEX IF NOT EXISTS idx_team_roster_slots_player
    ON public.tournament_team_roster_slots(player_id)
    WHERE player_id IS NOT NULL;

-- Un correo sólo puede ocupar un roster activo dentro del torneo.
CREATE UNIQUE INDEX IF NOT EXISTS uq_team_roster_active_email_tournament
    ON public.tournament_team_roster_slots(tournament_id, email)
    WHERE status IN ('pending_confirmation', 'confirmed');

-- Un player ya vinculado sólo puede ocupar un roster activo dentro del torneo.
CREATE UNIQUE INDEX IF NOT EXISTS uq_team_roster_active_player_tournament
    ON public.tournament_team_roster_slots(tournament_id, player_id)
    WHERE player_id IS NOT NULL
      AND status IN ('pending_confirmation', 'confirmed');

-- Sólo un capitán activo por equipo.
CREATE UNIQUE INDEX IF NOT EXISTS uq_team_roster_active_captain
    ON public.tournament_team_roster_slots(tournament_team_id)
    WHERE role = 'captain'
      AND status IN ('pending_confirmation', 'confirmed', 'converted');

DROP TRIGGER IF EXISTS trg_team_roster_slots_updated_at
    ON public.tournament_team_roster_slots;

CREATE TRIGGER trg_team_roster_slots_updated_at
BEFORE UPDATE ON public.tournament_team_roster_slots
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.tournament_team_roster_slots ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_team_roster_slots
FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.tournament_team_roster_slots
TO service_role;

-- ------------------------------------------------------------
-- 3. Helper: jugador actual
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._current_player_id_199()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
    SELECT p.id
    FROM public.players p
    WHERE p.auth_user_id = auth.uid()
      AND p.activo = true
    LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public._current_player_id_199()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public._current_player_id_199()
TO authenticated, service_role;

-- ------------------------------------------------------------
-- 4. Helper: permiso para administrar roster
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._puede_administrar_roster_equipo_199(
    p_team_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
    v_tournament_id uuid;
    v_captain_player_id uuid;
    v_current_player_id uuid;
    v_club_id uuid;
BEGIN
    SELECT tt.tournament_id, tt.captain_player_id, t.club_id
      INTO v_tournament_id, v_captain_player_id, v_club_id
      FROM public.tournament_teams tt
      JOIN public.tournaments t ON t.id = tt.tournament_id
     WHERE tt.id = p_team_id
       AND tt.activo = true;

    IF v_tournament_id IS NULL THEN
        RETURN false;
    END IF;

    IF public.is_superadmin(auth.uid())
       OR public.is_tournament_organizer(auth.uid(), v_tournament_id)
       OR public.is_club_admin(auth.uid(), v_club_id)
    THEN
        RETURN true;
    END IF;

    v_current_player_id := public._current_player_id_199();

    RETURN v_current_player_id IS NOT NULL
       AND v_current_player_id = v_captain_player_id;
END;
$$;

REVOKE ALL ON FUNCTION public._puede_administrar_roster_equipo_199(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public._puede_administrar_roster_equipo_199(uuid)
TO service_role;

-- ------------------------------------------------------------
-- 5. Helper interno: disponibilidad de correo/player en torneo
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._validar_disponibilidad_integrante_199(
    p_tournament_id uuid,
    p_team_id uuid,
    p_email citext
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
    v_email citext := NULLIF(btrim(p_email::text), '')::citext;
    v_player public.players%ROWTYPE;
    v_conflict_team_id uuid;
    v_source text;
    v_same_team boolean := false;
BEGIN
    IF v_email IS NULL THEN
        RETURN jsonb_build_object(
            'available', false,
            'code', 'EMAIL_REQUIRED',
            'message', 'Debes indicar el correo del integrante.'
        );
    END IF;

    SELECT *
      INTO v_player
      FROM public.players p
     WHERE p.email = v_email
     LIMIT 1;

    -- Inscripción formal: siempre bloquea una nueva invitación.
    IF v_player.id IS NOT NULL THEN
        SELECT tr.tournament_team_id
          INTO v_conflict_team_id
          FROM public.tournament_registrations tr
         WHERE tr.tournament_id = p_tournament_id
           AND tr.player_id = v_player.id
           AND tr.activo = true
         LIMIT 1;

        IF FOUND THEN
            v_same_team := v_conflict_team_id IS NOT NULL
                       AND v_conflict_team_id = p_team_id;

            RETURN jsonb_build_object(
                'available', false,
                'code',
                    CASE
                        WHEN v_same_team THEN 'ALREADY_REGISTERED_SAME_TEAM'
                        ELSE 'ALREADY_REGISTERED_TOURNAMENT'
                    END,
                'message',
                    CASE
                        WHEN v_same_team
                            THEN 'Este jugador ya está inscrito en este equipo.'
                        ELSE 'Este jugador ya está inscrito en este torneo y no puede agregarse a otro equipo.'
                    END,
                'playerId', v_player.id,
                'playerExists', true,
                'conflictTeamId', v_conflict_team_id
            );
        END IF;

        -- Pre-reserva activa.
        SELECT pr.tournament_team_id
          INTO v_conflict_team_id
          FROM public.tournament_pre_reservations pr
         WHERE pr.tournament_id = p_tournament_id
           AND pr.player_id = v_player.id
           AND pr.activo = true
           AND pr.tournament_registration_id IS NULL
         LIMIT 1;

        IF FOUND THEN
            v_same_team := v_conflict_team_id IS NOT NULL
                       AND v_conflict_team_id = p_team_id;

            RETURN jsonb_build_object(
                'available', false,
                'code',
                    CASE
                        WHEN v_same_team THEN 'ACTIVE_PRERESERVATION_SAME_TEAM'
                        ELSE 'ACTIVE_PRERESERVATION_TOURNAMENT'
                    END,
                'message',
                    CASE
                        WHEN v_same_team
                            THEN 'Este jugador ya tiene una pre-reserva activa en este equipo.'
                        ELSE 'Este jugador ya tiene una pre-reserva activa en este torneo.'
                    END,
                'playerId', v_player.id,
                'playerExists', true,
                'conflictTeamId', v_conflict_team_id
            );
        END IF;
    END IF;

    -- Reserva telefónica: se compara por correo porque puede no existir player_id.
    SELECT ph.tournament_team_id
      INTO v_conflict_team_id
      FROM public.phone_reservations ph
     WHERE ph.tournament_id = p_tournament_id
       AND ph.correo = v_email
       AND ph.activo = true
     LIMIT 1;

    IF FOUND THEN
        v_same_team := v_conflict_team_id IS NOT NULL
                   AND v_conflict_team_id = p_team_id;

        RETURN jsonb_build_object(
            'available', false,
            'code',
                CASE
                    WHEN v_same_team THEN 'ACTIVE_PHONE_RESERVATION_SAME_TEAM'
                    ELSE 'ACTIVE_PHONE_RESERVATION_TOURNAMENT'
                END,
            'message',
                CASE
                    WHEN v_same_team
                        THEN 'Este correo ya tiene una reserva activa en este equipo.'
                    ELSE 'Este correo ya tiene una reserva activa en este torneo.'
                END,
            'playerId', v_player.id,
            'playerExists', v_player.id IS NOT NULL,
            'conflictTeamId', v_conflict_team_id
        );
    END IF;

    -- Otro slot activo del roster.
    SELECT rs.tournament_team_id
      INTO v_conflict_team_id
      FROM public.tournament_team_roster_slots rs
     WHERE rs.tournament_id = p_tournament_id
       AND rs.email = v_email
       AND rs.status IN ('pending_confirmation', 'confirmed')
     LIMIT 1;

    IF FOUND THEN
        v_same_team := v_conflict_team_id = p_team_id;

        RETURN jsonb_build_object(
            'available', false,
            'code',
                CASE
                    WHEN v_same_team THEN 'ALREADY_IN_ROSTER_SAME_TEAM'
                    ELSE 'ALREADY_IN_OTHER_TEAM_ROSTER'
                END,
            'message',
                CASE
                    WHEN v_same_team
                        THEN 'Este correo ya forma parte del roster de este equipo.'
                    ELSE 'Este correo ya está reservado como integrante de otro equipo en este torneo.'
                END,
            'playerId', v_player.id,
            'playerExists', v_player.id IS NOT NULL,
            'conflictTeamId', v_conflict_team_id
        );
    END IF;

    RETURN jsonb_build_object(
        'available', true,
        'code', 'AVAILABLE',
        'message',
            CASE
                WHEN v_player.id IS NULL
                    THEN 'Correo disponible. El jugador deberá crear o vincular su perfil y confirmar la invitación.'
                ELSE 'Jugador localizado. La invitación requerirá su confirmación personal.'
            END,
        'playerExists', v_player.id IS NOT NULL,
        'playerId', v_player.id,
        'playerName',
            CASE
                WHEN v_player.id IS NULL THEN NULL
                ELSE btrim(concat_ws(' ', v_player.nombres, v_player.apellidos))
            END
    );
END;
$$;

REVOKE ALL ON FUNCTION public._validar_disponibilidad_integrante_199(
    uuid, uuid, citext
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public._validar_disponibilidad_integrante_199(
    uuid, uuid, citext
)
TO service_role;

-- ------------------------------------------------------------
-- 6. RPC pública: validación previa por correo
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validar_integrante_equipo_por_correo(
    p_team_id uuid,
    p_email citext
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
    v_tournament_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT public._puede_administrar_roster_equipo_199(p_team_id) THEN
        RAISE EXCEPTION 'No tienes permiso para administrar este equipo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tournament_id
      INTO v_tournament_id
      FROM public.tournament_teams
     WHERE id = p_team_id
       AND activo = true;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'El equipo indicado no existe o está inactivo.'
            USING ERRCODE = '22023';
    END IF;

    RETURN public._validar_disponibilidad_integrante_199(
        v_tournament_id,
        p_team_id,
        p_email
    );
END;
$$;

REVOKE ALL ON FUNCTION public.validar_integrante_equipo_por_correo(uuid, citext)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.validar_integrante_equipo_por_correo(uuid, citext)
TO authenticated, service_role;

-- ------------------------------------------------------------
-- 7. RPC: crear equipo como capitán
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crear_equipo_como_capitan(
    p_tournament_id uuid,
    p_nombre_equipo text,
    p_tournament_category_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
    v_player_id uuid;
    v_player public.players%ROWTYPE;
    v_team_id uuid;
    v_tipo_participacion public.formato_juego_torneo;
    v_status public.estatus_torneo;
    v_existing_team uuid;
BEGIN
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
     WHERE id = v_player_id;

    SELECT tf.tipo_participacion, t.estatus
      INTO v_tipo_participacion, v_status
      FROM public.tournaments t
      JOIN public.tournament_formats tf
        ON tf.id = t.tournament_format_id
     WHERE t.id = p_tournament_id
       AND t.activo = true;

    IF v_tipo_participacion IS NULL THEN
        RAISE EXCEPTION 'El torneo indicado no existe o está inactivo.'
            USING ERRCODE = '22023';
    END IF;

    IF v_tipo_participacion <> 'equipo'::public.formato_juego_torneo THEN
        RAISE EXCEPTION 'Esta función sólo aplica a torneos por equipos.'
            USING ERRCODE = '22023';
    END IF;

    IF v_status <> 'inscripciones_abiertas'::public.estatus_torneo THEN
        RAISE EXCEPTION 'Las inscripciones del torneo no están abiertas.'
            USING ERRCODE = '55000';
    END IF;

    IF NULLIF(btrim(p_nombre_equipo), '') IS NULL THEN
        RAISE EXCEPTION 'Debes indicar el nombre del equipo.'
            USING ERRCODE = '22023';
    END IF;

    -- Serializa operaciones del mismo jugador dentro del mismo torneo.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            p_tournament_id::text || ':player:' || v_player_id::text,
            199
        )
    );

    -- Una pre-reserva activa ya ocupa una plaza y no debe duplicarse
    -- con el roster provisional. Su reasignación se conserva como
    -- operación administrativa/flujo existente.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_pre_reservations pr
        WHERE pr.tournament_id = p_tournament_id
          AND pr.player_id = v_player_id
          AND pr.activo = true
          AND pr.tournament_registration_id IS NULL
    ) THEN
        RAISE EXCEPTION
            'Ya tienes una pre-reserva activa en este torneo. Debe resolverse antes de crear un equipo como capitán.'
            USING
                ERRCODE = '23505',
                DETAIL = 'CAPTAIN_ACTIVE_PRERESERVATION';
    END IF;

    -- Una reserva telefónica previa por el mismo correo también ocupa plaza.
    IF EXISTS (
        SELECT 1
        FROM public.phone_reservations ph
        WHERE ph.tournament_id = p_tournament_id
          AND ph.correo = v_player.email
          AND ph.activo = true
    ) THEN
        RAISE EXCEPTION
            'Ya existe una reserva activa para tu correo en este torneo. Debe resolverse antes de crear un equipo como capitán.'
            USING
                ERRCODE = '23505',
                DETAIL = 'CAPTAIN_ACTIVE_PHONE_RESERVATION';
    END IF;

    -- Si ya está formalmente inscrito en un equipo, no puede crear otro.
    SELECT tr.tournament_team_id
      INTO v_existing_team
      FROM public.tournament_registrations tr
     WHERE tr.tournament_id = p_tournament_id
       AND tr.player_id = v_player_id
       AND tr.activo = true
     LIMIT 1;

    IF FOUND AND v_existing_team IS NOT NULL THEN
        RAISE EXCEPTION 'Ya perteneces a un equipo en este torneo.'
            USING ERRCODE = '23505';
    END IF;

    -- Si ya está en otro roster activo, tampoco puede crear otro equipo.
    SELECT rs.tournament_team_id
      INTO v_existing_team
      FROM public.tournament_team_roster_slots rs
     WHERE rs.tournament_id = p_tournament_id
       AND rs.player_id = v_player_id
       AND rs.status IN ('pending_confirmation', 'confirmed')
     LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'Ya estás reservado como integrante de otro equipo en este torneo.'
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO public.tournament_teams (
        tournament_id,
        tournament_category_id,
        nombre_equipo,
        captain_player_id
    )
    VALUES (
        p_tournament_id,
        p_tournament_category_id,
        btrim(p_nombre_equipo),
        v_player_id
    )
    RETURNING id INTO v_team_id;

    -- Si el capitán ya tenía una inscripción pagada pero aún sin equipo,
    -- la asigna a su equipo y el slot queda convertido.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_registrations tr
        WHERE tr.tournament_id = p_tournament_id
          AND tr.player_id = v_player_id
          AND tr.activo = true
          AND tr.tournament_team_id IS NULL
    ) THEN
        UPDATE public.tournament_registrations
           SET tournament_team_id = v_team_id
         WHERE tournament_id = p_tournament_id
           AND player_id = v_player_id
           AND activo = true
           AND tournament_team_id IS NULL;

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
            confirmed_at
        )
        SELECT
            p_tournament_id,
            v_team_id,
            'captain',
            btrim(concat_ws(' ', v_player.nombres, v_player.apellidos)),
            v_player.email,
            v_player_id,
            'converted',
            tr.id,
            v_player_id,
            now()
        FROM public.tournament_registrations tr
        WHERE tr.tournament_id = p_tournament_id
          AND tr.player_id = v_player_id
          AND tr.activo = true
        LIMIT 1;
    ELSE
        INSERT INTO public.tournament_team_roster_slots (
            tournament_id,
            tournament_team_id,
            role,
            nombre_completo,
            email,
            player_id,
            status,
            invited_by_player_id,
            confirmed_at
        )
        VALUES (
            p_tournament_id,
            v_team_id,
            'captain',
            btrim(concat_ws(' ', v_player.nombres, v_player.apellidos)),
            v_player.email,
            v_player_id,
            'confirmed',
            v_player_id,
            now()
        );
    END IF;

    RETURN v_team_id;
END;
$$;

REVOKE ALL ON FUNCTION public.crear_equipo_como_capitan(uuid, text, uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.crear_equipo_como_capitan(uuid, text, uuid)
TO authenticated, service_role;

-- ------------------------------------------------------------
-- 8. RPC: agregar invitado al roster
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.agregar_integrante_equipo_por_capitan(
    p_team_id uuid,
    p_nombre_completo text,
    p_email citext
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
    v_tournament_id uuid;
    v_max_players integer;
    v_current_occupancy integer;
    v_validation jsonb;
    v_player_id uuid;
    v_actor_player_id uuid;
    v_slot_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión.'
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

    IF NOT public._puede_administrar_roster_equipo_199(p_team_id) THEN
        RAISE EXCEPTION 'No tienes permiso para administrar este equipo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tt.tournament_id, t.jugadores_por_equipo
      INTO v_tournament_id, v_max_players
      FROM public.tournament_teams tt
      JOIN public.tournaments t ON t.id = tt.tournament_id
     WHERE tt.id = p_team_id
       AND tt.activo = true;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'El equipo indicado no existe o está inactivo.'
            USING ERRCODE = '22023';
    END IF;

    -- Serializa dos intentos simultáneos para el mismo correo/torneo.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            v_tournament_id::text || ':email:' || lower(btrim(p_email::text)),
            199
        )
    );

    -- Validación inmediatamente antes de reservar la plaza.
    v_validation := public._validar_disponibilidad_integrante_199(
        v_tournament_id,
        p_team_id,
        p_email
    );

    IF NOT COALESCE((v_validation->>'available')::boolean, false) THEN
        RAISE EXCEPTION '%', v_validation->>'message'
            USING
                ERRCODE = '23505',
                DETAIL = COALESCE(v_validation->>'code', 'MEMBER_NOT_AVAILABLE');
    END IF;

    v_current_occupancy := public.ocupacion_actual_equipo(p_team_id);

    IF v_max_players IS NOT NULL
       AND v_current_occupancy >= v_max_players
    THEN
        RAISE EXCEPTION
            'El equipo ya alcanzó su máximo de % integrantes.',
            v_max_players
            USING ERRCODE = '23514';
    END IF;

    v_player_id := NULLIF(v_validation->>'playerId', '')::uuid;
    v_actor_player_id := public._current_player_id_199();

    -- Para administración asistida, si no hay player actual se usa
    -- el capitán como referencia de quién originó la invitación.
    IF v_actor_player_id IS NULL THEN
        SELECT captain_player_id
          INTO v_actor_player_id
          FROM public.tournament_teams
         WHERE id = p_team_id;
    END IF;

    IF v_actor_player_id IS NULL THEN
        RAISE EXCEPTION
            'El equipo debe tener un capitán para registrar integrantes provisionales.'
            USING ERRCODE = '55000';
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
        v_tournament_id,
        p_team_id,
        'member',
        btrim(p_nombre_completo),
        btrim(p_email::text)::citext,
        v_player_id,
        'pending_confirmation',
        v_actor_player_id
    )
    RETURNING id INTO v_slot_id;

    RETURN jsonb_build_object(
        'slotId', v_slot_id,
        'teamId', p_team_id,
        'tournamentId', v_tournament_id,
        'status', 'pending_confirmation',
        'playerExists', v_player_id IS NOT NULL,
        'playerId', v_player_id,
        'requiresConfirmation', true
    );
END;
$$;

REVOKE ALL ON FUNCTION public.agregar_integrante_equipo_por_capitan(
    uuid, text, citext
)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.agregar_integrante_equipo_por_capitan(
    uuid, text, citext
)
TO authenticated, service_role;

-- ------------------------------------------------------------
-- 9. RPC: invitado confirma personalmente
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.confirmar_invitacion_equipo(
    p_slot_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
    v_slot public.tournament_team_roster_slots%ROWTYPE;
    v_player public.players%ROWTYPE;
    v_conflict_team_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_player
      FROM public.players
     WHERE auth_user_id = auth.uid()
       AND activo = true
     LIMIT 1;

    IF v_player.id IS NULL THEN
        RAISE EXCEPTION 'No se encontró un perfil de jugador activo para esta sesión.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_slot
      FROM public.tournament_team_roster_slots
     WHERE id = p_slot_id
     FOR UPDATE;

    IF v_slot.id IS NULL THEN
        RAISE EXCEPTION 'La invitación indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF v_slot.status <> 'pending_confirmation' THEN
        RAISE EXCEPTION 'Esta invitación ya no está pendiente de confirmación.'
            USING ERRCODE = '55000';
    END IF;

    IF v_slot.email <> v_player.email THEN
        RAISE EXCEPTION 'Esta invitación pertenece a otro correo.'
            USING ERRCODE = '42501';
    END IF;

    -- Revalidación final: entre la invitación y la aceptación pudo
    -- haberse creado otra inscripción.
    SELECT tr.tournament_team_id
      INTO v_conflict_team_id
      FROM public.tournament_registrations tr
     WHERE tr.tournament_id = v_slot.tournament_id
       AND tr.player_id = v_player.id
       AND tr.activo = true
     LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'Ya tienes una inscripción activa en este torneo; la invitación no puede confirmarse.'
            USING
                ERRCODE = '23505',
                DETAIL = 'ALREADY_REGISTERED_TOURNAMENT';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_team_roster_slots rs
        WHERE rs.tournament_id = v_slot.tournament_id
          AND rs.player_id = v_player.id
          AND rs.id <> v_slot.id
          AND rs.status IN ('pending_confirmation', 'confirmed')
    ) THEN
        RAISE EXCEPTION
            'Ya perteneces o estás reservado en otro equipo de este torneo.'
            USING
                ERRCODE = '23505',
                DETAIL = 'PLAYER_ALREADY_IN_OTHER_TEAM';
    END IF;

    UPDATE public.tournament_team_roster_slots
       SET player_id = v_player.id,
           nombre_completo = btrim(
               concat_ws(' ', v_player.nombres, v_player.apellidos)
           ),
           status = 'confirmed',
           confirmed_at = now()
     WHERE id = p_slot_id;

    RETURN jsonb_build_object(
        'slotId', p_slot_id,
        'teamId', v_slot.tournament_team_id,
        'tournamentId', v_slot.tournament_id,
        'status', 'confirmed',
        'playerId', v_player.id
    );
END;
$$;

REVOKE ALL ON FUNCTION public.confirmar_invitacion_equipo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.confirmar_invitacion_equipo(uuid)
TO authenticated, service_role;

-- ------------------------------------------------------------
-- 10. RPC: invitado rechaza
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rechazar_invitacion_equipo(
    p_slot_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
    v_slot public.tournament_team_roster_slots%ROWTYPE;
    v_player public.players%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_player
      FROM public.players
     WHERE auth_user_id = auth.uid()
       AND activo = true
     LIMIT 1;

    SELECT *
      INTO v_slot
      FROM public.tournament_team_roster_slots
     WHERE id = p_slot_id
     FOR UPDATE;

    IF v_slot.id IS NULL THEN
        RAISE EXCEPTION 'La invitación indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF v_player.id IS NULL OR v_player.email <> v_slot.email THEN
        RAISE EXCEPTION 'Esta invitación pertenece a otro correo.'
            USING ERRCODE = '42501';
    END IF;

    IF v_slot.status <> 'pending_confirmation' THEN
        RAISE EXCEPTION 'Esta invitación ya no está pendiente.'
            USING ERRCODE = '55000';
    END IF;

    UPDATE public.tournament_team_roster_slots
       SET player_id = v_player.id,
           status = 'rejected',
           rejected_at = now()
     WHERE id = p_slot_id;
END;
$$;

REVOKE ALL ON FUNCTION public.rechazar_invitacion_equipo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.rechazar_invitacion_equipo(uuid)
TO authenticated, service_role;

-- ------------------------------------------------------------
-- 11. RPC: capitán cancela plaza pendiente
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancelar_integrante_provisional_equipo(
    p_slot_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
    v_slot public.tournament_team_roster_slots%ROWTYPE;
BEGIN
    SELECT *
      INTO v_slot
      FROM public.tournament_team_roster_slots
     WHERE id = p_slot_id
     FOR UPDATE;

    IF v_slot.id IS NULL THEN
        RAISE EXCEPTION 'El integrante provisional indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public._puede_administrar_roster_equipo_199(
        v_slot.tournament_team_id
    ) THEN
        RAISE EXCEPTION 'No tienes permiso para administrar este equipo.'
            USING ERRCODE = '42501';
    END IF;

    IF v_slot.role = 'captain' THEN
        RAISE EXCEPTION 'El capitán no puede cancelarse mediante esta operación.'
            USING ERRCODE = '55000';
    END IF;

    IF v_slot.status NOT IN ('pending_confirmation', 'confirmed') THEN
        RAISE EXCEPTION 'Esta plaza ya no está activa.'
            USING ERRCODE = '55000';
    END IF;

    UPDATE public.tournament_team_roster_slots
       SET status = 'cancelled',
           cancelled_at = now()
     WHERE id = p_slot_id;
END;
$$;

REVOKE ALL ON FUNCTION public.cancelar_integrante_provisional_equipo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.cancelar_integrante_provisional_equipo(uuid)
TO authenticated, service_role;

-- ------------------------------------------------------------
-- 12. RPC lectura de roster
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_roster_equipo(
    p_team_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
    v_result jsonb;
BEGIN
    IF NOT public._puede_administrar_roster_equipo_199(p_team_id) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar este roster.'
            USING ERRCODE = '42501';
    END IF;

    SELECT jsonb_build_object(
        'teamId', tt.id,
        'tournamentId', tt.tournament_id,
        'teamName', tt.nombre_equipo,
        'captainPlayerId', tt.captain_player_id,
        'maxPlayers', t.jugadores_por_equipo,
        'occupied', public.ocupacion_actual_equipo(tt.id),
        'slots',
            COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'slotId', rs.id,
                        'role', rs.role,
                        'name', rs.nombre_completo,
                        'email', rs.email,
                        'playerId', rs.player_id,
                        'status', rs.status,
                        'registrationId', rs.tournament_registration_id,
                        'confirmedAt', rs.confirmed_at
                    )
                    ORDER BY
                        CASE WHEN rs.role = 'captain' THEN 0 ELSE 1 END,
                        rs.created_at,
                        rs.id
                ) FILTER (WHERE rs.id IS NOT NULL),
                '[]'::jsonb
            )
    )
      INTO v_result
      FROM public.tournament_teams tt
      JOIN public.tournaments t ON t.id = tt.tournament_id
      LEFT JOIN public.tournament_team_roster_slots rs
        ON rs.tournament_team_id = tt.id
       AND rs.status <> 'cancelled'
     WHERE tt.id = p_team_id
       AND tt.activo = true
     GROUP BY
        tt.id,
        tt.tournament_id,
        tt.nombre_equipo,
        tt.captain_player_id,
        t.jugadores_por_equipo;

    IF v_result IS NULL THEN
        RAISE EXCEPTION 'El equipo indicado no existe o está inactivo.'
            USING ERRCODE = '22023';
    END IF;

    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_roster_equipo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.obtener_roster_equipo(uuid)
TO authenticated, service_role;

-- ------------------------------------------------------------
-- 13. RPC lectura de invitaciones propias
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_mis_invitaciones_equipo(
    p_tournament_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
    v_player public.players%ROWTYPE;
    v_result jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_player
      FROM public.players
     WHERE auth_user_id = auth.uid()
       AND activo = true
     LIMIT 1;

    IF v_player.id IS NULL THEN
        RAISE EXCEPTION 'No se encontró un perfil de jugador activo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'slotId', rs.id,
                'tournamentId', rs.tournament_id,
                'tournamentName', t.nombre,
                'teamId', rs.tournament_team_id,
                'teamName', tt.nombre_equipo,
                'status', rs.status,
                'invitedAt', rs.created_at
            )
            ORDER BY rs.created_at DESC
        ),
        '[]'::jsonb
    )
      INTO v_result
      FROM public.tournament_team_roster_slots rs
      JOIN public.tournaments t
        ON t.id = rs.tournament_id
      JOIN public.tournament_teams tt
        ON tt.id = rs.tournament_team_id
     WHERE rs.email = v_player.email
       AND rs.role = 'member'
       AND rs.status = 'pending_confirmation'
       AND (p_tournament_id IS NULL OR rs.tournament_id = p_tournament_id);

    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_mis_invitaciones_equipo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.obtener_mis_invitaciones_equipo(uuid)
TO authenticated, service_role;

-- ------------------------------------------------------------
-- 14. Vinculación automática por correo al aparecer el player
--     IMPORTANTE: sólo vincula player_id; NO confirma invitación.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.vincular_roster_equipo_por_email_199()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
BEGIN
    UPDATE public.tournament_team_roster_slots rs
       SET player_id = NEW.id
     WHERE rs.email = NEW.email
       AND rs.player_id IS NULL
       AND rs.status = 'pending_confirmation';

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_vincular_roster_equipo_por_email_199
    ON public.players;

CREATE TRIGGER trg_vincular_roster_equipo_por_email_199
AFTER INSERT OR UPDATE OF email ON public.players
FOR EACH ROW
EXECUTE FUNCTION public.vincular_roster_equipo_por_email_199();

-- ------------------------------------------------------------
-- 15. Cupo de equipo: incluye plazas provisionales sin duplicar
--     inscripciones ya convertidas.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ocupacion_actual_equipo(
    p_team_id uuid
)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path TO public, pg_temp
AS $$
    SELECT
        (
            SELECT count(*)
            FROM public.phone_reservations
            WHERE tournament_team_id = p_team_id
              AND activo = true
        )
        +
        (
            SELECT count(*)
            FROM public.tournament_pre_reservations
            WHERE tournament_team_id = p_team_id
              AND activo = true
              AND tournament_registration_id IS NULL
        )
        +
        (
            SELECT count(*)
            FROM public.tournament_registrations
            WHERE tournament_team_id = p_team_id
              AND activo = true
        )
        +
        (
            SELECT count(*)
            FROM public.tournament_team_roster_slots
            WHERE tournament_team_id = p_team_id
              AND status IN ('pending_confirmation', 'confirmed')
              AND tournament_registration_id IS NULL
        );
$$;

-- ------------------------------------------------------------
-- 16. Seguridad de creación de equipos
--     Ya no se permite INSERT anónimo.
-- ------------------------------------------------------------
REVOKE INSERT ON TABLE public.tournament_teams FROM anon;

DROP POLICY IF EXISTS tournament_teams_insert
    ON public.tournament_teams;

CREATE POLICY tournament_teams_insert
ON public.tournament_teams
FOR INSERT
TO authenticated
WITH CHECK (
    auth.uid() IS NOT NULL
    AND (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(), tournament_id)
        OR EXISTS (
            SELECT 1
            FROM public.tournaments t
            WHERE t.id = tournament_teams.tournament_id
              AND public.is_club_admin(auth.uid(), t.club_id)
        )
        OR captain_player_id = public._current_player_id_199()
    )
);

-- ------------------------------------------------------------
-- 17. Comentarios
-- ------------------------------------------------------------
COMMENT ON COLUMN public.tournament_teams.captain_player_id IS
'Jugador capitán del equipo para el flujo de autogestión del roster. No sustituye created_by administrativo.';

COMMENT ON TABLE public.tournament_team_roster_slots IS
'Roster provisional de equipos: permite reservar plazas por nombre/correo antes de que exista o confirme el player. No es un catálogo alterno de jugadores.';

COMMENT ON COLUMN public.tournament_team_roster_slots.status IS
'pending_confirmation=declarado por capitán; confirmed=aceptado personalmente; rejected/cancelled=plaza liberada; converted=ya existe inscripción definitiva.';

COMMIT;
