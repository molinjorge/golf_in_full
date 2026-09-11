-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 291
-- FASE 5 CONTRATACION DE PLATAFORMA
-- Intentos de pago de contrataciones de plataforma
--
-- Alcance:
--   - Crear intentos de pago separados de payment_attempts de jugadores.
--   - Vincular cada intento a platform_tournament_contracts.
--   - Copiar monto y moneda desde el snapshot de la contratacion.
--   - Permitir multiples intentos por contratacion.
--   - Registrar proveedor, referencias, pagador, metodo y resultado.
--
-- Fuera de alcance:
--   - Integracion concreta con Stripe.
--   - Webhooks.
--   - Confirmacion automatica del contrato como PAGADO.
--   - Creacion automatica del torneo.
-- ============================================================================

begin;

create table if not exists public.platform_contract_payment_attempts (
    id uuid primary key default gen_random_uuid(),

    contract_id uuid not null
        references public.platform_tournament_contracts(id),

    amount numeric(12,2) not null,
    currency text not null,

    payment_provider text null,
    payment_method text null,

    provider_session_id text null,
    provider_payment_id text null,
    payment_reference text null,

    payer_name text null,
    payer_email text null,

    payment_status text not null default 'INICIADO',

    provider_detail jsonb null,

    initiated_at timestamptz not null default now(),
    processed_at timestamptz null,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint platform_contract_payment_attempts_amount_chk
        check (amount >= 0),

    constraint platform_contract_payment_attempts_currency_chk
        check (currency ~ '^[A-Z]{3}$'),

    constraint platform_contract_payment_attempts_status_chk
        check (
            payment_status in (
                'INICIADO',
                'PENDIENTE',
                'APROBADO',
                'RECHAZADO',
                'CANCELADO',
                'EXPIRADO',
                'REEMBOLSADO'
            )
        ),

    constraint platform_contract_payment_attempts_payer_email_chk
        check (
            payer_email is null
            or (
                nullif(btrim(payer_email), '') is not null
                and position('@' in payer_email) > 1
            )
        )
);

comment on table public.platform_contract_payment_attempts is
'Intentos de pago de contrataciones de uso de plataforma. Separados del flujo de pagos de jugadores.';

comment on column public.platform_contract_payment_attempts.amount is
'Monto copiado del total congelado de la contratacion; no debe ser proporcionado por el frontend.';

comment on column public.platform_contract_payment_attempts.payment_status is
'Estado del intento de pago; una contratacion puede tener multiples intentos.';

create index if not exists platform_contract_payment_attempts_contract_idx
    on public.platform_contract_payment_attempts (
        contract_id,
        created_at desc
    );

create index if not exists platform_contract_payment_attempts_status_idx
    on public.platform_contract_payment_attempts (
        payment_status,
        created_at desc
    );

create unique index if not exists platform_contract_payment_attempts_provider_session_uq
    on public.platform_contract_payment_attempts (
        payment_provider,
        provider_session_id
    )
    where payment_provider is not null
      and provider_session_id is not null;

create unique index if not exists platform_contract_payment_attempts_provider_payment_uq
    on public.platform_contract_payment_attempts (
        payment_provider,
        provider_payment_id
    )
    where payment_provider is not null
      and provider_payment_id is not null;

drop trigger if exists trg_platform_contract_payment_attempts_updated_at
    on public.platform_contract_payment_attempts;

create trigger trg_platform_contract_payment_attempts_updated_at
before update on public.platform_contract_payment_attempts
for each row
execute function public.set_updated_at();

alter table public.platform_contract_payment_attempts enable row level security;

drop policy if exists platform_contract_payment_attempts_select_owner_or_superadmin
    on public.platform_contract_payment_attempts;

create policy platform_contract_payment_attempts_select_owner_or_superadmin
on public.platform_contract_payment_attempts
for select
to authenticated
using (
    public.is_superadmin(auth.uid())
    or exists (
        select 1
        from public.platform_tournament_contracts c
        join public.admin_users au
          on au.id = c.organizer_admin_user_id
        where c.id = contract_id
          and au.auth_user_id = auth.uid()
          and au.activo = true
    )
);

drop policy if exists platform_contract_payment_attempts_write_superadmin
    on public.platform_contract_payment_attempts;

create policy platform_contract_payment_attempts_write_superadmin
on public.platform_contract_payment_attempts
for all
to authenticated
using (public.is_superadmin(auth.uid()))
with check (public.is_superadmin(auth.uid()));

revoke all on table public.platform_contract_payment_attempts from anon;
revoke insert, update, delete on table public.platform_contract_payment_attempts from authenticated;
grant select on table public.platform_contract_payment_attempts to authenticated;
grant all on table public.platform_contract_payment_attempts to service_role;

create or replace function public.iniciar_intento_pago_contratacion_291(
    p_contract_id uuid,
    p_payment_provider text default null,
    p_payer_name text default null,
    p_payer_email text default null
)
returns public.platform_contract_payment_attempts
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_auth_user_id uuid := auth.uid();
    v_contract public.platform_tournament_contracts%rowtype;
    v_admin_user public.admin_users%rowtype;
    v_attempt public.platform_contract_payment_attempts%rowtype;
begin
    if v_auth_user_id is null then
        raise exception 'Usuario no autenticado.'
            using errcode = '42501';
    end if;

    select au.*
      into v_admin_user
      from public.admin_users au
     where au.auth_user_id = v_auth_user_id
       and au.activo = true
     limit 1;

    if not found then
        raise exception 'No existe un perfil administrativo activo vinculado al usuario.'
            using errcode = '42501';
    end if;

    select c.*
      into v_contract
      from public.platform_tournament_contracts c
     where c.id = p_contract_id
       and (
            c.organizer_admin_user_id = v_admin_user.id
            or public.is_superadmin(v_auth_user_id)
       );

    if not found then
        raise exception 'Contratacion no encontrada o sin autorizacion.'
            using errcode = '42501';
    end if;

    if v_contract.contract_status <> 'PENDIENTE_PAGO' then
        raise exception 'La contratacion no esta pendiente de pago.'
            using errcode = 'P0001';
    end if;

    insert into public.platform_contract_payment_attempts (
        contract_id,
        amount,
        currency,
        payment_provider,
        payer_name,
        payer_email,
        payment_status
    )
    values (
        v_contract.id,
        v_contract.total_amount,
        v_contract.currency,
        nullif(lower(btrim(p_payment_provider)), ''),
        nullif(btrim(p_payer_name), ''),
        case
            when nullif(btrim(p_payer_email), '') is null then null
            else lower(btrim(p_payer_email))
        end,
        'INICIADO'
    )
    returning *
      into v_attempt;

    return v_attempt;
end;
$function$;

revoke all on function public.iniciar_intento_pago_contratacion_291(uuid,text,text,text)
    from public, anon;

grant execute on function public.iniciar_intento_pago_contratacion_291(uuid,text,text,text)
    to authenticated, service_role;

commit;
