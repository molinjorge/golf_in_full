BEGIN;

-- ============================================================
-- MIGRACIÓN 360
-- ACCESO AL CAMPO
-- Credencial segura URL/QR por puerta asignada
-- ============================================================

CREATE TABLE public.tournament_access_point_credentials (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    assignment_id uuid NOT NULL UNIQUE
        REFERENCES public.tournament_access_point_assignments(id)
        ON DELETE RESTRICT,

    access_token text NOT NULL UNIQUE,

    activo boolean NOT NULL DEFAULT true,

    generado_at timestamptz NOT NULL DEFAULT now(),
    rotado_at timestamptz,
    revocado_at timestamptz,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_access_point_credentials_token_360
        CHECK (access_token ~ '^[0-9a-f]{64}$')
);

COMMENT ON TABLE public.tournament_access_point_credentials IS
'Credencial segura de la página operativa de una puerta asignada a un torneo. Un token identifica exclusivamente esa asignación.';
COMMENT ON COLUMN public.tournament_access_point_credentials.access_token IS
'Token aleatorio de 256 bits codificado como 64 caracteres hexadecimales. La URL/QR de puerta se construye en frontend con este token.';
COMMENT ON COLUMN public.tournament_access_point_credentials.activo IS
'Estado de la credencial. Es independiente de habilitado en la asignación: habilitado bloquea temporalmente la puerta; activo revoca o habilita la credencial.';

CREATE INDEX tournament_access_point_credentials_token_active_idx_360
ON public.tournament_access_point_credentials (access_token)
WHERE activo = true;

-- Sin acceso directo desde cliente: administración mediante RPC y
-- consulta pública exclusivamente mediante token.
ALTER TABLE public.tournament_access_point_credentials ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_access_point_credentials
FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Generar o rotar credencial.
-- Si ya existe, el token anterior deja de funcionar inmediatamente.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.generar_o_rotar_credencial_punto_acceso_360(
    p_assignment_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth_uid uuid;
    v_tournament_id uuid;
    v_assignment_enabled boolean;
    v_point_active boolean;
    v_uses_access boolean;
    v_status public.estatus_torneo;
    v_token text;
    v_credential_id uuid;
BEGIN
    v_auth_uid := auth.uid();

    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING errcode = '42501';
    END IF;

    SELECT a.tournament_id, a.habilitado, ap.activo,
           t.usar_control_acceso_qr, t.estatus
      INTO v_tournament_id, v_assignment_enabled, v_point_active,
           v_uses_access, v_status
      FROM public.tournament_access_point_assignments a
      JOIN public.tournament_access_points ap ON ap.id = a.access_point_id
      JOIN public.tournaments t ON t.id = a.tournament_id
     WHERE a.id = p_assignment_id
     FOR UPDATE OF a;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La asignación de punto de acceso no existe.'
            USING errcode = '23503';
    END IF;

    IF NOT (
        public.is_superadmin(v_auth_uid)
        OR public.is_tournament_organizer(v_auth_uid, v_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No tiene autorización para administrar esta credencial.'
            USING errcode = '42501';
    END IF;

    IF v_uses_access IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'El torneo no tiene habilitado el Control de Acceso QR de Tee Central.'
            USING errcode = '55000';
    END IF;

    IF v_status IN ('finalizado'::public.estatus_torneo, 'cancelado'::public.estatus_torneo) THEN
        RAISE EXCEPTION 'No se puede generar acceso para un torneo finalizado o cancelado.'
            USING errcode = '55000';
    END IF;

    IF v_point_active IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'No se puede generar acceso para un punto inactivo.'
            USING errcode = '55000';
    END IF;

    IF v_assignment_enabled IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'No se puede generar acceso para una puerta bloqueada.'
            USING errcode = '55000';
    END IF;

    v_token := encode(extensions.gen_random_bytes(32), 'hex');

    INSERT INTO public.tournament_access_point_credentials (
        assignment_id, access_token, activo, generado_at
    )
    VALUES (
        p_assignment_id, v_token, true, now()
    )
    ON CONFLICT (assignment_id)
    DO UPDATE SET
        access_token = EXCLUDED.access_token,
        activo = true,
        rotado_at = now(),
        revocado_at = NULL,
        updated_at = now()
    RETURNING id INTO v_credential_id;

    RETURN jsonb_build_object(
        'ok', true,
        'assignmentId', p_assignment_id,
        'credentialId', v_credential_id,
        'accessToken', v_token,
        'active', true
    );
END;
$$;

-- ------------------------------------------------------------
-- Revocar credencial.
-- No elimina asignación ni bloquea permanentemente la puerta.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.revocar_credencial_punto_acceso_360(
    p_assignment_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_auth_uid uuid;
    v_tournament_id uuid;
BEGIN
    v_auth_uid := auth.uid();

    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING errcode = '42501';
    END IF;

    SELECT a.tournament_id
      INTO v_tournament_id
      FROM public.tournament_access_point_assignments a
     WHERE a.id = p_assignment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La asignación de punto de acceso no existe.'
            USING errcode = '23503';
    END IF;

    IF NOT (
        public.is_superadmin(v_auth_uid)
        OR public.is_tournament_organizer(v_auth_uid, v_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No tiene autorización para administrar esta credencial.'
            USING errcode = '42501';
    END IF;

    UPDATE public.tournament_access_point_credentials
       SET activo = false,
           revocado_at = now(),
           updated_at = now()
     WHERE assignment_id = p_assignment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La puerta no tiene una credencial generada.'
            USING errcode = 'P0002';
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'assignmentId', p_assignment_id,
        'active', false
    );
END;
$$;

-- ------------------------------------------------------------
-- Resolver página de puerta por token.
-- Esta es la única RPC anónima de la fase.
-- Devuelve sólo datos operativos mínimos y nunca datos de jugadores.
--
-- La credencial puede abrirse desde el día anterior:
-- - PREPARADA: token válido, pero acceso general aún no abierto.
-- - ABIERTA: token válido y acceso general abierto.
-- - BLOQUEADA: asignación deshabilitada.
-- Torneo finalizado/cancelado, QR de torneo apagado, punto inactivo
-- o credencial revocada se consideran acceso no disponible.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_punto_acceso_por_token_360(
    p_access_token text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
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
            'name', ap.nombre,
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
$$;

REVOKE ALL ON FUNCTION public.generar_o_rotar_credencial_punto_acceso_360(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.generar_o_rotar_credencial_punto_acceso_360(uuid)
TO authenticated;

REVOKE ALL ON FUNCTION public.revocar_credencial_punto_acceso_360(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.revocar_credencial_punto_acceso_360(uuid)
TO authenticated;

REVOKE ALL ON FUNCTION public.obtener_punto_acceso_por_token_360(text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_punto_acceso_por_token_360(text)
TO anon, authenticated;

COMMIT;
