-- ============================================================================
-- 165_invitaciones_organizador_torneo.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 165 — INVITACIÓN DE ORGANIZADOR NO REGISTRADO
--
-- OBJETIVO
-- Soportar el provisionamiento de un torneo cuando el organizador:
--
--   A) ya existe en admin_users:
--      -> se seguirá usando admin_role_assignments (sin cambios).
--
--   B) todavía NO existe:
--      -> se registra una invitación pendiente asociada al torneo.
--
-- PRINCIPIOS
-- - NO crea usuarios falsos.
-- - NO almacena contraseñas.
-- - NO modifica asignaciones existentes.
-- - NO modifica torneos existentes.
-- - La aceptación/alta automática se implementará en una fase posterior.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. ENUM DE ESTADO DE INVITACIÓN
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public'
          AND t.typname = 'estado_invitacion_organizador_torneo'
    ) THEN
        CREATE TYPE public.estado_invitacion_organizador_torneo AS ENUM (
            'pending',
            'accepted',
            'cancelled',
            'expired'
        );
    END IF;
END;
$$;

-- ============================================================================
-- 2. TABLA DE INVITACIONES
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tournament_organizer_invitations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id)
        ON DELETE RESTRICT,

    organizer_name text NOT NULL,
    organizer_email text NOT NULL,
    organizer_phone text,

    status public.estado_invitacion_organizador_torneo
        NOT NULL DEFAULT 'pending',

    -- Se llena sólo cuando la invitación queda vinculada a un admin_user real.
    accepted_admin_user_id uuid
        REFERENCES public.admin_users(id)
        ON DELETE RESTRICT,

    invited_by uuid
        REFERENCES public.admin_users(id)
        ON DELETE RESTRICT,

    invited_at timestamptz NOT NULL DEFAULT now(),
    accepted_at timestamptz,
    cancelled_at timestamptz,
    expired_at timestamptz,
    expires_at timestamptz,

    cancellation_reason text,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_organizer_invitations_name_not_blank
        CHECK (length(trim(organizer_name)) > 0),

    CONSTRAINT tournament_organizer_invitations_email_not_blank
        CHECK (length(trim(organizer_email)) > 0),

    CONSTRAINT tournament_organizer_invitations_acceptance_consistent
        CHECK (
            (status = 'accepted'
             AND accepted_admin_user_id IS NOT NULL
             AND accepted_at IS NOT NULL)
            OR
            (status <> 'accepted')
        )
);

COMMENT ON TABLE public.tournament_organizer_invitations IS
'Invitación pendiente para un organizador que aún no existe en admin_users. No concede permisos hasta materializar un admin_role_assignment real.';

COMMENT ON COLUMN public.tournament_organizer_invitations.organizer_email IS
'Email esperado del futuro organizador. La aceptación deberá validar el email autenticado antes de crear la asignación real.';

-- ============================================================================
-- 3. ÍNDICES
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_tournament_organizer_invitations_tournament
    ON public.tournament_organizer_invitations (tournament_id);

CREATE INDEX IF NOT EXISTS idx_tournament_organizer_invitations_status
    ON public.tournament_organizer_invitations (status);

CREATE INDEX IF NOT EXISTS idx_tournament_organizer_invitations_email_lower
    ON public.tournament_organizer_invitations (lower(organizer_email));

-- Evita duplicar una invitación pendiente para el mismo torneo/email.
CREATE UNIQUE INDEX IF NOT EXISTS uq_tournament_organizer_invitation_pending
    ON public.tournament_organizer_invitations (
        tournament_id,
        lower(organizer_email)
    )
    WHERE status = 'pending';

-- ============================================================================
-- 4. UPDATED_AT
-- ============================================================================

DROP TRIGGER IF EXISTS trg_tournament_organizer_invitations_updated_at
ON public.tournament_organizer_invitations;

CREATE TRIGGER trg_tournament_organizer_invitations_updated_at
BEFORE UPDATE ON public.tournament_organizer_invitations
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

-- ============================================================================
-- 5. RLS
--
-- En esta fase sólo Superadmin administra invitaciones.
-- El futuro flujo de aceptación se hará mediante RPC SECURITY DEFINER
-- con validación estricta del usuario/email.
-- ============================================================================

ALTER TABLE public.tournament_organizer_invitations
ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tournament_organizer_invitations_select
ON public.tournament_organizer_invitations;

CREATE POLICY tournament_organizer_invitations_select
ON public.tournament_organizer_invitations
FOR SELECT
TO authenticated
USING (
    public.is_superadmin(auth.uid())
);

DROP POLICY IF EXISTS tournament_organizer_invitations_write
ON public.tournament_organizer_invitations;

CREATE POLICY tournament_organizer_invitations_write
ON public.tournament_organizer_invitations
FOR ALL
TO authenticated
USING (
    public.is_superadmin(auth.uid())
)
WITH CHECK (
    public.is_superadmin(auth.uid())
);

-- ============================================================================
-- 6. GRANTS
-- ============================================================================

REVOKE ALL ON TABLE public.tournament_organizer_invitations
FROM anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLE public.tournament_organizer_invitations
TO authenticated;

GRANT ALL
ON TABLE public.tournament_organizer_invitations
TO service_role;

COMMIT;
