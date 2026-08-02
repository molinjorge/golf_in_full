-- =========================================================
-- MIGRACIÓN 086
-- Datos de membresía de club, opcionales — para integrar en una
-- fase futura la tarifa de socios en el momento del pago (torneos
-- en el campo de su propio club, y eventualmente clubes "amigos"
-- con tarifa recíproca). Por ahora, solo se captura el dato.
-- =========================================================

alter table players
  add column club_id           uuid references clubs (id) on delete restrict,
  add column numero_membresia  text;

comment on column players.club_id is 'Club de golf del que el jugador es socio (opcional). Referencia a clubs, no a campos_golf — la membresía es con el club como entidad, que puede operar varios campos.';
comment on column players.numero_membresia is 'Número de membresía del jugador en club_id (opcional). Sin formato validado por ahora.';
