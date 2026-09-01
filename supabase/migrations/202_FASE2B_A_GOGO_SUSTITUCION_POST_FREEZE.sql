-- ============================================================================
-- MIGRACIÓN 202 FASE 2B
-- A-Go-Go — sustitución controlada de integrante después del freeze
-- Proyecto: Tee Central / GOLF IN FULL
--
-- PRINCIPIOS
-- - Nunca cambiar player_id dentro de una inscripción histórica.
-- - El jugador saliente conserva su inscripción histórica y su evidencia de pago.
-- - El reemplazo confirma personalmente su participación.
-- - La nueva inscripción se crea con monto adicional 0.
-- - Si existe cobertura económica de equipo, se conserva en el reemplazo.
-- - No se tocan todavía salidas ya validadas: eso queda para Fase 4.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Solicitudes de sustitución
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_team_substitution_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,

    tournament_team_id uuid NOT NULL
        REFERENCES public.tournament_teams(id) ON DELETE RESTRICT,

    outgoing_registration_id uuid NOT NULL
        REFERENCES public.tournament_registrations(id) ON DELETE RESTRICT,

    outgoing_player_id uuid NOT NULL
        REFERENCES public.players(id) ON DELETE RESTRICT,

    incoming_name text NOT NULL,
    incoming_email public.citext NOT NULL,

    incoming_player_id uuid NULL
        REFERENCES public.players(id) ON DELETE RESTRICT,

    status text NOT NULL DEFAULT 'pending_confirmation'
        CHECK (status IN (
            'pending_confirmation',
            'confirmed',
            'cancelled',
            'rejected'
        )),

    reason text NOT NULL,

    payment_coverage_id uuid NULL
        REFERENCES public.tournament_team_payment_coverages(id)
        ON DELETE RESTRICT,

    incoming_registration_id uuid NULL
        REFERENCES public.tournament_registrations(id)
        ON DELETE RESTRICT,

    requested_by_admin_id uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,

    requested_at timestamptz NOT NULL DEFAULT now(),
    confirmed_at timestamptz NULL,
    rejected_at timestamptz NULL,
    cancelled_at timestamptz NULL,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_team_substitution_active_outgoing
    ON public.tournament_team_substitution_requests(outgoing_registration_id)
    WHERE status = 'pending_confirmation';

CREATE UNIQUE INDEX IF NOT EXISTS uq_team_substitution_active_email_tournament
    ON public.tournament_team_substitution_requests(
        tournament_id,
        incoming_email
    )
    WHERE status = 'pending_confirmation';

CREATE UNIQUE INDEX IF NOT EXISTS uq_team_substitution_active_player_tournament
    ON public.tournament_team_substitution_requests(
        tournament_id,
        incoming_player_id
    )
    WHERE incoming_player_id IS NOT NULL
      AND status = 'pending_confirmation';

CREATE INDEX IF NOT EXISTS idx_team_substitution_team
    ON public.tournament_team_substitution_requests(tournament_team_id);

DROP TRIGGER IF EXISTS set_updated_at_tournament_team_substitution_requests
    ON public.tournament_team_substitution_requests;

CREATE TRIGGER set_updated_at_tournament_team_substitution_requests
BEFORE UPDATE ON public.tournament_team_substitution_requests
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.tournament_team_substitution_requests ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_team_substitution_requests
FROM anon, authenticated;

GRANT ALL ON TABLE public.tournament_team_substitution_requests
TO service_role;

-- ----------------------------------------------------------------------------
-- 2. Trazabilidad explícita en inscripción nueva y bitácora 201
-- ----------------------------------------------------------------------------

