-- =========================================================
-- MIGRACIÓN 037
-- tournaments.numero_rondas: cuántas rondas tendrá el torneo,
-- declarado desde su creación. El frontend debe usarlo para
-- generar automáticamente esa cantidad de filas en
-- tournament_rounds (con fechas sugeridas y el campo del
-- torneo ya precargado), en vez de que el comité las agregue
-- una por una a ciegas.
--
-- No se sincroniza a la fuerza con el conteo real de
-- tournament_rounds después de creado — es el valor inicial de
-- planeación; las rondas reales siguen siendo la fuente de verdad
-- una vez que existen (se pueden agregar/desactivar después).
-- =========================================================

alter table tournaments
  add column numero_rondas integer not null default 1;

alter table tournaments
  add constraint tournaments_numero_rondas_positivo
  check (numero_rondas > 0);

comment on column tournaments.numero_rondas is 'Cantidad de rondas declarada al crear el torneo. Se usa para generar automáticamente esa cantidad de filas en tournament_rounds. No se mantiene sincronizado por la fuerza después — tournament_rounds es la fuente de verdad una vez que las rondas existen.';
