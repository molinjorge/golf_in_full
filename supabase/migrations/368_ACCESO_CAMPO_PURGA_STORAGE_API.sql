BEGIN;

-- ============================================================
-- MIGRACIÓN 368
-- ACCESO AL CAMPO
-- Preparación segura de purga física vía Storage API
-- ============================================================
-- IMPORTANTE:
-- Esta migración NO despliega la Edge Function.
-- Sustituye la antigua purga SQL destructiva por una cola de purga
-- que será procesada por una Edge Function mediante Storage API.

CREATE TABLE public.tournament_access_storage_purge_queue (
    tournament_id uuid PRIMARY KEY
        REFERENCES public.tournament_access_retention(tournament_id) ON DELETE CASCADE,
    queued_at timestamptz NOT NULL DEFAULT now(),
    processing_started_at timestamptz NULL,
    completed_at timestamptz NULL,
    last_error text NULL,
    attempt_count integer NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_access_storage_purge_queue_attempt_chk
      CHECK (attempt_count >= 0)
);

ALTER TABLE public.tournament_access_storage_purge_queue ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.tournament_access_storage_purge_queue
FROM PUBLIC, anon, authenticated;

CREATE INDEX tournament_access_storage_purge_queue_pending_idx
ON public.tournament_access_storage_purge_queue(queued_at)
WHERE completed_at IS NULL;


CREATE OR REPLACE FUNCTION public.purgar_datos_acceso_vencidos_364()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_queued integer := 0;
BEGIN
    -- Ya NO borra storage.objects ni eventos.
    -- Sólo encola torneos vencidos para que una función de servidor
    -- elimine primero los archivos mediante la Storage API.
    INSERT INTO public.tournament_access_storage_purge_queue(
        tournament_id,queued_at,updated_at
    )
    SELECT r.tournament_id,now(),now()
    FROM public.tournament_access_retention r
    WHERE r.purged_at IS NULL
      AND r.purge_after<=now()
    ON CONFLICT (tournament_id) DO UPDATE
       SET updated_at=excluded.updated_at
       WHERE public.tournament_access_storage_purge_queue.completed_at IS NULL;

    GET DIAGNOSTICS v_queued = ROW_COUNT;

    RETURN jsonb_build_object(
        'ok',true,
        'queuedTournaments',v_queued,
        'note','Purga física pendiente de procesamiento por Storage API.'
    );
END;
$$;

REVOKE ALL ON FUNCTION public.purgar_datos_acceso_vencidos_364() FROM PUBLIC,anon,authenticated;


-- RPC privada para que la futura Edge Function obtenga trabajo.
CREATE OR REPLACE FUNCTION public.obtener_lote_purga_acceso_368(
    p_limit integer DEFAULT 10
)
RETURNS TABLE(
    tournament_id uuid,
    storage_paths text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
BEGIN
    IF current_user NOT IN ('postgres','service_role') THEN
        RAISE EXCEPTION 'Operación reservada al servicio.'
            USING errcode='42501';
    END IF;

    RETURN QUERY
    WITH picked AS (
        SELECT q.tournament_id
        FROM public.tournament_access_storage_purge_queue q
        WHERE q.completed_at IS NULL
          AND (
              q.processing_started_at IS NULL
              OR q.processing_started_at < now()-interval '30 minutes'
          )
        ORDER BY q.queued_at
        LIMIT greatest(1,least(coalesce(p_limit,10),50))
        FOR UPDATE SKIP LOCKED
    ),
    marked AS (
        UPDATE public.tournament_access_storage_purge_queue q
           SET processing_started_at=now(),
               attempt_count=q.attempt_count+1,
               last_error=NULL,
               updated_at=now()
          FROM picked p
         WHERE q.tournament_id=p.tournament_id
        RETURNING q.tournament_id
    )
    SELECT m.tournament_id,
           COALESCE(
             array_agg(e.vehiculo_foto_path)
               FILTER (WHERE e.vehiculo_foto_path IS NOT NULL),
             ARRAY[]::text[]
           ) AS storage_paths
    FROM marked m
    LEFT JOIN public.tournament_access_entries e
      ON e.tournament_id=m.tournament_id
    GROUP BY m.tournament_id;
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_lote_purga_acceso_368(integer)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_lote_purga_acceso_368(integer)
TO service_role;


-- RPC privada: sólo se llama DESPUÉS de que Storage API haya eliminado
-- satisfactoriamente todas las fotografías del torneo.
CREATE OR REPLACE FUNCTION public.confirmar_purga_acceso_368(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_events integer := 0;
BEGIN
    IF current_user NOT IN ('postgres','service_role') THEN
        RAISE EXCEPTION 'Operación reservada al servicio.'
            USING errcode='42501';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.tournament_access_storage_purge_queue q
        WHERE q.tournament_id=p_tournament_id
          AND q.completed_at IS NULL
    ) THEN
        RAISE EXCEPTION 'No existe una purga pendiente para este torneo.'
            USING errcode='22023';
    END IF;

    DELETE FROM public.tournament_access_entries
    WHERE tournament_id=p_tournament_id;
    GET DIAGNOSTICS v_events=ROW_COUNT;

    -- Las autorizaciones dependen de los ingresos y se eliminan por CASCADE.
    UPDATE public.tournament_access_retention
       SET purged_at=now(),updated_at=now()
     WHERE tournament_id=p_tournament_id
       AND purged_at IS NULL;

    UPDATE public.tournament_access_storage_purge_queue
       SET completed_at=now(),
           processing_started_at=NULL,
           last_error=NULL,
           updated_at=now()
     WHERE tournament_id=p_tournament_id;

    RETURN jsonb_build_object(
        'ok',true,
        'tournamentId',p_tournament_id,
        'accessEntriesDeleted',v_events
    );
END;
$$;

REVOKE ALL ON FUNCTION public.confirmar_purga_acceso_368(uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.confirmar_purga_acceso_368(uuid)
TO service_role;


CREATE OR REPLACE FUNCTION public.registrar_error_purga_acceso_368(
    p_tournament_id uuid,
    p_error text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
BEGIN
    IF current_user NOT IN ('postgres','service_role') THEN
        RAISE EXCEPTION 'Operación reservada al servicio.'
            USING errcode='42501';
    END IF;

    UPDATE public.tournament_access_storage_purge_queue
       SET processing_started_at=NULL,
           last_error=left(coalesce(p_error,'Error no especificado'),2000),
           updated_at=now()
     WHERE tournament_id=p_tournament_id
       AND completed_at IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_error_purga_acceso_368(uuid,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_error_purga_acceso_368(uuid,text)
TO service_role;

COMMIT;
