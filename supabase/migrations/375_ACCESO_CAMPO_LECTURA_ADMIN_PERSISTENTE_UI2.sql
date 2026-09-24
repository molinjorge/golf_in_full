-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 375
-- ACCESO AL CAMPO — LECTURA ADMINISTRATIVA PERSISTENTE UI-2
-- ============================================================================
-- OBJETIVO
-- Resolver dos huecos de lectura detectados al terminar UI-2:
--   1) recuperar después de recargar la apertura manual/programada;
--   2) recuperar la credencial ACTIVA existente de un punto sin rotarla.
--
-- SEGURIDAD
-- Ambas RPC son administrativas, SECURITY DEFINER y requieren usuario
-- autenticado Superadmin u organizador autorizado del torneo.
-- anon NO recibe EXECUTE.
--
-- Esta migración NO modifica datos existentes ni rota/revoca credenciales.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1. Estado administrativo completo de apertura.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_estado_acceso_campo_admin_375(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_auth_uid uuid := auth.uid();
    v_status public.estatus_torneo;
    v_uses_access boolean;
    v_manual_at timestamptz;
    v_scheduled_at timestamptz;
    v_open boolean;
    v_state text;
BEGIN
    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_tournament_id IS NULL THEN
        RAISE EXCEPTION 'Debe indicar el torneo.' USING ERRCODE='22023';
    END IF;

    SELECT t.estatus,
           t.usar_control_acceso_qr,
           s.apertura_manual_at,
           s.apertura_programada_at
      INTO v_status,
           v_uses_access,
           v_manual_at,
           v_scheduled_at
      FROM public.tournaments t
      LEFT JOIN public.tournament_access_control_settings s
        ON s.tournament_id=t.id
     WHERE t.id=p_tournament_id
       AND t.activo=true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo no existe o no está activo.'
            USING ERRCODE='23503';
    END IF;

    IF NOT (
        public.is_superadmin(v_auth_uid)
        OR public.is_tournament_organizer(v_auth_uid,p_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No tiene autorización para consultar el acceso de este torneo.'
            USING ERRCODE='42501';
    END IF;

    v_open := (
        v_uses_access=true
        AND v_status NOT IN (
            'finalizado'::public.estatus_torneo,
            'cancelado'::public.estatus_torneo
        )
        AND (
            v_manual_at IS NOT NULL
            OR (v_scheduled_at IS NOT NULL AND now() >= v_scheduled_at)
        )
    );

    v_state :=
        CASE
            WHEN v_uses_access IS DISTINCT FROM true THEN 'NO_HABILITADO'
            WHEN v_status IN (
                'finalizado'::public.estatus_torneo,
                'cancelado'::public.estatus_torneo
            ) THEN 'BLOQUEADO'
            WHEN v_open THEN 'ABIERTO'
            WHEN v_scheduled_at IS NOT NULL AND now() < v_scheduled_at THEN 'PROGRAMADO'
            ELSE 'PREPARADO'
        END;

    RETURN jsonb_build_object(
        'ok',true,
        'tournamentId',p_tournament_id,
        'state',v_state,
        'accessEnabled',v_uses_access,
        'accessOpen',v_open,
        'manualOpenedAt',v_manual_at,
        'scheduledOpeningAt',v_scheduled_at,
        'tournamentStatus',v_status
    );
END;
$function$;

-- --------------------------------------------------------------------------
-- 2. Recuperar credencial activa existente sin generar/rotar otra.
--    El token sólo se entrega al administrador autorizado.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_credencial_activa_punto_acceso_admin_375(
    p_assignment_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_auth_uid uuid := auth.uid();
    v_tournament_id uuid;
    v_alias text;
    v_responsable text;
    v_enabled boolean;
    v_retired_at timestamptz;
    v_token text;
    v_generated_at timestamptz;
    v_rotated_at timestamptz;
BEGIN
    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_assignment_id IS NULL THEN
        RAISE EXCEPTION 'Debe indicar el punto de acceso.' USING ERRCODE='22023';
    END IF;

    SELECT a.tournament_id,
           a.alias_operativo,
           a.responsable_nombre,
           a.habilitado,
           a.retirado_at
      INTO v_tournament_id,
           v_alias,
           v_responsable,
           v_enabled,
           v_retired_at
      FROM public.tournament_access_point_assignments a
     WHERE a.id=p_assignment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El punto de acceso asignado no existe.'
            USING ERRCODE='23503';
    END IF;

    IF NOT (
        public.is_superadmin(v_auth_uid)
        OR public.is_tournament_organizer(v_auth_uid,v_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No tiene autorización para consultar esta credencial.'
            USING ERRCODE='42501';
    END IF;

    IF v_retired_at IS NOT NULL THEN
        RAISE EXCEPTION 'El punto de acceso fue retirado del torneo.'
            USING ERRCODE='55000';
    END IF;

    SELECT c.access_token,c.generado_at,c.rotado_at
      INTO v_token,v_generated_at,v_rotated_at
      FROM public.tournament_access_point_credentials c
     WHERE c.assignment_id=p_assignment_id
       AND c.activo=true;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok',true,
            'assignmentId',p_assignment_id,
            'tournamentId',v_tournament_id,
            'name',v_alias,
            'responsibleName',v_responsable,
            'enabled',v_enabled,
            'hasActiveCredential',false,
            'accessToken',NULL
        );
    END IF;

    RETURN jsonb_build_object(
        'ok',true,
        'assignmentId',p_assignment_id,
        'tournamentId',v_tournament_id,
        'name',v_alias,
        'responsibleName',v_responsable,
        'enabled',v_enabled,
        'hasActiveCredential',true,
        'accessToken',v_token,
        'generatedAt',v_generated_at,
        'rotatedAt',v_rotated_at
    );
END;
$function$;

-- Hardening explícito: estas dos RPC jamás son públicas.
REVOKE EXECUTE ON FUNCTION public.obtener_estado_acceso_campo_admin_375(uuid)
    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.obtener_credencial_activa_punto_acceso_admin_375(uuid)
    FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.obtener_estado_acceso_campo_admin_375(uuid)
    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.obtener_credencial_activa_punto_acceso_admin_375(uuid)
    TO authenticated, service_role;

COMMIT;
