-- =========================================================
-- MIGRACIÓN 049
-- Pre-reservas: jugadores que apartan lugar pagando por
-- transferencia (a confirmar) o el día del evento (en sitio).
-- Tabla separada de tournament_registrations a propósito — ver
-- razones en la conversación. El cupo por categoría se valida
-- de forma CRUZADA entre ambas tablas, para no sobrevender un
-- cupo combinando los dos canales. Se agrega una vista que las
-- unifica para consultas de roster.
-- =========================================================

create type modalidad_pre_reserva as enum ('transferencia', 'pago_dia_evento');
create type estatus_pre_reserva as enum ('pendiente_pago', 'pagado', 'cancelado', 'no_show');

create table tournament_pre_reservations (
  id                       uuid                    primary key default gen_random_uuid(),
  tournament_id            uuid                    not null references tournaments (id) on delete restrict,
  player_id                uuid                    not null references players (id) on delete restrict,
  tournament_category_id   uuid                    not null references tournament_categories (id) on delete restrict,

  modalidad                modalidad_pre_reserva   not null,
  estatus                  estatus_pre_reserva     not null default 'pendiente_pago',

  monto                    numeric(10,2)           not null,
  fecha_reserva            timestamptz             not null default now(),
  fecha_limite_pago        timestamptz,
  fecha_pago               timestamptz,
  referencia_pago          text,
  confirmado_por            uuid                    references admin_users (id) on delete restrict,

  qr_token                 text                    not null default encode(gen_random_bytes(16), 'hex'),

  activo                   boolean                 not null default true,
  fecha_baja               timestamptz,
  dado_de_baja_por         uuid                    references admin_users (id) on delete restrict,
  motivo_baja              text,

  created_by               uuid                    references admin_users (id) on delete restrict,
  created_at               timestamptz             not null default now(),
  updated_at               timestamptz             not null default now(),

  constraint tournament_pre_reservations_monto_valido check (monto >= 0),
  constraint tournament_pre_reservations_qr_unico unique (qr_token)
);

comment on table tournament_pre_reservations is 'Jugadores que apartan lugar sin pago inmediato (transferencia a confirmar, o pago el día del evento). Separada de tournament_registrations a propósito — ciclo de vida distinto.';

create trigger trg_tournament_pre_reservations_updated_at
before update on tournament_pre_reservations
for each row execute function set_updated_at();

create trigger trg_track_estatus_tournament_pre_reservations
before update on tournament_pre_reservations
for each row execute function track_estatus_activo();

create trigger trg_audit_tournament_pre_reservations
after insert or update or delete on tournament_pre_reservations
for each row execute function log_audit();

create unique index tournament_pre_reservations_unico_activo
  on tournament_pre_reservations (tournament_id, player_id)
  where activo = true;

create index idx_tournament_pre_reservations_tournament on tournament_pre_reservations (tournament_id);
create index idx_tournament_pre_reservations_player on tournament_pre_reservations (player_id);
create index idx_tournament_pre_reservations_category on tournament_pre_reservations (tournament_category_id);

create trigger trg_validar_categoria_pertenece_al_torneo_prereserva
before insert or update on tournament_pre_reservations
for each row execute function validar_categoria_pertenece_al_torneo();

-- ---------------------------------------------------------
-- Cupo CRUZADO: cuenta inscripciones en línea + pre-reservas
-- activas juntas, para no sobrevender una categoría.
-- ---------------------------------------------------------

create or replace function validar_cupo_categoria_cruzado()
returns trigger as $$
declare
  v_cupo_maximo integer;
  v_total       integer;
begin
  select cupo_maximo into v_cupo_maximo
    from tournament_categories where id = new.tournament_category_id;

  if v_cupo_maximo is not null then
    select
      (select count(*) from tournament_registrations
        where tournament_category_id = new.tournament_category_id and activo = true)
      +
      (select count(*) from tournament_pre_reservations
        where tournament_category_id = new.tournament_category_id and activo = true)
    into v_total;

    if v_total >= v_cupo_maximo then
      raise exception 'Esta categoría ya alcanzó su cupo máximo de % lugares (contando inscripciones en línea y pre-reservas).', v_cupo_maximo;
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_validar_cupo_categoria on tournament_registrations;
create trigger trg_validar_cupo_categoria_cruzado
before insert on tournament_registrations
for each row execute function validar_cupo_categoria_cruzado();

create trigger trg_validar_cupo_categoria_cruzado_prereserva
before insert on tournament_pre_reservations
for each row execute function validar_cupo_categoria_cruzado();

-- ---------------------------------------------------------
-- Vista unificada, para roster/consultas combinadas
-- ---------------------------------------------------------

create view tournament_participantes
with (security_invoker = true) as
select
  id, tournament_id, player_id, tournament_category_id,
  'online'::text as canal,
  'pagado'::text as estatus_pago,
  monto_pagado as monto,
  fecha_pago,
  qr_token,
  activo,
  created_at
from tournament_registrations
union all
select
  id, tournament_id, player_id, tournament_category_id,
  'pre_reserva'::text as canal,
  estatus::text as estatus_pago,
  monto,
  fecha_pago,
  qr_token,
  activo,
  created_at
from tournament_pre_reservations;

comment on view tournament_participantes is 'Unifica inscripciones en línea y pre-reservas para consultas de roster. canal indica el origen; estatus_pago siempre es "pagado" en línea, y varía en pre-reserva.';

grant select on tournament_participantes to authenticated;

-- ---------------------------------------------------------
-- RLS
-- ---------------------------------------------------------

alter table tournament_pre_reservations enable row level security;

create policy tournament_pre_reservations_select on tournament_pre_reservations
  for select to authenticated
  using (
    player_id in (select id from players where auth_user_id = auth.uid())
    or is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

create policy tournament_pre_reservations_insert on tournament_pre_reservations
  for insert to authenticated
  with check (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

create policy tournament_pre_reservations_update on tournament_pre_reservations
  for update to authenticated
  using (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

-- ---------------------------------------------------------
-- GRANTS
-- ---------------------------------------------------------

grant select, insert, update on tournament_pre_reservations to authenticated;
