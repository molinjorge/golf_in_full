-- =========================================================
-- MIGRACIÓN 042
-- Tarifas del torneo: individual (siempre aplica) y equipo
-- completo (solo aplica si la modalidad es de equipo).
-- =========================================================

alter table tournaments
  add column tarifa_individual       numeric(10,2) not null default 0,
  add column tarifa_equipo_completo  numeric(10,2),
  add column moneda                  text not null default 'MXN';

alter table tournaments
  add constraint tournaments_tarifa_individual_valida check (tarifa_individual >= 0),
  add constraint tournaments_tarifa_equipo_valida check (tarifa_equipo_completo is null or tarifa_equipo_completo >= 0);

comment on column tournaments.tarifa_individual is 'Costo de inscripción por jugador individual (siempre aplica, incluido alguien inscribiéndose solo en un torneo de equipos, buscando compañero).';
comment on column tournaments.tarifa_equipo_completo is 'Costo de inscribir un equipo ya conformado completo. Solo puede tener valor si la modalidad del torneo es de equipo.';

-- Reutiliza y amplía la misma función que ya valida
-- jugadores_por_equipo, para no duplicar la consulta a
-- tournament_formats — ahora también valida la tarifa de equipo.
create or replace function validar_jugadores_por_equipo()
returns trigger as $$
declare
  v_categoria formato_juego_torneo;
begin
  select tipo_participacion into v_categoria from tournament_formats where id = new.tournament_format_id;

  if v_categoria = 'individual' then
    if new.jugadores_por_equipo is not null then
      raise exception 'jugadores_por_equipo debe quedar vacío cuando la modalidad es individual.';
    end if;
    if new.tarifa_equipo_completo is not null then
      raise exception 'tarifa_equipo_completo debe quedar vacía cuando la modalidad es individual.';
    end if;
  elsif v_categoria = 'equipo' then
    if new.jugadores_por_equipo is null then
      raise exception 'Debes especificar jugadores_por_equipo cuando la modalidad es de equipo.';
    end if;
  end if;

  return new;
end;
$$ language plpgsql;
