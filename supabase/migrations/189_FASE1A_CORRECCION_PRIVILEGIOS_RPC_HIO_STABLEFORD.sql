-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 189 Fase 1A
-- Corrección de privilegios RPC HIO Stableford
--
-- Motivo:
--   Las default privileges del esquema public conceden EXECUTE a anon al crear
--   funciones. La 189 Fase 1 revocó PUBLIC, pero no revocó explícitamente anon.
--
-- Alcance:
--   - Revoca EXECUTE a anon en las dos RPC HIO.
--   - Preserva EXECUTE para authenticated y service_role.
--   - No modifica tablas, RLS, datos, snapshots ni lógica deportiva.
-- ============================================================================

BEGIN;

REVOKE EXECUTE ON FUNCTION public.obtener_reglas_especiales_stableford_torneo(uuid)
FROM anon;

REVOKE EXECUTE ON FUNCTION public.configurar_regla_hole_in_one_torneo(uuid,boolean,integer)
FROM anon;

-- Defensa adicional: PUBLIC continúa sin EXECUTE.
REVOKE EXECUTE ON FUNCTION public.obtener_reglas_especiales_stableford_torneo(uuid)
FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.configurar_regla_hole_in_one_torneo(uuid,boolean,integer)
FROM PUBLIC;

-- Preservar acceso previsto.
GRANT EXECUTE ON FUNCTION public.obtener_reglas_especiales_stableford_torneo(uuid)
TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.configurar_regla_hole_in_one_torneo(uuid,boolean,integer)
TO authenticated, service_role;

COMMIT;
