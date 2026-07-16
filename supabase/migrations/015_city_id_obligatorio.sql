-- =========================================================
-- MIGRACIÓN 015
-- Hace obligatorio clubs.city_id.
--
-- IMPORTANTE: correr esto DESPUÉS de borrar/corregir cualquier
-- club que no tenga city_id asignado (por ejemplo, el club de
-- prueba). Si queda alguna fila con city_id nulo, esta migración
-- se detiene con un mensaje claro en vez de fallar con un error
-- críptico de constraint.
-- =========================================================

DO $$
DECLARE
  v_pendientes integer;
BEGIN
  SELECT count(*) INTO v_pendientes FROM clubs WHERE city_id IS NULL;
  IF v_pendientes > 0 THEN
    RAISE EXCEPTION 'Hay % club(es) sin city_id asignado. Asígnales una ciudad o bórralos antes de correr esta migración.', v_pendientes;
  END IF;
END $$;

alter table clubs alter column city_id set not null;
