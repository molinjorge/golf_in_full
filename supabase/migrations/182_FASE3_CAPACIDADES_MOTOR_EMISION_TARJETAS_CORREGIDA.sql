-- ============================================================================
-- 182_FASE3_CAPACIDADES_MOTOR_EMISION_TARJETAS_CORREGIDA.sql
-- TEE CENTRAL
--
-- VERSION CORREGIDA
--
-- OBJETIVO
-- Desacoplar emitir_tarjetas_score_ronda() de nombres hardcoded de motor,
-- formato de salida y tipo de unidad, usando capacidades explícitas registradas.
--
-- ESTA FASE:
-- - NO implementa Tee Times.
-- - NO habilita nuevas modalidades.
-- - Shotgun + individual + stroke sigue siendo la única combinación habilitada.
-- - NO modifica validaciones históricas.
-- - NO cambia conteos, folios, INSERTs ni inicialización de captura.
-- - NO usa SQL dinámico ni regexp_replace.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. CAPACIDADES EXPLÍCITAS DEL MOTOR
-- ============================================================================
ALTER TABLE public.tournament_start_engine_registry
ADD COLUMN IF NOT EXISTS supports_scorecard_emission boolean NOT NULL DEFAULT false;

ALTER TABLE public.tournament_start_engine_registry
ADD COLUMN IF NOT EXISTS scorecard_unit_type text;

ALTER TABLE public.tournament_start_engine_registry
ADD COLUMN IF NOT EXISTS scorecard_emission_engine text;

COMMENT ON COLUMN public.tournament_start_engine_registry.supports_scorecard_emission IS
'Indica si una validación producida por este motor puede alimentar la emisión oficial de tarjetas.';

COMMENT ON COLUMN public.tournament_start_engine_registry.scorecard_unit_type IS
'Tipo de unidad normalizada que el emisor acepta para este motor: registration, team u otro futuro.';

COMMENT ON COLUMN public.tournament_start_engine_registry.scorecard_emission_engine IS
'Identificador estable de la estrategia de emisión, desacoplado del validator_engine.';


-- ============================================================================
-- 02. FAIL-CLOSED + HABILITAR SOLAMENTE EL MOTOR ACTUAL
-- ============================================================================
UPDATE public.tournament_start_engine_registry
SET
    supports_scorecard_emission = false,
    scorecard_unit_type = NULL,
    scorecard_emission_engine = NULL,
    updated_at = now();

UPDATE public.tournament_start_engine_registry
SET
    supports_scorecard_emission = true,
    scorecard_unit_type = 'registration',
    scorecard_emission_engine = 'official_scorecard_registration_v1',
    updated_at = now()
WHERE start_format = 'shotgun'::public.formato_salida_ronda
  AND participation_type = 'individual'
  AND scoring_engine = 'stroke'
  AND preparation_engine = 'shotgun_v1'
  AND validation_engine = 'stroke_individual_shotgun_v1'
  AND activo;


-- ============================================================================
-- 03. RESOLVER CAPACIDAD DESDE LA VALIDACIÓN FORMAL SELLADA
-- ============================================================================
CREATE OR REPLACE FUNCTION public._resolver_capacidad_emision_tarjetas_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_validation record;
    v_registry record;
BEGIN
    SELECT
        v.id,
        v.tournament_id,
        v.tournament_round_id,
        v.status,
        v.validator_engine,
        v.start_format,
        v.participation_type,
        v.scoring_engine,
        v.start_contract_version
      INTO v_validation
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_round_id = p_tournament_round_id
       AND v.status = 'validated'
     ORDER BY v.version DESC
     LIMIT 1;

    IF v_validation.id IS NULL THEN
        RETURN jsonb_build_object(
            'supported', false,
            'code', 'round_not_validated',
            'message',
                'La ronda todavía no tiene una validación formal de salidas.'
        );
    END IF;

    SELECT
        r.id,
        r.preparation_engine,
        r.validation_engine,
        r.contract_version,
        r.supports_scorecard_emission,
        r.scorecard_unit_type,
        r.scorecard_emission_engine,
        r.activo
      INTO v_registry
      FROM public.tournament_start_engine_registry r
     WHERE r.start_format::text = v_validation.start_format
       AND r.participation_type = v_validation.participation_type
       AND r.scoring_engine = v_validation.scoring_engine
       AND r.validation_engine = v_validation.validator_engine
       AND r.activo
     LIMIT 1;

    IF v_registry.id IS NULL THEN
        RETURN jsonb_build_object(
            'supported', false,
            'code', 'validated_engine_not_registered',
            'message',
                'El motor que produjo la validación no está registrado como motor activo.',
            'validationId', v_validation.id,
            'validatorEngine', v_validation.validator_engine,
            'startFormat', v_validation.start_format,
            'participationType', v_validation.participation_type,
            'scoringEngine', v_validation.scoring_engine
        );
    END IF;

    IF NOT COALESCE(v_registry.supports_scorecard_emission, false)
       OR v_registry.scorecard_unit_type IS NULL
       OR v_registry.scorecard_emission_engine IS NULL
    THEN
        RETURN jsonb_build_object(
            'supported', false,
            'code', 'scorecard_emission_not_supported',
            'message',
                'El motor validado no tiene habilitada la emisión oficial de tarjetas.',
            'validationId', v_validation.id,
            'registryId', v_registry.id,
            'validatorEngine', v_validation.validator_engine
        );
    END IF;

    RETURN jsonb_build_object(
        'supported', true,
        'code', 'ok',
        'validationId', v_validation.id,
        'registryId', v_registry.id,
        'startContractVersion', v_validation.start_contract_version,
        'preparationEngine', v_registry.preparation_engine,
        'validationEngine', v_registry.validation_engine,
        'scorecardEmissionEngine',
            v_registry.scorecard_emission_engine,
        'unitType',
            v_registry.scorecard_unit_type
    );
