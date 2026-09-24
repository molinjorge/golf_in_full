-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 371
-- ACCESO AL CAMPO — ADMINISTRACIÓN TRANSACCIONAL DE PUNTOS DEL TORNEO
-- ============================================================================
-- OBJETIVO
-- Ocultar al frontend el catálogo técnico tournament_access_points y ofrecer
-- RPC seguras/atómicas para crear, editar y retirar puntos operativos de un
-- torneo.
--
-- DECISIÓN FUNCIONAL
-- El usuario sólo trabaja con nombres operativos del torneo (alias), por
-- ejemplo PUERTA NORTE. El punto base se crea internamente y no requiere una
-- pantalla de catálogo.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. CREAR PUNTO OPERATIVO DEL TORNEO
--    - Determina internamente el organizer_admin_user_id.
--    - Crea un punto base técnico único.
--    - Crea la asignación con alias/responsable.
--    - Todo ocurre en la misma transacción de la llamada RPC.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crear_punto_acceso_torneo_371(
    p_tournament_id uuid,
    p_alias_operativo text,
    p_responsable_nombre text DEFAULT NULL
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
    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_tournament_id IS NULL THEN
        RAISE EXCEPTION 'Debe indicar el torneo.' USING ERRCODE='22023';
    END IF;

    IF v_alias IS NULL OR length(v_alias)>120 THEN
        RAISE EXCEPTION 'El nombre del punto de acceso es obligatorio y no puede exceder 120 caracteres.'
            USING ERRCODE='22023';
    END IF;

    IF v_responsable IS NOT NULL AND length(v_responsable)>150 THEN
        RAISE EXCEPTION 'El nombre del responsable no puede exceder 150 caracteres.'
            USING ERRCODE='22023';
    END IF;

    SELECT t.estatus, t.usar_control_acceso_qr
      INTO v_tournament_status, v_uses_access
      FROM public.tournaments t
     WHERE t.id=p_tournament_id
       AND t.activo=true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo no existe o no está activo.' USING ERRCODE='23503';
    END IF;

    IF NOT (
        public.is_superadmin(v_auth_uid)
        OR public.is_tournament_organizer(v_auth_uid,p_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No tiene autorización para administrar los puntos de acceso de este torneo.'
            USING ERRCODE='42501';
    END IF;

    IF v_tournament_status IN (
        'finalizado'::public.estatus_torneo,
        'cancelado'::public.estatus_torneo
    ) THEN
        RAISE EXCEPTION 'No se pueden agregar puntos de acceso a un torneo finalizado o cancelado.'
            USING ERRCODE='55000';
    END IF;

    IF v_uses_access IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'El torneo no tiene habilitado el Control de Acceso QR de Tee Central.'
            USING ERRCODE='55000';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM public.tournament_access_point_assignments a
         WHERE a.tournament_id=p_tournament_id
           AND lower(btrim(a.alias_operativo))=lower(v_alias)
    ) THEN
        RAISE EXCEPTION 'Ya existe un punto de acceso con ese nombre en este torneo.'
            USING ERRCODE='23505';
    END IF;

    -- Para organizador normal, el propietario técnico es su admin_user_id.
    SELECT au.id
      INTO v_organizer_admin_user_id
      FROM public.admin_users au
      JOIN public.admin_role_assignments ara ON ara.admin_user_id=au.id
      JOIN public.roles r ON r.id=ara.role_id
     WHERE au.auth_user_id=v_auth_uid
       AND au.activo=true
       AND ara.activo=true
       AND r.codigo='tournament_organizer'
       AND ara.tournament_id=p_tournament_id
     ORDER BY ara.created_at
     LIMIT 1;

    -- Si quien opera es Superadmin y no es el organizador asignado, el punto
    -- técnico se atribuye al organizador activo del torneo.
    IF v_organizer_admin_user_id IS NULL AND public.is_superadmin(v_auth_uid) THEN
        SELECT au.id
          INTO v_organizer_admin_user_id
          FROM public.admin_users au
          JOIN public.admin_role_assignments ara ON ara.admin_user_id=au.id
          JOIN public.roles r ON r.id=ara.role_id
         WHERE au.activo=true
           AND ara.activo=true
           AND r.codigo='tournament_organizer'
           AND ara.tournament_id=p_tournament_id
         ORDER BY ara.created_at
         LIMIT 1;
    END IF;

    IF v_organizer_admin_user_id IS NULL THEN
        RAISE EXCEPTION 'El torneo no tiene un organizador activo al cual atribuir el punto de acceso.'
            USING ERRCODE='55000';
    END IF;

    -- Nombre técnico opaco/reutilizable. El usuario nunca necesita verlo.
    v_internal_name := 'ACCESO-' || replace(gen_random_uuid()::text,'-','');

    INSERT INTO public.tournament_access_points(
        organizer_admin_user_id,
        nombre,
        descripcion,
        activo
    )
    VALUES(
        v_organizer_admin_user_id,
        v_internal_name,
        NULL,
        true
    )
    RETURNING id INTO v_access_point_id;

    INSERT INTO public.tournament_access_point_assignments(
        tournament_id,
        access_point_id,
        alias_operativo,
        responsable_nombre,
        habilitado
    )
    VALUES(
        p_tournament_id,
        v_access_point_id,
        v_alias,
        v_responsable,
        true
    )
    RETURNING id INTO v_assignment_id;

    RETURN jsonb_build_object(
        'ok',true,
        'assignmentId',v_assignment_id,
        'accessPointId',v_access_point_id,
        'name',v_alias,
        'responsibleName',v_responsable,
        'enabled',true
    );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 2. EDITAR PUNTO OPERATIVO
--    Actualiza alias, responsable y habilitado sin exponer el catálogo base.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.actualizar_punto_acceso_torneo_371(
    p_assignment_id uuid,
    p_alias_operativo text,
    p_responsable_nombre text DEFAULT NULL,
    p_habilitado boolean DEFAULT true
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
    v_tournament_id uuid;
    v_status public.estatus_torneo;
BEGIN
    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_assignment_id IS NULL THEN
        RAISE EXCEPTION 'Debe indicar el punto de acceso.' USING ERRCODE='22023';
    END IF;

    IF v_alias IS NULL OR length(v_alias)>120 THEN
        RAISE EXCEPTION 'El nombre del punto de acceso es obligatorio y no puede exceder 120 caracteres.'
            USING ERRCODE='22023';
    END IF;

    IF v_responsable IS NOT NULL AND length(v_responsable)>150 THEN
        RAISE EXCEPTION 'El nombre del responsable no puede exceder 150 caracteres.'
            USING ERRCODE='22023';
    END IF;

    SELECT a.tournament_id,t.estatus
      INTO v_tournament_id,v_status
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
        RAISE EXCEPTION 'No tiene autorización para administrar este punto de acceso.'
            USING ERRCODE='42501';
    END IF;

    IF v_status IN (
        'finalizado'::public.estatus_torneo,
        'cancelado'::public.estatus_torneo
    ) THEN
        RAISE EXCEPTION 'No se puede modificar un punto de acceso de un torneo finalizado o cancelado.'
            USING ERRCODE='55000';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM public.tournament_access_point_assignments x
         WHERE x.tournament_id=v_tournament_id
           AND x.id<>p_assignment_id
           AND lower(btrim(x.alias_operativo))=lower(v_alias)
    ) THEN
        RAISE EXCEPTION 'Ya existe otro punto de acceso con ese nombre en este torneo.'
            USING ERRCODE='23505';
    END IF;

    UPDATE public.tournament_access_point_assignments
       SET alias_operativo=v_alias,
           responsable_nombre=v_responsable,
           habilitado=COALESCE(p_habilitado,true),
           updated_at=now()
     WHERE id=p_assignment_id;

    RETURN jsonb_build_object(
        'ok',true,
        'assignmentId',p_assignment_id,
        'name',v_alias,
        'responsibleName',v_responsable,
        'enabled',COALESCE(p_habilitado,true)
    );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 3. RETIRAR PUNTO DEL TORNEO
--    No borra físicamente infraestructura ni historial. Deshabilita la
--    asignación y revoca cualquier credencial activa del punto.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.retirar_punto_acceso_torneo_371(
    p_assignment_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_auth_uid uuid := auth.uid();
    v_tournament_id uuid;
    v_access_point_id uuid;
    v_status public.estatus_torneo;
BEGIN
    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT a.tournament_id,a.access_point_id,t.estatus
      INTO v_tournament_id,v_access_point_id,v_status
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
        RAISE EXCEPTION 'No tiene autorización para administrar este punto de acceso.'
            USING ERRCODE='42501';
    END IF;

    IF v_status IN (
        'finalizado'::public.estatus_torneo,
        'cancelado'::public.estatus_torneo
    ) THEN
        RAISE EXCEPTION 'No se puede retirar un punto de acceso de un torneo finalizado o cancelado.'
            USING ERRCODE='55000';
    END IF;

    UPDATE public.tournament_access_point_assignments
       SET habilitado=false,
           updated_at=now()
     WHERE id=p_assignment_id;

    UPDATE public.tournament_access_point_credentials
       SET activo=false,
           revocado_at=COALESCE(revocado_at,now()),
           updated_at=now()
     WHERE assignment_id=p_assignment_id
       AND activo=true;

    -- El punto base creado para esta asignación queda inactivo si no está
    -- siendo usado por ninguna otra asignación habilitada.
    IF NOT EXISTS (
        SELECT 1
          FROM public.tournament_access_point_assignments x
         WHERE x.access_point_id=v_access_point_id
           AND x.id<>p_assignment_id
           AND x.habilitado=true
    ) THEN
        UPDATE public.tournament_access_points
           SET activo=false,
               updated_at=now()
         WHERE id=v_access_point_id;
    END IF;

    RETURN jsonb_build_object(
        'ok',true,
        'assignmentId',p_assignment_id,
        'enabled',false,
        'credentialRevoked',true
    );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. LISTAR PUNTOS DEL TORNEO
--    El frontend recibe sólo el modelo operativo necesario.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.listar_puntos_acceso_torneo_371(
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
    v_points jsonb;
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

    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'assignmentId',a.id,
                'name',a.alias_operativo,
                'responsibleName',a.responsable_nombre,
                'enabled',a.habilitado,
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
     WHERE a.tournament_id=p_tournament_id;

    RETURN jsonb_build_object(
        'ok',true,
        'tournamentId',p_tournament_id,
        'points',v_points
    );
END;
$function$;

-- Sólo usuarios autenticados pueden invocar administración/listado.
REVOKE ALL ON FUNCTION public.crear_punto_acceso_torneo_371(uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.actualizar_punto_acceso_torneo_371(uuid,text,text,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.retirar_punto_acceso_torneo_371(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.listar_puntos_acceso_torneo_371(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.crear_punto_acceso_torneo_371(uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.actualizar_punto_acceso_torneo_371(uuid,text,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.retirar_punto_acceso_torneo_371(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.listar_puntos_acceso_torneo_371(uuid) TO authenticated;

COMMIT;
