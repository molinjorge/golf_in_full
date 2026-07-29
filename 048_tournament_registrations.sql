-- =========================================================
-- MIGRACIÓN 048
-- Inscripción individual a torneo. La fila SOLO existe si el
-- pago fue confirmado — no hay estatus "pendiente" dentro de
-- esta tabla. Los intentos abandonados se registran aparte,
-- para poder mandar el correo de abandono y dar seguimiento.
-- =========================================================

create table tournament_registrations (
  id                       uuid            primary key default gen_random_uuid(),
  tournament_id            uuid            not null references tournaments (id) on delete restrict,
  player_id                uuid            not null references players (id) on delete restrict,
  tournament_category_id   uuid            not null references tournament_categories (id) on delete restrict,

  monto_pagado             numeric(10,2)   not null,
  fecha_pago               timestamptz     not null default now(),
  medio_pago               medio_pago_licencia not null,
  referencia_pago          text            not null,

  qr_token                 text            not null default encode(gen_random_bytes(16), 'hex'),

  activo                   boolean         not null default true,
  fecha_baja               timestamptz,
  dado_de_baja_por         uuid            references admin_users (id) on delete restrict,
  motivo_baja              text,

  created_by               uuid            references admin_users (id) on delete restrict,
  created_at               timestamptz     not null default now(),
  updated_at               timestamptz     not null default now(),

  constraint tournament_registrations_monto_valido check (monto_pagado >= 0),
  constraint tournament_registrations_qr_unico unique (qr_token)
);

comment on table tournament_registrations is 'Inscripción individual confirmada. Solo existe con pago ya validado — no hay estatus "pendiente" aquí. Solo el proceso de pago (server-side) o el superadmin pueden crear filas.';
comment on column tournament_registrations.qr_token is 'Código único para el QR de acceso, validado contra tournaments.acceso_fecha_hora_inicio/fin.';

create trigger trg_tournament_registrations_updated_at
before update on tournament_registrations
for each row execute function set_updated_at();

create trigger trg_track_estatus_tournament_registrations
before update on tournament_registrations
for each row execute function track_estatus_activo();

create trigger trg_audit_tournament_registrations
after insert or update or delete on tournament_registrations
for each row execute function log_audit();

create unique index tournament_registrations_unico_activo
  on tournament_registrations (tournament_id, player_id)
  where activo = true;

create index idx_tournament_registrations_tournament on tournament_registrations (tournament_id);
create index idx_tournament_registrations_player on tournament_registrations (player_id);
create index idx_tournament_registrations_category on tournament_registrations (tournament_category_id);

create or replace function validar_categoria_pertenece_al_torneo()
returns trigger as $$
declare
  v_tournament_de_categoria uuid;
begin
  select tournament_id into v_tournament_de_categoria
    from tournament_categories where id = new.tournament_category_id;

  if v_tournament_de_categoria is distinct from new.tournament_id then
    raise exception 'La categoría elegida no pertenece a este torneo.';
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validar_categoria_pertenece_al_torneo
before insert or update on tournament_registrations
for each row execute function validar_categoria_pertenece_al_torneo();

create or replace function validar_cupo_categoria()
returns trigger as $$
declare
  v_cupo_maximo integer;
  v_inscritos   integer;
begin
  select cupo_maximo into v_cupo_maximo
    from tournament_categories where id = new.tournament_category_id;

  if v_cupo_maximo is not null then
    select count(*) into v_inscritos
      from tournament_registrations
     where tournament_category_id = new.tournament_category_id
       and activo = true;

    if v_inscritos >= v_cupo_maximo then
      raise exception 'Esta categoría ya alcanzó su cupo máximo de % inscripciones.', v_cupo_maximo;
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validar_cupo_categoria
before insert on tournament_registrations
for each row execute function validar_cupo_categoria();

-- ---------------------------------------------------------
-- TOURNAMENT_REGISTRATION_ATTEMPTS
-- ---------------------------------------------------------

create table tournament_registration_attempts (
  id                          uuid        primary key default gen_random_uuid(),
  tournament_id               uuid        not null references tournaments (id) on delete restrict,
  player_id                   uuid        not null references players (id) on delete restrict,

  fecha_hora_intento          timestamptz not null default now(),
  tournament_registration_id  uuid        references tournament_registrations (id) on delete set null,
  correo_abandono_enviado     boolean     not null default false,

  created_at                  timestamptz not null default now()
);

comment on table tournament_registration_attempts is 'Registro de cada intento de inscripción, exitoso o no. Un proceso aparte (tarea programada) debe revisar los que no se completaron después de cierto tiempo y disparar el correo de abandono.';

create index idx_tournament_registration_attempts_tournament on tournament_registration_attempts (tournament_id);
create index idx_tournament_registration_attempts_player on tournament_registration_attempts (player_id);
create index idx_tournament_registration_attempts_sin_completar
  on tournament_registration_attempts (fecha_hora_intento)
  where tournament_registration_id is null and correo_abandono_enviado = false;

-- ---------------------------------------------------------
-- RLS
-- ---------------------------------------------------------

alter table tournament_registrations enable row level security;
alter table tournament_registration_attempts enable row level security;

create policy tournament_registrations_select on tournament_registrations
  for select to authenticated
  using (
    player_id in (select id from players where auth_user_id = auth.uid())
    or is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

create policy tournament_registrations_insert on tournament_registrations
  for insert to authenticated
  with check (is_superadmin(auth.uid()));

create policy tournament_registrations_update on tournament_registrations
  for update to authenticated
  using (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

create policy tournament_registration_attempts_select on tournament_registration_attempts
  for select to authenticated
  using (
    player_id in (select id from players where auth_user_id = auth.uid())
    or is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

create policy tournament_registration_attempts_insert on tournament_registration_attempts
  for insert to authenticated
  with check (player_id in (select id from players where auth_user_id = auth.uid()));

-- ---------------------------------------------------------
-- GRANTS
-- ---------------------------------------------------------

grant select, insert, update on tournament_registrations to authenticated;
grant select, insert on tournament_registration_attempts to authenticated;
