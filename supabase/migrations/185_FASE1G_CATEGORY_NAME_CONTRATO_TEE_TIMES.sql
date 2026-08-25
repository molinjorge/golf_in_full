-- ============================================================================
-- MIGRACION 185 FASE 1G
-- TEE TIMES: CATEGORY NAME EN CONTRATO COMUN DE SALIDAS
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._construir_contrato_salida_tee_times_v1(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH ctx AS (
        SELECT
            tr.id AS round_id,
            tr.tournament_id,
            f.id AS freeze_id,
            rcs.id AS round_condition_snapshot_id,
            tr.numero_ronda,
            tr.fecha,
            tr.formato_salida::text AS start_format,
            rcs.format_code,
            rcs.format_name,
            rcs.participation_type,
            rcs.scoring_engine
        FROM public.tournament_rounds tr
        JOIN public.tournament_condition_freezes f
          ON f.tournament_id = tr.tournament_id
        JOIN public.tournament_round_condition_snapshots rcs
          ON rcs.freeze_id = f.id
         AND rcs.tournament_round_id = tr.id
        WHERE tr.id = p_tournament_round_id
    ),
    group_rows AS (
        SELECT
            g.id AS group_id,
            ttg.tournament_tee_time_category_config_id AS config_id,
            rs.id AS shift_id,
            sc.id AS shift_category_id,
            sc.tournament_category_id,
            ttg.tournament_tee_time_start_hole_id AS format_slot_id,
            g.hoyo_id,
            hole.hole_number,
            g.hora_salida,
            rs.numero_turno,
            rs.hora_salida AS shift_time,
            g.etiqueta,
            cfg.tamano_grupo_normal,
            cfg.tamano_grupo_maximo,
            ttg.sequence_number,
            sh.lane_order
        FROM ctx
        JOIN public.tournament_round_shifts rs
          ON rs.tournament_round_id = ctx.round_id
         AND rs.activo
        JOIN public.tournament_groups g
          ON g.tournament_round_shift_id = rs.id
         AND g.activo
        JOIN public.tournament_tee_time_groups ttg
          ON ttg.tournament_group_id = g.id
         AND ttg.activo
        JOIN public.tournament_tee_time_category_configs cfg
          ON cfg.id = ttg.tournament_tee_time_category_config_id
         AND cfg.activo
        JOIN public.tournament_round_shift_categories sc
          ON sc.id = cfg.tournament_round_shift_category_id
         AND sc.activo
        JOIN public.tournament_tee_time_shift_start_holes sh
          ON sh.id = ttg.tournament_tee_time_start_hole_id
         AND sh.activo
        JOIN public.tournament_round_hole_snapshots hole
          ON hole.tournament_round_id = ctx.round_id
         AND hole.source_hole_id = g.hoyo_id
    ),
    groups_json AS (
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'sourceGroupId', gr.group_id,
                    'sourceConfigId', gr.config_id,
                    'sourceShiftId', gr.shift_id,
                    'sourceShiftCategoryId', gr.shift_category_id,
                    'tournamentCategoryId', gr.tournament_category_id,
                    'categoryName', (
                        SELECT min(hs.category_name)
                        FROM public.tournament_group_players gp
                        JOIN public.tournament_round_handicap_snapshots rhs
                          ON rhs.tournament_round_id = p_tournament_round_id
                         AND rhs.tournament_registration_id = gp.tournament_registration_id
                        JOIN public.tournament_handicap_snapshots hs
                          ON hs.id = rhs.handicap_snapshot_id
                        WHERE gp.tournament_group_id = gr.group_id
                          AND hs.tournament_category_id = gr.tournament_category_id
                    ),
                    'sourceFormatSlotId', gr.format_slot_id,
                    'sourceHoleId', gr.hoyo_id,
                    'holeNumber', gr.hole_number,
                    'startAt', gr.hora_salida,
                    'startPosition', NULL,
                    'shiftNumber', gr.numero_turno,
                    'shiftTime', gr.shift_time,
                    'groupLabel', gr.etiqueta,
                    'normalSize', gr.tamano_grupo_normal,
                    'maximumSize', gr.tamano_grupo_maximo,
                    'units', COALESCE((
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'unitType', 'registration',
                                'registrationId', gp.tournament_registration_id,
                                'teamId', NULL,
                                'playerId', hs.player_id,
                                'name', hs.player_name,
                                'folio', hs.registration_folio,
                                'orderInGroup', gp.orden_en_grupo,
                                'handicapSnapshotId', hs.id,
                                'roundHandicapSnapshotId', rhs.id,
                                'teeId', rhs.tee_id,
                                'handicapIndex', hs.handicap_index,
                                'courseHandicap', rhs.course_handicap,
                                'playingHandicap', rhs.playing_handicap
                            )
                            ORDER BY gp.orden_en_grupo, gp.id
                        )
                        FROM public.tournament_group_players gp
                        JOIN public.tournament_round_handicap_snapshots rhs
                          ON rhs.tournament_round_id = p_tournament_round_id
                         AND rhs.tournament_registration_id = gp.tournament_registration_id
                        JOIN public.tournament_handicap_snapshots hs
                          ON hs.id = rhs.handicap_snapshot_id
                        WHERE gp.tournament_group_id = gr.group_id
                    ), '[]'::jsonb),
                    'formatMetadata', jsonb_build_object(
                        'startFormat', 'tee_times',
                        'sequenceNumber', gr.sequence_number,
                        'laneOrder', gr.lane_order
                    )
                )
                ORDER BY gr.numero_turno, gr.lane_order, gr.sequence_number, gr.group_id
            ),
            '[]'::jsonb
        ) AS data
        FROM group_rows gr
    )
    SELECT jsonb_build_object(
        'schemaVersion', 2,
        'contract', 'tee_central_round_start',
        'contractVersion', 2,
        'preparationEngine', 'tee_times_v1',
        'validationEngine', 'stroke_individual_tee_times_v1',
        'freezeId', ctx.freeze_id,
        'roundConditionSnapshotId', ctx.round_condition_snapshot_id,
        'tournament', jsonb_build_object('id', ctx.tournament_id),
        'round', jsonb_build_object(
            'id', ctx.round_id,
            'number', ctx.numero_ronda,
            'date', ctx.fecha,
            'startFormat', ctx.start_format
        ),
        'format', jsonb_build_object(
            'code', ctx.format_code,
            'name', ctx.format_name,
            'participationType', ctx.participation_type,
            'scoringEngine', ctx.scoring_engine
        ),
        'groups', gj.data
    )
    FROM ctx
    CROSS JOIN groups_json gj;
$function$;

REVOKE ALL
ON FUNCTION public._construir_contrato_salida_tee_times_v1(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._construir_contrato_salida_tee_times_v1(uuid)
TO service_role;

COMMIT;
