-- ============================================================================
-- 169_generalizacion_invitaciones_administrativas.sql
-- GOLF IN FULL / Tee Central
-- ============================================================================

BEGIN;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
    WHERE n.nspname='public' AND t.typname='estado_invitacion_organizador_torneo'
  ) AND NOT EXISTS (
    SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
    WHERE n.nspname='public' AND t.typname='estado_invitacion_admin'
  ) THEN
    ALTER TYPE public.estado_invitacion_organizador_torneo
      RENAME TO estado_invitacion_admin;
  END IF;
END $$;

DO $$
BEGIN
  IF to_regclass('public.tournament_organizer_invitations') IS NOT NULL
     AND to_regclass('public.admin_user_invitations') IS NULL THEN
    ALTER TABLE public.tournament_organizer_invitations
      RENAME TO admin_user_invitations;
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='admin_user_invitations'
      AND column_name='organizer_name'
  ) THEN
    ALTER TABLE public.admin_user_invitations
      RENAME COLUMN organizer_name TO display_name;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='admin_user_invitations'
      AND column_name='organizer_email'
  ) THEN
    ALTER TABLE public.admin_user_invitations
      RENAME COLUMN organizer_email TO email;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='admin_user_invitations'
      AND column_name='organizer_phone'
  ) THEN
    ALTER TABLE public.admin_user_invitations
      RENAME COLUMN organizer_phone TO phone;
  END IF;
END $$;

