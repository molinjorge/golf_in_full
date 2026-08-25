-- ============================================================================
-- MIGRACION 185 FASE 1B
-- TEE TIMES: SEQUENCE_ORDER SOLO ORDENA LA PROPUESTA, NO RESTRINGE EL ORDEN REAL
-- TEE CENTRAL
-- ============================================================================

BEGIN;

DO $do$
BEGIN
    IF to_regprocedure(
        'public._previsualizar_validacion_salidas_tee_times_v1_core_1851b(uuid)'
    ) IS NULL THEN
        ALTER FUNCTION public._previsualizar_validacion_salidas_tee_times_v1(uuid)
        RENAME TO _previsualizar_validacion_salidas_tee_times_v1_core_1851b;
    END IF;
END
$do$;

CREATE OR REPLACE FUNCTION public._previsualizar_validacion_salidas_tee_times_v1(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_result jsonb;
    v_filtered_errors jsonb;
    v_error_count integer;
BEGIN
    v_result := public._previsualizar_validacion_salidas_tee_times_v1_core_1851b(
        p_tournament_round_id
    );

    SELECT COALESCE(jsonb_agg(e.value), '[]'::jsonb)
      INTO v_filtered_errors
      FROM jsonb_array_elements(
          COALESCE(v_result->'errors', '[]'::jsonb)
      ) e(value)
     WHERE e.value->>'code' IS DISTINCT FROM 'orden_categorias_inconsistente';

    v_error_count := jsonb_array_length(v_filtered_errors);

    v_result := jsonb_set(
        v_result,
        '{errors}',
        v_filtered_errors,
        true
    );

    v_result := jsonb_set(
        v_result,
        '{counts,errors}',
        to_jsonb(v_error_count),
        true
    );

    v_result := jsonb_set(
        v_result,
        '{ready}',
        to_jsonb(v_error_count = 0),
        true
    );

    RETURN v_result;
END;
$function$;

REVOKE ALL
ON FUNCTION public._previsualizar_validacion_salidas_tee_times_v1_core_1851b(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._previsualizar_validacion_salidas_tee_times_v1_core_1851b(uuid)
TO service_role;

REVOKE ALL
ON FUNCTION public._previsualizar_validacion_salidas_tee_times_v1(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._previsualizar_validacion_salidas_tee_times_v1(uuid)
TO service_role;

COMMIT;