ALTER TABLE public.tournament_registrations
    ADD COLUMN IF NOT EXISTS substitution_source_registration_id uuid NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'tournament_registrations_substitution_source_fkey'
          AND conrelid = 'public.tournament_registrations'::regclass
    ) THEN
        ALTER TABLE public.tournament_registrations
            ADD CONSTRAINT tournament_registrations_substitution_source_fkey
            FOREIGN KEY (substitution_source_registration_id)
            REFERENCES public.tournament_registrations(id)
            ON DELETE RESTRICT;
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_tournament_registrations_substitution_source
    ON public.tournament_registrations(substitution_source_registration_id)
    WHERE substitution_source_registration_id IS NOT NULL;

ALTER TABLE public.tournament_team_composition_changes
    ADD COLUMN IF NOT EXISTS replacement_player_id uuid NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'team_composition_changes_replacement_player_fkey'
          AND conrelid = 'public.tournament_team_composition_changes'::regclass
    ) THEN
        ALTER TABLE public.tournament_team_composition_changes
            ADD CONSTRAINT team_composition_changes_replacement_player_fkey
            FOREIGN KEY (replacement_player_id)
            REFERENCES public.players(id)
            ON DELETE RESTRICT;
    END IF;
END
$$;

-- ----------------------------------------------------------------------------
-- 3. Bypass interno y estrecho para INSERT post-freeze por sustitución
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._a_gogo_substitution_override_202()
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
    SELECT current_setting(
        'app.a_gogo_substitution_override',
        true
    ) = 'true';
$$;

REVOKE ALL ON FUNCTION public._a_gogo_substitution_override_202()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public._a_gogo_substitution_override_202()
TO service_role;

