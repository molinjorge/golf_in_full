-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 255
-- AJUSTE ACL — validar_franjas_handicap_torneo(uuid)
-- ============================================================================
-- Objetivo:
--   Retirar EXECUTE explícito al rol anon sobre la función central de validación
--   de franjas creada en la migración 254.
--
-- No modifica lógica funcional, datos, scoring ni flujos de torneo.
-- Ejecutar manualmente en Supabase.
-- ============================================================================

BEGIN;

REVOKE EXECUTE
ON FUNCTION public.validar_franjas_handicap_torneo(uuid)
FROM anon;

-- Reafirmar permisos esperados.
GRANT EXECUTE
ON FUNCTION public.validar_franjas_handicap_torneo(uuid)
TO authenticated, service_role;

COMMIT;
