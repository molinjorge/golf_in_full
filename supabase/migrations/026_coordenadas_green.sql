-- =========================================================
-- MIGRACIÓN 026
-- Coordenadas de green (frente/centro/atrás) por hoyo, usando
-- PostGIS para poder hacer cálculos de distancia nativos más
-- adelante (en vez de columnas numeric sueltas).
-- Opcional: no todos los campos las tendrán de inicio.
-- =========================================================

create extension if not exists postgis;

create table green_coordenadas (
  id                 uuid        primary key default gen_random_uuid(),
  hoyo_id            uuid        not null unique references hoyos (id) on delete cascade,

  green_frente       geography(POINT, 4326),
  green_centro       geography(POINT, 4326),
  green_atras        geography(POINT, 4326),

  created_by         uuid        references admin_users (id) on delete restrict,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table green_coordenadas is 'Coordenadas GPS del green (frente/centro/atrás) de un hoyo. Opcional — no todos los campos la tienen capturada. Un hoyo = a lo más una fila (unique en hoyo_id).';
comment on column green_coordenadas.green_frente is 'Punto GPS del frente del green, formato WGS84 (SRID 4326). Insertar con ST_MakePoint(longitud, latitud)::geography — el orden es LONGITUD primero, LATITUD segundo.';

create trigger trg_green_coordenadas_updated_at
before update on green_coordenadas
for each row execute function set_updated_at();

create trigger trg_audit_green_coordenadas
after insert or update or delete on green_coordenadas
for each row execute function log_audit();

create index idx_green_coordenadas_hoyo on green_coordenadas (hoyo_id);

-- ---------------------------------------------------------
-- RLS — mismo criterio que hoyos/distancias_hoyo
-- ---------------------------------------------------------

alter table green_coordenadas enable row level security;

create policy green_coordenadas_select on green_coordenadas
  for select to public using (true);

create policy green_coordenadas_write on green_coordenadas
  for all to authenticated
  using (
    is_superadmin(auth.uid())
    or exists (
      select 1 from hoyos h
      join campos_golf cg on cg.id = h.campo_golf_id
      where h.id = hoyo_id and is_club_admin(auth.uid(), cg.club_id)
    )
  )
  with check (
    is_superadmin(auth.uid())
    or exists (
      select 1 from hoyos h
      join campos_golf cg on cg.id = h.campo_golf_id
      where h.id = hoyo_id and is_club_admin(auth.uid(), cg.club_id)
    )
  );

-- ---------------------------------------------------------
-- GRANTS
-- ---------------------------------------------------------

grant select on green_coordenadas to anon;
grant select, insert, update, delete on green_coordenadas to authenticated;
