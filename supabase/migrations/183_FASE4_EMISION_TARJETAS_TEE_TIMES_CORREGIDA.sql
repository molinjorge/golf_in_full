-- ============================================================================
-- 183_FASE4_EMISION_TARJETAS_TEE_TIMES.sql
-- TEE CENTRAL
--
-- OBJETIVO
-- Habilitar la emisión oficial de tarjetas para:
--   Tee Times + individual + Stroke
--
-- reutilizando el emisor genérico desacoplado en 182 Fase 3.
--
-- PRINCIPIOS
-- - No se crea un segundo emisor.
-- - No se crea un segundo sistema de captura.
-- - Tee Times reutiliza:
--     tournament_round_start_validations
--     tournament_round_start_validation_groups
--     tournament_round_start_validation_units
--     tournament_score_card_emissions
--     tournament_score_cards
--     inicializar_captura_scores_ronda()
-- - La unidad emitida sigue siendo registration porque esta versión Tee Times
--   es individual.
-- - La secuencia de juego parte de validation_groups.hole_number, que es común
--   tanto para Shotgun como para Tee Times.
-- - Shotgun debe conservar su numeración histórica de tarjetas.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. HABILITAR CAPACIDAD DE EMISIÓN TEE TIMES
-- ============================================================================
DO $migration$
DECLARE
    v_updated integer := 0;
BEGIN
    UPDATE public.tournament_start_engine_registry
    SET
        supports_scorecard_emission = true,
        scorecard_unit_type = 'registration',
        scorecard_emission_engine = 'official_scorecard_registration_v1',
        updated_at = now()
    WHERE start_format =
            'tee_times'::public.formato_salida_ronda
      AND participation_type = 'individual'
      AND scoring_engine = 'stroke'
      AND preparation_engine = 'tee_times_v1'
      AND validation_engine =
          'stroke_individual_tee_times_v1'
      AND supports_start_validation = true
      AND start_validation_handler = 'tee_times_v1'
      AND activo;

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    IF v_updated <> 1 THEN
        RAISE EXCEPTION
            'Se esperaba exactamente un motor Tee Times individual Stroke validable y activo; filas actualizadas=%.',
            v_updated
            USING ERRCODE = '55000';
    END IF;
END;
$migration$;


-- ============================================================================
-- 02. EMISOR COMÚN — ORDEN DE FOLIOS COMPATIBLE CON AMBOS FORMATOS
--
-- Único ajuste al emisor:
--
-- Shotgun:
--   conserva exactamente:
--     shift_number, hole_number, start_position, order_in_group, id
--
-- Tee Times:
--   como start_position IS NULL, ordena primero por start_at para que los
--   folios sigan la secuencia cronológica real del turno.
--
-- No cambia ninguna otra regla, tabla, inserción ni inicialización.
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

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para emitir tarjetas oficiales de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(
        p_tournament_round_id
    );

    -- Idempotencia: si ya existe emisión activa, no duplica tarjetas.
    IF public._ronda_tiene_tarjetas_emitidas(
        p_tournament_round_id
    ) THEN
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
     WHERE v.tournament_round_id =
         p_tournament_round_id
       AND v.status = 'validated'
     FOR UPDATE;

    IF v_validation.id IS NULL THEN
        RAISE EXCEPTION
            'Las salidas de la ronda deben estar validadas antes de emitir tarjetas oficiales.'
            USING ERRCODE = '23514',
                  HINT =
                      'Revise y valide primero las salidas de la ronda.';
    END IF;

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
                  DETAIL =
                      v_emission_capability::text;
    END IF;

    v_emission_validation_id :=
        (v_emission_capability->>'validationId')::uuid;

    v_emission_unit_type :=
        v_emission_capability->>'unitType';

    IF v_emission_validation_id
       IS DISTINCT FROM v_validation.id
    THEN
        RAISE EXCEPTION
            'La capacidad de emisión no corresponde a la validación formal bloqueada.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'validation_locked=%s; validation_capability=%s',
                      v_validation.id,
                      v_emission_validation_id
                  );
    END IF;

    SELECT
        count(*),
        public._contar_unidades_invalidas_emision_tarjetas(
            v_validation.id,
            v_emission_unit_type
        )
      INTO
        v_units,
        v_bad_units
      FROM public.tournament_round_start_validation_units u
     WHERE u.validation_id =
         v_validation.id;

    IF v_units = 0
       OR v_units <> v_validation.unit_count
    THEN
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
    RETURNING id
    INTO v_emission_id;

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

                    -- Tee Times:
                    -- start_position es NULL, por lo que toma start_at.
                    -- Shotgun:
                    -- start_position A/B no es NULL, por lo que esta expresión
                    -- queda NULL para todos y no altera su orden histórico.
                    CASE
                        WHEN g.start_position IS NULL
                        THEN g.start_at
                        ELSE NULL
                    END,

                    g.hole_number,
                    g.start_position,
                    u.order_in_group,
                    u.id
            )::integer AS card_number

        FROM public.tournament_round_start_validation_units u

        JOIN public.tournament_round_start_validation_groups g
          ON g.id = u.validation_group_id
         AND g.validation_id = u.validation_id

        WHERE u.validation_id =
            v_validation.id
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
            || lpad(
                v_round_number::text,
                2,
                '0'
            )
            || '-V'
            || lpad(
                v_validation.version::text,
                2,
                '0'
            )
            || '-'
            || lpad(
                ou.card_number::text,
                4,
                '0'
            ),

        'issued'

    FROM ordered_units ou

    ORDER BY ou.card_number;

    GET DIAGNOSTICS
        v_inserted = ROW_COUNT;

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
    -- inicializar_captura_scores_ronda() consume el grupo validado común y su
    -- hole_number de inicio, por lo que funciona para Shotgun y Tee Times.
    PERFORM public.inicializar_captura_scores_ronda(
        p_tournament_round_id
    );

    RETURN public.obtener_estado_emision_tarjetas_ronda(
        p_tournament_round_id
    );
END;
$function$;


COMMIT;
