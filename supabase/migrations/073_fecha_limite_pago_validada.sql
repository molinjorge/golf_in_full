-- =========================================================
-- MIGRACIÓN 073
-- 1) fecha_limite_pago pasa de timestamptz a date (solo fecha,
--    sin hora) en tournament_pre_reservations y phone_reservations.
-- 2) No puede ser posterior a tournaments.fecha_inicio.
-- 3) Si modalidad = 'pago_dia_evento', se autocompleta con
--    tournaments.fecha_inicio — no se captura a mano.
-- =========================================================

alter table tournament_pre_reservations
  alter column fecha_limite_pago type date using fecha_limite_pago::date;

alter table phone_reservations
  alter column fecha_limite_pago type date using fecha_limite_pago::date;

create or replace function ajustar_fecha_limite_pago()
returns trigger as $$
declare
  v_fecha_inicio date;
begin
  select fecha_inicio into v_fecha_inicio from tournaments where id = new.tournament_id;

  if new.modalidad = 'pago_dia_evento' then
    new.fecha_limite_pago := v_fecha_inicio;
  end if;

  if new.fecha_limite_pago is not null and new.fecha_limite_pago > v_fecha_inicio then
    raise exception 'La fecha límite de pago no puede ser posterior a la fecha del torneo (%).', v_fecha_inicio;
  end if;

  return new;
end;
$$ language plpgsql;

comment on function ajustar_fecha_limite_pago is 'Si modalidad=pago_dia_evento, autocompleta fecha_limite_pago con la fecha del torneo. En cualquier caso, valida que no sea posterior a esa fecha.';

create trigger trg_ajustar_fecha_limite_pago_prereserva
before insert or update on tournament_pre_reservations
for each row execute function ajustar_fecha_limite_pago();

create trigger trg_ajustar_fecha_limite_pago_phone
before insert or update on phone_reservations
for each row execute function ajustar_fecha_limite_pago();
