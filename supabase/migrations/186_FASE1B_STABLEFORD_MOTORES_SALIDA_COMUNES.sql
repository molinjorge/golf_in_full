-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 186 Fase 1B
-- Stableford Individual en motores comunes Shotgun / Tee Times
--
-- OBJETIVO
--   1) Registrar Stableford Individual para Shotgun y Tee Times.
--   2) Reutilizar los mismos motores de preparación, handlers de validación,
--      contrato común y emisión oficial por inscripción.
--   3) Generalizar exclusivamente los guards que hoy restringen esas rutas a
--      scoring_engine='stroke', admitiendo también 'stableford'.
--
-- NO HACE
--   - No calcula puntos Stableford.
--   - No agrega Pickup.
--   - No modifica tarjetas, conciliación, resultados ni leaderboard.
--   - No altera Stroke Play.
--
-- PRECONDICIÓN
--   Migración 186 Fase 1A aplicada y verificada.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Registry: dos capacidades nuevas, sin duplicar handlers.
-- ----------------------------------------------------------------------------

INSERT INTO public.tournament_start_engine_registry (
    start_format,
    participation_type,
    scoring_engine,
    preparation_engine,
    validation_engine,
    contract_version,
    activo,
    supports_scorecard_emission,
    scorecard_unit_type,
    scorecard_emission_engine,
    supports_start_validation,
    start_validation_handler
)
VALUES
(
    'shotgun'::public.formato_salida_ronda,
    'individual',
    'stableford',
    'shotgun_v1',
    'stableford_individual_shotgun_v1',
    2,
    true,
    true,
    'registration',
    'official_scorecard_registration_v1',
    true,
    'shotgun_v1'
),
(
    'tee_times'::public.formato_salida_ronda,
    'individual',
    'stableford',
    'tee_times_v1',
    'stableford_individual_tee_times_v1',
    2,
    true,
    true,
    'registration',
    'official_scorecard_registration_v1',
    true,
    'tee_times_v1'
)
ON CONFLICT (start_format, participation_type, scoring_engine)
DO UPDATE SET
    preparation_engine = EXCLUDED.preparation_engine,
    validation_engine = EXCLUDED.validation_engine,
    contract_version = EXCLUDED.contract_version,
    activo = true,
    supports_scorecard_emission = EXCLUDED.supports_scorecard_emission,
    scorecard_unit_type = EXCLUDED.scorecard_unit_type,
    scorecard_emission_engine = EXCLUDED.scorecard_emission_engine,
    supports_start_validation = EXCLUDED.supports_start_validation,
    start_validation_handler = EXCLUDED.start_validation_handler,
    updated_at = now();

-- ----------------------------------------------------------------------------
-- 2. Shotgun preview:
--    misma validación estructural para Stroke y Stableford individual.
--    El validatorEngine reportado se vuelve dinámico.
-- ----------------------------------------------------------------------------

DO $do$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(
        'public._previsualizar_validacion_salidas_shotgun_v1(uuid)'::regprocedure
    )
    INTO v_def;

    IF position(
        'COALESCE(v_ctx.scoring_engine, '''') <> ''stroke'''
        IN v_def
    ) = 0 THEN
        RAISE EXCEPTION
            'No se encontró el guard Stroke esperado en _previsualizar_validacion_salidas_shotgun_v1.'
            USING ERRCODE='55000';
    END IF;

    v_def := replace(
        v_def,
        'COALESCE(v_ctx.scoring_engine, '''') <> ''stroke''',
        'COALESCE(v_ctx.scoring_engine, '''') NOT IN (''stroke'', ''stableford'')'
    );

    v_def := replace(
        v_def,
        '''Esta versión valida únicamente Stroke Play individual con salida Shotgun.''',
        '''Esta versión valida modalidades individuales Stroke Play y Stableford con salida Shotgun.'''
    );

    IF position(
        '''validatorEngine'', ''stroke_individual_shotgun_v1'''
        IN v_def
    ) = 0 THEN
        RAISE EXCEPTION
            'No se encontró validatorEngine Shotgun esperado.'
            USING ERRCODE='55000';
    END IF;

    v_def := replace(
        v_def,
        '''validatorEngine'', ''stroke_individual_shotgun_v1''',
        '''validatorEngine'', CASE
            WHEN v_ctx.scoring_engine = ''stableford''
                THEN ''stableford_individual_shotgun_v1''
            ELSE ''stroke_individual_shotgun_v1''
        END'
    );

    EXECUTE v_def;
END;
$do$;

-- ----------------------------------------------------------------------------
-- 3. Shotgun contract:
--    mantiene el contrato V2 y sólo vuelve dinámica la identidad del validador.
-- ----------------------------------------------------------------------------

