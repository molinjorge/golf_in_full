-- ============================================================================
-- 177_telefono_permanente_admin_users.sql
-- TEE CENTRAL / GOLF IN FULL
--
-- OBJETIVO
-- Convertir el teléfono en parte permanente del perfil de admin_users.
--
-- REGLAS
--   - admin_users.telefono será la fuente permanente del teléfono administrativo.
--   - admin_user_invitations.phone conserva su función histórica/de invitación.
--   - al aceptar una invitación, phone se copia/actualiza en admin_users.telefono.
--   - al asignar/invitar un admin ya existente, un teléfono explícito actualiza
--     su perfil permanente.
--   - se recuperan teléfonos históricos desde invitaciones aceptadas.
--
-- NO CREA una tabla exclusiva para organizadores.
-- El perfil personal vive en admin_users; los roles/alcances viven en
-- admin_role_assignments.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. COLUMNA PERMANENTE DE TELÉFONO
-- ============================================================================

ALTER TABLE public.admin_users
    ADD COLUMN IF NOT EXISTS telefono text;

COMMENT ON COLUMN public.admin_users.telefono IS
'Teléfono permanente del usuario administrativo. Se conserva independientemente de sus roles o asignaciones.';


-- ============================================================================
-- 02. BACKFILL DESDE INVITACIONES ACEPTADAS
--
-- Toma la invitación aceptada más reciente con phone no vacío para cada
-- accepted_admin_user_id.
-- No sobreescribe un teléfono ya existente en admin_users.
-- ============================================================================

WITH telefonos_historicos AS (
    SELECT DISTINCT ON (i.accepted_admin_user_id)
        i.accepted_admin_user_id AS admin_user_id,
        NULLIF(trim(i.phone), '') AS telefono
    FROM public.admin_user_invitations i
    WHERE i.status = 'accepted'::public.estado_invitacion_admin
      AND i.accepted_admin_user_id IS NOT NULL
      AND NULLIF(trim(i.phone), '') IS NOT NULL
    ORDER BY
        i.accepted_admin_user_id,
        i.accepted_at DESC NULLS LAST,
        i.updated_at DESC,
        i.created_at DESC
)
UPDATE public.admin_users au
   SET telefono = th.telefono
  FROM telefonos_historicos th
 WHERE au.id = th.admin_user_id
   AND NULLIF(trim(au.telefono), '') IS NULL;


