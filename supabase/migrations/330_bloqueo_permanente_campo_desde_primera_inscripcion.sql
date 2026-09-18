-- ============================================================================
-- MIGRACIÓN 330
-- Bloqueo permanente del campo desde la primera inscripción
-- TEE CENTRAL / GOLF IN FULL
--
-- REGLA:
--   Desde que un torneo recibe su primera inscripción, el campo del torneo
--   y el campo ya definido de sus rondas existentes quedan inamovibles.
--
-- PRINCIPIOS:
--   * No modifica la asignación automática de marcas de salida.
--   * No modifica Freeze, motores deportivos, snapshots ni ciclo 314.
--   * El bloqueo persiste aunque posteriormente la inscripción se inactive.
--   * La protección vive en backend y cubre cualquier ruta de escritura.
--   * No obliga a que todas las rondas usen el mismo campo: un torneo
--     multirronda puede haber definido campos distintos ANTES de inscribir.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1. Latch permanente en tournaments.
--    Se guarda cuándo ocurrió la primera inscripción y qué registro la activó.
--    El UUID del registro se conserva como dato histórico sin FK deliberadamente:
--    el bloqueo debe sobrevivir aunque el registro deje de existir.
-- --------------------------------------------------------------------------

ALTER TABLE public.tournaments
    ADD COLUMN IF NOT EXISTS campo_bloqueado_inscripciones_at timestamptz,
    ADD COLUMN IF NOT EXISTS campo_bloqueado_por_registro_id uuid;

COMMENT ON COLUMN public.tournaments.campo_bloqueado_inscripciones_at IS
'Momento en que el campo quedó bloqueado permanentemente por la primera inscripción del torneo.';

COMMENT ON COLUMN public.tournaments.campo_bloqueado_por_registro_id IS
'UUID histórico de la inscripción que activó el bloqueo permanente del campo. No tiene FK para que el bloqueo sobreviva a bajas o eliminaciones históricas.';

-- --------------------------------------------------------------------------
-- 2. Backfill para torneos que ya tienen o tuvieron inscripciones.
--    La primera inscripción histórica conocida activa el latch.
-- --------------------------------------------------------------------------

WITH primera_inscripcion AS (
    SELECT DISTINCT ON (r.tournament_id)
           r.tournament_id,
           r.id AS registration_id,
           r.created_at
      FROM public.tournament_registrations r
     ORDER BY r.tournament_id, r.created_at, r.id
)
UPDATE public.tournaments t
   SET campo_bloqueado_inscripciones_at =
           COALESCE(t.campo_bloqueado_inscripciones_at, p.created_at, now()),
       campo_bloqueado_por_registro_id =
           COALESCE(t.campo_bloqueado_por_registro_id, p.registration_id)
  FROM primera_inscripcion p
 WHERE p.tournament_id = t.id
   AND t.campo_bloqueado_inscripciones_at IS NULL
   AND t.estatus IS DISTINCT FROM 'cancelado'::public.estatus_torneo;

-- Los torneos ya CANCELADOS permanecen estrictamente de sólo lectura.
-- No se les hace backfill porque la Migración 233 prohíbe cualquier UPDATE
-- posterior a la cancelación. No necesitan el latch 330: su campo ya está
-- inmutable por una protección más fuerte.

-- --------------------------------------------------------------------------
-- 3. El latch, una vez activado, no puede quitarse ni cambiarse.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._proteger_latch_campo_inscripciones_330()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
    IF OLD.campo_bloqueado_inscripciones_at IS NOT NULL
       AND (
            NEW.campo_bloqueado_inscripciones_at
                IS DISTINCT FROM OLD.campo_bloqueado_inscripciones_at
            OR NEW.campo_bloqueado_por_registro_id
                IS DISTINCT FROM OLD.campo_bloqueado_por_registro_id
       )
    THEN
        RAISE EXCEPTION
            'El bloqueo del campo por inscripciones es permanente y no puede modificarse.'
            USING ERRCODE = '55000';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_proteger_latch_campo_inscripciones_330
    ON public.tournaments;

CREATE TRIGGER trg_proteger_latch_campo_inscripciones_330
BEFORE UPDATE OF campo_bloqueado_inscripciones_at,
                 campo_bloqueado_por_registro_id
ON public.tournaments
FOR EACH ROW
EXECUTE FUNCTION public._proteger_latch_campo_inscripciones_330();

