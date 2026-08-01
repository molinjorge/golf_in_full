-- =========================================================
-- MIGRACIÓN 074
-- Bandera para no reenviar el correo de confirmación de
-- pre-reserva por accidente. Mismo patrón que el resto del
-- proyecto.
-- =========================================================

alter table tournament_pre_reservations
  add column correo_confirmacion_enviado boolean not null default false;

comment on column tournament_pre_reservations.correo_confirmacion_enviado is 'true una vez que se envió el correo de confirmación de pre-reserva al jugador. Evita reenvíos duplicados.';
