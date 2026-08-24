-- ============================================================================
-- 182_FASE4_DISPATCH_VALIDADORES_SALIDA.sql
-- TEE CENTRAL
--
-- OBJETIVO
-- Desacoplar la RPC pública previsualizar_validacion_salidas_ronda(uuid)
-- del conocimiento directo de Shotgun / Stroke / individual.
--
-- ESTRATEGIA SEGURA
-- 1) El validador actual se conserva íntegro y se renombra como handler Shotgun.
-- 2) El registro de motores declara explícitamente si soporta validación.
-- 3) La RPC pública se convierte en dispatcher genérico.
-- 4) validar_salidas_ronda(uuid) NO se reescribe: ya consume la RPC pública,
--    por lo que automáticamente pasa por el dispatcher.
-- 5) Tee Times continúa NO habilitado.
--
-- IMPORTANTE
-- Esta fase NO reescribe las reglas internas del validador Shotgun.
-- Sólo separa ORQUESTACIÓN GENÉRICA de VALIDACIÓN ESPECÍFICA DEL MOTOR.
-- La extracción de reglas comunes a helpers reutilizables puede hacerse
-- posteriormente sin volver a cambiar la API pública.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. CAPACIDADES DE VALIDACIÓN EN EL REGISTRO DE MOTORES
-- ============================================================================
ALTER TABLE public.tournament_start_engine_registry
ADD COLUMN IF NOT EXISTS supports_start_validation boolean NOT NULL DEFAULT false;

ALTER TABLE public.tournament_start_engine_registry
ADD COLUMN IF NOT EXISTS start_validation_handler text;

COMMENT ON COLUMN public.tournament_start_engine_registry.supports_start_validation IS
'Indica si el motor tiene un handler operativo capaz de previsualizar/validar salidas.';

COMMENT ON COLUMN public.tournament_start_engine_registry.start_validation_handler IS
'Clave estable del handler específico de validación de salidas. La RPC pública despacha por esta capacidad.';


-- ============================================================================
-- 02. FAIL-CLOSED + HABILITAR SOLAMENTE EL VALIDADOR ACTUAL
-- ============================================================================
UPDATE public.tournament_start_engine_registry
SET
    supports_start_validation = false,
    start_validation_handler = NULL,
    updated_at = now();

UPDATE public.tournament_start_engine_registry
SET
    supports_start_validation = true,
    start_validation_handler = 'shotgun_v1',
    updated_at = now()
WHERE start_format = 'shotgun'::public.formato_salida_ronda
  AND participation_type = 'individual'
  AND scoring_engine = 'stroke'
  AND preparation_engine = 'shotgun_v1'
  AND validation_engine = 'stroke_individual_shotgun_v1'
  AND activo;


-- ============================================================================
-- 03. CONSERVAR ÍNTEGRO EL VALIDADOR ACTUAL COMO HANDLER SHOTGUN
--
-- No copiamos ni reescribimos las ~300 líneas de reglas actuales.
-- Renombrar preserva:
-- - cuerpo;
-- - SECURITY DEFINER;
-- - STABLE;
-- - search_path;
-- - lógica exacta;
-- - mensajes/códigos actuales.
-- ============================================================================
DO $migration$
BEGIN
    IF to_regprocedure(
        'public._previsualizar_validacion_salidas_shotgun_v1(uuid)'
    ) IS NULL THEN

        IF to_regprocedure(
            'public.previsualizar_validacion_salidas_ronda(uuid)'
        ) IS NULL THEN
            RAISE EXCEPTION
                'No existe previsualizar_validacion_salidas_ronda(uuid).';
        END IF;

        ALTER FUNCTION public.previsualizar_validacion_salidas_ronda(uuid)
        RENAME TO _previsualizar_validacion_salidas_shotgun_v1;
    END IF;
END;
$migration$;


-- ============================================================================
-- 04. RESOLVER HANDLER DE VALIDACIÓN DESDE EL MOTOR DE LA RONDA
--
-- Usa contexto VIVO para permitir revisión incluso antes del freeze.
-- El freeze sigue siendo una precondición que reporta el handler específico,
-- exactamente como hasta ahora.
-- ============================================================================
CREATE OR REPLACE FUNCTION public._resolver_validador_salida_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_engine jsonb;
    v_registry record;
