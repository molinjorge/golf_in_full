-- 103_incluir_phone_reservations_cupo_categoria.sql
--
-- Corrección de bug real: validar_cupo_categoria_cruzado() (individual por categoría)
-- no contaba las reservas telefónicas (phone_reservations) al validar el cupo máximo
-- de una categoría, a diferencia de ocupacion_actual_equipo() (equipos), que sí las
-- suma. phone_reservations.tournament_category_id existe desde su creación (migración 070),
-- así que sí es posible tener una reserva telefónica ligada a una categoría individual —
-- la omisión dejaba pasar inscripciones por encima del cupo real cuando había reservas
-- telefónicas activas sin contar.
--
-- Detectado durante la prueba 4 (cupos), agosto 2026, al comparar el código real de
-- ambas funciones antes de construir el modal de disponibilidad para el organizador.
--
-- Mismo patrón de conteo que ya usa ocupacion_actual_equipo(): solo se filtra por
-- activo = true. No se excluye por convertida_a_pre_reserva_id porque, según la
-- migración 070, al convertirse una reserva telefónica en pre-reserva real, la reserva
-- telefónica original se cancela (activo = false) — el filtro activo = true ya evita
-- el doble conteo por sí solo.

create or replace function validar_cupo_categoria_cruzado()
returns trigger
language plpgsql
as $$
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
      +
      (select count(*) from phone_reservations
        where tournament_category_id = new.tournament_category_id and activo = true)
    into v_total;

    if v_total >= v_cupo_maximo then
      raise exception 'Esta categoría ya alcanzó su cupo máximo de % lugares (contando inscripciones en línea, pre-reservas y reservas telefónicas).', v_cupo_maximo;
    end if;
  end if;

  return new;
end;
$$;
