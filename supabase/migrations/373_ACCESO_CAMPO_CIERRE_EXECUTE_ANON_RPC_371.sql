-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 373
-- ACCESO AL CAMPO — CIERRE DEFINITIVO DE EXECUTE ANON EN RPC 371
-- ============================================================================
-- DIAGNÓSTICO REAL EN PROD
-- - Las RPC 371 pertenecen a postgres.
-- - anon NO hereda authenticated ni service_role.
-- - Los default privileges de funciones creadas por postgres en public
--   conceden EXECUTE explícito a anon/authenticated/service_role.
-- - Las cuatro RPC 371 conservan anon=X/postgres.
--
-- OBJETIVO
-- Quitar el grant explícito de anon de las RPC administrativas 371 y evitar
-- que una recreación futura de funciones por postgres en public vuelva a
-- recibir EXECUTE para anon por default.
-- ============================================================================

BEGIN;

-- 1) Corregir los privilegios predeterminados de FUTURAS funciones creadas
--    por postgres en el schema public.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
REVOKE EXECUTE ON FUNCTIONS FROM anon;

-- 2) Quitar PUBLIC por defensa en profundidad.
REVOKE EXECUTE ON FUNCTION public.crear_punto_acceso_torneo_371(uuid,text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.actualizar_punto_acceso_torneo_371(uuid,text,text,boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.retirar_punto_acceso_torneo_371(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.listar_puntos_acceso_torneo_371(uuid) FROM PUBLIC;

-- 3) Quitar el grant EXPLÍCITO existente de anon.
REVOKE EXECUTE ON FUNCTION public.crear_punto_acceso_torneo_371(uuid,text,text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.actualizar_punto_acceso_torneo_371(uuid,text,text,boolean) FROM anon;
REVOKE EXECUTE ON FUNCTION public.retirar_punto_acceso_torneo_371(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.listar_puntos_acceso_torneo_371(uuid) FROM anon;

-- 4) Mantener los roles que sí requieren ejecución.
GRANT EXECUTE ON FUNCTION public.crear_punto_acceso_torneo_371(uuid,text,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.actualizar_punto_acceso_torneo_371(uuid,text,text,boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.retirar_punto_acceso_torneo_371(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.listar_puntos_acceso_torneo_371(uuid) TO authenticated, service_role;

COMMIT;
