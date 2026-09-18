-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 336
-- Reparar recursión histórica del leaderboard operativo pre328
-- ============================================================
-- NO modifica datos.
-- NO elimina controles de autenticación/autorización.
-- NO modifica motores deportivos.
-- NO modifica el workflow ni el Asistente.
-- NO reconstruye torneos.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._obtener_leaderboard_operativo_ronda_pre328(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT public._obtener_leaderboard_operativo_ronda_pre211(
        p_tournament_round_id
    );
$function$;

COMMENT ON FUNCTION public._obtener_leaderboard_operativo_ronda_pre328(uuid)
IS 'Migración 336: alias histórico previo a Best Ball. Delega en pre211 y elimina la recursión accidental hacia obtener_leaderboard_operativo_ronda(). Conserva intactos los controles de autenticación/autorización de pre211.';

COMMIT;
