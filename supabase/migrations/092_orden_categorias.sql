-- =========================================================
-- MIGRACIÓN 092
-- Orden de presentación estándar de categorías — mismo patrón
-- que ya usamos para marcas de salida y métodos de desempate.
-- Los valores reales se cargan en una migración aparte, una vez
-- confirmado el orden exacto con el usuario.
-- =========================================================

alter table categories
  add column display_order integer;

comment on column categories.display_order is 'Orden de presentación estándar: primero categorías de caballeros, luego damas, luego única. Debe respetarse en todas las pantallas (catálogo, selectores de inscripción/pre-reserva, configuración de torneo).';
