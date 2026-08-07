-- 113_validar_cupo_turnos_no_exceda_torneo.sql
--
-- Bug real detectado: no existía ninguna validación de que la suma de
-- tournament_round_shifts.cupo_maximo (turnos) de una misma ronda no excediera
-- tournaments.cupo_maximo (el techo total del torneo, validado por 104). Caso real:
-- torneo con cupo_maximo=50, turno 1 con cupo 20 y turno 2 creado con cupo 40 —
-- suman 60, por encima del total permitido, y el sistema lo dejó pasar sin aviso.
--
-- Validación: al crear o editar un turno, la suma de cupo_maximo de todos los turnos
-- ACTIVOS de esa misma ronda (incluyendo el que se está guardando) no puede exceder
-- tournaments.cupo_maximo del torneo al que pertenece esa ronda.

create or replace function validar_cupo_turnos_no_exceda_torneo()
returns trigger
language plpgsql
as $$
declare
  v_cupo_torneo   integer;
  v_suma_turnos   integer;
begin
  select t.cupo_maximo into v_cupo_torneo
    from tournament_rounds tr
    join tournaments t on t.id = tr.tournament_id
   where tr.id = new.tournament_round_id;

  select coalesce(sum(cupo_maximo), 0) into v_suma_turnos
    from tournament_round_shifts
   where tournament_round_id = new.tournament_round_id
     and activo = true
     and id is distinct from new.id;

  if new.activo then
    v_suma_turnos := v_suma_turnos + coalesce(new.cupo_maximo, 0);
  end if;

  if v_suma_turnos > v_cupo_torneo then
    raise exception 'La suma de cupos de los turnos de esta ronda (%) excede el cupo máximo del torneo (%). Ajusta el cupo de este turno o el de otro turno de la misma ronda.', v_suma_turnos, v_cupo_torneo;
  end if;

  return new;
end;
$$;

create trigger trg_validar_cupo_turnos_no_exceda_torneo
  before insert or update on tournament_round_shifts
  for each row
  execute function validar_cupo_turnos_no_exceda_torneo();
