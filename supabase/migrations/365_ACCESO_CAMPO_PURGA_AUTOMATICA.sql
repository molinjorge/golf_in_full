BEGIN;

-- ============================================================
-- MIGRACIÓN 365
-- ACCESO AL CAMPO
-- Automatización diaria de la purga de datos vencidos
-- ============================================================
-- Supabase Cron utiliza pg_cron. La migración habilita la extensión
-- y programa una ejecución diaria de la función interna creada en 364.

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Evita duplicar el job si la migración se reintenta.
DO $$
DECLARE
    v_jobid bigint;
BEGIN
    SELECT jobid
      INTO v_jobid
      FROM cron.job
     WHERE jobname='tee-central-purge-access-data-365'
     LIMIT 1;

    IF v_jobid IS NOT NULL THEN
        PERFORM cron.unschedule(v_jobid);
    END IF;
END;
$$;

-- 06:15 UTC todos los días. La regla de 15 días se evalúa con timestamptz,
-- por lo que no depende de la zona horaria del torneo.
SELECT cron.schedule(
    'tee-central-purge-access-data-365',
    '15 6 * * *',
    $cron$
        SELECT public.purgar_datos_acceso_vencidos_364();
    $cron$
);

COMMIT;
