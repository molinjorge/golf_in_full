-- =========================================================
-- MIGRACIÓN 059
-- Hora del escopetazo, en la información para el jugador.
-- =========================================================

alter table tournament_marketing_info
  add column hora_escopetazo time;

comment on column tournament_marketing_info.hora_escopetazo is 'Hora de salida en escopetazo (todos los grupos arrancan a la vez). Opcional — no todos los torneos usan este formato de salida.';
