-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 290
-- FASE 4 CONTRATACION DE PLATAFORMA
-- Contratacion previa al torneo + snapshot economico calculado en backend
--
-- Alcance:
--   - Crear entidad comercial previa a la existencia del torneo.
--   - Resolver tarifa especial vigente por correo; en su ausencia, default.
--   - Calcular en backend dias inclusivos, subtotal, IVA y total.
--   - Congelar el snapshot economico usado en la contratacion.
--   - Permitir que posteriormente se vincule un tournament_id real.
--
-- Fuera de alcance:
--   - Procesamiento de pagos.
--   - Creacion automatica del torneo.
--   - Envio de correos.
--   - Vencimiento/licencia operativa.
-- ============================================================================

begin;

create table if not exists public.platform_tournament_contracts (
    id uuid primary key default gen_random_uuid(),

    organizer_admin_user_id uuid not null
        references public.admin_users(id),

    organizer_email text not null,

    proposed_tournament_name text not null,
    proposed_start_date date not null,
    proposed_end_date date not null,

    tariff_id uuid not null
        references public.platform_tariffs(id),

    tariff_assignment_id uuid null
        references public.platform_tariff_assignments(id),

    tariff_code_snapshot text not null,
    tariff_name_snapshot text not null,
    tariff_type_snapshot text not null,

    number_of_days integer not null,
    unit_price numeric(12,2) not null,
    subtotal numeric(12,2) not null,

    vat_rate numeric(5,2) not null,
    vat_amount numeric(12,2) not null,
    total_amount numeric(12,2) not null,

    currency text not null,

    contract_status text not null default 'PENDIENTE_PAGO',

    tournament_id uuid null
        references public.tournaments(id),

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint platform_tournament_contracts_email_chk
        check (
            nullif(btrim(organizer_email), '') is not null
            and position('@' in organizer_email) > 1
        ),

    constraint platform_tournament_contracts_name_chk
        check (nullif(btrim(proposed_tournament_name), '') is not null),

    constraint platform_tournament_contracts_dates_chk
        check (proposed_end_date >= proposed_start_date),

    constraint platform_tournament_contracts_tariff_type_chk
        check (tariff_type_snapshot in ('POR_DIA', 'POR_TORNEO')),

    constraint platform_tournament_contracts_days_chk
        check (number_of_days >= 1),

    constraint platform_tournament_contracts_unit_price_chk
        check (unit_price >= 0),

    constraint platform_tournament_contracts_subtotal_chk
        check (subtotal >= 0),

    constraint platform_tournament_contracts_vat_rate_chk
        check (vat_rate >= 0 and vat_rate <= 100),

    constraint platform_tournament_contracts_vat_amount_chk
        check (vat_amount >= 0),

    constraint platform_tournament_contracts_total_chk
        check (total_amount >= 0),

    constraint platform_tournament_contracts_currency_chk
        check (currency ~ '^[A-Z]{3}$'),

    constraint platform_tournament_contracts_status_chk
        check (contract_status in ('PENDIENTE_PAGO','PAGADO','CANCELADO','REEMBOLSADO')),

    constraint platform_tournament_contracts_totals_consistency_chk
        check (
            subtotal = round(
                case
                    when tariff_type_snapshot = 'POR_DIA'
                        then unit_price * number_of_days
                    else unit_price
                end
            , 2)
            and vat_amount = round(subtotal * vat_rate / 100.0, 2)
            and total_amount = round(subtotal + vat_amount, 2)
        )
);

comment on table public.platform_tournament_contracts is
'Contratacion comercial previa al torneo. Conserva el snapshot economico calculado en backend y puede vincularse posteriormente al torneo creado.';

comment on column public.platform_tournament_contracts.number_of_days is
'Duracion inclusiva en dias calendario: fecha_fin - fecha_inicio + 1.';

comment on column public.platform_tournament_contracts.vat_rate is
'Porcentaje de IVA congelado para preservar historia economica.';

create index if not exists platform_tournament_contracts_organizer_idx
    on public.platform_tournament_contracts (
        organizer_admin_user_id,
        created_at desc
    );

create index if not exists platform_tournament_contracts_status_idx
    on public.platform_tournament_contracts (
        contract_status,
        created_at desc
    );

create unique index if not exists platform_tournament_contracts_tournament_uq
    on public.platform_tournament_contracts (tournament_id)
    where tournament_id is not null;

drop trigger if exists trg_platform_tournament_contracts_updated_at
    on public.platform_tournament_contracts;

create trigger trg_platform_tournament_contracts_updated_at
before update on public.platform_tournament_contracts
for each row
execute function public.set_updated_at();

alter table public.platform_tournament_contracts enable row level security;

drop policy if exists platform_tournament_contracts_select_owner_or_superadmin
    on public.platform_tournament_contracts;

create policy platform_tournament_contracts_select_owner_or_superadmin
on public.platform_tournament_contracts
for select
to authenticated
using (
    public.is_superadmin(auth.uid())
    or organizer_admin_user_id = (
        select au.id
        from public.admin_users au
        where au.auth_user_id = auth.uid()
          and au.activo = true
        limit 1
    )
);

drop policy if exists platform_tournament_contracts_write_superadmin
    on public.platform_tournament_contracts;

