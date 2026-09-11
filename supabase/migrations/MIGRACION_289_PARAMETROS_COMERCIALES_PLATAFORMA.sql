-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 289
-- FASE 3 CONTRATACION DE PLATAFORMA
-- Parametros comerciales/fiscales de plataforma
--
-- Alcance:
--   - Crear configuracion comercial independiente del dominio deportivo.
--   - Guardar porcentaje de IVA configurable.
--   - Guardar correo administrativo de notificaciones comerciales.
--   - Mantener una sola fila de configuracion global.
--   - Reservar mantenimiento directo al Superadmin.
--
-- Fuera de alcance:
--   - Calculo de cotizaciones.
--   - Contrataciones.
--   - Pagos.
--   - Envio de correos.
--   - Provisionamiento automatico de torneos.
-- ============================================================================

begin;

create table if not exists public.platform_commercial_settings (
    id smallint primary key default 1,

    vat_rate numeric(5,2) not null default 16.00,
    notification_email text null,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint platform_commercial_settings_singleton_chk
        check (id = 1),

    constraint platform_commercial_settings_vat_rate_chk
        check (vat_rate >= 0 and vat_rate <= 100),

    constraint platform_commercial_settings_notification_email_chk
        check (
            notification_email is null
            or (
                nullif(btrim(notification_email), '') is not null
                and position('@' in notification_email) > 1
            )
        )
);

comment on table public.platform_commercial_settings is
'Configuracion comercial global de TEE CENTRAL, separada de parametros deportivos.';

comment on column public.platform_commercial_settings.vat_rate is
'Porcentaje de IVA vigente usado para nuevas cotizaciones; las contrataciones conservaran su propio snapshot.';

comment on column public.platform_commercial_settings.notification_email is
'Correo administrativo que recibira notificaciones comerciales de plataforma.';

insert into public.platform_commercial_settings (
    id,
    vat_rate,
    notification_email
)
values (
    1,
    16.00,
    null
)
on conflict (id) do nothing;

drop trigger if exists trg_platform_commercial_settings_updated_at
    on public.platform_commercial_settings;

create trigger trg_platform_commercial_settings_updated_at
before update on public.platform_commercial_settings
for each row
execute function public.set_updated_at();

alter table public.platform_commercial_settings enable row level security;

drop policy if exists platform_commercial_settings_select_superadmin
    on public.platform_commercial_settings;

create policy platform_commercial_settings_select_superadmin
on public.platform_commercial_settings
for select
to authenticated
using (public.is_superadmin(auth.uid()));

drop policy if exists platform_commercial_settings_insert_superadmin
    on public.platform_commercial_settings;

create policy platform_commercial_settings_insert_superadmin
on public.platform_commercial_settings
for insert
to authenticated
with check (
    public.is_superadmin(auth.uid())
    and id = 1
);

drop policy if exists platform_commercial_settings_update_superadmin
    on public.platform_commercial_settings;

create policy platform_commercial_settings_update_superadmin
on public.platform_commercial_settings
for update
to authenticated
using (public.is_superadmin(auth.uid()))
with check (
    public.is_superadmin(auth.uid())
    and id = 1
);

drop policy if exists platform_commercial_settings_delete_superadmin
    on public.platform_commercial_settings;

create policy platform_commercial_settings_delete_superadmin
on public.platform_commercial_settings
for delete
to authenticated
using (public.is_superadmin(auth.uid()));

revoke all on table public.platform_commercial_settings from anon;
grant select, insert, update, delete
    on table public.platform_commercial_settings
    to authenticated;
grant all
    on table public.platform_commercial_settings
    to service_role;

commit;
