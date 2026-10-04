-- 430-MIGRACION_CORREGIR_DATOS_GENERALES_A_GOGO_ASISTENTE.sql
-- TEE CENTRAL / GOLF IN FULL
--
-- OBJETIVO
-- Corregir la evidencia descriptiva de Datos generales usada por el
-- Asistente Operativo para que A-Go-Go (scoring_engine = team_stroke)
-- no exija tournaments.handicap_allowance_pct.
--
-- DIAGNOSTICO
-- PRUEBA A-GO-GO CON QR:
--   - modalidad A_GOGO
--   - scoring_engine = team_stroke
--   - handicap_allowance_pct = NULL
--   - handicap_allowance_default de la modalidad = NULL
-- La función 405 exigía PORCENTAJE_HANDICAP para todas las modalidades,
-- por lo que el evaluador 395 mantenía pendiente CONFIGURAR DATOS GENERALES.
--
-- ALCANCE
-- Solo reemplaza public.obtener_estado_datos_generales_torneo_405(uuid).
-- No modifica motores deportivos, HCP TEAM, workflow 395/396,
-- apertura/cierre de inscripciones ni datos de torneos.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_estado_datos_generales_torneo_405(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
    v_scoring_engine text;
    v_requires_general_allowance boolean := true;
    v_missing jsonb := '[]'::jsonb;
    v_required_fields jsonb;
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

    IF v_t.tournament_format_id IS NOT NULL THEN
        SELECT tf.scoring_engine::text
          INTO v_scoring_engine
          FROM public.tournament_formats tf
         WHERE tf.id = v_t.tournament_format_id;
    END IF;

    -- A-Go-Go / team_stroke usa su configuración específica de HCP TEAM.
    -- No depende del handicap_allowance_pct general del torneo.
    v_requires_general_allowance :=
        COALESCE(v_scoring_engine, '') <> 'team_stroke';

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

    IF v_requires_general_allowance
       AND (
           v_t.handicap_allowance_pct IS NULL
           OR v_t.handicap_allowance_pct < 0
           OR v_t.handicap_allowance_pct > 100
       )
    THEN
        v_missing := v_missing || jsonb_build_array('PORCENTAJE_HANDICAP');
    END IF;

    -- Cero es válido para torneos gratuitos.
    IF v_t.tarifa_individual IS NULL OR v_t.tarifa_individual < 0 THEN
        v_missing := v_missing || jsonb_build_array('TARIFA_INDIVIDUAL');
    END IF;

    v_valid := jsonb_array_length(v_missing)=0;

    v_required_fields := jsonb_build_array(
        'NOMBRE','CAMPO_GOLF','FECHA_INICIO','FECHA_FIN',
        'CUPO_MAXIMO','NUMERO_RONDAS','MODALIDAD'
    );

    IF v_requires_general_allowance THEN
        v_required_fields :=
            v_required_fields || jsonb_build_array('PORCENTAJE_HANDICAP');
    END IF;

    v_required_fields :=
        v_required_fields || jsonb_build_array('TARIFA_INDIVIDUAL');

    RETURN jsonb_build_object(
        'complete', v_valid,
        'missingOrInvalid', v_missing,
        'requiredFields', v_required_fields,
        'requiresGeneralHandicapAllowance', v_requires_general_allowance,
        'scoringEngine', v_scoring_engine,
        'tarifaCeroValida', true,
        'descriptiveOnly', true
    );
END;
$function$;

COMMIT;
