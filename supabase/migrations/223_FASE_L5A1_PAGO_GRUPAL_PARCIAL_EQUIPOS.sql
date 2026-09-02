-- TEE CENTRAL / GOLF IN FULL
-- Migración 223 — Fase L5A1
-- Pago grupal parcial de 1..N plazas en torneos por equipos.
--
-- Objetivo:
-- - conservar intacto el pago individual;
-- - conservar el pago de equipo completo de la migración 200;
-- - permitir múltiples coberturas parciales aprobadas para un mismo equipo;
-- - cubrir únicamente los roster slots seleccionados;
-- - conservar la conversión posterior slot -> tournament_registration;
-- - no exigir que el pagador sea capitán: puede pagar un integrante activo del equipo
--   o un administrador autorizado;
-- - no crear players ficticios.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Extender el modelo de cobertura económica sin reemplazarlo.
-- -----------------------------------------------------------------------------

ALTER TABLE public.tournament_team_payment_coverages
    ADD COLUMN IF NOT EXISTS coverage_type text NOT NULL DEFAULT 'full_team';

ALTER TABLE public.tournament_team_payment_coverages
    DROP CONSTRAINT IF EXISTS tournament_team_payment_coverages_coverage_type_check;

ALTER TABLE public.tournament_team_payment_coverages
    ADD CONSTRAINT tournament_team_payment_coverages_coverage_type_check
    CHECK (coverage_type IN ('full_team', 'partial_slots'));

ALTER TABLE public.tournament_team_roster_slots
    ADD COLUMN IF NOT EXISTS economically_covered_amount numeric;

ALTER TABLE public.tournament_team_roster_slots
    DROP CONSTRAINT IF EXISTS tournament_team_roster_slots_covered_amount_check;

ALTER TABLE public.tournament_team_roster_slots
    ADD CONSTRAINT tournament_team_roster_slots_covered_amount_check
    CHECK (economically_covered_amount IS NULL OR economically_covered_amount >= 0);

-- La migración 200 permitía una sola cobertura pagada por equipo.
-- Ahora sólo la cobertura FULL TEAM conserva unicidad; las parciales pueden ser varias.
DROP INDEX IF EXISTS public.uq_team_payment_coverage_paid_team;

CREATE UNIQUE INDEX IF NOT EXISTS uq_team_payment_coverage_paid_full_team
    ON public.tournament_team_payment_coverages (tournament_team_id)
    WHERE status = 'paid' AND coverage_type = 'full_team';

CREATE INDEX IF NOT EXISTS idx_team_payment_coverages_paid_partial_team
    ON public.tournament_team_payment_coverages (tournament_team_id, paid_at)
    WHERE status = 'paid' AND coverage_type = 'partial_slots';

-- -----------------------------------------------------------------------------
-- 2. Autorización de pago grupal.
--    El pagador NO tiene que ser capitán.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._puede_pagar_equipo_grupal_223(
    p_team_id uuid,
    p_player_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
BEGIN
    SELECT tt.tournament_id
      INTO v_tournament_id
      FROM public.tournament_teams tt
     WHERE tt.id = p_team_id
       AND tt.activo = true;

    IF v_tournament_id IS NULL OR p_player_id IS NULL THEN
        RETURN false;
    END IF;

    -- Conserva administradores/capitán del contrato 199.
    IF public._puede_administrar_roster_equipo_199(p_team_id) THEN
        RETURN true;
    END IF;

    -- Además, cualquier integrante real/activo del equipo puede pagar.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_team_roster_slots rs
         WHERE rs.tournament_team_id = p_team_id
           AND rs.player_id = p_player_id
           AND rs.status IN ('pending_confirmation','confirmed','converted')
    ) THEN
        RETURN true;
    END IF;

    IF EXISTS (
        SELECT 1
          FROM public.tournament_registrations tr
         WHERE tr.tournament_team_id = p_team_id
           AND tr.player_id = p_player_id
           AND tr.activo = true
    ) THEN
        RETURN true;
    END IF;

    RETURN false;
