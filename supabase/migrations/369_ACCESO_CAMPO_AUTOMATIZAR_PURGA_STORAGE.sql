BEGIN;

-- ============================================================
-- MIGRACIÓN 369
-- ACCESO AL CAMPO
-- Automatización de purga física mediante Edge Function
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_net;

-- Guardamos en Vault únicamente datos de invocación servidor-a-servidor.
-- La clave secreta NO debe escribirse en esta migración.
-- La configuración del secreto se hace fuera del SQL versionado.

-- El Cron 365 conserva su primera responsabilidad:
-- identificar retenciones vencidas y encolarlas.
-- Después invoca la Edge Function, que procesa la cola mediante Storage API.

SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname='tee-central-purge-access-data-365';

SELECT cron.schedule(
    'tee-central-purge-access-data-365',
    '15 6 * * *',
    $cron$
    SELECT public.purgar_datos_acceso_vencidos_364();

    SELECT net.http_post(
        url := (
            SELECT decrypted_secret
            FROM vault.decrypted_secrets
            WHERE name='tee_central_project_url_369'
        ) || '/functions/v1/purge-access-storage-368',
        headers := jsonb_build_object(
            'Content-Type','application/json',
            'apikey',(
                SELECT decrypted_secret
                FROM vault.decrypted_secrets
                WHERE name='tee_central_purge_secret_key_369'
            )
        ),
        body := jsonb_build_object(
            'source','cron-369',
            'requestedAt',now()
        ),
        timeout_milliseconds := 120000
    );
    $cron$
);

COMMIT;
