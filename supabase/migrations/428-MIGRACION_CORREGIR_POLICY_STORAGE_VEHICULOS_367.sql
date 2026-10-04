BEGIN;

ALTER POLICY acceso_campo_vehiculos_insert_367
ON storage.objects
TO anon;

COMMIT;
