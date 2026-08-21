-- ============================================================================
-- 163_provisionamiento_torneos_base.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 163 — BASE DE PROVISIONAMIENTO DE TORNEOS
--
-- OBJETIVO
-- Preparar public.tournaments para separar:
--
--   A) creación/provisionamiento comercial por SUPERADMIN
--   B) configuración deportiva posterior por el ORGANIZADOR asignado
--
-- PRINCIPIOS
-- - NO crea una segunda tabla de torneos.
-- - Mantiene public.tournaments como entidad canónica.
-- - Los torneos existentes permanecen operativos.
-- - El estado deportivo public.tournaments.estatus NO se modifica.
-- - Se agrega un eje independiente: estado_servicio.
-- - Sólo SUPERADMIN podrá crear nuevos tournaments.
-- - El organizador podrá seguir actualizando torneos que tenga asignados,
--   conforme a la policy UPDATE existente.
--
-- ESTA FASE NO CREA TODAVÍA:
-- - datos comerciales / contrato
-- - contratante
-- - constancia fiscal
-- - invitaciones de organizador
-- - RPC transaccional de provisionamiento
-- - automatización de pausa/archivo
-- - UI
--
-- DIAGNÓSTICO PREVIO
-- Actualmente tournaments exige sin default:
--   club_id, nombre, fecha_inicio, fecha_fin, cupo_maximo,
--   tournament_format_id.
--
-- Para el nuevo flujo el SUPERADMIN sí conoce:
--   nombre, fecha_inicio, fecha_fin.
--
-- El ORGANIZADOR completará después:
--   club_id, cupo_maximo, tournament_format_id y demás datos deportivos.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. ENUM INDEPENDIENTE DEL ESTATUS DEPORTIVO
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public'
          AND t.typname = 'estado_servicio_torneo'
    ) THEN
        CREATE TYPE public.estado_servicio_torneo AS ENUM (
            'provisionado',
            'activo',
            'pausado',
            'archivado',
            'cancelado'
        );
    END IF;
END;
$$;

COMMENT ON TYPE public.estado_servicio_torneo IS
'Estado comercial/operativo del acceso a la plataforma, independiente del estatus deportivo del torneo.';

-- ============================================================================
-- 2. NUEVO ESTADO DE SERVICIO
--
-- DEFAULT activo preserva los torneos históricos ya existentes.
-- Los nuevos torneos del futuro flujo de provisionamiento deberán insertarse
-- explícitamente con estado_servicio = provisionado.
-- ============================================================================

ALTER TABLE public.tournaments
    ADD COLUMN IF NOT EXISTS estado_servicio public.estado_servicio_torneo;

UPDATE public.tournaments
SET estado_servicio = 'activo'::public.estado_servicio_torneo
WHERE estado_servicio IS NULL;

ALTER TABLE public.tournaments
    ALTER COLUMN estado_servicio
    SET DEFAULT 'activo'::public.estado_servicio_torneo;

ALTER TABLE public.tournaments
    ALTER COLUMN estado_servicio
    SET NOT NULL;

COMMENT ON COLUMN public.tournaments.estado_servicio IS
'Eje de servicio Tee Central: provisionado/activo/pausado/archivado/cancelado. No sustituye estatus_torneo.';

-- ============================================================================
-- 3. CAMPOS DEPORTIVOS QUE PUEDEN ESTAR PENDIENTES DURANTE PROVISIONAMIENTO
--
-- NO relajamos:
--   nombre
--   fecha_inicio
--   fecha_fin
--
-- porque el Superadmin sí los captura al provisionar.
-- ============================================================================

ALTER TABLE public.tournaments
    ALTER COLUMN club_id DROP NOT NULL;

ALTER TABLE public.tournaments
    ALTER COLUMN cupo_maximo DROP NOT NULL;

ALTER TABLE public.tournaments
    ALTER COLUMN tournament_format_id DROP NOT NULL;

COMMENT ON COLUMN public.tournaments.club_id IS
'Puede permanecer NULL mientras estado_servicio=provisionado; debe definirse durante la configuración deportiva.';

COMMENT ON COLUMN public.tournaments.cupo_maximo IS
'Puede permanecer NULL mientras el torneo está provisionado; se define durante la configuración deportiva.';

COMMENT ON COLUMN public.tournaments.tournament_format_id IS
'Puede permanecer NULL durante el provisionamiento; el organizador define posteriormente el formato deportivo.';

-- ============================================================================
-- 4. CREACIÓN DE TORNEOS: EXCLUSIVAMENTE SUPERADMIN
--
-- Antes:
--   SUPERADMIN OR CLUB_ADMIN
--
-- Después:
--   sólo SUPERADMIN
--
-- Esto formaliza la regla comercial:
-- el organizador/club no puede autogenerar torneos cobrables.
-- ============================================================================

DROP POLICY IF EXISTS tournaments_insert
ON public.tournaments;

CREATE POLICY tournaments_insert
ON public.tournaments
FOR INSERT
TO authenticated
WITH CHECK (
    public.is_superadmin(auth.uid())
);

-- ============================================================================
-- 5. PROTEGER estado_servicio CONTRA CAMBIOS DEL ORGANIZADOR
--
-- El organizador puede configurar el torneo asignado, pero no puede cambiar
-- por sí mismo el estado comercial/de servicio de Tee Central.
--
-- Se permite:
--   - SUPERADMIN
--   - service_role
--   - postgres (mantenimiento/migraciones)
--
-- La automatización futura de pausa/archivo se implementará explícitamente
-- en otra fase.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.proteger_estado_servicio_torneo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role text;
BEGIN
    IF NEW.estado_servicio IS NOT DISTINCT FROM OLD.estado_servicio THEN
        RETURN NEW;
    END IF;

    v_role := auth.role();

    IF current_user = 'postgres'
       OR v_role = 'service_role'
       OR public.is_superadmin(auth.uid())
    THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION
        'Sólo el Superadmin puede cambiar el estado de servicio del torneo.'
        USING ERRCODE = '42501';
END;
$$;

DROP TRIGGER IF EXISTS trg_proteger_estado_servicio_torneo
ON public.tournaments;

CREATE TRIGGER trg_proteger_estado_servicio_torneo
BEFORE UPDATE OF estado_servicio
ON public.tournaments
FOR EACH ROW
EXECUTE FUNCTION public.proteger_estado_servicio_torneo();

-- ============================================================================
-- 6. NO CAMBIAMOS UPDATE/SELECT
--
-- tournaments_update continúa permitiendo:
--   superadmin
--   club_admin del club
--   tournament_organizer asignado
--
-- Esto preserva el comportamiento actual mientras construimos el flujo
-- formal de provisionamiento e invitaciones.
-- ============================================================================

COMMIT;