BEGIN
    v_engine :=
        public.obtener_motor_salida_ronda(
            p_tournament_round_id
        );

    IF NOT COALESCE(
        (v_engine->>'supported')::boolean,
        false
    ) THEN
        RETURN jsonb_build_object(
            'supported', false,
            'code', 'motor_salida_no_registrado',
            'message',
                'No existe un motor activo registrado para el formato y modalidad efectivos de la ronda.',
            'engineContext', v_engine
        );
    END IF;

    SELECT
        r.id,
        r.start_format::text AS start_format,
        r.participation_type,
        r.scoring_engine,
        r.preparation_engine,
        r.validation_engine,
        r.supports_start_validation,
        r.start_validation_handler,
        r.contract_version,
        r.activo
      INTO v_registry
      FROM public.tournament_start_engine_registry r
     WHERE r.id =
        (v_engine #>> '{engine,registryId}')::uuid;

    IF v_registry.id IS NULL
       OR NOT COALESCE(v_registry.activo, false)
    THEN
        RETURN jsonb_build_object(
            'supported', false,
            'code', 'motor_salida_inactivo',
            'message',
                'El motor de salida de la ronda no está activo.',
            'engineContext', v_engine
        );
    END IF;

    IF NOT COALESCE(v_registry.supports_start_validation, false)
       OR NULLIF(btrim(v_registry.start_validation_handler), '') IS NULL
    THEN
        RETURN jsonb_build_object(
            'supported', false,
            'code', 'validacion_salida_no_soportada',
            'message',
                'El motor de salida existe, pero todavía no tiene habilitado un validador de salidas.',
            'registryId', v_registry.id,
            'startFormat', v_registry.start_format,
            'participationType', v_registry.participation_type,
            'scoringEngine', v_registry.scoring_engine,
            'preparationEngine', v_registry.preparation_engine,
            'validationEngine', v_registry.validation_engine
        );
    END IF;

    RETURN jsonb_build_object(
        'supported', true,
        'code', 'ok',
        'registryId', v_registry.id,
        'startFormat', v_registry.start_format,
        'participationType', v_registry.participation_type,
        'scoringEngine', v_registry.scoring_engine,
        'preparationEngine', v_registry.preparation_engine,
        'validationEngine', v_registry.validation_engine,
        'validationHandler', v_registry.start_validation_handler,
        'contractVersion', v_registry.contract_version
    );
END;
$function$;


-- ============================================================================
-- 05. RPC PÚBLICA GENÉRICA / DISPATCHER
--
-- La API pública conserva exactamente la misma firma:
--   previsualizar_validacion_salidas_ronda(uuid) -> jsonb
--
-- Ya NO contiene:
-- - joins a tablas Shotgun;
-- - reglas A/B;
-- - chequeos de modalidad Stroke individual;
-- - nombre stroke_individual_shotgun_v1 como decisión de negocio.
--
-- Esos detalles permanecen encapsulados en el handler específico.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.previsualizar_validacion_salidas_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_round record;
    v_dispatch jsonb;
    v_handler text;
    v_result jsonb;
    v_state jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        tr.tournament_id,
        tr.numero_ronda,
        tr.fecha,
        tr.formato_salida::text AS start_format,
        t.nombre AS tournament_name,
        t.estatus::text AS tournament_status,
        tf.id AS tournament_format_id,
        tf.code AS format_code,
        tf.name AS format_name,
        tf.tipo_participacion::text AS participation_type,
        tf.scoring_engine::text AS scoring_engine
      INTO v_round
      FROM public.tournament_rounds tr
      JOIN public.tournaments t
        ON t.id = tr.tournament_id
      LEFT JOIN public.tournament_formats tf
        ON tf.id = COALESCE(
            tr.tournament_format_id,
            t.tournament_format_id
        )
     WHERE tr.id = p_tournament_round_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    v_tournament_id := v_round.tournament_id;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para validar las salidas de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    v_dispatch :=
        public._resolver_validador_salida_ronda(
            p_tournament_round_id
        );

    IF NOT COALESCE(
        (v_dispatch->>'supported')::boolean,
        false
    ) THEN
        -- No lanzamos excepción de modalidad: una PREVISUALIZACIÓN debe poder
        -- explicar al operador por qué el motor aún no está soportado.
        v_state :=
            public.obtener_estado_validacion_salidas_ronda(
                p_tournament_round_id
            );

        RETURN jsonb_build_object(
            'schemaVersion', 2,
            'validatorEngine', NULL,
            'validationHandler', NULL,
            'generatedAt', now(),
            'ready', false,
            'alreadyValidated',
                COALESCE((v_state->>'validated')::boolean, false),

            'tournament', jsonb_build_object(
                'id', v_tournament_id,
                'name', v_round.tournament_name,
                'status', v_round.tournament_status
            ),

            'round', jsonb_build_object(
                'id', p_tournament_round_id,
                'number', v_round.numero_ronda,
                'date', v_round.fecha,
                'startFormat', v_round.start_format
            ),

            'format', jsonb_build_object(
                'tournamentFormatId', v_round.tournament_format_id,
                'code', v_round.format_code,
                'name', v_round.format_name,
                'participationType', v_round.participation_type,
                'scoringEngine', v_round.scoring_engine
            ),

            'counts', jsonb_build_object(
                'configs', 0,
                'groups', 0,
                'eligibleUnits', 0,
                'assignedUnits', 0,
                'errors', 1,
                'warnings', 0
            ),

            'errors', jsonb_build_array(
                jsonb_build_object(
                    'code',
                        COALESCE(
                            v_dispatch->>'code',
                            'validacion_salida_no_soportada'
                        ),
                    'message',
                        COALESCE(
                            v_dispatch->>'message',
                            'La ronda todavía no tiene un validador de salidas habilitado.'
                        ),
                    'detail', v_dispatch
                )
            ),
            'warnings', '[]'::jsonb,
            'dispatch', v_dispatch
        );
    END IF;

    v_handler := v_dispatch->>'validationHandler';

    -- ------------------------------------------------------------------------
    -- HANDLERS REGISTRADOS
    -- Agregar un formato futuro sólo requiere:
    -- 1) su handler específico;
    -- 2) registrarlo;
    -- 3) agregar su case aquí.
    -- La API pública y validar_salidas_ronda permanecen iguales.
    -- ------------------------------------------------------------------------
    CASE v_handler
        WHEN 'shotgun_v1' THEN
            v_result :=
                public._previsualizar_validacion_salidas_shotgun_v1(
                    p_tournament_round_id
                );
        ELSE
            RETURN jsonb_build_object(
                'schemaVersion', 2,
                'validatorEngine', v_dispatch->>'validationEngine',
                'validationHandler', v_handler,
                'generatedAt', now(),
                'ready', false,
                'alreadyValidated', false,
                'tournament', jsonb_build_object(
                    'id', v_tournament_id,
                    'name', v_round.tournament_name,
                    'status', v_round.tournament_status
                ),
                'round', jsonb_build_object(
                    'id', p_tournament_round_id,
                    'number', v_round.numero_ronda,
                    'date', v_round.fecha,
                    'startFormat', v_round.start_format
                ),
                'format', jsonb_build_object(
                    'code', v_round.format_code,
                    'name', v_round.format_name,
                    'participationType', v_round.participation_type,
                    'scoringEngine', v_round.scoring_engine
                ),
                'counts', jsonb_build_object(
                    'configs', 0,
                    'groups', 0,
                    'eligibleUnits', 0,
                    'assignedUnits', 0,
                    'errors', 1,
                    'warnings', 0
                ),
                'errors', jsonb_build_array(
                    jsonb_build_object(
                        'code', 'handler_validacion_no_implementado',
                        'message',
                            'El motor está registrado, pero su handler de validación aún no está implementado.',
                        'detail', v_dispatch
                    )
                ),
                'warnings', '[]'::jsonb,
                'dispatch', v_dispatch
            );
    END CASE;

    -- Enriquecemos sin alterar errors/warnings/counts del handler actual.
    RETURN v_result || jsonb_build_object(
        'schemaVersion', 2,
        'validationHandler', v_handler,
        'dispatch', v_dispatch
    );
END;
$function$;


-- ============================================================================
-- 06. PRIVILEGIOS
-- ============================================================================
REVOKE ALL
ON FUNCTION public._previsualizar_validacion_salidas_shotgun_v1(uuid)
FROM PUBLIC, anon, authenticated;

REVOKE ALL
ON FUNCTION public._resolver_validador_salida_ronda(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._previsualizar_validacion_salidas_shotgun_v1(uuid)
TO service_role;

GRANT EXECUTE
ON FUNCTION public._resolver_validador_salida_ronda(uuid)
TO service_role;

REVOKE ALL
ON FUNCTION public.previsualizar_validacion_salidas_ronda(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.previsualizar_validacion_salidas_ronda(uuid)
TO authenticated, service_role;


COMMIT;
