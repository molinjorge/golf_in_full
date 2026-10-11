-- 440-MIGRACION_FORMALIZACION_STABLEFORD_TEAM.sql
-- TEE CENTRAL / GOLF IN FULL
-- Ejecutar manualmente en Supabase. Lovable NO ejecuta migraciones.
--
-- Objetivo:
-- Evitar que la formalización común de resultados de Stableford TEAM caiga en
-- _obtener_estado_cierre_competitivo_ronda_pre249 -> pre213, cuya rama histórica
-- sólo soporta Stroke individual y Stableford individual.
--
-- Stableford TEAM reutiliza su estado competitivo 437/438.
-- Las demás modalidades conservan exactamente la ruta pre249 existente.

BEGIN;

DO $$
DECLARE
    v_def text;
    v_old text;
    v_new text;
BEGIN
    SELECT pg_get_functiondef(p.oid)
      INTO v_def
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public'
       AND p.proname='_estado_formalizacion_resultados_ronda_265'
       AND pg_get_function_identity_arguments(p.oid)='p_tournament_round_id uuid';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No se encontró _estado_formalizacion_resultados_ronda_265(uuid).';
    END IF;

    v_old :=
'    -- Estado competitivo previo a formalización.
    -- Se usa directamente el pre249 para evitar dependencia circular con
    -- obtener_estado_cierre_competitivo_ronda().
    v_base_state :=
        public._obtener_estado_cierre_competitivo_ronda_pre249(
            p_tournament_round_id
        );';

    v_new :=
'    -- 440: Stableford TEAM ya tiene estado competitivo propio (437/438).
    -- No debe caer en pre249 -> pre213, porque esa rama histórica sólo
    -- soporta Stroke individual y Stableford individual.
    -- Para el resto de modalidades se conserva exactamente la ruta pre249.
    IF v_operational#>>''{round,scoringEngine}'' = ''stableford''
       AND v_operational#>>''{round,participationType}'' = ''equipo''
    THEN
        v_base_state :=
            public.obtener_estado_cierre_stableford_team_ronda_437(
                p_tournament_round_id
            );
    ELSE
        v_base_state :=
            public._obtener_estado_cierre_competitivo_ronda_pre249(
                p_tournament_round_id
            );
    END IF;';

    IF position(v_old in v_def)=0 THEN
        RAISE EXCEPTION
          '440 abortada: el bloque esperado de _estado_formalizacion_resultados_ronda_265 cambió. No se modificó nada.';
    END IF;

    v_def := replace(v_def,v_old,v_new);

    IF position('obtener_estado_cierre_stableford_team_ronda_437' in v_def)=0 THEN
        RAISE EXCEPTION '440 abortada: no quedó insertada la rama Stableford TEAM.';
    END IF;

    EXECUTE v_def;
END $$;

COMMENT ON FUNCTION public._estado_formalizacion_resultados_ronda_265(uuid)
IS '440: formalización común; Stableford TEAM consume estado competitivo 437/438 y las demás modalidades conservan pre249.';

COMMIT;
