-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 292
-- FASE 6 CONTRATACION DE PLATAFORMA
-- Finalizacion automatica post-pago
--
-- Alcance:
--   - Confirmar un intento de pago como APROBADO desde backend/service_role.
--   - Marcar la contratacion como PAGADO.
--   - Crear una sola vez el torneo real.
--   - Crear la autorizacion tournament_organizer para el organizador.
--   - Vincular la contratacion al torneo.
--   - Dejar el torneo activo sin liberacion manual del Superadmin.
--
-- Fuera de alcance:
--   - Integracion especifica con Stripe/webhooks.
--   - Perfil fiscal del contratante.
--   - Notificaciones por correo.
--   - Licencia/vencimiento posterior.
--
-- Seguridad:
--   - La RPC queda concedida exclusivamente a service_role.
--   - Es idempotente: si el contrato ya tiene torneo, devuelve el existente.
-- ============================================================================

begin;

create or replace function public.finalizar_contratacion_pagada_292(
    p_payment_attempt_id uuid,
    p_provider_payment_id text default null,
    p_payment_reference text default null,
    p_payment_method text default null,
    p_payer_name text default null,
    p_payer_email text default null,
    p_provider_detail jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_attempt public.platform_contract_payment_attempts%rowtype;
    v_contract public.platform_tournament_contracts%rowtype;
    v_role_id uuid;
    v_tournament_id uuid;
    v_assignment_id uuid;
begin
    if p_payment_attempt_id is null then
        raise exception 'El intento de pago es obligatorio.'
            using errcode = '22023';
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
        raise exception 'La contratacion asociada no existe.'
            using errcode = '22023';
    end if;

    if v_attempt.amount <> v_contract.total_amount
       or v_attempt.currency <> v_contract.currency
    then
        raise exception
            'El intento de pago no coincide con el monto/moneda congelados en la contratacion.'
            using errcode = '23514';
    end if;

    -- Idempotencia: si ya existe torneo, no crear otro.
    if v_contract.tournament_id is not null then
        update public.platform_contract_payment_attempts
           set payment_status = 'APROBADO',
               provider_payment_id = coalesce(
                   nullif(btrim(p_provider_payment_id), ''),
                   provider_payment_id
               ),
               payment_reference = coalesce(
                   nullif(btrim(p_payment_reference), ''),
                   payment_reference
               ),
               payment_method = coalesce(
                   nullif(btrim(p_payment_method), ''),
                   payment_method
               ),
               payer_name = coalesce(
                   nullif(btrim(p_payer_name), ''),
                   payer_name
               ),
               payer_email = coalesce(
                   case
                       when nullif(btrim(p_payer_email), '') is null then null
                       else lower(btrim(p_payer_email))
                   end,
                   payer_email
               ),
               provider_detail = coalesce(p_provider_detail, provider_detail),
               processed_at = coalesce(processed_at, now())
         where id = v_attempt.id;

        if v_contract.contract_status <> 'PAGADO' then
            update public.platform_tournament_contracts
               set contract_status = 'PAGADO'
             where id = v_contract.id;
        end if;

        return jsonb_build_object(
            'ok', true,
            'alreadyFinalized', true,
            'contractId', v_contract.id,
            'paymentAttemptId', v_attempt.id,
            'tournamentId', v_contract.tournament_id
        );
    end if;

    if v_contract.contract_status <> 'PENDIENTE_PAGO' then
        raise exception
            'La contratacion no esta en estado PENDIENTE_PAGO. Estado actual: %.',
            v_contract.contract_status
            using errcode = '23514';
    end if;

    select r.id
      into v_role_id
      from public.roles r
     where r.codigo = 'tournament_organizer'
       and r.activo = true
     limit 1;

    if v_role_id is null then
        raise exception 'No existe el rol activo tournament_organizer.'
            using errcode = 'P0001';
    end if;

    insert into public.tournaments (
        nombre,
        fecha_inicio,
        fecha_fin,
        estatus,
        estado_servicio,
        activo,
        created_by
    )
    values (
        v_contract.proposed_tournament_name,
        v_contract.proposed_start_date,
        v_contract.proposed_end_date,
        'planificado'::public.estatus_torneo,
        'activo'::public.estado_servicio_torneo,
        true,
        v_contract.organizer_admin_user_id
    )
    returning id into v_tournament_id;

    select ara.id
      into v_assignment_id
      from public.admin_role_assignments ara
     where ara.admin_user_id = v_contract.organizer_admin_user_id
       and ara.role_id = v_role_id
       and ara.tournament_id = v_tournament_id
       and ara.activo = true
     limit 1;

    if v_assignment_id is null then
        insert into public.admin_role_assignments (
            admin_user_id,
            role_id,
            club_id,
            tournament_id,
            created_by,
            activo
        )
        values (
            v_contract.organizer_admin_user_id,
            v_role_id,
            null,
            v_tournament_id,
            v_contract.organizer_admin_user_id,
            true
        )
        returning id into v_assignment_id;
    end if;

    update public.platform_contract_payment_attempts
       set payment_status = 'APROBADO',
           provider_payment_id = coalesce(
               nullif(btrim(p_provider_payment_id), ''),
               provider_payment_id
           ),
           payment_reference = coalesce(
               nullif(btrim(p_payment_reference), ''),
               payment_reference
           ),
           payment_method = coalesce(
               nullif(btrim(p_payment_method), ''),
               payment_method
           ),
           payer_name = coalesce(
               nullif(btrim(p_payer_name), ''),
               payer_name
           ),
           payer_email = coalesce(
               case
                   when nullif(btrim(p_payer_email), '') is null then null
                   else lower(btrim(p_payer_email))
               end,
               payer_email
           ),
           provider_detail = coalesce(p_provider_detail, provider_detail),
           processed_at = coalesce(processed_at, now())
     where id = v_attempt.id;

    update public.platform_tournament_contracts
       set contract_status = 'PAGADO',
           tournament_id = v_tournament_id
     where id = v_contract.id;

    return jsonb_build_object(
        'ok', true,
        'alreadyFinalized', false,
        'contractId', v_contract.id,
        'paymentAttemptId', v_attempt.id,
        'tournamentId', v_tournament_id,
        'assignmentId', v_assignment_id,
        'estadoServicio', 'activo',
        'activo', true
    );
end;
$function$;

revoke all on function public.finalizar_contratacion_pagada_292(
    uuid,text,text,text,text,text,jsonb
) from public, anon, authenticated;

grant execute on function public.finalizar_contratacion_pagada_292(
    uuid,text,text,text,text,text,jsonb
) to service_role;

commit;
