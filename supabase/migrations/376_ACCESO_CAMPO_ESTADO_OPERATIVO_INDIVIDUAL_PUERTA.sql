-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 376
-- ACCESO AL CAMPO — ESTADO OPERATIVO INDIVIDUAL POR PUERTA
-- ============================================================================
-- OBJETIVO
-- Separar la habilitación administrativa de cada punto de acceso de su estado
-- operativo ABIERTA/CERRADA, conservando la misma credencial/QR al cerrar y
-- volver a abrir una puerta.
--
-- IMPORTANTE
-- - habilitado          = configuración administrativa existente.
-- - operativa_abierta   = estado operativo individual de la puerta.
-- - acceso efectivo     = acceso general abierto + habilitado +
--                         operativa_abierta + credencial válida.
-- - Cerrar una puerta NO revoca ni rota su credencial.
-- - Retirar un punto SÍ conserva el comportamiento existente de revocación.
-- ============================================================================

BEGIN;

-- 1) Estado operativo independiente.
ALTER TABLE public.tournament_access_point_assignments
    ADD COLUMN IF NOT EXISTS operativa_abierta boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.tournament_access_point_assignments.operativa_abierta IS
'Estado operativo individual de la puerta. true=ABIERTA, false=CERRADA. No revoca ni rota la credencial. El acceso efectivo también requiere apertura general y habilitación administrativa.';

CREATE INDEX IF NOT EXISTS tournament_access_point_assignments_operativa_376
    ON public.tournament_access_point_assignments
       (tournament_id, operativa_abierta)
    WHERE retirado_at IS NULL;