-- ----------------------------------------------------------------------------
-- 4. Freeze: conservar todos los bloqueos anteriores y permitir únicamente
--    INSERT interno de sustitución A-Go-Go.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.proteger_inscripcion_torneo_congelado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_torneo_congelado boolean;
    v_pertenece_snapshot boolean;
    v_allow_team_override boolean := false;
    v_allow_substitution_insert boolean := false;
    v_participation_type text;
    v_scoring_engine text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT EXISTS (
            SELECT 1
            FROM public.tournament_condition_freezes f
            WHERE f.tournament_id = NEW.tournament_id
        )
        INTO v_torneo_congelado;

        IF v_torneo_congelado AND NEW.activo = true THEN

            IF public._a_gogo_substitution_override_202() THEN
                SELECT tf.tipo_participacion::text,
                       tf.scoring_engine::text
                  INTO v_participation_type,
                       v_scoring_engine
                  FROM public.tournaments t
                  JOIN public.tournament_formats tf
                    ON tf.id = t.tournament_format_id
                 WHERE t.id = NEW.tournament_id;

                v_allow_substitution_insert :=
                    v_participation_type = 'equipo'
                    AND v_scoring_engine = 'team_stroke'
                    AND NEW.substitution_source_registration_id IS NOT NULL;
            END IF;

            IF NOT v_allow_substitution_insert THEN
                RAISE EXCEPTION
                    'No se pueden agregar inscripciones activas: las condiciones y los participantes del torneo ya fueron congelados.'
                    USING ERRCODE = '55000',
                          HINT = 'Los casos excepcionales posteriores al congelamiento requieren un procedimiento explícito y auditado.';
            END IF;
        END IF;

        RETURN NEW;
    END IF;

    IF NEW.tournament_id IS DISTINCT FROM OLD.tournament_id
       AND (
            EXISTS (
                SELECT 1
                FROM public.tournament_condition_freezes f
                WHERE f.tournament_id = OLD.tournament_id
            )
            OR EXISTS (
                SELECT 1
                FROM public.tournament_condition_freezes f
                WHERE f.tournament_id = NEW.tournament_id
            )
       ) THEN
        RAISE EXCEPTION
            'No se puede cambiar de torneo una inscripción vinculada con un torneo congelado.'
            USING ERRCODE = '55000';
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = OLD.tournament_id
    )
    INTO v_torneo_congelado;

    IF NOT v_torneo_congelado THEN
        RETURN NEW;
    END IF;

    IF public._a_gogo_composition_override_201() THEN
        SELECT tf.tipo_participacion::text,
               tf.scoring_engine::text
          INTO v_participation_type,
               v_scoring_engine
          FROM public.tournaments t
          JOIN public.tournament_formats tf
            ON tf.id = t.tournament_format_id
         WHERE t.id = OLD.tournament_id;

        v_allow_team_override :=
            v_participation_type = 'equipo'
            AND v_scoring_engine = 'team_stroke';
    END IF;

    IF NEW.player_id IS DISTINCT FROM OLD.player_id THEN
        RAISE EXCEPTION
            'No se puede cambiar el jugador: la inscripción pertenece a un torneo congelado.'
            USING ERRCODE = '55000';
    END IF;

    IF NEW.tournament_category_id IS DISTINCT FROM OLD.tournament_category_id THEN
        RAISE EXCEPTION
            'No se puede cambiar la categoría: las condiciones y hándicaps del torneo ya fueron congelados.'
            USING ERRCODE = '55000',
                  HINT = 'La categoría competitiva válida es la guardada en el snapshot del torneo.';
    END IF;

    IF NEW.marca_salida_id IS DISTINCT FROM OLD.marca_salida_id THEN
        RAISE EXCEPTION
            'No se puede cambiar la marca de salida: las condiciones y hándicaps del torneo ya fueron congelados.'
            USING ERRCODE = '55000',
                  HINT = 'La marca efectiva válida es la guardada en los snapshots por ronda.';
    END IF;

    IF NEW.tournament_team_id IS DISTINCT FROM OLD.tournament_team_id
       AND NOT v_allow_team_override THEN
        RAISE EXCEPTION
            'No se puede cambiar el equipo: la composición competitiva del torneo ya fue congelada.'
            USING ERRCODE = '55000',
                  HINT = 'En A-Go-Go use el procedimiento administrativo auditado de cambio de equipo.';
    END IF;

    IF OLD.activo = false AND NEW.activo = true THEN
        SELECT EXISTS (
            SELECT 1
            FROM public.tournament_handicap_snapshots hs
            WHERE hs.tournament_id = OLD.tournament_id
              AND hs.tournament_registration_id = OLD.id
        )
        INTO v_pertenece_snapshot;

        IF NOT v_pertenece_snapshot THEN
            RAISE EXCEPTION
                'No se puede reactivar esta inscripción porque no formó parte de los participantes congelados.'
                USING ERRCODE = '55000',
                      HINT = 'Los casos excepcionales posteriores al congelamiento requieren un procedimiento explícito y auditado.';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. Crear solicitud de sustitución
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.solicitar_sustitucion_integrante_a_gogo_post_freeze(
    p_outgoing_registration_id uuid,
    p_incoming_name text,
    p_incoming_email public.citext,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_reg public.tournament_registrations%ROWTYPE;
    v_team public.tournament_teams%ROWTYPE;
    v_tournament public.tournaments%ROWTYPE;
    v_admin_id uuid;
    v_freeze_id uuid;
    v_validation jsonb;
    v_incoming_player_id uuid;
    v_request_id uuid;
    v_participation_type text;
    v_scoring_engine text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    IF NULLIF(btrim(p_incoming_name), '') IS NULL THEN
        RAISE EXCEPTION 'Debes indicar el nombre del reemplazo.';
    END IF;

    IF NULLIF(btrim(p_incoming_email::text), '') IS NULL THEN
        RAISE EXCEPTION 'Debes indicar el correo del reemplazo.';
    END IF;

    IF length(btrim(COALESCE(p_reason, ''))) < 5 THEN
        RAISE EXCEPTION
            'El motivo de la sustitución debe contener al menos 5 caracteres.';
    END IF;

    SELECT *
      INTO v_reg
      FROM public.tournament_registrations
     WHERE id = p_outgoing_registration_id
     FOR UPDATE;

    IF v_reg.id IS NULL OR NOT v_reg.activo THEN
        RAISE EXCEPTION 'La inscripción saliente no existe o está inactiva.';
    END IF;

    IF v_reg.tournament_team_id IS NULL THEN
        RAISE EXCEPTION 'La inscripción saliente no pertenece a un equipo.';
    END IF;

    SELECT *
      INTO v_tournament
      FROM public.tournaments
     WHERE id = v_reg.tournament_id
       AND activo = true;

    SELECT *
      INTO v_team
      FROM public.tournament_teams
     WHERE id = v_reg.tournament_team_id
       AND tournament_id = v_reg.tournament_id
       AND activo = true;

    IF v_tournament.id IS NULL OR v_team.id IS NULL THEN
        RAISE EXCEPTION 'El torneo o el equipo ya no están activos.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament.id) THEN
        RAISE EXCEPTION
            'No tienes permiso para sustituir integrantes de este torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tf.tipo_participacion::text,
           tf.scoring_engine::text
      INTO v_participation_type,
           v_scoring_engine
      FROM public.tournament_formats tf
     WHERE tf.id = v_tournament.tournament_format_id;

    IF v_participation_type IS DISTINCT FROM 'equipo'
       OR v_scoring_engine IS DISTINCT FROM 'team_stroke' THEN
        RAISE EXCEPTION
            'Este procedimiento solo aplica a formatos A-Go-Go/team_stroke.';
    END IF;

    SELECT f.id
      INTO v_freeze_id
      FROM public.tournament_condition_freezes f
     WHERE f.tournament_id = v_tournament.id
     ORDER BY f.created_at DESC
     LIMIT 1;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION
            'El torneo todavía no está congelado; use el flujo normal de composición.';
    END IF;

    -- Fase 2B todavía no modifica una ronda con salidas validadas.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_round_start_validations sv
          JOIN public.tournament_rounds r
            ON r.id = sv.tournament_round_id
         WHERE r.tournament_id = v_tournament.id
           AND sv.status = 'validated'
    ) THEN
        RAISE EXCEPTION
            'Existe al menos una ronda con salidas validadas. Las sustituciones posteriores a la validación se habilitarán en la Fase 4.'
            USING ERRCODE = '55000';
    END IF;

    IF v_team.captain_player_id = v_reg.player_id THEN
        RAISE EXCEPTION
            'El capitán no puede sustituirse mediante esta operación. Requiere un flujo específico de cambio de capitán.';
    END IF;

    -- Evitar dos operaciones simultáneas para el mismo saliente/correo.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(v_reg.id::text, 202)
    );

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            v_tournament.id::text || ':sub:' ||
            lower(btrim(p_incoming_email::text)),
            202
        )
    );

    v_validation :=
        public._validar_disponibilidad_integrante_199(
            v_tournament.id,
            v_team.id,
            p_incoming_email
        );

    IF NOT COALESCE((v_validation->>'available')::boolean, false) THEN
        RAISE EXCEPTION '%', v_validation->>'message'
            USING ERRCODE = '23505',
                  DETAIL = COALESCE(
                      v_validation->>'code',
                      'MEMBER_NOT_AVAILABLE'
                  );
    END IF;

    v_incoming_player_id :=
        NULLIF(v_validation->>'playerId', '')::uuid;

    IF EXISTS (
        SELECT 1
          FROM public.tournament_team_substitution_requests sr
         WHERE sr.tournament_id = v_tournament.id
           AND sr.status = 'pending_confirmation'
           AND (
                lower(sr.incoming_email::text) =
                    lower(btrim(p_incoming_email::text))
                OR (
                    v_incoming_player_id IS NOT NULL
                    AND sr.incoming_player_id = v_incoming_player_id
                )
           )
    ) THEN
        RAISE EXCEPTION
            'Este correo ya participa en otra sustitución pendiente del torneo.';
    END IF;

    INSERT INTO public.tournament_team_substitution_requests (
        tournament_id,
        tournament_team_id,
        outgoing_registration_id,
        outgoing_player_id,
        incoming_name,
        incoming_email,
        incoming_player_id,
        status,
        reason,
        payment_coverage_id,
        requested_by_admin_id
    )
    VALUES (
        v_tournament.id,
        v_team.id,
        v_reg.id,
        v_reg.player_id,
        btrim(p_incoming_name),
        btrim(p_incoming_email::text)::public.citext,
        v_incoming_player_id,
        'pending_confirmation',
        btrim(p_reason),
        v_reg.team_payment_coverage_id,
        v_admin_id
    )
    RETURNING id INTO v_request_id;

    RETURN jsonb_build_object(
        'requestId', v_request_id,
        'tournamentId', v_tournament.id,
        'teamId', v_team.id,
        'outgoingRegistrationId', v_reg.id,
        'outgoingPlayerId', v_reg.player_id,
        'incomingPlayerExists', v_incoming_player_id IS NOT NULL,
        'incomingPlayerId', v_incoming_player_id,
        'incomingEmail', btrim(p_incoming_email::text),
        'status', 'pending_confirmation',
        'requiresConfirmation', true,
        'economicallyCovered',
            v_reg.team_payment_coverage_id IS NOT NULL
    );
