-- MIGRACIÓN 351 — CIERRE DE PERMISO ANON EN PREVISUALIZACIÓN HCP
-- TEE CENTRAL / GOLF IN FULL
--
-- Objetivo:
-- Corregir exclusivamente el permiso EXECUTE heredado por el rol anon sobre
-- public.previsualizar_categorias_hcp_torneo_350(uuid,numeric).
--
-- Diagnóstico PROD posterior a Migración 350:
--   authenticated_execute = true
--   anon_execute          = true   <-- no deseado
--
-- La función ya valida auth.uid(), pero el contrato de seguridad definido para
-- esta RPC exige que anon tampoco tenga permiso formal EXECUTE.
--
-- Esta migración:
--   * NO modifica datos.
--   * NO modifica la lógica de HCP.
--   * NO modifica categorías ni marcas.
--   * NO modifica la Migración 350.
--   * Mantiene EXECUTE para authenticated.
--
-- IMPORTANTE: ejecutar manualmente. ChatGPT no ejecuta esta migración.

BEGIN;

REVOKE EXECUTE
ON FUNCTION public.previsualizar_categorias_hcp_torneo_350(uuid,numeric)
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.previsualizar_categorias_hcp_torneo_350(uuid,numeric)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.previsualizar_categorias_hcp_torneo_350(uuid,numeric)
TO authenticated;

COMMIT;
