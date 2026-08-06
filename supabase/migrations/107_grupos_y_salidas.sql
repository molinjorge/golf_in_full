-- 107_grupos_y_salidas.sql
--
-- Nuevo módulo: arma los grupos de salida de una ronda (quién juega junto, a qué hora,
-- en qué hoyo), paso siguiente después de inscripciones/cupos, según el proceso oficial
-- del R&A Committee Procedures (establecer y publicar el sorteo/grupos y los horarios
-- de salida antes de la competencia).
--
-- Decisiones de diseño confirmadas antes de escribir el código:
--   1. "Grupo" (logística de salida) y "equipo" (unidad de competencia/puntuación,
--      tournament_teams) son conceptos independientes. En torneos de equipo, el grupo
--      de salida SIEMPRE es el equipo completo, sin mezclar con otros equipos — por
--      eso no hace falta tournament_group_players en modo equipo, los jugadores del
--      grupo ya se resuelven vía tournament_registrations.tournament_team_id.
--   2. El formato de salida (tee_times / shotgun) es una propiedad de la RONDA, no del
--      torneo completo — un torneo de varias rondas podría en teoría cambiar de formato
--      entre un día y otro.
--   3. Cada grupo tiene tanto hora_salida como hoyo (vía hoyo_id, hereda el par real del
--      campo). Lo que varía entre grupos de un mismo turno depende del formato:
--        - tee_times: mismo hoyo (normalmente el 1), hora_salida distinta por grupo.
--        - shotgun: misma hora_salida (la del arranque), hoyo_id distinto por grupo.
--   4. Doble salida (dos grupos "A"/"B" en el mismo hoyo) SOLO se permite en hoyos par 4
--      o par 5 — nunca en par 3, por el cuello de botella físico que se genera ahí
--      (el green es el área de aterrizaje, no hay forma de que el segundo grupo espere
--      sin bloquear a los demás). Confirmado contra fuentes oficiales del formato shotgun.
--   5. Tamaño máximo de grupo, configurable por torneo, NO es un número fijo global:
--        - Individual: tournaments.jugadores_por_grupo (nuevo, default 4).
--        - Equipo: hereda tournaments.jugadores_por_equipo (ya existente, 018) — el
--          grupo siempre es el equipo completo.
--   6. Un jugador/equipo puede estar en un grupo distinto en cada ronda del torneo — la
--      restricción de "no repetir" aplica por RONDA, no por torneo completo.
--   7. Fase 1: solo armado MANUAL (crear/editar grupos uno por uno). La sugerencia
--      automática de grupos queda como fase futura, no se construye aquí.

-- 1. Tamaño de grupo para torneos individuales (equivalente a jugadores_por_equipo, 018).
alter table tournaments
  add column jugadores_por_grupo integer not null default 4;

-- 2. Formato de salida de la ronda. Nullable: una ronda puede existir antes de decidir
--    su formato; se exige recién al intentar crear el primer grupo (ver trigger más abajo).
create type formato_salida_ronda as enum ('tee_times', 'shotgun');

alter table tournament_rounds
  add column formato_salida formato_salida_ronda;

