-- ============================================================================
-- 171_provisionamiento_torneo_organizador_estructurado.sql
-- Tee Central / GOLF IN FULL
--
-- MIGRACIÓN 171 — PROVISIONAMIENTO CON NOMBRES/APELLIDOS ESTRUCTURADOS
--
-- OBJETIVO
-- Crear una nueva firma de provisionar_torneo(...) que reciba nombres y
-- apellidos del organizador por separado y utilice la firma canónica de
-- asignar_o_invitar_admin(...) creada en la Migración 170.
--
-- TRANSICIÓN SEGURA
-- - La firma anterior de provisionar_torneo permanece temporalmente.
-- - La nueva UI deberá usar exclusivamente esta nueva firma.
-- - No modifica datos existentes.
-- - No toca Auth, RLS ni policies.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.provisionar_torneo(
  p_nombre text,
  p_fecha_inicio date,
  p_fecha_fin date,

  p_organizer_nombres text,
  p_organizer_apellidos text,
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

  v_nombres text;
  v_apellidos text;
  v_display_name text;
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
    RAISE EXCEPTION 'No autenticado.'
      USING ERRCODE='42501';
  END IF;

  IF NOT public.is_superadmin(auth.uid()) THEN
    RAISE EXCEPTION
      'Sólo el Superadmin puede provisionar torneos.'
      USING ERRCODE='42501';
  END IF;

  SELECT public.current_admin_id()
    INTO v_admin_id;

  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION
      'No se encontró el usuario administrativo del Superadmin autenticado.'
      USING ERRCODE='42501';
  END IF;

  IF NULLIF(trim(p_nombre),'') IS NULL THEN
    RAISE EXCEPTION 'El nombre del torneo es obligatorio.'
      USING ERRCODE='22023';
  END IF;

  IF p_fecha_inicio IS NULL OR p_fecha_fin IS NULL THEN
    RAISE EXCEPTION 'Las fechas inicial y final son obligatorias.'
      USING ERRCODE='22023';
  END IF;

  IF p_fecha_fin < p_fecha_inicio THEN
    RAISE EXCEPTION
      'La fecha final no puede ser anterior a la fecha inicial.'
      USING ERRCODE='22023';
  END IF;

  v_nombres := NULLIF(trim(p_organizer_nombres),'');
  v_apellidos := NULLIF(trim(p_organizer_apellidos),'');
  v_display_name := concat_ws(' ',v_nombres,v_apellidos);
  v_email := lower(NULLIF(trim(p_organizer_email),''));
  v_phone := NULLIF(trim(p_organizer_phone),'');

  IF v_nombres IS NULL THEN
    RAISE EXCEPTION 'Los nombres del organizador son obligatorios.'
      USING ERRCODE='22023';
  END IF;

  IF v_apellidos IS NULL THEN
    RAISE EXCEPTION 'Los apellidos del organizador son obligatorios.'
      USING ERRCODE='22023';
  END IF;

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'El email del organizador es obligatorio.'
      USING ERRCODE='22023';
  END IF;

  IF p_platform_fee IS NULL OR p_platform_fee < 0 THEN
    RAISE EXCEPTION
      'El valor de alquiler de la plataforma debe ser cero o mayor.'
      USING ERRCODE='22023';
  END IF;

  IF NULLIF(trim(p_contractor_name),'') IS NULL THEN
    RAISE EXCEPTION
      'El nombre o razón social del contratante es obligatorio.'
      USING ERRCODE='22023';
  END IF;

  IF NULLIF(trim(p_currency),'') IS NULL THEN
    RAISE EXCEPTION 'La moneda es obligatoria.'
      USING ERRCODE='22023';
  END IF;

  v_paid_at := CASE
    WHEN COALESCE(p_paid,false) THEN COALESCE(p_paid_at,now())
    ELSE NULL
  END;

  INSERT INTO public.tournaments(
    nombre,
    fecha_inicio,
    fecha_fin,
    estatus,
    estado_servicio,
    activo,
    created_by
  )
  VALUES(
    trim(p_nombre),
    p_fecha_inicio,
    p_fecha_fin,
    'planificado'::public.estatus_torneo,
    'provisionado'::public.estado_servicio_torneo,
    false,
    v_admin_id
  )
  RETURNING id INTO v_tournament_id;

  INSERT INTO public.tournament_commercial_profiles(
    tournament_id,
    contractor_name,
    contractor_rfc,
    contractor_address,
    contractor_phone_1,
    contractor_phone_2,
    contractor_email,
    platform_fee,
    currency,
    paid,
    paid_at,
    payment_reference,
    payment_notes,
    fiscal_document_path,
    created_by
  )
  VALUES(
    v_tournament_id,
    trim(p_contractor_name),
    NULLIF(trim(p_contractor_rfc),''),
    NULLIF(trim(p_contractor_address),''),
    NULLIF(trim(p_contractor_phone_1),''),
    NULLIF(trim(p_contractor_phone_2),''),
    lower(NULLIF(trim(p_contractor_email),'')),
    p_platform_fee,
    upper(trim(p_currency)),
    COALESCE(p_paid,false),
    v_paid_at,
    NULLIF(trim(p_payment_reference),''),
    NULLIF(trim(p_payment_notes),''),
    NULLIF(trim(p_fiscal_document_path),''),
    v_admin_id
  )
  RETURNING id INTO v_profile_id;

  v_result := public.asignar_o_invitar_admin(
    'tournament_organizer',
    v_nombres,
    v_apellidos,
    v_email,
    v_phone,
    NULL,
    v_tournament_id
  );

  v_resultado := v_result->>'resultado';
  v_admin_user_id := NULLIF(v_result->>'adminUserId','')::uuid;
  v_assignment_id := NULLIF(v_result->>'assignmentId','')::uuid;
  v_invitation_id := NULLIF(v_result->>'invitationId','')::uuid;

  v_mode := CASE
    WHEN v_resultado='INVITED' THEN 'INVITATION'
    ELSE 'EXISTING'
  END;

  RETURN jsonb_build_object(
    'ok',true,
    'tournamentId',v_tournament_id,
    'commercialProfileId',v_profile_id,
    'estadoServicio','provisionado',
    'activo',false,
    'organizer',jsonb_build_object(
      'mode',v_mode,
      'name',v_display_name,
      'nombres',v_nombres,
      'apellidos',v_apellidos,
      'email',v_email,
      'adminUserId',v_admin_user_id,
      'assignmentId',v_assignment_id,
      'invitationId',v_invitation_id
    ),
    'payment',jsonb_build_object(
      'platformFee',p_platform_fee,
      'currency',upper(trim(p_currency)),
      'paid',COALESCE(p_paid,false),
      'paidAt',v_paid_at
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.provisionar_torneo(
  text,date,date,text,text,text,numeric,text,text,text,text,text,text,text,text,
  boolean,timestamptz,text,text,text
)
FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.provisionar_torneo(
  text,date,date,text,text,text,numeric,text,text,text,text,text,text,text,text,
  boolean,timestamptz,text,text,text
)
TO authenticated;

COMMIT;