END;
$function$;

-- -----------------------------------------------------------------------------
-- 3. Validador común para pago parcial por slots.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._validar_pago_grupal_slots_223(
    p_team_id uuid,
    p_payer_player_id uuid,
    p_slot_ids uuid[],
    p_ignore_attempt_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_team public.tournament_teams%ROWTYPE;
    v_tournament public.tournaments%ROWTYPE;
    v_participation text;
    v_expected integer;
    v_requested integer;
    v_found integer;
    v_total numeric;
    v_pricing jsonb;
    v_slot record;
BEGIN
    IF p_payer_player_id IS NULL THEN
        RAISE EXCEPTION 'No se pudo identificar al jugador que realizará el pago.';
    END IF;

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

    SELECT tf.tipo_participacion::text
      INTO v_participation
      FROM public.tournament_formats tf
     WHERE tf.id = v_tournament.tournament_format_id;

    IF v_participation IS DISTINCT FROM 'equipo' THEN
        RAISE EXCEPTION 'El pago grupal por plazas sólo aplica a torneos por equipos.';
    END IF;

    IF v_tournament.estatus <> 'inscripciones_abiertas'::public.estatus_torneo THEN
        RAISE EXCEPTION 'Las inscripciones del torneo no están abiertas.';
    END IF;

    IF NOT public._puede_pagar_equipo_grupal_223(p_team_id, p_payer_player_id) THEN
        RAISE EXCEPTION 'No tienes permiso para pagar integrantes de este equipo.'
            USING ERRCODE = '42501';
    END IF;

    v_expected := v_tournament.jugadores_por_equipo;

    IF v_expected IS NULL OR v_expected <= 0 THEN
        RAISE EXCEPTION 'El torneo no tiene configurado el número de jugadores por equipo.';
    END IF;

    IF p_slot_ids IS NULL OR cardinality(p_slot_ids) = 0 THEN
        RAISE EXCEPTION 'Debes seleccionar al menos una plaza para pagar.';
    END IF;

    SELECT count(DISTINCT x)
      INTO v_requested
      FROM unnest(p_slot_ids) AS u(x);

    IF v_requested <> cardinality(p_slot_ids) THEN
        RAISE EXCEPTION 'La selección contiene plazas duplicadas.';
    END IF;

    IF v_requested > v_expected THEN
        RAISE EXCEPTION 'No puedes pagar más plazas que jugadores permitidos por equipo.';
    END IF;

    -- Si ya existe pago de equipo completo aprobado, no puede coexistir uno parcial.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_team_payment_coverages c
         WHERE c.tournament_team_id = p_team_id
           AND c.status = 'paid'
           AND c.coverage_type = 'full_team'
    ) THEN
        RAISE EXCEPTION 'Este equipo ya tiene un pago de equipo completo aprobado.';
    END IF;

    -- Un intento FULL TEAM pendiente también bloquea pagos parciales.
    IF EXISTS (
        SELECT 1
          FROM public.payment_attempts pa
         WHERE pa.tournament_team_id = p_team_id
           AND pa.concepto = 'inscripcion_equipo'::public.concepto_pago
           AND pa.resultado IS NULL
           AND pa.id IS DISTINCT FROM p_ignore_attempt_id
           AND COALESCE(pa.detalle->>'source','') = 'team_full_payment_v200'
    ) THEN
        RAISE EXCEPTION 'Este equipo ya tiene un intento de pago completo pendiente.';
    END IF;

    -- Evitar que un mismo slot quede simultáneamente en dos intentos parciales pendientes.
    IF EXISTS (
        SELECT 1
          FROM public.payment_attempts pa
          CROSS JOIN LATERAL jsonb_array_elements(COALESCE(pa.detalle->'slots','[]'::jsonb)) e
         WHERE pa.tournament_team_id = p_team_id
           AND pa.concepto = 'inscripcion_equipo'::public.concepto_pago
           AND pa.resultado IS NULL
           AND pa.id IS DISTINCT FROM p_ignore_attempt_id
           AND COALESCE(pa.detalle->>'source','') = 'team_partial_slots_v223'
           AND NULLIF(e->>'slotId','')::uuid = ANY(p_slot_ids)
    ) THEN
        RAISE EXCEPTION 'Una de las plazas seleccionadas ya participa en otro intento de pago pendiente.';
    END IF;

    SELECT count(*)
      INTO v_found
      FROM public.tournament_team_roster_slots rs
     WHERE rs.id = ANY(p_slot_ids)
       AND rs.tournament_team_id = p_team_id
       AND rs.tournament_id = v_team.tournament_id
       AND rs.status IN ('pending_confirmation','confirmed')
       AND rs.tournament_registration_id IS NULL
       AND rs.payment_coverage_id IS NULL;

    IF v_found <> v_requested THEN
        RAISE EXCEPTION 'Una o más plazas ya no están disponibles para pago grupal.';
    END IF;

    -- Revalidar conflictos formales y monto individual por cada plaza.
    FOR v_slot IN
        SELECT rs.id, rs.player_id, rs.email
          FROM public.tournament_team_roster_slots rs
         WHERE rs.id = ANY(p_slot_ids)
         ORDER BY rs.id
    LOOP
        IF v_slot.player_id IS NOT NULL
           AND EXISTS (
               SELECT 1
                 FROM public.tournament_registrations tr
                WHERE tr.tournament_id = v_team.tournament_id
                  AND tr.player_id = v_slot.player_id
                  AND tr.activo = true
           ) THEN
            RAISE EXCEPTION 'Uno de los jugadores seleccionados ya está inscrito en este torneo.';
        END IF;

        IF v_slot.player_id IS NOT NULL
           AND EXISTS (
               SELECT 1
                 FROM public.tournament_pre_reservations pr
                WHERE pr.tournament_id = v_team.tournament_id
                  AND pr.player_id = v_slot.player_id
                  AND pr.activo = true
                  AND pr.tournament_registration_id IS NULL
           ) THEN
            RAISE EXCEPTION 'Uno de los jugadores seleccionados ya tiene una pre-reserva activa.';
        END IF;

        IF EXISTS (
            SELECT 1
              FROM public.phone_reservations ph
             WHERE ph.tournament_id = v_team.tournament_id
               AND ph.activo = true
               AND lower(ph.correo::text) = lower(v_slot.email::text)
        ) THEN
            RAISE EXCEPTION 'Uno de los jugadores seleccionados ya tiene una reserva telefónica activa.';
        END IF;
    END LOOP;

    SELECT
        jsonb_agg(
            jsonb_build_object(
                'slotId', rs.id,
                'playerId', rs.player_id,
                'amount', public.tarifa_vigente_torneo(v_team.tournament_id, rs.player_id)
            )
            ORDER BY rs.id
        ),
        sum(public.tarifa_vigente_torneo(v_team.tournament_id, rs.player_id))
      INTO v_pricing, v_total
      FROM public.tournament_team_roster_slots rs
     WHERE rs.id = ANY(p_slot_ids);

    IF v_total IS NULL OR v_total <= 0 THEN
        RAISE EXCEPTION 'No fue posible determinar una tarifa válida para las plazas seleccionadas.';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM public.tournament_team_roster_slots rs
         WHERE rs.id = ANY(p_slot_ids)
           AND COALESCE(public.tarifa_vigente_torneo(v_team.tournament_id, rs.player_id), 0) <= 0
    ) THEN
        RAISE EXCEPTION 'Una de las plazas seleccionadas no tiene una tarifa vigente válida.';
    END IF;

    RETURN jsonb_build_object(
        'valid', true,
        'tournamentId', v_team.tournament_id,
        'teamId', p_team_id,
        'payerPlayerId', p_payer_player_id,
        'expectedPlayers', v_expected,
        'selectedSlots', v_requested,
        'amount', v_total,
        'currency', v_tournament.moneda,
        'slots', v_pricing
    );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 4. Preparar intento de pago parcial 1..N.
