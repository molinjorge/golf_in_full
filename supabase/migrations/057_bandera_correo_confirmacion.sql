-- =========================================================
-- MIGRACIÓN 057
-- Bandera para no mandar el correo de confirmación de
-- inscripción más de una vez por error. Mismo patrón que
-- correo_abandono_enviado en payment_attempts.
-- =========================================================

alter table tournament_registrations
  add column correo_confirmacion_enviado boolean not null default false;

comment on column tournament_registrations.correo_confirmacion_enviado is 'true una vez que se envió el correo de confirmación de inscripción al jugador. Evita reenvíos duplicados.';
