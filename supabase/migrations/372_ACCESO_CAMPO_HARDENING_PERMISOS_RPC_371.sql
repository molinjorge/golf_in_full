-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 372
-- ACCESO AL CAMPO — HARDENING DE PERMISOS RPC 371
-- ============================================================================
-- OBJETIVO
-- Eliminar el privilegio EXECUTE explícito del rol anon sobre las cuatro RPC
-- administrativas creadas en la migración 371.
--
-- NO MODIFICA LÓGICA FUNCIONAL NI DATOS.
-- ============================================================================

BEGIN;

REVOKE EXECUTE ON FUNCTION public.crear_punto_acceso_torneo_371(uuid,text,text)
FROM anon;

REVOKE EXECUTE ON FUNCTION public.actualizar_punto_acceso_torneo_371(uuid,text,text,boolean)
FROM anon;

REVOKE EXECUTE ON FUNCTION public.retirar_punto_acceso_torneo_371(uuid)
FROM anon;

REVOKE EXECUTE ON FUNCTION public.listar_puntos_acceso_torneo_371(uuid)
FROM anon;

-- Mantener explícitamente el acceso para usuarios autenticados.
GRANT EXECUTE ON FUNCTION public.crear_punto_acceso_torneo_371(uuid,text,text)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.actualizar_punto_acceso_torneo_371(uuid,text,text,boolean)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.retirar_punto_acceso_torneo_371(uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.listar_puntos_acceso_torneo_371(uuid)
TO authenticated;

COMMIT;
