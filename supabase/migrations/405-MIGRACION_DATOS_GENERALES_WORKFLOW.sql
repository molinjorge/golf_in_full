-- 405-MIGRACION_DATOS_GENERALES_WORKFLOW.sql
-- TEE CENTRAL
--
-- OBJETIVO
-- Separar la evidencia descriptiva de "Configurar datos generales" de las
-- categorías, franjas de HCP, desempates y estructura de rondas.
--
-- IMPORTANTE
-- Esta migración NO modifica autorizaciones, bloqueos, motores deportivos,
-- apertura/cierre de inscripciones ni ninguna regla operativa.
-- Sólo agrega una función descriptiva y hace que el evaluador 395 la use
-- para la regla TOURNAMENT_CONFIGURATION_COMPLETE.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_estado_datos_generales_torneo_405(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
    v_missing jsonb := '[]'::jsonb;
    v_valid boolean := true;
BEGIN
    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Torneo no encontrado.'
            USING ERRCODE='P0002';
    END IF;

    -- Los campos corresponden a los marcados como obligatorios en
    -- Datos generales. Tarifa individual = 0 es válida.
    IF NULLIF(btrim(v_t.nombre),'') IS NULL THEN
        v_missing := v_missing || jsonb_build_array('NOMBRE');
    END IF;

    IF v_t.campo_golf_id IS NULL THEN
        v_missing := v_missing || jsonb_build_array('CAMPO_GOLF');
    END IF;

    IF v_t.fecha_inicio IS NULL THEN
        v_missing := v_missing || jsonb_build_array('FECHA_INICIO');
    END IF;

    IF v_t.fecha_fin IS NULL THEN
        v_missing := v_missing || jsonb_build_array('FECHA_FIN');
    ELSIF v_t.fecha_inicio IS NOT NULL AND v_t.fecha_fin < v_t.fecha_inicio THEN
        v_missing := v_missing || jsonb_build_array('FECHA_FIN_ANTERIOR_INICIO');
    END IF;

    IF v_t.cupo_maximo IS NULL OR v_t.cupo_maximo <= 0 THEN
        v_missing := v_missing || jsonb_build_array('CUPO_MAXIMO');
    END IF;

    IF v_t.numero_rondas IS NULL OR v_t.numero_rondas <= 0 THEN
        v_missing := v_missing || jsonb_build_array('NUMERO_RONDAS');
    END IF;

    IF v_t.tournament_format_id IS NULL THEN
        v_missing := v_missing || jsonb_build_array('MODALIDAD');
    END IF;

    IF v_t.handicap_allowance_pct IS NULL
       OR v_t.handicap_allowance_pct < 0
       OR v_t.handicap_allowance_pct > 100
    THEN
        v_missing := v_missing || jsonb_build_array('PORCENTAJE_HANDICAP');
    END IF;

    -- Cero es válido para torneos gratuitos.
    IF v_t.tarifa_individual IS NULL OR v_t.tarifa_individual < 0 THEN
        v_missing := v_missing || jsonb_build_array('TARIFA_INDIVIDUAL');
    END IF;

    v_valid := jsonb_array_length(v_missing)=0;

    RETURN jsonb_build_object(
        'complete', v_valid,
        'missingOrInvalid', v_missing,
        'requiredFields', jsonb_build_array(
            'NOMBRE','CAMPO_GOLF','FECHA_INICIO','FECHA_FIN',
            'CUPO_MAXIMO','NUMERO_RONDAS','MODALIDAD',
            'PORCENTAJE_HANDICAP','TARIFA_INDIVIDUAL'
        ),
        'tarifaCeroValida', true,
        'descriptiveOnly', true
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_estado_datos_generales_torneo_405(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_estado_datos_generales_torneo_405(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_estado_datos_generales_torneo_405(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_estado_datos_generales_torneo_405(uuid) TO service_role;

-- Modificación mínima y localizada del evaluador existente:
-- sustituir únicamente la evidencia de TOURNAMENT_CONFIGURATION_COMPLETE.
DO $do$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(p.oid)
      INTO v_def
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public'
       AND p.proname='obtener_workflow_evaluado_395'
       AND p.prokind='f';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No existe obtener_workflow_evaluado_395.';
    END IF;

    IF position(
        'v_complete := COALESCE((v_open->>''baseConfigurationReady'')::boolean,false);'
        in v_def
    ) = 0 THEN
        RAISE EXCEPTION
          'La definición actual de obtener_workflow_evaluado_395 no contiene el bloque esperado. No se aplicó ningún cambio.';
    END IF;

    v_def := replace(
        v_def,
        'v_complete := COALESCE((v_open->>''baseConfigurationReady'')::boolean,false);' ||
        E'\r\n        v_evidence := jsonb_build_object(''baseConfigurationReady'',v_complete,' ||
        E'\r\n          ''usarTarjetaDigital'',v_t.usar_tarjeta_digital,' ||
        E'\r\n          ''usarEstacionesDigitalesPremios'',v_t.usar_estaciones_digitales_premios);',
        'v_evidence := public.obtener_estado_datos_generales_torneo_405(p_tournament_id);' ||
        E'\r\n        v_complete := COALESCE((v_evidence->>''complete'')::boolean,false);'
    );

    IF position('obtener_estado_datos_generales_torneo_405' in v_def)=0 THEN
        RAISE EXCEPTION 'No fue posible construir la nueva definición del evaluador.';
    END IF;

    EXECUTE v_def;
END
$do$;

COMMENT ON FUNCTION public.obtener_estado_datos_generales_torneo_405(uuid)
IS '405: evidencia descriptiva del paso Configurar datos generales; independiente de categorías, franjas HCP, desempates y estructura de rondas.';

COMMIT;
