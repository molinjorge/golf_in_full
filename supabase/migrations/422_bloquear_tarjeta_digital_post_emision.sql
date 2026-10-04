-- 422_bloquear_tarjeta_digital_post_emision.sql
-- TEE CENTRAL / GOLF IN FULL
--
-- OBJETIVO
-- Bloquear cambios a tournaments.usar_tarjeta_digital después de que
-- exista al menos una EMISIÓN OFICIAL de tarjetas en cualquier ronda
-- del torneo.
--
-- REGLA
-- - Antes de la primera emisión oficial: SÍ puede cambiarse.
-- - Preparar grupos, validar salidas o congelar condiciones NO bloquea este campo.
-- - Después de la primera emisión oficial con status='issued': NO puede cambiarse.
-- - El bloqueo aplica en backend, no sólo en UI.
-- - No modifica torneos ni valores existentes.

BEGIN;

CREATE OR REPLACE FUNCTION public._proteger_tarjeta_digital_post_emision_422()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- Si el valor no cambia, no hay nada que proteger.
    IF NEW.usar_tarjeta_digital
       IS NOT DISTINCT FROM OLD.usar_tarjeta_digital
    THEN
        RETURN NEW;
    END IF;

    -- La evidencia oficial de emisión es la misma usada actualmente
    -- por Tee Central: tournament_score_card_emissions.status = 'issued'.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_score_card_emissions e
         WHERE e.tournament_id = OLD.id
           AND e.status = 'issued'
    )
    THEN
        RAISE EXCEPTION
            'No se puede cambiar el uso de tarjetas digitales después de emitir las tarjetas oficiales.'
            USING ERRCODE = '55000',
                  HINT =
                    'La opción TARJETA DIGITAL puede modificarse hasta antes de la primera emisión oficial de tarjetas del torneo.';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_proteger_tarjeta_digital_post_emision_422
ON public.tournaments;

CREATE TRIGGER trg_proteger_tarjeta_digital_post_emision_422
BEFORE UPDATE OF usar_tarjeta_digital
ON public.tournaments
FOR EACH ROW
EXECUTE FUNCTION public._proteger_tarjeta_digital_post_emision_422();

COMMENT ON FUNCTION public._proteger_tarjeta_digital_post_emision_422() IS
'Impide cambiar tournaments.usar_tarjeta_digital cuando el torneo ya tiene al menos una emisión oficial de tarjetas con status=issued. Es independiente del congelamiento de condiciones.';

COMMIT;