ALTER TABLE public.admin_user_invitations
  ADD COLUMN IF NOT EXISTS role_id uuid REFERENCES public.roles(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS club_id uuid REFERENCES public.clubs(id) ON DELETE RESTRICT;

ALTER TABLE public.admin_user_invitations
  ALTER COLUMN tournament_id DROP NOT NULL;

UPDATE public.admin_user_invitations i
SET role_id = r.id
FROM public.roles r
WHERE i.role_id IS NULL
  AND r.codigo='tournament_organizer';

ALTER TABLE public.admin_user_invitations
  ALTER COLUMN role_id SET NOT NULL;

ALTER TABLE public.admin_user_invitations
  DROP CONSTRAINT IF EXISTS tournament_organizer_invitations_name_not_blank,
  DROP CONSTRAINT IF EXISTS tournament_organizer_invitations_email_not_blank,
  DROP CONSTRAINT IF EXISTS tournament_organizer_invitations_acceptance_consistent;

ALTER TABLE public.admin_user_invitations
  ADD CONSTRAINT admin_user_invitations_display_name_not_blank
    CHECK (length(trim(display_name)) > 0),
  ADD CONSTRAINT admin_user_invitations_email_not_blank
    CHECK (length(trim(email::text)) > 0),
  ADD CONSTRAINT admin_user_invitations_acceptance_consistent
    CHECK (
      (status='accepted'::public.estado_invitacion_admin
       AND accepted_admin_user_id IS NOT NULL
       AND accepted_at IS NOT NULL)
      OR
      status<>'accepted'::public.estado_invitacion_admin
    );

CREATE OR REPLACE FUNCTION public.validar_ambito_invitacion_admin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_ambito text;
  v_activo boolean;
BEGIN
  SELECT r.ambito::text, r.activo
    INTO v_ambito, v_activo
  FROM public.roles r
  WHERE r.id=NEW.role_id;

  IF v_ambito IS NULL THEN
    RAISE EXCEPTION 'El rol administrativo de la invitación no existe.'
      USING ERRCODE='23503';
  END IF;

  IF COALESCE(v_activo,false)=false THEN
    RAISE EXCEPTION 'El rol administrativo de la invitación está inactivo.'
      USING ERRCODE='55000';
  END IF;

  CASE v_ambito
    WHEN 'global' THEN
      IF NEW.club_id IS NOT NULL OR NEW.tournament_id IS NOT NULL THEN
        RAISE EXCEPTION 'Un rol global no debe tener club ni torneo.'
          USING ERRCODE='22023';
      END IF;
    WHEN 'club' THEN
      IF NEW.club_id IS NULL OR NEW.tournament_id IS NOT NULL THEN
        RAISE EXCEPTION 'Un rol de club requiere club_id y no debe tener tournament_id.'
          USING ERRCODE='22023';
      END IF;
    WHEN 'tournament' THEN
      IF NEW.tournament_id IS NULL OR NEW.club_id IS NOT NULL THEN
        RAISE EXCEPTION 'Un rol de torneo requiere tournament_id y no debe tener club_id.'
          USING ERRCODE='22023';
      END IF;
    ELSE
      RAISE EXCEPTION 'Ámbito de rol no soportado: %', v_ambito
        USING ERRCODE='22023';
  END CASE;

  NEW.email := lower(trim(NEW.email::text));
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_validar_ambito_invitacion_admin
ON public.admin_user_invitations;

CREATE TRIGGER trg_validar_ambito_invitacion_admin
BEFORE INSERT OR UPDATE OF role_id,club_id,tournament_id,email
ON public.admin_user_invitations
FOR EACH ROW EXECUTE FUNCTION public.validar_ambito_invitacion_admin();

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_trigger tg
    JOIN pg_class c ON c.oid=tg.tgrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public'
      AND c.relname='admin_user_invitations'
      AND tg.tgname='trg_tournament_organizer_invitations_updated_at'
      AND NOT tg.tgisinternal
  ) AND NOT EXISTS (
    SELECT 1 FROM pg_trigger tg
    JOIN pg_class c ON c.oid=tg.tgrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public'
      AND c.relname='admin_user_invitations'
      AND tg.tgname='trg_admin_user_invitations_updated_at'
      AND NOT tg.tgisinternal
  ) THEN
    ALTER TRIGGER trg_tournament_organizer_invitations_updated_at
    ON public.admin_user_invitations
    RENAME TO trg_admin_user_invitations_updated_at;
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public'
      AND tablename='admin_user_invitations'
      AND policyname='tournament_organizer_invitations_select'
  ) THEN
    ALTER POLICY tournament_organizer_invitations_select
    ON public.admin_user_invitations
    RENAME TO admin_user_invitations_select;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public'
      AND tablename='admin_user_invitations'
      AND policyname='tournament_organizer_invitations_write'
  ) THEN
    ALTER POLICY tournament_organizer_invitations_write
    ON public.admin_user_invitations
    RENAME TO admin_user_invitations_write;
  END IF;
END $$;

DROP INDEX IF EXISTS public.uq_tournament_organizer_invitation_pending;
DROP INDEX IF EXISTS public.idx_tournament_organizer_invitations_tournament;
DROP INDEX IF EXISTS public.idx_tournament_organizer_invitations_status;
DROP INDEX IF EXISTS public.idx_tournament_organizer_invitations_email_lower;

CREATE INDEX IF NOT EXISTS idx_admin_user_invitations_email
  ON public.admin_user_invitations (lower(email::text));
CREATE INDEX IF NOT EXISTS idx_admin_user_invitations_status
  ON public.admin_user_invitations (status);
CREATE INDEX IF NOT EXISTS idx_admin_user_invitations_role
  ON public.admin_user_invitations (role_id);
CREATE INDEX IF NOT EXISTS idx_admin_user_invitations_club
  ON public.admin_user_invitations (club_id) WHERE club_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_admin_user_invitations_tournament
  ON public.admin_user_invitations (tournament_id) WHERE tournament_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_admin_invitation_pending_global
  ON public.admin_user_invitations (lower(email::text),role_id)
  WHERE status='pending'::public.estado_invitacion_admin
    AND club_id IS NULL AND tournament_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_admin_invitation_pending_club
  ON public.admin_user_invitations (lower(email::text),role_id,club_id)
  WHERE status='pending'::public.estado_invitacion_admin
    AND club_id IS NOT NULL AND tournament_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_admin_invitation_pending_tournament
  ON public.admin_user_invitations (lower(email::text),role_id,tournament_id)
  WHERE status='pending'::public.estado_invitacion_admin
    AND tournament_id IS NOT NULL AND club_id IS NULL;

