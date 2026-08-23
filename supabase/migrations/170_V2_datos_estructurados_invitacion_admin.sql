-- ============================================================================
-- 170_V2_datos_estructurados_invitacion_admin.sql
-- Tee Central / GOLF IN FULL
--
-- MIGRACIÓN 170 V2 — DATOS ESTRUCTURADOS DE INVITACIÓN ADMINISTRATIVA
--
-- Esta versión es TRANSICIONAL y segura con el frontend actual:
-- - Agrega nombres/apellidos a admin_user_invitations (nullable durante transición).
-- - Agrega la firma canónica nueva de asignar_o_invitar_admin con nombres/apellidos.
-- - Agrega aceptar_invitacion_admin(uuid), que toma esos datos de la invitación.
-- - Conserva las firmas anteriores para no romper el frontend actual.
-- - NO modifica provisionar_torneo todavía: se adaptará junto con el frontend
--   para no introducir una ruptura entre DB y UI.
--
-- La invitación nueva creada por la firma canónica queda lista para activarse
-- sin volver a pedir nombres/apellidos al invitado.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. COLUMNAS ESTRUCTURADAS
-- ============================================================================

ALTER TABLE public.admin_user_invitations
  ADD COLUMN IF NOT EXISTS nombres text,
  ADD COLUMN IF NOT EXISTS apellidos text;

ALTER TABLE public.admin_user_invitations
  DROP CONSTRAINT IF EXISTS admin_user_invitations_nombres_not_blank,
  DROP CONSTRAINT IF EXISTS admin_user_invitations_apellidos_not_blank;

ALTER TABLE public.admin_user_invitations
  ADD CONSTRAINT admin_user_invitations_nombres_not_blank
    CHECK (nombres IS NULL OR length(trim(nombres)) > 0),
  ADD CONSTRAINT admin_user_invitations_apellidos_not_blank
    CHECK (apellidos IS NULL OR length(trim(apellidos)) > 0);

COMMENT ON COLUMN public.admin_user_invitations.nombres IS
'Nombres capturados por Superadmin al originar el alta administrativa.';

COMMENT ON COLUMN public.admin_user_invitations.apellidos IS
'Apellidos capturados por Superadmin al originar el alta administrativa.';

-- ============================================================================
-- 2. NUEVA FIRMA CANÓNICA DE ASIGNAR / INVITAR
-- ============================================================================

