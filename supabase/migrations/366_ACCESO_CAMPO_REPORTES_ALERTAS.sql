BEGIN;

-- ============================================================
-- MIGRACIÓN 366
-- ACCESO AL CAMPO
-- Reporte operativo y alertas de reutilización
-- ============================================================

CREATE OR REPLACE FUNCTION public.obtener_reporte_acceso_torneo_366(
    p_tournament_id uuid,
    p_access_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_timezone text;
    v_local_date date;
    v_rows jsonb;
    v_summary jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(),p_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No autorizado.' USING ERRCODE='42501';
    END IF;

    SELECT NULLIF(btrim(c.timezone_id),'')
      INTO v_timezone
      FROM public.tournaments t
      JOIN public.campos_golf c ON c.id=t.campo_golf_id
     WHERE t.id=p_tournament_id;

    IF v_timezone IS NULL THEN
        RAISE EXCEPTION 'El torneo no tiene zona horaria operativa válida.'
            USING ERRCODE='22023';
    END IF;

    v_local_date := COALESCE(
        p_access_date,
        (now() AT TIME ZONE v_timezone)::date
    );

    SELECT jsonb_build_object(
        'accessDate',v_local_date,
        'totalEntries',count(*),
        'uniquePlayers',count(DISTINCT e.player_id),
        'sameDayReuses',count(*) FILTER (WHERE e.reutilizado_mismo_dia),
        'accompaniedEntries',count(*) FILTER (WHERE e.viene_acompanado),
        'vehiclePhotos',count(*) FILTER (WHERE e.vehiculo_foto_path IS NOT NULL),
        'platesCaptured',count(*) FILTER (WHERE e.vehiculo_placa IS NOT NULL)
    )
    INTO v_summary
    FROM public.tournament_access_entries e
    WHERE e.tournament_id=p_tournament_id
      AND e.access_date=v_local_date;

    SELECT COALESCE(jsonb_agg(x.row_json ORDER BY x.entered_at DESC),'[]'::jsonb)
      INTO v_rows
      FROM (
        SELECT
            e.entered_at,
            jsonb_build_object(
                'entryId',e.id,
                'accessDate',e.access_date,
                'enteredAt',e.entered_at,
                'registrationId',e.registration_id,
                'playerId',e.player_id,
                'player',jsonb_build_object(
                    'nombres',p.nombres,
                    'apellidos',p.apellidos
                ),
                'accessPoint',jsonb_build_object(
                    'assignmentId',e.assignment_id,
                    'accessPointId',a.access_point_id,
                    'nombre',ap.nombre,
                    'responsableNombre',a.responsable_nombre
                ),
                'qr',jsonb_build_object(
                    'useNumber',e.qr_uso_numero,
                    'reused',e.qr_reutilizado,
                    'sameDayReuse',e.reutilizado_mismo_dia,
                    'reuseWarningConfirmed',e.advertencia_reutilizacion_confirmada
                ),
                'identityConfirmed',e.identidad_confirmada,
                'accompanied',e.viene_acompanado,
                'vehicle',jsonb_build_object(
                    'hasPhoto',e.vehiculo_foto_path IS NOT NULL,
                    'photoPath',e.vehiculo_foto_path,
                    'plate',e.vehiculo_placa
                ),
                'review',jsonb_build_object(
                    'required',e.reutilizado_mismo_dia,
                    'level',CASE WHEN e.reutilizado_mismo_dia THEN 'REVIEW' ELSE 'NONE' END,
                    'reason',CASE
                        WHEN e.reutilizado_mismo_dia
                        THEN 'QR reutilizado el mismo día. Revisar el registro; no implica por sí solo uso indebido.'
                        ELSE NULL
                    END
                )
            ) AS row_json
        FROM public.tournament_access_entries e
        JOIN public.players p ON p.id=e.player_id
        JOIN public.tournament_access_point_assignments a ON a.id=e.assignment_id
        JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
        WHERE e.tournament_id=p_tournament_id
          AND e.access_date=v_local_date
      ) x;

    RETURN jsonb_build_object(
        'ok',true,
        'tournamentId',p_tournament_id,
        'timezone',v_timezone,
        'summary',v_summary,
        'entries',v_rows
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_reporte_acceso_torneo_366(uuid,date)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_reporte_acceso_torneo_366(uuid,date)
TO authenticated;


CREATE OR REPLACE FUNCTION public.obtener_alertas_acceso_torneo_366(
    p_tournament_id uuid,
    p_access_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_timezone text;
    v_local_date date;
    v_alerts jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(),p_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No autorizado.' USING ERRCODE='42501';
    END IF;

    SELECT NULLIF(btrim(c.timezone_id),'')
      INTO v_timezone
      FROM public.tournaments t
      JOIN public.campos_golf c ON c.id=t.campo_golf_id
     WHERE t.id=p_tournament_id;

    IF v_timezone IS NULL THEN
        RAISE EXCEPTION 'El torneo no tiene zona horaria operativa válida.'
            USING ERRCODE='22023';
    END IF;

    v_local_date := COALESCE(
        p_access_date,
        (now() AT TIME ZONE v_timezone)::date
    );

    SELECT COALESCE(jsonb_agg(q.alert_json ORDER BY q.entered_at DESC),'[]'::jsonb)
      INTO v_alerts
      FROM (
        SELECT
            e.entered_at,
            jsonb_build_object(
                'entryId',e.id,
                'registrationId',e.registration_id,
                'playerId',e.player_id,
                'player',concat_ws(' ',p.nombres,p.apellidos),
                'enteredAt',e.entered_at,
                'accessPoint',ap.nombre,
                'responsableNombre',a.responsable_nombre,
                'useNumber',e.qr_uso_numero,
                'type','QR_REUSED_SAME_DAY',
                'severity','REVIEW',
                'message','QR reutilizado el mismo día. Revisar el registro; no implica por sí solo uso indebido.'
            ) AS alert_json
        FROM public.tournament_access_entries e
        JOIN public.players p ON p.id=e.player_id
        JOIN public.tournament_access_point_assignments a ON a.id=e.assignment_id
        JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
        WHERE e.tournament_id=p_tournament_id
          AND e.access_date=v_local_date
          AND e.reutilizado_mismo_dia=true
      ) q;

    RETURN jsonb_build_object(
        'ok',true,
        'tournamentId',p_tournament_id,
        'accessDate',v_local_date,
        'timezone',v_timezone,
        'alertCount',jsonb_array_length(v_alerts),
        'alerts',v_alerts
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_alertas_acceso_torneo_366(uuid,date)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_alertas_acceso_torneo_366(uuid,date)
TO authenticated;

COMMIT;
