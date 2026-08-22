-- ============================================================================
-- 166_rpc_provisionar_torneo.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 166 — RPC TRANSACCIONAL DE PROVISIONAMIENTO
--
-- Crea en UNA sola transacción:
--   1) torneo provisionado e inactivo públicamente;
--   2) perfil comercial;
--   3) asignación directa si el organizador ya existe;
--      o invitación pending si todavía no existe.
--
-- Sólo SUPERADMIN puede ejecutarla.
-- No crea usuarios ni contraseñas.
-- ============================================================================

BEGIN;

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
SET search_path = public, pg_temp
AS $$
DECLARE
    v_admin_id uuid;
    v_tournament_id uuid;
    v_profile_id uuid;

    v_organizer_email text;
    v_organizer_name text;
    v_organizer_phone text;

    v_existing_count integer;
    v_existing_active_count integer;
    v_organizer_admin_user_id uuid;
    v_organizer_auth_user_id uuid;

    v_organizer_role_id uuid;
    v_assignment_id uuid;
    v_invitation_id uuid;
    v_organizer_mode text;

    v_paid_at timestamptz;
BEGIN
    -- ------------------------------------------------------------------------
    -- 1. AUTENTICACIÓN / AUTORIZACIÓN
    -- ------------------------------------------------------------------------
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT public.is_superadmin(auth.uid()) THEN
        RAISE EXCEPTION
            'Sólo el Superadmin puede provisionar torneos.'
            USING ERRCODE = '42501';
    END IF;

    SELECT public.current_admin_id()
      INTO v_admin_id;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No se encontró el usuario administrativo del Superadmin autenticado.'
            USING ERRCODE = '42501';
    END IF;

    -- ------------------------------------------------------------------------
    -- 2. VALIDACIONES MÍNIMAS
    -- ------------------------------------------------------------------------
    IF p_nombre IS NULL OR trim(p_nombre) = '' THEN
        RAISE EXCEPTION 'El nombre del torneo es obligatorio.'
            USING ERRCODE = '22023';
    END IF;

    IF p_fecha_inicio IS NULL OR p_fecha_fin IS NULL THEN
        RAISE EXCEPTION 'Las fechas inicial y final son obligatorias.'
            USING ERRCODE = '22023';
    END IF;

    IF p_fecha_fin < p_fecha_inicio THEN
        RAISE EXCEPTION
            'La fecha final no puede ser anterior a la fecha inicial.'
            USING ERRCODE = '22023';
    END IF;

    v_organizer_name := NULLIF(trim(p_organizer_name), '');
    v_organizer_email := lower(NULLIF(trim(p_organizer_email), ''));
    v_organizer_phone := NULLIF(trim(p_organizer_phone), '');

    IF v_organizer_name IS NULL THEN
        RAISE EXCEPTION 'El nombre del organizador es obligatorio.'
            USING ERRCODE = '22023';
    END IF;

    IF v_organizer_email IS NULL THEN
        RAISE EXCEPTION 'El email del organizador es obligatorio.'
            USING ERRCODE = '22023';
    END IF;

    IF p_platform_fee IS NULL OR p_platform_fee < 0 THEN
        RAISE EXCEPTION
            'El valor de alquiler de la plataforma debe ser cero o mayor.'
            USING ERRCODE = '22023';
    END IF;

    IF p_contractor_name IS NULL OR trim(p_contractor_name) = '' THEN
        RAISE EXCEPTION
            'El nombre o razón social del contratante es obligatorio.'
            USING ERRCODE = '22023';
    END IF;

    IF p_currency IS NULL OR trim(p_currency) = '' THEN
        RAISE EXCEPTION 'La moneda es obligatoria.'
            USING ERRCODE = '22023';
    END IF;

    -- Si se marca pagado y no se proporciona fecha, se registra ahora.
    -- Si está pendiente, paid_at debe permanecer NULL.
    IF COALESCE(p_paid, false) THEN
        v_paid_at := COALESCE(p_paid_at, now());
    ELSE
        v_paid_at := NULL;
    END IF;

    -- ------------------------------------------------------------------------
    -- 3. DETERMINAR SI EL ORGANIZADOR YA EXISTE
    -- ------------------------------------------------------------------------
    SELECT
        count(*),
        count(*) FILTER (WHERE au.activo = true)
    INTO
        v_existing_count,
        v_existing_active_count
    FROM public.admin_users au
    WHERE lower(trim(au.email)) = v_organizer_email;

    IF v_existing_active_count > 1 THEN
        RAISE EXCEPTION
            'Existen varios usuarios administrativos activos con el email del organizador.'
            USING ERRCODE = '23505';
    END IF;

    IF v_existing_count > 0 AND v_existing_active_count = 0 THEN
        RAISE EXCEPTION
            'El email del organizador corresponde a un usuario administrativo inactivo. Reactívalo antes de asignarle un torneo.'
            USING ERRCODE = '55000';
    END IF;

    IF v_existing_active_count = 1 THEN
        SELECT au.id, au.auth_user_id
          INTO v_organizer_admin_user_id, v_organizer_auth_user_id
          FROM public.admin_users au
         WHERE lower(trim(au.email)) = v_organizer_email
           AND au.activo = true
         LIMIT 1;

        IF v_organizer_auth_user_id IS NULL THEN
            RAISE EXCEPTION
                'El organizador existe en admin_users pero todavía no está vinculado a Supabase Auth.'
                USING ERRCODE = '55000';
        END IF;

        v_organizer_mode := 'EXISTING';
    ELSE
        v_organizer_mode := 'INVITATION';
    END IF;

    -- ------------------------------------------------------------------------
    -- 4. CREAR TORNEO MÍNIMO
    --
    -- activo=false evita que un torneo todavía provisionado quede visible
    -- públicamente por la policy actual de SELECT.
    -- ------------------------------------------------------------------------
    INSERT INTO public.tournaments (
        nombre,
        fecha_inicio,
        fecha_fin,
        estatus,
        estado_servicio,
        activo,
        created_by
    )
    VALUES (
        trim(p_nombre),
        p_fecha_inicio,
        p_fecha_fin,
        'planificado'::public.estatus_torneo,
        'provisionado'::public.estado_servicio_torneo,
        false,
        v_admin_id
    )
    RETURNING id
    INTO v_tournament_id;

    -- ------------------------------------------------------------------------
    -- 5. CREAR PERFIL COMERCIAL 1:1
    -- ------------------------------------------------------------------------
    INSERT INTO public.tournament_commercial_profiles (
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
    VALUES (
        v_tournament_id,
        trim(p_contractor_name),
        NULLIF(trim(p_contractor_rfc), ''),
        NULLIF(trim(p_contractor_address), ''),
        NULLIF(trim(p_contractor_phone_1), ''),
        NULLIF(trim(p_contractor_phone_2), ''),
        lower(NULLIF(trim(p_contractor_email), '')),
        p_platform_fee,
        upper(trim(p_currency)),
        COALESCE(p_paid, false),
        v_paid_at,
        NULLIF(trim(p_payment_reference), ''),
        NULLIF(trim(p_payment_notes), ''),
        NULLIF(trim(p_fiscal_document_path), ''),
        v_admin_id
    )
    RETURNING id
    INTO v_profile_id;

    -- ------------------------------------------------------------------------
    -- 6A. ORGANIZADOR EXISTENTE -> ASIGNACIÓN REAL
    -- ------------------------------------------------------------------------
    IF v_organizer_mode = 'EXISTING' THEN

        SELECT r.id
          INTO v_organizer_role_id
          FROM public.roles r
         WHERE r.codigo = 'tournament_organizer'
         LIMIT 1;

        IF v_organizer_role_id IS NULL THEN
            RAISE EXCEPTION
                'No existe el rol tournament_organizer.'
                USING ERRCODE = '55000';
        END IF;

        INSERT INTO public.admin_role_assignments (
            admin_user_id,
            role_id,
            tournament_id,
            club_id,
            created_by,
            activo
        )
        VALUES (
            v_organizer_admin_user_id,
            v_organizer_role_id,
            v_tournament_id,
            NULL,
            v_admin_id,
            true
        )
        RETURNING id
        INTO v_assignment_id;

    -- ------------------------------------------------------------------------
    -- 6B. ORGANIZADOR NO REGISTRADO -> INVITACIÓN PENDING
    -- ------------------------------------------------------------------------
    ELSE
        INSERT INTO public.tournament_organizer_invitations (
            tournament_id,
            organizer_name,
            organizer_email,
            organizer_phone,
            status,
            invited_by
        )
        VALUES (
            v_tournament_id,
            v_organizer_name,
            v_organizer_email,
            v_organizer_phone,
            'pending'::public.estado_invitacion_organizador_torneo,
            v_admin_id
        )
        RETURNING id
        INTO v_invitation_id;
    END IF;

    -- ------------------------------------------------------------------------
    -- 7. RESPUESTA
    -- ------------------------------------------------------------------------
    RETURN jsonb_build_object(
        'ok', true,
        'tournamentId', v_tournament_id,
        'commercialProfileId', v_profile_id,
        'estadoServicio', 'provisionado',
        'activo', false,

        'organizer',
        jsonb_build_object(
            'mode', v_organizer_mode,
            'name', v_organizer_name,
            'email', v_organizer_email,
            'adminUserId', v_organizer_admin_user_id,
            'assignmentId', v_assignment_id,
            'invitationId', v_invitation_id
        ),

        'payment',
        jsonb_build_object(
            'platformFee', p_platform_fee,
            'currency', upper(trim(p_currency)),
            'paid', COALESCE(p_paid, false),
            'paidAt', v_paid_at
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.provisionar_torneo(
    text,date,date,text,text,numeric,text,
    text,text,text,text,text,text,text,
    boolean,timestamptz,text,text,text
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.provisionar_torneo(
    text,date,date,text,text,numeric,text,
    text,text,text,text,text,text,text,
    boolean,timestamptz,text,text,text
)
TO authenticated;

COMMIT;
