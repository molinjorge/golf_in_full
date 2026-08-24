-- ============================================================================
-- 182_FASE1_CONTRATO_COMUN_MOTOR_SALIDAS.sql
-- TEE CENTRAL
-- VERSION CORREGIDA
--
-- OBJETIVO
-- Crear la capa común del motor de salidas SIN cambiar todavía el
-- comportamiento operativo de Shotgun y SIN mutar validaciones históricas.
--
-- PRINCIPIOS
-- - formato_salida sigue perteneciendo a tournament_rounds.
-- - Shotgun y Tee Times serán motores de preparación distintos.
-- - Las validaciones históricas son INMUTABLES y no se actualizan.
-- - Esta fase NO modifica previsualizar_validacion_salidas_ronda(),
--   validar_salidas_ronda() ni emitir_tarjetas_score_ronda().
-- - El flujo Shotgun existente debe seguir funcionando exactamente igual.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. REGISTRO DE MOTORES DE SALIDA
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.tournament_start_engine_registry (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    start_format public.formato_salida_ronda NOT NULL,
    participation_type text NOT NULL,
    scoring_engine text NOT NULL,

    preparation_engine text NOT NULL,
    validation_engine text NOT NULL,

    contract_version integer NOT NULL DEFAULT 2
        CHECK (contract_version > 0),

    activo boolean NOT NULL DEFAULT true,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_tournament_start_engine_registry
        UNIQUE (
            start_format,
            participation_type,
            scoring_engine
        )
);

COMMENT ON TABLE public.tournament_start_engine_registry IS
'Registro central de motores de salida. Separa formato de salida, tipo de participación y motor de scoring.';

COMMENT ON COLUMN public.tournament_start_engine_registry.preparation_engine IS
'Motor que construye/prepara grupos y posiciones de salida.';

COMMENT ON COLUMN public.tournament_start_engine_registry.validation_engine IS
'Motor que valida y congela la fotografía de salidas.';

COMMENT ON COLUMN public.tournament_start_engine_registry.contract_version IS
'Versión del contrato común de salida producido por el motor.';


-- ============================================================================
-- 02. REGISTRAR EL MOTOR EXISTENTE SIN CAMBIAR SU COMPORTAMIENTO
-- ============================================================================
INSERT INTO public.tournament_start_engine_registry (
    start_format,
    participation_type,
    scoring_engine,
    preparation_engine,
    validation_engine,
    contract_version,
    activo
)
VALUES (
    'shotgun'::public.formato_salida_ronda,
    'individual',
    'stroke',
    'shotgun_v1',
    'stroke_individual_shotgun_v1',
    2,
    true
)
ON CONFLICT (
    start_format,
    participation_type,
    scoring_engine
)
DO UPDATE SET
    preparation_engine = EXCLUDED.preparation_engine,
    validation_engine = EXCLUDED.validation_engine,
    contract_version = EXCLUDED.contract_version,
    activo = EXCLUDED.activo,
    updated_at = now();


-- ============================================================================
-- 03. VERSIONAR EL CONTRATO HISTÓRICO
--
-- IMPORTANTE:
-- No se hace UPDATE sobre filas históricas. El DEFAULT 1 representa el
-- contrato legacy para registros existentes y futuros mientras el flujo
-- operativo siga usando la fotografía v1.
-- ============================================================================
ALTER TABLE public.tournament_round_start_validations
ADD COLUMN IF NOT EXISTS start_contract_version integer NOT NULL DEFAULT 1;

ALTER TABLE public.tournament_round_start_validations
DROP CONSTRAINT IF EXISTS chk_start_contract_version_positive;

ALTER TABLE public.tournament_round_start_validations
ADD CONSTRAINT chk_start_contract_version_positive
CHECK (start_contract_version > 0);

COMMENT ON COLUMN public.tournament_round_start_validations.start_contract_version IS
'Versión del contrato almacenado en validation_snapshot. Registros legacy usan 1; futuros contratos comunes usarán 2 o superior.';


-- ============================================================================
-- 04. GENERALIZAR LA ESTRUCTURA DE GRUPOS SIN MUTAR HISTÓRICOS
--
-- NO se hace backfill:
-- las validaciones históricas son inmutables por diseño.
--
-- source_shotgun_hole_id permanece como dato histórico legacy.
-- source_format_slot_id / source_format_metadata serán poblados sólo por
-- futuras validaciones que ya utilicen el contrato común.
--
-- start_position pasa a nullable:
-- - Shotgun legacy conserva A/B.
-- - Tee Times podrá no requerir A/B.
-- ============================================================================
ALTER TABLE public.tournament_round_start_validation_groups
ADD COLUMN IF NOT EXISTS source_format_slot_id uuid;