CREATE OR REPLACE FUNCTION public.asignar_o_invitar_admin(
  p_role_codigo text,
  p_display_name text,
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
    RAISE EXCEPTION 'Sólo el Superadmin puede asignar o invitar usuarios administrativos.'
      USING ERRCODE='42501';
  END IF;

  SELECT public.current_admin_id() INTO v_actor;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'No se encontró el usuario administrativo del Superadmin autenticado.'
      USING ERRCODE='42501';
  END IF;

  v_role_code := lower(NULLIF(trim(p_role_codigo),''));
  v_email := lower(NULLIF(trim(p_email),''));
  v_name := NULLIF(trim(p_display_name),'');
  v_phone := NULLIF(trim(p_phone),'');

  IF v_role_code NOT IN ('club_admin','tournament_organizer') THEN
    RAISE EXCEPTION 'El rol solicitado todavía no está habilitado para invitaciones administrativas.'
      USING ERRCODE='22023';
  END IF;
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'El email es obligatorio.' USING ERRCODE='22023';
  END IF;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'El nombre es obligatorio.' USING ERRCODE='22023';
  END IF;

  SELECT r.id,r.ambito::text
    INTO v_role_id,v_ambito
  FROM public.roles r
  WHERE r.codigo=v_role_code AND r.activo=true
  LIMIT 1;

  IF v_role_id IS NULL THEN
    RAISE EXCEPTION 'El rol solicitado no existe o está inactivo.'
      USING ERRCODE='55000';
  END IF;

  IF v_ambito='club' THEN
    IF p_club_id IS NULL OR p_tournament_id IS NOT NULL THEN
      RAISE EXCEPTION 'El rol club_admin requiere club_id y no admite tournament_id.'
        USING ERRCODE='22023';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.clubs WHERE id=p_club_id) THEN
      RAISE EXCEPTION 'El club indicado no existe.' USING ERRCODE='23503';
    END IF;
  ELSIF v_ambito='tournament' THEN
    IF p_tournament_id IS NULL OR p_club_id IS NOT NULL THEN
      RAISE EXCEPTION 'El rol tournament_organizer requiere tournament_id y no admite club_id.'
        USING ERRCODE='22023';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.tournaments WHERE id=p_tournament_id) THEN
      RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='23503';
    END IF;
  ELSE
    RAISE EXCEPTION 'El ámbito del rol no está habilitado en esta operación.'
      USING ERRCODE='22023';
  END IF;

  SELECT au.id,au.auth_user_id,au.activo
    INTO v_admin_id,v_auth_uid,v_admin_activo
  FROM public.admin_users au
  WHERE lower(trim(au.email::text))=v_email
  LIMIT 1;

  IF v_admin_id IS NOT NULL THEN
    IF COALESCE(v_admin_activo,false)=false THEN
      RAISE EXCEPTION 'El correo corresponde a un usuario administrativo inactivo.'
        USING ERRCODE='55000';
    END IF;
    IF v_auth_uid IS NULL THEN
      RAISE EXCEPTION 'El usuario administrativo existe pero todavía no está vinculado a Supabase Auth.'
        USING ERRCODE='55000';
    END IF;

    SELECT ara.id INTO v_assignment_id
    FROM public.admin_role_assignments ara
    WHERE ara.admin_user_id=v_admin_id
      AND ara.role_id=v_role_id
      AND ara.activo=true
      AND (
        (v_ambito='club' AND ara.club_id=p_club_id AND ara.tournament_id IS NULL)
        OR
        (v_ambito='tournament' AND ara.tournament_id=p_tournament_id AND ara.club_id IS NULL)
      )
    LIMIT 1;

    IF v_assignment_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'ok',true,'resultado','ALREADY_ASSIGNED',
        'adminUserId',v_admin_id,'assignmentId',v_assignment_id,
        'invitationId',NULL,'roleCode',v_role_code,
        'clubId',p_club_id,'tournamentId',p_tournament_id
      );
    END IF;

    SELECT ara.id INTO v_assignment_id
    FROM public.admin_role_assignments ara
    WHERE ara.admin_user_id=v_admin_id
      AND ara.role_id=v_role_id
      AND ara.activo=false
      AND (
        (v_ambito='club' AND ara.club_id=p_club_id AND ara.tournament_id IS NULL)
        OR
        (v_ambito='tournament' AND ara.tournament_id=p_tournament_id AND ara.club_id IS NULL)
      )
    ORDER BY ara.created_at DESC
    LIMIT 1;

    IF v_assignment_id IS NOT NULL THEN
      UPDATE public.admin_role_assignments
      SET activo=true,fecha_baja=NULL,dado_de_baja_por=NULL,motivo_baja=NULL
      WHERE id=v_assignment_id;

      RETURN jsonb_build_object(
        'ok',true,'resultado','ASSIGNED','assignmentAction','REACTIVATED',
        'adminUserId',v_admin_id,'assignmentId',v_assignment_id,
        'invitationId',NULL,'roleCode',v_role_code,
        'clubId',p_club_id,'tournamentId',p_tournament_id
      );
    END IF;

    INSERT INTO public.admin_role_assignments(
      admin_user_id,role_id,club_id,tournament_id,created_by,activo
    )
    VALUES(v_admin_id,v_role_id,p_club_id,p_tournament_id,v_actor,true)
    RETURNING id INTO v_assignment_id;

    RETURN jsonb_build_object(
      'ok',true,'resultado','ASSIGNED','assignmentAction','CREATED',
      'adminUserId',v_admin_id,'assignmentId',v_assignment_id,
      'invitationId',NULL,'roleCode',v_role_code,
      'clubId',p_club_id,'tournamentId',p_tournament_id
    );
  END IF;

  SELECT i.id INTO v_invitation_id
  FROM public.admin_user_invitations i
  WHERE lower(trim(i.email::text))=v_email
    AND i.role_id=v_role_id
    AND i.status='pending'::public.estado_invitacion_admin
    AND (
      (v_ambito='club' AND i.club_id=p_club_id AND i.tournament_id IS NULL)
      OR
      (v_ambito='tournament' AND i.tournament_id=p_tournament_id AND i.club_id IS NULL)
    )
  LIMIT 1;

  IF v_invitation_id IS NULL THEN
    INSERT INTO public.admin_user_invitations(
      display_name,email,phone,role_id,club_id,tournament_id,status,invited_by
    )
    VALUES(
      v_name,v_email,v_phone,v_role_id,p_club_id,p_tournament_id,
      'pending'::public.estado_invitacion_admin,v_actor
    )
    RETURNING id INTO v_invitation_id;
  ELSE
    UPDATE public.admin_user_invitations
    SET display_name=v_name,phone=v_phone
    WHERE id=v_invitation_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',true,'resultado','INVITED',
    'adminUserId',NULL,'assignmentId',NULL,
    'invitationId',v_invitation_id,'roleCode',v_role_code,
    'clubId',p_club_id,'tournamentId',p_tournament_id
  );