create policy platform_tournament_contracts_write_superadmin
on public.platform_tournament_contracts
for all
to authenticated
using (public.is_superadmin(auth.uid()))
with check (public.is_superadmin(auth.uid()));

revoke all on table public.platform_tournament_contracts from anon;
revoke insert, update, delete on table public.platform_tournament_contracts from authenticated;
grant select on table public.platform_tournament_contracts to authenticated;
grant all on table public.platform_tournament_contracts to service_role;

create or replace function public.crear_contratacion_plataforma_290(
    p_tournament_name text,
    p_start_date date,
    p_end_date date
)
returns public.platform_tournament_contracts
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_auth_user_id uuid := auth.uid();
    v_admin_user public.admin_users%rowtype;
    v_assignment public.platform_tariff_assignments%rowtype;
    v_tariff public.platform_tariffs%rowtype;
    v_settings public.platform_commercial_settings%rowtype;
    v_days integer;
    v_subtotal numeric(12,2);
    v_vat_amount numeric(12,2);
    v_total numeric(12,2);
    v_contract public.platform_tournament_contracts%rowtype;
begin
    if v_auth_user_id is null then
        raise exception 'Usuario no autenticado.'
            using errcode = '42501';
    end if;

    select *
      into v_admin_user
      from public.admin_users
     where auth_user_id = v_auth_user_id
       and activo = true
     limit 1;

    if not found then
        raise exception 'No existe un perfil administrativo activo vinculado al usuario.'
            using errcode = '42501';
    end if;

    if nullif(btrim(p_tournament_name), '') is null then
        raise exception 'El nombre del torneo es obligatorio.'
            using errcode = '22023';
    end if;

    if p_start_date is null or p_end_date is null then
        raise exception 'Las fechas de inicio y fin son obligatorias.'
            using errcode = '22023';
    end if;

    if p_end_date < p_start_date then
        raise exception 'La fecha final no puede ser anterior a la fecha inicial.'
            using errcode = '22023';
    end if;

    select a.*
      into v_assignment
      from public.platform_tariff_assignments a
     where a.activo = true
       and lower(btrim(a.organizer_email)) = lower(btrim(v_admin_user.email::text))
       and current_date >= a.vigente_desde
       and (a.vigente_hasta is null or current_date <= a.vigente_hasta)
     order by a.vigente_desde desc, a.created_at desc
     limit 1;

    if found then
        select t.*
          into v_tariff
          from public.platform_tariffs t
         where t.id = v_assignment.tariff_id
           and t.activo = true
           and current_date >= t.vigente_desde
           and (t.vigente_hasta is null or current_date <= t.vigente_hasta);

        if not found then
            raise exception 'La tarifa especial asignada no esta activa o vigente.'
                using errcode = 'P0001';
        end if;
    else
        select t.*
          into v_tariff
          from public.platform_tariffs t
         where t.activo = true
           and t.es_default = true
           and current_date >= t.vigente_desde
           and (t.vigente_hasta is null or current_date <= t.vigente_hasta)
         order by t.vigente_desde desc, t.created_at desc
         limit 1;

        if not found then
            raise exception 'No existe una tarifa default activa y vigente.'
                using errcode = 'P0001';
        end if;
    end if;

    select *
      into v_settings
      from public.platform_commercial_settings
     where id = 1;

    if not found then
        raise exception 'No existe configuracion comercial global de plataforma.'
            using errcode = 'P0001';
    end if;

    v_days := (p_end_date - p_start_date) + 1;

    v_subtotal := round(
        case
            when v_tariff.tipo_tarifa = 'POR_DIA'
                then v_tariff.importe * v_days
            else v_tariff.importe
        end
    , 2);

    v_vat_amount := round(v_subtotal * v_settings.vat_rate / 100.0, 2);
    v_total := round(v_subtotal + v_vat_amount, 2);

    insert into public.platform_tournament_contracts (
        organizer_admin_user_id,
        organizer_email,
        proposed_tournament_name,
        proposed_start_date,
        proposed_end_date,
        tariff_id,
        tariff_assignment_id,
        tariff_code_snapshot,
        tariff_name_snapshot,
        tariff_type_snapshot,
        number_of_days,
        unit_price,
        subtotal,
        vat_rate,
        vat_amount,
        total_amount,
        currency,
        contract_status
    )
    values (
        v_admin_user.id,
        lower(btrim(v_admin_user.email::text)),
        btrim(p_tournament_name),
        p_start_date,
        p_end_date,
        v_tariff.id,
        case when v_assignment.id is not null then v_assignment.id else null end,
        v_tariff.codigo,
        v_tariff.nombre,
        v_tariff.tipo_tarifa,
        v_days,
        v_tariff.importe,
        v_subtotal,
        v_settings.vat_rate,
        v_vat_amount,
        v_total,
        v_tariff.moneda,
        'PENDIENTE_PAGO'
    )
    returning *
      into v_contract;

    return v_contract;
end;
$function$;

revoke all on function public.crear_contratacion_plataforma_290(text,date,date)
    from public, anon;

grant execute on function public.crear_contratacion_plataforma_290(text,date,date)
    to authenticated, service_role;

commit;
