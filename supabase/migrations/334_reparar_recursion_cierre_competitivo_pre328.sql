-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 334
-- Reparación de recursión accidental en cierre competitivo pre-Best Ball
--
-- Requisito previo: Migración 333 ya ejecutada y verificada.
--
-- DIAGNÓSTICO
-- Durante el diseño de la siguiente fase del workflow materializado se detectó
-- que:
--
--   obtener_estado_cierre_competitivo_ronda(uuid)
--       -> _obtener_estado_cierre_competitivo_ronda_pre328(uuid)
--       -> obtener_estado_cierre_competitivo_ronda(uuid)
--
-- formaba una recursión circular para rondas que NO son Best Ball, provocando:
--   ERROR 54001: stack depth limit exceeded
--
-- La cadena histórica correcta ya existe:
--   _obtener_estado_cierre_competitivo_ronda_pre249(uuid)
--       -> _obtener_estado_cierre_competitivo_ronda_pre213(uuid)
--
-- OBJETIVO
-- - Reparar únicamente el alias histórico pre328.
-- - Para modalidades no Best Ball, delegar en pre249 en vez de regresar a la
--   función pública.
-- - No cambiar motores, resultados, desempates, cierres, publicaciones,
--   lifecycle, workflow materializado ni frontend.
-- - No reconstruir torneos ni recorrer datos.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._obtener_estado_cierre_competitivo_ronda_pre328(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT public._obtener_estado_cierre_competitivo_ronda_pre249(
        p_tournament_round_id
    );
$function$;

COMMENT ON FUNCTION public._obtener_estado_cierre_competitivo_ronda_pre328(uuid)
IS 'Migración 334: alias histórico previo a Best Ball. Delega en pre249 y elimina la recursión accidental hacia obtener_estado_cierre_competitivo_ronda().';

COMMIT;