CREATE OR REPLACE FUNCTION public.asignar_o_invitar_admin(
  p_role_codigo text,
  p_nombres text,
  p_apellidos text,
  p_email text,
  p_phone text DEFAULT NULL,
  p_club_id uuid DEFAULT NULL,
  p_tournament_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_actor uuid;
  v_role_id uuid;
  v_role_code text;
  v_ambito text;
  v_email text;
  v_nombres text;
  v_apellidos text;
  v_display_name text;
  v_phone text;

  v_admin_id uuid;
  v_auth_uid uuid;
  v_admin_activo boolean;

  v_assignment_id uuid;
  v_invitation_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
  END IF;

  IF NOT public.is_superadmin(auth.uid()) THEN
    RAISE EXCEPTION
      'Sólo el Superadmin puede asignar o invitar usuarios administrativos.'
      USING ERRCODE='42501';
  END IF;

  SELECT public.current_admin_id()
    INTO v_actor;

  IF v_actor IS NULL THEN
    RAISE EXCEPTION
      'No se encontró el usuario administrativo del Superadmin autenticado.'
      USING ERRCODE='42501';
  END IF;

  v_role_code := lower(NULLIF(trim(p_role_codigo),''));
  v_nombres := NULLIF(trim(p_nombres),'');
  v_apellidos := NULLIF(trim(p_apellidos),'');
  v_email := lower(NULLIF(trim(p_email),''));
  v_phone := NULLIF(trim(p_phone),'');
  v_display_name := concat_ws(' ',v_nombres,v_apellidos);

  IF v_role_code NOT IN ('club_admin','tournament_organizer') THEN
    RAISE EXCEPTION
      'El rol solicitado todavía no está habilitado para invitaciones administrativas.'
      USING ERRCODE='22023';
  END IF;

  IF v_nombres IS NULL THEN
    RAISE EXCEPTION 'Los nombres son obligatorios.' USING ERRCODE='22023';
  END IF;

  IF v_apellidos IS NULL THEN
    RAISE EXCEPTION 'Los apellidos son obligatorios.' USING ERRCODE='22023';
  END IF;

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'El email es obligatorio.' USING ERRCODE='22023';
  END IF;

  SELECT r.id,r.ambito::text
    INTO v_role_id,v_ambito
  FROM public.roles r
  WHERE r.codigo=v_role_code
    AND r.activo=true
  LIMIT 1;

  IF v_role_id IS NULL THEN
    RAISE EXCEPTION
      'El rol solicitado no existe o está inactivo.'
      USING ERRCODE='55000';
  END IF;

  IF v_ambito='club' THEN
    IF p_club_id IS NULL OR p_tournament_id IS NOT NULL THEN
      RAISE EXCEPTION
        'El rol club_admin requiere club_id y no admite tournament_id.'
        USING ERRCODE='22023';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.clubs c WHERE c.id=p_club_id
    ) THEN
      RAISE EXCEPTION 'El club indicado no existe.'
        USING ERRCODE='23503';
    END IF;

  ELSIF v_ambito='tournament' THEN
    IF p_tournament_id IS NULL OR p_club_id IS NOT NULL THEN
      RAISE EXCEPTION
        'El rol tournament_organizer requiere tournament_id y no admite club_id.'
        USING ERRCODE='22023';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.tournaments t WHERE t.id=p_tournament_id
    ) THEN
      RAISE EXCEPTION 'El torneo indicado no existe.'
        USING ERRCODE='23503';
    END IF;
  ELSE
    RAISE EXCEPTION
      'El ámbito del rol no está habilitado en esta operación.'
      USING ERRCODE='22023';
  END IF;

  -- --------------------------------------------------------------------------
  -- ADMIN EXISTENTE: asignar o reutilizar assignment, sin invitación.
  -- --------------------------------------------------------------------------
  SELECT au.id,au.auth_user_id,au.activo
    INTO v_admin_id,v_auth_uid,v_admin_activo
  FROM public.admin_users au
  WHERE lower(trim(au.email::text))=v_email
  LIMIT 1;

  IF v_admin_id IS NOT NULL THEN
    IF COALESCE(v_admin_activo,false)=false THEN
      RAISE EXCEPTION
        'El correo corresponde a un usuario administrativo inactivo.'
        USING ERRCODE='55000';
    END IF;

    IF v_auth_uid IS NULL THEN
      RAISE EXCEPTION
        'El usuario administrativo existe pero todavía no está vinculado a Supabase Auth.'
        USING ERRCODE='55000';
    END IF;

    SELECT ara.id
      INTO v_assignment_id
    FROM public.admin_role_assignments ara
    WHERE ara.admin_user_id=v_admin_id
      AND ara.role_id=v_role_id
      AND ara.activo=true
      AND (
        (v_ambito='club'
         AND ara.club_id=p_club_id
         AND ara.tournament_id IS NULL)
        OR
        (v_ambito='tournament'
         AND ara.tournament_id=p_tournament_id
         AND ara.club_id IS NULL)
      )
    LIMIT 1;

    IF v_assignment_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'ok',true,
        'resultado','ALREADY_ASSIGNED',
        'adminUserId',v_admin_id,
        'assignmentId',v_assignment_id,
        'invitationId',NULL,
        'roleCode',v_role_code,
        'clubId',p_club_id,
        'tournamentId',p_tournament_id
      );
    END IF;

    SELECT ara.id
      INTO v_assignment_id
    FROM public.admin_role_assignments ara
    WHERE ara.admin_user_id=v_admin_id
      AND ara.role_id=v_role_id
      AND ara.activo=false
      AND (
        (v_ambito='club'
         AND ara.club_id=p_club_id
         AND ara.tournament_id IS NULL)
        OR
        (v_ambito='tournament'
         AND ara.tournament_id=p_tournament_id
         AND ara.club_id IS NULL)
      )
    ORDER BY ara.created_at DESC
    LIMIT 1;

    IF v_assignment_id IS NOT NULL THEN
      UPDATE public.admin_role_assignments
      SET activo=true,
          fecha_baja=NULL,
          dado_de_baja_por=NULL,
          motivo_baja=NULL
      WHERE id=v_assignment_id;

      RETURN jsonb_build_object(
        'ok',true,
        'resultado','ASSIGNED',
        'assignmentAction','REACTIVATED',
        'adminUserId',v_admin_id,
        'assignmentId',v_assignment_id,
        'invitationId',NULL,
        'roleCode',v_role_code,
        'clubId',p_club_id,
        'tournamentId',p_tournament_id
      );
    END IF;

    INSERT INTO public.admin_role_assignments(
      admin_user_id,
      role_id,
      club_id,
      tournament_id,
      created_by,
      activo
    )
    VALUES(
      v_admin_id,
      v_role_id,
      p_club_id,
      p_tournament_id,
      v_actor,
      true
    )
    RETURNING id INTO v_assignment_id;

    RETURN jsonb_build_object(
      'ok',true,
      'resultado','ASSIGNED',
      'assignmentAction','CREATED',
      'adminUserId',v_admin_id,
      'assignmentId',v_assignment_id,
      'invitationId',NULL,
      'roleCode',v_role_code,
      'clubId',p_club_id,
      'tournamentId',p_tournament_id
    );
  END IF;

  -- --------------------------------------------------------------------------
  -- ADMIN NUEVO: invitación pending con nombres/apellidos estructurados.
  -- --------------------------------------------------------------------------
  SELECT i.id
    INTO v_invitation_id
  FROM public.admin_user_invitations i
  WHERE lower(trim(i.email::text))=v_email
    AND i.role_id=v_role_id
    AND i.status='pending'::public.estado_invitacion_admin
    AND (
      (v_ambito='club'
       AND i.club_id=p_club_id
       AND i.tournament_id IS NULL)
      OR
      (v_ambito='tournament'
       AND i.tournament_id=p_tournament_id
       AND i.club_id IS NULL)
    )
  LIMIT 1;

  IF v_invitation_id IS NULL THEN
    INSERT INTO public.admin_user_invitations(
      display_name,
      nombres,
      apellidos,
      email,
      phone,
      role_id,
      club_id,
      tournament_id,
      status,
      invited_by
    )
    VALUES(
      v_display_name,
      v_nombres,
      v_apellidos,
      v_email,
      v_phone,
      v_role_id,
      p_club_id,
      p_tournament_id,
      'pending'::public.estado_invitacion_admin,
      v_actor
    )
    RETURNING id INTO v_invitation_id;
  ELSE
    UPDATE public.admin_user_invitations
    SET display_name=v_display_name,
        nombres=v_nombres,
        apellidos=v_apellidos,
        phone=v_phone
    WHERE id=v_invitation_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',true,
    'resultado','INVITED',
    'adminUserId',NULL,
    'assignmentId',NULL,
    'invitationId',v_invitation_id,
    'roleCode',v_role_code,
    'clubId',p_club_id,
    'tournamentId',p_tournament_id
  );
