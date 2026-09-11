-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 287
-- FASE 1 CONTRATACION DE PLATAFORMA
-- Catalogo de tarifas de uso de plataforma
-- ============================================================================

begin;

create table if not exists public.platform_tariffs (
    id uuid primary key default gen_random_uuid(),
    codigo text not null,
    nombre text not null,
    tipo_tarifa text not null,
    importe numeric(12,2) not null,
    moneda text not null default 'MXN',
    vigente_desde date not null default current_date,
    vigente_hasta date null,
    activo boolean not null default true,
    es_default boolean not null default false,
    descripcion text null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint platform_tariffs_codigo_no_vacio_chk
        check (nullif(btrim(codigo), '') is not null),

    constraint platform_tariffs_nombre_no_vacio_chk
        check (nullif(btrim(nombre), '') is not null),

    constraint platform_tariffs_tipo_chk
        check (tipo_tarifa in ('POR_DIA', 'POR_TORNEO')),

    constraint platform_tariffs_importe_chk
        check (importe >= 0),

    constraint platform_tariffs_moneda_chk
        check (moneda ~ '^[A-Z]{3}$'),

    constraint platform_tariffs_vigencia_chk
        check (vigente_hasta is null or vigente_hasta >= vigente_desde)
);

comment on table public.platform_tariffs is
'Catalogo comercial de tarifas de uso de TEE CENTRAL. No representa pagos ni contrataciones.';

comment on column public.platform_tariffs.codigo is
'Codigo comercial estable de la tarifa.';

comment on column public.platform_tariffs.tipo_tarifa is
'POR_DIA o POR_TORNEO.';

comment on column public.platform_tariffs.importe is
'Importe base antes de impuestos.';

comment on column public.platform_tariffs.es_default is
'Indica la tarifa activa que se usara por defecto cuando no exista una tarifa especial aplicable.';

create unique index if not exists platform_tariffs_codigo_uq
    on public.platform_tariffs (lower(btrim(codigo)));

create unique index if not exists platform_tariffs_default_activa_uq
    on public.platform_tariffs ((1))
    where activo = true and es_default = true;

create index if not exists platform_tariffs_vigencia_idx
    on public.platform_tariffs (activo, vigente_desde, vigente_hasta);

drop trigger if exists trg_platform_tariffs_updated_at
    on public.platform_tariffs;

create trigger trg_platform_tariffs_updated_at
before update on public.platform_tariffs
for each row
execute function public.set_updated_at();

alter table public.platform_tariffs enable row level security;

drop policy if exists platform_tariffs_select_superadmin
    on public.platform_tariffs;

create policy platform_tariffs_select_superadmin
on public.platform_tariffs
for select
to authenticated
using (public.is_superadmin(auth.uid()));

drop policy if exists platform_tariffs_insert_superadmin
    on public.platform_tariffs;

create policy platform_tariffs_insert_superadmin
on public.platform_tariffs
for insert
to authenticated
with check (public.is_superadmin(auth.uid()));

drop policy if exists platform_tariffs_update_superadmin
    on public.platform_tariffs;

create policy platform_tariffs_update_superadmin
on public.platform_tariffs
for update
to authenticated
using (public.is_superadmin(auth.uid()))
with check (public.is_superadmin(auth.uid()));

drop policy if exists platform_tariffs_delete_superadmin
    on public.platform_tariffs;

create policy platform_tariffs_delete_superadmin
on public.platform_tariffs
for delete
to authenticated
using (public.is_superadmin(auth.uid()));

revoke all on table public.platform_tariffs from anon;
grant select, insert, update, delete on table public.platform_tariffs to authenticated;
grant all on table public.platform_tariffs to service_role;

commit;
