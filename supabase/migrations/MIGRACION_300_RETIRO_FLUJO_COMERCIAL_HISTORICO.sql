-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 300
-- Retiro controlado del flujo comercial histórico de provisionamiento/liberación
--
-- Objetivo:
--   - Retirar las RPC operativas antiguas de provisionamiento, confirmación
--     manual de pago, liberación y control administrativo histórico.
--   - Simplificar la protección de estado_servicio para conservar únicamente
--     la coherencia estructural estado_servicio <-> activo.
--   - NO borrar tournament_commercial_profiles ni sus datos históricos.
--   - NO borrar configuracion_finalizada_at / configuracion_finalizada_por.
--   - NO modificar el flujo deportivo ni el autoservicio 287–299.
--
-- Precondición:
--   No debe existir ningún torneo estado_servicio='provisionado'.
-- ============================================================================

BEGIN;

DO $$
DECLARE
    v_provisionados integer;
BEGIN
    SELECT count(*)
      INTO v_provisionados
      FROM public.tournaments
     WHERE estado_servicio = 'provisionado'::public.estado_servicio_torneo;

    IF v_provisionados <> 0 THEN
        RAISE EXCEPTION
            'Migración 300 cancelada: existen % torneo(s) provisionado(s).',
            v_provisionados
            USING ERRCODE = '23514';
    END IF;
END;
$$;

-- --------------------------------------------------------------------------
-- 1. Retirar RPCs del modelo comercial histórico.
--    Se conservan las tablas/datos históricos.
-- --------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.confirmar_pago_plataforma_torneo(uuid, text, text);
DROP FUNCTION IF EXISTS public.liberar_torneo(uuid);
DROP FUNCTION IF EXISTS public.obtener_control_administrativo_torneos();

DROP FUNCTION IF EXISTS public.provisionar_torneo(
    text, date, date, text, text, numeric, text,
    text, text, text, text, text, text, text,
    boolean, timestamptz, text, text, text
);

DROP FUNCTION IF EXISTS public.provisionar_torneo(
    text, date, date, text, text, text, numeric, text,
    text, text, text, text, text, text, text,
    boolean, timestamptz, text, text, text
);

-- --------------------------------------------------------------------------
-- 2. Simplificar la protección de estado de servicio.
--
--    Ya no existe la transición comercial:
--       provisionado -> activo
--    condicionada por:
--       configuración finalizada + pago en tournament_commercial_profiles.
--
--    Se conserva:
--       activo=true              => estado_servicio='activo'
--       estado_servicio='activo' => activo=true
--
--    También se conserva el control de quién puede cambiar estado_servicio:
--       postgres / service_role / Superadmin.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.proteger_estado_servicio_torneo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_role text;
BEGIN
    -- Coherencia estructural permanente.
    IF NEW.activo = true
       AND NEW.estado_servicio
           IS DISTINCT FROM 'activo'::public.estado_servicio_torneo
    THEN
        RAISE EXCEPTION
            'Un torneo activo debe tener estado_servicio = activo.'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.estado_servicio =
           'activo'::public.estado_servicio_torneo
       AND NEW.activo IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION
            'Un torneo con estado_servicio = activo debe tener activo = true.'
            USING ERRCODE = '23514';
    END IF;

    -- Si no cambia estado_servicio, basta la validación de coherencia.
    IF NEW.estado_servicio
           IS NOT DISTINCT FROM OLD.estado_servicio
    THEN
        RETURN NEW;
    END IF;

    v_role := auth.role();

    IF NOT (
        current_user = 'postgres'
        OR v_role = 'service_role'
        OR public.is_superadmin(auth.uid())
    ) THEN
        RAISE EXCEPTION
            'Sólo el Superadmin puede cambiar el estado de servicio del torneo.'
            USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END;
$function$;

-- --------------------------------------------------------------------------
-- 3. Privilegios de la función trigger.
-- --------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.proteger_estado_servicio_torneo() FROM PUBLIC;

COMMIT;