END $$;

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

  SELECT lower(trim(email)),email_confirmed_at
  INTO v_auth_email,v_confirmed
  FROM auth.users WHERE id=v_auth_uid;

  IF v_auth_email IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar el correo del usuario autenticado.'
      USING ERRCODE='42501';
  END IF;
  IF v_confirmed IS NULL THEN
    RAISE EXCEPTION 'Debes verificar tu correo electrónico antes de aceptar la invitación.'
      USING ERRCODE='42501';
  END IF;
  IF NULLIF(trim(p_nombres),'') IS NULL THEN
    RAISE EXCEPTION 'El nombre es obligatorio.' USING ERRCODE='22023';
  END IF;
  IF NULLIF(trim(p_apellidos),'') IS NULL THEN
    RAISE EXCEPTION 'Los apellidos son obligatorios.' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_inv
  FROM public.admin_user_invitations
  WHERE id=p_invitation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La invitación no existe.' USING ERRCODE='22023';
  END IF;
  IF v_inv.status<>'pending'::public.estado_invitacion_admin THEN
    RAISE EXCEPTION 'La invitación ya no está disponible.' USING ERRCODE='55000';
  END IF;
  IF v_inv.expires_at IS NOT NULL AND v_inv.expires_at<=now() THEN
    UPDATE public.admin_user_invitations
    SET status='expired'::public.estado_invitacion_admin,
        expired_at=COALESCE(expired_at,now())
    WHERE id=v_inv.id;
    RAISE EXCEPTION 'La invitación ha expirado.' USING ERRCODE='55000';
  END IF;
  IF lower(trim(v_inv.email::text)) IS DISTINCT FROM v_auth_email THEN
    RAISE EXCEPTION 'El correo autenticado no corresponde a esta invitación.'
      USING ERRCODE='42501';
  END IF;

  SELECT r.codigo,r.ambito::text
  INTO v_role_code,v_ambito
  FROM public.roles r
  WHERE r.id=v_inv.role_id AND r.activo=true;

  IF v_role_code NOT IN ('club_admin','tournament_organizer') THEN
    RAISE EXCEPTION 'El rol de esta invitación todavía no está habilitado para activación.'
      USING ERRCODE='22023';
  END IF;

  SELECT au.id,au.auth_user_id,au.activo
  INTO v_admin_id,v_existing_auth,v_activo
  FROM public.admin_users au
  WHERE lower(trim(au.email::text))=v_auth_email
  LIMIT 1;

  IF v_admin_id IS NULL THEN
    INSERT INTO public.admin_users(auth_user_id,email,nombres,apellidos,activo)
    VALUES(v_auth_uid,v_auth_email,trim(p_nombres),trim(p_apellidos),true)
    RETURNING id INTO v_admin_id;
  ELSE
    IF COALESCE(v_activo,false)=false THEN
      RAISE EXCEPTION 'La cuenta administrativa asociada a este correo está inactiva.'
        USING ERRCODE='55000';
    END IF;

    IF v_existing_auth IS NULL THEN
      UPDATE public.admin_users
      SET auth_user_id=v_auth_uid,nombres=trim(p_nombres),apellidos=trim(p_apellidos)
      WHERE id=v_admin_id;
    ELSIF v_existing_auth IS DISTINCT FROM v_auth_uid THEN
      RAISE EXCEPTION 'Ya existe un usuario administrativo con este correo vinculado a otra identidad.'
        USING ERRCODE='23505';
    ELSE
      UPDATE public.admin_users
      SET nombres=trim(p_nombres),apellidos=trim(p_apellidos)
      WHERE id=v_admin_id;
    END IF;
  END IF;

  SELECT ara.id INTO v_assignment_id
  FROM public.admin_role_assignments ara
  WHERE ara.admin_user_id=v_admin_id
    AND ara.role_id=v_inv.role_id
    AND ara.activo=true
    AND (
      (v_ambito='club' AND ara.club_id=v_inv.club_id AND ara.tournament_id IS NULL)
      OR
      (v_ambito='tournament' AND ara.tournament_id=v_inv.tournament_id AND ara.club_id IS NULL)
    )
  LIMIT 1;

  IF v_assignment_id IS NULL THEN
    INSERT INTO public.admin_role_assignments(
      admin_user_id,role_id,club_id,tournament_id,created_by,activo
    )
    VALUES(
      v_admin_id,v_inv.role_id,v_inv.club_id,v_inv.tournament_id,v_inv.invited_by,true
    )
    RETURNING id INTO v_assignment_id;
  END IF;

  UPDATE public.admin_user_invitations
  SET status='accepted'::public.estado_invitacion_admin,
      accepted_admin_user_id=v_admin_id,
      accepted_at=now()
  WHERE id=v_inv.id;

  RETURN jsonb_build_object(
    'ok',true,'invitationId',v_inv.id,'adminUserId',v_admin_id,
    'assignmentId',v_assignment_id,'roleCode',v_role_code,
    'clubId',v_inv.club_id,'tournamentId',v_inv.tournament_id,
    'email',v_auth_email,'status','accepted'
  );
