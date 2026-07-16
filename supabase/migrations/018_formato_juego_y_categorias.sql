-- =========================================================
-- MIGRACIÓN 018
-- Formato de juego (individual/equipo) y modalidad en tournaments.
-- Catálogo de categorías + relación muchos-a-muchos con torneos.
-- Duración del torneo calculada automáticamente.
-- =========================================================

-- ---------------------------------------------------------
-- tournaments: formato de juego y modalidad
-- ---------------------------------------------------------

create type formato_juego_torneo as enum ('individual', 'equipo');
create type modalidad_individual_torneo as enum ('stroke_play', 'stableford');
create type modalidad_equipo_torneo as enum ('a_gogo', 'stableford', 'best_ball');

alter table tournaments
  add column formato_juego        formato_juego_torneo,
  add column modalidad_individual modalidad_individual_torneo,
  add column modalidad_equipo     modalidad_equipo_torneo,
  add column jugadores_por_equipo integer,
  add column duracion_dias        integer generated always as (fecha_fin - fecha_inicio + 1) stored;

alter table tournaments
  add constraint tournaments_jugadores_por_equipo_rango
  check (jugadores_por_equipo is null or jugadores_por_equipo between 2 and 5);

comment on column tournaments.duracion_dias is 'Calculado automáticamente a partir de fecha_inicio/fecha_fin. No se captura manualmente.';
comment on column tournaments.jugadores_por_equipo is 'Solo aplica si formato_juego = equipo. Entre 2 y 5.';

-- Consistencia entre formato_juego y los campos de modalidad
create or replace function validar_formato_modalidad_torneo()
returns trigger as $$
begin
  if new.formato_juego = 'individual' then
    if new.modalidad_individual is null then
      raise exception 'Debes especificar modalidad_individual cuando formato_juego es "individual".';
    end if;
    if new.modalidad_equipo is not null or new.jugadores_por_equipo is not null then
      raise exception 'modalidad_equipo y jugadores_por_equipo deben quedar vacíos cuando formato_juego es "individual".';
    end if;

  elsif new.formato_juego = 'equipo' then
    if new.modalidad_equipo is null or new.jugadores_por_equipo is null then
      raise exception 'Debes especificar modalidad_equipo y jugadores_por_equipo cuando formato_juego es "equipo".';
    end if;
    if new.modalidad_individual is not null then
      raise exception 'modalidad_individual debe quedar vacío cuando formato_juego es "equipo".';
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validar_formato_modalidad_torneo
before insert or update on tournaments
for each row execute function validar_formato_modalidad_torneo();

-- ---------------------------------------------------------
-- CATEGORIES (catálogo)
-- ---------------------------------------------------------

create table categories (
  id                 uuid        primary key default gen_random_uuid(),
  codigo             text        not null unique,
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

comment on table categories is 'Catálogo de categorías de torneo (ej. Campeonato, AA, A, Senior). Criterios de elegibilidad (hándicap/edad/género) pendientes de definir.';

create trigger trg_categories_updated_at
before update on categories
for each row execute function set_updated_at();

create trigger trg_track_estatus_categories
before update on categories
for each row execute function track_estatus_activo();

create trigger trg_audit_categories
after insert or update or delete on categories
for each row execute function log_audit();

-- ---------------------------------------------------------
-- TOURNAMENT_CATEGORIES (un torneo puede tener varias categorías)
-- ---------------------------------------------------------

create table tournament_categories (
  id             uuid        primary key default gen_random_uuid(),
  tournament_id  uuid        not null references tournaments (id) on delete restrict,
  category_id    uuid        not null references categories (id) on delete restrict,
  created_by     uuid        references admin_users (id) on delete restrict,
  created_at     timestamptz not null default now(),

  constraint tournament_categories_unique unique (tournament_id, category_id)
);

comment on table tournament_categories is 'Relación muchos-a-muchos: qué categorías participan en cada torneo.';

create index idx_tournament_categories_tournament on tournament_categories (tournament_id);
create index idx_tournament_categories_category on tournament_categories (category_id);

-- ---------------------------------------------------------
-- RLS
-- ---------------------------------------------------------

alter table categories enable row level security;
alter table tournament_categories enable row level security;

create policy categories_select on categories
  for select to public using (activo = true or is_superadmin(auth.uid()));
create policy categories_write on categories
  for all to authenticated using (is_superadmin(auth.uid())) with check (is_superadmin(auth.uid()));

create policy tournament_categories_select on tournament_categories
  for select to public using (true);

create policy tournament_categories_write on tournament_categories
  for all to authenticated
  using (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (
      select 1 from tournaments t
       where t.id = tournament_id
         and is_club_admin(auth.uid(), t.club_id)
    )
  )
  with check (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (
      select 1 from tournaments t
       where t.id = tournament_id
         and is_club_admin(auth.uid(), t.club_id)
    )
  );

-- ---------------------------------------------------------
-- GRANTS
-- ---------------------------------------------------------

grant select on categories to anon;
grant select, insert, update, delete on categories to authenticated;

grant select on tournament_categories to anon;
grant select, insert, update, delete on tournament_categories to authenticated;
