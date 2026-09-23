-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 357
-- CONTROL DE ACCESO QR CONFIGURABLE POR TORNEO
-- ============================================================================
-- EJECUCIÓN MANUAL EN SUPABASE.
--
-- Objetivo:
--   Permitir que cada torneo decida si utilizará el control de acceso mediante
--   QR de Tee Central.
--
-- Compatibilidad:
--   * Torneos ya existentes: quedan en TRUE, preservando el comportamiento
--     histórico sin ejecutar UPDATE sobre filas existentes.
--   * Torneos nuevos: nacen en FALSE (opt-in).
--   * El valor puede cambiar mientras el torneo no esté congelado.
--   * Después del freeze competitivo queda bloqueado.
--
-- Esta migración NO modifica qr_token, inscripciones, pagos ni correos.
-- ============================================================================

BEGIN;

-- 1. Agregar la decisión operativa al torneo.
-- DEFAULT true en el ADD COLUMN preserva todas las filas existentes sin UPDATE.
ALTER TABLE public.tournaments
    ADD COLUMN usar_control_acceso_qr boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.tournaments.usar_control_acceso_qr IS
'Indica si el torneo utiliza el módulo de control de acceso mediante QR de Tee Central. Los torneos nuevos inician desactivados; los torneos preexistentes a la migración 357 conservaron TRUE.';

-- 2. A partir de ahora, los torneos nuevos nacen sin QR de Tee Central.
-- ALTER DEFAULT no modifica ninguna fila existente.
ALTER TABLE public.tournaments
    ALTER COLUMN usar_control_acceso_qr SET DEFAULT false;

-- 3. Proteger la decisión después del congelamiento competitivo.
CREATE OR REPLACE FUNCTION public._proteger_control_acceso_qr_post_freeze_357()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.usar_control_acceso_qr IS NOT DISTINCT FROM OLD.usar_control_acceso_qr THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = OLD.id
    ) THEN
        RAISE EXCEPTION
            'No se puede cambiar el control de acceso QR después de congelar el torneo.'
            USING ERRCODE = '55000',
                  HINT = 'La decisión de utilizar el acceso QR de Tee Central debe definirse antes del congelamiento.';
    END IF;

    RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public._proteger_control_acceso_qr_post_freeze_357()
FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_proteger_control_acceso_qr_post_freeze_357
ON public.tournaments;

CREATE TRIGGER trg_proteger_control_acceso_qr_post_freeze_357
BEFORE UPDATE OF usar_control_acceso_qr
ON public.tournaments
FOR EACH ROW
EXECUTE FUNCTION public._proteger_control_acceso_qr_post_freeze_357();

COMMIT;
