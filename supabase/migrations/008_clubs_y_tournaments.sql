-- =========================================================
-- MIGRACIÓN 008
-- Tablas clubs y tournaments + activación de las FK
-- club_id / tournament_id que quedaron pendientes en
-- admin_role_assignments desde la migración 003.
-- =========================================================

-- ---------------------------------------------------------
-- CLUBS
-- ---------------------------------------------------------

create table clubs (
  id                 uuid        primary key default gen_random_uuid(),

  nombre             text        not null,
  ciudad             text,
  estado             text,          -- estado de México, texto libre por ahora
  direccion          text,
  telefono           varchar(20),
  email              citext,
  sitio_web          text,
  numero_hoyos       integer,

  activo             boolean     not null default true,
  fecha_baja         timestamptz,
  dado_de_baja_por   uuid        references admin_users (id) on delete restrict,
  motivo_baja        text,

  created_by         uuid        references admin_users (id) on delete restrict,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table clubs is 'Clubes de golf registrados en la plataforma.';

create trigger trg_clubs_updated_at
before update on clubs
for each row execute function set_updated_at();

create trigger trg_track_estatus_clubs
before update on clubs
for each row execute function track_estatus_activo();

create trigger trg_audit_clubs
after insert or update or delete on clubs
for each row execute function log_audit();

-- ---------------------------------------------------------
-- TOURNAMENTS
-- ---------------------------------------------------------

create type estatus_torneo as enum (
  'planificado',
  'inscripciones_abiertas',
  'en_curso',
  'finalizado',
  'cancelado'
);

create table tournaments (
  id                 uuid            primary key default gen_random_uuid(),
  club_id            uuid            not null references clubs (id) on delete restrict,

  nombre             text            not null,
  descripcion        text,
  fecha_inicio       date            not null,
  fecha_fin          date            not null,
  estatus            estatus_torneo  not null default 'planificado',
  cupo_maximo        integer,

  activo             boolean         not null default true,
  fecha_baja         timestamptz,
  dado_de_baja_por   uuid            references admin_users (id) on delete restrict,
  motivo_baja        text,

  created_by         uuid            references admin_users (id) on delete restrict,
  created_at         timestamptz     not null default now(),
  updated_at         timestamptz     not null default now(),

  constraint tournaments_fechas_validas check (fecha_fin >= fecha_inicio)
);

comment on table tournaments is 'Torneos organizados por un club. El formato/modalidad de juego se modelará en una migración posterior.';

create trigger trg_tournaments_updated_at
before update on tournaments
for each row execute function set_updated_at();

create trigger trg_track_estatus_tournaments
before update on tournaments
for each row execute function track_estatus_activo();

create trigger trg_audit_tournaments
after insert or update or delete on tournaments
for each row execute function log_audit();

create index idx_tournaments_club on tournaments (club_id);
create index idx_tournaments_fechas on tournaments (fecha_inicio, fecha_fin);

-- ---------------------------------------------------------
-- ACTIVAR LAS FK PENDIENTES EN admin_role_assignments
-- ---------------------------------------------------------

alter table admin_role_assignments
  add constraint admin_role_assignments_club_id_fk
  foreign key (club_id) references clubs (id) on delete restrict;

alter table admin_role_assignments
  add constraint admin_role_assignments_tournament_id_fk
  foreign key (tournament_id) references tournaments (id) on delete restrict;

-- ---------------------------------------------------------
-- RLS
-- ---------------------------------------------------------

alter table clubs enable row level security;
alter table tournaments enable row level security;

-- Lectura pública de clubes/torneos activos; el superadmin, el
-- club_admin del club, o el tournament_organizer del torneo
-- también ven los inactivos (para poder reactivarlos).

create policy clubs_select on clubs
  for select to public
  using (
    activo = true
    or is_superadmin(auth.uid())
    or is_club_admin(auth.uid(), id)
  );

create policy clubs_insert on clubs
  for insert to authenticated
  with check (is_superadmin(auth.uid()));

create policy clubs_update on clubs
  for update to authenticated
  using (
    is_superadmin(auth.uid())
    or is_club_admin(auth.uid(), id)
  );

create policy tournaments_select on tournaments
  for select to public
  using (
    activo = true
    or is_superadmin(auth.uid())
    or is_club_admin(auth.uid(), club_id)
    or is_tournament_organizer(auth.uid(), id)
  );

create policy tournaments_insert on tournaments
  for insert to authenticated
  with check (
    is_superadmin(auth.uid())
    or is_club_admin(auth.uid(), club_id)
  );

create policy tournaments_update on tournaments
  for update to authenticated
  using (
    is_superadmin(auth.uid())
    or is_club_admin(auth.uid(), club_id)
    or is_tournament_organizer(auth.uid(), id)
  );

-- Nota: intencionalmente no hay política de DELETE en ninguna de
-- las dos tablas — mismo patrón que admin_users: la única baja
-- válida es UPDATE activo = false.
