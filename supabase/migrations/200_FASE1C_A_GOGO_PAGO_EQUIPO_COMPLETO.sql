-- ============================================================================
-- MIGRACIÓN 200 FASE 1C
-- A-Go-Go — pago de equipo completo con cobertura económica única
-- Proyecto: Tee Central / GOLF IN FULL
--
-- OBJETIVO
-- - Un único pago del capitán cubre económicamente al equipo.
-- - No crear jugadores ficticios.
-- - No duplicar el importe del equipo en cada inscripción.
-- - Los integrantes pendientes de identidad/confirmación pueden quedar cubiertos
--   económicamente y se convierten a inscripción cuando confirman personalmente.
-- - Revalidar el roster y los conflictos inmediatamente antes del pago.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. payment_attempts: identificar explícitamente el equipo del pago
-- ----------------------------------------------------------------------------

ALTER TABLE public.payment_attempts
    ADD COLUMN IF NOT EXISTS tournament_team_id uuid NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'payment_attempts_tournament_team_id_fkey'
          AND conrelid = 'public.payment_attempts'::regclass
    ) THEN
        ALTER TABLE public.payment_attempts
            ADD CONSTRAINT payment_attempts_tournament_team_id_fkey
            FOREIGN KEY (tournament_team_id)
            REFERENCES public.tournament_teams(id)
            ON DELETE RESTRICT;
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_payment_attempts_tournament_team
    ON public.payment_attempts(tournament_team_id)
    WHERE tournament_team_id IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 2. Cobertura económica de equipo
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_team_payment_coverages (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    tournament_team_id uuid NOT NULL
        REFERENCES public.tournament_teams(id) ON DELETE RESTRICT,
    payment_attempt_id uuid NOT NULL
        REFERENCES public.payment_attempts(id) ON DELETE RESTRICT,
    payer_player_id uuid NOT NULL
        REFERENCES public.players(id) ON DELETE RESTRICT,
    amount numeric NOT NULL CHECK (amount >= 0),
    currency text NOT NULL,
    medio_pago public.medio_pago_torneo NOT NULL,
    referencia_pago text NOT NULL,
    status text NOT NULL DEFAULT 'paid'
        CHECK (status IN ('paid','voided')),
    paid_at timestamptz NOT NULL DEFAULT now(),
    voided_at timestamptz NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_team_payment_coverages_attempt_unique
        UNIQUE (payment_attempt_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_team_payment_coverage_paid_team
    ON public.tournament_team_payment_coverages(tournament_team_id)
    WHERE status = 'paid';

CREATE INDEX IF NOT EXISTS idx_team_payment_coverages_tournament
    ON public.tournament_team_payment_coverages(tournament_id);

CREATE INDEX IF NOT EXISTS idx_team_payment_coverages_payer
    ON public.tournament_team_payment_coverages(payer_player_id);

DROP TRIGGER IF EXISTS set_updated_at_tournament_team_payment_coverages
    ON public.tournament_team_payment_coverages;

CREATE TRIGGER set_updated_at_tournament_team_payment_coverages
BEFORE UPDATE ON public.tournament_team_payment_coverages
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.tournament_team_payment_coverages ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_team_payment_coverages
FROM anon, authenticated;

GRANT ALL ON TABLE public.tournament_team_payment_coverages
TO service_role;

-- ----------------------------------------------------------------------------
-- 3. Relacionar slots e inscripciones con la cobertura económica
-- ----------------------------------------------------------------------------

ALTER TABLE public.tournament_team_roster_slots
    ADD COLUMN IF NOT EXISTS payment_coverage_id uuid NULL,
    ADD COLUMN IF NOT EXISTS economically_covered_at timestamptz NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'team_roster_slots_payment_coverage_id_fkey'
          AND conrelid = 'public.tournament_team_roster_slots'::regclass
    ) THEN
        ALTER TABLE public.tournament_team_roster_slots
            ADD CONSTRAINT team_roster_slots_payment_coverage_id_fkey
            FOREIGN KEY (payment_coverage_id)
            REFERENCES public.tournament_team_payment_coverages(id)
            ON DELETE RESTRICT;
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_team_roster_slots_payment_coverage
    ON public.tournament_team_roster_slots(payment_coverage_id)
    WHERE payment_coverage_id IS NOT NULL;

ALTER TABLE public.tournament_registrations
    ADD COLUMN IF NOT EXISTS team_payment_coverage_id uuid NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'tournament_registrations_team_payment_coverage_id_fkey'
          AND conrelid = 'public.tournament_registrations'::regclass
    ) THEN
        ALTER TABLE public.tournament_registrations
            ADD CONSTRAINT tournament_registrations_team_payment_coverage_id_fkey
            FOREIGN KEY (team_payment_coverage_id)
            REFERENCES public.tournament_team_payment_coverages(id)
            ON DELETE RESTRICT;
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_tournament_registrations_team_payment_coverage
    ON public.tournament_registrations(team_payment_coverage_id)
    WHERE team_payment_coverage_id IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 4. Helper de validación para pago completo
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._validar_equipo_pago_completo_200(
    p_team_id uuid,
    p_payer_player_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_team public.tournament_teams%ROWTYPE;
    v_tournament public.tournaments%ROWTYPE;
    v_format_participation text;
    v_scoring_engine text;
    v_expected integer;
    v_roster_count integer;
    v_paid_coverage uuid;
    v_conflict record;
    v_total_reserved integer;
BEGIN
    SELECT *
      INTO v_team
      FROM public.tournament_teams
     WHERE id = p_team_id
       AND activo = true;

    IF v_team.id IS NULL THEN
        RAISE EXCEPTION 'El equipo no existe o está inactivo.';
    END IF;

    SELECT *
      INTO v_tournament
      FROM public.tournaments
     WHERE id = v_team.tournament_id
       AND activo = true;

    IF v_tournament.id IS NULL THEN
        RAISE EXCEPTION 'El torneo no existe o está inactivo.';
    END IF;

    SELECT tf.tipo_participacion::text, tf.scoring_engine::text
      INTO v_format_participation, v_scoring_engine
      FROM public.tournament_formats tf
     WHERE tf.id = v_tournament.tournament_format_id;

    IF v_format_participation IS DISTINCT FROM 'equipo'
       OR v_scoring_engine IS DISTINCT FROM 'team_stroke' THEN
        RAISE EXCEPTION
            'El pago de equipo completo de esta fase aplica únicamente a formatos de equipo con motor team_stroke.';
    END IF;

    IF v_tournament.estatus <> 'inscripciones_abiertas'::public.estatus_torneo THEN
        RAISE EXCEPTION 'Las inscripciones del torneo no están abiertas.';
    END IF;

    IF v_team.captain_player_id IS DISTINCT FROM p_payer_player_id THEN
        RAISE EXCEPTION 'Solo el capitán del equipo puede iniciar el pago del equipo completo.';
    END IF;

    IF v_tournament.tarifa_equipo_completo IS NULL
       OR v_tournament.tarifa_equipo_completo <= 0 THEN
        RAISE EXCEPTION 'Este torneo no tiene configurada una tarifa válida para equipo completo.';
    END IF;

    v_expected := v_tournament.jugadores_por_equipo;

    IF v_expected IS NULL OR v_expected <= 0 THEN
        RAISE EXCEPTION 'El torneo no tiene configurado el número de jugadores por equipo.';
    END IF;

    SELECT count(*)
      INTO v_roster_count
      FROM public.tournament_team_roster_slots rs
     WHERE rs.tournament_team_id = p_team_id
       AND rs.status IN ('pending_confirmation','confirmed');

    IF v_roster_count <> v_expected THEN
        RAISE EXCEPTION
            'El equipo debe tener exactamente % plazas activas antes de pagar. Actualmente tiene %.',
            v_expected, v_roster_count;
    END IF;

    SELECT c.id
      INTO v_paid_coverage
      FROM public.tournament_team_payment_coverages c
     WHERE c.tournament_team_id = p_team_id
       AND c.status = 'paid'
     LIMIT 1;

    IF v_paid_coverage IS NOT NULL THEN
        RAISE EXCEPTION 'Este equipo ya tiene un pago completo aprobado.';
    END IF;

    -- El flujo de pago completo parte de un roster todavía no convertido.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_team_roster_slots rs
         WHERE rs.tournament_team_id = p_team_id
           AND rs.status = 'converted'
    ) OR EXISTS (
        SELECT 1
          FROM public.tournament_registrations tr
         WHERE tr.tournament_team_id = p_team_id
           AND tr.activo = true
    ) THEN
        RAISE EXCEPTION
            'El equipo ya contiene inscripciones formalizadas. El pago completo solo puede iniciarse antes de convertir integrantes a inscripciones.';
    END IF;

    -- Revalidación de conflictos por cada integrante conocido o por correo.
    FOR v_conflict IN
        SELECT rs.id,
               rs.email,
               rs.player_id
          FROM public.tournament_team_roster_slots rs
         WHERE rs.tournament_team_id = p_team_id
           AND rs.status IN ('pending_confirmation','confirmed')
    LOOP
        IF v_conflict.player_id IS NOT NULL
           AND EXISTS (
               SELECT 1
                 FROM public.tournament_registrations tr
                WHERE tr.tournament_id = v_team.tournament_id
                  AND tr.player_id = v_conflict.player_id
                  AND tr.activo = true
           ) THEN
            RAISE EXCEPTION
                'Este jugador ya está inscrito en este torneo y no puede incluirse en el pago del equipo.';
        END IF;

        IF v_conflict.player_id IS NOT NULL
           AND EXISTS (
               SELECT 1
                 FROM public.tournament_pre_reservations pr
                WHERE pr.tournament_id = v_team.tournament_id
                  AND pr.player_id = v_conflict.player_id
                  AND pr.activo = true
                  AND pr.tournament_registration_id IS NULL
           ) THEN
            RAISE EXCEPTION
                'Uno de los integrantes ya tiene una pre-reserva activa en este torneo.';
        END IF;

        IF EXISTS (
            SELECT 1
              FROM public.phone_reservations ph
             WHERE ph.tournament_id = v_team.tournament_id
               AND ph.activo = true
               AND lower(ph.correo::text) = lower(v_conflict.email::text)
        ) THEN
            RAISE EXCEPTION
                'Uno de los integrantes ya tiene una reserva telefónica activa en este torneo.';
        END IF;
    END LOOP;

    -- Cupo total del torneo: contar personas ya ocupadas fuera de este roster
    -- más las plazas del equipo que se pretende pagar.
    IF v_tournament.cupo_maximo IS NOT NULL THEN
        SELECT
            (SELECT count(*)
               FROM public.tournament_registrations tr
              WHERE tr.tournament_id = v_team.tournament_id
                AND tr.activo = true)
            +
            (SELECT count(*)
               FROM public.tournament_pre_reservations pr
              WHERE pr.tournament_id = v_team.tournament_id
                AND pr.activo = true
                AND pr.tournament_registration_id IS NULL
                AND pr.tournament_team_id IS DISTINCT FROM p_team_id)
            +
            (SELECT count(*)
               FROM public.phone_reservations ph
              WHERE ph.tournament_id = v_team.tournament_id
                AND ph.activo = true
                AND ph.tournament_team_id IS DISTINCT FROM p_team_id)
            +
            (SELECT count(*)
               FROM public.tournament_team_roster_slots rs
              WHERE rs.tournament_id = v_team.tournament_id
                AND rs.tournament_team_id <> p_team_id
                AND rs.status IN ('pending_confirmation','confirmed')
                AND rs.tournament_registration_id IS NULL)
            +
            v_roster_count
        INTO v_total_reserved;

        IF v_total_reserved > v_tournament.cupo_maximo THEN
            RAISE EXCEPTION
                'El pago no puede continuar porque el torneo excedería su cupo máximo de % jugadores.',
                v_tournament.cupo_maximo;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'valid', true,
        'tournamentId', v_team.tournament_id,
        'teamId', p_team_id,
        'captainPlayerId', v_team.captain_player_id,
        'expectedPlayers', v_expected,
        'rosterPlayers', v_roster_count,
        'amount', v_tournament.tarifa_equipo_completo,
        'currency', v_tournament.moneda
    );
