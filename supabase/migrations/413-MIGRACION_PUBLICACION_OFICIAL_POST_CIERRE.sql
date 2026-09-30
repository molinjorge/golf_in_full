-- TEE CENTRAL
-- MIGRACION 413 - PUBLICACION OFICIAL POST CIERRE
-- Corrige solo la evidencia descriptiva de formalizacion.
-- No publica resultados ni modifica datos deportivos.

BEGIN;

DO $migration$
DECLARE
    v_oid oid;
    v_def text;
    v_start_marker text := E'    -- Ronda históricamente cerrada: la etapa completa no debe reabrirse';
    v_end_marker text := E'    WITH category_base AS (';
    v_start integer;
    v_end integer;
BEGIN
    SELECT p.oid INTO v_oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND p.proname='_estado_formalizacion_resultados_ronda_265'
      AND pg_get_function_identity_arguments(p.oid)='p_tournament_round_id uuid';

    IF v_oid IS NULL THEN
        RAISE EXCEPTION 'No existe public._estado_formalizacion_resultados_ronda_265(uuid).';
    END IF;

    v_def := pg_get_functiondef(v_oid);

    IF position('grandfatheredByRoundClosure' in v_def)=0
       OR position('IF v_round_closed THEN' in v_def)=0 THEN
        RAISE EXCEPTION 'La funcion 265 ya no coincide con la version esperada; no se modifica.';
    END IF;

    v_start := position(v_start_marker in v_def);
    v_end := position(v_end_marker in v_def);

    IF v_start=0 OR v_end=0 OR v_end<=v_start THEN
        RAISE EXCEPTION 'No se localizaron de forma segura los limites del bloque heredado.';
    END IF;

    -- Elimina exclusivamente el retorno anticipado que convertia el cierre
    -- de ronda en cierre/publicacion de todas las categorias.
    v_def := substring(v_def from 1 for v_start-1)
          || E'    -- 413: una ronda cerrada sigue evaluando cierres de categoria y publicaciones reales.\n'
          || E'    -- El cierre competitivo NO equivale a publicacion oficial.\n\n'
          || substring(v_def from v_end);

    IF position('''roundClosed'',false' in v_def)=0 THEN
        RAISE EXCEPTION 'No se encontro el retorno roundClosed esperado; no se modifica.';
    END IF;

    v_def := replace(
        v_def,
        '''roundClosed'',false',
        '''roundClosed'',v_round_closed'
    );

    EXECUTE v_def;
END
$migration$;

COMMIT;
