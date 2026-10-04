-- 436A-MIGRACION_TARJETA_DIGITAL_REVERSIBLE_PREINICIO.sql
-- TEE CENTRAL / GOLF IN FULL
-- Objetivo:
-- Permitir al organizador cambiar TARJETA DIGITAL SI <-> NO incluso después
-- de emitir tarjetas oficiales, siempre que el torneo todavía no haya iniciado.
-- Una vez iniciado el torneo, el valor queda congelado.
--
-- No modifica tarjetas emitidas, folios, qr_token, salidas ni validaciones.
-- La autorización sigue dependiendo de las políticas RLS existentes de tournaments.

BEGIN;

CREATE OR REPLACE FUNCTION public._proteger_tarjeta_digital_post_emision_422()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- Sin cambio: no hay nada que proteger.
    IF NEW.usar_tarjeta_digital
       IS NOT DISTINCT FROM OLD.usar_tarjeta_digital
    THEN
        RETURN NEW;
    END IF;

    -- 436A:
    -- Mientras el torneo siga antes de INICIAR TORNEO, TARJETA DIGITAL
    -- es una decisión operativa reversible SI <-> NO, haya o no tarjetas emitidas.
    --
    -- Los qr_token ya emitidos no se eliminan ni regeneran. El campo
    -- usar_tarjeta_digital actúa como interruptor maestro del mecanismo digital.
    IF OLD.estatus = 'inscripcion_cerrada'::public.estatus_torneo
       AND NEW.estatus = OLD.estatus
    THEN
        RETURN NEW;
    END IF;

    -- Antes de la emisión se conserva el comportamiento histórico para estados
    -- previos a inscripcion_cerrada, sujeto a las reglas/RLS existentes.
    IF NOT EXISTS (
        SELECT 1
          FROM public.tournament_score_card_emissions e
         WHERE e.tournament_id = OLD.id
           AND e.status = 'issued'
    )
    THEN
        RETURN NEW;
    END IF;

    -- Con tarjetas emitidas, fuera del estado preinicio, el interruptor queda
    -- congelado para no cambiar las reglas operativas durante/después del torneo.
    RAISE EXCEPTION
        'No se puede cambiar TARJETA DIGITAL después de iniciar el torneo.'
        USING ERRCODE = '55000',
              HINT =
                'Antes de iniciar el torneo TARJETA DIGITAL puede cambiarse libremente entre SÍ y NO. Después de iniciar el torneo queda bloqueada.';
END;
$function$;

COMMENT ON FUNCTION public._proteger_tarjeta_digital_post_emision_422()
IS '436A: TARJETA DIGITAL es reversible SI<->NO hasta antes de iniciar el torneo, incluso con tarjetas emitidas. Después del inicio queda congelada.';

COMMIT;
