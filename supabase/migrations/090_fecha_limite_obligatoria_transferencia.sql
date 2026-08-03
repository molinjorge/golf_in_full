-- =========================================================
-- MIGRACIÓN 090
-- Exige fecha_limite_pago cuando modalidad = 'transferencia' —
-- antes solo se autocompletaba para 'pago_dia_evento', pero
-- nunca se exigió capturarla para transferencia, permitiendo
-- reservas sin fecha límite que nunca podrían darse seguimiento.
-- =========================================================

create or replace function ajustar_fecha_limite_pago()
returns trigger as $$
declare
  v_fecha_inicio date;
begin
  select fecha_inicio into v_fecha_inicio from tournaments where id = new.tournament_id;

  if new.modalidad = 'pago_dia_evento' then
    new.fecha_limite_pago := v_fecha_inicio;
  elsif new.modalidad = 'transferencia' and new.fecha_limite_pago is null then
    raise exception 'Debes indicar una fecha límite de pago para una reserva por transferencia.';
  end if;

  if new.fecha_limite_pago is not null and new.fecha_limite_pago > v_fecha_inicio then
    raise exception 'La fecha límite de pago no puede ser posterior a la fecha del torneo (%).', v_fecha_inicio;
  end if;

  return new;
end;
$$ language plpgsql;
