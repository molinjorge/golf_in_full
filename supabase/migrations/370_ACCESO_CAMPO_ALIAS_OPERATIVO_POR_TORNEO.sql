-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 370
-- ACCESO AL CAMPO — ALIAS OPERATIVO POR TORNEO
-- ============================================================================
-- OBJETIVO
-- Permitir que un mismo punto base reutilizable tenga un nombre operativo
-- distinto en cada torneo (ej. PUERTA 1 -> PUERTA NORTE).
--
-- REGLAS
-- - El alias pertenece a la ASIGNACIÓN torneo + punto, no al catálogo global.
-- - Es obligatorio, no vacío y único dentro del torneo (sin distinguir
--   mayúsculas/minúsculas ni espacios exteriores).
-- - Las RPC públicas y reportes muestran el alias operativo.
-- - El nombre del catálogo se conserva como referencia interna/base.
-- - No modifica motores deportivos, inscripciones ni premios especiales.
-- ============================================================================

BEGIN;

ALTER TABLE public.tournament_access_point_assignments
    ADD COLUMN IF NOT EXISTS alias_operativo text;

-- Si en algún ambiente existieran asignaciones previas, conservar continuidad
-- usando temporalmente el nombre base como alias.
UPDATE public.tournament_access_point_assignments a
SET alias_operativo = btrim(ap.nombre)
FROM public.tournament_access_points ap
WHERE ap.id = a.access_point_id
  AND NULLIF(btrim(COALESCE(a.alias_operativo, '')), '') IS NULL;

ALTER TABLE public.tournament_access_point_assignments
    ALTER COLUMN alias_operativo SET NOT NULL;

ALTER TABLE public.tournament_access_point_assignments
    DROP CONSTRAINT IF EXISTS tournament_access_point_assignments_alias_operativo_chk;

ALTER TABLE public.tournament_access_point_assignments
    ADD CONSTRAINT tournament_access_point_assignments_alias_operativo_chk
    CHECK (
        NULLIF(btrim(alias_operativo), '') IS NOT NULL
        AND length(btrim(alias_operativo)) <= 120
    );

CREATE UNIQUE INDEX IF NOT EXISTS uq_tournament_access_assignment_alias_370
    ON public.tournament_access_point_assignments (
        tournament_id,
        lower(btrim(alias_operativo))
    );

COMMENT ON COLUMN public.tournament_access_point_assignments.alias_operativo IS
'Nombre operativo del punto dentro de este torneo, por ejemplo PUERTA NORTE. Puede diferir del nombre base del catálogo.';

