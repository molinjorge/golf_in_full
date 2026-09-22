-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 353
-- Corrección del generador de folio de inscripción.
--
-- Problema:
-- generar_folio_inscripcion() calculaba count(*) + 1.
-- Si existía un hueco histórico (por ejemplo, faltaba INS-0004),
-- podía intentar reutilizar un folio que ya existía y violar
-- tournament_registrations_folio_unico (tournament_id, folio).
--
-- Solución:
-- conservar el bloqueo por torneo y calcular el siguiente folio como
-- MAX(número de folio INS-NNNN existente) + 1.
-- No modifica folios existentes ni inscripciones.

BEGIN;

CREATE OR REPLACE FUNCTION public.generar_folio_inscripcion()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_consecutivo integer;
BEGIN
    -- Serializa la generación de folios dentro del mismo torneo.
    PERFORM 1
      FROM public.tournaments
     WHERE id = NEW.tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE = '23503';
    END IF;

    SELECT COALESCE(
               MAX(
                   substring(tr.folio FROM '^INS-([0-9]+)$')::integer
               ),
               0
           ) + 1
      INTO v_consecutivo
      FROM public.tournament_registrations tr
     WHERE tr.tournament_id = NEW.tournament_id
       AND tr.folio ~ '^INS-[0-9]+$';

    NEW.folio := 'INS-' || lpad(v_consecutivo::text, 4, '0');

    RETURN NEW;
END;
$function$;

COMMIT;
