-- ============================================================================
-- 168_trazabilidad_envio_invitacion_organizador.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 168 — TRAZABILIDAD DE ENVÍO DE INVITACIÓN DE ORGANIZADOR
--
-- OBJETIVO
-- Registrar cuándo y cuántas veces el Superadmin envía/reenvía una invitación
-- de organizador.
--
-- ESTA FASE NO ENVÍA CORREOS.
-- El envío seguirá realizándose desde una server function con Resend.
-- ============================================================================

BEGIN;

ALTER TABLE public.tournament_organizer_invitations
    ADD COLUMN IF NOT EXISTS last_sent_at timestamptz,
    ADD COLUMN IF NOT EXISTS sent_count integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS last_sent_by uuid
        REFERENCES public.admin_users(id)
        ON DELETE SET NULL;

ALTER TABLE public.tournament_organizer_invitations
    DROP CONSTRAINT IF EXISTS tournament_organizer_invitations_sent_count_nonnegative;

ALTER TABLE public.tournament_organizer_invitations
    ADD CONSTRAINT tournament_organizer_invitations_sent_count_nonnegative
    CHECK (sent_count >= 0);

COMMENT ON COLUMN public.tournament_organizer_invitations.last_sent_at IS
'Fecha/hora del envío o reenvío más reciente de la invitación.';

COMMENT ON COLUMN public.tournament_organizer_invitations.sent_count IS
'Número de veces que la invitación ha sido enviada o reenviada.';

COMMENT ON COLUMN public.tournament_organizer_invitations.last_sent_by IS
'Superadmin que realizó el envío o reenvío más reciente.';

COMMIT;
