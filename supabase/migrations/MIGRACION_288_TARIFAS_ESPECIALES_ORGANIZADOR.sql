-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 288
-- FASE 2 CONTRATACION DE PLATAFORMA
-- Tarifas especiales por organizador
--
-- Alcance:
--   - Asociar un correo de organizador con una tarifa especial de plataforma.
--   - Permitir vigencia e inactivacion sin borrar historial.
--   - Evitar traslapes de asignaciones activas para el mismo correo.
--   - Reservar mantenimiento directo al Superadmin.
--
-- Fuera de alcance:
--   - IVA / parametros fiscales.
--   - Contrataciones.
--   - Cotizacion.
--   - Pagos.
--   - Provisionamiento automatico de torneos.
-- ============================================================================

begin;

create table if not exists public.platform_tariff_assignments (
    id uuid primary key default gen_random_uuid(),

    organizer_email text not null,
    tariff_id uuid not null
        references public.platform_tariffs(id),

    vigente_desde date not null default current_date,
    vigente_hasta date null,

    activo boolean not null default true,
    notas text null,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint platform_tariff_assignments_email_chk
        check (
            nullif(btrim(organizer_email), '') is not null
            and position('@' in organizer_email) > 1
        ),

    constraint platform_tariff_assignments_vigencia_chk
        check (
            vigente_hasta is null
            or vigente_hasta >= vigente_desde
        )
);

comment on table public.platform_tariff_assignments is
'Asignaciones comerciales de una tarifa especial de plataforma a un correo de organizador.';

comment on column public.platform_tariff_assignments.organizer_email is
'Correo normalizado del organizador al que se aplica la tarifa especial.';

comment on column public.platform_tariff_assignments.tariff_id is
'Tarifa especial asignada. Debe existir en platform_tariffs.';

create index if not exists platform_tariff_assignments_email_idx
    on public.platform_tariff_assignments (
        lower(btrim(organizer_email)),
        activo,
        vigente_desde,
        vigente_hasta
    );

create index if not exists platform_tariff_assignments_tariff_idx
    on public.platform_tariff_assignments (tariff_id);

drop trigger if exists trg_platform_tariff_assignments_updated_at
    on public.platform_tariff_assignments;

create trigger trg_platform_tariff_assignments_updated_at
before update on public.platform_tariff_assignments
for each row
execute function public.set_updated_at();

create or replace function public.validar_platform_tariff_assignment_288()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_email text;
begin
    v_email := lower(btrim(new.organizer_email));
    new.organizer_email := v_email;

    if new.activo = true then
        if exists (
            select 1
            from public.platform_tariff_assignments a
            where a.id is distinct from new.id
              and a.activo = true
              and lower(btrim(a.organizer_email)) = v_email
              and daterange(
                    a.vigente_desde,
                    coalesce(a.vigente_hasta, 'infinity'::date),
                    '[]'
                  )
                  &&
                  daterange(
                    new.vigente_desde,
                    coalesce(new.vigente_hasta, 'infinity'::date),
                    '[]'
                  )
        ) then
            raise exception
                'Ya existe una tarifa especial activa con vigencia traslapada para el correo %.',
                v_email
                using errcode = '23514';
        end if;
    end if;

    return new;
end;
$function$;

revoke all on function public.validar_platform_tariff_assignment_288()
    from public, anon, authenticated;

grant execute on function public.validar_platform_tariff_assignment_288()
    to service_role;

drop trigger if exists trg_validar_platform_tariff_assignment_288
    on public.platform_tariff_assignments;

create trigger trg_validar_platform_tariff_assignment_288
before insert or update
on public.platform_tariff_assignments
for each row
execute function public.validar_platform_tariff_assignment_288();

alter table public.platform_tariff_assignments enable row level security;

drop policy if exists platform_tariff_assignments_select_superadmin
    on public.platform_tariff_assignments;

create policy platform_tariff_assignments_select_superadmin
on public.platform_tariff_assignments
for select
to authenticated
using (public.is_superadmin(auth.uid()));

drop policy if exists platform_tariff_assignments_insert_superadmin
    on public.platform_tariff_assignments;

create policy platform_tariff_assignments_insert_superadmin
on public.platform_tariff_assignments
for insert
to authenticated
with check (public.is_superadmin(auth.uid()));

drop policy if exists platform_tariff_assignments_update_superadmin
    on public.platform_tariff_assignments;

create policy platform_tariff_assignments_update_superadmin
on public.platform_tariff_assignments
for update
to authenticated
using (public.is_superadmin(auth.uid()))
with check (public.is_superadmin(auth.uid()));

drop policy if exists platform_tariff_assignments_delete_superadmin
    on public.platform_tariff_assignments;

create policy platform_tariff_assignments_delete_superadmin
on public.platform_tariff_assignments
for delete
to authenticated
using (public.is_superadmin(auth.uid()));

revoke all on table public.platform_tariff_assignments from anon;
grant select, insert, update, delete
    on table public.platform_tariff_assignments
    to authenticated;
grant all
    on table public.platform_tariff_assignments
    to service_role;

commit;