-- ----------------------------------------------------------------------------
-- RPC 360: página pública del punto
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_punto_acceso_por_token_360(p_access_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_token text;
    v_result jsonb;
BEGIN
    v_token := lower(btrim(coalesce(p_access_token, '')));

    IF v_token !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'Código de acceso inválido.'
            USING errcode = '22023';
    END IF;

    SELECT jsonb_build_object(
        'ok', true,
        'assignmentId', a.id,
        'status',
            CASE
                WHEN a.habilitado IS DISTINCT FROM true THEN 'BLOQUEADA'
                WHEN public.acceso_campo_abierto_359(t.id) THEN 'ABIERTA'
                ELSE 'PREPARADA'
            END,
        'accessOpen',
            CASE
                WHEN a.habilitado IS DISTINCT FROM true THEN false
                ELSE public.acceso_campo_abierto_359(t.id)
            END,
        'accessPoint', jsonb_build_object(
            'id', ap.id,
            'name', a.alias_operativo,
            'baseName', ap.nombre,
            'description', ap.descripcion,
            'responsibleName', a.responsable_nombre,
            'enabled', a.habilitado
        ),
        'tournament', jsonb_build_object(
            'id', t.id,
            'name', t.nombre,
            'startDate', t.fecha_inicio,
            'endDate', t.fecha_fin
        )
    )
      INTO v_result
      FROM public.tournament_access_point_credentials c
      JOIN public.tournament_access_point_assignments a
        ON a.id = c.assignment_id
      JOIN public.tournament_access_points ap
        ON ap.id = a.access_point_id
      JOIN public.tournaments t
        ON t.id = a.tournament_id
     WHERE c.access_token = v_token
       AND c.activo = true
       AND ap.activo = true
       AND t.activo = true
       AND t.usar_control_acceso_qr = true
       AND t.estatus NOT IN (
           'finalizado'::public.estatus_torneo,
           'cancelado'::public.estatus_torneo
       )
     LIMIT 1;

    IF v_result IS NULL THEN
        RAISE EXCEPTION 'Este acceso ya no está disponible. Solicite un nuevo acceso al organizador.'
            USING errcode = '42501';
    END IF;

    RETURN v_result;
END;
$function$;

-- ----------------------------------------------------------------------------
-- RPC 361: validación del QR del jugador
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validar_qr_jugador_acceso_361(
    p_access_token text,
    p_player_qr_token text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_access_token text;
    v_player_token text;
    v_assignment_id uuid;
    v_tournament_id uuid;
    v_access_point_id uuid;
    v_access_point_name text;
    v_responsible_name text;
    v_tournament_name text;
    v_tournament_start date;
    v_tournament_end date;
    v_course_timezone text;
    v_access_date date;
    v_registration_id uuid;
    v_player_id uuid;
    v_folio text;
    v_player_names text;
    v_player_surnames text;
    v_total_prior integer;
    v_today_prior integer;
    v_last_entry_at timestamptz;
    v_last_access_point text;
BEGIN
    v_access_token := lower(btrim(coalesce(p_access_token, '')));
    v_player_token := lower(btrim(coalesce(p_player_qr_token, '')));

    IF v_access_token !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'Código de acceso de puerta inválido.' USING errcode='22023';
    END IF;
    IF v_player_token !~ '^[0-9a-f]{32}$' THEN
        RAISE EXCEPTION 'Código QR de jugador inválido.' USING errcode='22023';
    END IF;

    SELECT a.id, a.tournament_id, a.access_point_id, a.alias_operativo,
           a.responsable_nombre, t.nombre, t.fecha_inicio, t.fecha_fin,
           cg.timezone_id
      INTO v_assignment_id, v_tournament_id, v_access_point_id,
           v_access_point_name, v_responsible_name, v_tournament_name,
           v_tournament_start, v_tournament_end, v_course_timezone
      FROM public.tournament_access_point_credentials c
      JOIN public.tournament_access_point_assignments a ON a.id=c.assignment_id
      JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
      JOIN public.tournaments t ON t.id=a.tournament_id
      JOIN public.campos_golf cg ON cg.id=t.campo_golf_id
     WHERE c.access_token=v_access_token
       AND c.activo=true
       AND a.habilitado=true
       AND ap.activo=true
       AND t.activo=true
       AND t.usar_control_acceso_qr=true
       AND t.estatus NOT IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo)
       AND public.acceso_campo_abierto_359(t.id)=true
     LIMIT 1;

    IF v_assignment_id IS NULL THEN
        RAISE EXCEPTION 'La puerta no está disponible o el acceso al campo aún no está abierto.'
            USING errcode='42501';
    END IF;

    IF nullif(btrim(coalesce(v_course_timezone,'')),'') IS NULL THEN
        RAISE EXCEPTION 'El campo del torneo no tiene zona horaria configurada.'
            USING errcode='55000';
    END IF;

    v_access_date := (now() AT TIME ZONE v_course_timezone)::date;

    SELECT r.id,r.player_id,r.folio,p.nombres,p.apellidos
      INTO v_registration_id,v_player_id,v_folio,v_player_names,v_player_surnames
      FROM public.tournament_registrations r
      JOIN public.players p ON p.id=r.player_id
     WHERE lower(btrim(r.qr_token))=v_player_token
       AND r.tournament_id=v_tournament_id
       AND r.activo=true
     LIMIT 1;

    IF v_registration_id IS NULL THEN
        RAISE EXCEPTION 'El QR no corresponde a una inscripción activa de este torneo.'
            USING errcode='42501';
    END IF;

    SELECT count(*)::integer,
           count(*) FILTER (WHERE e.access_date=v_access_date)::integer
      INTO v_total_prior,v_today_prior
      FROM public.tournament_access_entries e
     WHERE e.registration_id=v_registration_id;

    SELECT e.entered_at, a.alias_operativo
      INTO v_last_entry_at,v_last_access_point
      FROM public.tournament_access_entries e
      JOIN public.tournament_access_point_assignments a ON a.id=e.assignment_id
     WHERE e.registration_id=v_registration_id
     ORDER BY e.entered_at DESC
     LIMIT 1;

    RETURN jsonb_build_object(
        'ok',true,
        'valid',true,
        'tournament',jsonb_build_object(
            'id',v_tournament_id,'name',v_tournament_name,
            'startDate',v_tournament_start,'endDate',v_tournament_end,
            'courseTimezone',v_course_timezone
        ),
        'accessDate',v_access_date,
        'registration',jsonb_build_object('id',v_registration_id,'folio',v_folio),
        'player',jsonb_build_object(
            'id',v_player_id,'firstNames',v_player_names,'lastNames',v_player_surnames,
            'displayName',btrim(concat_ws(' ',v_player_names,v_player_surnames))
        ),
        'accessPoint',jsonb_build_object(
            'assignmentId',v_assignment_id,'id',v_access_point_id,
            'name',v_access_point_name,'responsibleName',v_responsible_name
        ),
        'accessHistory',jsonb_build_object(
            'priorEntries',v_total_prior,
            'priorEntriesToday',v_today_prior,
            'hasPriorEntries',v_total_prior>0,
            'hasPriorEntryToday',v_today_prior>0,
            'lastEntryAt',v_last_entry_at,
            'lastAccessPoint',v_last_access_point,
            'warningLevel',CASE WHEN v_today_prior>0 THEN 'STRONG'
                                WHEN v_total_prior>0 THEN 'INFO'
                                ELSE 'NONE' END,
            'warningMessage',CASE
                WHEN v_today_prior>0 THEN
                    'QR UTILIZADO ANTERIORMENTE HOY — IDENTIFIQUE A LA PERSONA BAJO SU RESPONSABILIDAD'
                WHEN v_total_prior>0 THEN
                    'Este QR tiene ingresos registrados en días anteriores del torneo.'
                ELSE NULL
            END
        ),
        'instructions',jsonb_build_object(
            'physicalIdRequired',true,
            'message','Solicite una identificación física y confirme que corresponde a la persona mostrada antes de registrar el ingreso.'
        )
    );
END;
$function$;

-- ----------------------------------------------------------------------------
-- RPC 366: reporte del torneo
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_reporte_acceso_torneo_366(
    p_tournament_id uuid,
    p_access_date date DEFAULT NULL::date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
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
                    'nombre',a.alias_operativo,
                    'nombreBase',ap.nombre,
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
$function$;

-- ----------------------------------------------------------------------------
-- RPC 366: alertas del torneo
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_alertas_acceso_torneo_366(
    p_tournament_id uuid,
    p_access_date date DEFAULT NULL::date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
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
                'accessPoint',a.alias_operativo,
                'responsableNombre',a.responsable_nombre,
                'useNumber',e.qr_uso_numero,
                'type','QR_REUSED_SAME_DAY',
                'severity','REVIEW',
                'message','QR reutilizado el mismo día. Revisar el registro; no implica por sí solo uso indebido.'
            ) AS alert_json
        FROM public.tournament_access_entries e
        JOIN public.players p ON p.id=e.player_id
        JOIN public.tournament_access_point_assignments a ON a.id=e.assignment_id
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
$function$;

COMMIT;
