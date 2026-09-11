-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 293
-- Simulador temporal de resultado de pago de plataforma
--
-- Objetivo:
--   Permitir pruebas end-to-end antes de conectar una pasarela real,
--   siguiendo el mismo patrón ya usado en pagos de jugadores:
--       aprobado = true  -> pago APROBADO y finalización automática
--       aprobado = false -> pago RECHAZADO y sin creación de torneo
--
-- Seguridad:
--   - Puede invocarla un usuario autenticado.
--   - El organizador sólo puede simular intentos asociados a SUS contratos.
--   - El Superadmin también puede usarla.
--   - No permite modificar monto ni moneda.
--
-- Temporal:
--   Esta RPC podrá eliminarse cuando la pasarela/webhook real sustituya
--   la simulación.
-- ============================================================================

begin;

create or replace function public.simular_resultado_pago_plataforma_293(
    p_payment_attempt_id uuid,
    p_aprobado boolean,
    p_referencia_simulada text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_attempt public.platform_contract_payment_attempts%rowtype;
    v_contract public.platform_tournament_contracts%rowtype;
    v_admin_user_id uuid;
    v_reference text;
    v_result jsonb;
begin
    if auth.uid() is null then
        raise exception 'Usuario no autenticado.'
            using errcode = '42501';
    end if;

    if p_payment_attempt_id is null then
        raise exception 'El intento de pago es obligatorio.'
            using errcode = '22023';
    end if;

    if p_aprobado is null then
        raise exception 'Debe indicar si el pago fue aprobado o rechazado.'
            using errcode = '22023';
    end if;

    select au.id
      into v_admin_user_id
      from public.admin_users au
     where au.auth_user_id = auth.uid()
       and au.activo = true
     limit 1;

    if v_admin_user_id is null and not public.is_superadmin(auth.uid()) then
        raise exception 'No se encontró un usuario administrativo activo.'
            using errcode = '42501';
    end if;

    select *
      into v_attempt
      from public.platform_contract_payment_attempts
     where id = p_payment_attempt_id
     for update;

    if not found then
        raise exception 'El intento de pago no existe.'
            using errcode = '22023';
    end if;

    select *
      into v_contract
      from public.platform_tournament_contracts
     where id = v_attempt.contract_id
     for update;

    if not found then
        raise exception 'La contratación asociada no existe.'
            using errcode = '22023';
    end if;

    if not public.is_superadmin(auth.uid())
       and v_contract.organizer_admin_user_id <> v_admin_user_id
    then
        raise exception 'No está autorizado para simular este pago.'
            using errcode = '42501';
    end if;

    if v_attempt.payment_status in ('CANCELADO','EXPIRADO','REEMBOLSADO') then
        raise exception
            'No puede simularse resultado para un intento en estado %.',
            v_attempt.payment_status
            using errcode = '23514';
    end if;

    v_reference := coalesce(
        nullif(btrim(p_referencia_simulada), ''),
        'SIM-' ||
        to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') ||
        '-' ||
        left(replace(p_payment_attempt_id::text, '-', ''), 8)
    );

    if p_aprobado then
        v_result := public.finalizar_contratacion_pagada_292(
            p_payment_attempt_id,
            'SIMULADO-' || p_payment_attempt_id::text,
            v_reference,
            'SIMULACION',
            null,
            v_contract.organizer_email,
            jsonb_build_object(
                'simulated', true,
                'approved', true,
                'simulatedByAuthUserId', auth.uid(),
                'simulatedAt', now()
            )
        );

        return jsonb_build_object(
            'ok', true,
            'simulated', true,
            'approved', true,
            'paymentAttemptId', p_payment_attempt_id,
            'simulationReference', v_reference,
            'finalization', v_result
        );
    end if;

    if v_contract.contract_status <> 'PENDIENTE_PAGO' then
        raise exception
            'No puede rechazarse un pago de una contratación en estado %.',
            v_contract.contract_status
            using errcode = '23514';
    end if;

    update public.platform_contract_payment_attempts
       set payment_status = 'RECHAZADO',
           payment_reference = v_reference,
           payment_method = coalesce(payment_method, 'SIMULACION'),
           payer_email = coalesce(payer_email, v_contract.organizer_email),
           provider_detail = coalesce(provider_detail, '{}'::jsonb)
               || jsonb_build_object(
                    'simulated', true,
                    'approved', false,
                    'simulatedByAuthUserId', auth.uid(),
                    'simulatedAt', now()
                  ),
           processed_at = coalesce(processed_at, now())
     where id = p_payment_attempt_id;

    return jsonb_build_object(
        'ok', true,
        'simulated', true,
        'approved', false,
        'paymentAttemptId', p_payment_attempt_id,
        'simulationReference', v_reference,
        'paymentStatus', 'RECHAZADO',
        'contractStatus', v_contract.contract_status,
        'tournamentCreated', false
    );
end;
$function$;

revoke all on function public.simular_resultado_pago_plataforma_293(
    uuid, boolean, text
) from public, anon;

grant execute on function public.simular_resultado_pago_plataforma_293(
    uuid, boolean, text
) to authenticated, service_role;

commit;
