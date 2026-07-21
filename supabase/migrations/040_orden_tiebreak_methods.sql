-- =========================================================
-- MIGRACIÓN 040
-- Agrega orden de presentación a tiebreak_methods (ya creada y
-- sembrada en la migración 031, sin columna de orden todavía).
-- =========================================================

alter table tiebreak_methods add column display_order integer;

update tiebreak_methods set display_order = 1 where code = 'MUERTE_SUBITA';
update tiebreak_methods set display_order = 2 where code = 'TARJETA_ULTIMO_HOYO';
update tiebreak_methods set display_order = 3 where code = 'TARJETA_ULTIMOS_3';
update tiebreak_methods set display_order = 4 where code = 'TARJETA_ULTIMOS_6';
update tiebreak_methods set display_order = 5 where code = 'TARJETA_ULTIMOS_9';
update tiebreak_methods set display_order = 6 where code = 'TARJETA_18';
update tiebreak_methods set display_order = 7 where code = 'SORTEO';

alter table tiebreak_methods alter column display_order set not null;

comment on column tiebreak_methods.display_order is 'Orden sugerido de presentación: Muerte Súbita, luego tarjeta de menor a mayor tramo (último hoyo -> 3 -> 6 -> 9 -> 18), y Sorteo al final.';
