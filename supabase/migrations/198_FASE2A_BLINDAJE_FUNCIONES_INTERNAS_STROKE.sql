-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 198 FASE 2A
-- Blindaje de funciones internas base Stroke
-- ============================================================
-- Objetivo:
--   Evitar que usuarios autenticados invoquen directamente las
--   funciones internas base creadas/renombradas en 198 Fase 2,
--   saltándose los wrappers públicos que aplican la clasificación
--   competitiva GROSS / NETO / BOTH.
--
-- Alcance:
--   - Solo permisos EXECUTE.
--   - No modifica datos.
--   - No modifica resultados.
--   - No modifica lógica competitiva.
-- ============================================================

BEGIN;

REVOKE ALL PRIVILEGES
ON FUNCTION public._obtener_leaderboard_ronda_base_198_f2(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._obtener_leaderboard_ronda_base_198_f2(uuid)
TO service_role;

REVOKE ALL PRIVILEGES
ON FUNCTION public._obtener_desempates_ronda_base_198_f2(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._obtener_desempates_ronda_base_198_f2(uuid)
TO service_role;

REVOKE ALL PRIVILEGES
ON FUNCTION public._resolver_desempate_manual_ronda_base_198_f2(
    uuid,
    uuid,
    public.tipo_resultado_desempate,
    integer,
    integer,
    uuid[],
    text
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._resolver_desempate_manual_ronda_base_198_f2(
    uuid,
    uuid,
    public.tipo_resultado_desempate,
    integer,
    integer,
    uuid[],
    text
)
TO service_role;

COMMIT;
