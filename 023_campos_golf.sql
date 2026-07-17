-- =========================================================
-- MIGRACIÓN 023 (v2 — alcance reducido a lo esencial)
-- campos_golf: la instalación física de golf, sin datos
-- administrativos/de contacto (esos ya viven en clubs). Un club
-- puede operar varios campos. Se agregarán marcas de salida y
-- datos hoyo por hoyo en una migración posterior.
-- =========================================================

create table campos_golf (
  id                 uuid        primary key default gen_random_uuid(),
  club_id            uuid        not null references clubs (id) on delete restrict,

  nombre_oficial     text        not null,
  numero_hoyos       integer     not null,
  timezone_id        text        not null references timezones (iana_id) on delete restrict,
  latitud            numeric(9,6),
  longitud           numeric(9,6),

  activo             boolean     not null default true,
  fecha_baja         timestamptz,
  dado_de_baja_por   uuid        references admin_users (id) on delete restrict,
  motivo_baja        text,

  created_by         uuid        references admin_users (id) on delete restrict,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint campos_golf_hoyos_positivo check (numero_hoyos > 0),
  constraint campos_golf_latitud_valida check (latitud is null or latitud between -90 and 90),
  constraint campos_golf_longitud_valida check (longitud is null or longitud between -180 and 180)
);

comment on table campos_golf is 'Instalación física de golf. Un club puede operar varios. Coordenadas opcionales. Datos de contacto por área (Pro Shop, Starter, etc.) vivirán en una tabla aparte, fase futura.';

create trigger trg_campos_golf_updated_at
before update on campos_golf
for each row execute function set_updated_at();

create trigger trg_track_estatus_campos_golf
before update on campos_golf
for each row execute function track_estatus_activo();

create trigger trg_audit_campos_golf
after insert or update or delete on campos_golf
for each row execute function log_audit();

create index idx_campos_golf_club on campos_golf (club_id);

-- ---------------------------------------------------------
-- LIMPIAR clubs: "numero_hoyos" ya no tiene sentido ahí (un club
-- con varios campos no tiene un único número de hoyos). Ahora
-- vive en campos_golf.numero_hoyos.
-- ---------------------------------------------------------

alter table clubs drop column numero_hoyos;

-- ---------------------------------------------------------
-- RLS
-- ---------------------------------------------------------

alter table campos_golf enable row level security;

create policy campos_golf_select on campos_golf
  for select to public
  using (
    activo = true
    or is_superadmin(auth.uid())
    or is_club_admin(auth.uid(), club_id)
  );

create policy campos_golf_insert on campos_golf
  for insert to authenticated
  with check (is_superadmin(auth.uid()));

create policy campos_golf_update on campos_golf
  for update to authenticated
  using (
    is_superadmin(auth.uid())
    or is_club_admin(auth.uid(), club_id)
  );

-- Sin política de DELETE, a propósito.

-- ---------------------------------------------------------
-- GRANTS
-- ---------------------------------------------------------

grant select on campos_golf to anon;
grant select, insert, update on campos_golf to authenticated;