DO $do$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(
        'public._construir_contrato_salida_shotgun_v2(uuid)'::regprocedure
    )
    INTO v_def;

    IF position(
        '''validationEngine'', ''stroke_individual_shotgun_v1'''
        IN v_def
    ) = 0 THEN
        RAISE EXCEPTION
            'No se encontró validationEngine en contrato Shotgun.'
            USING ERRCODE='55000';
    END IF;

    v_def := replace(
        v_def,
        '''validationEngine'', ''stroke_individual_shotgun_v1''',
        '''validationEngine'', CASE
            WHEN ctx.scoring_engine = ''stableford''
                THEN ''stableford_individual_shotgun_v1''
            ELSE ''stroke_individual_shotgun_v1''
        END'
    );

    EXECUTE v_def;
END;
$do$;

-- ----------------------------------------------------------------------------
-- 4. Tee Times preview core:
--    mismo conjunto de validaciones para ambas modalidades individuales.
-- ----------------------------------------------------------------------------

DO $do$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(
        'public._previsualizar_validacion_salidas_tee_times_v1_core_1851b(uuid)'::regprocedure
    )
    INTO v_def;

    IF position(
        'COALESCE(v_ctx.scoring_engine, '''') <> ''stroke'''
        IN v_def
    ) = 0 THEN
        RAISE EXCEPTION
            'No se encontró el guard Stroke esperado en preview Tee Times.'
            USING ERRCODE='55000';
    END IF;

    v_def := replace(
        v_def,
        'COALESCE(v_ctx.scoring_engine, '''') <> ''stroke''',
        'COALESCE(v_ctx.scoring_engine, '''') NOT IN (''stroke'', ''stableford'')'
    );

    v_def := replace(
        v_def,
        '''Esta versión valida Tee Times únicamente para Stroke Play individual.''',
        '''Esta versión valida Tee Times para modalidades individuales Stroke Play y Stableford.'''
    );

    IF position(
        '''stroke_individual_tee_times_v1'''
        IN v_def
    ) = 0 THEN
        RAISE EXCEPTION
            'No se encontró validatorEngine Tee Times esperado.'
            USING ERRCODE='55000';
    END IF;

    v_def := replace(
        v_def,
        '''stroke_individual_tee_times_v1''',
        'CASE
            WHEN v_ctx.scoring_engine = ''stableford''
                THEN ''stableford_individual_tee_times_v1''
            ELSE ''stroke_individual_tee_times_v1''
        END'
    );

    EXECUTE v_def;
END;
$do$;

-- ----------------------------------------------------------------------------
-- 5. Tee Times contract V2: identidad dinámica del validador.
-- ----------------------------------------------------------------------------

DO $do$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(
        'public._construir_contrato_salida_tee_times_v1(uuid)'::regprocedure
    )
    INTO v_def;

    IF position(
        '''validationEngine'', ''stroke_individual_tee_times_v1'''
        IN v_def
    ) = 0 THEN
        RAISE EXCEPTION
            'No se encontró validationEngine en contrato Tee Times.'
            USING ERRCODE='55000';
    END IF;

    v_def := replace(
        v_def,
        '''validationEngine'', ''stroke_individual_tee_times_v1''',
        '''validationEngine'', CASE
            WHEN ctx.scoring_engine = ''stableford''
                THEN ''stableford_individual_tee_times_v1''
            ELSE ''stroke_individual_tee_times_v1''
        END'
    );

    EXECUTE v_def;
END;
$do$;

-- ----------------------------------------------------------------------------
-- 6. Tee Times materialización:
--    generaliza únicamente el guard de scoring_engine.
-- ----------------------------------------------------------------------------

DO $do$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(
        'public.materializar_conformacion_tee_times_core_1851e(uuid,jsonb)'::regprocedure
    )
    INTO v_def;

    IF position(
        'v_scoring_engine <> ''stroke'''
        IN v_def
    ) = 0 THEN
        RAISE EXCEPTION
            'No se encontró guard Stroke en materialización Tee Times.'
            USING ERRCODE='55000';
    END IF;

    v_def := replace(
        v_def,
        'v_scoring_engine <> ''stroke''',
        'v_scoring_engine NOT IN (''stroke'', ''stableford'')'
    );

    v_def := replace(
        v_def,
        '''Esta fase de Tee Times sólo prepara Stroke Play individual.''',
        '''Esta fase de Tee Times prepara modalidades individuales Stroke Play y Stableford.'''
    );

    EXECUTE v_def;
END;
$do$;

-- ----------------------------------------------------------------------------
-- 7. Tee Times modificación de conformación:
--    misma generalización, sin tocar ninguna otra regla.
-- ----------------------------------------------------------------------------

DO $do$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(
        'public.actualizar_conformacion_tee_times(uuid,jsonb)'::regprocedure
    )
    INTO v_def;

    IF position(
        'v_scoring_engine <> ''stroke'''
        IN v_def
    ) = 0 THEN
        RAISE EXCEPTION
            'No se encontró guard Stroke en actualización Tee Times.'
            USING ERRCODE='55000';
    END IF;

    v_def := replace(
        v_def,
        'v_scoring_engine <> ''stroke''',
        'v_scoring_engine NOT IN (''stroke'', ''stableford'')'
    );

    v_def := replace(
        v_def,
        '''Esta fase de Tee Times sólo modifica Stroke Play individual.''',
        '''Esta fase de Tee Times modifica modalidades individuales Stroke Play y Stableford.'''
    );

    EXECUTE v_def;
END;
$do$;

COMMIT;

-- ============================================================================
-- FIN MIGRACIÓN 186 FASE 1B
-- ============================================================================
