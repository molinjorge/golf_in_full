-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 382
-- CORRECCIÓN DE TOTAL_A_PAGAR Y ESTADO_PAGO EN PAGO SIMULADO
--
-- OBJETIVO
-- Corregir procesar_resultado_pago() para que las inscripciones materializadas
-- por un pago aprobado conserven explícitamente su obligación económica:
--   total_a_pagar = importe aprobado
--   estado_pago    = 'PAGADO'
--
-- ALCANCE
-- 1) inscripcion_individual
-- 2) confirmar_pre_reserva
--
-- NO hace backfill ni modifica inscripciones históricas.
-- NO altera pagos administrativos, anulaciones, reportes ni pagos de equipo.

BEGIN;

CREATE OR REPLACE FUNCTION public.procesar_resultado_pago(
    p_attempt_id uuid,
    p_aprobado boolean,
    p_referencia_pago text DEFAULT NULL::text
)
RETURNS public.tournament_registrations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
            tournament_id,
            player_id,
            tournament_category_id,
            total_a_pagar,
            monto_pagado,
            fecha_pago,
            medio_pago,
            referencia_pago,
            estado_pago
        )
        VALUES (
            v_attempt.tournament_id,
            v_attempt.player_id,
            v_attempt.referencia_id,
            v_attempt.monto,
            v_attempt.monto,
            now(),
            v_attempt.medio_pago,
            coalesce(
                p_referencia_pago,
                'SIMULADO-' || encode(extensions.gen_random_bytes(6), 'hex')
            ),
            'PAGADO'
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

        IF v_pre.monto IS NULL OR v_pre.monto < 0 THEN
            RAISE EXCEPTION 'La pre-reserva no tiene un monto válido.';
        END IF;

        IF v_attempt.monto IS DISTINCT FROM v_pre.monto THEN
            RAISE EXCEPTION
                'El monto del intento de pago ya no coincide con el monto de la pre-reserva.';
        END IF;

        PERFORM set_config('app.saltar_validacion_cupo_equipo', 'true', true);

        INSERT INTO public.tournament_registrations (
            tournament_id,
            player_id,
            tournament_category_id,
            tournament_team_id,
            total_a_pagar,
            monto_pagado,
            fecha_pago,
            medio_pago,
            referencia_pago,
            estado_pago
        )
        VALUES (
            v_pre.tournament_id,
            v_pre.player_id,
            v_pre.tournament_category_id,
            v_pre.tournament_team_id,
            v_pre.monto,
            v_pre.monto,
            now(),
            v_attempt.medio_pago,
            coalesce(
                p_referencia_pago,
                'SIMULADO-' || encode(extensions.gen_random_bytes(6), 'hex')
            ),
            'PAGADO'
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
$function$;

COMMENT ON FUNCTION public.procesar_resultado_pago(uuid, boolean, text) IS
'382: conserva total_a_pagar y estado PAGADO al materializar inscripciones desde pagos aprobados; valida monto de pre-reserva antes de convertirla.';

COMMIT;
