BEGIN;

-- ============================================================================
-- MIGRACIÓN 139
-- Visibilidad controlada de rondas inactivas para su reactivación.
--
-- CONTEXTO:
-- La Migración 138 creó la RPC crear_o_reactivar_siguiente_ronda(), pero la
-- policy SELECT histórica sólo permite ver rondas activas (salvo al
-- superadministrador). Por ello, un organizador o administrador de club no
-- puede detectar desde Lovable que la siguiente ronda ya existe inactiva.
--
-- ALCANCE:
-- - no modifica datos;
-- - no cambia la policy de escritura;
-- - no cambia las reglas de secuencia o congelamiento de la Migración 138;
-- - mantiene visibles públicamente únicamente las rondas activas;
-- - permite ver rondas inactivas sólo a administradores autorizados.
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

-- La policy pública queda deliberadamente simple: anon y authenticated pueden
-- consultar rondas activas, igual que antes.
DROP POLICY IF EXISTS tournament_rounds_select
    ON public.tournament_rounds;

CREATE POLICY tournament_rounds_select
ON public.tournament_rounds
FOR SELECT
TO PUBLIC
USING (activo = true);

-- Policy adicional sólo para sesiones autenticadas. El helper SECURITY DEFINER
-- encapsula la comprobación de superadmin, organizador del torneo o club_admin
-- del club anfitrión, sin exponer rondas inactivas a otros usuarios.
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
