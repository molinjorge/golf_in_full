-- =========================================================
-- MIGRACIÓN 079 — INSCRIPCIÓN POR EQUIPOS, FASE 1
-- Estructura base: equipos, categoría heredada por el equipo
-- (o ninguna, si el torneo no maneja categorías), jugador "sin
-- equipo" funcionando igual que una inscripción individual.
-- El cupo por categoría deja de aplicar en torneos de equipos.
-- =========================================================

create table tournament_teams (
  id                       uuid        primary key default gen_random_uuid(),
  tournament_id            uuid        not null references tournaments (id) on delete restrict,
  nombre_equipo            text        not null,
  tournament_category_id   uuid        references tournament_categories (id) on delete restrict,

  activo                   boolean     not null default true,
  fecha_baja               timestamptz,
  dado_de_baja_por         uuid        references admin_users (id) on delete restrict,
  motivo_baja              text,

  created_by               uuid        references admin_users (id) on delete restrict,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

comment on table tournament_teams is 'Equipo dentro de un torneo por equipos. tournament_category_id es opcional — null si el torneo no maneja categorías.';

create trigger trg_tournament_teams_updated_at
before update on tournament_teams
for each row execute function set_updated_at();

create trigger trg_track_estatus_tournament_teams
before update on tournament_teams
for each row execute function track_estatus_activo();

create trigger trg_audit_tournament_teams
after insert or update or delete on tournament_teams
for each row execute function log_audit();

create trigger trg_validar_categoria_pertenece_al_torneo_teams
before insert or update on tournament_teams
for each row
when (new.tournament_category_id is not null)
execute function validar_categoria_pertenece_al_torneo();

create unique index tournament_teams_nombre_unico_activo
  on tournament_teams (tournament_id, nombre_equipo)
  where activo = true;

create index idx_tournament_teams_tournament on tournament_teams (tournament_id);

alter table tournament_registrations
  add column tournament_team_id uuid references tournament_teams (id) on delete restrict;

alter table tournament_registrations
  alter column tournament_category_id drop not null;

comment on column tournament_registrations.tournament_team_id is 'Equipo al que pertenece esta inscripción. NULL en torneos individuales, o en un jugador "sin equipo" dentro de un torneo por equipos.';
comment on column tournament_registrations.tournament_category_id is 'Obligatoria si tournament_team_id es NULL. Si tournament_team_id tiene valor, se copia automáticamente de tournament_teams.tournament_category_id.';

create or replace function validar_categoria_registro_equipo()
returns trigger as $$
declare
  v_categoria_equipo      uuid;
  v_tournament_del_equipo uuid;
  v_tiene_categorias      boolean;
begin
  if new.tournament_team_id is not null then
    select tournament_category_id, tournament_id
      into v_categoria_equipo, v_tournament_del_equipo
      from tournament_teams where id = new.tournament_team_id;

    if v_tournament_del_equipo is distinct from new.tournament_id then
      raise exception 'El equipo seleccionado no pertenece a este torneo.';
    end if;

    new.tournament_category_id := v_categoria_equipo;
  else
    -- Solo se exige categoría si el torneo realmente tiene
    -- categorías asignadas. Si el torneo es de categoría única
    -- (sin ninguna fila en tournament_categories), se deja vacía.
    select exists (
      select 1 from tournament_categories where tournament_id = new.tournament_id
    ) into v_tiene_categorias;

    if v_tiene_categorias and new.tournament_category_id is null then
      raise exception 'Debes elegir una categoría cuando te inscribes sin equipo.';
    end if;

    if not v_tiene_categorias then
      new.tournament_category_id := null;
    end if;

    -- Confirmar que la categoría enviada (si la hay) sí pertenezca
    -- a este torneo específico — validación que existía en el
    -- trigger viejo y que hay que conservar.
    if new.tournament_category_id is not null then
      if not exists (
        select 1 from tournament_categories
         where id = new.tournament_category_id
           and tournament_id = new.tournament_id
      ) then
        raise exception 'La categoría elegida no pertenece a este torneo.';
      end if;
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validar_categoria_registro_equipo
before insert or update on tournament_registrations
for each row execute function validar_categoria_registro_equipo();

drop trigger if exists trg_validar_categoria_pertenece_al_torneo on tournament_registrations;

create or replace function validar_cupo_equipo()
returns trigger as $$
declare
  v_jugadores_por_equipo integer;
  v_miembros_actuales    integer;
begin
  if new.tournament_team_id is not null then
    select jugadores_por_equipo into v_jugadores_por_equipo
      from tournaments where id = new.tournament_id;

    select count(*) into v_miembros_actuales
      from tournament_registrations
     where tournament_team_id = new.tournament_team_id
       and activo = true;

    if v_miembros_actuales >= v_jugadores_por_equipo then
      raise exception 'Este equipo ya está completo (% de % lugares).', v_miembros_actuales, v_jugadores_por_equipo;
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validar_cupo_equipo
before insert on tournament_registrations
for each row execute function validar_cupo_equipo();

create or replace function validar_cupo_categoria_cruzado()
returns trigger as $$
declare
  v_cupo_maximo integer;
  v_total       integer;
  v_tipo_participacion formato_juego_torneo;
begin
  if new.tournament_category_id is null then
    return new;
  end if;

  select tf.tipo_participacion into v_tipo_participacion
    from tournaments t
    join tournament_formats tf on tf.id = t.tournament_format_id
   where t.id = new.tournament_id;

  if v_tipo_participacion = 'equipo' then
    return new;
  end if;

  select cupo_maximo into v_cupo_maximo
    from tournament_categories where id = new.tournament_category_id;

  if v_cupo_maximo is not null then
    select
      (select count(*) from tournament_registrations
        where tournament_category_id = new.tournament_category_id and activo = true)
      +
      (select count(*) from tournament_pre_reservations
        where tournament_category_id = new.tournament_category_id
          and activo = true
          and tournament_registration_id is null)
    into v_total;

    if v_total >= v_cupo_maximo then
      raise exception 'Esta categoría ya alcanzó su cupo máximo de % lugares (contando inscripciones en línea y pre-reservas).', v_cupo_maximo;
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

create view tournament_equipos_incompletos
with (security_invoker = true) as
select
  tt.id,
  tt.tournament_id,
  tt.nombre_equipo,
  tt.tournament_category_id,
  t.jugadores_por_equipo,
  count(tr.id) filter (where tr.activo = true) as miembros_actuales
from tournament_teams tt
join tournaments t on t.id = tt.tournament_id
left join tournament_registrations tr on tr.tournament_team_id = tt.id
where tt.activo = true
group by tt.id, tt.tournament_id, tt.nombre_equipo, tt.tournament_category_id, t.jugadores_por_equipo
having count(tr.id) filter (where tr.activo = true) < t.jugadores_por_equipo;

comment on view tournament_equipos_incompletos is 'Equipos que todavía tienen lugares disponibles.';

grant select on tournament_equipos_incompletos to authenticated, anon;

alter table tournament_teams enable row level security;

create policy tournament_teams_select on tournament_teams
  for select to public using (true);

create policy tournament_teams_insert on tournament_teams
  for insert to authenticated
  with check (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

create policy tournament_teams_update on tournament_teams
  for update to authenticated
  using (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

grant select on tournament_teams to anon;
grant select, insert, update on tournament_teams to authenticated;

create or replace function reasignar_jugador_a_equipo(
  p_tournament_registration_id uuid,
  p_nuevo_tournament_team_id   uuid
)
returns tournament_registrations
security definer
set search_path = public
as $$
declare
  v_registro   tournament_registrations;
  v_autorizado boolean;
  v_resultado  tournament_registrations;
begin
  select * into v_registro from tournament_registrations where id = p_tournament_registration_id;

  if v_registro.id is null then
    raise exception 'No existe esa inscripción.';
  end if;

  v_autorizado := is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), v_registro.tournament_id)
    or exists (select 1 from tournaments t where t.id = v_registro.tournament_id and is_club_admin(auth.uid(), t.club_id));

  if not v_autorizado then
    raise exception 'No tienes permiso para reasignar jugadores en este torneo.';
  end if;

  update tournament_registrations
     set tournament_team_id = p_nuevo_tournament_team_id
   where id = p_tournament_registration_id
  returning * into v_resultado;

  return v_resultado;
end;
$$ language plpgsql;

comment on function reasignar_jugador_a_equipo is 'Permite al organizador/superadmin/club_admin mover a un jugador ya inscrito a otro equipo, o dejarlo sin equipo. Dispara automáticamente la herencia de categoría.';

grant execute on function reasignar_jugador_a_equipo(uuid, uuid) to authenticated;