--    Reutiliza concepto_pago = inscripcion_equipo; el subtipo vive en detalle.source.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.preparar_pago_grupal_equipo(
    p_team_id uuid,
    p_slot_ids uuid[],
    p_medio_pago public.medio_pago_torneo
)
RETURNS public.payment_attempts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_player_id uuid;
    v_validation jsonb;
    v_attempt public.payment_attempts;
BEGIN
    v_player_id := public._current_player_id_199();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión como jugador.';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(p_team_id::text, 223));

    v_validation := public._validar_pago_grupal_slots_223(
        p_team_id,
        v_player_id,
        p_slot_ids,
        NULL
    );

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
            'source', 'team_partial_slots_v223',
            'selectedSlots', (v_validation->>'selectedSlots')::integer,
            'expectedPlayers', (v_validation->>'expectedPlayers')::integer,
            'currency', v_validation->>'currency',
            'slots', v_validation->'slots'
        )
    )
    RETURNING * INTO v_attempt;

    RETURN v_attempt;
END;
$function$;

-- -----------------------------------------------------------------------------
-- 5. Generalizar la conversión slot -> inscripción.
--    FULL TEAM conserva semántica 200; PARTIAL SLOTS usa el monto propio del slot.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._convertir_slot_cubierto_a_inscripcion_200(p_slot_id uuid)
RETURNS public.tournament_registrations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
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

    IF v_cov.coverage_type = 'partial_slots' THEN
        IF v_slot.economically_covered_amount IS NULL THEN
            RAISE EXCEPTION 'La plaza cubierta parcialmente no tiene monto económico asignado.';
        END IF;
        v_amount := v_slot.economically_covered_amount;
    ELSE
        -- Compatibilidad exacta con migración 200:
        -- el total del equipo completo se refleja únicamente en la inscripción del capitán.
        IF v_slot.player_id = v_team.captain_player_id THEN
            v_amount := v_cov.amount;
        END IF;
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
$function$;