END;
$$;

-- ============================================================================
-- 3. NUEVA ACEPTACIÓN CANÓNICA: SÓLO invitation_id
-- ============================================================================

CREATE OR REPLACE FUNCTION public.aceptar_invitacion_admin(
  p_invitation_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,auth,pg_temp
AS $$
DECLARE
  v_auth_uid uuid;
  v_auth_email text;
  v_confirmed timestamptz;

  v_inv public.admin_user_invitations%ROWTYPE;
  v_role_code text;
  v_ambito text;

  v_admin_id uuid;
  v_existing_auth uuid;
  v_activo boolean;
  v_assignment_id uuid;
BEGIN
  v_auth_uid:=auth.uid();

  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
  END IF;

  SELECT lower(trim(u.email)),u.email_confirmed_at
    INTO v_auth_email,v_confirmed
  FROM auth.users u
  WHERE u.id=v_auth_uid;

  IF v_auth_email IS NULL THEN
    RAISE EXCEPTION
      'No se pudo determinar el correo del usuario autenticado.'
      USING ERRCODE='42501';
  END IF;

  IF v_confirmed IS NULL THEN
    RAISE EXCEPTION
      'Debes verificar tu correo electrónico antes de aceptar la invitación.'
      USING ERRCODE='42501';
  END IF;

  SELECT *
    INTO v_inv
  FROM public.admin_user_invitations
  WHERE id=p_invitation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La invitación no existe.'
      USING ERRCODE='22023';
  END IF;

  IF v_inv.status<>'pending'::public.estado_invitacion_admin THEN
    RAISE EXCEPTION
      'La invitación ya no está disponible.'
      USING ERRCODE='55000';
  END IF;

  IF v_inv.expires_at IS NOT NULL
     AND v_inv.expires_at<=now()
  THEN
    UPDATE public.admin_user_invitations
    SET status='expired'::public.estado_invitacion_admin,
        expired_at=COALESCE(expired_at,now())
    WHERE id=v_inv.id;

    RAISE EXCEPTION 'La invitación ha expirado.'
      USING ERRCODE='55000';
  END IF;

  IF lower(trim(v_inv.email::text)) IS DISTINCT FROM v_auth_email THEN
    RAISE EXCEPTION
      'El correo autenticado no corresponde a esta invitación.'
      USING ERRCODE='42501';
  END IF;

  IF NULLIF(trim(v_inv.nombres),'') IS NULL
     OR NULLIF(trim(v_inv.apellidos),'') IS NULL
  THEN
    RAISE EXCEPTION
      'La invitación no contiene nombres y apellidos estructurados. Debe actualizarse antes de activarse.'
      USING ERRCODE='55000';
  END IF;

  SELECT r.codigo,r.ambito::text
    INTO v_role_code,v_ambito
  FROM public.roles r
  WHERE r.id=v_inv.role_id
    AND r.activo=true;

  IF v_role_code NOT IN ('club_admin','tournament_organizer') THEN
    RAISE EXCEPTION
      'El rol de esta invitación todavía no está habilitado para activación.'
      USING ERRCODE='22023';
  END IF;

  SELECT au.id,au.auth_user_id,au.activo
    INTO v_admin_id,v_existing_auth,v_activo
  FROM public.admin_users au
  WHERE lower(trim(au.email::text))=v_auth_email
  LIMIT 1;

  IF v_admin_id IS NULL THEN
    INSERT INTO public.admin_users(
      auth_user_id,email,nombres,apellidos,activo
    )
    VALUES(
      v_auth_uid,
      v_auth_email,
      v_inv.nombres,
      v_inv.apellidos,
      true
    )
    RETURNING id INTO v_admin_id;
  ELSE
    IF COALESCE(v_activo,false)=false THEN
      RAISE EXCEPTION
        'La cuenta administrativa asociada a este correo está inactiva.'
        USING ERRCODE='55000';
    END IF;

    IF v_existing_auth IS NULL THEN
      UPDATE public.admin_users
      SET auth_user_id=v_auth_uid,
          nombres=v_inv.nombres,
          apellidos=v_inv.apellidos
      WHERE id=v_admin_id;

    ELSIF v_existing_auth IS DISTINCT FROM v_auth_uid THEN
      RAISE EXCEPTION
        'Ya existe un usuario administrativo con este correo vinculado a otra identidad.'
        USING ERRCODE='23505';
    ELSE
      UPDATE public.admin_users
      SET nombres=v_inv.nombres,
          apellidos=v_inv.apellidos
      WHERE id=v_admin_id;
    END IF;
  END IF;

  SELECT ara.id
    INTO v_assignment_id
  FROM public.admin_role_assignments ara
  WHERE ara.admin_user_id=v_admin_id
    AND ara.role_id=v_inv.role_id
    AND ara.activo=true
    AND (
      (v_ambito='club'
       AND ara.club_id=v_inv.club_id
       AND ara.tournament_id IS NULL)
      OR
      (v_ambito='tournament'
       AND ara.tournament_id=v_inv.tournament_id
       AND ara.club_id IS NULL)
    )
  LIMIT 1;

  IF v_assignment_id IS NULL THEN
    INSERT INTO public.admin_role_assignments(
      admin_user_id,
      role_id,
      club_id,
      tournament_id,
      created_by,
      activo
    )
    VALUES(
      v_admin_id,
      v_inv.role_id,
      v_inv.club_id,
      v_inv.tournament_id,
      v_inv.invited_by,
      true
    )
    RETURNING id INTO v_assignment_id;
  END IF;

  UPDATE public.admin_user_invitations
  SET status='accepted'::public.estado_invitacion_admin,
      accepted_admin_user_id=v_admin_id,
      accepted_at=now()
  WHERE id=v_inv.id;

  RETURN jsonb_build_object(
    'ok',true,
    'invitationId',v_inv.id,
    'adminUserId',v_admin_id,
    'assignmentId',v_assignment_id,
    'roleCode',v_role_code,
    'clubId',v_inv.club_id,
    'tournamentId',v_inv.tournament_id,
    'email',v_auth_email,
    'status','accepted'
  );
END;
$$;

-- ============================================================================
-- 4. COMPATIBILIDAD TEMPORAL
-- ============================================================================

CREATE OR REPLACE FUNCTION public.aceptar_invitacion_admin(
  p_invitation_id uuid,
  p_nombres text,
  p_apellidos text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,auth,pg_temp
AS $$
BEGIN
  -- Si la invitación antigua todavía no tiene datos estructurados, esta firma
  -- permite completar la transición usando los datos que ya enviaba la UI vieja.
  UPDATE public.admin_user_invitations
  SET nombres=COALESCE(nombres,NULLIF(trim(p_nombres),'')),
      apellidos=COALESCE(apellidos,NULLIF(trim(p_apellidos),''))
  WHERE id=p_invitation_id
    AND status='pending'::public.estado_invitacion_admin;

  RETURN public.aceptar_invitacion_admin(p_invitation_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.aceptar_invitacion_organizador_torneo(
  p_invitation_id uuid,
  p_nombres text,
  p_apellidos text
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
  SELECT public.aceptar_invitacion_admin(
    p_invitation_id,p_nombres,p_apellidos
  );
$$;

-- ============================================================================
-- 5. LECTURA PÚBLICA LIMITADA
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_invitacion_admin_publica(
  p_invitation_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
SELECT jsonb_build_object(
  'invitationId',i.id,
  'displayName',i.display_name,
  'nombres',i.nombres,
  'apellidos',i.apellidos,
  'email',i.email,
  'phone',i.phone,
  'status',i.status,
  'invitedAt',i.invited_at,
  'expiresAt',i.expires_at,
  'roleCode',r.codigo,
  'roleName',r.nombre,
  'roleScope',r.ambito,
  'clubId',i.club_id,
  'clubName',c.nombre,
  'tournamentId',i.tournament_id,
  'tournamentName',t.nombre,
  'tournamentStartDate',t.fecha_inicio,
  'tournamentEndDate',t.fecha_fin
)
FROM public.admin_user_invitations i
JOIN public.roles r ON r.id=i.role_id
LEFT JOIN public.clubs c ON c.id=i.club_id
LEFT JOIN public.tournaments t ON t.id=i.tournament_id
WHERE i.id=p_invitation_id;
$$;

-- ============================================================================
-- 6. PRIVILEGIOS
-- ============================================================================

REVOKE ALL ON FUNCTION public.asignar_o_invitar_admin(
  text,text,text,text,text,uuid,uuid
) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.asignar_o_invitar_admin(
  text,text,text,text,text,uuid,uuid
) TO authenticated;

REVOKE ALL ON FUNCTION public.aceptar_invitacion_admin(uuid)
FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.aceptar_invitacion_admin(uuid)
TO authenticated;

-- La firma anterior conserva EXECUTE para compatibilidad temporal.
REVOKE ALL ON FUNCTION public.aceptar_invitacion_admin(uuid,text,text)
FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.aceptar_invitacion_admin(uuid,text,text)
TO authenticated;

COMMIT;
