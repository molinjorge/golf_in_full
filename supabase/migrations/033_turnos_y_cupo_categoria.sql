-- =========================================================
-- MIGRACIÓN 033
-- Turnos: dentro de una misma ronda (mismo día), el comité puede
-- dividir a los jugadores en bloques de horario (hasta 3 por día),
-- cada uno con su propia hora de salida y cupo máximo definido
-- a mano por el comité. Los jugadores de un turno son un mix de
-- categorías, no un turno por categoría.
--
-- Cupo por categoría: el comité define cuántas inscripciones
-- acepta por cada categoría del torneo.
-- =========================================================

-- ---------------------------------------------------------
-- TOURNAMENT_ROUND_SHIFTS (turnos)
-- ---------------------------------------------------------

create table tournament_round_shifts (
  id                   uuid            primary key default gen_random_uuid(),
  tournament_round_id  uuid            not null references tournament_rounds (id) on delete restrict,

  numero_turno         integer         not null,
  hora_salida          time            not null,
  cupo_maximo          integer         not null,

  activo               boolean         not null default true,
  fecha_baja           timestamptz,
  dado_de_baja_por     uuid            references admin_users (id) on delete restrict,
  motivo_baja          text,

  created_by           uuid            references admin_users (id) on delete restrict,
  created_at           timestamptz     not null default now(),
  updated_at           timestamptz     not null default now(),

  constraint tournament_round_shifts_numero_unico unique (tournament_round_id, numero_turno),
  constraint tournament_round_shifts_numero_valido check (numero_turno between 1 and 3),
  constraint tournament_round_shifts_cupo_positivo check (cupo_maximo > 0)
);

comment on table tournament_round_shifts is 'Bloques de horario dentro de una ronda (máx. 3 por día). Cada turno mezcla jugadores de distintas categorías; el cupo lo define el comité manualmente, no se calcula solo.';

create trigger trg_tournament_round_shifts_updated_at
before update on tournament_round_shifts
for each row execute function set_updated_at();

create trigger trg_track_estatus_tournament_round_shifts
before update on tournament_round_shifts
for each row execute function track_estatus_activo();

create trigger trg_audit_tournament_round_shifts
after insert or update or delete on tournament_round_shifts
for each row execute function log_audit();

create index idx_tournament_round_shifts_round on tournament_round_shifts (tournament_round_id);

-- ---------------------------------------------------------
-- CUPO MÁXIMO POR CATEGORÍA DEL TORNEO
-- ---------------------------------------------------------

alter table tournament_categories
  add column cupo_maximo integer;

comment on column tournament_categories.cupo_maximo is 'Máximo de inscripciones que acepta el comité para esta categoría en este torneo. NULL = sin límite definido.';

alter table tournament_categories
  add constraint tournament_categories_cupo_positivo
  check (cupo_maximo is null or cupo_maximo > 0);

-- ---------------------------------------------------------
-- RLS
-- ---------------------------------------------------------

alter table tournament_round_shifts enable row level security;

create policy tournament_round_shifts_select on tournament_round_shifts
  for select to public using (activo = true or is_superadmin(auth.uid()));

create policy tournament_round_shifts_write on tournament_round_shifts
  for all to authenticated
  using (
    is_superadmin(auth.uid())
    or exists (
      select 1 from tournament_rounds tr
      join tournaments t on t.id = tr.tournament_id
      where tr.id = tournament_round_id
        and (is_tournament_organizer(auth.uid(), t.id) or is_club_admin(auth.uid(), t.club_id))
    )
  )
  with check (
    is_superadmin(auth.uid())
    or exists (
      select 1 from tournament_rounds tr
      join tournaments t on t.id = tr.tournament_id
      where tr.id = tournament_round_id
        and (is_tournament_organizer(auth.uid(), t.id) or is_club_admin(auth.uid(), t.club_id))
    )
  );

-- ---------------------------------------------------------
-- GRANTS
-- ---------------------------------------------------------

grant select on tournament_round_shifts to anon;
grant select, insert, update, delete on tournament_round_shifts to authenticated;