-- -----------------------------------------------------------------------------
-- 6. Procesar resultado del pago parcial.
--    Se mantiene separado de procesar_resultado_pago() para no alterar aún el
--    flujo común de pagos ni Stripe/checkout antes de la fase de integración.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.procesar_resultado_pago_grupal_equipo(
    p_attempt_id uuid,
    p_aprobado boolean,
    p_referencia_pago text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_attempt public.payment_attempts%ROWTYPE;
    v_validation jsonb;
    v_coverage public.tournament_team_payment_coverages%ROWTYPE;
    v_slot_json jsonb;
    v_slot_id uuid;
    v_slot_amount numeric;
    v_reg public.tournament_registrations;
    v_reg_count integer := 0;
    v_reference text;
    v_current_player_id uuid;
BEGIN
    SELECT *
      INTO v_attempt
      FROM public.payment_attempts
     WHERE id = p_attempt_id
     FOR UPDATE;

    IF v_attempt.id IS NULL THEN
        RAISE EXCEPTION 'No existe ese intento de pago.';
    END IF;

    IF v_attempt.concepto <> 'inscripcion_equipo'::public.concepto_pago
       OR COALESCE(v_attempt.detalle->>'source','') <> 'team_partial_slots_v223' THEN
        RAISE EXCEPTION 'El intento indicado no corresponde a un pago grupal parcial.';
    END IF;

    v_current_player_id := public._current_player_id_199();

    IF v_attempt.player_id IS DISTINCT FROM v_current_player_id
       AND NOT public.is_superadmin(auth.uid()) THEN
        RAISE EXCEPTION 'No puedes procesar el resultado del intento de otro jugador.'
            USING ERRCODE = '42501';
    END IF;

    IF v_attempt.resultado IS NOT NULL THEN
        RAISE EXCEPTION 'Este intento ya fue procesado anteriormente.';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(v_attempt.tournament_team_id::text, 223)
    );

    IF NOT p_aprobado THEN
        UPDATE public.payment_attempts
           SET resultado = false,
               referencia_pago = p_referencia_pago,
               procesado_at = now()
         WHERE id = v_attempt.id;

        RETURN jsonb_build_object(
            'attemptId', v_attempt.id,
            'approved', false,
            'teamId', v_attempt.tournament_team_id
        );
    END IF;

    v_validation := public._validar_pago_grupal_slots_223(
        v_attempt.tournament_team_id,
        v_attempt.player_id,
        ARRAY(
            SELECT (e->>'slotId')::uuid
              FROM jsonb_array_elements(COALESCE(v_attempt.detalle->'slots','[]'::jsonb)) e
        ),
        v_attempt.id
    );

    IF v_attempt.tournament_id IS DISTINCT FROM (v_validation->>'tournamentId')::uuid THEN
        RAISE EXCEPTION 'El torneo del intento no coincide con el equipo.';
    END IF;

    IF v_attempt.monto IS DISTINCT FROM (v_validation->>'amount')::numeric THEN
        RAISE EXCEPTION 'El monto del intento ya no coincide con las tarifas vigentes de las plazas seleccionadas.';
    END IF;

    IF COALESCE(v_attempt.detalle->'slots','[]'::jsonb)
       IS DISTINCT FROM COALESCE(v_validation->'slots','[]'::jsonb) THEN
        RAISE EXCEPTION 'La composición o tarifa de las plazas cambió desde que se preparó el pago.';
    END IF;

    IF v_attempt.medio_pago IS NULL THEN
        RAISE EXCEPTION 'El intento de pago no tiene medio de pago.';
    END IF;

    UPDATE public.payment_attempts
       SET resultado = true,
           referencia_pago = p_referencia_pago,
           procesado_at = now()
     WHERE id = v_attempt.id;

    v_reference := COALESCE(
        p_referencia_pago,
        'GRUPO-' || encode(extensions.gen_random_bytes(6), 'hex')
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
        paid_at,
        coverage_type
    )
    VALUES (
        v_attempt.tournament_id,
        v_attempt.tournament_team_id,
        v_attempt.id,
        v_attempt.player_id,
        v_attempt.monto,
        v_validation->>'currency',
        v_attempt.medio_pago,
        v_reference,
        'paid',
        now(),
        'partial_slots'
    )
    RETURNING * INTO v_coverage;

    FOR v_slot_json IN
        SELECT e
          FROM jsonb_array_elements(v_attempt.detalle->'slots') e
    LOOP
        v_slot_id := (v_slot_json->>'slotId')::uuid;
        v_slot_amount := (v_slot_json->>'amount')::numeric;

        UPDATE public.tournament_team_roster_slots
           SET payment_coverage_id = v_coverage.id,
               economically_covered_at = v_coverage.paid_at,
               economically_covered_amount = v_slot_amount,
               updated_at = now()
         WHERE id = v_slot_id
           AND tournament_team_id = v_attempt.tournament_team_id
           AND status IN ('pending_confirmation','confirmed')
           AND tournament_registration_id IS NULL
           AND payment_coverage_id IS NULL;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Una de las plazas dejó de estar disponible mientras se procesaba el pago.';
        END IF;

        SELECT *
          INTO v_reg
          FROM public._convertir_slot_cubierto_a_inscripcion_200(v_slot_id);

        IF v_reg.id IS NOT NULL THEN
            v_reg_count := v_reg_count + 1;
        END IF;
    END LOOP;

    -- Si el pagador quedó convertido en esta cobertura, conservar el enlace útil
    -- del intento sin imponer que el pagador sea capitán ni uno de los seleccionados.
    UPDATE public.payment_attempts pa
       SET tournament_registration_id = tr.id
      FROM public.tournament_registrations tr
     WHERE pa.id = v_attempt.id
       AND tr.team_payment_coverage_id = v_coverage.id
       AND tr.player_id = v_attempt.player_id
       AND tr.activo = true;

    RETURN jsonb_build_object(
        'attemptId', v_attempt.id,
        'approved', true,
        'teamId', v_attempt.tournament_team_id,
        'coverageId', v_coverage.id,
        'coverageType', 'partial_slots',
        'amount', v_coverage.amount,
        'coveredSlots', (v_validation->>'selectedSlots')::integer,
        'registrationsCreated', v_reg_count,
        'pendingConfirmations',
            (v_validation->>'selectedSlots')::integer - v_reg_count
    );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 7. Mantener obtener_cobertura_pago_equipo() como contrato FULL TEAM de la 200.