-- ============================================================================
-- 03. ACEPTAR INVITACIÓN ADMIN
--     Copia phone al perfil permanente.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.aceptar_invitacion_admin(
    p_invitation_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
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
  v_auth_uid := auth.uid();

  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
  END IF;

  SELECT lower(trim(u.email)), u.email_confirmed_at
    INTO v_auth_email, v_confirmed
  FROM auth.users u
  WHERE u.id = v_auth_uid;

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
  WHERE id = p_invitation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La invitación no existe.'
      USING ERRCODE='22023';
  END IF;

  IF v_inv.status <> 'pending'::public.estado_invitacion_admin THEN
    RAISE EXCEPTION
      'La invitación ya no está disponible.'
      USING ERRCODE='55000';
  END IF;

  IF v_inv.expires_at IS NOT NULL
     AND v_inv.expires_at <= now()
  THEN
    UPDATE public.admin_user_invitations
       SET status = 'expired'::public.estado_invitacion_admin,
           expired_at = COALESCE(expired_at, now())
     WHERE id = v_inv.id;

    RAISE EXCEPTION 'La invitación ha expirado.'
      USING ERRCODE='55000';
  END IF;

  IF lower(trim(v_inv.email::text)) IS DISTINCT FROM v_auth_email THEN
    RAISE EXCEPTION
      'El correo autenticado no corresponde a esta invitación.'
      USING ERRCODE='42501';
  END IF;

  IF NULLIF(trim(v_inv.nombres), '') IS NULL
     OR NULLIF(trim(v_inv.apellidos), '') IS NULL
  THEN
    RAISE EXCEPTION
      'La invitación no contiene nombres y apellidos estructurados. Debe actualizarse antes de activarse.'
      USING ERRCODE='55000';
  END IF;

  SELECT r.codigo, r.ambito::text
    INTO v_role_code, v_ambito
  FROM public.roles r
  WHERE r.id = v_inv.role_id
    AND r.activo = true;

  IF v_role_code NOT IN ('club_admin', 'tournament_organizer') THEN
    RAISE EXCEPTION
      'El rol de esta invitación todavía no está habilitado para activación.'
      USING ERRCODE='22023';
  END IF;

  SELECT au.id, au.auth_user_id, au.activo
    INTO v_admin_id, v_existing_auth, v_activo
  FROM public.admin_users au
  WHERE lower(trim(au.email::text)) = v_auth_email
  LIMIT 1;

  IF v_admin_id IS NULL THEN
    INSERT INTO public.admin_users(
      auth_user_id,
      email,
      nombres,
      apellidos,
      telefono,
      activo
    )
    VALUES(
      v_auth_uid,
      v_auth_email,
      v_inv.nombres,
      v_inv.apellidos,
      NULLIF(trim(v_inv.phone), ''),
      true
    )
    RETURNING id INTO v_admin_id;

  ELSE
    IF COALESCE(v_activo, false) = false THEN
      RAISE EXCEPTION
        'La cuenta administrativa asociada a este correo está inactiva.'
        USING ERRCODE='55000';
    END IF;

    IF v_existing_auth IS NULL THEN
      UPDATE public.admin_users
         SET auth_user_id = v_auth_uid,
             nombres = v_inv.nombres,
             apellidos = v_inv.apellidos,
             telefono = COALESCE(
               NULLIF(trim(v_inv.phone), ''),
               telefono
             )
       WHERE id = v_admin_id;

    ELSIF v_existing_auth IS DISTINCT FROM v_auth_uid THEN
      RAISE EXCEPTION
        'Ya existe un usuario administrativo con este correo vinculado a otra identidad.'
        USING ERRCODE='23505';

    ELSE
      UPDATE public.admin_users
         SET nombres = v_inv.nombres,
             apellidos = v_inv.apellidos,
             telefono = COALESCE(
               NULLIF(trim(v_inv.phone), ''),
               telefono
             )
       WHERE id = v_admin_id;
    END IF;
  END IF;

  SELECT ara.id
    INTO v_assignment_id
  FROM public.admin_role_assignments ara
  WHERE ara.admin_user_id = v_admin_id
    AND ara.role_id = v_inv.role_id
    AND ara.activo = true
    AND (
      (
        v_ambito = 'club'
        AND ara.club_id = v_inv.club_id
        AND ara.tournament_id IS NULL
      )
      OR
      (
        v_ambito = 'tournament'
        AND ara.tournament_id = v_inv.tournament_id
        AND ara.club_id IS NULL
      )
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
     SET status = 'accepted'::public.estado_invitacion_admin,
         accepted_admin_user_id = v_admin_id,
         accepted_at = now()
   WHERE id = v_inv.id;

  RETURN jsonb_build_object(
    'ok', true,
    'invitationId', v_inv.id,
    'adminUserId', v_admin_id,
    'assignmentId', v_assignment_id,
    'roleCode', v_role_code,
    'clubId', v_inv.club_id,
    'tournamentId', v_inv.tournament_id,
    'email', v_auth_email,
    'telefono',
      (
        SELECT au.telefono
        FROM public.admin_users au
        WHERE au.id = v_admin_id
      ),
    'status', 'accepted'
  );
END;
$function$;


-- ============================================================================
-- 04. ASIGNAR O INVITAR ADMIN — FIRMA ESTRUCTURADA
--
-- Para admin existente:
-- si p_phone viene informado, actualiza admin_users.telefono.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.asignar_o_invitar_admin(
    p_role_codigo text,
    p_nombres text,
    p_apellidos text,
    p_email text,
    p_phone text DEFAULT NULL::text,
    p_club_id uuid DEFAULT NULL::uuid,
    p_tournament_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
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

  v_role_code := lower(NULLIF(trim(p_role_codigo), ''));
  v_nombres := NULLIF(trim(p_nombres), '');
  v_apellidos := NULLIF(trim(p_apellidos), '');
  v_email := lower(NULLIF(trim(p_email), ''));
  v_phone := NULLIF(trim(p_phone), '');
  v_display_name := concat_ws(' ', v_nombres, v_apellidos);

  IF v_role_code NOT IN ('club_admin', 'tournament_organizer') THEN
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

  SELECT r.id, r.ambito::text
    INTO v_role_id, v_ambito
  FROM public.roles r
  WHERE r.codigo = v_role_code
    AND r.activo = true
  LIMIT 1;

  IF v_role_id IS NULL THEN
    RAISE EXCEPTION
      'El rol solicitado no existe o está inactivo.'
      USING ERRCODE='55000';
  END IF;

  IF v_ambito = 'club' THEN
    IF p_club_id IS NULL OR p_tournament_id IS NOT NULL THEN
      RAISE EXCEPTION
        'El rol club_admin requiere club_id y no admite tournament_id.'
        USING ERRCODE='22023';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.clubs c WHERE c.id = p_club_id
    ) THEN
      RAISE EXCEPTION 'El club indicado no existe.'
        USING ERRCODE='23503';
    END IF;

  ELSIF v_ambito = 'tournament' THEN
    IF p_tournament_id IS NULL OR p_club_id IS NOT NULL THEN
      RAISE EXCEPTION
        'El rol tournament_organizer requiere tournament_id y no admite club_id.'
        USING ERRCODE='22023';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.tournaments t WHERE t.id = p_tournament_id
    ) THEN
      RAISE EXCEPTION 'El torneo indicado no existe.'
        USING ERRCODE='23503';
    END IF;

  ELSE
    RAISE EXCEPTION
      'El ámbito del rol no está habilitado en esta operación.'
      USING ERRCODE='22023';
  END IF;

  SELECT au.id, au.auth_user_id, au.activo
    INTO v_admin_id, v_auth_uid, v_admin_activo
  FROM public.admin_users au
  WHERE lower(trim(au.email::text)) = v_email
  LIMIT 1;

  IF v_admin_id IS NOT NULL THEN
    IF COALESCE(v_admin_activo, false) = false THEN
      RAISE EXCEPTION
        'El correo corresponde a un usuario administrativo inactivo.'
        USING ERRCODE='55000';
    END IF;

    IF v_auth_uid IS NULL THEN
      RAISE EXCEPTION
        'El usuario administrativo existe pero todavía no está vinculado a Supabase Auth.'
        USING ERRCODE='55000';
    END IF;

    -- El teléfono explícitamente enviado pasa a ser el teléfono vigente
    -- del perfil permanente. Si viene NULL/vacío, se conserva el existente.
    IF v_phone IS NOT NULL THEN
      UPDATE public.admin_users
         SET telefono = v_phone
       WHERE id = v_admin_id;
    END IF;

    SELECT ara.id
      INTO v_assignment_id
    FROM public.admin_role_assignments ara
    WHERE ara.admin_user_id = v_admin_id
      AND ara.role_id = v_role_id
      AND ara.activo = true
      AND (
        (
          v_ambito = 'club'
          AND ara.club_id = p_club_id
          AND ara.tournament_id IS NULL
        )
        OR
        (
          v_ambito = 'tournament'
          AND ara.tournament_id = p_tournament_id
          AND ara.club_id IS NULL
        )
      )
    LIMIT 1;

    IF v_assignment_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'ok', true,
        'resultado', 'ALREADY_ASSIGNED',
        'adminUserId', v_admin_id,
        'assignmentId', v_assignment_id,
        'invitationId', NULL,
        'roleCode', v_role_code,
        'clubId', p_club_id,
        'tournamentId', p_tournament_id,
        'telefono',
          (
            SELECT au.telefono
            FROM public.admin_users au
            WHERE au.id = v_admin_id
          )
      );
    END IF;

    SELECT ara.id
      INTO v_assignment_id
    FROM public.admin_role_assignments ara
    WHERE ara.admin_user_id = v_admin_id
      AND ara.role_id = v_role_id
      AND ara.activo = false
      AND (
        (
          v_ambito = 'club'
          AND ara.club_id = p_club_id
          AND ara.tournament_id IS NULL
        )
        OR
        (
          v_ambito = 'tournament'
          AND ara.tournament_id = p_tournament_id
          AND ara.club_id IS NULL
        )
      )
    ORDER BY ara.created_at DESC
    LIMIT 1;

    IF v_assignment_id IS NOT NULL THEN
      UPDATE public.admin_role_assignments
         SET activo = true,
             fecha_baja = NULL,
             dado_de_baja_por = NULL,
             motivo_baja = NULL
       WHERE id = v_assignment_id;

      RETURN jsonb_build_object(
        'ok', true,
        'resultado', 'ASSIGNED',
        'assignmentAction', 'REACTIVATED',
        'adminUserId', v_admin_id,
        'assignmentId', v_assignment_id,
        'invitationId', NULL,
        'roleCode', v_role_code,
        'clubId', p_club_id,
        'tournamentId', p_tournament_id,
        'telefono',
          (
            SELECT au.telefono
            FROM public.admin_users au
            WHERE au.id = v_admin_id
          )
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
      'ok', true,
      'resultado', 'ASSIGNED',
      'assignmentAction', 'CREATED',
      'adminUserId', v_admin_id,
      'assignmentId', v_assignment_id,
      'invitationId', NULL,
      'roleCode', v_role_code,
      'clubId', p_club_id,
      'tournamentId', p_tournament_id,
      'telefono',
        (
          SELECT au.telefono
          FROM public.admin_users au
          WHERE au.id = v_admin_id
        )
    );
  END IF;

  SELECT i.id
    INTO v_invitation_id
  FROM public.admin_user_invitations i
  WHERE lower(trim(i.email::text)) = v_email
    AND i.role_id = v_role_id
    AND i.status = 'pending'::public.estado_invitacion_admin
    AND (
      (
        v_ambito = 'club'
        AND i.club_id = p_club_id
        AND i.tournament_id IS NULL
      )
      OR
      (
        v_ambito = 'tournament'
        AND i.tournament_id = p_tournament_id
        AND i.club_id IS NULL
      )
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
       SET display_name = v_display_name,
           nombres = v_nombres,
           apellidos = v_apellidos,
           phone = v_phone
     WHERE id = v_invitation_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'resultado', 'INVITED',
    'adminUserId', NULL,
    'assignmentId', NULL,
    'invitationId', v_invitation_id,
    'roleCode', v_role_code,
    'clubId', p_club_id,
    'tournamentId', p_tournament_id,
    'telefono', v_phone
  );
