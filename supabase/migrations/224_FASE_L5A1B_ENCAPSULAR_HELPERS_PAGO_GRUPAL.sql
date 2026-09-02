-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 224 — FASE L5A1B
-- Encapsular helpers internos del pago grupal parcial de equipos
--
-- Objetivo:
--   Corregir únicamente los permisos de ejecución detectados al verificar 223.
--   Los helpers SECURITY DEFINER deben permanecer internos y ser consumidos
--   únicamente por los RPC públicos de la fase.
--
-- NO cambia lógica funcional.
-- NO toca pagos individuales.
-- NO toca pago de equipo completo (Migración 200).
-- NO toca roster, sustituciones, HCP, congelamiento ni frontend.
-- ============================================================================

BEGIN;

REVOKE EXECUTE ON FUNCTION public._puede_pagar_equipo_grupal_223(uuid, uuid)
FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public._validar_pago_grupal_slots_223(uuid, uuid, uuid[], uuid)
FROM PUBLIC, anon, authenticated;

-- Mantener acceso operativo para propietario/backend privilegiado.
GRANT EXECUTE ON FUNCTION public._puede_pagar_equipo_grupal_223(uuid, uuid)
TO postgres, service_role;

GRANT EXECUTE ON FUNCTION public._validar_pago_grupal_slots_223(uuid, uuid, uuid[], uuid)
TO postgres, service_role;

COMMIT;
