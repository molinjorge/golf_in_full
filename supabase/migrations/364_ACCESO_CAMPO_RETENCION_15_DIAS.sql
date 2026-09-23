BEGIN;

-- ============================================================
-- MIGRACIÓN 364
-- ACCESO AL CAMPO
-- Retención de 15 días y depuración automática
-- ============================================================

-- PROD no tiene pg_cron habilitado. Esta migración deja la regla de
-- vencimiento en la base y una función idempotente de depuración.
-- La ejecución periódica podrá conectarse después desde la aplicación
-- o desde un scheduler, sin cambiar la regla de retención.

CREATE TABLE public.tournament_access_retention (
    tournament_id uuid PRIMARY KEY
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    terminal_status public.estatus_torneo NOT NULL,
    terminal_at timestamptz NOT NULL,
    purge_after timestamptz NOT NULL,
    purged_at timestamptz NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_access_retention_terminal_364
        CHECK (terminal_status IN (
            'finalizado'::public.estatus_torneo,
            'cancelado'::public.estatus_torneo
        )),
    CONSTRAINT tournament_access_retention_window_364
        CHECK (purge_after = terminal_at + interval '15 days')
);

ALTER TABLE public.tournament_access_retention ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.tournament_access_retention
FROM PUBLIC,anon,authenticated;

CREATE POLICY tournament_access_retention_select_364
ON public.tournament_access_retention
FOR SELECT TO authenticated
USING (
    public.is_superadmin(auth.uid())
    OR public.is_tournament_organizer(auth.uid(),tournament_id)
);
GRANT SELECT ON TABLE public.tournament_access_retention TO authenticated;

CREATE INDEX tournament_access_retention_due_idx_364
ON public.tournament_access_retention (purge_after)
WHERE purged_at IS NULL;

-- Registrar automáticamente el momento exacto en que un torneo entra
-- a FINALIZADO o CANCELADO. No se usa fecha_fin porque la regla solicitada
-- comienza cuando el estado terminal realmente ocurre.
CREATE OR REPLACE FUNCTION public._registrar_retencion_acceso_364()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
BEGIN
    IF NEW.estatus IN (
        'finalizado'::public.estatus_torneo,
        'cancelado'::public.estatus_torneo
    )
    AND OLD.estatus IS DISTINCT FROM NEW.estatus THEN
        INSERT INTO public.tournament_access_retention (
            tournament_id,terminal_status,terminal_at,purge_after
        )
        VALUES (
            NEW.id,NEW.estatus,now(),now()+interval '15 days'
        )
        ON CONFLICT (tournament_id) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_registrar_retencion_acceso_364
ON public.tournaments;

CREATE TRIGGER trg_registrar_retencion_acceso_364
AFTER UPDATE OF estatus ON public.tournaments
FOR EACH ROW
EXECUTE FUNCTION public._registrar_retencion_acceso_364();

-- Backfill defensivo para torneos que ya estén terminales y tengan
-- datos de acceso. Como el esquema histórico no conserva un timestamp
-- específico de finalización/cancelación, se usa updated_at como referencia
-- sólo para esos casos preexistentes.
INSERT INTO public.tournament_access_retention (
    tournament_id,terminal_status,terminal_at,purge_after
)
SELECT DISTINCT
    t.id,t.estatus,t.updated_at,t.updated_at+interval '15 days'
FROM public.tournaments t
JOIN public.tournament_access_entries e ON e.tournament_id=t.id
WHERE t.estatus IN (
    'finalizado'::public.estatus_torneo,
    'cancelado'::public.estatus_torneo
)
ON CONFLICT (tournament_id) DO NOTHING;

-- Función interna idempotente. Elimina primero objetos privados y después
-- eventos de acceso. No toca inscripciones, jugadores ni datos competitivos.
CREATE OR REPLACE FUNCTION public.purgar_datos_acceso_vencidos_364()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','storage','pg_temp'
AS $$
DECLARE
    v_tournament_id uuid;
    v_events integer;
    v_objects integer;
    v_total_events integer := 0;
    v_total_objects integer := 0;
    v_tournaments integer := 0;
BEGIN
    FOR v_tournament_id IN
        SELECT r.tournament_id
        FROM public.tournament_access_retention r
        WHERE r.purged_at IS NULL
          AND r.purge_after <= now()
        ORDER BY r.purge_after
        FOR UPDATE SKIP LOCKED
    LOOP
        DELETE FROM storage.objects o
        WHERE o.bucket_id='acceso-campo-vehiculos'
          AND (storage.foldername(o.name))[1]=v_tournament_id::text;
        GET DIAGNOSTICS v_objects = ROW_COUNT;

        DELETE FROM public.tournament_access_entries e
        WHERE e.tournament_id=v_tournament_id;
        GET DIAGNOSTICS v_events = ROW_COUNT;

        UPDATE public.tournament_access_retention
        SET purged_at=now(),updated_at=now()
        WHERE tournament_id=v_tournament_id;

        v_total_objects := v_total_objects+v_objects;
        v_total_events := v_total_events+v_events;
        v_tournaments := v_tournaments+1;
    END LOOP;

    RETURN jsonb_build_object(
        'ok',true,
        'tournamentsPurged',v_tournaments,
        'accessEntriesDeleted',v_total_events,
        'vehicleObjectsDeleted',v_total_objects
    );
END;
$$;

-- No debe ser ejecutable por usuarios finales.
REVOKE ALL ON FUNCTION public.purgar_datos_acceso_vencidos_364()
FROM PUBLIC,anon,authenticated;

-- Consulta para que organizador/Superadmin conozca la fecha de eliminación.
CREATE OR REPLACE FUNCTION public.obtener_retencion_acceso_torneo_364(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_r public.tournament_access_retention%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING errcode='42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(),p_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No autorizado.' USING errcode='42501';
    END IF;

    SELECT * INTO v_r
    FROM public.tournament_access_retention
    WHERE tournament_id=p_tournament_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok',true,
            'retentionStarted',false,
            'retentionDays',15
        );
    END IF;

    RETURN jsonb_build_object(
        'ok',true,
        'retentionStarted',true,
        'retentionDays',15,
        'terminalStatus',v_r.terminal_status,
        'terminalAt',v_r.terminal_at,
        'purgeAfter',v_r.purge_after,
        'purgedAt',v_r.purged_at
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_retencion_acceso_torneo_364(uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_retencion_acceso_torneo_364(uuid)
TO authenticated;

COMMIT;