END;
$function$;


-- ============================================================================
-- 05. ASIGNAR O INVITAR ADMIN — FIRMA LEGACY display_name
--
-- Se conserva por compatibilidad. También actualiza teléfono cuando el admin
-- ya existe.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.asignar_o_invitar_admin(
    p_role_codigo text,
    p_display_name text,
    p_email text,
    p_phone text DEFAULT NULL::text,
    p_club_id uuid DEFAULT NULL::uuid,
    p_tournament_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_actor uuid;
  v_role_id uuid;
  v_role_code text;
  v_ambito text;
  v_email text;
  v_name text;
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

  SELECT public.current_admin_id() INTO v_actor;

  IF v_actor IS NULL THEN
    RAISE EXCEPTION
      'No se encontró el usuario administrativo del Superadmin autenticado.'
      USING ERRCODE='42501';
  END IF;

  v_role_code := lower(NULLIF(trim(p_role_codigo), ''));
  v_email := lower(NULLIF(trim(p_email), ''));
  v_name := NULLIF(trim(p_display_name), '');
  v_phone := NULLIF(trim(p_phone), '');

  IF v_role_code NOT IN ('club_admin', 'tournament_organizer') THEN
    RAISE EXCEPTION
      'El rol solicitado todavía no está habilitado para invitaciones administrativas.'
      USING ERRCODE='22023';
  END IF;

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'El email es obligatorio.' USING ERRCODE='22023';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'El nombre es obligatorio.' USING ERRCODE='22023';
  END IF;

  SELECT r.id, r.ambito::text
    INTO v_role_id, v_ambito
  FROM public.roles r
  WHERE r.codigo = v_role_code
    AND r.activo = true
  LIMIT 1;

  IF v_role_id IS NULL THEN
    RAISE EXCEPTION
      'El rol solicitado no existe o está inactivo.'
      USING ERRCODE='55000';
  END IF;

  IF v_ambito = 'club' THEN
    IF p_club_id IS NULL OR p_tournament_id IS NOT NULL THEN
      RAISE EXCEPTION
        'El rol club_admin requiere club_id y no admite tournament_id.'
        USING ERRCODE='22023';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.clubs WHERE id = p_club_id
    ) THEN
      RAISE EXCEPTION 'El club indicado no existe.' USING ERRCODE='23503';
    END IF;

  ELSIF v_ambito = 'tournament' THEN
    IF p_tournament_id IS NULL OR p_club_id IS NOT NULL THEN
      RAISE EXCEPTION
        'El rol tournament_organizer requiere tournament_id y no admite club_id.'
        USING ERRCODE='22023';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.tournaments WHERE id = p_tournament_id
    ) THEN
      RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='23503';
    END IF;

  ELSE
    RAISE EXCEPTION
      'El ámbito del rol no está habilitado en esta operación.'
      USING ERRCODE='22023';
  END IF;

  SELECT au.id, au.auth_user_id, au.activo
    INTO v_admin_id, v_auth_uid, v_admin_activo
  FROM public.admin_users au
  WHERE lower(trim(au.email::text)) = v_email
  LIMIT 1;

  IF v_admin_id IS NOT NULL THEN
    IF COALESCE(v_admin_activo, false) = false THEN
      RAISE EXCEPTION
        'El correo corresponde a un usuario administrativo inactivo.'
        USING ERRCODE='55000';
    END IF;

    IF v_auth_uid IS NULL THEN
      RAISE EXCEPTION
        'El usuario administrativo existe pero todavía no está vinculado a Supabase Auth.'
        USING ERRCODE='55000';
    END IF;

    IF v_phone IS NOT NULL THEN
      UPDATE public.admin_users
         SET telefono = v_phone
       WHERE id = v_admin_id;
    END IF;

    SELECT ara.id
      INTO v_assignment_id
    FROM public.admin_role_assignments ara
    WHERE ara.admin_user_id = v_admin_id
      AND ara.role_id = v_role_id
      AND ara.activo = true
      AND (
        (
          v_ambito = 'club'
          AND ara.club_id = p_club_id
          AND ara.tournament_id IS NULL
        )
        OR
        (
          v_ambito = 'tournament'
          AND ara.tournament_id = p_tournament_id
          AND ara.club_id IS NULL
        )
      )
    LIMIT 1;

    IF v_assignment_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'ok', true,
        'resultado', 'ALREADY_ASSIGNED',
        'adminUserId', v_admin_id,
        'assignmentId', v_assignment_id,
        'invitationId', NULL,
        'roleCode', v_role_code,
        'clubId', p_club_id,
        'tournamentId', p_tournament_id,
        'telefono',
          (
            SELECT au.telefono
            FROM public.admin_users au
            WHERE au.id = v_admin_id
          )
      );
    END IF;

    SELECT ara.id
      INTO v_assignment_id
    FROM public.admin_role_assignments ara
    WHERE ara.admin_user_id = v_admin_id
      AND ara.role_id = v_role_id
      AND ara.activo = false
      AND (
        (
          v_ambito = 'club'
          AND ara.club_id = p_club_id
          AND ara.tournament_id IS NULL
        )
        OR
        (
          v_ambito = 'tournament'
          AND ara.tournament_id = p_tournament_id
          AND ara.club_id IS NULL
        )
      )
    ORDER BY ara.created_at DESC
    LIMIT 1;

    IF v_assignment_id IS NOT NULL THEN
      UPDATE public.admin_role_assignments
         SET activo = true,
             fecha_baja = NULL,
             dado_de_baja_por = NULL,
             motivo_baja = NULL
       WHERE id = v_assignment_id;

      RETURN jsonb_build_object(
        'ok', true,
        'resultado', 'ASSIGNED',
        'assignmentAction', 'REACTIVATED',
        'adminUserId', v_admin_id,
        'assignmentId', v_assignment_id,
        'invitationId', NULL,
        'roleCode', v_role_code,
        'clubId', p_club_id,
        'tournamentId', p_tournament_id,
        'telefono',
          (
            SELECT au.telefono
            FROM public.admin_users au
            WHERE au.id = v_admin_id
          )
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
      'ok', true,
      'resultado', 'ASSIGNED',
      'assignmentAction', 'CREATED',
      'adminUserId', v_admin_id,
      'assignmentId', v_assignment_id,
      'invitationId', NULL,
      'roleCode', v_role_code,
      'clubId', p_club_id,
      'tournamentId', p_tournament_id,
      'telefono',
        (
          SELECT au.telefono
          FROM public.admin_users au
          WHERE au.id = v_admin_id
        )
    );
  END IF;

  SELECT i.id
    INTO v_invitation_id
  FROM public.admin_user_invitations i
  WHERE lower(trim(i.email::text)) = v_email
    AND i.role_id = v_role_id
    AND i.status = 'pending'::public.estado_invitacion_admin
    AND (
      (
        v_ambito = 'club'
        AND i.club_id = p_club_id
        AND i.tournament_id IS NULL
      )
      OR
      (
        v_ambito = 'tournament'
        AND i.tournament_id = p_tournament_id
        AND i.club_id IS NULL
      )
    )
  LIMIT 1;

  IF v_invitation_id IS NULL THEN
    INSERT INTO public.admin_user_invitations(
      display_name,
      email,
      phone,
      role_id,
      club_id,
      tournament_id,
      status,
      invited_by
    )
    VALUES(
      v_name,
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
       SET display_name = v_name,
           phone = v_phone
     WHERE id = v_invitation_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'resultado', 'INVITED',
    'adminUserId', NULL,
    'assignmentId', NULL,
    'invitationId', v_invitation_id,
    'roleCode', v_role_code,
    'clubId', p_club_id,
    'tournamentId', p_tournament_id,
    'telefono', v_phone
  );
END;
$function$;

COMMIT;
