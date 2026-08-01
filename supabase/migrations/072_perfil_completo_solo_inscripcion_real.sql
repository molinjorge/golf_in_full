-- =========================================================
-- MIGRACIÓN 072
-- La exigencia de "perfil completo" (fecha de nacimiento y
-- teléfono) debe aplicar solo al confirmar una inscripción real
-- (tournament_registrations) — no al crear una pre-reserva
-- (tournament_pre_reservations), que es justamente un compromiso
-- provisional y puede convivir con un perfil incompleto hasta
-- que se confirme el pago real.
-- =========================================================

drop trigger if exists trg_validar_perfil_completo_prereservations on tournament_pre_reservations;

comment on function validar_perfil_completo_trigger is 'Exige perfil completo (fecha_nacimiento, teléfono) antes de una inscripción real. Ya NO aplica a tournament_pre_reservations — solo a tournament_registrations, donde la validación sigue activa.';