--    Las coberturas parciales se consultan por un RPC nuevo.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_cobertura_pago_equipo(p_team_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cov public.tournament_team_payment_coverages%ROWTYPE;
BEGIN
    IF NOT public._puede_administrar_roster_equipo_199(p_team_id) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar este pago de equipo.';
    END IF;

    SELECT *
      INTO v_cov
      FROM public.tournament_team_payment_coverages
     WHERE tournament_team_id = p_team_id
       AND status = 'paid'
       AND coverage_type = 'full_team'
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
$function$;

CREATE OR REPLACE FUNCTION public.obtener_coberturas_pago_grupal_equipo(p_team_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_player_id uuid;
BEGIN
    v_player_id := public._current_player_id_199();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión como jugador.';
    END IF;

    IF NOT public._puede_pagar_equipo_grupal_223(p_team_id, v_player_id) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar los pagos grupales de este equipo.'
            USING ERRCODE = '42501';
    END IF;

    RETURN jsonb_build_object(
        'teamId', p_team_id,
        'coverages', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'coverageId', c.id,
                    'coverageType', c.coverage_type,
                    'payerPlayerId', c.payer_player_id,
                    'amount', c.amount,
                    'currency', c.currency,
                    'medioPago', c.medio_pago,
                    'reference', c.referencia_pago,
                    'paidAt', c.paid_at,
                    'coveredSlots', (
                        SELECT count(*)
                          FROM public.tournament_team_roster_slots rs
                         WHERE rs.payment_coverage_id = c.id
                    ),
                    'registrationsCreated', (
                        SELECT count(*)
                          FROM public.tournament_registrations tr
                         WHERE tr.team_payment_coverage_id = c.id
                           AND tr.activo = true
                    )
                )
                ORDER BY c.paid_at, c.id
            )
              FROM public.tournament_team_payment_coverages c
             WHERE c.tournament_team_id = p_team_id
               AND c.status = 'paid'
               AND c.coverage_type = 'partial_slots'
        ), '[]'::jsonb),
        'slots', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'slotId', rs.id,
                    'status', rs.status,
                    'playerId', rs.player_id,
                    'email', rs.email,
                    'economicallyCovered', rs.payment_coverage_id IS NOT NULL,
                    'paymentCoverageId', rs.payment_coverage_id,
                    'coveredAmount', rs.economically_covered_amount,
                    'registrationId', rs.tournament_registration_id
                )
                ORDER BY rs.created_at, rs.id
            )
              FROM public.tournament_team_roster_slots rs
             WHERE rs.tournament_team_id = p_team_id
               AND rs.status IN ('pending_confirmation','confirmed','converted')
        ), '[]'::jsonb)
    );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 8. Permisos RPC. Helpers internos no se exponen a authenticated.
-- -----------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public._puede_pagar_equipo_grupal_223(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._validar_pago_grupal_slots_223(uuid, uuid, uuid[], uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.preparar_pago_grupal_equipo(uuid, uuid[], public.medio_pago_torneo) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.procesar_resultado_pago_grupal_equipo(uuid, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_coberturas_pago_grupal_equipo(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.preparar_pago_grupal_equipo(uuid, uuid[], public.medio_pago_torneo) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.procesar_resultado_pago_grupal_equipo(uuid, boolean, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.obtener_coberturas_pago_grupal_equipo(uuid) TO authenticated, service_role;

COMMIT;
