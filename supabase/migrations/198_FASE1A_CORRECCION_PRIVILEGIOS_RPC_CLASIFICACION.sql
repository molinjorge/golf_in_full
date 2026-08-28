-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 198 FASE 1A
-- CORRECCIÓN DE PRIVILEGIOS RPC DE CLASIFICACIÓN COMPETITIVA
-- ============================================================================
-- Objetivo
--   1) Retirar el EXECUTE directo que el rol anon conserva sobre las RPCs 198.
--   2) Mantener EXECUTE únicamente para authenticated y service_role.
--   3) No modificar datos, clasificaciones, snapshots ni torneos congelados.
--
-- Diagnóstico previo
--   - 198 Fase 1 revocó PUBLIC correctamente, pero las funciones conservaron
--     grants directos a anon en su ACL.
--   - Los snapshots faltantes detectados pertenecen a freezes históricos
--     previos: no fueron creados ni alterados por 198 Fase 1.
-- ============================================================================

BEGIN;

REVOKE EXECUTE ON FUNCTION public.obtener_clasificaciones_categorias_torneo(uuid)
FROM anon;

REVOKE EXECUTE ON FUNCTION public.configurar_clasificacion_categoria_torneo(uuid, text)
FROM anon;

REVOKE ALL ON FUNCTION public.obtener_clasificaciones_categorias_torneo(uuid)
FROM PUBLIC;

REVOKE ALL ON FUNCTION public.configurar_clasificacion_categoria_torneo(uuid, text)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.obtener_clasificaciones_categorias_torneo(uuid)
TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.configurar_clasificacion_categoria_torneo(uuid, text)
TO authenticated, service_role;

COMMIT;
