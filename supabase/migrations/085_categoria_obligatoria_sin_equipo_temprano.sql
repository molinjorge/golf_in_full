-- =========================================================
-- MIGRACIÓN 085
-- Adelanta la regla "sin equipo, categoría obligatoria" al
-- momento de CREAR la pre-reserva (phone_reservations,
-- tournament_pre_reservations) — antes solo se validaba hasta
-- el momento de pagar/confirmar, en tournament_registrations,
-- lo cual permitía crear reservas incompletas que fallaban
-- recién al intentar pagarlas.
-- =========================================================

create or replace function validar_categoria_o_equipo_reserva()
returns trigger as $$
begin
  if new.tournament_team_id is null and new.tournament_category_id is null then
    raise exception 'Debes indicar una categoría cuando la reserva queda sin equipo.';
  end if;

  return new;
end;
$$ language plpgsql;

comment on function validar_categoria_o_equipo_reserva is 'Exige categoría cuando no hay equipo asignado — mismo momento de captura, no hasta el pago. Si hay equipo, la categoría es libre (se hereda después, puede quedar NULL aquí sin problema).';

create trigger trg_validar_categoria_o_equipo_phone
before insert or update on phone_reservations
for each row execute function validar_categoria_o_equipo_reserva();

create trigger trg_validar_categoria_o_equipo_prereserva
before insert or update on tournament_pre_reservations
for each row execute function validar_categoria_o_equipo_reserva();
