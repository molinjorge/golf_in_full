-- =========================================================
-- MIGRACIÓN 014
-- Elimina las columnas de texto libre ciudad/estado en clubs,
-- ahora que la ubicación vive normalizada vía city_id
-- (clubs -> cities -> states -> countries).
-- =========================================================

alter table clubs drop column ciudad;
alter table clubs drop column estado;
