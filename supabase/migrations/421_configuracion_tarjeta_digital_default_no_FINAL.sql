-- 421_configuracion_tarjeta_digital_default_no_FINAL.sql
-- TEE CENTRAL / GOLF IN FULL
--
-- OBJETIVO
-- Reutilizar public.tournaments.usar_tarjeta_digital como decisión explícita
-- de cada torneo sobre el uso de tarjeta/captura digital.
--
-- DECISIÓN
-- 1. Torneos nuevos: DEFAULT false.
-- 2. Torneos existentes PLANIFICADOS: false.
-- 3. Torneos EN CURSO, FINALIZADOS o CANCELADOS: NO se modifican.
-- 4. No se desactiva ni evade ningún candado existente.
-- 5. Esta migración NO implementa todavía QR, PDF ni captura pública.

BEGIN;

DO $$
DECLARE
    v_data_type text;
    v_is_nullable text;
BEGIN
    SELECT data_type, is_nullable
      INTO v_data_type, v_is_nullable
      FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name = 'tournaments'
       AND column_name = 'usar_tarjeta_digital';

    IF NOT FOUND THEN
        RAISE EXCEPTION
            '421 abortada: no existe public.tournaments.usar_tarjeta_digital.';
    END IF;

    IF v_data_type <> 'boolean' THEN
        RAISE EXCEPTION
            '421 abortada: usar_tarjeta_digital no es boolean (tipo actual: %).',
            v_data_type;
    END IF;

    IF v_is_nullable <> 'NO' THEN
        RAISE EXCEPTION
            '421 abortada: usar_tarjeta_digital debe ser NOT NULL.';
    END IF;
END
$$;

-- Los torneos nuevos nacen sin tarjeta digital.
ALTER TABLE public.tournaments
    ALTER COLUMN usar_tarjeta_digital SET DEFAULT false;

-- Sólo normalizamos torneos que aún están en planificación.
-- No tocamos torneos en curso, finalizados, cancelados ni históricos.
UPDATE public.tournaments
   SET usar_tarjeta_digital = false
 WHERE estatus = 'planificado'::public.estatus_torneo
   AND usar_tarjeta_digital IS DISTINCT FROM false;

COMMENT ON COLUMN public.tournaments.usar_tarjeta_digital IS
'Define si el torneo utilizará tarjeta/captura digital. Default false. La decisión se configura durante la planificación; esta migración no modifica torneos en curso, finalizados ni cancelados.';

COMMIT;
