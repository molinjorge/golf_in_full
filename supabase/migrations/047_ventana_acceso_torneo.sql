-- =========================================================
-- MIGRACIÓN 047
-- Ventana de acceso del torneo (fecha/hora de inicio y fin) —
-- compartida por todas las inscripciones, no una por jugador.
-- Es la base contra la que se validará cada QR de acceso,
-- cuando se construya tournament_registrations.
-- =========================================================

alter table tournaments
  add column acceso_fecha_hora_inicio timestamptz,
  add column acceso_fecha_hora_fin    timestamptz;

comment on column tournaments.acceso_fecha_hora_inicio is 'Desde cuándo son válidos los QR de acceso de este torneo (compartido por todas las inscripciones).';
comment on column tournaments.acceso_fecha_hora_fin is 'Hasta cuándo son válidos los QR de acceso de este torneo.';

alter table tournaments
  add constraint tournaments_ventana_acceso_valida
  check (
    acceso_fecha_hora_inicio is null
    or acceso_fecha_hora_fin is null
    or acceso_fecha_hora_fin >= acceso_fecha_hora_inicio
  );