-- 2) Crear punto: nace administrativamente habilitado y operativamente abierto.
--    Antes de la apertura general seguirá siendo PREPARADA y no operará.
CREATE OR REPLACE FUNCTION public.crear_punto_acceso_torneo_371(
    p_tournament_id uuid,
    p_alias_operativo text,
    p_responsable_nombre text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_auth_uid uuid := auth.uid();
    v_alias text := NULLIF(btrim(COALESCE(p_alias_operativo,'')),'');
    v_responsable text := NULLIF(btrim(COALESCE(p_responsable_nombre,'')),'');
    v_organizer_admin_user_id uuid;
    v_access_point_id uuid;
    v_assignment_id uuid;
    v_internal_name text;
    v_tournament_status public.estatus_torneo;
    v_uses_access boolean;
BEGIN
    IF v_auth_uid IS NULL THEN RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501'; END IF;
    IF p_tournament_id IS NULL THEN RAISE EXCEPTION 'Debe indicar el torneo.' USING ERRCODE='22023'; END IF;
    IF v_alias IS NULL OR length(v_alias)>120 THEN
        RAISE EXCEPTION 'El nombre del punto de acceso es obligatorio y no puede exceder 120 caracteres.' USING ERRCODE='22023';
    END IF;
    IF v_responsable IS NOT NULL AND length(v_responsable)>150 THEN
        RAISE EXCEPTION 'El nombre del responsable no puede exceder 150 caracteres.' USING ERRCODE='22023';
    END IF;

    SELECT t.estatus,t.usar_control_acceso_qr
      INTO v_tournament_status,v_uses_access
      FROM public.tournaments t
     WHERE t.id=p_tournament_id AND t.activo=true;
    IF NOT FOUND THEN RAISE EXCEPTION 'El torneo no existe o no está activo.' USING ERRCODE='23503'; END IF;

    IF NOT (public.is_superadmin(v_auth_uid) OR public.is_tournament_organizer(v_auth_uid,p_tournament_id)) THEN
        RAISE EXCEPTION 'No tiene autorización para administrar los puntos de acceso de este torneo.' USING ERRCODE='42501';
    END IF;
    IF v_tournament_status IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo) THEN
        RAISE EXCEPTION 'No se pueden agregar puntos de acceso a un torneo finalizado o cancelado.' USING ERRCODE='55000';
    END IF;
    IF v_uses_access IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'El torneo no tiene habilitado el Control de Acceso QR de Tee Central.' USING ERRCODE='55000';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.tournament_access_point_assignments a
         WHERE a.tournament_id=p_tournament_id
           AND a.retirado_at IS NULL
           AND lower(btrim(a.alias_operativo))=lower(v_alias)
    ) THEN
        RAISE EXCEPTION 'Ya existe un punto de acceso con ese nombre en este torneo.' USING ERRCODE='23505';
    END IF;

    SELECT au.id INTO v_organizer_admin_user_id
      FROM public.admin_users au
      JOIN public.admin_role_assignments ara ON ara.admin_user_id=au.id
      JOIN public.roles r ON r.id=ara.role_id
     WHERE au.auth_user_id=v_auth_uid AND au.activo=true AND ara.activo=true
       AND r.codigo='tournament_organizer' AND ara.tournament_id=p_tournament_id
     ORDER BY ara.created_at LIMIT 1;

    IF v_organizer_admin_user_id IS NULL AND public.is_superadmin(v_auth_uid) THEN
        SELECT au.id INTO v_organizer_admin_user_id
          FROM public.admin_users au
          JOIN public.admin_role_assignments ara ON ara.admin_user_id=au.id
          JOIN public.roles r ON r.id=ara.role_id
         WHERE au.activo=true AND ara.activo=true
           AND r.codigo='tournament_organizer' AND ara.tournament_id=p_tournament_id
         ORDER BY ara.created_at LIMIT 1;
    END IF;
    IF v_organizer_admin_user_id IS NULL THEN
        RAISE EXCEPTION 'El torneo no tiene un organizador activo al cual atribuir el punto de acceso.' USING ERRCODE='55000';
    END IF;

    v_internal_name := 'ACCESO-' || replace(gen_random_uuid()::text,'-','');
    INSERT INTO public.tournament_access_points(organizer_admin_user_id,nombre,descripcion,activo)
    VALUES(v_organizer_admin_user_id,v_internal_name,NULL,true)
    RETURNING id INTO v_access_point_id;

    INSERT INTO public.tournament_access_point_assignments(
        tournament_id,access_point_id,alias_operativo,responsable_nombre,
        habilitado,operativa_abierta,retirado_at
    )
    VALUES(p_tournament_id,v_access_point_id,v_alias,v_responsable,true,true,NULL)
    RETURNING id INTO v_assignment_id;

    RETURN jsonb_build_object(
        'ok',true,'assignmentId',v_assignment_id,'accessPointId',v_access_point_id,
        'name',v_alias,'responsibleName',v_responsable,
        'enabled',true,'gateOpen',true
    );
END;
$function$;

-- 3) Lista administrativa: expone estado individual y estado efectivo.
CREATE OR REPLACE FUNCTION public.listar_puntos_acceso_torneo_371(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_auth_uid uuid := auth.uid();
    v_points jsonb;
    v_general_open boolean;
BEGIN
    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;
    IF NOT (
        public.is_superadmin(v_auth_uid)
        OR public.is_tournament_organizer(v_auth_uid,p_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No tiene autorización para consultar los puntos de acceso de este torneo.'
            USING ERRCODE='42501';
    END IF;

    v_general_open := public.acceso_campo_abierto_359(p_tournament_id);

    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'assignmentId',a.id,
                'name',a.alias_operativo,
                'responsibleName',a.responsable_nombre,
                'enabled',a.habilitado,
                'gateOpen',a.operativa_abierta,
                'effectiveOpen',(a.habilitado AND a.operativa_abierta AND v_general_open),
                'hasCredential',(c.id IS NOT NULL),
                'credentialActive',COALESCE(c.activo,false),
                'createdAt',a.created_at,
                'updatedAt',a.updated_at
            )
            ORDER BY lower(a.alias_operativo),a.created_at
        ),
        '[]'::jsonb
    )
      INTO v_points
      FROM public.tournament_access_point_assignments a
      LEFT JOIN public.tournament_access_point_credentials c
        ON c.assignment_id=a.id
     WHERE a.tournament_id=p_tournament_id
       AND a.retirado_at IS NULL;

    RETURN jsonb_build_object(
        'ok',true,
        'tournamentId',p_tournament_id,
        'generalAccessOpen',v_general_open,
        'points',v_points
    );
