-- 427-MIGRACION_CORREGIR_VOLATILIDAD_QR_426
-- Objetivo: permitir que obtener_tarjeta_publica_qr_426 ejecute correctamente
-- la cadena 426 -> 425 -> 424, ya que 424 realiza housekeeping de controles QR expirados.
--
-- IMPORTANTE:
-- - No cambia lógica deportiva.
-- - No cambia permisos.
-- - No cambia firmas.
-- - No cambia el core Stableford 426, que permanece STABLE porque es de solo lectura.

BEGIN;

ALTER FUNCTION public.obtener_tarjeta_publica_qr_426(text, text) VOLATILE;

COMMIT;