ALTER TABLE public.tournament_round_start_validation_groups
ADD COLUMN IF NOT EXISTS source_format_metadata jsonb;

ALTER TABLE public.tournament_round_start_validation_groups
ALTER COLUMN start_position DROP NOT NULL;

COMMENT ON COLUMN public.tournament_round_start_validation_groups.source_format_slot_id IS
'Identificador genérico del slot definido por el motor de salida. NULL en validaciones históricas legacy.';

COMMENT ON COLUMN public.tournament_round_start_validation_groups.source_format_metadata IS
'Metadatos específicos del motor de salida. NULL en validaciones históricas legacy.';

COMMENT ON COLUMN public.tournament_round_start_validation_groups.start_position IS
'Posición opcional dentro del punto de salida. Shotgun usa A/B; otros formatos pueden dejarla NULL.';


-- ============================================================================
-- 05. RLS DEL REGISTRO
-- ============================================================================
ALTER TABLE public.tournament_start_engine_registry
ENABLE ROW LEVEL SECURITY;

REVOKE ALL
ON TABLE public.tournament_start_engine_registry
FROM PUBLIC, anon, authenticated;

GRANT SELECT
ON TABLE public.tournament_start_engine_registry
TO authenticated;

GRANT ALL
ON TABLE public.tournament_start_engine_registry
TO service_role;

DROP POLICY IF EXISTS
"authenticated_read_start_engine_registry"
ON public.tournament_start_engine_registry;

CREATE POLICY "authenticated_read_start_engine_registry"
ON public.tournament_start_engine_registry
FOR SELECT
TO authenticated
USING (true);


-- ============================================================================
-- 06. RESOLVER EL MOTOR EFECTIVO DE UNA RONDA
-- ============================================================================
CREATE OR REPLACE FUNCTION public.obtener_motor_salida_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_round record;
    v_engine record;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        tr.id AS round_id,
        tr.tournament_id,
        tr.numero_ronda,
        tr.fecha,
        tr.formato_salida::text AS start_format,
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

    IF v_round.round_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_round.tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar el motor de salida de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        r.id,
        r.preparation_engine,
        r.validation_engine,
        r.contract_version,
        r.activo
      INTO v_engine
      FROM public.tournament_start_engine_registry r
     WHERE r.start_format::text = COALESCE(v_round.start_format, '')
       AND r.participation_type = COALESCE(v_round.participation_type, '')
       AND r.scoring_engine = COALESCE(v_round.scoring_engine, '')
     LIMIT 1;

    RETURN jsonb_build_object(
        'tournamentRoundId', v_round.round_id,
        'tournamentId', v_round.tournament_id,
        'roundNumber', v_round.numero_ronda,
        'roundDate', v_round.fecha,
        'startFormat', v_round.start_format,
        'format', jsonb_build_object(
            'tournamentFormatId', v_round.tournament_format_id,
            'code', v_round.format_code,
            'name', v_round.format_name,
            'participationType', v_round.participation_type,
            'scoringEngine', v_round.scoring_engine
        ),
        'supported',
            v_engine.id IS NOT NULL
            AND COALESCE(v_engine.activo, false),
        'engine',
            CASE
                WHEN v_engine.id IS NULL THEN NULL
                ELSE jsonb_build_object(
                    'registryId', v_engine.id,
                    'preparationEngine', v_engine.preparation_engine,
                    'validationEngine', v_engine.validation_engine,
                    'contractVersion', v_engine.contract_version,
                    'active', v_engine.activo
                )
            END
    );
END;
$function$;