END $$;

CREATE OR REPLACE FUNCTION public.obtener_invitacion_admin_publica(
  p_invitation_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
SELECT jsonb_build_object(
  'invitationId',i.id,
  'displayName',i.display_name,
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

CREATE OR REPLACE FUNCTION public.provisionar_torneo(
  p_nombre text,
  p_fecha_inicio date,
  p_fecha_fin date,
  p_organizer_name text,
  p_organizer_email text,
  p_platform_fee numeric,
  p_contractor_name text,
  p_organizer_phone text DEFAULT NULL,
  p_contractor_rfc text DEFAULT NULL,
  p_contractor_address text DEFAULT NULL,
  p_contractor_phone_1 text DEFAULT NULL,
  p_contractor_phone_2 text DEFAULT NULL,
  p_contractor_email text DEFAULT NULL,
  p_currency text DEFAULT 'MXN',
  p_paid boolean DEFAULT false,
  p_paid_at timestamptz DEFAULT NULL,
  p_payment_reference text DEFAULT NULL,
  p_payment_notes text DEFAULT NULL,
  p_fiscal_document_path text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_admin_id uuid;
  v_tournament_id uuid;
  v_profile_id uuid;
  v_name text;
  v_email text;
  v_phone text;
  v_result jsonb;
  v_resultado text;
  v_admin_user_id uuid;
  v_assignment_id uuid;
  v_invitation_id uuid;
  v_mode text;
  v_paid_at timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
  END IF;
  IF NOT public.is_superadmin(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo el Superadmin puede provisionar torneos.'
      USING ERRCODE='42501';
  END IF;

  SELECT public.current_admin_id() INTO v_admin_id;
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No se encontró el usuario administrativo del Superadmin autenticado.'
      USING ERRCODE='42501';
  END IF;

  IF NULLIF(trim(p_nombre),'') IS NULL THEN
    RAISE EXCEPTION 'El nombre del torneo es obligatorio.' USING ERRCODE='22023';
  END IF;
  IF p_fecha_inicio IS NULL OR p_fecha_fin IS NULL THEN
    RAISE EXCEPTION 'Las fechas inicial y final son obligatorias.' USING ERRCODE='22023';
  END IF;
  IF p_fecha_fin<p_fecha_inicio THEN
    RAISE EXCEPTION 'La fecha final no puede ser anterior a la fecha inicial.'
      USING ERRCODE='22023';
  END IF;

  v_name:=NULLIF(trim(p_organizer_name),'');
  v_email:=lower(NULLIF(trim(p_organizer_email),''));
  v_phone:=NULLIF(trim(p_organizer_phone),'');

  IF v_name IS NULL OR v_email IS NULL THEN
    RAISE EXCEPTION 'Nombre y email del organizador son obligatorios.'
      USING ERRCODE='22023';
  END IF;
  IF p_platform_fee IS NULL OR p_platform_fee<0 THEN
    RAISE EXCEPTION 'El valor de alquiler de la plataforma debe ser cero o mayor.'
      USING ERRCODE='22023';
  END IF;
  IF NULLIF(trim(p_contractor_name),'') IS NULL THEN
    RAISE EXCEPTION 'El nombre o razón social del contratante es obligatorio.'
      USING ERRCODE='22023';
  END IF;
  IF NULLIF(trim(p_currency),'') IS NULL THEN
    RAISE EXCEPTION 'La moneda es obligatoria.' USING ERRCODE='22023';
  END IF;

  v_paid_at:=CASE WHEN COALESCE(p_paid,false)
    THEN COALESCE(p_paid_at,now()) ELSE NULL END;

  INSERT INTO public.tournaments(
    nombre,fecha_inicio,fecha_fin,estatus,estado_servicio,activo,created_by
  )
  VALUES(
    trim(p_nombre),p_fecha_inicio,p_fecha_fin,
    'planificado'::public.estatus_torneo,
    'provisionado'::public.estado_servicio_torneo,
    false,v_admin_id
  )
  RETURNING id INTO v_tournament_id;

  INSERT INTO public.tournament_commercial_profiles(
    tournament_id,contractor_name,contractor_rfc,contractor_address,
    contractor_phone_1,contractor_phone_2,contractor_email,
    platform_fee,currency,paid,paid_at,payment_reference,payment_notes,
    fiscal_document_path,created_by
  )
  VALUES(
    v_tournament_id,trim(p_contractor_name),
    NULLIF(trim(p_contractor_rfc),''),
    NULLIF(trim(p_contractor_address),''),
    NULLIF(trim(p_contractor_phone_1),''),
    NULLIF(trim(p_contractor_phone_2),''),
    lower(NULLIF(trim(p_contractor_email),'')),
    p_platform_fee,upper(trim(p_currency)),COALESCE(p_paid,false),v_paid_at,
    NULLIF(trim(p_payment_reference),''),
    NULLIF(trim(p_payment_notes),''),
    NULLIF(trim(p_fiscal_document_path),''),
    v_admin_id
  )
  RETURNING id INTO v_profile_id;

  v_result:=public.asignar_o_invitar_admin(
    'tournament_organizer',v_name,v_email,v_phone,NULL,v_tournament_id
  );

  v_resultado:=v_result->>'resultado';
  v_admin_user_id:=NULLIF(v_result->>'adminUserId','')::uuid;
  v_assignment_id:=NULLIF(v_result->>'assignmentId','')::uuid;
  v_invitation_id:=NULLIF(v_result->>'invitationId','')::uuid;
  v_mode:=CASE WHEN v_resultado='INVITED' THEN 'INVITATION' ELSE 'EXISTING' END;

  RETURN jsonb_build_object(
    'ok',true,'tournamentId',v_tournament_id,
    'commercialProfileId',v_profile_id,
    'estadoServicio','provisionado','activo',false,
    'organizer',jsonb_build_object(
      'mode',v_mode,'name',v_name,'email',v_email,
      'adminUserId',v_admin_user_id,
      'assignmentId',v_assignment_id,
      'invitationId',v_invitation_id
    ),
    'payment',jsonb_build_object(
      'platformFee',p_platform_fee,'currency',upper(trim(p_currency)),
      'paid',COALESCE(p_paid,false),'paidAt',v_paid_at
    )
  );
END $$;

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

REVOKE ALL ON FUNCTION public.asignar_o_invitar_admin(text,text,text,text,uuid,uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.asignar_o_invitar_admin(text,text,text,text,uuid,uuid)
TO authenticated;

REVOKE ALL ON FUNCTION public.aceptar_invitacion_admin(uuid,text,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.aceptar_invitacion_admin(uuid,text,text)
TO authenticated;

REVOKE ALL ON FUNCTION public.obtener_invitacion_admin_publica(uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_invitacion_admin_publica(uuid)
TO anon,authenticated;

REVOKE ALL ON FUNCTION public.aceptar_invitacion_organizador_torneo(uuid,text,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.aceptar_invitacion_organizador_torneo(uuid,text,text)
TO authenticated;

COMMIT;
