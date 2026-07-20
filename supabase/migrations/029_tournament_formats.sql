-- =========================================================
-- MIGRACIÓN 029
-- Catálogo de modalidades de torneo (tournament_formats).
-- Estructura únicamente: los "motores" de cada modalidad se
-- definen en una fase posterior.
-- =========================================================

create type motor_puntuacion as enum (
  'stroke',        -- juego por golpes
  'match',         -- juego por hoyos
  'team_stroke',    -- golpes agregados por equipo
  'best_ball',      -- mejor bola
  'stableford',     -- sistema de puntos
  'scramble'        -- mejor posición, todos juegan desde ahí
);

comment on type motor_puntuacion is 'Lista inicial de motores de puntuación. Ampliar con ALTER TYPE ... ADD VALUE conforme se definan más adelante.';

create table tournament_formats (
  id                 uuid                    primary key default gen_random_uuid(),
  code               text                    not null unique,   -- ej. 'STROKE_PLAY', 'SCRAMBLE'
  name               text                    not null,
  tipo_participacion           formato_juego_torneo    not null,          -- reutiliza el enum de tournaments (individual/equipo)
  scoring_engine     motor_puntuacion        not null,
  short_description  text,
  description        text,
  display_order      integer,

  activo             boolean                 not null default true,
  fecha_baja         timestamptz,
  dado_de_baja_por   uuid                    references admin_users (id) on delete restrict,
  motivo_baja        text,

  created_by         uuid                    references admin_users (id) on delete restrict,
  created_at         timestamptz             not null default now(),
  updated_at         timestamptz             not null default now()
);

comment on table tournament_formats is 'Catálogo de modalidades de torneo. Reemplazará, en una migración futura, a los enums fijos formato_juego/modalidad_individual/modalidad_equipo que hoy viven directo en tournaments.';

create trigger trg_tournament_formats_updated_at
before update on tournament_formats
for each row execute function set_updated_at();

create trigger trg_track_estatus_tournament_formats
before update on tournament_formats
for each row execute function track_estatus_activo();

create trigger trg_audit_tournament_formats
after insert or update or delete on tournament_formats
for each row execute function log_audit();

create index idx_tournament_formats_tipo_participacion on tournament_formats (tipo_participacion);

-- ---------------------------------------------------------
-- RLS — catálogo: lectura pública, escritura solo superadmin
-- (mismo patrón que roles/modules)
-- ---------------------------------------------------------

alter table tournament_formats enable row level security;

create policy tournament_formats_select on tournament_formats
  for select to public using (activo = true or is_superadmin(auth.uid()));

create policy tournament_formats_write on tournament_formats
  for all to authenticated
  using (is_superadmin(auth.uid()))
  with check (is_superadmin(auth.uid()));

-- ---------------------------------------------------------
-- GRANTS
-- ---------------------------------------------------------

grant select on tournament_formats to anon;
grant select, insert, update, delete on tournament_formats to authenticated;
