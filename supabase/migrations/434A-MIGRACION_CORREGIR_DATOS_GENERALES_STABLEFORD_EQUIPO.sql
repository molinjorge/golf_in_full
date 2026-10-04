-- 434A-MIGRACION_CORREGIR_DATOS_GENERALES_STABLEFORD_EQUIPO.sql
-- TEE CENTRAL / GOLF IN FULL
-- Objetivo:
-- Corregir exclusivamente el diagnóstico de datos generales del Asistente para que
-- STABLEFORD_EQUIPO no exija handicap_allowance_pct general.
-- Stableford por equipos conserva HCP/Playing HCP individual por jugador; no existe HCP TEAM.
-- No modifica motores deportivos, scores, resultados, congelamiento ni reglas de otras modalidades.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_estado_datos_generales_torneo_405(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
    v_scoring_engine text;
    v_format_code text;
    v_participation_type text;
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
        SELECT tf.scoring_engine::text,
               tf.code,
               tf.tipo_participacion::text
          INTO v_scoring_engine,
               v_format_code,
               v_participation_type
          FROM public.tournament_formats tf
         WHERE tf.id = v_t.tournament_format_id;
    END IF;

    -- A-Go-Go / team_stroke usa configuración específica de HCP TEAM.
    -- Stableford por equipos usa Playing HCP individual por integrante y NO HCP TEAM.
    -- Ninguno de los dos depende de handicap_allowance_pct general del torneo.
    v_requires_general_allowance :=
        NOT (
            COALESCE(v_scoring_engine,'') = 'team_stroke'
            OR (
                COALESCE(v_format_code,'') = 'STABLEFORD_EQUIPO'
                AND COALESCE(v_participation_type,'') = 'equipo'
                AND COALESCE(v_scoring_engine,'') = 'stableford'
            )
        );

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
        'formatCode', v_format_code,
        'participationType', v_participation_type,
        'tarifaCeroValida', true,
        'descriptiveOnly', true
    );
END;
$function$;

COMMIT;
