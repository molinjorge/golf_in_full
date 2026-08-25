-- ============================================================================
-- MIGRACION 185 FASE 1H
-- PREVISUALIZACION OFICIAL DE TARJETAS ANTES DE EMISION
-- TEE CENTRAL
--
-- OBJETIVO
-- Permitir revisar las tarjetas que se emitirían para una ronda YA VALIDADA
-- sin crear todavía:
--   - tournament_score_card_emissions
--   - tournament_score_cards
--   - QR oficiales
--   - sesiones de captura
--   - scores por hoyo
--   - marcadores
--
-- ALCANCE
-- Es COMUN para cualquier motor registrado con emisión por registration,
-- incluyendo:
--   - Shotgun individual Stroke Play
--   - Tee Times individual Stroke Play
--
-- FUENTE
-- Fotografía validada e inmutable:
--   tournament_round_start_validations
--   tournament_round_start_validation_groups
--   tournament_round_start_validation_units
--   snapshots congelados de hándicap, tee, ronda y hoyos
--
-- NUMERACION
-- Copia exactamente el ORDER BY de emitir_tarjetas_score_ronda(uuid).
-- Por tanto prospectiveCardNumber/prospectiveCardFolio coinciden con lo que
-- recibiría la emisión si se ejecuta sobre la misma validación.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.previsualizar_tarjetas_score_ronda(
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
    v_round_number integer;
    v_validation record;
    v_capability jsonb;
    v_expected_unit_type text;
    v_bad_units integer := 0;
    v_units integer := 0;
    v_ctx record;
    v_payload jsonb;
    v_already_issued boolean := false;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id es obligatorio.'
            USING ERRCODE = '22023';
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
            'No tienes permiso para previsualizar las tarjetas de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        v.id,
        v.version,
        v.freeze_id,
        v.round_condition_snapshot_id,
        v.validator_engine,
        v.start_format,
        v.participation_type,
        v.scoring_engine,
        v.start_contract_version,
        v.unit_count,
        v.group_count,
        v.validated_at
      INTO v_validation
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_round_id = p_tournament_round_id
       AND v.status = 'validated'
     ORDER BY v.version DESC
     LIMIT 1;

    IF v_validation.id IS NULL THEN
        RAISE EXCEPTION
            'Las salidas de la ronda deben estar validadas antes de previsualizar tarjetas.'
            USING ERRCODE = '23514';
    END IF;

    v_capability :=
        public._resolver_capacidad_emision_tarjetas_ronda(
            p_tournament_round_id
        );

    IF NOT COALESCE(
        (v_capability->>'supported')::boolean,
        false
    ) THEN
        RAISE EXCEPTION
            'El motor validado no permite emitir tarjetas oficiales.'
            USING ERRCODE = '0A000',
                  DETAIL = v_capability::text;
    END IF;

    IF (v_capability->>'validationId')::uuid
       IS DISTINCT FROM v_validation.id
    THEN
        RAISE EXCEPTION
            'La capacidad de emisión no corresponde a la validación activa.'
            USING ERRCODE = '55000';
    END IF;

    v_expected_unit_type := v_capability->>'unitType';

    -- La fase actual del emisor oficial común soporta tarjetas por inscripción.
    IF v_expected_unit_type IS DISTINCT FROM 'registration' THEN
        RAISE EXCEPTION
            'La previsualización actual sólo soporta emisión oficial por inscripción.'
            USING ERRCODE = '0A000',
                  DETAIL = format(
                      'unit_type=%s',
                      COALESCE(v_expected_unit_type, 'NULL')
                  );
    END IF;

    SELECT
        count(*),
        public._contar_unidades_invalidas_emision_tarjetas(
            v_validation.id,
            v_expected_unit_type
        )
      INTO v_units, v_bad_units
      FROM public.tournament_round_start_validation_units u
     WHERE u.validation_id = v_validation.id;

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
                      v_expected_unit_type,
                      v_bad_units
                  );
    END IF;

    SELECT
        rcs.round_number,
        rcs.round_date,
        rcs.course_id,
        rcs.course_name,
        rcs.course_timezone,
        rcs.format_code,
        rcs.format_name,
        rcs.handicap_allowance_pct,
        rcs.course_par,
        t.nombre AS tournament_name,
        t.logo_url AS tournament_logo_url,
        t.es_beneficencia
      INTO v_ctx
      FROM public.tournament_round_condition_snapshots rcs
      JOIN public.tournaments t
        ON t.id = rcs.tournament_id
     WHERE rcs.id = v_validation.round_condition_snapshot_id
       AND rcs.tournament_round_id = p_tournament_round_id
       AND rcs.tournament_id = v_tournament_id
     LIMIT 1;

    IF v_ctx.round_number IS NULL THEN
        RAISE EXCEPTION
            'La validación no tiene un snapshot de condiciones de ronda válido.'
            USING ERRCODE = '55000';
    END IF;

    v_already_issued :=
        public._ronda_tiene_tarjetas_emitidas(
            p_tournament_round_id
        );

    RETURN (
        WITH
        hole_base AS (
            SELECT
                h.source_hole_id,
                h.hole_number,
                h.par,
                h.stroke_index,
                h.tee_distances_yards
            FROM public.tournament_round_hole_snapshots h
            WHERE h.round_condition_snapshot_id =
                  v_validation.round_condition_snapshot_id
            ORDER BY h.hole_number
        ),

        holes_root AS (
            SELECT COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'hoyoId', hb.source_hole_id,
                        'numero', hb.hole_number,
                        'par', hb.par,
                        'strokeIndex', hb.stroke_index
                    )
                    ORDER BY hb.hole_number
                ),
                '[]'::jsonb
            ) AS data
            FROM hole_base hb
        ),

        ordered_units AS (
            SELECT
                u.id AS validation_unit_id,
                u.validation_group_id,
                u.tournament_registration_id,
                u.player_id,
                u.tournament_category_id,
                u.unit_name,
                u.unit_folio,
                u.order_in_group,
                u.handicap_snapshot_id,
                u.round_handicap_snapshot_id,

                g.category_name,
                g.hole_number,
                g.start_position,
                g.start_at,
                g.shift_number,
                g.shift_time,
                g.group_label,
                g.source_format_metadata,

                row_number() OVER (
                    ORDER BY
                        g.shift_number,

                        -- EXACTAMENTE la regla de emitir_tarjetas_score_ronda:
                        CASE
                            WHEN g.start_position IS NULL
                            THEN g.start_at
                            ELSE NULL
                        END,

                        g.hole_number,
                        g.start_position,
                        u.order_in_group,
                        u.id
                )::integer AS prospective_card_number

            FROM public.tournament_round_start_validation_units u
            JOIN public.tournament_round_start_validation_groups g
              ON g.id = u.validation_group_id
             AND g.validation_id = u.validation_id
            WHERE u.validation_id = v_validation.id
        ),

        card_rows AS (
            SELECT
                ou.*,

                hs.handicap_index,
                hs.handicap_source,
                hs.handicap_source_date,
                hs.handicap_status,
                hs.player_sex,

                rhs.tee_id,
                rhs.course_rating,
                rhs.slope_rating,
                rhs.rating_source,
                rhs.handicap_allowance_pct,
                rhs.course_handicap_unrounded,
                rhs.course_handicap,
                rhs.playing_handicap,

                ts.tee_name,
                ts.tee_color_hex,

                'R'
                || lpad(v_round_number::text, 2, '0')
                || '-V'
                || lpad(v_validation.version::text, 2, '0')
                || '-'
                || lpad(ou.prospective_card_number::text, 4, '0')
                    AS prospective_card_folio

            FROM ordered_units ou
            JOIN public.tournament_handicap_snapshots hs
              ON hs.id = ou.handicap_snapshot_id
             AND hs.tournament_registration_id =
                 ou.tournament_registration_id
            JOIN public.tournament_round_handicap_snapshots rhs
              ON rhs.id = ou.round_handicap_snapshot_id
             AND rhs.handicap_snapshot_id = hs.id
             AND rhs.tournament_round_id =
                 p_tournament_round_id
             AND rhs.tournament_registration_id =
                 ou.tournament_registration_id
            JOIN public.tournament_round_handicap_tee_snapshots ts
              ON ts.round_handicap_snapshot_id = rhs.id
             AND ts.tee_id = rhs.tee_id
        ),

        companions AS (
            SELECT
                u.validation_group_id,
                jsonb_agg(
                    jsonb_build_object(
                        'validationUnitId', u.id,
                        'registrationId',
                            u.tournament_registration_id,
                        'nombreCompleto', u.unit_name,
                        'folioInscripcion', u.unit_folio,
                        'ordenEnGrupo', u.order_in_group
                    )
                    ORDER BY u.order_in_group, u.id
                ) AS members
            FROM public.tournament_round_start_validation_units u
            WHERE u.validation_id = v_validation.id
            GROUP BY u.validation_group_id
        ),

        cards_json AS (
            SELECT COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        -- IMPORTANTE:
                        -- no hay scoreCardId, emissionId ni qrToken,
                        -- porque todavía NO existe tarjeta oficial.
                        'prospectiveCardNumber',
                            cr.prospective_card_number,
                        'prospectiveCardFolio',
                            cr.prospective_card_folio,
                        'officiallyIssued',
                            false,

                        'validationUnitId',
                            cr.validation_unit_id,
                        'registrationId',
                            cr.tournament_registration_id,
                        'registrationFolio',
                            cr.unit_folio,

                        'player', jsonb_build_object(
                            'id', cr.player_id,
                            'nombreCompleto', cr.unit_name,
                            'sexo', cr.player_sex
                        ),

                        'category', jsonb_build_object(
                            'tournamentCategoryId',
                                cr.tournament_category_id,
                            'nombre',
                                cr.category_name
                        ),

                        'handicap', jsonb_build_object(
                            'valor',
                                cr.handicap_index,
                            'origen',
                                cr.handicap_source,
                            'estatus',
                                cr.handicap_status,
                            'fechaOrigen',
                                cr.handicap_source_date,
                            'courseHandicap',
                                cr.course_handicap,
                            'courseHandicapSinRedondear',
                                cr.course_handicap_unrounded,
                            'playingHandicap',
                                cr.playing_handicap,
                            'allowancePct',
                                cr.handicap_allowance_pct,
                            'courseRating',
                                cr.course_rating,
                            'slopeRating',
                                cr.slope_rating,
                            'ratingSource',
                                cr.rating_source
                        ),

                        'tee', jsonb_build_object(
                            'teeId',
                                cr.tee_id,
                            'nombre',
                                cr.tee_name,
                            'colorHex',
                                cr.tee_color_hex
                        ),

                        'start', jsonb_build_object(
                            'validationGroupId',
                                cr.validation_group_id,
                            'numeroHoyo',
                                cr.hole_number,
                            'posicion',
                                cr.start_position,
                            'hora',
                                cr.start_at,
                            'horaLocalTexto',
                                to_char(
                                    cr.start_at
                                    AT TIME ZONE
                                    v_ctx.course_timezone,
                                    'HH24:MI'
                                ),
                            'numeroTurno',
                                cr.shift_number,
                            'horaTurno',
                                cr.shift_time,
                            'etiqueta',
                                cr.group_label,
                            'ordenEnGrupo',
                                cr.order_in_group,
                            'formatMetadata',
                                cr.source_format_metadata,
                            'companeros',
                                COALESCE(
                                    cp.members,
                                    '[]'::jsonb
                                )
                        ),

                        'holes', (
                            SELECT COALESCE(
                                jsonb_agg(
                                    jsonb_build_object(
                                        'hoyoId',
                                            hb.source_hole_id,
                                        'numero',
                                            hb.hole_number,
                                        'par',
                                            hb.par,
                                        'strokeIndex',
                                            hb.stroke_index,
                                        'distancia',
                                            CASE
                                                WHEN hb.tee_distances_yards
                                                     ? cr.tee_id::text
                                                THEN (
                                                    hb.tee_distances_yards
                                                    ->> cr.tee_id::text
                                                )::integer
                                                ELSE NULL
                                            END
                                    )
                                    ORDER BY hb.hole_number
                                ),
                                '[]'::jsonb
                            )
                            FROM hole_base hb
                        ),

                        'totals', jsonb_build_object(
                            'parOut', (
                                SELECT sum(hb.par)
                                FROM hole_base hb
                                WHERE hb.hole_number
                                      BETWEEN 1 AND 9
                            ),
                            'parIn', (
                                SELECT sum(hb.par)
                                FROM hole_base hb
                                WHERE hb.hole_number
                                      BETWEEN 10 AND 18
                            ),
                            'parTotal', (
                                SELECT sum(hb.par)
                                FROM hole_base hb
                            ),
                            'yardsOut', (
                                SELECT sum(
                                    CASE
                                        WHEN hb.tee_distances_yards
                                             ? cr.tee_id::text
                                        THEN (
                                            hb.tee_distances_yards
                                            ->> cr.tee_id::text
                                        )::integer
                                        ELSE NULL
                                    END
                                )
                                FROM hole_base hb
                                WHERE hb.hole_number
                                      BETWEEN 1 AND 9
                            ),
                            'yardsIn', (
                                SELECT sum(
                                    CASE
                                        WHEN hb.tee_distances_yards
                                             ? cr.tee_id::text
                                        THEN (
                                            hb.tee_distances_yards
                                            ->> cr.tee_id::text
                                        )::integer
                                        ELSE NULL
                                    END
                                )
                                FROM hole_base hb
                                WHERE hb.hole_number
                                      BETWEEN 10 AND 18
                            ),
                            'yardsTotal', (
                                SELECT sum(
                                    CASE
                                        WHEN hb.tee_distances_yards
                                             ? cr.tee_id::text
                                        THEN (
                                            hb.tee_distances_yards
                                            ->> cr.tee_id::text
                                        )::integer
                                        ELSE NULL
                                    END
                                )
                                FROM hole_base hb
                            )
                        )
                    )
                    ORDER BY cr.prospective_card_number
                ),
                '[]'::jsonb
            ) AS data
            FROM card_rows cr
            LEFT JOIN companions cp
              ON cp.validation_group_id =
                 cr.validation_group_id
        )

        SELECT jsonb_build_object(
            'schemaVersion', 1,
            'preview', true,
            'officiallyIssued',
                v_already_issued,

            'emissionCapability',
                v_capability,

            'validation', jsonb_build_object(
                'id',
                    v_validation.id,
                'version',
                    v_validation.version,
                'validatedAt',
                    v_validation.validated_at,
                'validatorEngine',
                    v_validation.validator_engine,
                'startFormat',
                    v_validation.start_format,
                'participationType',
                    v_validation.participation_type,
                'scoringEngine',
                    v_validation.scoring_engine,
                'startContractVersion',
                    v_validation.start_contract_version,
                'expectedCardCount',
                    v_validation.unit_count
            ),

            'tournament', jsonb_build_object(
                'id',
                    v_tournament_id,
                'nombre',
                    v_ctx.tournament_name,
                'logoUrl',
                    v_ctx.tournament_logo_url,
                'esBeneficencia',
                    v_ctx.es_beneficencia
            ),

            'course', jsonb_build_object(
                'id',
                    v_ctx.course_id,
                'nombreOficial',
                    v_ctx.course_name,
                'timezone',
                    v_ctx.course_timezone,
                'par',
                    v_ctx.course_par
            ),

            'round', jsonb_build_object(
                'id',
                    p_tournament_round_id,
                'numeroRonda',
                    v_ctx.round_number,
                'fecha',
                    v_ctx.round_date,
                'formatoSalida',
                    v_validation.start_format
            ),

            'format', jsonb_build_object(
                'code',
                    v_ctx.format_code,
                'name',
                    v_ctx.format_name,
                'participationType',
                    v_validation.participation_type,
                'scoringEngine',
                    v_validation.scoring_engine,
                'validatorEngine',
                    v_validation.validator_engine
            ),

            'holes',
                hr.data,
            'cards',
                cj.data,

            'counts', jsonb_build_object(
                'cards',
                    jsonb_array_length(cj.data),
                'expectedCards',
                    v_validation.unit_count,
                'holes',
                    jsonb_array_length(hr.data)
            )
        )
        FROM holes_root hr
        CROSS JOIN cards_json cj
    );
END;
$function$;

REVOKE ALL
ON FUNCTION public.previsualizar_tarjetas_score_ronda(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.previsualizar_tarjetas_score_ronda(uuid)
TO authenticated, service_role;

COMMIT;
