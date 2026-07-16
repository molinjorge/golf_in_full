-- =========================================================
-- MIGRACIÓN 013
-- Catálogo geográfico normalizado: countries -> states -> cities
-- Huso horario vive en "cities" (nivel correcto de precisión).
-- clubs pasa a referenciar city_id en vez de texto libre.
-- =========================================================

-- ---------------------------------------------------------
-- COUNTRIES
-- ---------------------------------------------------------

create table countries (
  id                 uuid        primary key default gen_random_uuid(),
  codigo_iso2        char(2)     not null unique,   -- ej. 'MX'
  codigo_iso3        char(3)     not null unique,   -- ej. 'MEX'
  nombre             text        not null,

  activo             boolean     not null default true,
  fecha_baja         timestamptz,
  dado_de_baja_por   uuid        references admin_users (id) on delete restrict,
  motivo_baja        text,

  created_by         uuid        references admin_users (id) on delete restrict,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table countries is 'Catálogo de países (ISO 3166-1).';

create trigger trg_countries_updated_at
before update on countries
for each row execute function set_updated_at();

create trigger trg_track_estatus_countries
before update on countries
for each row execute function track_estatus_activo();

create trigger trg_audit_countries
after insert or update or delete on countries
for each row execute function log_audit();

insert into countries (codigo_iso2, codigo_iso3, nombre) values
  ('MX', 'MEX', 'México'),
  ('US', 'USA', 'Estados Unidos');

-- ---------------------------------------------------------
-- STATES
-- ---------------------------------------------------------

create table states (
  id                 uuid        primary key default gen_random_uuid(),
  country_id         uuid        not null references countries (id) on delete restrict,
  codigo             text,          -- abreviación (ej. 'JAL', 'CA')
  nombre             text        not null,

  activo             boolean     not null default true,
  fecha_baja         timestamptz,
  dado_de_baja_por   uuid        references admin_users (id) on delete restrict,
  motivo_baja        text,

  created_by         uuid        references admin_users (id) on delete restrict,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint states_country_nombre_unique unique (country_id, nombre)
);

comment on table states is 'Estados/provincias, agrupados por país. No tiene huso horario propio: ver cities.';

create trigger trg_states_updated_at
before update on states
for each row execute function set_updated_at();

create trigger trg_track_estatus_states
before update on states
for each row execute function track_estatus_activo();

create trigger trg_audit_states
after insert or update or delete on states
for each row execute function log_audit();

create index idx_states_country on states (country_id);

-- 32 estados de México
insert into states (country_id, codigo, nombre)
select c.id, v.codigo, v.nombre
from countries c
cross join (values
  ('AGU','Aguascalientes'), ('BCN','Baja California'), ('BCS','Baja California Sur'),
  ('CAM','Campeche'), ('CHP','Chiapas'), ('CHH','Chihuahua'),
  ('CMX','Ciudad de México'), ('COA','Coahuila'), ('COL','Colima'),
  ('DUR','Durango'), ('GUA','Guanajuato'), ('GRO','Guerrero'),
  ('HID','Hidalgo'), ('JAL','Jalisco'), ('MEX','México'),
  ('MIC','Michoacán'), ('MOR','Morelos'), ('NAY','Nayarit'),
  ('NLE','Nuevo León'), ('OAX','Oaxaca'), ('PUE','Puebla'),
  ('QUE','Querétaro'), ('ROO','Quintana Roo'), ('SLP','San Luis Potosí'),
  ('SIN','Sinaloa'), ('SON','Sonora'), ('TAB','Tabasco'),
  ('TAM','Tamaulipas'), ('TLA','Tlaxcala'), ('VER','Veracruz'),
  ('YUC','Yucatán'), ('ZAC','Zacatecas')
) as v(codigo, nombre)
where c.codigo_iso2 = 'MX';

-- 50 estados de EE.UU. + Distrito de Columbia
insert into states (country_id, codigo, nombre)
select c.id, v.codigo, v.nombre
from countries c
cross join (values
  ('AL','Alabama'), ('AK','Alaska'), ('AZ','Arizona'), ('AR','Arkansas'),
  ('CA','California'), ('CO','Colorado'), ('CT','Connecticut'), ('DE','Delaware'),
  ('DC','Distrito de Columbia'), ('FL','Florida'), ('GA','Georgia'), ('HI','Hawái'),
  ('ID','Idaho'), ('IL','Illinois'), ('IN','Indiana'), ('IA','Iowa'),
  ('KS','Kansas'), ('KY','Kentucky'), ('LA','Luisiana'), ('ME','Maine'),
  ('MD','Maryland'), ('MA','Massachusetts'), ('MI','Michigan'), ('MN','Minnesota'),
  ('MS','Misisipi'), ('MO','Misuri'), ('MT','Montana'), ('NE','Nebraska'),
  ('NV','Nevada'), ('NH','New Hampshire'), ('NJ','Nueva Jersey'), ('NM','Nuevo México'),
  ('NY','Nueva York'), ('NC','Carolina del Norte'), ('ND','Dakota del Norte'), ('OH','Ohio'),
  ('OK','Oklahoma'), ('OR','Oregón'), ('PA','Pensilvania'), ('RI','Rhode Island'),
  ('SC','Carolina del Sur'), ('SD','Dakota del Sur'), ('TN','Tennessee'), ('TX','Texas'),
  ('UT','Utah'), ('VT','Vermont'), ('VA','Virginia'), ('WA','Washington'),
  ('WV','Virginia Occidental'), ('WI','Wisconsin'), ('WY','Wyoming')
) as v(codigo, nombre)
where c.codigo_iso2 = 'US';

-- ---------------------------------------------------------
-- CITIES
-- ---------------------------------------------------------

create table cities (
  id                 uuid        primary key default gen_random_uuid(),
  state_id           uuid        not null references states (id) on delete restrict,
  nombre             text        not null,
  timezone           text        not null,   -- identificador IANA, ej. 'America/Mexico_City'

  activo             boolean     not null default true,
  fecha_baja         timestamptz,
  dado_de_baja_por   uuid        references admin_users (id) on delete restrict,
  motivo_baja        text,

  created_by         uuid        references admin_users (id) on delete restrict,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint cities_state_nombre_unique unique (state_id, nombre)
);

comment on table cities is 'Ciudades/localidades. El huso horario vive aquí, no en states, porque es el nivel de precisión correcto (un mismo estado puede abarcar más de un huso).';

create trigger trg_cities_updated_at
before update on cities
for each row execute function set_updated_at();

create trigger trg_track_estatus_cities
before update on cities
for each row execute function track_estatus_activo();

create trigger trg_audit_cities
after insert or update or delete on cities
for each row execute function log_audit();

create index idx_cities_state on cities (state_id);

-- Ciudades donde ya identificamos clubes de golf (dataset inicial;
-- se agregan más desde el dashboard según se necesiten).
-- Husos horarios según la Ley del Sistema de Horario en los Estados
-- Unidos Mexicanos: Noroeste=America/Tijuana, Pacífico=America/Mazatlan,
-- Centro=America/Mexico_City, Sureste=America/Cancun.
insert into cities (state_id, nombre, timezone)
select s.id, v.nombre, v.timezone
from states s
join countries c on c.id = s.country_id and c.codigo_iso2 = 'MX'
join (values
  ('Baja California Sur','Los Cabos','America/Mazatlan'),
  ('Baja California Sur','San José del Cabo','America/Mazatlan'),
  ('Nayarit','Bahía de Banderas','America/Mazatlan'),
  ('Nayarit','Nuevo Vallarta','America/Mazatlan'),
  ('Jalisco','Puerto Vallarta','America/Mexico_City'),
  ('Jalisco','El Salto','America/Mexico_City'),
  ('Quintana Roo','Playa del Carmen','America/Cancun'),
  ('Quintana Roo','Cancún','America/Cancun'),
  ('Quintana Roo','Akumal','America/Cancun'),
  ('Yucatán','Mérida','America/Mexico_City'),
  ('México','Naucalpan','America/Mexico_City'),
  ('México','Huixquilucan','America/Mexico_City'),
  ('México','Toluca','America/Mexico_City'),
  ('Ciudad de México','Ciudad de México','America/Mexico_City'),
  ('Querétaro','Santiago de Querétaro','America/Mexico_City'),
  ('Querétaro','El Marqués','America/Mexico_City'),
  ('Querétaro','San Juan del Río','America/Mexico_City'),
  ('Querétaro','Juriquilla','America/Mexico_City'),
  ('Guanajuato','San Miguel de Allende','America/Mexico_City'),
  ('Guanajuato','León','America/Mexico_City'),
  ('Guanajuato','Celaya','America/Mexico_City'),
  ('Guanajuato','Irapuato','America/Mexico_City'),
  ('Aguascalientes','Aguascalientes','America/Mexico_City'),
  ('San Luis Potosí','San Luis Potosí','America/Mexico_City'),
  ('Baja California','Tijuana','America/Tijuana'),
  ('Michoacán','Morelia','America/Mexico_City'),
  ('Guerrero','Acapulco','America/Mexico_City')
) as v(estado, nombre, timezone) on v.estado = s.nombre;

-- ---------------------------------------------------------
-- clubs: agregar city_id (las columnas ciudad/estado de texto
-- libre se quedan por ahora, marcadas como obsoletas, hasta que
-- migres los datos existentes y confirmes que ya no se usan)
-- ---------------------------------------------------------

alter table clubs add column city_id uuid references cities (id) on delete restrict;

comment on column clubs.ciudad is 'OBSOLETO — usar city_id. Se conserva temporalmente para no perder datos existentes; pendiente de eliminar.';
comment on column clubs.estado is 'OBSOLETO — usar city_id (city -> state -> country). Se conserva temporalmente; pendiente de eliminar.';

-- ---------------------------------------------------------
-- RLS
-- ---------------------------------------------------------

alter table countries enable row level security;
alter table states enable row level security;
alter table cities enable row level security;

create policy countries_select on countries
  for select to public using (activo = true or is_superadmin(auth.uid()));
create policy countries_write on countries
  for all to authenticated using (is_superadmin(auth.uid())) with check (is_superadmin(auth.uid()));

create policy states_select on states
  for select to public using (activo = true or is_superadmin(auth.uid()));
create policy states_write on states
  for all to authenticated using (is_superadmin(auth.uid())) with check (is_superadmin(auth.uid()));

create policy cities_select on cities
  for select to public using (activo = true or is_superadmin(auth.uid()));
create policy cities_write on cities
  for all to authenticated using (is_superadmin(auth.uid())) with check (is_superadmin(auth.uid()));

-- ---------------------------------------------------------
-- GRANTS (lección aprendida en la migración 011: sin esto,
-- RLS nunca llega a evaluarse)
-- ---------------------------------------------------------

grant select on countries, states, cities to anon;
grant select, insert, update, delete on countries, states, cities to authenticated;
