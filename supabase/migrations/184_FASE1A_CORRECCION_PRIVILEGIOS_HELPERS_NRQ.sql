-- ============================================================================
-- MIGRACION 184 FASE 1A
-- CORRECCION DE PRIVILEGIOS EN HELPERS INTERNOS NRQ
-- TEE CENTRAL
--
-- CONTEXTO
-- La Migración 184 Fase 1 quedó funcionalmente instalada y verificada en
-- 24 de 25 controles. El único error detectado fue de exposición directa
-- de dos funciones trigger internas al rol authenticated.
--
-- OBJETIVO
-- - Mantener operativos los triggers instalados en 184 Fase 1.
-- - Retirar EXECUTE directo de PUBLIC, anon y authenticated sobre:
--      _autocompletar_conciliacion_nrq_al_finalizar_fisica()
--      _proteger_captura_digital_despues_nrq()
-- - Conservar EXECUTE para service_role.
--
-- IMPORTANTE
-- Esta migración NO cambia:
-- - lógica NRQ;
-- - detección de captura digital real;
-- - autocierre técnico COMPLETED;
-- - backfill histórico;
-- - resultados oficiales;
-- - conciliación;
-- - datos existentes.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. HELPER TRIGGER DE AUTOCIERRE NRQ
-- ============================================================================

REVOKE ALL
ON FUNCTION public._autocompletar_conciliacion_nrq_al_finalizar_fisica()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._autocompletar_conciliacion_nrq_al_finalizar_fisica()
TO service_role;

-- ============================================================================
-- 02. HELPER TRIGGER DE PROTECCION DIGITAL POST-NRQ
-- ============================================================================

REVOKE ALL
ON FUNCTION public._proteger_captura_digital_despues_nrq()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._proteger_captura_digital_despues_nrq()
TO service_role;

COMMIT;
