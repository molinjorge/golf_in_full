-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 239
-- Fallback histórico para nombre de marca en preview TEAM
-- ============================================================================
-- Objetivo:
--   Corregir únicamente la etiqueta histórica de la marca de salida de cada
--   integrante en la previsualización A-Go-Go TEAM.
--
-- Principios:
--   * No crea tablas ni modifica datos.
--   * No altera emisión, score_card_id, scoring, salidas ni HCP TEAM.
--   * Conserva la versión HCP TEAM fijada por la validación de salidas.
--   * Usa snapshots congelados para ronda/campo/hoyos.
--   * Las marcas y yardas siguen siendo POR JUGADOR/TEE; nunca se inventa
--     una tee ni una distancia única del equipo.
--   * Conserva íntegro el contrato introducido por la Migración 238.
--   * Si el snapshot específico de tee de ronda tiene tee_name NULL, usa
--     como fallback el tee_name del tournament_handicap_snapshot del MISMO
--     freeze + inscripción + jugador + tee_id.
--   * No consulta marcas_salida para el nombre: evita convertir un catálogo
--     vivo en fuente histórica.
--   * El color sólo se toma del snapshot específico de ronda; si allí es
--     NULL permanece NULL (no se fabrica color histórico).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.previsualizar_tarjetas_equipo_a_gogo_ronda(
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
    v_validation public.tournament_round_start_validations%ROWTYPE;
    v_capability jsonb;
    v_bad_units integer;
    v_already_issued boolean;
    v_ctx record;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    SELECT tr.tournament_id, tr.numero_ronda
      INTO v_tournament_id, v_round_number
      FROM public.tournament_rounds tr
     WHERE tr.id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para previsualizar tarjetas.'
            USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_validation
      FROM public.tournament_round_start_validations
     WHERE tournament_round_id = p_tournament_round_id
       AND status = 'validated'
     ORDER BY version DESC
     LIMIT 1;

    IF v_validation.id IS NULL THEN
        RAISE EXCEPTION
            'Las salidas deben estar validadas antes de previsualizar tarjetas.'
            USING ERRCODE='23514';
    END IF;

    IF v_validation.start_format IS DISTINCT FROM 'shotgun'
       OR v_validation.participation_type IS DISTINCT FROM 'equipo'
       OR v_validation.scoring_engine IS DISTINCT FROM 'team_stroke'
    THEN
        RAISE EXCEPTION
            'Esta RPC corresponde únicamente a A-Go-Go Shotgun por equipo.'
            USING ERRCODE='0A000';
    END IF;

    v_capability := public._resolver_capacidad_emision_tarjetas_ronda(
        p_tournament_round_id
    );

    IF NOT COALESCE((v_capability->>'supported')::boolean, false)
       OR v_capability->>'unitType' IS DISTINCT FROM 'team'
    THEN
        RAISE EXCEPTION
            'El motor validado no tiene emisión de tarjeta TEAM habilitada.'
            USING ERRCODE='0A000',
                  DETAIL=v_capability::text;
    END IF;

    IF (v_capability->>'validationId')::uuid
       IS DISTINCT FROM v_validation.id
    THEN
        RAISE EXCEPTION
            'La capacidad de emisión no corresponde a la validación activa.'
            USING ERRCODE='55000';
    END IF;

    SELECT public._contar_unidades_invalidas_emision_tarjetas(
        v_validation.id,
        'team'
    )
      INTO v_bad_units;

    IF v_bad_units > 0 THEN
        RAISE EXCEPTION
            'La validación contiene unidades incompatibles con tarjeta TEAM.'
            USING ERRCODE='0A000',
                  DETAIL=format('unidades_no_soportadas=%s', v_bad_units);
    END IF;

    -- Debe existir y continuar vigente EXACTAMENTE la versión HCP TEAM
    -- asociada a la validación de salidas. No se toma "la última".
    IF EXISTS (
        SELECT 1
          FROM public.tournament_round_start_validation_units u
          LEFT JOIN LATERAL (
              SELECT public._team_hcp_version_from_validation_208(
                  v_validation.id,
                  u.tournament_team_id
              ) AS hcp_version_id
          ) x ON true
          LEFT JOIN public.tournament_round_team_handicap_versions hv
            ON hv.id = x.hcp_version_id
         WHERE u.validation_id = v_validation.id
           AND u.unit_type = 'team'
           AND (
               x.hcp_version_id IS NULL
               OR hv.id IS NULL
               OR hv.status IS DISTINCT FROM 'active'
               OR hv.is_stale
               OR hv.tournament_round_id IS DISTINCT FROM p_tournament_round_id
               OR hv.tournament_team_id IS DISTINCT FROM u.tournament_team_id
           )
    ) THEN
        RAISE EXCEPTION
            'Una o más tarjetas apuntan a un HCP de equipo faltante u obsoleto. Recalcula y revalida las salidas antes de emitir.'
            USING ERRCODE='23514';
    END IF;

    -- Contexto oficial: condiciones/hoyos provienen del snapshot congelado.
    -- Nombre/logo del torneo se conservan desde tournaments, igual que el
    -- contrato individual/oficial vigente, porque esos campos no forman parte
    -- del snapshot de condiciones de ronda.
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
            USING ERRCODE='55000';
    END IF;

    v_already_issued := public._ronda_tiene_tarjetas_emitidas(
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

        ordered AS (
            SELECT
                u.id AS validation_unit_id,
                u.validation_group_id,
                u.tournament_team_id,
                u.tournament_category_id,
                u.unit_name,
                u.order_in_group,
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
                        CASE
                            WHEN g.start_position IS NULL THEN g.start_at
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
            WHERE u.validation_id = v_validation.id
              AND u.unit_type = 'team'
        ),

        cards_base AS (
            SELECT
                o.*,
                hv.id AS team_hcp_version_id,
                hv.version AS team_hcp_version,
                hv.method,
                hv.team_handicap_unrounded,
                hv.team_playing_handicap
            FROM ordered o
            JOIN public.tournament_round_team_handicap_versions hv
              ON hv.id = public._team_hcp_version_from_validation_208(
                    v_validation.id,
                    o.tournament_team_id
                 )
        ),

        member_rows AS (
            SELECT
                cb.validation_unit_id,
                m.tournament_registration_id,
                m.player_id,
                m.player_name,
                m.handicap_index,
                m.handicap_source,
                m.handicap_source_date,
                m.handicap_status,
                m.tee_id,
                m.course_rating,
                m.slope_rating,
                m.course_par,
                m.course_handicap_unrounded,
                m.whs_rank,
                m.whs_weight_pct,
                m.contribution,
                rhs.course_handicap,
                rhs.playing_handicap,

                -- 239: nombre histórico de marca. El snapshot específico
                -- de ronda puede existir con tee_name NULL. En ese caso se
                -- recupera del snapshot general del MISMO freeze y jugador.
                COALESCE(ts.tee_name, hs_fallback.tee_name) AS tee_name,

                -- No existe otra fuente histórica congelada para color.
                -- Si el snapshot de ronda no lo tiene, debe permanecer NULL.
                ts.tee_color_hex
            FROM cards_base cb
            JOIN public.tournament_round_team_handicap_members m
              ON m.team_handicap_version_id = cb.team_hcp_version_id
            LEFT JOIN public.tournament_round_handicap_snapshots rhs
              ON rhs.round_condition_snapshot_id =
                 v_validation.round_condition_snapshot_id
             AND rhs.tournament_round_id = p_tournament_round_id
             AND rhs.tournament_registration_id = m.tournament_registration_id
             AND rhs.player_id = m.player_id
             AND rhs.tee_id = m.tee_id
            LEFT JOIN public.tournament_round_handicap_tee_snapshots ts
              ON ts.round_handicap_snapshot_id = rhs.id
             AND ts.tee_id = m.tee_id
            LEFT JOIN LATERAL (
                SELECT hs.tee_name
                FROM public.tournament_handicap_snapshots hs
                WHERE hs.freeze_id = v_validation.freeze_id
                  AND hs.tournament_id = v_tournament_id
                  AND hs.tournament_registration_id = m.tournament_registration_id
                  AND hs.player_id = m.player_id
                  AND hs.tee_id = m.tee_id
                ORDER BY hs.created_at DESC, hs.id DESC
                LIMIT 1
            ) hs_fallback ON true
        ),

        members_json AS (
            SELECT
                mr.validation_unit_id,
                COALESCE(
                    jsonb_agg(
                        jsonb_build_object(
                            -- Claves TEAM existentes
                            'registrationId', mr.tournament_registration_id,
                            'playerId', mr.player_id,
                            'name', mr.player_name,
                            'handicapIndex', mr.handicap_index,
                            'handicapSource', mr.handicap_source,
                            'handicapStatus', mr.handicap_status,
                            'teeId', mr.tee_id,
                            'courseHandicapUnrounded', mr.course_handicap_unrounded,

                            -- Contexto adicional normalizado para UI TEAM
                            'nombreCompleto', mr.player_name,
                            'handicapSourceDate', mr.handicap_source_date,
                            'courseHandicap', mr.course_handicap,
                            'playingHandicap', mr.playing_handicap,
                            'courseRating', mr.course_rating,
                            'slopeRating', mr.slope_rating,
                            'coursePar', mr.course_par,
                            'teeName', mr.tee_name,
                            'teeColorHex', mr.tee_color_hex,
                            'whsRank', mr.whs_rank,
                            'whsWeightPct', mr.whs_weight_pct,
                            'contribution', mr.contribution
                        )
                        ORDER BY
                            COALESCE(mr.whs_rank, 2147483647),
                            mr.player_name,
                            mr.player_id
                    ),
                    '[]'::jsonb
                ) AS members
            FROM member_rows mr
            GROUP BY mr.validation_unit_id
        ),

        team_tees AS (
            SELECT DISTINCT
                mr.validation_unit_id,
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
                        'prospectiveCardNumber', cb.card_number,
                        'prospectiveCardFolio',
                            'R' || lpad(v_round_number::text, 2, '0') ||
                            '-V' || lpad(v_validation.version::text, 2, '0') ||
                            '-' || lpad(cb.card_number::text, 4, '0'),
                        'officiallyIssued', false,
                        'validationUnitId', cb.validation_unit_id,

                        'unit', jsonb_build_object(
                            'kind', 'team'
                        ),

                        'team', jsonb_build_object(
                            'id', cb.tournament_team_id,
                            -- se preserva "name" y se agrega alias común
                            'name', cb.unit_name,
                            'nombre', cb.unit_name,
                            'members', COALESCE(mj.members, '[]'::jsonb)
                        ),

                        'category', jsonb_build_object(
                            'tournamentCategoryId', cb.tournament_category_id,
                            -- se preserva "name" y se agrega alias común
                            'name', cb.category_name,
                            'nombre', cb.category_name
                        ),

                        'teamHandicap', jsonb_build_object(
                            'versionId', cb.team_hcp_version_id,
                            'version', cb.team_hcp_version,
                            'method', cb.method,
                            'unrounded', cb.team_handicap_unrounded,
                            'playingHandicap', cb.team_playing_handicap
                        ),

                        -- No se fabrica handicap individual para el equipo.
                        -- El alias existe sólo para facilitar un ViewModel común
                        -- y apunta explícitamente al HCP competitivo TEAM.
                        'handicap', jsonb_build_object(
                            'kind', 'team',
                            'valor', cb.team_playing_handicap,
                            'unrounded', cb.team_handicap_unrounded,
                            'method', cb.method,
                            'versionId', cb.team_hcp_version_id,
                            'version', cb.team_hcp_version
                        ),

                        'start', jsonb_build_object(
                            'validationGroupId', cb.validation_group_id,

                            -- claves TEAM existentes
                            'holeNumber', cb.hole_number,
                            'position', cb.start_position,
                            'startAt', cb.start_at,
                            'shiftNumber', cb.shift_number,
                            'shiftTime', cb.shift_time,
                            'groupLabel', cb.group_label,
                            'orderInGroup', cb.order_in_group,

                            -- aliases del contrato común individual
                            'numeroHoyo', cb.hole_number,
                            'posicion', cb.start_position,
                            'hora', cb.start_at,
                            'horaLocalTexto',
                                CASE
                                    WHEN cb.start_at IS NULL THEN NULL
                                    ELSE to_char(
                                        cb.start_at AT TIME ZONE
                                        v_ctx.course_timezone,
                                        'HH24:MI'
                                    )
                                END,
                            'numeroTurno', cb.shift_number,
                            'horaTurno', cb.shift_time,
                            'etiqueta', cb.group_label,
                            'ordenEnGrupo', cb.order_in_group,
                            'formatMetadata', cb.source_format_metadata
                        ),

                        'holes', (
                            SELECT COALESCE(
                                jsonb_agg(
                                    jsonb_build_object(
                                        'hoyoId', hb.source_hole_id,
                                        'numero', hb.hole_number,
                                        'par', hb.par,
                                        'strokeIndex', hb.stroke_index,

                                        -- TEAM no tiene una distancia única.
                                        'distancia', NULL,

                                        -- Sólo se exponen las tees utilizadas
                                        -- por integrantes de ESTA tarjeta/equipo.
                                        'distanciasPorTee', COALESCE((
                                            SELECT jsonb_agg(
                                                jsonb_build_object(
                                                    'teeId', tt.tee_id,
                                                    'nombre', tt.tee_name,
                                                    'colorHex', tt.tee_color_hex,
                                                    'distancia',
                                                        CASE
                                                            WHEN hb.tee_distances_yards
                                                                 ? tt.tee_id::text
                                                            THEN (
                                                                hb.tee_distances_yards
                                                                ->> tt.tee_id::text
                                                            )::integer
                                                            ELSE NULL
                                                        END
                                                )
                                                ORDER BY tt.tee_name NULLS LAST,
                                                         tt.tee_id
                                            )
                                            FROM team_tees tt
                                            WHERE tt.validation_unit_id =
                                                  cb.validation_unit_id
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

                            -- No existe un yardaje único del equipo.
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
                                                    WHEN hb.tee_distances_yards
                                                         ? tt.tee_id::text
                                                    THEN (
                                                        hb.tee_distances_yards
                                                        ->> tt.tee_id::text
                                                    )::integer
                                                    ELSE NULL
                                                END
                                            )
                                            FROM hole_base hb
                                            WHERE hb.hole_number BETWEEN 1 AND 9
                                        ),
                                        'yardsIn', (
                                            SELECT sum(
                                                CASE
                                                    WHEN hb.tee_distances_yards
                                                         ? tt.tee_id::text
                                                    THEN (
                                                        hb.tee_distances_yards
                                                        ->> tt.tee_id::text
                                                    )::integer
                                                    ELSE NULL
                                                END
                                            )
                                            FROM hole_base hb
                                            WHERE hb.hole_number BETWEEN 10 AND 18
                                        ),
                                        'yardsTotal', (
                                            SELECT sum(
                                                CASE
                                                    WHEN hb.tee_distances_yards
                                                         ? tt.tee_id::text
                                                    THEN (
                                                        hb.tee_distances_yards
                                                        ->> tt.tee_id::text
                                                    )::integer
                                                    ELSE NULL
                                                END
                                            )
                                            FROM hole_base hb
                                        )
                                    )
                                    ORDER BY tt.tee_name NULLS LAST, tt.tee_id
                                )
                                FROM team_tees tt
                                WHERE tt.validation_unit_id = cb.validation_unit_id
                            ), '[]'::jsonb)
                        ),

                        'signatures', jsonb_build_object(
                            'teamPlayerRequired', true,
                            'opposingMarkerRequired', true
                        )
                    )
                    ORDER BY cb.card_number
                ),
                '[]'::jsonb
            ) AS data
            FROM cards_base cb
            LEFT JOIN members_json mj
              ON mj.validation_unit_id = cb.validation_unit_id
        )

        SELECT jsonb_build_object(
            'schemaVersion', 2,
            'preview', true,
            'officiallyIssued', v_already_issued,
            'emissionCapability', v_capability,

            'validation', jsonb_build_object(
                'id', v_validation.id,
                'version', v_validation.version,
                'validatedAt', v_validation.validated_at,
                'validatorEngine', v_validation.validator_engine,
                'startFormat', v_validation.start_format,
                'participationType', v_validation.participation_type,
                'scoringEngine', v_validation.scoring_engine,
                'startContractVersion', v_validation.start_contract_version,
                'expectedCardCount', v_validation.unit_count
            ),

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
                'formatoSalida', v_validation.start_format
            ),

            'format', jsonb_build_object(
                'code', v_ctx.format_code,
                'name', v_ctx.format_name,
                'participationType', v_validation.participation_type,
                'scoringEngine', v_validation.scoring_engine,
                'validatorEngine', v_validation.validator_engine
            ),

            'holes', hr.data,
            'cards', cj.data,

            'counts', jsonb_build_object(
                'cards', jsonb_array_length(cj.data),
                'expectedCards', v_validation.unit_count,
                'holes', jsonb_array_length(hr.data)
            )
        )
        FROM holes_root hr
        CROSS JOIN cards_json cj
    );
END;
$function$;

-- Mantener el mismo contrato de permisos vigente para la RPC específica TEAM.
REVOKE ALL ON FUNCTION public.previsualizar_tarjetas_equipo_a_gogo_ronda(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.previsualizar_tarjetas_equipo_a_gogo_ronda(uuid)
TO authenticated, service_role;