-- ============================================================================
-- 07. CONTRATO COMÚN DE SALIDA V2
--
-- Esta función NO reemplaza aún a _construir_fotografia_salida_ronda().
-- Adapta en lectura la fotografía Shotgun legacy al contrato común.
--
-- Así evitamos mutar cualquier validación histórica.
-- ============================================================================
CREATE OR REPLACE FUNCTION public._construir_contrato_salida_ronda(
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
    v_legacy jsonb;
    v_groups jsonb;
    v_start_format text;
    v_preparation_engine text;
    v_validation_engine text;
    v_contract_version integer;
BEGIN
    v_engine :=
        public.obtener_motor_salida_ronda(
            p_tournament_round_id
        );

    IF NOT COALESCE(
        (v_engine->>'supported')::boolean,
        false
    ) THEN
        RAISE EXCEPTION
            'No existe un motor de salida activo para esta combinación de formato, participación y puntuación.'
            USING ERRCODE = '0A000',
                  DETAIL = v_engine::text,
                  HINT =
                      'Registra/implementa primero el motor correspondiente en tournament_start_engine_registry.';
    END IF;

    v_start_format := v_engine->>'startFormat';
    v_preparation_engine :=
        v_engine #>> '{engine,preparationEngine}';
    v_validation_engine :=
        v_engine #>> '{engine,validationEngine}';
    v_contract_version :=
        (v_engine #>> '{engine,contractVersion}')::integer;

    IF v_preparation_engine <> 'shotgun_v1'
       OR v_start_format <> 'shotgun'
    THEN
        RAISE EXCEPTION
            'El contrato común existe, pero el adaptador de preparación para este motor todavía no está implementado.'
            USING ERRCODE = '0A000',
                  DETAIL = v_engine::text;
    END IF;

    v_legacy :=
        public._construir_fotografia_salida_ronda(
            p_tournament_round_id
        );

    IF v_legacy IS NULL THEN
        RAISE EXCEPTION
            'No fue posible construir la fotografía de salidas existente.'
            USING ERRCODE = '55000';
    END IF;

    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'sourceGroupId',
                    g->>'sourceGroupId',
                'sourceConfigId',
                    g->>'sourceConfigId',
                'sourceShiftId',
                    g->>'sourceShiftId',
                'sourceShiftCategoryId',
                    g->>'sourceShiftCategoryId',
                'tournamentCategoryId',
                    g->>'tournamentCategoryId',
                'categoryName',
                    g->>'categoryName',

                -- Conversión legacy -> común EN LECTURA.
                'sourceFormatSlotId',
                    g->>'sourceShotgunHoleId',

                'sourceHoleId',
                    g->>'sourceHoleId',
                'holeNumber',
                    NULLIF(g->>'holeNumber','')::integer,

                'startAt',
                    g->>'startAt',
                'startPosition',
                    NULLIF(g->>'startPosition',''),

                'shiftNumber',
                    NULLIF(g->>'shiftNumber','')::integer,
                'shiftTime',
                    g->>'shiftTime',

                'groupLabel',
                    g->>'groupLabel',
                'normalSize',
                    NULLIF(g->>'normalSize','')::integer,
                'maximumSize',
                    NULLIF(g->>'maximumSize','')::integer,

                'units',
                    COALESCE(g->'units', '[]'::jsonb),

                'formatMetadata',
                    jsonb_build_object(
                        'startFormat', 'shotgun',
                        'sourceShotgunHoleId',
                            g->>'sourceShotgunHoleId',
                        'startPosition',
                            g->>'startPosition'
                    )
            )
            ORDER BY
                NULLIF(g->>'shiftNumber','')::integer,
                NULLIF(g->>'holeNumber','')::integer,
                g->>'startPosition',
                g->>'sourceGroupId'
        ),
        '[]'::jsonb
    )
      INTO v_groups
      FROM jsonb_array_elements(
          COALESCE(v_legacy->'groups', '[]'::jsonb)
      ) x(g);

    RETURN jsonb_build_object(
        'schemaVersion', 2,
        'contract', 'tee_central_round_start',
        'contractVersion', v_contract_version,

        'preparationEngine', v_preparation_engine,
        'validationEngine', v_validation_engine,

        'freezeId', v_legacy->>'freezeId',
        'roundConditionSnapshotId',
            v_legacy->>'roundConditionSnapshotId',

        'tournament',
            v_legacy->'tournament',

        'round',
            v_legacy->'round',

        'format',
            v_legacy->'format',

        'groups',
            v_groups
    );
END;
$function$;


-- ============================================================================
-- 08. PRIVILEGIOS
-- ============================================================================
REVOKE ALL
ON FUNCTION public.obtener_motor_salida_ronda(uuid)
FROM PUBLIC, anon;

REVOKE ALL
ON FUNCTION public._construir_contrato_salida_ronda(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.obtener_motor_salida_ronda(uuid)
TO authenticated, service_role;

GRANT EXECUTE
ON FUNCTION public._construir_contrato_salida_ronda(uuid)
TO service_role;


COMMIT;