END;
$function$;

-- 4) Abrir puerta individual: no toca credencial.
CREATE OR REPLACE FUNCTION public.abrir_punto_acceso_torneo_376(p_assignment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_auth_uid uuid := auth.uid();
    v_tournament_id uuid;
    v_alias text;
    v_habilitado boolean;
    v_retirado_at timestamptz;
    v_status public.estatus_torneo;
    v_uses_access boolean;
BEGIN
    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT a.tournament_id,a.alias_operativo,a.habilitado,a.retirado_at,
           t.estatus,t.usar_control_acceso_qr
      INTO v_tournament_id,v_alias,v_habilitado,v_retirado_at,v_status,v_uses_access
      FROM public.tournament_access_point_assignments a
      JOIN public.tournaments t ON t.id=a.tournament_id
     WHERE a.id=p_assignment_id
     FOR UPDATE OF a;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El punto de acceso asignado no existe.' USING ERRCODE='23503';
    END IF;
    IF NOT (
        public.is_superadmin(v_auth_uid)
        OR public.is_tournament_organizer(v_auth_uid,v_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No tiene autorización para administrar este punto de acceso.' USING ERRCODE='42501';
    END IF;
    IF v_retirado_at IS NOT NULL THEN
        RAISE EXCEPTION 'El punto de acceso fue retirado del torneo.' USING ERRCODE='55000';
    END IF;
    IF v_status IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo) THEN
        RAISE EXCEPTION 'No se puede abrir una puerta de un torneo finalizado o cancelado.' USING ERRCODE='55000';
    END IF;
    IF v_uses_access IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'El torneo no tiene habilitado el Control de Acceso QR de Tee Central.' USING ERRCODE='55000';
    END IF;
    IF v_habilitado IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'El punto de acceso está deshabilitado administrativamente.' USING ERRCODE='55000';
    END IF;

    UPDATE public.tournament_access_point_assignments
       SET operativa_abierta=true,updated_at=now()
     WHERE id=p_assignment_id;

    RETURN jsonb_build_object(
        'ok',true,'assignmentId',p_assignment_id,'name',v_alias,
        'gateOpen',true,
        'effectiveOpen',public.acceso_campo_abierto_359(v_tournament_id)
    );
END;
$function$;

-- 5) Cerrar puerta individual: conserva exactamente la misma credencial.
CREATE OR REPLACE FUNCTION public.cerrar_punto_acceso_torneo_376(p_assignment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_auth_uid uuid := auth.uid();
    v_tournament_id uuid;
    v_alias text;
    v_retirado_at timestamptz;
    v_status public.estatus_torneo;
BEGIN
    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT a.tournament_id,a.alias_operativo,a.retirado_at,t.estatus
      INTO v_tournament_id,v_alias,v_retirado_at,v_status
      FROM public.tournament_access_point_assignments a
      JOIN public.tournaments t ON t.id=a.tournament_id
     WHERE a.id=p_assignment_id
     FOR UPDATE OF a;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El punto de acceso asignado no existe.' USING ERRCODE='23503';
    END IF;
    IF NOT (
        public.is_superadmin(v_auth_uid)
        OR public.is_tournament_organizer(v_auth_uid,v_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No tiene autorización para administrar este punto de acceso.' USING ERRCODE='42501';
    END IF;
    IF v_retirado_at IS NOT NULL THEN
        RAISE EXCEPTION 'El punto de acceso fue retirado del torneo.' USING ERRCODE='55000';
    END IF;
    IF v_status IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo) THEN
        RAISE EXCEPTION 'No se puede cerrar una puerta de un torneo finalizado o cancelado.' USING ERRCODE='55000';
    END IF;

    UPDATE public.tournament_access_point_assignments
       SET operativa_abierta=false,updated_at=now()
     WHERE id=p_assignment_id;

    RETURN jsonb_build_object(
        'ok',true,'assignmentId',p_assignment_id,'name',v_alias,
        'gateOpen',false,'effectiveOpen',false
    );
END;
$function$;

-- 6) Página pública del punto: distingue CERRADA de PREPARADA.
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
        RAISE EXCEPTION 'Código de acceso inválido.' USING errcode = '22023';
    END IF;

    SELECT jsonb_build_object(
        'ok', true,
        'assignmentId', a.id,
        'status',
            CASE
                WHEN a.habilitado IS DISTINCT FROM true THEN 'BLOQUEADA'
                WHEN a.operativa_abierta IS DISTINCT FROM true THEN 'CERRADA'
                WHEN public.acceso_campo_abierto_359(t.id) THEN 'ABIERTA'
                ELSE 'PREPARADA'
            END,
        'accessOpen',
            (a.habilitado = true
             AND a.operativa_abierta = true
             AND public.acceso_campo_abierto_359(t.id)),
        'accessPoint', jsonb_build_object(
            'id', ap.id,
            'name', a.alias_operativo,
            'baseName', ap.nombre,
            'description', ap.descripcion,
            'responsibleName', a.responsable_nombre,
            'enabled', a.habilitado,
            'gateOpen', a.operativa_abierta
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
      JOIN public.tournament_access_point_assignments a ON a.id = c.assignment_id
      JOIN public.tournament_access_points ap ON ap.id = a.access_point_id
      JOIN public.tournaments t ON t.id = a.tournament_id
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

-- 7) Validación del jugador: exige puerta individual abierta.
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
       AND a.operativa_abierta=true
       AND a.retirado_at IS NULL
       AND ap.activo=true
       AND t.activo=true
       AND t.usar_control_acceso_qr=true
       AND t.estatus NOT IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo)
       AND public.acceso_campo_abierto_359(t.id)=true
     LIMIT 1;

    IF v_assignment_id IS NULL THEN
        RAISE EXCEPTION 'La puerta está cerrada/no disponible o el acceso general al campo aún no está abierto.'
            USING errcode='42501';
    END IF;

    IF nullif(btrim(coalesce(v_course_timezone,'')),'') IS NULL THEN
        RAISE EXCEPTION 'El campo del torneo no tiene zona horaria configurada.' USING errcode='55000';
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
        RAISE EXCEPTION 'El QR no corresponde a una inscripción activa de este torneo.' USING errcode='42501';
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
        'ok',true,'valid',true,
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

-- 8) Registro del ingreso: misma defensa server-side.
CREATE OR REPLACE FUNCTION public.registrar_ingreso_acceso_362(
    p_access_token text,
    p_player_qr_token text,
    p_identidad_confirmada boolean,
    p_advertencia_reutilizacion_confirmada boolean DEFAULT false,
    p_viene_acompanado boolean DEFAULT false
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
    v_registration_id uuid;
    v_player_id uuid;
    v_course_timezone text;
    v_access_date date;
    v_prior_count integer;
    v_today_prior integer;
    v_use_number integer;
    v_entry_id uuid;
    v_entered_at timestamptz;
BEGIN
    IF p_identidad_confirmada IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Debe confirmar la identidad física del jugador antes de registrar el ingreso.'
            USING errcode='22023';
    END IF;

    v_access_token := lower(btrim(coalesce(p_access_token,'')));
    v_player_token := lower(btrim(coalesce(p_player_qr_token,'')));

    IF v_access_token !~ '^[0-9a-f]{64}$'
       OR v_player_token !~ '^[0-9a-f]{32}$' THEN
        RAISE EXCEPTION 'Código de acceso o QR de jugador inválido.' USING errcode='22023';
    END IF;

    SELECT a.id,a.tournament_id,cg.timezone_id
      INTO v_assignment_id,v_tournament_id,v_course_timezone
      FROM public.tournament_access_point_credentials c
      JOIN public.tournament_access_point_assignments a ON a.id=c.assignment_id
      JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
      JOIN public.tournaments t ON t.id=a.tournament_id
      JOIN public.campos_golf cg ON cg.id=t.campo_golf_id
     WHERE c.access_token=v_access_token
       AND c.activo=true
       AND a.habilitado=true
       AND a.operativa_abierta=true
       AND a.retirado_at IS NULL
       AND ap.activo=true
       AND t.activo=true
       AND t.usar_control_acceso_qr=true
       AND t.estatus NOT IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo)
       AND public.acceso_campo_abierto_359(t.id)=true
     LIMIT 1;

    IF v_assignment_id IS NULL THEN
        RAISE EXCEPTION 'La puerta está cerrada/no disponible o el acceso general al campo aún no está abierto.'
            USING errcode='42501';
    END IF;

    v_access_date := (now() AT TIME ZONE v_course_timezone)::date;

    SELECT r.id,r.player_id
      INTO v_registration_id,v_player_id
      FROM public.tournament_registrations r
     WHERE lower(btrim(r.qr_token))=v_player_token
       AND r.tournament_id=v_tournament_id
       AND r.activo=true
     LIMIT 1
     FOR UPDATE;

    IF v_registration_id IS NULL THEN
        RAISE EXCEPTION 'El QR no corresponde a una inscripción activa de este torneo.' USING errcode='42501';
    END IF;

    SELECT count(*)::integer,
           count(*) FILTER (WHERE access_date=v_access_date)::integer
      INTO v_prior_count,v_today_prior
      FROM public.tournament_access_entries
     WHERE registration_id=v_registration_id;

    IF v_today_prior>0
       AND p_advertencia_reutilizacion_confirmada IS DISTINCT FROM true THEN
        RAISE EXCEPTION
            'QR UTILIZADO ANTERIORMENTE HOY — IDENTIFIQUE A LA PERSONA BAJO SU RESPONSABILIDAD y confirme la advertencia para continuar.'
            USING errcode='22023';
    END IF;

    v_use_number := v_prior_count+1;

    INSERT INTO public.tournament_access_entries (
        tournament_id,assignment_id,registration_id,player_id,
        access_date,entered_at,qr_uso_numero,qr_reutilizado,
        reutilizado_mismo_dia,identidad_confirmada,
        advertencia_reutilizacion_confirmada,viene_acompanado
    )
    VALUES (
        v_tournament_id,v_assignment_id,v_registration_id,v_player_id,
        v_access_date,now(),v_use_number,(v_prior_count>0),
        (v_today_prior>0),true,
        CASE WHEN v_today_prior>0 THEN true ELSE false END,
        coalesce(p_viene_acompanado,false)
    )
    RETURNING id,entered_at INTO v_entry_id,v_entered_at;

    RETURN jsonb_build_object(
        'ok',true,'entryId',v_entry_id,'accessDate',v_access_date,
        'enteredAt',v_entered_at,'qrUseNumber',v_use_number,
        'qrReused',v_prior_count>0,'reusedSameDay',v_today_prior>0,
        'accompanied',coalesce(p_viene_acompanado,false)
    );
END;
$function$;

-- 9) Permisos de las nuevas RPC operativas.
REVOKE ALL ON FUNCTION public.abrir_punto_acceso_torneo_376(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cerrar_punto_acceso_torneo_376(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.abrir_punto_acceso_torneo_376(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerrar_punto_acceso_torneo_376(uuid) TO authenticated, service_role;

-- Reafirmar permisos de RPC administrativas reemplazadas.
REVOKE ALL ON FUNCTION public.crear_punto_acceso_torneo_371(uuid,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.listar_puntos_acceso_torneo_371(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_punto_acceso_torneo_371(uuid,text,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.listar_puntos_acceso_torneo_371(uuid) TO authenticated, service_role;

-- Las RPC públicas de operación de puerta/jugador conservan su acceso anon.
REVOKE ALL ON FUNCTION public.obtener_punto_acceso_por_token_360(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.validar_qr_jugador_acceso_361(text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.registrar_ingreso_acceso_362(text,text,boolean,boolean,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_punto_acceso_por_token_360(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.validar_qr_jugador_acceso_361(text,text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.registrar_ingreso_acceso_362(text,text,boolean,boolean,boolean) TO anon, authenticated, service_role;

COMMIT;
