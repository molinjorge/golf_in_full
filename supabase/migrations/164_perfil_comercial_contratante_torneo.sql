-- ============================================================================
-- 164_perfil_comercial_contratante_torneo.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 164 — PERFIL COMERCIAL / CONTRATANTE DEL TORNEO
--
-- OBJETIVO
-- Separar de public.tournaments la información comercial y fiscal asociada
-- a la contratación de la plataforma.
--
-- ALCANCE DE ESTA FASE
-- - Crea perfil comercial 1:1 por torneo.
-- - Registra contratante independiente del organizador.
-- - Registra monto de plataforma y pagado/no pagado.
-- - Registra referencia/fecha/notas de pago.
-- - Registra ruta de Constancia de Situación Fiscal.
-- - Crea bucket privado exclusivo para documentos fiscales del contrato.
-- - Acceso comercial/fiscal: Superadmin.
--
-- NO IMPLEMENTA TODAVÍA
-- - invitación de organizador;
-- - RPC transaccional de provisionamiento;
-- - UI;
-- - automatización de pausa/archivo.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. TABLA 1:1 COMERCIAL
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tournament_commercial_profiles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_id uuid NOT NULL UNIQUE
        REFERENCES public.tournaments(id)
        ON DELETE RESTRICT,

    -- Contratante: puede ser distinto del organizador.
    contractor_name text NOT NULL,
    contractor_rfc text,
    contractor_address text,
    contractor_phone_1 text,
    contractor_phone_2 text,
    contractor_email text,

    -- Contratación de la plataforma.
    platform_fee numeric NOT NULL DEFAULT 0,
    currency text NOT NULL DEFAULT 'MXN',

    -- Control simple solicitado: pagó / no pagó.
    paid boolean NOT NULL DEFAULT false,
    paid_at timestamptz,
    payment_reference text,
    payment_notes text,

    -- Ruta dentro del bucket privado.
    fiscal_document_path text,

    created_by uuid
        REFERENCES public.admin_users(id)
        ON DELETE RESTRICT,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_commercial_profiles_platform_fee_valid
        CHECK (platform_fee >= 0),

    CONSTRAINT tournament_commercial_profiles_currency_not_blank
        CHECK (length(trim(currency)) > 0),

    CONSTRAINT tournament_commercial_profiles_contractor_not_blank
        CHECK (length(trim(contractor_name)) > 0)
);

COMMENT ON TABLE public.tournament_commercial_profiles IS
'Perfil comercial/fiscal 1:1 del torneo. Separa contratante, renta de plataforma, pago y documento fiscal de la configuración deportiva.';

COMMENT ON COLUMN public.tournament_commercial_profiles.contractor_name IS
'Nombre o razón social del contratante; puede ser distinto del organizador del torneo.';

COMMENT ON COLUMN public.tournament_commercial_profiles.fiscal_document_path IS
'Ruta del archivo dentro del bucket privado tournament-contract-fiscal-documents.';

-- ============================================================================
-- 2. ÍNDICES
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_tournament_commercial_profiles_paid
    ON public.tournament_commercial_profiles (paid);

CREATE INDEX IF NOT EXISTS idx_tournament_commercial_profiles_created_at
    ON public.tournament_commercial_profiles (created_at DESC);

-- ============================================================================
-- 3. UPDATED_AT
-- ============================================================================

DROP TRIGGER IF EXISTS trg_tournament_commercial_profiles_updated_at
ON public.tournament_commercial_profiles;

CREATE TRIGGER trg_tournament_commercial_profiles_updated_at
BEFORE UPDATE ON public.tournament_commercial_profiles
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

-- ============================================================================
-- 4. RLS
-- ============================================================================

ALTER TABLE public.tournament_commercial_profiles
ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tournament_commercial_profiles_select
ON public.tournament_commercial_profiles;

CREATE POLICY tournament_commercial_profiles_select
ON public.tournament_commercial_profiles
FOR SELECT
TO authenticated
USING (
    public.is_superadmin(auth.uid())
);

DROP POLICY IF EXISTS tournament_commercial_profiles_write
ON public.tournament_commercial_profiles;

CREATE POLICY tournament_commercial_profiles_write
ON public.tournament_commercial_profiles
FOR ALL
TO authenticated
USING (
    public.is_superadmin(auth.uid())
)
WITH CHECK (
    public.is_superadmin(auth.uid())
);

-- ============================================================================
-- 5. GRANTS
-- ============================================================================

REVOKE ALL ON TABLE public.tournament_commercial_profiles
FROM anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLE public.tournament_commercial_profiles
TO authenticated;

GRANT ALL
ON TABLE public.tournament_commercial_profiles
TO service_role;

-- ============================================================================
-- 6. BUCKET PRIVADO PARA DOCUMENTOS FISCALES DEL CONTRATO
-- ============================================================================

INSERT INTO storage.buckets (
    id,
    name,
    public
)
VALUES (
    'tournament-contract-fiscal-documents',
    'tournament-contract-fiscal-documents',
    false
)
ON CONFLICT (id)
DO UPDATE SET
    public = false;

-- ============================================================================
-- 7. POLICIES DEL BUCKET
--
-- Regla:
-- - sólo Superadmin;
-- - ruta esperada: <tournament_id>/<archivo>
-- - el torneo indicado por la carpeta debe existir.
-- ============================================================================

DROP POLICY IF EXISTS tournament_contract_fiscal_documents_select
ON storage.objects;

CREATE POLICY tournament_contract_fiscal_documents_select
ON storage.objects
FOR SELECT
TO authenticated
USING (
    bucket_id = 'tournament-contract-fiscal-documents'
    AND public.is_superadmin(auth.uid())
    AND EXISTS (
        SELECT 1
        FROM public.tournaments t
        WHERE t.id = (storage.foldername(name))[1]::uuid
    )
);

DROP POLICY IF EXISTS tournament_contract_fiscal_documents_insert
ON storage.objects;

CREATE POLICY tournament_contract_fiscal_documents_insert
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
    bucket_id = 'tournament-contract-fiscal-documents'
    AND public.is_superadmin(auth.uid())
    AND EXISTS (
        SELECT 1
        FROM public.tournaments t
        WHERE t.id = (storage.foldername(name))[1]::uuid
    )
);

DROP POLICY IF EXISTS tournament_contract_fiscal_documents_update
ON storage.objects;

CREATE POLICY tournament_contract_fiscal_documents_update
ON storage.objects
FOR UPDATE
TO authenticated
USING (
    bucket_id = 'tournament-contract-fiscal-documents'
    AND public.is_superadmin(auth.uid())
    AND EXISTS (
        SELECT 1
        FROM public.tournaments t
        WHERE t.id = (storage.foldername(name))[1]::uuid
    )
)
WITH CHECK (
    bucket_id = 'tournament-contract-fiscal-documents'
    AND public.is_superadmin(auth.uid())
    AND EXISTS (
        SELECT 1
        FROM public.tournaments t
        WHERE t.id = (storage.foldername(name))[1]::uuid
    )
);

DROP POLICY IF EXISTS tournament_contract_fiscal_documents_delete
ON storage.objects;

CREATE POLICY tournament_contract_fiscal_documents_delete
ON storage.objects
FOR DELETE
TO authenticated
USING (
    bucket_id = 'tournament-contract-fiscal-documents'
    AND public.is_superadmin(auth.uid())
    AND EXISTS (
        SELECT 1
        FROM public.tournaments t
        WHERE t.id = (storage.foldername(name))[1]::uuid
    )
);

COMMIT;
