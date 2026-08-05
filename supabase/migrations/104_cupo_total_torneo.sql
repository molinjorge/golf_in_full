-- 104_cupo_total_torneo.sql
--
-- Nueva regla de negocio: el cupo total del torneo (tournaments.cupo_maximo) pasa a ser
-- obligatorio, y se valida ANTES de crear cualquier inscripción confirmada o pre-reserva —
-- sin importar categoría ni forma de pago. Hoy la columna existe pero no la usa ningún
-- trigger (confirmado revisando pg_trigger antes de escribir esta migración); el único
-- techo real que existía era por categoría (validar_cupo_categoria_cruzado, 089/103) o
-- por equipo (validar_cupo_equipo / validar_cupo_equipo_reserva) — nada impedía que la
-- suma de categorías rebasara el cupo físico real acordado con el director del campo.
--
-- Reglas confirmadas antes de escribir el código:
--   1. Se valida ANTES de iniciar el proceso: tanto al crear una inscripción confirmada
--      (tournament_registrations) como al crear una pre-reserva (tournament_pre_reservations).
--   2. El total suma inscripciones confirmadas + pre-reservas activas, SIN filtrar por
--      categoría ni forma de pago (transferencia/día del evento cuentan igual).
--   3. phone_reservations NO cuenta para el total — son personas que aún no están en el
--      catálogo de jugadores; solo cuentan una vez que se conviertan en pre-reserva real
--      o inscripción (momento en que ya caen en una de las dos tablas de arriba).
--   4. El cupo total siempre se expresa en número de JUGADORES, no de equipos — cada fila
--      de tournament_registrations/tournament_pre_reservations ya representa a un jugador
--      individual, así que el conteo no necesita ajuste adicional por tamaño de equipo.
--   5. Ya no debe existir ningún torneo sin cupo_maximo definido — confirmado que hoy
--      ningún torneo real tiene la columna en NULL, así que el candado NOT NULL no rompe
--      datos existentes.

-- 1. El cupo total del torneo deja de ser opcional.
alter table tournaments
  alter column cupo_maximo set not null;

-- 2. Función de validación del cupo total — reutilizable en ambas tablas.
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
        and tournament_registration_id is null)
  into v_total;

  if v_total >= v_cupo_maximo then
    raise exception 'Este torneo ya alcanzó su cupo máximo total de % jugadores (contando inscripciones confirmadas y pre-reservas activas).', v_cupo_maximo;
  end if;

  return new;
end;
$$;

-- 3. Enganchada en tournament_registrations — antes de crear una inscripción confirmada.
create trigger trg_validar_cupo_total_torneo
  before insert on tournament_registrations
  for each row
  execute function validar_cupo_total_torneo();

-- 4. Enganchada en tournament_pre_reservations — antes de crear una pre-reserva.
create trigger trg_validar_cupo_total_torneo_prereserva
  before insert on tournament_pre_reservations
  for each row
  execute function validar_cupo_total_torneo();
