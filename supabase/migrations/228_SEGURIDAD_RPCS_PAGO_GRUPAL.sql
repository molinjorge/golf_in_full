-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 228
-- Seguridad de RPCs públicos de pago grupal
-- ============================================================================
--
-- Objetivo:
--   Retirar ejecución directa al rol anon de los RPC públicos de pago grupal
--   introducidos/extendidos en la Migración 223, preservando acceso para
--   authenticated y service_role.
--
-- Alcance:
--   - NO modifica lógica de negocio.
--   - NO modifica firmas.
--   - NO modifica SECURITY DEFINER.
--   - NO modifica tablas, datos, pagos, coberturas ni inscripciones.
--   - NO modifica Stroke Play / Stableford / A-Go-Go scoring.
-- ============================================================================

BEGIN;

REVOKE ALL ON FUNCTION public.preparar_pago_grupal_equipo(
    uuid,
    uuid[],
    public.medio_pago_torneo
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.preparar_pago_grupal_equipo(
    uuid,
    uuid[],
    public.medio_pago_torneo
) FROM anon;

GRANT EXECUTE ON FUNCTION public.preparar_pago_grupal_equipo(
    uuid,
    uuid[],
    public.medio_pago_torneo
) TO authenticated, service_role;


REVOKE ALL ON FUNCTION public.procesar_resultado_pago_grupal_equipo(
    uuid,
    boolean,
    text
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.procesar_resultado_pago_grupal_equipo(
    uuid,
    boolean,
    text
) FROM anon;

GRANT EXECUTE ON FUNCTION public.procesar_resultado_pago_grupal_equipo(
    uuid,
    boolean,
    text
) TO authenticated, service_role;


REVOKE ALL ON FUNCTION public.obtener_coberturas_pago_grupal_equipo(
    uuid
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.obtener_coberturas_pago_grupal_equipo(
    uuid
) FROM anon;

GRANT EXECUTE ON FUNCTION public.obtener_coberturas_pago_grupal_equipo(
    uuid
) TO authenticated, service_role;

COMMIT;