END;
$function$;


-- ============================================================================
-- 04. VALIDAR UNIDADES SEGÚN CAPACIDAD
--
-- Preserva exactamente las exigencias actuales para registration:
-- - unit_type = registration
-- - tournament_registration_id no NULL
-- - player_id no NULL
--
-- Deja preparado el contrato para team, pero NINGÚN motor team se habilita
-- en esta fase.
-- ============================================================================
CREATE OR REPLACE FUNCTION public._contar_unidades_invalidas_emision_tarjetas(
    p_validation_id uuid,
    p_expected_unit_type text
)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT count(*)::integer
    FROM public.tournament_round_start_validation_units u
    WHERE u.validation_id = p_validation_id
      AND (
          u.unit_type IS DISTINCT FROM p_expected_unit_type

          OR (
              p_expected_unit_type = 'registration'
              AND (
                  u.tournament_registration_id IS NULL
                  OR u.player_id IS NULL
              )
          )

          OR (
              p_expected_unit_type = 'team'
              AND u.tournament_team_id IS NULL
          )
      );
$function$;


-- ============================================================================
-- 05. EMISIÓN OFICIAL RECONSTRUIDA EXPLÍCITAMENTE
--
-- Se conserva la lógica original instalada.
-- ÚNICOS CAMBIOS CONCEPTUALES:
-- A) compatibilidad de motor -> registry capability
-- B) unit_type esperado -> registry capability
-- ============================================================================
CREATE OR REPLACE FUNCTION public.emitir_tarjetas_score_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_round_number integer;
    v_admin_id uuid;
    v_validation record;
    v_emission_id uuid;
    v_inserted integer := 0;
    v_units integer := 0;
    v_bad_units integer := 0;

    v_emission_capability jsonb;
    v_emission_validation_id uuid;
    v_emission_unit_type text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tr.tournament_id, tr.numero_ronda
      INTO v_tournament_id, v_round_number
      FROM public.tournament_rounds tr
     WHERE tr.id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para emitir tarjetas oficiales de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(p_tournament_round_id);

    -- Idempotencia: si ya existe emisión activa, no duplica tarjetas.
    IF public._ronda_tiene_tarjetas_emitidas(p_tournament_round_id) THEN
        PERFORM public.inicializar_captura_scores_ronda(
            p_tournament_round_id
        );

        RETURN public.obtener_estado_emision_tarjetas_ronda(
            p_tournament_round_id
        );
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        v.id,
        v.version,
        v.validator_engine,
        v.start_format,
        v.participation_type,
        v.scoring_engine,
        v.unit_count
      INTO v_validation
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_round_id = p_tournament_round_id
       AND v.status = 'validated'
     FOR UPDATE;

    IF v_validation.id IS NULL THEN
        RAISE EXCEPTION
            'Las salidas de la ronda deben estar validadas antes de emitir tarjetas oficiales.'
            USING ERRCODE = '23514',
                  HINT =
                      'Revise y valide primero las salidas de la ronda.';
    END IF;

    -- ------------------------------------------------------------------------
    -- NUEVO: capacidad declarada por el motor de la validación sellada.
    -- ------------------------------------------------------------------------
    v_emission_capability :=
        public._resolver_capacidad_emision_tarjetas_ronda(
            p_tournament_round_id
        );

    IF NOT COALESCE(
        (v_emission_capability->>'supported')::boolean,
        false
    ) THEN
        RAISE EXCEPTION
            'El motor validado no permite emitir tarjetas oficiales.'
            USING ERRCODE = '0A000',
                  DETAIL = v_emission_capability::text;
    END IF;

    v_emission_validation_id :=
        (v_emission_capability->>'validationId')::uuid;

    v_emission_unit_type :=
        v_emission_capability->>'unitType';

    -- Defensa: el resolver debe estar hablando de la misma validación bloqueada.
    IF v_emission_validation_id IS DISTINCT FROM v_validation.id THEN
        RAISE EXCEPTION
            'La capacidad de emisión no corresponde a la validación formal bloqueada.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'validation_locked=%s; validation_capability=%s',
                      v_validation.id,
                      v_emission_validation_id
                  );
    END IF;

    -- ------------------------------------------------------------------------
    -- Conteos originales preservados.
    -- ------------------------------------------------------------------------
    SELECT
        count(*),
        public._contar_unidades_invalidas_emision_tarjetas(
            v_validation.id,
            v_emission_unit_type
        )
      INTO v_units, v_bad_units
      FROM public.tournament_round_start_validation_units u
     WHERE u.validation_id = v_validation.id;

    IF v_units = 0 OR v_units <> v_validation.unit_count THEN
        RAISE EXCEPTION
            'La fotografía validada no contiene el número esperado de participantes.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'unidades_snapshot=%s; unidades_validacion=%s',
                      v_units,
                      v_validation.unit_count
                  );
    END IF;

    IF v_bad_units > 0 THEN
        RAISE EXCEPTION
            'La validación contiene unidades incompatibles con el motor de emisión.'
            USING ERRCODE = '0A000',
                  DETAIL = format(
                      'unit_type_esperado=%s; unidades_no_soportadas=%s',
                      v_emission_unit_type,
                      v_bad_units
                  );
    END IF;

    -- ------------------------------------------------------------------------
    -- Lógica original de emisión: SIN CAMBIOS.
    -- ------------------------------------------------------------------------
    INSERT INTO public.tournament_score_card_emissions (
        tournament_id,
        tournament_round_id,
        validation_id,
        validation_version,
        status,
        card_count,
        issued_by
    )
    VALUES (
        v_tournament_id,
        p_tournament_round_id,
        v_validation.id,
        v_validation.version,
        'issued',
        v_validation.unit_count,
        v_admin_id
    )
    RETURNING id INTO v_emission_id;

    WITH ordered_units AS (
        SELECT
            u.id AS validation_unit_id,
            u.validation_group_id,
            u.unit_type,
            u.tournament_registration_id,
            u.tournament_team_id,
            u.player_id,
            u.tournament_category_id,
            row_number() OVER (
                ORDER BY
                    g.shift_number,
                    g.hole_number,
                    g.start_position,
                    u.order_in_group,
                    u.id
            )::integer AS card_number
        FROM public.tournament_round_start_validation_units u
        JOIN public.tournament_round_start_validation_groups g
          ON g.id = u.validation_group_id
         AND g.validation_id = u.validation_id
        WHERE u.validation_id = v_validation.id
    )
    INSERT INTO public.tournament_score_cards (
        emission_id,
        tournament_id,
        tournament_round_id,
        validation_id,
        validation_version,
        validation_group_id,
        validation_unit_id,
        unit_type,
        tournament_registration_id,
        tournament_team_id,
        player_id,
        tournament_category_id,
        card_number,
        card_folio,
        status
    )
    SELECT
        v_emission_id,
        v_tournament_id,
        p_tournament_round_id,
        v_validation.id,
        v_validation.version,
        ou.validation_group_id,
        ou.validation_unit_id,
        ou.unit_type,
        ou.tournament_registration_id,
        ou.tournament_team_id,
        ou.player_id,
        ou.tournament_category_id,
        ou.card_number,
        'R'
            || lpad(v_round_number::text, 2, '0')
            || '-V'
            || lpad(v_validation.version::text, 2, '0')
            || '-'
            || lpad(ou.card_number::text, 4, '0'),
        'issued'
    FROM ordered_units ou
    ORDER BY ou.card_number;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    IF v_inserted <> v_validation.unit_count THEN
        RAISE EXCEPTION
            'La emisión de tarjetas quedó incompleta y fue revertida automáticamente.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'tarjetas_insertadas=%s; tarjetas_esperadas=%s',
                      v_inserted,
                      v_validation.unit_count
                  );
    END IF;

    -- La emisión y la inicialización digital quedan en la MISMA transacción.
    -- Si la inicialización falla, PostgreSQL revierte también la emisión.
    PERFORM public.inicializar_captura_scores_ronda(
        p_tournament_round_id
    );

    RETURN public.obtener_estado_emision_tarjetas_ronda(
        p_tournament_round_id
    );
END;
$function$;


-- ============================================================================
-- 06. PRIVILEGIOS
-- ============================================================================
REVOKE ALL
ON FUNCTION public._resolver_capacidad_emision_tarjetas_ronda(uuid)
FROM PUBLIC, anon, authenticated;

REVOKE ALL
ON FUNCTION public._contar_unidades_invalidas_emision_tarjetas(uuid,text)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._resolver_capacidad_emision_tarjetas_ronda(uuid)
TO service_role;

GRANT EXECUTE
ON FUNCTION public._contar_unidades_invalidas_emision_tarjetas(uuid,text)
TO service_role;

COMMIT;
