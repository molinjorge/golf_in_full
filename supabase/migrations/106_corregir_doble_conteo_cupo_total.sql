-- 106_corregir_doble_conteo_cupo_total.sql
--
-- Corrección de bug real: al confirmar el pago de una inscripción, validar_cupo_total_torneo()
-- (104) contaba la propia pre-reserva del jugador que se está inscribiendo como una persona
-- aparte, además de la inscripción que se está creando en ese mismo instante — porque el
-- vínculo tournament_pre_reservations.tournament_registration_id se establece DESPUÉS del
-- insert en tournament_registrations, no antes. Una misma persona contaba doble justo en el
-- momento de conversión pre-reserva → inscripción, bloqueando el último lugar disponible
-- del cupo aunque en realidad sí hubiera espacio.
--
-- Caso real detectado: torneo a63d5c86-71f2-4e9b-a17d-ce24726bb970, cupo_maximo = 20, con
-- 19 inscripciones confirmadas + la pre-reserva de Noriega (jugador #20, sin
-- tournament_registration_id todavía) sumaban 20 — el trigger rechazó su propia conversión
-- a inscripción por "cupo ya alcanzado", cuando en realidad debía ser el jugador #20, no el #21.
--
-- Fix: al contar pre-reservas activas sin convertir, se excluye la del propio jugador que
-- se está insertando (new.player_id) — esa pre-reserva específica es la que se está
-- convirtiendo en esta misma inscripción, no una persona adicional.

create or replace function validar_cupo_total_torneo()
returns trigger
language plpgsql
as $$
declare
  v_cupo_maximo integer;
  v_total       integer;
begin
  select cupo_maximo into v_cupo_maximo
    from tournaments where id = new.tournament_id;

  select
    (select count(*) from tournament_registrations
      where tournament_id = new.tournament_id and activo = true)
    +
    (select count(*) from tournament_pre_reservations
      where tournament_id = new.tournament_id
        and activo = true
        and tournament_registration_id is null
        and player_id is distinct from new.player_id)
  into v_total;

  if v_total >= v_cupo_maximo then
    raise exception 'Este torneo ya alcanzó su cupo máximo total de % jugadores (contando inscripciones confirmadas y pre-reservas activas).', v_cupo_maximo;
  end if;

  return new;
end;
$$;

-- Mismo patrón de bug, mismo fix: validar_cupo_categoria_cruzado() (089/103) contaba la
-- propia pre-reserva del jugador que se está insertando como una persona aparte de su
-- propia inscripción — latente hasta hoy porque ninguna categoría de prueba tenía
-- cupo_maximo configurado, pero listo para fallar en cuanto alguna lo tuviera.

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
          and tournament_registration_id is null
          and player_id is distinct from new.player_id)
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