END;
$$;

REVOKE ALL ON FUNCTION
public.solicitar_sustitucion_integrante_a_gogo_post_freeze(
    uuid, text, public.citext, text
)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
public.solicitar_sustitucion_integrante_a_gogo_post_freeze(
    uuid, text, public.citext, text
)
TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 6. Confirmación personal del reemplazo
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.confirmar_sustitucion_integrante_a_gogo(
    p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_current_player_id uuid;
    v_current_email public.citext;
    v_request public.tournament_team_substitution_requests%ROWTYPE;
    v_old_reg public.tournament_registrations%ROWTYPE;
    v_team public.tournament_teams%ROWTYPE;
    v_new_reg public.tournament_registrations%ROWTYPE;
    v_change_id uuid;
    v_old_slot_id uuid;
    v_new_slot_id uuid;
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
      INTO v_request
      FROM public.tournament_team_substitution_requests
     WHERE id = p_request_id
     FOR UPDATE;

    IF v_request.id IS NULL THEN
        RAISE EXCEPTION 'La solicitud de sustitución no existe.';
    END IF;

    IF v_request.status <> 'pending_confirmation' THEN
        RAISE EXCEPTION 'La sustitución ya no está pendiente de confirmación.';
    END IF;

    IF lower(v_request.incoming_email::text) <>
       lower(v_current_email::text) THEN
        RAISE EXCEPTION 'Esta sustitución pertenece a otro correo.';
    END IF;

    -- Serializar por torneo/player.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            v_request.tournament_id::text ||
            ':player:' || v_current_player_id::text,
            202
        )
    );

    -- Revalidar disponibilidad al momento exacto de confirmar.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_registrations tr
         WHERE tr.tournament_id = v_request.tournament_id
           AND tr.player_id = v_current_player_id
           AND tr.activo = true
    ) THEN
        RAISE EXCEPTION
            'Este jugador ya está inscrito en este torneo y no puede confirmar la sustitución.';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM public.tournament_pre_reservations pr
         WHERE pr.tournament_id = v_request.tournament_id
           AND pr.player_id = v_current_player_id
           AND pr.activo = true
           AND pr.tournament_registration_id IS NULL
    ) THEN
        RAISE EXCEPTION
            'Este jugador ya tiene una pre-reserva activa en este torneo.';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM public.phone_reservations ph
         WHERE ph.tournament_id = v_request.tournament_id
           AND ph.activo = true
           AND lower(ph.correo::text) = lower(v_current_email::text)
    ) THEN
        RAISE EXCEPTION
            'Este jugador ya tiene una reserva telefónica activa en este torneo.';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM public.tournament_team_roster_slots rs
         WHERE rs.tournament_id = v_request.tournament_id
           AND rs.status IN ('pending_confirmation','confirmed')
           AND (
               rs.player_id = v_current_player_id
               OR lower(rs.email::text) = lower(v_current_email::text)
           )
    ) THEN
        RAISE EXCEPTION
            'Este correo ya está reservado como integrante de otro equipo en este torneo.';
    END IF;

    -- Fase 2B no altera salidas validadas.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_round_start_validations sv
          JOIN public.tournament_rounds r
            ON r.id = sv.tournament_round_id
         WHERE r.tournament_id = v_request.tournament_id
           AND sv.status = 'validated'
    ) THEN
        RAISE EXCEPTION
            'Existe una ronda con salidas validadas. La sustitución debe procesarse en el flujo de Fase 4.';
    END IF;

    SELECT *
      INTO v_old_reg
      FROM public.tournament_registrations
     WHERE id = v_request.outgoing_registration_id
     FOR UPDATE;

    IF v_old_reg.id IS NULL OR NOT v_old_reg.activo THEN
        RAISE EXCEPTION
            'La inscripción del jugador saliente ya no está activa.';
    END IF;

    IF v_old_reg.tournament_team_id IS DISTINCT FROM
       v_request.tournament_team_id THEN
        RAISE EXCEPTION
            'La inscripción saliente ya no pertenece al equipo esperado.';
    END IF;

    SELECT *
      INTO v_team
      FROM public.tournament_teams
     WHERE id = v_request.tournament_team_id
       AND activo = true;

    IF v_team.id IS NULL THEN
        RAISE EXCEPTION 'El equipo ya no está activo.';
    END IF;

    IF v_team.captain_player_id = v_old_reg.player_id THEN
        RAISE EXCEPTION
            'El capitán no puede sustituirse mediante esta operación.';
    END IF;

    -- 1) dar de baja al saliente, preservando su inscripción y pago histórico.
    UPDATE public.tournament_registrations
       SET activo = false,
           fecha_baja = now(),
           motivo_baja =
               'Sustitución A-Go-Go post-freeze. Solicitud ' ||
               v_request.id::text
     WHERE id = v_old_reg.id;

    -- 2) marcar cualquier slot convertido del saliente como cancelado histórico.
    SELECT rs.id
      INTO v_old_slot_id
      FROM public.tournament_team_roster_slots rs
     WHERE rs.tournament_registration_id = v_old_reg.id
     ORDER BY rs.created_at
     LIMIT 1;

    IF v_old_slot_id IS NOT NULL THEN
        UPDATE public.tournament_team_roster_slots
           SET status = 'cancelled',
               cancelled_at = now(),
               updated_at = now()
         WHERE id = v_old_slot_id;
    END IF;

    -- 3) INSERT excepcional y auditado post-freeze.
    PERFORM set_config(
        'app.a_gogo_substitution_override',
        'true',
        true
    );

    PERFORM set_config(
        'app.saltar_validacion_cupo_equipo',
        'true',
        true
    );

    INSERT INTO public.tournament_registrations (
        tournament_id,
        player_id,
        tournament_category_id,
        tournament_team_id,
        monto_pagado,
        fecha_pago,
        medio_pago,
        referencia_pago,
        team_payment_coverage_id,
        substitution_source_registration_id
    )
    VALUES (
        v_request.tournament_id,
        v_current_player_id,
        v_team.tournament_category_id,
        v_request.tournament_team_id,

        -- Sustitución: no genera ingreso adicional.
        0,

        now(),
        v_old_reg.medio_pago,
        'SUST-' || v_request.id::text,
        v_request.payment_coverage_id,
        v_old_reg.id
    )
    RETURNING * INTO v_new_reg;

    -- 4) conservar roster actual como fotografía operativa.
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
        economically_covered_at
    )
    VALUES (
        v_request.tournament_id,
        v_request.tournament_team_id,
        'member',
        v_request.incoming_name,
        v_request.incoming_email,
        v_current_player_id,
        'converted',
        v_new_reg.id,
        v_team.captain_player_id,
        now(),
        v_request.payment_coverage_id,
        CASE
            WHEN v_request.payment_coverage_id IS NOT NULL
            THEN now()
            ELSE NULL
        END
    )
    RETURNING id INTO v_new_slot_id;

    UPDATE public.tournament_team_substitution_requests
       SET incoming_player_id = v_current_player_id,
           incoming_registration_id = v_new_reg.id,
           status = 'confirmed',
           confirmed_at = now(),
           updated_at = now()
     WHERE id = v_request.id;

    INSERT INTO public.tournament_team_composition_changes (
        tournament_id,
        tournament_registration_id,
        player_id,
        replacement_player_id,
        change_type,
        old_team_id,
        new_team_id,
        reason,
        changed_by_admin_id,
        freeze_id,
        metadata
    )
    VALUES (
        v_request.tournament_id,
        v_old_reg.id,
        v_old_reg.player_id,
        v_current_player_id,
        'player_substitution',
        v_request.tournament_team_id,
        v_request.tournament_team_id,
        v_request.reason,
        v_request.requested_by_admin_id,
        (
            SELECT f.id
            FROM public.tournament_condition_freezes f
            WHERE f.tournament_id = v_request.tournament_id
            ORDER BY f.created_at DESC
            LIMIT 1
        ),
        jsonb_build_object(
            'phase', '202_FASE2B',
            'requestId', v_request.id,
            'incomingRegistrationId', v_new_reg.id,
            'oldRosterSlotId', v_old_slot_id,
            'newRosterSlotId', v_new_slot_id,
            'additionalCharge', 0,
            'teamPaymentCoverageId', v_request.payment_coverage_id
        )
    )
    RETURNING id INTO v_change_id;

    RETURN jsonb_build_object(
        'requestId', v_request.id,
        'changeId', v_change_id,
        'teamId', v_request.tournament_team_id,
        'outgoingRegistrationId', v_old_reg.id,
        'outgoingPlayerId', v_old_reg.player_id,
        'incomingRegistrationId', v_new_reg.id,
        'incomingPlayerId', v_current_player_id,
        'additionalCharge', 0,
        'teamPaymentCoverageId', v_request.payment_coverage_id,
        'status', 'confirmed'
    );