-- 3. Grupos de salida.
create table tournament_groups (
  id uuid primary key default gen_random_uuid(),
  tournament_round_shift_id uuid not null references tournament_round_shifts(id),
  hoyo_id uuid not null references hoyos(id),
  hora_salida timestamptz not null,
  etiqueta text,  -- 'A' / 'B' cuando hay doble salida en el mismo hoyo; opcional
  tournament_team_id uuid references tournament_teams(id),  -- obligatorio solo en modo equipo
  activo boolean not null default true,
  fecha_baja timestamptz,
  dado_de_baja_por uuid,
  motivo_baja text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 4. Jugadores del grupo — SOLO se usa en modo individual (en modo equipo, los jugadores
--    del grupo ya están definidos por tournament_registrations.tournament_team_id).
create table tournament_group_players (
  id uuid primary key default gen_random_uuid(),
  tournament_group_id uuid not null references tournament_groups(id),
  tournament_registration_id uuid not null references tournament_registrations(id),
  orden_en_grupo smallint,
  created_at timestamptz not null default now()
);

create trigger trg_tournament_groups_updated_at
  before update on tournament_groups
  for each row
  execute function set_updated_at();

-- 5. El hoyo del grupo debe pertenecer al mismo campo donde se juega la ronda.
create or replace function validar_hoyo_pertenece_a_campo_ronda()
returns trigger
language plpgsql
as $$
declare
  v_campo_ronda uuid;
  v_campo_hoyo  uuid;
begin
  select tr.campo_golf_id into v_campo_ronda
    from tournament_round_shifts trs
    join tournament_rounds tr on tr.id = trs.tournament_round_id
   where trs.id = new.tournament_round_shift_id;

  select campo_golf_id into v_campo_hoyo
    from hoyos where id = new.hoyo_id;

  if v_campo_hoyo is distinct from v_campo_ronda then
    raise exception 'El hoyo seleccionado no pertenece al campo de golf de esta ronda.';
  end if;

  return new;
end;
$$;

create trigger trg_validar_hoyo_pertenece_a_campo_ronda
  before insert or update on tournament_groups
  for each row
  execute function validar_hoyo_pertenece_a_campo_ronda();

-- 6. Formato de salida definido, y doble salida solo en hoyos par 4/5.
create or replace function validar_formato_salida_y_doble_hoyo()
returns trigger
language plpgsql
as $$
declare
  v_formato_salida formato_salida_ronda;
  v_par             integer;
  v_grupos_en_hoyo  integer;
begin
  select tr.formato_salida into v_formato_salida
    from tournament_round_shifts trs
    join tournament_rounds tr on tr.id = trs.tournament_round_id
   where trs.id = new.tournament_round_shift_id;

  if v_formato_salida is null then
    raise exception 'Esta ronda todavía no tiene definido su formato de salida (tee_times o shotgun). Defínelo antes de crear grupos.';
  end if;

  select count(*) into v_grupos_en_hoyo
    from tournament_groups
   where tournament_round_shift_id = new.tournament_round_shift_id
     and hoyo_id = new.hoyo_id
     and activo = true
     and id is distinct from new.id;

  if v_grupos_en_hoyo > 0 then
    select par into v_par from hoyos where id = new.hoyo_id;

    if v_par not in (4, 5) then
      raise exception 'No se puede asignar más de un grupo a este hoyo: es par %, y la doble salida solo es válida en hoyos par 4 o par 5 (en par 3 el green es el área de aterrizaje y genera un cuello de botella).', v_par;
    end if;
  end if;

  return new;
end;
$$;

create trigger trg_validar_formato_salida_y_doble_hoyo
  before insert or update on tournament_groups
  for each row
  execute function validar_formato_salida_y_doble_hoyo();

-- 7. tournament_team_id obligatorio solo si el torneo es de formato equipo; prohibido
--    si es individual (en individual, los jugadores van por tournament_group_players).
create or replace function validar_team_id_segun_formato_torneo()
returns trigger
language plpgsql
as $$
declare
  v_tipo_participacion formato_juego_torneo;
begin
  select tf.tipo_participacion into v_tipo_participacion
    from tournament_round_shifts trs
    join tournament_rounds tr on tr.id = trs.tournament_round_id
    join tournaments t on t.id = tr.tournament_id
    join tournament_formats tf on tf.id = t.tournament_format_id
   where trs.id = new.tournament_round_shift_id;

  if v_tipo_participacion = 'equipo' and new.tournament_team_id is null then
    raise exception 'Este torneo es de equipos: todo grupo debe tener un tournament_team_id asignado.';
  end if;

  if v_tipo_participacion is distinct from 'equipo' and new.tournament_team_id is not null then
    raise exception 'Este torneo es individual: los grupos no deben tener tournament_team_id (los jugadores se asignan vía tournament_group_players).';
  end if;

  return new;
end;
$$;

create trigger trg_validar_team_id_segun_formato_torneo
  before insert or update on tournament_groups
  for each row
  execute function validar_team_id_segun_formato_torneo();

-- 8. Un equipo no puede estar en más de un grupo dentro de la misma ronda.
create or replace function validar_equipo_unico_por_ronda()
returns trigger
language plpgsql
as $$
declare
  v_round_id  uuid;
  v_conflicto integer;
begin
  if new.tournament_team_id is null then
    return new;
  end if;

  select tr.id into v_round_id
    from tournament_round_shifts trs
    join tournament_rounds tr on tr.id = trs.tournament_round_id
   where trs.id = new.tournament_round_shift_id;

  select count(*) into v_conflicto
    from tournament_groups g
    join tournament_round_shifts trs on trs.id = g.tournament_round_shift_id
    join tournament_rounds tr on tr.id = trs.tournament_round_id
   where tr.id = v_round_id
     and g.tournament_team_id = new.tournament_team_id
     and g.activo = true
     and g.id is distinct from new.id;

  if v_conflicto > 0 then
    raise exception 'Este equipo ya tiene un grupo asignado en esta ronda.';
  end if;

  return new;
end;
$$;

create trigger trg_validar_equipo_unico_por_ronda
  before insert or update on tournament_groups
  for each row
  execute function validar_equipo_unico_por_ronda();

-- 9. Tamaño máximo del grupo (individual) y jugador único por ronda.
create or replace function validar_grupo_individual()
returns trigger
language plpgsql
as $$
declare
  v_round_id          uuid;
  v_jugadores_por_grupo integer;
  v_total_en_grupo    integer;
  v_conflicto_ronda   integer;
begin
  select tr.id, t.jugadores_por_grupo
    into v_round_id, v_jugadores_por_grupo
    from tournament_groups g
    join tournament_round_shifts trs on trs.id = g.tournament_round_shift_id
    join tournament_rounds tr on tr.id = trs.tournament_round_id
    join tournaments t on t.id = tr.tournament_id
   where g.id = new.tournament_group_id;

  -- Tamaño máximo del grupo.
  select count(*) into v_total_en_grupo
    from tournament_group_players
   where tournament_group_id = new.tournament_group_id
     and id is distinct from new.id;

  if v_total_en_grupo >= v_jugadores_por_grupo then
    raise exception 'Este grupo ya alcanzó su máximo de % jugadores.', v_jugadores_por_grupo;
  end if;

  -- El jugador no puede estar en dos grupos de la misma ronda.
  select count(*) into v_conflicto_ronda
    from tournament_group_players gp
    join tournament_groups g on g.id = gp.tournament_group_id
    join tournament_round_shifts trs on trs.id = g.tournament_round_shift_id
    join tournament_rounds tr on tr.id = trs.tournament_round_id
   where tr.id = v_round_id
     and gp.tournament_registration_id = new.tournament_registration_id
     and gp.id is distinct from new.id;

  if v_conflicto_ronda > 0 then
    raise exception 'Este jugador ya está asignado a otro grupo en esta ronda.';
  end if;

  return new;
end;
$$;

create trigger trg_validar_grupo_individual
  before insert or update on tournament_group_players
  for each row
  execute function validar_grupo_individual();
