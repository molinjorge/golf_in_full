-- =========================================================
-- MIGRACIÓN 017
-- Catálogo de módulos contratables + licencias por club.
-- Fase 1: solo estructura de tablas (sin frontend todavía).
-- =========================================================

-- ---------------------------------------------------------
-- MODULES (catálogo)
-- ---------------------------------------------------------

create table modules (
  id                 uuid        primary key default gen_random_uuid(),
  codigo             text        not null unique,   -- ej. 'torneos'
  nombre             text        not null,
  descripcion        text,

  activo             boolean     not null default true,
  fecha_baja         timestamptz,
  dado_de_baja_por   uuid        references admin_users (id) on delete restrict,
  motivo_baja        text,

  created_by         uuid        references admin_users (id) on delete restrict,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table modules is 'Catálogo de módulos contratables por un club (ej. Torneos). Nuevos módulos se agregan como filas, no como migración.';

create trigger trg_modules_updated_at
before update on modules
for each row execute function set_updated_at();

create trigger trg_track_estatus_modules
before update on modules
for each row execute function track_estatus_activo();

create trigger trg_audit_modules
after insert or update or delete on modules
for each row execute function log_audit();

insert into modules (codigo, nombre, descripcion) values
  ('torneos', 'Torneos', 'Permite al club crear y administrar torneos dentro de la plataforma.');

-- ---------------------------------------------------------
-- CLUB_MODULE_LICENSES (la licencia en sí)
-- ---------------------------------------------------------

create type modalidad_contratacion as enum ('anual', 'por_torneo');
create type medio_pago_licencia as enum ('tarjeta_credito', 'tarjeta_debito', 'transferencia');

create table club_module_licenses (
  id                       uuid                    primary key default gen_random_uuid(),
  club_id                  uuid                    not null references clubs (id) on delete restrict,
  module_id                uuid                    not null references modules (id) on delete restrict,

  modalidad_contratacion   modalidad_contratacion  not null,
  -- Solo aplica trazabilidad opcional cuando la modalidad es "por_torneo":
  tournament_id            uuid                    references tournaments (id) on delete restrict,

  fecha_inicio             date                    not null,
  fecha_fin                date,   -- se calcula solo si es "anual"; obligatorio si es "por_torneo" (ver trigger)

  tarifa                   numeric(10,2)           not null,
  moneda                   text                    not null default 'MXN',

  -- Control de pago
  monto_pago               numeric(10,2),
  fecha_pago               date,
  medio_pago               medio_pago_licencia,
  pago_confirmado          boolean                 not null default false,
  fecha_confirmacion_pago  timestamptz,
  confirmado_por           uuid                    references admin_users (id) on delete restrict,

  -- Encendido/apagado a discreción (reutiliza el patrón estándar del proyecto)
  activo                   boolean                 not null default true,
  fecha_baja               timestamptz,
  dado_de_baja_por         uuid                    references admin_users (id) on delete restrict,
  motivo_baja              text,

  created_by               uuid                    references admin_users (id) on delete restrict,
  created_at               timestamptz             not null default now(),
  updated_at               timestamptz             not null default now(),

  constraint club_module_licenses_fechas_validas check (fecha_fin is null or fecha_fin >= fecha_inicio),
  constraint club_module_licenses_tarifa_no_negativa check (tarifa >= 0)
);

comment on table club_module_licenses is 'Licencia de un módulo contratado por un club: vigencia, tarifa y control de pago.';
comment on column club_module_licenses.activo is 'Interruptor discrecional de encendido/apagado del módulo para este club, independiente de las fechas de vigencia.';
comment on column club_module_licenses.fecha_fin is 'Si modalidad_contratacion = anual, se calcula automáticamente como fecha_inicio + 1 año. Si es por_torneo, es obligatorio capturarla.';

create trigger trg_club_module_licenses_updated_at
before update on club_module_licenses
for each row execute function set_updated_at();

create trigger trg_track_estatus_club_module_licenses
before update on club_module_licenses
for each row execute function track_estatus_activo();

create trigger trg_audit_club_module_licenses
after insert or update or delete on club_module_licenses
for each row execute function log_audit();

create index idx_club_module_licenses_club on club_module_licenses (club_id);
create index idx_club_module_licenses_module on club_module_licenses (module_id);

-- Calcula fecha_fin automáticamente si la modalidad es "anual";
-- exige que venga explícita si es "por_torneo".
create or replace function calcular_fecha_fin_licencia()
returns trigger as $$
begin
  if new.modalidad_contratacion = 'anual' then
    new.fecha_fin := new.fecha_inicio + interval '1 year';
  elsif new.modalidad_contratacion = 'por_torneo' and new.fecha_fin is null then
    raise exception 'Debes especificar fecha_fin cuando la modalidad de contratación es "por_torneo".';
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_calcular_fecha_fin_licencia
before insert or update on club_module_licenses
for each row execute function calcular_fecha_fin_licencia();

-- ---------------------------------------------------------
-- Helper para el frontend: ¿tiene el club este módulo activo HOY?
-- ---------------------------------------------------------

create or replace function club_has_active_module(p_club_id uuid, p_module_codigo text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from club_module_licenses cml
    join modules m on m.id = cml.module_id
    where cml.club_id = p_club_id
      and m.codigo = p_module_codigo
      and cml.activo = true
      and current_date between cml.fecha_inicio and cml.fecha_fin
  );
$$;

comment on function club_has_active_module is 'true si el club tiene el módulo (por código) activo y dentro de su vigencia el día de hoy.';

grant execute on function club_has_active_module(uuid, text) to authenticated;

-- ---------------------------------------------------------
-- RLS
-- ---------------------------------------------------------

alter table modules enable row level security;
alter table club_module_licenses enable row level security;

create policy modules_select on modules
  for select to public using (activo = true or is_superadmin(auth.uid()));
create policy modules_write on modules
  for all to authenticated using (is_superadmin(auth.uid())) with check (is_superadmin(auth.uid()));

-- El club_admin puede VER la licencia de su propio club (para saber si
-- el módulo está habilitado), pero solo el superadmin la administra
-- (tarifas y pagos son control centralizado).
create policy club_module_licenses_select on club_module_licenses
  for select to authenticated
  using (is_superadmin(auth.uid()) or is_club_admin(auth.uid(), club_id));

create policy club_module_licenses_write on club_module_licenses
  for all to authenticated
  using (is_superadmin(auth.uid()))
  with check (is_superadmin(auth.uid()));

-- ---------------------------------------------------------
-- GRANTS
-- ---------------------------------------------------------

grant select on modules to anon;
grant select, insert, update, delete on modules to authenticated;

-- Sin anon aquí a propósito: tarifas y datos de pago no son públicos.
grant select, insert, update, delete on club_module_licenses to authenticated;
