-- Migración 347
-- Endurecimiento de permisos de la sustitución administrativa Best Ball 346.
-- No modifica lógica deportiva ni datos.

BEGIN;

REVOKE ALL ON FUNCTION public.sustituir_jugador_best_ball_346(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.sustituir_jugador_best_ball_346(uuid, uuid, text, uuid) FROM anon;

GRANT EXECUTE ON FUNCTION public.sustituir_jugador_best_ball_346(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sustituir_jugador_best_ball_346(uuid, uuid, text, uuid) TO service_role;

COMMIT;
