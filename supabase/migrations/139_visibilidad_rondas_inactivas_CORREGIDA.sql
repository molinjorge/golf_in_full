BEGIN;

-- ============================================================================
-- MIGRACIÓN 139 — VERSIÓN CORREGIDA
-- Visibilidad controlada de rondas inactivas para su reactivación.
--
-- Esta versión sustituye completamente a la primera entrega de la Migración
-- 139. Revoca expresamente el permiso EXECUTE que una base histórica puede
-- conservar para el rol anon.
--
-- No modifica datos ni las reglas de secuencia/congelamiento de la 138.
-- ============================================================================

DO $$
BEGIN
    IF to_regprocedure(
        'public.puede_administrar_congelamiento_torneo(uuid)'
    ) IS NULL THEN
        RAISE EXCEPTION
            'Falta public.puede_administrar_congelamiento_torneo(uuid). Ejecute primero la Migración 136.'
            USING ERRCODE = '42883';
    END IF;

    IF to_regclass('public.tournament_rounds') IS NULL THEN
        RAISE EXCEPTION
            'Falta public.tournament_rounds.'
            USING ERRCODE = '42P01';
    END IF;
END;
$$;

-- Endurecimiento explícito de permisos del helper administrativo.
REVOKE ALL ON FUNCTION
    public.puede_administrar_congelamiento_torneo(uuid)
FROM PUBLIC;

REVOKE ALL ON FUNCTION
    public.puede_administrar_congelamiento_torneo(uuid)
FROM anon;

GRANT EXECUTE ON FUNCTION
    public.puede_administrar_congelamiento_torneo(uuid)
TO authenticated;

-- Visitantes y usuarios autenticados pueden consultar rondas activas.
DROP POLICY IF EXISTS tournament_rounds_select
    ON public.tournament_rounds;

CREATE POLICY tournament_rounds_select
ON public.tournament_rounds
FOR SELECT
TO PUBLIC
USING (activo = true);

-- Sólo administradores autenticados autorizados pueden consultar también las
-- rondas inactivas que podrían reactivarse.
DROP POLICY IF EXISTS tournament_rounds_select_inactive_admin
    ON public.tournament_rounds;

CREATE POLICY tournament_rounds_select_inactive_admin
ON public.tournament_rounds
FOR SELECT
TO authenticated
USING (
    public.puede_administrar_congelamiento_torneo(tournament_id)
);

COMMENT ON POLICY tournament_rounds_select
ON public.tournament_rounds IS
'Lectura pública únicamente de rondas activas.';

COMMENT ON POLICY tournament_rounds_select_inactive_admin
ON public.tournament_rounds IS
'Permite a superadmin, organizador del torneo y administrador del club consultar también rondas inactivas para reactivarlas.';

COMMIT;
