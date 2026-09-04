-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 240
-- Payload oficial de tarjetas: contrato TEAM para A-Go-Go / team_stroke
--
-- Objetivo:
--   - Mantener el RPC común obtener_payload_tarjetas_score_oficiales_ronda(uuid).
--   - Incorporar una rama TEAM para A-Go-Go/equipo/team_stroke.
--   - Leer la evidencia oficial vigente desde tournament_score_cards y
--     tournament_team_scorecard_snapshots, que ya son actualizados por las
--     revisiones post-emisión 215/216 sin cambiar score_card_id.
--   - Preservar el comportamiento PLAYER existente para Stroke/Stableford.
--   - No exponer qrToken en la rama TEAM.
--   - No fabricar tee ni yardaje único de equipo.
--
-- No crea tablas, no altera datos, no toca emisión, scoring ni conciliación.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(
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

    -- =====================================================================
    -- RAMA TEAM — A-Go-Go / equipo / team_stroke
    -- =====================================================================
    IF v_ctx.participation_type = 'equipo'
       AND v_ctx.scoring_engine = 'team_stroke'
    THEN
        SELECT
            count(*),
            count(*) FILTER (
                WHERE sc.unit_type IS DISTINCT FROM 'team'
                   OR sc.tournament_team_id IS NULL
                   OR u.id IS NULL
                   OR g.id IS NULL
                   OR ss.id IS NULL
            )
          INTO v_cards_count, v_bad_links
          FROM public.tournament_score_cards sc
          LEFT JOIN public.tournament_round_start_validation_units u
            ON u.id = sc.validation_unit_id
           AND u.validation_id = sc.validation_id
           AND u.unit_type = 'team'
           AND u.tournament_team_id = sc.tournament_team_id
          LEFT JOIN public.tournament_round_start_validation_groups g
            ON g.id = sc.validation_group_id
           AND g.validation_id = sc.validation_id
          LEFT JOIN public.tournament_team_scorecard_snapshots ss
            ON ss.score_card_id = sc.id
           AND ss.tournament_team_id = sc.tournament_team_id
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
                'Existen tarjetas TEAM oficiales con vínculos históricos incompletos.'
                USING ERRCODE = '55000',
                      DETAIL = format(
                          'tarjetas_team_con_vinculos_incompletos=%s',
                          v_bad_links
                      );
        END IF;

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

        team_cards AS (
            SELECT
                sc.id AS score_card_id,
                sc.card_number,
                sc.card_folio,
                sc.status,
                sc.issued_at,
                sc.validation_id,
                sc.validation_version,
                sc.validation_group_id,
                sc.validation_unit_id,
                sc.tournament_team_id,
                sc.tournament_category_id,

                u.order_in_group,

                g.category_name,
                g.hole_number,
                g.start_position,
                g.start_at,
                g.shift_number,
                g.shift_time,
                g.group_label,
                g.source_format_metadata,

                ss.team_handicap_version_id,
                ss.team_name,
                ss.team_handicap_method,
                ss.team_handicap_unrounded,
                ss.team_playing_handicap,
                ss.member_count,
                ss.members_snapshot,
                ss.signature_requirements,

                COALESCE((
                    SELECT max(r.revision_number)
                    FROM public.tournament_team_scorecard_revisions r
                    WHERE r.score_card_id = sc.id
                ), 0) AS revision_number,

                EXISTS (
                    SELECT 1
                    FROM public.tournament_scorecard_capture_sessions cs
                    WHERE cs.score_card_id = sc.id
                ) AS capture_initialized

            FROM public.tournament_score_cards sc
            JOIN public.tournament_round_start_validation_units u
              ON u.id = sc.validation_unit_id
             AND u.validation_id = sc.validation_id
             AND u.unit_type = 'team'
             AND u.tournament_team_id = sc.tournament_team_id
            JOIN public.tournament_round_start_validation_groups g
              ON g.id = sc.validation_group_id
             AND g.validation_id = sc.validation_id
            JOIN public.tournament_team_scorecard_snapshots ss
              ON ss.score_card_id = sc.id
             AND ss.tournament_team_id = sc.tournament_team_id
            WHERE sc.emission_id = v_ctx.emission_id
              AND sc.status = 'issued'
              AND sc.unit_type = 'team'
        ),

        member_rows AS (
            SELECT
                tc.score_card_id,
                NULLIF(m.value->>'registrationId','')::uuid AS registration_id,
                NULLIF(m.value->>'playerId','')::uuid AS player_id,
                m.value->>'name' AS player_name,
                NULLIF(m.value->>'handicapIndex','')::numeric AS handicap_index,
                m.value->>'handicapSource' AS handicap_source,
                m.value->>'handicapStatus' AS handicap_status,
                NULLIF(m.value->>'teeId','')::uuid AS tee_id,
                NULLIF(m.value->>'courseRating','')::numeric AS course_rating,
                NULLIF(m.value->>'slopeRating','')::numeric AS slope_rating,
                NULLIF(m.value->>'courseHandicapUnrounded','')::numeric AS course_handicap_unrounded,
                NULLIF(m.value->>'whsRank','')::integer AS whs_rank,
                NULLIF(m.value->>'whsWeightPct','')::numeric AS whs_weight_pct,

                COALESCE(round_tee.tee_name, freeze_tee.tee_name) AS tee_name,
                round_tee.tee_color_hex

            FROM team_cards tc
            CROSS JOIN LATERAL jsonb_array_elements(tc.members_snapshot) AS m(value)

            LEFT JOIN LATERAL (
                SELECT
                    ts.tee_name,
                    ts.tee_color_hex
                FROM public.tournament_round_handicap_snapshots rhs
                JOIN public.tournament_round_handicap_tee_snapshots ts
                  ON ts.round_handicap_snapshot_id = rhs.id
                 AND ts.tee_id = NULLIF(m.value->>'teeId','')::uuid
                WHERE rhs.round_condition_snapshot_id = v_ctx.round_condition_snapshot_id
                  AND rhs.tournament_round_id = p_tournament_round_id
                  AND rhs.tournament_registration_id = NULLIF(m.value->>'registrationId','')::uuid
                  AND rhs.player_id = NULLIF(m.value->>'playerId','')::uuid
                  AND rhs.tee_id = NULLIF(m.value->>'teeId','')::uuid
                ORDER BY rhs.created_at DESC, rhs.id DESC
                LIMIT 1
            ) round_tee ON true

            LEFT JOIN LATERAL (
                SELECT hs.tee_name
                FROM public.tournament_handicap_snapshots hs
                WHERE hs.freeze_id = v_ctx.freeze_id
                  AND hs.tournament_id = v_tournament_id
                  AND hs.tournament_registration_id = NULLIF(m.value->>'registrationId','')::uuid
                  AND hs.player_id = NULLIF(m.value->>'playerId','')::uuid
                  AND hs.tee_id = NULLIF(m.value->>'teeId','')::uuid
                ORDER BY hs.created_at DESC, hs.id DESC
                LIMIT 1
            ) freeze_tee ON true
        ),

        members_json AS (
            SELECT
                mr.score_card_id,
                COALESCE(
                    jsonb_agg(
                        jsonb_build_object(
                            'registrationId', mr.registration_id,
                            'playerId', mr.player_id,
                            'name', mr.player_name,
                            'nombreCompleto', mr.player_name,
                            'handicapIndex', mr.handicap_index,
                            'handicapSource', mr.handicap_source,
                            'handicapStatus', mr.handicap_status,
                            'teeId', mr.tee_id,
                            'teeName', mr.tee_name,
                            'teeColorHex', mr.tee_color_hex,
                            'courseRating', mr.course_rating,
                            'slopeRating', mr.slope_rating,
                            'courseHandicapUnrounded', mr.course_handicap_unrounded,
                            'whsRank', mr.whs_rank,
                            'whsWeightPct', mr.whs_weight_pct
                        )
                        ORDER BY
                            COALESCE(mr.whs_rank, 2147483647),
                            mr.player_name,
                            mr.player_id
                    ),
                    '[]'::jsonb
                ) AS members
            FROM member_rows mr
            GROUP BY mr.score_card_id
        ),

        team_tees AS (
            SELECT DISTINCT
                mr.score_card_id,
                mr.tee_id,
                mr.tee_name,
                mr.tee_color_hex
            FROM member_rows mr
            WHERE mr.tee_id IS NOT NULL
        ),

        cards_json AS (
            SELECT COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'scoreCardId', tc.score_card_id,
                        'cardNumber', tc.card_number,
                        'cardFolio', tc.card_folio,
                        'status', tc.status,
                        'issuedAt', tc.issued_at,
                        'validationVersion', tc.validation_version,
                        'revisionNumber', tc.revision_number,
                        'captureInitialized', tc.capture_initialized,

                        'unit', jsonb_build_object(
                            'kind', 'team'
                        ),

                        'team', jsonb_build_object(
                            'id', tc.tournament_team_id,
                            'name', tc.team_name,
                            'nombre', tc.team_name,
                            'members', COALESCE(mj.members, '[]'::jsonb)
                        ),

                        'category', jsonb_build_object(
                            'tournamentCategoryId', tc.tournament_category_id,
                            'name', tc.category_name,
                            'nombre', tc.category_name
                        ),

                        'teamHandicap', jsonb_build_object(
                            'versionId', tc.team_handicap_version_id,
                            'method', tc.team_handicap_method,
                            'unrounded', tc.team_handicap_unrounded,
                            'playingHandicap', tc.team_playing_handicap
                        ),

                        'handicap', jsonb_build_object(
                            'kind', 'team',
                            'valor', tc.team_playing_handicap,
                            'unrounded', tc.team_handicap_unrounded,
                            'method', tc.team_handicap_method,
                            'versionId', tc.team_handicap_version_id
                        ),

                        'start', jsonb_build_object(
                            'validationGroupId', tc.validation_group_id,

                            'holeNumber', tc.hole_number,
                            'position', tc.start_position,
                            'startAt', tc.start_at,
                            'shiftNumber', tc.shift_number,
                            'shiftTime', tc.shift_time,
                            'groupLabel', tc.group_label,
                            'orderInGroup', tc.order_in_group,

                            'numeroHoyo', tc.hole_number,
                            'posicion', tc.start_position,
                            'hora', tc.start_at,
                            'horaLocalTexto',
                                CASE
                                    WHEN tc.start_at IS NULL THEN NULL
                                    ELSE to_char(
                                        tc.start_at AT TIME ZONE v_ctx.course_timezone,
                                        'HH24:MI'
                                    )
                                END,
                            'numeroTurno', tc.shift_number,
                            'horaTurno', tc.shift_time,
                            'etiqueta', tc.group_label,
                            'ordenEnGrupo', tc.order_in_group,
                            'formatMetadata', tc.source_format_metadata
                        ),

                        'holes', (
                            SELECT COALESCE(
                                jsonb_agg(
                                    jsonb_build_object(
                                        'hoyoId', hb.source_hole_id,
                                        'numero', hb.hole_number,
                                        'par', hb.par,
                                        'strokeIndex', hb.stroke_index,
                                        'distancia', NULL,
                                        'distanciasPorTee', COALESCE((
                                            SELECT jsonb_agg(
                                                jsonb_build_object(
                                                    'teeId', tt.tee_id,
                                                    'nombre', tt.tee_name,
                                                    'colorHex', tt.tee_color_hex,
                                                    'distancia',
                                                        CASE
                                                            WHEN hb.tee_distances_yards ? tt.tee_id::text
                                                            THEN (hb.tee_distances_yards ->> tt.tee_id::text)::integer
                                                            ELSE NULL
                                                        END
                                                )
                                                ORDER BY tt.tee_name NULLS LAST, tt.tee_id
                                            )
                                            FROM team_tees tt
                                            WHERE tt.score_card_id = tc.score_card_id
                                        ), '[]'::jsonb)
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
                                WHERE hb.hole_number BETWEEN 1 AND 9
                            ),
                            'parIn', (
                                SELECT sum(hb.par)
                                FROM hole_base hb
                                WHERE hb.hole_number BETWEEN 10 AND 18
                            ),
                            'parTotal', (
                                SELECT sum(hb.par)
                                FROM hole_base hb
                            ),
                            'yardsOut', NULL,
                            'yardsIn', NULL,
                            'yardsTotal', NULL,
                            'yardagesByTee', COALESCE((
                                SELECT jsonb_agg(
                                    jsonb_build_object(
                                        'teeId', tt.tee_id,
                                        'nombre', tt.tee_name,
                                        'colorHex', tt.tee_color_hex,
                                        'yardsOut', (
                                            SELECT sum(
                                                CASE
                                                    WHEN hb.tee_distances_yards ? tt.tee_id::text
                                                    THEN (hb.tee_distances_yards ->> tt.tee_id::text)::integer
                                                    ELSE NULL
                                                END
                                            )
                                            FROM hole_base hb
                                            WHERE hb.hole_number BETWEEN 1 AND 9
                                        ),
                                        'yardsIn', (
                                            SELECT sum(
                                                CASE
                                                    WHEN hb.tee_distances_yards ? tt.tee_id::text
                                                    THEN (hb.tee_distances_yards ->> tt.tee_id::text)::integer
                                                    ELSE NULL
                                                END
                                            )
                                            FROM hole_base hb
                                            WHERE hb.hole_number BETWEEN 10 AND 18
                                        ),
                                        'yardsTotal', (
                                            SELECT sum(
                                                CASE
                                                    WHEN hb.tee_distances_yards ? tt.tee_id::text
                                                    THEN (hb.tee_distances_yards ->> tt.tee_id::text)::integer
                                                    ELSE NULL
                                                END
                                            )
                                            FROM hole_base hb
                                        )
                                    )
                                    ORDER BY tt.tee_name NULLS LAST, tt.tee_id
                                )
                                FROM team_tees tt
                                WHERE tt.score_card_id = tc.score_card_id
                            ), '[]'::jsonb)
                        ),

                        'signatures', tc.signature_requirements
                    )
                    ORDER BY tc.card_number
                ),
                '[]'::jsonb
            ) AS data
            FROM team_cards tc
            LEFT JOIN members_json mj
              ON mj.score_card_id = tc.score_card_id
        )

        SELECT jsonb_build_object(
            'schemaVersion', 2,

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
    END IF;

    -- =====================================================================
    -- RAMA PLAYER — comportamiento histórico preservado
    -- =====================================================================

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
$function$;

-- Seguridad: conservar el mismo patrón del RPC oficial.
REVOKE ALL ON FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(uuid) TO service_role;

COMMIT;
