-- ============================================================================
-- 167_aceptacion_invitacion_organizador.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 167 — ACEPTACIÓN SEGURA DE INVITACIÓN DE ORGANIZADOR
--
-- OBJETIVO
-- Cuando un organizador invitado ya creó/verificó su identidad en Supabase Auth,
-- permitirle aceptar una invitación PENDING y materializar su acceso:
--
--   auth.users (ya existe)
--      -> public.admin_users
--      -> public.admin_role_assignments (tournament_organizer)
--      -> invitation: pending -> accepted
--
-- PRINCIPIOS
-- - La contraseña permanece exclusivamente en Supabase Auth.
-- - La RPC NO crea auth.users ni passwords.
-- - El email autenticado debe coincidir con el email invitado.
-- - El email debe estar confirmado en Supabase Auth.
-- - La operación es transaccional.
-- - No altera torneos ni configuración deportiva.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. RPC DE ACEPTACIÓN
-- ============================================================================

CREATE OR REPLACE FUNCTION public.aceptar_invitacion_organizador_torneo(
    p_invitation_id uuid,
    p_nombres text,
    p_apellidos text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
    v_auth_uid uuid;
    v_auth_email text;
    v_email_confirmed_at timestamptz;

    v_invitation public.tournament_organizer_invitations%ROWTYPE;

    v_admin_user_id uuid;
    v_existing_admin_auth_uid uuid;
    v_existing_admin_active boolean;

    v_role_id uuid;
    v_assignment_id uuid;
BEGIN
    -- ------------------------------------------------------------------------
    -- 1. IDENTIDAD AUTENTICADA
    -- ------------------------------------------------------------------------
    v_auth_uid := auth.uid();

    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        lower(trim(u.email)),
        u.email_confirmed_at
    INTO
        v_auth_email,
        v_email_confirmed_at
    FROM auth.users u
    WHERE u.id = v_auth_uid;

    IF v_auth_email IS NULL THEN
        RAISE EXCEPTION
            'No se pudo determinar el correo del usuario autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF v_email_confirmed_at IS NULL THEN
        RAISE EXCEPTION
            'Debes verificar tu correo electrónico antes de aceptar la invitación.'
            USING ERRCODE = '42501';
    END IF;

    -- ------------------------------------------------------------------------
    -- 2. DATOS PERSONALES
    -- ------------------------------------------------------------------------
    IF p_nombres IS NULL OR trim(p_nombres) = '' THEN
        RAISE EXCEPTION 'El nombre es obligatorio.'
            USING ERRCODE = '22023';
    END IF;

    IF p_apellidos IS NULL OR trim(p_apellidos) = '' THEN
        RAISE EXCEPTION 'Los apellidos son obligatorios.'
            USING ERRCODE = '22023';
    END IF;

    -- ------------------------------------------------------------------------
    -- 3. BLOQUEAR Y VALIDAR INVITACIÓN
    -- ------------------------------------------------------------------------
    SELECT *
      INTO v_invitation
      FROM public.tournament_organizer_invitations i
     WHERE i.id = p_invitation_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La invitación no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF v_invitation.status <> 'pending'::public.estado_invitacion_organizador_torneo THEN
        RAISE EXCEPTION
            'La invitación ya no está disponible.'
            USING ERRCODE = '55000';
    END IF;

    IF v_invitation.expires_at IS NOT NULL
       AND v_invitation.expires_at <= now()
    THEN
        UPDATE public.tournament_organizer_invitations
           SET status = 'expired'::public.estado_invitacion_organizador_torneo,
               expired_at = COALESCE(expired_at, now())
         WHERE id = v_invitation.id;

        RAISE EXCEPTION
            'La invitación ha expirado.'
            USING ERRCODE = '55000';
    END IF;

    IF lower(trim(v_invitation.organizer_email)) IS DISTINCT FROM v_auth_email THEN
        RAISE EXCEPTION
            'El correo autenticado no corresponde a esta invitación.'
            USING ERRCODE = '42501';
    END IF;

    -- ------------------------------------------------------------------------
    -- 4. ADMIN_USER
    --
    -- Caso normal: no existe aún y se crea.
    -- Caso robusto: si ya existe con el mismo email, sólo se reutiliza si está
    -- vinculado exactamente al auth.uid() autenticado y sigue activo.
    -- ------------------------------------------------------------------------
    SELECT
        au.id,
        au.auth_user_id,
        au.activo
    INTO
        v_admin_user_id,
        v_existing_admin_auth_uid,
        v_existing_admin_active
    FROM public.admin_users au
    WHERE lower(trim(au.email)) = v_auth_email
    LIMIT 1;

    IF v_admin_user_id IS NULL THEN
        INSERT INTO public.admin_users (
            auth_user_id,
            email,
            nombres,
            apellidos,
            activo
        )
        VALUES (
            v_auth_uid,
            v_auth_email,
            trim(p_nombres),
            trim(p_apellidos),
            true
        )
        RETURNING id
        INTO v_admin_user_id;
    ELSE
        IF v_existing_admin_auth_uid IS DISTINCT FROM v_auth_uid THEN
            RAISE EXCEPTION
                'Ya existe un usuario administrativo con este correo y está vinculado a otra identidad.'
                USING ERRCODE = '23505';
        END IF;

        IF COALESCE(v_existing_admin_active, false) = false THEN
            RAISE EXCEPTION
                'La cuenta administrativa asociada a este correo está inactiva.'
                USING ERRCODE = '55000';
        END IF;

        -- Conservamos la identidad existente, pero permitimos completar/corregir
        -- nombres al aceptar la invitación.
        UPDATE public.admin_users
           SET nombres = trim(p_nombres),
               apellidos = trim(p_apellidos)
         WHERE id = v_admin_user_id;
    END IF;

    -- ------------------------------------------------------------------------
    -- 5. ROL DE ORGANIZADOR
    -- ------------------------------------------------------------------------
    SELECT r.id
      INTO v_role_id
      FROM public.roles r
     WHERE r.codigo = 'tournament_organizer'
     LIMIT 1;

    IF v_role_id IS NULL THEN
        RAISE EXCEPTION
            'No existe el rol tournament_organizer.'
            USING ERRCODE = '55000';
    END IF;

    -- Evita duplicar una asignación activa para el mismo usuario/torneo/rol.
    SELECT ara.id
      INTO v_assignment_id
      FROM public.admin_role_assignments ara
     WHERE ara.admin_user_id = v_admin_user_id
       AND ara.role_id = v_role_id
       AND ara.tournament_id = v_invitation.tournament_id
       AND ara.activo = true
     LIMIT 1;

    IF v_assignment_id IS NULL THEN
        INSERT INTO public.admin_role_assignments (
            admin_user_id,
            role_id,
            tournament_id,
            club_id,
            created_by,
            activo
        )
        VALUES (
            v_admin_user_id,
            v_role_id,
            v_invitation.tournament_id,
            NULL,
            v_invitation.invited_by,
            true
        )
        RETURNING id
        INTO v_assignment_id;
    END IF;

    -- ------------------------------------------------------------------------
    -- 6. CERRAR INVITACIÓN
    -- ------------------------------------------------------------------------
    UPDATE public.tournament_organizer_invitations
       SET status = 'accepted'::public.estado_invitacion_organizador_torneo,
           accepted_admin_user_id = v_admin_user_id,
           accepted_at = now()
     WHERE id = v_invitation.id;

    -- ------------------------------------------------------------------------
    -- 7. RESPUESTA
    -- ------------------------------------------------------------------------
    RETURN jsonb_build_object(
        'ok', true,
        'invitationId', v_invitation.id,
        'tournamentId', v_invitation.tournament_id,
        'adminUserId', v_admin_user_id,
        'assignmentId', v_assignment_id,
        'email', v_auth_email,
        'status', 'accepted'
    );
END;
$$;

-- ============================================================================
-- 2. PRIVILEGIOS
--
-- La función debe poder ejecutarse por un usuario ya autenticado.
-- La autorización interna exige:
--   - auth.uid()
--   - email confirmado
--   - email = invitación pending
-- ============================================================================

REVOKE ALL ON FUNCTION public.aceptar_invitacion_organizador_torneo(
    uuid, text, text
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.aceptar_invitacion_organizador_torneo(
    uuid, text, text
)
TO authenticated;

COMMIT;
