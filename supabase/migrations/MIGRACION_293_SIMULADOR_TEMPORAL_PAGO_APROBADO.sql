-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 293
-- Simulador temporal de pago aprobado
--
-- Objetivo:
--   Permitir pruebas end-to-end antes de conectar una pasarela real.
--
-- Diseño:
--   - Sólo Superadmin puede ejecutar la simulación.
--   - Recibe un intento de pago YA EXISTENTE.
--   - No duplica la lógica de negocio.
--   - Invoca finalizar_contratacion_pagada_292(...), que continúa siendo
--     la única responsable de:
--       * aprobar el intento,
--       * marcar la contratación PAGADA,
--       * crear el torneo una sola vez,
--       * asignar tournament_organizer,
--       * activar el torneo.
--
-- Temporal:
--   Esta RPC podrá eliminarse cuando la pasarela/webhook real sustituya
--   la simulación.
-- ============================================================================

begin;

create or replace function public.simular_pago_aprobado_293(
    p_payment_attempt_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_attempt public.platform_contract_payment_attempts%rowtype;
    v_result jsonb;
    v_simulated_reference text;
begin
    if auth.uid() is null then
        raise exception 'Usuario no autenticado.'
            using errcode = '42501';
    end if;

    if not public.is_superadmin(auth.uid()) then
        raise exception
            'Sólo el Superadmin puede simular la aprobación de un pago.'
            using errcode = '42501';
    end if;

    if p_payment_attempt_id is null then
        raise exception 'El intento de pago es obligatorio.'
            using errcode = '22023';
    end if;

    select *
      into v_attempt
      from public.platform_contract_payment_attempts
     where id = p_payment_attempt_id;

    if not found then
        raise exception 'El intento de pago no existe.'
            using errcode = '22023';
    end if;

    if v_attempt.payment_status in ('RECHAZADO','CANCELADO','EXPIRADO','REEMBOLSADO') then
        raise exception
            'No puede simularse aprobación para un intento en estado %.',
            v_attempt.payment_status
            using errcode = '23514';
    end if;

    v_simulated_reference :=
        'SIM-' ||
        to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') ||
        '-' ||
        left(replace(p_payment_attempt_id::text, '-', ''), 8);

    v_result := public.finalizar_contratacion_pagada_292(
        p_payment_attempt_id,
        'SIMULADO-' || p_payment_attempt_id::text,
        v_simulated_reference,
        'SIMULACION',
        null,
        null,
        jsonb_build_object(
            'simulated', true,
            'simulatedByAuthUserId', auth.uid(),
            'simulatedAt', now()
        )
    );

    return jsonb_build_object(
        'ok', true,
        'simulated', true,
        'paymentAttemptId', p_payment_attempt_id,
        'simulationReference', v_simulated_reference,
        'finalization', v_result
    );
end;
$function$;

revoke all on function public.simular_pago_aprobado_293(uuid)
    from public, anon;

grant execute on function public.simular_pago_aprobado_293(uuid)
    to authenticated, service_role;

commit;
