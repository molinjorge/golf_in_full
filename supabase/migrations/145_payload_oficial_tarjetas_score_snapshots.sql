-- ============================================================================
-- MIGRACIÓN 145
-- PAYLOAD OFICIAL DE TARJETAS DE SCORE DESDE SNAPSHOTS
--
-- OBJETIVO
-- Exponer una RPC de SOLO LECTURA que construya el payload de impresión oficial
-- de una ronda emitida utilizando:
--
--   tournament_score_card_emissions
--   tournament_score_cards
--   tournament_round_start_validations
--   tournament_round_start_validation_groups
--   tournament_round_start_validation_units
--   tournament_handicap_snapshots
--   tournament_round_handicap_snapshots
--   tournament_round_handicap_tee_snapshots       (Migración 144)
--   tournament_round_condition_snapshots
--   tournament_round_hole_snapshots
--
-- PRINCIPIO
-- Los datos deportivos de la tarjeta oficial se reconstruyen desde snapshots
-- históricos y NO desde la conformación viva.
--
-- NO usa:
--   tournament_groups
--   tournament_group_players
--   tournament_registrations.qr_token
--   tournament_registrations.folio como folio de tarjeta
--   marcas_salida para nombre/color del tee
--   distancias_hoyo para yardas de la tarjeta
--
-- El nombre/logo del torneo se consultan del catálogo institucional vivo.
--
-- NO genera PDF.
-- NO modifica tarjetas.
-- NO modifica snapshots.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Dependencias
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    v_faltantes text;
BEGIN
    WITH req(tipo, objeto) AS (
        VALUES
            ('tabla', 'public.tournaments'),
            ('tabla', 'public.tournament_rounds'),
            ('tabla', 'public.tournament_score_card_emissions'),
            ('tabla', 'public.tournament_score_cards'),
            ('tabla', 'public.tournament_round_start_validations'),
            ('tabla', 'public.tournament_round_start_validation_groups'),
            ('tabla', 'public.tournament_round_start_validation_units'),
            ('tabla', 'public.tournament_handicap_snapshots'),
            ('tabla', 'public.tournament_round_handicap_snapshots'),
            ('tabla', 'public.tournament_round_handicap_tee_snapshots'),
            ('tabla', 'public.tournament_round_condition_snapshots'),
            ('tabla', 'public.tournament_round_hole_snapshots'),
            ('función', 'public.puede_administrar_congelamiento_torneo(uuid)')
    )
    SELECT string_agg(tipo || ': ' || objeto, E'\n' ORDER BY tipo, objeto)
      INTO v_faltantes
      FROM req
     WHERE (tipo = 'tabla' AND to_regclass(objeto) IS NULL)
        OR (tipo = 'función' AND to_regprocedure(objeto) IS NULL);

    IF v_faltantes IS NOT NULL THEN
        RAISE EXCEPTION
            'No puede ejecutarse la Migración 145. Faltan dependencias:%',
            E'\n' || v_faltantes
            USING ERRCODE = '55000';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. RPC oficial de lectura
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tournament_id uuid;
    v_ctx record;
    v_cards_count integer := 0;
    v_bad_links integer := 0;
    v_payload jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tr.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds tr
     WHERE tr.id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar las tarjetas oficiales de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        e.id AS emission_id,
        e.validation_id,
        e.validation_version,
        e.card_count,
        e.issued_at,
        e.issued_by,

        v.round_condition_snapshot_id,
        v.freeze_id,
        v.validator_engine,
        v.start_format,
        v.participation_type,
        v.scoring_engine,

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
      FROM public.tournament_score_card_emissions e
      JOIN public.tournament_round_start_validations v
        ON v.id = e.validation_id
       AND v.tournament_round_id = e.tournament_round_id
      JOIN public.tournament_round_condition_snapshots rcs
        ON rcs.id = v.round_condition_snapshot_id
      JOIN public.tournaments t
        ON t.id = e.tournament_id
     WHERE e.tournament_round_id = p_tournament_round_id
       AND e.status = 'issued'
     LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La ronda todavía no tiene una emisión oficial activa de tarjetas.'
            USING ERRCODE = '23514',
                  HINT = 'Emita primero las tarjetas oficiales de la ronda.';
    END IF;

    -- -----------------------------------------------------------------------
    -- 3. Integridad de vínculos de las tarjetas activas
    -- -----------------------------------------------------------------------

    SELECT
        count(*),
        count(*) FILTER (
            WHERE u.id IS NULL
               OR g.id IS NULL
               OR hs.id IS NULL
               OR rhs.id IS NULL
               OR ts.round_handicap_snapshot_id IS NULL
        )
      INTO v_cards_count, v_bad_links
      FROM public.tournament_score_cards sc
      LEFT JOIN public.tournament_round_start_validation_units u
        ON u.id = sc.validation_unit_id
       AND u.validation_id = sc.validation_id
      LEFT JOIN public.tournament_round_start_validation_groups g
        ON g.id = sc.validation_group_id
       AND g.validation_id = sc.validation_id
      LEFT JOIN public.tournament_handicap_snapshots hs
        ON hs.id = u.handicap_snapshot_id
      LEFT JOIN public.tournament_round_handicap_snapshots rhs
        ON rhs.id = u.round_handicap_snapshot_id
       AND rhs.handicap_snapshot_id = hs.id
      LEFT JOIN public.tournament_round_handicap_tee_snapshots ts
        ON ts.round_handicap_snapshot_id = rhs.id
     WHERE sc.emission_id = v_ctx.emission_id
       AND sc.status = 'issued';

    IF v_cards_count <> v_ctx.card_count THEN
        RAISE EXCEPTION
            'La emisión oficial no contiene el número esperado de tarjetas.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'tarjetas_encontradas=%s; tarjetas_emision=%s',
                      v_cards_count,
                      v_ctx.card_count
                  );
    END IF;

    IF v_bad_links > 0 THEN
        RAISE EXCEPTION
            'Existen tarjetas oficiales con vínculos históricos incompletos.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'tarjetas_con_vinculos_incompletos=%s',
                      v_bad_links
                  ),
                  HINT = 'Revise snapshots de validación, hándicap y tee antes de generar el PDF oficial.';
    END IF;

    -- -----------------------------------------------------------------------
    -- 4. Payload oficial
    -- -----------------------------------------------------------------------

    WITH
    hole_base AS (
        SELECT
            h.source_hole_id,
            h.hole_number,
            h.par,
            h.stroke_index,
            h.tee_distances_yards
        FROM public.tournament_round_hole_snapshots h
        WHERE h.round_condition_snapshot_id = v_ctx.round_condition_snapshot_id
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

    card_rows AS (
        SELECT
            sc.id AS score_card_id,
            sc.card_number,
            sc.card_folio,
            sc.qr_token,
            sc.status,
            sc.issued_at,
            sc.validation_version,

            u.tournament_registration_id,
            u.player_id,
            u.tournament_category_id,
            u.unit_name,
            u.unit_folio,
            u.order_in_group,

            g.id AS validation_group_id,
            g.category_name,
            g.hole_number,
            g.start_position,
            g.start_at,
            g.shift_number,
            g.shift_time,
            g.group_label,

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
            ts.tee_color_hex

        FROM public.tournament_score_cards sc
        JOIN public.tournament_round_start_validation_units u
          ON u.id = sc.validation_unit_id
         AND u.validation_id = sc.validation_id
        JOIN public.tournament_round_start_validation_groups g
          ON g.id = sc.validation_group_id
         AND g.validation_id = sc.validation_id
        JOIN public.tournament_handicap_snapshots hs
          ON hs.id = u.handicap_snapshot_id
        JOIN public.tournament_round_handicap_snapshots rhs
          ON rhs.id = u.round_handicap_snapshot_id
         AND rhs.handicap_snapshot_id = hs.id
        JOIN public.tournament_round_handicap_tee_snapshots ts
          ON ts.round_handicap_snapshot_id = rhs.id
        WHERE sc.emission_id = v_ctx.emission_id
          AND sc.status = 'issued'
    ),

    companions AS (
        SELECT
            u.validation_group_id,
            jsonb_agg(
                jsonb_build_object(
                    'validationUnitId', u.id,
                    'nombreCompleto', u.unit_name,
                    'ordenEnGrupo', u.order_in_group
                )
                ORDER BY u.order_in_group, u.id
            ) AS members
        FROM public.tournament_round_start_validation_units u
        WHERE u.validation_id = v_ctx.validation_id
        GROUP BY u.validation_group_id
    ),

    cards_json AS (
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'scoreCardId', cr.score_card_id,
                    'cardNumber', cr.card_number,
                    'cardFolio', cr.card_folio,
                    'qrToken', cr.qr_token,
                    'status', cr.status,
                    'issuedAt', cr.issued_at,
                    'validationVersion', cr.validation_version,

                    'registrationId', cr.tournament_registration_id,

                    'player', jsonb_build_object(
                        'id', cr.player_id,
                        'nombreCompleto', cr.unit_name,
                        'sexo', cr.player_sex
                    ),

                    'category', jsonb_build_object(
                        'tournamentCategoryId', cr.tournament_category_id,
                        'nombre', cr.category_name
                    ),

                    'handicap', jsonb_build_object(
                        'valor', cr.handicap_index,
                        'origen', cr.handicap_source,
                        'estatus', cr.handicap_status,
                        'fechaOrigen', cr.handicap_source_date,
                        'courseHandicap', cr.course_handicap,
                        'courseHandicapSinRedondear', cr.course_handicap_unrounded,
                        'playingHandicap', cr.playing_handicap,
                        'allowancePct', cr.handicap_allowance_pct,
                        'courseRating', cr.course_rating,
                        'slopeRating', cr.slope_rating,
                        'ratingSource', cr.rating_source
                    ),

                    'tee', jsonb_build_object(
                        'teeId', cr.tee_id,
                        'nombre', cr.tee_name,
                        'colorHex', cr.tee_color_hex
                    ),

                    'start', jsonb_build_object(
                        'validationGroupId', cr.validation_group_id,
                        'numeroHoyo', cr.hole_number,
                        'posicion', cr.start_position,
                        'hora', cr.start_at,
                        'horaLocalTexto',
                            CASE
                                WHEN cr.start_at IS NULL THEN NULL
                                ELSE to_char(
                                    cr.start_at AT TIME ZONE v_ctx.course_timezone,
                                    'HH24:MI'
                                )
                            END,
                        'numeroTurno', cr.shift_number,
                        'horaTurno', cr.shift_time,
                        'etiqueta', cr.group_label,
                        'ordenEnGrupo', cr.order_in_group,
                        'companeros', COALESCE(cp.members, '[]'::jsonb)
                    ),

                    'holes',
                    (
                        SELECT COALESCE(
                            jsonb_agg(
                                jsonb_build_object(
                                    'hoyoId', hb.source_hole_id,
                                    'numero', hb.hole_number,
                                    'par', hb.par,
                                    'strokeIndex', hb.stroke_index,
                                    'distancia',
                                        CASE
                                            WHEN hb.tee_distances_yards ? cr.tee_id::text
                                            THEN (hb.tee_distances_yards ->> cr.tee_id::text)::integer
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
                        'parOut',
                            (
                                SELECT sum(hb.par)
                                FROM hole_base hb
                                WHERE hb.hole_number BETWEEN 1 AND 9
                            ),
                        'parIn',
                            (
                                SELECT sum(hb.par)
                                FROM hole_base hb
                                WHERE hb.hole_number BETWEEN 10 AND 18
                            ),
                        'parTotal',
                            (
                                SELECT sum(hb.par)
                                FROM hole_base hb
                            ),
                        'yardsOut',
                            (
                                SELECT sum(
                                    CASE
                                        WHEN hb.tee_distances_yards ? cr.tee_id::text
                                        THEN (hb.tee_distances_yards ->> cr.tee_id::text)::integer
                                        ELSE NULL
                                    END
                                )
                                FROM hole_base hb
                                WHERE hb.hole_number BETWEEN 1 AND 9
                            ),
                        'yardsIn',
                            (
                                SELECT sum(
                                    CASE
                                        WHEN hb.tee_distances_yards ? cr.tee_id::text
                                        THEN (hb.tee_distances_yards ->> cr.tee_id::text)::integer
                                        ELSE NULL
                                    END
                                )
                                FROM hole_base hb
                                WHERE hb.hole_number BETWEEN 10 AND 18
                            ),
                        'yardsTotal',
                            (
                                SELECT sum(
                                    CASE
                                        WHEN hb.tee_distances_yards ? cr.tee_id::text
                                        THEN (hb.tee_distances_yards ->> cr.tee_id::text)::integer
                                        ELSE NULL
                                    END
                                )
                                FROM hole_base hb
                            )
                    )
                )
                ORDER BY cr.card_number
            ),
            '[]'::jsonb
        ) AS data
        FROM card_rows cr
        LEFT JOIN companions cp
          ON cp.validation_group_id = cr.validation_group_id
    )

    SELECT jsonb_build_object(
        'schemaVersion', 1,

        'tournament', jsonb_build_object(
            'id', v_tournament_id,
            'nombre', v_ctx.tournament_name,
            'logoUrl', v_ctx.tournament_logo_url,
            'esBeneficencia', v_ctx.es_beneficencia
        ),

        'course', jsonb_build_object(
            'id', v_ctx.course_id,
            'nombreOficial', v_ctx.course_name,
            'timezone', v_ctx.course_timezone,
            'par', v_ctx.course_par
        ),

        'round', jsonb_build_object(
            'id', p_tournament_round_id,
            'numeroRonda', v_ctx.round_number,
            'fecha', v_ctx.round_date,
            'formatoSalida', v_ctx.start_format
        ),

        'format', jsonb_build_object(
            'code', v_ctx.format_code,
            'name', v_ctx.format_name,
            'participationType', v_ctx.participation_type,
            'scoringEngine', v_ctx.scoring_engine,
            'validatorEngine', v_ctx.validator_engine
        ),

        'emission', jsonb_build_object(
            'id', v_ctx.emission_id,
            'validationId', v_ctx.validation_id,
            'validationVersion', v_ctx.validation_version,
            'cardCount', v_ctx.card_count,
            'issuedAt', v_ctx.issued_at,
            'issuedBy', v_ctx.issued_by
        ),

        'holes', hr.data,
        'cards', cj.data,

        'counts', jsonb_build_object(
            'cards', jsonb_array_length(cj.data),
            'holes', jsonb_array_length(hr.data)
        )
    )
      INTO v_payload
      FROM holes_root hr
      CROSS JOIN cards_json cj;

    RETURN v_payload;
END;
$$;

COMMENT ON FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(uuid)
IS 'Devuelve el payload oficial de tarjetas emitidas de una ronda usando fotografías/snapshots históricos. No genera PDF ni consulta conformación deportiva viva.';

-- ---------------------------------------------------------------------------
-- 5. Privilegios
-- ---------------------------------------------------------------------------

REVOKE ALL
ON FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(uuid)
TO authenticated;

COMMIT;