END;
$$;

REVOKE ALL ON FUNCTION
public.confirmar_sustitucion_integrante_a_gogo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
public.confirmar_sustitucion_integrante_a_gogo(uuid)
TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 7. Rechazo personal del reemplazo
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rechazar_sustitucion_integrante_a_gogo(
    p_request_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_player_id uuid;
    v_email public.citext;
    v_request public.tournament_team_substitution_requests%ROWTYPE;
BEGIN
    v_player_id := public._current_player_id_199();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión como jugador.';
    END IF;

    SELECT email
      INTO v_email
      FROM public.players
     WHERE id = v_player_id
       AND activo = true;

    SELECT *
      INTO v_request
      FROM public.tournament_team_substitution_requests
     WHERE id = p_request_id
     FOR UPDATE;

    IF v_request.id IS NULL
       OR v_request.status <> 'pending_confirmation' THEN
        RAISE EXCEPTION 'La sustitución ya no está pendiente.';
    END IF;

    IF lower(v_request.incoming_email::text) <>
       lower(v_email::text) THEN
        RAISE EXCEPTION 'Esta sustitución pertenece a otro correo.';
    END IF;

    UPDATE public.tournament_team_substitution_requests
       SET status = 'rejected',
           rejected_at = now(),
           updated_at = now()
     WHERE id = p_request_id;
END;
$$;

REVOKE ALL ON FUNCTION
public.rechazar_sustitucion_integrante_a_gogo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
public.rechazar_sustitucion_integrante_a_gogo(uuid)
TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 8. Cancelación administrativa mientras siga pendiente
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cancelar_sustitucion_integrante_a_gogo(
    p_request_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_request public.tournament_team_substitution_requests%ROWTYPE;
BEGIN
    SELECT *
      INTO v_request
      FROM public.tournament_team_substitution_requests
     WHERE id = p_request_id
     FOR UPDATE;

    IF v_request.id IS NULL
       OR v_request.status <> 'pending_confirmation' THEN
        RAISE EXCEPTION 'La sustitución ya no está pendiente.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_request.tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para cancelar esta sustitución.'
            USING ERRCODE = '42501';
    END IF;

    UPDATE public.tournament_team_substitution_requests
       SET status = 'cancelled',
           cancelled_at = now(),
           updated_at = now()
     WHERE id = p_request_id;
END;
$$;

REVOKE ALL ON FUNCTION
public.cancelar_sustitucion_integrante_a_gogo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
public.cancelar_sustitucion_integrante_a_gogo(uuid)
TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 9. Consultar sustituciones pendientes propias
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_mis_sustituciones_a_gogo(
    p_tournament_id uuid DEFAULT NULL
)
RETURNS TABLE (
    request_id uuid,
    tournament_id uuid,
    team_id uuid,
    team_name text,
    outgoing_player_name text,
    incoming_email public.citext,
    reason text,
    requested_at timestamptz,
    economically_covered boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_player_id uuid;
    v_email public.citext;
BEGIN
    v_player_id := public._current_player_id_199();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión como jugador.';
    END IF;

    SELECT p.email
      INTO v_email
      FROM public.players p
     WHERE p.id = v_player_id
       AND p.activo = true;

    RETURN QUERY
    SELECT sr.id,
           sr.tournament_id,
           sr.tournament_team_id,
           tt.nombre_equipo,
           concat_ws(' ', po.nombres, po.apellidos)::text,
           sr.incoming_email,
           sr.reason,
           sr.requested_at,
           sr.payment_coverage_id IS NOT NULL
      FROM public.tournament_team_substitution_requests sr
      JOIN public.tournament_teams tt
        ON tt.id = sr.tournament_team_id
      JOIN public.players po
        ON po.id = sr.outgoing_player_id
     WHERE sr.status = 'pending_confirmation'
       AND lower(sr.incoming_email::text) = lower(v_email::text)
       AND (
            p_tournament_id IS NULL
            OR sr.tournament_id = p_tournament_id
       )
     ORDER BY sr.requested_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION
public.obtener_mis_sustituciones_a_gogo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
public.obtener_mis_sustituciones_a_gogo(uuid)
TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 10. Vincular player_id por correo cuando el invitado crea/actualiza su cuenta
--     Sin auto-confirmar.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._vincular_sustitucion_a_gogo_por_email_202()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
    UPDATE public.tournament_team_substitution_requests sr
       SET incoming_player_id = NEW.id,
           updated_at = now()
     WHERE sr.status = 'pending_confirmation'
       AND lower(sr.incoming_email::text) = lower(NEW.email::text)
       AND sr.incoming_player_id IS NULL;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_vincular_sustitucion_a_gogo_por_email_202
ON public.players;

CREATE TRIGGER trg_vincular_sustitucion_a_gogo_por_email_202
AFTER INSERT OR UPDATE OF email
ON public.players
FOR EACH ROW
EXECUTE FUNCTION public._vincular_sustitucion_a_gogo_por_email_202();

COMMENT ON TABLE public.tournament_team_substitution_requests IS
'Solicitudes post-freeze para reemplazar un integrante A-Go-Go sin modificar la identidad de la inscripción saliente. El reemplazo debe confirmar personalmente.';

COMMENT ON COLUMN public.tournament_registrations.substitution_source_registration_id IS
'Inscripción histórica que dio origen a esta nueva inscripción por sustitución.';

COMMIT;