END;
$$;

REVOKE ALL ON FUNCTION public._validar_equipo_pago_completo_200(uuid, uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public._validar_equipo_pago_completo_200(uuid, uuid)
TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 5. RPC para iniciar el pago completo
--    El frontend no decide el monto.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.preparar_pago_equipo_completo(
    p_team_id uuid,
    p_medio_pago public.medio_pago_torneo
)
RETURNS public.payment_attempts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_player_id uuid;
    v_validation jsonb;
    v_attempt public.payment_attempts;
BEGIN
    v_player_id := public._current_player_id_199();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión como jugador.';
    END IF;

    -- Serializa creación de intento por equipo.
    PERFORM pg_advisory_xact_lock(hashtextextended(p_team_id::text, 200));

    v_validation :=
        public._validar_equipo_pago_completo_200(p_team_id, v_player_id);

    IF EXISTS (
        SELECT 1
          FROM public.payment_attempts pa
         WHERE pa.tournament_team_id = p_team_id
           AND pa.concepto = 'inscripcion_equipo'::public.concepto_pago
           AND pa.resultado IS NULL
    ) THEN
        RAISE EXCEPTION 'Este equipo ya tiene un intento de pago pendiente.';
    END IF;

    INSERT INTO public.payment_attempts (
        player_id,
        tournament_id,
        tournament_team_id,
        concepto,
        monto,
        medio_pago,
        referencia_id,
        detalle
    )
    VALUES (
        v_player_id,
        (v_validation->>'tournamentId')::uuid,
        p_team_id,
        'inscripcion_equipo'::public.concepto_pago,
        (v_validation->>'amount')::numeric,
        p_medio_pago,
        p_team_id,
        jsonb_build_object(
            'source', 'team_full_payment_v200',
            'expectedPlayers', (v_validation->>'expectedPlayers')::integer,
            'currency', v_validation->>'currency'
        )
    )
    RETURNING * INTO v_attempt;

    RETURN v_attempt;
END;
$$;

REVOKE ALL ON FUNCTION public.preparar_pago_equipo_completo(
    uuid, public.medio_pago_torneo
)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.preparar_pago_equipo_completo(
    uuid, public.medio_pago_torneo
)
TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 6. Helper interno: convertir un slot confirmado y cubierto a inscripción
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._convertir_slot_cubierto_a_inscripcion_200(
    p_slot_id uuid
)
RETURNS public.tournament_registrations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_slot public.tournament_team_roster_slots%ROWTYPE;
    v_team public.tournament_teams%ROWTYPE;
    v_cov public.tournament_team_payment_coverages%ROWTYPE;
    v_reg public.tournament_registrations;
    v_amount numeric := 0;
BEGIN
    SELECT *
      INTO v_slot
      FROM public.tournament_team_roster_slots
     WHERE id = p_slot_id
     FOR UPDATE;

    IF v_slot.id IS NULL THEN
        RAISE EXCEPTION 'No existe el integrante del roster.';
    END IF;

    IF v_slot.status <> 'confirmed'
       OR v_slot.player_id IS NULL
       OR v_slot.payment_coverage_id IS NULL
       OR v_slot.tournament_registration_id IS NOT NULL THEN
        RETURN NULL;
    END IF;

    SELECT *
      INTO v_cov
      FROM public.tournament_team_payment_coverages
     WHERE id = v_slot.payment_coverage_id
       AND status = 'paid';

    IF v_cov.id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT *
      INTO v_team
      FROM public.tournament_teams
     WHERE id = v_slot.tournament_team_id;

    IF EXISTS (
        SELECT 1
          FROM public.tournament_registrations tr
         WHERE tr.tournament_id = v_slot.tournament_id
           AND tr.player_id = v_slot.player_id
           AND tr.activo = true
    ) THEN
        RAISE EXCEPTION
            'Este jugador ya está inscrito en este torneo y no puede convertirse desde el roster.';
    END IF;

    -- Para conservar compatibilidad con reportes existentes que suman monto_pagado:
    -- el importe total del equipo se registra únicamente en la inscripción del capitán.
    IF v_slot.player_id = v_team.captain_player_id THEN
        v_amount := v_cov.amount;
    END IF;

    PERFORM set_config('app.saltar_validacion_cupo_equipo', 'true', true);

    INSERT INTO public.tournament_registrations (
        tournament_id,
        player_id,
        tournament_category_id,
        tournament_team_id,
        monto_pagado,
        fecha_pago,
        medio_pago,
        referencia_pago,
        team_payment_coverage_id
    )
    VALUES (
        v_slot.tournament_id,
        v_slot.player_id,
        v_team.tournament_category_id,
        v_slot.tournament_team_id,
        v_amount,
        v_cov.paid_at,
        v_cov.medio_pago,
        v_cov.referencia_pago,
        v_cov.id
    )
    RETURNING * INTO v_reg;

    UPDATE public.tournament_team_roster_slots
       SET status = 'converted',
           tournament_registration_id = v_reg.id,
           updated_at = now()
     WHERE id = v_slot.id;

    RETURN v_reg;
END;
$$;

REVOKE ALL ON FUNCTION public._convertir_slot_cubierto_a_inscripcion_200(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public._convertir_slot_cubierto_a_inscripcion_200(uuid)
TO service_role;

-- ----------------------------------------------------------------------------
-- 7. Confirmación de invitación:
--    si el equipo ya está pagado, confirmar identidad convierte la inscripción.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.confirmar_invitacion_equipo(
    p_slot_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_current_player_id uuid;
    v_current_email public.citext;
    v_slot public.tournament_team_roster_slots%ROWTYPE;
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

    -- Revalidar que el jugador no haya quedado formalmente comprometido
    -- por otra vía después de que el capitán lo invitó.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_registrations tr
         WHERE tr.tournament_id = v_slot.tournament_id
           AND tr.player_id = v_current_player_id
           AND tr.activo = true
    ) THEN
        RAISE EXCEPTION
            'Este jugador ya está inscrito en este torneo y no puede agregarse a otro equipo.';
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
        'economicallyCovered', v_slot.payment_coverage_id IS NOT NULL
    );
END;
$$;

REVOKE ALL ON FUNCTION public.confirmar_invitacion_equipo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.confirmar_invitacion_equipo(uuid)
TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 8. Procesamiento de pago:
--    conservar ramas existentes + implementar inscripcion_equipo
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.procesar_resultado_pago(
    p_attempt_id uuid,
    p_aprobado boolean,
    p_referencia_pago text DEFAULT NULL::text
)
RETURNS public.tournament_registrations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_attempt   public.payment_attempts;
    v_pre       public.tournament_pre_reservations;
    v_resultado public.tournament_registrations;
    v_validation jsonb;
    v_coverage public.tournament_team_payment_coverages;
    v_slot record;
    v_payment_reference text;
BEGIN
    SELECT *
      INTO v_attempt
      FROM public.payment_attempts
     WHERE id = p_attempt_id
     FOR UPDATE;

    IF v_attempt.id IS NULL THEN
        RAISE EXCEPTION 'No existe ese intento de pago.';
    END IF;

    IF v_attempt.player_id NOT IN (
        SELECT id FROM public.players WHERE auth_user_id = auth.uid()
    )
       AND NOT public.is_superadmin(auth.uid()) THEN
        RAISE EXCEPTION 'No puedes procesar el resultado del intento de otro jugador.';
    END IF;

    IF v_attempt.resultado IS NOT NULL THEN
        RAISE EXCEPTION 'Este intento ya fue procesado anteriormente.';
    END IF;

    -- Para pago de equipo, revalidar TODO antes de aceptar el resultado.
    IF p_aprobado
       AND v_attempt.concepto = 'inscripcion_equipo'::public.concepto_pago THEN

        IF v_attempt.tournament_team_id IS NULL THEN
            RAISE EXCEPTION 'El intento de pago de equipo no tiene equipo asociado.';
        END IF;

        PERFORM pg_advisory_xact_lock(
            hashtextextended(v_attempt.tournament_team_id::text, 200)
        );

        v_validation :=
            public._validar_equipo_pago_completo_200(
                v_attempt.tournament_team_id,
                v_attempt.player_id
            );

        IF v_attempt.tournament_id IS DISTINCT FROM
           (v_validation->>'tournamentId')::uuid THEN
            RAISE EXCEPTION 'El torneo del intento de pago no coincide con el equipo.';
        END IF;

        IF v_attempt.monto IS DISTINCT FROM
           (v_validation->>'amount')::numeric THEN
            RAISE EXCEPTION
                'El monto del intento de pago ya no coincide con la tarifa vigente del equipo.';
        END IF;

        IF v_attempt.medio_pago IS NULL THEN
            RAISE EXCEPTION 'El intento de pago no tiene medio de pago.';
        END IF;
    END IF;

    UPDATE public.payment_attempts
       SET resultado       = p_aprobado,
           referencia_pago = p_referencia_pago,
           procesado_at    = now()
     WHERE id = p_attempt_id;

    IF NOT p_aprobado THEN
        RETURN NULL;
    END IF;

    IF v_attempt.concepto = 'inscripcion_individual' THEN
        INSERT INTO public.tournament_registrations (
            tournament_id, player_id, tournament_category_id,
            monto_pagado, fecha_pago, medio_pago, referencia_pago
        )
        VALUES (
            v_attempt.tournament_id, v_attempt.player_id, v_attempt.referencia_id,
            v_attempt.monto, now(), v_attempt.medio_pago,
            coalesce(
                p_referencia_pago,
                'SIMULADO-' || encode(extensions.gen_random_bytes(6), 'hex')
            )
        )
        RETURNING * INTO v_resultado;

        UPDATE public.payment_attempts
           SET tournament_registration_id = v_resultado.id
         WHERE id = p_attempt_id;

        RETURN v_resultado;

    ELSIF v_attempt.concepto = 'confirmar_pre_reserva' THEN
        SELECT *
          INTO v_pre
          FROM public.tournament_pre_reservations
         WHERE id = v_attempt.referencia_id;

        IF v_pre.id IS NULL THEN
            RAISE EXCEPTION 'No existe la pre-reserva referenciada.';
        END IF;

        IF v_pre.player_id <> v_attempt.player_id THEN
            RAISE EXCEPTION 'Esta pre-reserva no pertenece a este jugador.';
        END IF;

        IF v_pre.estatus <> 'pendiente_pago'
           OR v_pre.activo = false THEN
            RAISE EXCEPTION
                'Esta pre-reserva ya no está pendiente de pago (estatus actual: %).',
                v_pre.estatus;
        END IF;

        IF v_pre.tournament_registration_id IS NOT NULL THEN
            RAISE EXCEPTION 'Esta pre-reserva ya fue confirmada anteriormente.';
        END IF;

        PERFORM set_config('app.saltar_validacion_cupo_equipo', 'true', true);

        INSERT INTO public.tournament_registrations (
            tournament_id, player_id, tournament_category_id, tournament_team_id,
            monto_pagado, fecha_pago, medio_pago, referencia_pago
        )
        VALUES (
            v_pre.tournament_id, v_pre.player_id, v_pre.tournament_category_id,
            v_pre.tournament_team_id,
            v_pre.monto, now(), v_attempt.medio_pago,
            coalesce(
                p_referencia_pago,
                'SIMULADO-' || encode(extensions.gen_random_bytes(6), 'hex')
            )
        )
        RETURNING * INTO v_resultado;

        UPDATE public.tournament_pre_reservations
           SET estatus = 'pagado',
               fecha_pago = now(),
               referencia_pago = p_referencia_pago,
               tournament_registration_id = v_resultado.id
         WHERE id = v_pre.id;

        UPDATE public.payment_attempts
           SET tournament_registration_id = v_resultado.id
         WHERE id = p_attempt_id;

        RETURN v_resultado;

    ELSIF v_attempt.concepto = 'inscripcion_equipo'::public.concepto_pago THEN
        v_payment_reference :=
            coalesce(
                p_referencia_pago,
                'EQUIPO-' || encode(extensions.gen_random_bytes(6), 'hex')
            );

        INSERT INTO public.tournament_team_payment_coverages (
            tournament_id,
            tournament_team_id,
            payment_attempt_id,
            payer_player_id,
            amount,
            currency,
            medio_pago,
            referencia_pago,
            status,
            paid_at
        )
        VALUES (
            v_attempt.tournament_id,
            v_attempt.tournament_team_id,
            v_attempt.id,
            v_attempt.player_id,
            v_attempt.monto,
            v_validation->>'currency',
            v_attempt.medio_pago,
            v_payment_reference,
            'paid',
            now()
        )
        RETURNING * INTO v_coverage;

        UPDATE public.tournament_team_roster_slots
           SET payment_coverage_id = v_coverage.id,
               economically_covered_at = v_coverage.paid_at,
               updated_at = now()
         WHERE tournament_team_id = v_attempt.tournament_team_id
           AND status IN ('pending_confirmation','confirmed');

        -- Convertir ahora únicamente a quienes ya confirmaron personalmente.
        -- Los pending_confirmation quedan cubiertos y se convierten al confirmar.
        FOR v_slot IN
            SELECT rs.id
              FROM public.tournament_team_roster_slots rs
             WHERE rs.tournament_team_id = v_attempt.tournament_team_id
               AND rs.status = 'confirmed'
               AND rs.player_id IS NOT NULL
             ORDER BY
                CASE WHEN rs.role = 'captain' THEN 0 ELSE 1 END,
                rs.created_at,
                rs.id
        LOOP
            v_resultado :=
                public._convertir_slot_cubierto_a_inscripcion_200(v_slot.id);

            IF v_resultado.player_id = v_attempt.player_id THEN
                UPDATE public.payment_attempts
                   SET tournament_registration_id = v_resultado.id
                 WHERE id = p_attempt_id;
            END IF;
        END LOOP;

        -- El capitán siempre debe estar confirmado y debe producir una inscripción.
        SELECT tr.*
          INTO v_resultado
          FROM public.tournament_registrations tr
         WHERE tr.team_payment_coverage_id = v_coverage.id
           AND tr.player_id = v_attempt.player_id
           AND tr.activo = true
         LIMIT 1;

        IF v_resultado.id IS NULL THEN
            RAISE EXCEPTION
                'No fue posible crear la inscripción del capitán después del pago del equipo.';
        END IF;

        RETURN v_resultado;

    ELSE
        RAISE EXCEPTION
            'El concepto de pago "%" todavía no está implementado.',
            v_attempt.concepto;
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.procesar_resultado_pago(uuid, boolean, text)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.procesar_resultado_pago(uuid, boolean, text)
TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 9. Consulta resumida de cobertura económica del equipo
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_cobertura_pago_equipo(
    p_team_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_cov public.tournament_team_payment_coverages%ROWTYPE;
    v_team public.tournament_teams%ROWTYPE;
    v_player_id uuid;
BEGIN
    IF NOT public._puede_administrar_roster_equipo_199(p_team_id) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar este pago de equipo.';
    END IF;

    SELECT *
      INTO v_team
      FROM public.tournament_teams
     WHERE id = p_team_id;

    SELECT *
      INTO v_cov
      FROM public.tournament_team_payment_coverages
     WHERE tournament_team_id = p_team_id
       AND status = 'paid'
     LIMIT 1;

    IF v_cov.id IS NULL THEN
        RETURN jsonb_build_object(
            'teamId', p_team_id,
            'paid', false
        );
    END IF;

    RETURN jsonb_build_object(
        'teamId', p_team_id,
        'paid', true,
        'coverageId', v_cov.id,
        'amount', v_cov.amount,
        'currency', v_cov.currency,
        'medioPago', v_cov.medio_pago,
        'reference', v_cov.referencia_pago,
        'paidAt', v_cov.paid_at,
        'coveredSlots', (
            SELECT count(*)
              FROM public.tournament_team_roster_slots rs
             WHERE rs.payment_coverage_id = v_cov.id
        ),
        'registrationsCreated', (
            SELECT count(*)
              FROM public.tournament_registrations tr
             WHERE tr.team_payment_coverage_id = v_cov.id
               AND tr.activo = true
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_cobertura_pago_equipo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.obtener_cobertura_pago_equipo(uuid)
TO authenticated, service_role;

COMMENT ON TABLE public.tournament_team_payment_coverages IS
'Pago económico único de un equipo completo. Evita duplicar el importe en cada integrante y permite cubrir slots pendientes de confirmación.';

COMMENT ON COLUMN public.tournament_registrations.team_payment_coverage_id IS
'Cobertura económica de equipo que financió esta inscripción. El importe total se registra solo en la inscripción del capitán; integrantes cubiertos llevan monto_pagado=0.';

COMMENT ON COLUMN public.tournament_team_roster_slots.payment_coverage_id IS
'Cobertura económica del equipo. Puede existir aunque el invitado todavía no haya confirmado identidad/participación.';

COMMIT;
