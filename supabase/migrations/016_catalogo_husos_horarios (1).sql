-- =========================================================
-- MIGRACIÓN 016
-- Catálogo de husos horarios con etiqueta amigable en español
-- y diferencia UTC explícita, para que el dropdown del frontend
-- no tenga que mostrar el identificador técnico crudo.
-- cities.timezone pasa a tener una FK real hacia este catálogo
-- (mismo valor que ya tenía, solo se formaliza la relación).
-- =========================================================

-- Limpieza de seguridad por si algo alcanzó a crearse antes del error
drop table if exists timezones cascade;

create table timezones (
  id                         uuid        primary key default gen_random_uuid(),
  iana_id                    text        not null unique,   -- ej. 'America/Mexico_City'
  etiqueta                   text        not null,          -- ej. 'Centro de México'
  utc_offset_estandar        text        not null,          -- ej. 'UTC-6'
  observa_horario_verano     boolean     not null default false,
  pais_referencia            text,                           -- solo informativo, ej. 'México'

  activo                     boolean     not null default true,
  fecha_baja                 timestamptz,
  dado_de_baja_por           uuid        references admin_users (id) on delete restrict,
  motivo_baja                text,

  created_by                 uuid        references admin_users (id) on delete restrict,
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now()
);

comment on table timezones is 'Catálogo curado de husos horarios (no los ~400 de la base IANA completa), con etiqueta amigable. El iana_id sigue siendo la fuente de verdad para cálculos de hora.';

create trigger trg_timezones_updated_at
before update on timezones
for each row execute function set_updated_at();

create trigger trg_track_estatus_timezones
before update on timezones
for each row execute function track_estatus_activo();

create trigger trg_audit_timezones
after insert or update or delete on timezones
for each row execute function log_audit();

-- Las 4 zonas reales de México (Ley del Sistema de Horario)
insert into timezones (iana_id, etiqueta, utc_offset_estandar, observa_horario_verano, pais_referencia) values
  ('America/Tijuana',     'Noroeste — Tijuana',                         'UTC-8', true,  'México'),
  ('America/Mazatlan',    'Pacífico — Baja California Sur / Nayarit / Sinaloa', 'UTC-7', false, 'México'),
  ('America/Mexico_City', 'Centro de México',                           'UTC-6', false, 'México'),
  ('America/Cancun',      'Sureste — Quintana Roo',                     'UTC-5', false, 'México');

-- Zonas principales de EE.UU. (para cuando se agreguen ciudades ahí)
insert into timezones (iana_id, etiqueta, utc_offset_estandar, observa_horario_verano, pais_referencia) values
  ('America/New_York',    'Este de EE.UU. (Eastern)',    'UTC-5', true, 'Estados Unidos'),
  ('America/Chicago',     'Centro de EE.UU. (Central)',  'UTC-6', true, 'Estados Unidos'),
  ('America/Denver',      'Montaña de EE.UU. (Mountain)','UTC-7', true, 'Estados Unidos'),
  ('America/Phoenix',     'Arizona (Mountain, sin horario de verano)', 'UTC-7', false, 'Estados Unidos'),
  ('America/Los_Angeles', 'Pacífico de EE.UU. (Pacific)','UTC-8', true, 'Estados Unidos');

-- Formalizar la relación: cities.timezone ya tenía exactamente
-- estos valores (los sembramos así en la migración 013), así que
-- esta FK no requiere tocar ningún dato existente.
alter table cities
  add constraint cities_timezone_fk
  foreign key (timezone) references timezones (iana_id) on delete restrict;

-- RLS y grants, mismo patrón que countries/states/cities
alter table timezones enable row level security;

create policy timezones_select on timezones
  for select to public using (activo = true or is_superadmin(auth.uid()));

create policy timezones_write on timezones
  for all to authenticated
  using (is_superadmin(auth.uid()))
  with check (is_superadmin(auth.uid()));

grant select on timezones to anon;
grant select, insert, update, delete on timezones to authenticated;