-- --------------------------------------------------------------------------
-- 4. La primera inscripción activa el latch ANTES de guardar el registro.
--    El advisory lock serializa la inscripción con cualquier cambio de campo.
--    Si la inscripción falla por cualquier otra validación, toda la transacción
--    revierte y el latch tampoco queda activado.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._bloquear_campo_al_primera_inscripcion_330()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
    v_torneo public.tournaments%ROWTYPE;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended(NEW.tournament_id::text, 330)
    );

    SELECT *
      INTO v_torneo
      FROM public.tournaments t
     WHERE t.id = NEW.tournament_id
     FOR UPDATE;

    IF v_torneo.id IS NULL THEN
        RAISE EXCEPTION
            'El torneo de la inscripción no existe.'
            USING ERRCODE = '23503';
    END IF;

    IF v_torneo.campo_golf_id IS NULL THEN
        RAISE EXCEPTION
            'No se puede registrar al primer jugador: primero debes definir el campo de golf del torneo.'
            USING ERRCODE = '23514';
    END IF;

    IF v_torneo.campo_bloqueado_inscripciones_at IS NULL THEN
        UPDATE public.tournaments
           SET campo_bloqueado_inscripciones_at = now(),
               campo_bloqueado_por_registro_id = NEW.id
         WHERE id = NEW.tournament_id
           AND campo_bloqueado_inscripciones_at IS NULL;
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_330_bloquear_campo_primera_inscripcion
    ON public.tournament_registrations;

CREATE TRIGGER trg_330_bloquear_campo_primera_inscripcion
BEFORE INSERT
ON public.tournament_registrations
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_campo_al_primera_inscripcion_330();

-- --------------------------------------------------------------------------
-- 5. Campo general del torneo: inamovible desde la primera inscripción.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._proteger_campo_torneo_inscripciones_330()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
    IF NEW.campo_golf_id IS NOT DISTINCT FROM OLD.campo_golf_id THEN
        RETURN NEW;
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(OLD.id::text, 330)
    );

    IF OLD.campo_bloqueado_inscripciones_at IS NOT NULL
       OR EXISTS (
            SELECT 1
              FROM public.tournament_registrations r
             WHERE r.tournament_id = OLD.id
             LIMIT 1
       )
    THEN
        RAISE EXCEPTION
            'Campo bloqueado: este torneo ya tiene jugadores inscritos. El campo de golf no puede modificarse después de recibir la primera inscripción.'
            USING ERRCODE = '55000';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_proteger_campo_torneo_inscripciones_330
    ON public.tournaments;

CREATE TRIGGER trg_proteger_campo_torneo_inscripciones_330
BEFORE UPDATE OF campo_golf_id
ON public.tournaments
FOR EACH ROW
EXECUTE FUNCTION public._proteger_campo_torneo_inscripciones_330();

-- --------------------------------------------------------------------------
-- 6. Campo de una ronda existente: inamovible desde la primera inscripción.
--
--    No se prohíben campos distintos entre rondas si fueron configurados antes
--    de inscribir. Sólo se impide cambiar posteriormente el campo ya definido
--    de una ronda existente.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._proteger_campo_ronda_inscripciones_330()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
    v_bloqueado_at timestamptz;
BEGIN
    IF NEW.campo_golf_id IS NOT DISTINCT FROM OLD.campo_golf_id THEN
        RETURN NEW;
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(OLD.tournament_id::text, 330)
    );

    SELECT t.campo_bloqueado_inscripciones_at
      INTO v_bloqueado_at
      FROM public.tournaments t
     WHERE t.id = OLD.tournament_id
     FOR SHARE;

    IF v_bloqueado_at IS NOT NULL
       OR EXISTS (
            SELECT 1
              FROM public.tournament_registrations r
             WHERE r.tournament_id = OLD.tournament_id
             LIMIT 1
       )
    THEN
        RAISE EXCEPTION
            'Campo de ronda bloqueado: este torneo ya tiene jugadores inscritos. El campo de golf de la ronda no puede modificarse después de recibir la primera inscripción.'
            USING ERRCODE = '55000';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_proteger_campo_ronda_inscripciones_330
    ON public.tournament_rounds;

CREATE TRIGGER trg_proteger_campo_ronda_inscripciones_330
BEFORE UPDATE OF campo_golf_id
ON public.tournament_rounds
FOR EACH ROW
EXECUTE FUNCTION public._proteger_campo_ronda_inscripciones_330();

COMMIT;
