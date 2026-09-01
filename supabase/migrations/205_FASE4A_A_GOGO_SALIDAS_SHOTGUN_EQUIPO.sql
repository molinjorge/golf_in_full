-- ============================================================================
-- MIGRACIÓN 205 FASE 4A
-- A-Go-Go — contrato y validación de salidas Shotgun por EQUIPO
-- Proyecto: Tee Central / GOLF IN FULL
--
-- Alcance:
-- - Registra motor Shotgun + equipo + team_stroke.
-- - Usa tournament_group_teams como fuente autoritativa.
-- - Construye contrato común v2 con unitType='team'.
-- - Valida que cada equipo activo esté asignado exactamente una vez.
-- - Exige categoría coherente y HCP competitivo CURRENT por equipo/ronda.
-- - NO habilita todavía emisión de tarjeta oficial por equipo (Fase 5).
-- - NO habilita todavía reacomodos post-validación (Fase 4B).
-- - Tee Times por equipos queda fuera de esta migración.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Registro de motor de salida
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
VALUES (
    'shotgun'::public.formato_salida_ronda,
    'equipo',
    'team_stroke',
    'shotgun_team_v1',
    'team_stroke_team_shotgun_v1',
    2,
    true,
    false,
    'team',
    NULL,
    true,
    'shotgun_team_v1'
)
ON CONFLICT (start_format, participation_type, scoring_engine)
DO UPDATE SET
    preparation_engine = EXCLUDED.preparation_engine,
    validation_engine = EXCLUDED.validation_engine,
    contract_version = EXCLUDED.contract_version,
    activo = true,
    supports_scorecard_emission = false,
    scorecard_unit_type = 'team',
    scorecard_emission_engine = NULL,
    supports_start_validation = true,
    start_validation_handler = 'shotgun_team_v1',
    updated_at = now();

-- ----------------------------------------------------------------------------
-- 2. Constructor de contrato común v2 por equipo
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._construir_contrato_salida_shotgun_team_v1(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
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
      ON f.tournament_id=tr.tournament_id
    JOIN public.tournament_round_condition_snapshots rcs
      ON rcs.freeze_id=f.id
     AND rcs.tournament_round_id=tr.id
    WHERE tr.id=p_tournament_round_id
),
group_rows AS (
    SELECT
        g.id AS group_id,
        cfg.id AS config_id,
        rs.id AS shift_id,
        sc.id AS shift_category_id,
        sc.tournament_category_id,
        sh.id AS format_slot_id,
        sh.hoyo_id,
        hole.hole_number,
        g.posicion_salida,
        g.hora_salida,
        rs.numero_turno,
        rs.hora_salida AS shift_time,
        g.etiqueta,
        cfg.tamano_grupo_normal,
        cfg.tamano_grupo_maximo
    FROM ctx
    JOIN public.tournament_round_shifts rs
      ON rs.tournament_round_id=ctx.round_id
     AND rs.activo
    JOIN public.tournament_round_shift_categories sc
      ON sc.tournament_round_shift_id=rs.id
     AND sc.activo
    JOIN public.tournament_shotgun_category_configs cfg
      ON cfg.tournament_round_shift_category_id=sc.id
     AND cfg.activo
    JOIN public.tournament_shotgun_category_holes sh
      ON sh.tournament_shotgun_category_config_id=cfg.id
     AND sh.activo
    JOIN public.tournament_groups g
      ON g.tournament_shotgun_category_hole_id=sh.id
     AND g.tournament_round_shift_id=rs.id
     AND g.activo
    JOIN public.tournament_round_hole_snapshots hole
      ON hole.tournament_round_id=ctx.round_id
     AND hole.source_hole_id=sh.hoyo_id
),
unit_rows AS (
    SELECT
        gr.*,
        gt.tournament_team_id AS team_id,
        gt.orden_en_grupo,
        tt.nombre_equipo AS team_name,
        tt.tournament_category_id AS team_category_id,
        hv.id AS team_handicap_version_id,
        hv.version AS team_handicap_version,
        hv.method AS handicap_method,
        hv.team_handicap_unrounded,
        hv.team_playing_handicap
    FROM group_rows gr
    JOIN public.tournament_group_teams gt
      ON gt.tournament_group_id=gr.group_id
     AND gt.activo=true
    JOIN public.tournament_teams tt
      ON tt.id=gt.tournament_team_id
     AND tt.activo=true
    LEFT JOIN public.tournament_round_team_handicap_versions hv
      ON hv.tournament_round_id=p_tournament_round_id
     AND hv.tournament_team_id=tt.id
     AND hv.status='active'
     AND hv.is_stale=false
),
groups_json AS (
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'sourceGroupId',gr.group_id,
                'sourceConfigId',gr.config_id,
                'sourceShiftId',gr.shift_id,
                'sourceShiftCategoryId',gr.shift_category_id,
                'tournamentCategoryId',gr.tournament_category_id,
                'categoryName',(
                    SELECT c.nombre
                    FROM public.tournament_categories tc
                    JOIN public.categories c ON c.id=tc.category_id
                    WHERE tc.id=gr.tournament_category_id
                    LIMIT 1
                ),
                'sourceFormatSlotId',gr.format_slot_id,
                'sourceHoleId',gr.hoyo_id,
                'holeNumber',gr.hole_number,
                'startAt',gr.hora_salida,
                'startPosition',gr.posicion_salida,
                'shiftNumber',gr.numero_turno,
                'shiftTime',gr.shift_time,
                'groupLabel',gr.etiqueta,
                'normalSize',gr.tamano_grupo_normal,
                'maximumSize',gr.tamano_grupo_maximo,
                'units',COALESCE((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'unitType','team',
                            'registrationId',NULL,
                            'teamId',u.team_id,
                            'playerId',NULL,
                            'name',u.team_name,
                            'folio',NULL,
                            'orderInGroup',u.orden_en_grupo,
                            'handicapSnapshotId',NULL,
                            'roundHandicapSnapshotId',NULL,
                            'teamHandicapVersionId',
                                u.team_handicap_version_id,
                            'teamHandicapVersion',
                                u.team_handicap_version,
                            'teamHandicapMethod',
                                u.handicap_method,
                            'teamHandicapUnrounded',
                                u.team_handicap_unrounded,
                            'teamPlayingHandicap',
                                u.team_playing_handicap
                        )
                        ORDER BY u.orden_en_grupo,u.team_id
                    )
                    FROM unit_rows u
                    WHERE u.group_id=gr.group_id
                ),'[]'::jsonb),
                'formatMetadata',jsonb_build_object(
                    'startFormat','shotgun',
                    'sourceShotgunHoleId',gr.format_slot_id,
                    'startPosition',gr.posicion_salida
                )
            )
            ORDER BY
                gr.numero_turno,
                gr.hole_number,
                gr.posicion_salida,
                gr.group_id
        ),
        '[]'::jsonb
    ) AS data
    FROM group_rows gr
)
SELECT jsonb_build_object(
    'schemaVersion',2,
    'contract','tee_central_round_start',
    'contractVersion',2,
    'preparationEngine','shotgun_team_v1',
    'validationEngine','team_stroke_team_shotgun_v1',
    'freezeId',ctx.freeze_id,
    'roundConditionSnapshotId',ctx.round_condition_snapshot_id,
    'tournament',jsonb_build_object('id',ctx.tournament_id),
    'round',jsonb_build_object(
        'id',ctx.round_id,
        'number',ctx.numero_ronda,
        'date',ctx.fecha,
        'startFormat',ctx.start_format
    ),
    'format',jsonb_build_object(
        'code',ctx.format_code,
        'name',ctx.format_name,
        'participationType',ctx.participation_type,
        'scoringEngine',ctx.scoring_engine
    ),
    'groups',gj.data
)
FROM ctx
CROSS JOIN groups_json gj;
$$;

-- ----------------------------------------------------------------------------
-- 3. Validador previo Shotgun A-Go-Go por equipos
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._previsualizar_validacion_salidas_shotgun_team_v1(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_ctx record;
    v_errors jsonb := '[]'::jsonb;
    v_warnings jsonb := '[]'::jsonb;
    v_n integer;
    v_config_count integer := 0;
    v_group_count integer := 0;
    v_unit_count integer := 0;
    v_eligible_count integer := 0;
    v_existing record;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT
        tr.id AS round_id,
        tr.tournament_id,
        tr.numero_ronda,
        tr.fecha,
        tr.activo AS round_active,
        tr.formato_salida::text AS live_start_format,
        t.nombre AS tournament_name,
        t.estatus::text AS tournament_status,
        f.id AS freeze_id,
        f.warnings_snapshot AS freeze_warnings,
        rcs.id AS round_condition_snapshot_id,
        rcs.format_code,
        rcs.format_name,
        rcs.participation_type,
        rcs.scoring_engine,
        rcs.tournament_format_id AS frozen_format_id,
        COALESCE(tr.tournament_format_id,t.tournament_format_id)
            AS live_format_id
      INTO v_ctx
      FROM public.tournament_rounds tr
      JOIN public.tournaments t ON t.id=tr.tournament_id
      LEFT JOIN public.tournament_condition_freezes f
        ON f.tournament_id=tr.tournament_id
      LEFT JOIN public.tournament_round_condition_snapshots rcs
        ON rcs.freeze_id=f.id
       AND rcs.tournament_round_id=tr.id
     WHERE tr.id=p_tournament_round_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La ronda indicada no existe.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_ctx.tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para validar las salidas de esta ronda.'
            USING ERRCODE='42501';
    END IF;

    SELECT id,version,validated_at,content_hash,validator_engine
      INTO v_existing
      FROM public.tournament_round_start_validations
     WHERE tournament_round_id=p_tournament_round_id
       AND status='validated'
     ORDER BY version DESC
     LIMIT 1;

    IF NOT v_ctx.round_active THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','ronda_inactiva',
            'message','La ronda está inactiva.'
        ));
    END IF;

    IF v_ctx.freeze_id IS NULL THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','torneo_no_congelado',
            'message','El torneo debe estar congelado antes de validar salidas.'
        ));
    ELSIF v_ctx.round_condition_snapshot_id IS NULL THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','ronda_sin_snapshot',
            'message','La ronda no forma parte del congelamiento vigente.'
        ));
    END IF;

    IF COALESCE(v_ctx.live_start_format,'') <> 'shotgun' THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','ronda_no_shotgun',
            'message','Este motor requiere salida Shotgun.'
        ));
    END IF;

    IF COALESCE(v_ctx.participation_type,'') <> 'equipo'
       OR COALESCE(v_ctx.scoring_engine,'') <> 'team_stroke'
    THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','modalidad_no_soportada',
            'message','Este validador corresponde únicamente a A-Go-Go/team_stroke por equipos.'
        ));
    END IF;

    IF v_ctx.frozen_format_id IS DISTINCT FROM v_ctx.live_format_id THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','formato_distinto_del_congelado',
            'message','El formato efectivo vivo no coincide con el formato congelado.'
        ));
    END IF;

    IF v_ctx.tournament_status NOT IN ('inscripcion_cerrada','en_curso') THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','estatus_torneo_no_operativo',
            'message',format(
                'El torneo tiene estatus %s. Debes cerrar inscripciones antes de validar salidas.',
                v_ctx.tournament_status
            )
        ));
    END IF;

    IF jsonb_array_length(COALESCE(v_ctx.freeze_warnings,'[]'::jsonb))>0 THEN
        v_warnings:=v_warnings || jsonb_build_array(jsonb_build_object(
            'code','congelamiento_con_advertencias',
            'message','El congelamiento contiene advertencias.',
            'detail',v_ctx.freeze_warnings
        ));
    END IF;

    SELECT count(*) INTO v_n
    FROM public.tournament_round_hole_snapshots
    WHERE tournament_round_id=p_tournament_round_id;

    IF v_ctx.freeze_id IS NOT NULL AND v_n<>18 THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','snapshot_hoyos_incompleto',
            'message',format('La ronda tiene %s hoyos congelados; se requieren 18.',v_n)
        ));
    END IF;

    SELECT count(*) INTO v_config_count
    FROM public.tournament_shotgun_category_configs cfg
    JOIN public.tournament_round_shift_categories sc
      ON sc.id=cfg.tournament_round_shift_category_id
     AND sc.activo
    JOIN public.tournament_round_shifts rs
      ON rs.id=sc.tournament_round_shift_id
     AND rs.activo
    WHERE rs.tournament_round_id=p_tournament_round_id
      AND cfg.activo;

    -- Equipos activos del torneo = unidades elegibles.
    SELECT count(*) INTO v_eligible_count
    FROM public.tournament_teams tt
    WHERE tt.tournament_id=v_ctx.tournament_id
      AND tt.activo=true;

    IF v_eligible_count=0 THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','sin_equipos_elegibles',
            'message','El torneo no tiene equipos activos para esta ronda.'
        ));
    END IF;

    -- Cada equipo activo debe estar asignado exactamente una vez.
    WITH assigned AS (
        SELECT gt.tournament_team_id,count(*) n
        FROM public.tournament_group_teams gt
        JOIN public.tournament_groups g
          ON g.id=gt.tournament_group_id
         AND g.activo
        JOIN public.tournament_round_shifts rs
          ON rs.id=g.tournament_round_shift_id
         AND rs.activo
        WHERE rs.tournament_round_id=p_tournament_round_id
          AND gt.activo
        GROUP BY gt.tournament_team_id
    )
    SELECT count(*) INTO v_n
    FROM public.tournament_teams tt
    LEFT JOIN assigned a ON a.tournament_team_id=tt.id
    WHERE tt.tournament_id=v_ctx.tournament_id
      AND tt.activo
      AND COALESCE(a.n,0)<>1;

    IF v_n>0 THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','equipo_sin_grupo_unico',
            'message',format(
                '%s equipo(s) activos no están asignados exactamente una vez.',
                v_n
            )
        ));
    END IF;

    -- No debe haber jugadores como unidad competitiva.
    SELECT count(*) INTO v_n
    FROM public.tournament_group_players gp
    JOIN public.tournament_groups g ON g.id=gp.tournament_group_id AND g.activo
    JOIN public.tournament_round_shifts rs
      ON rs.id=g.tournament_round_shift_id
     AND rs.activo
    WHERE rs.tournament_round_id=p_tournament_round_id;

    IF v_n>0 THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','unidades_individuales_en_modalidad_equipo',
            'message',format(
                '%s asignación(es) individuales existen en una ronda A-Go-Go.',
                v_n
            )
        ));
    END IF;

    -- Todas las asignaciones deben apuntar a equipo activo del torneo.
    SELECT count(*) INTO v_n
    FROM public.tournament_group_teams gt
    JOIN public.tournament_groups g
      ON g.id=gt.tournament_group_id AND g.activo
    JOIN public.tournament_round_shifts rs
      ON rs.id=g.tournament_round_shift_id AND rs.activo
    LEFT JOIN public.tournament_teams tt
      ON tt.id=gt.tournament_team_id
    WHERE rs.tournament_round_id=p_tournament_round_id
      AND gt.activo
      AND (
          tt.id IS NULL
          OR NOT COALESCE(tt.activo,false)
          OR tt.tournament_id IS DISTINCT FROM v_ctx.tournament_id
      );

    IF v_n>0 THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','asignacion_equipo_no_elegible',
            'message',format(
                '%s asignación(es) apuntan a equipos inexistentes, inactivos o de otro torneo.',
                v_n
            )
        ));
    END IF;

    -- Categoría del equipo debe coincidir con categoría del grupo.
    SELECT count(*) INTO v_n
    FROM public.tournament_group_teams gt
    JOIN public.tournament_groups g
      ON g.id=gt.tournament_group_id AND g.activo
    JOIN public.tournament_round_shifts rs
      ON rs.id=g.tournament_round_shift_id AND rs.activo
    JOIN public.tournament_shotgun_category_holes sh
      ON sh.id=g.tournament_shotgun_category_hole_id AND sh.activo
    JOIN public.tournament_shotgun_category_configs cfg
      ON cfg.id=sh.tournament_shotgun_category_config_id AND cfg.activo
    JOIN public.tournament_round_shift_categories sc
      ON sc.id=cfg.tournament_round_shift_category_id AND sc.activo
    JOIN public.tournament_teams tt
      ON tt.id=gt.tournament_team_id
    WHERE rs.tournament_round_id=p_tournament_round_id
      AND gt.activo
      AND tt.tournament_category_id IS DISTINCT FROM sc.tournament_category_id;

    IF v_n>0 THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','categoria_equipo_incorrecta',
            'message',format(
                '%s equipo(s) están asignados a un grupo de otra categoría.',
                v_n
            )
        ));
    END IF;

    -- Cada equipo activo debe tener HCP competitivo CURRENT, salvo que el
    -- torneo esté configurado GROSS_ONLY: incluso allí debe existir versión 0
    -- vigente para preservar contrato/auditoría.
    SELECT count(*) INTO v_n
    FROM public.tournament_teams tt
    WHERE tt.tournament_id=v_ctx.tournament_id
      AND tt.activo
      AND NOT EXISTS (
          SELECT 1
          FROM public.tournament_round_team_handicap_versions hv
          WHERE hv.tournament_round_id=p_tournament_round_id
            AND hv.tournament_team_id=tt.id
            AND hv.status='active'
            AND hv.is_stale=false
      );

    IF v_n>0 THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','handicap_equipo_no_vigente',
            'message',format(
                '%s equipo(s) no tienen HCP competitivo CURRENT para esta ronda. Recalcula antes de validar salidas.',
                v_n
            )
        ));
    END IF;

    -- Grupos activos deben tener al menos un equipo.
    SELECT count(*) INTO v_n
    FROM public.tournament_groups g
    JOIN public.tournament_round_shifts rs
      ON rs.id=g.tournament_round_shift_id AND rs.activo
    WHERE rs.tournament_round_id=p_tournament_round_id
      AND g.activo
      AND NOT EXISTS (
          SELECT 1
          FROM public.tournament_group_teams gt
          WHERE gt.tournament_group_id=g.id
            AND gt.activo
      );

    IF v_n>0 THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','grupo_vacio',
            'message',format('%s grupo(s) activos no contienen equipos.',v_n)
        ));
    END IF;

    -- Máximo de equipos por grupo.
    SELECT count(*) INTO v_n
    FROM (
        SELECT g.id
        FROM public.tournament_groups g
        JOIN public.tournament_round_shifts rs
          ON rs.id=g.tournament_round_shift_id AND rs.activo
        JOIN public.tournament_shotgun_category_holes sh
          ON sh.id=g.tournament_shotgun_category_hole_id AND sh.activo
        JOIN public.tournament_shotgun_category_configs cfg
          ON cfg.id=sh.tournament_shotgun_category_config_id AND cfg.activo
        LEFT JOIN public.tournament_group_teams gt
          ON gt.tournament_group_id=g.id
         AND gt.activo
        WHERE rs.tournament_round_id=p_tournament_round_id
          AND g.activo
        GROUP BY g.id,cfg.tamano_grupo_maximo
        HAVING count(gt.id)>cfg.tamano_grupo_maximo
    ) x;

    IF v_n>0 THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','grupo_excede_maximo',
            'message',format('%s grupo(s) exceden el máximo de equipos.',v_n)
        ));
    END IF;

    -- Orden interno.
    SELECT count(*) INTO v_n
    FROM (
        SELECT gt.tournament_group_id
        FROM public.tournament_group_teams gt
        JOIN public.tournament_groups g
          ON g.id=gt.tournament_group_id AND g.activo
        JOIN public.tournament_round_shifts rs
          ON rs.id=g.tournament_round_shift_id AND rs.activo
        WHERE rs.tournament_round_id=p_tournament_round_id
          AND gt.activo
        GROUP BY gt.tournament_group_id
        HAVING bool_or(gt.orden_en_grupo IS NULL)
            OR count(*)<>count(DISTINCT gt.orden_en_grupo)
    ) x;

    IF v_n>0 THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','orden_grupo_invalido',
            'message',format(
                '%s grupo(s) tienen posiciones de equipo nulas o duplicadas.',
                v_n
            )
        ));
    END IF;

    SELECT count(*) INTO v_group_count
    FROM public.tournament_groups g
    JOIN public.tournament_round_shifts rs
      ON rs.id=g.tournament_round_shift_id AND rs.activo
    WHERE rs.tournament_round_id=p_tournament_round_id
      AND g.activo;

    SELECT count(*) INTO v_unit_count
    FROM public.tournament_group_teams gt
    JOIN public.tournament_groups g
      ON g.id=gt.tournament_group_id AND g.activo
    JOIN public.tournament_round_shifts rs
      ON rs.id=g.tournament_round_shift_id AND rs.activo
    WHERE rs.tournament_round_id=p_tournament_round_id
      AND gt.activo;

    RETURN jsonb_build_object(
        'schemaVersion',2,
        'validatorEngine','team_stroke_team_shotgun_v1',
        'generatedAt',now(),
        'ready',jsonb_array_length(v_errors)=0,
        'alreadyValidated',v_existing.id IS NOT NULL,
        'tournament',jsonb_build_object(
            'id',v_ctx.tournament_id,
            'name',v_ctx.tournament_name,
            'status',v_ctx.tournament_status
        ),
        'round',jsonb_build_object(
            'id',v_ctx.round_id,
            'number',v_ctx.numero_ronda,
            'date',v_ctx.fecha,
            'startFormat',v_ctx.live_start_format
        ),
        'format',jsonb_build_object(
            'code',v_ctx.format_code,
            'name',v_ctx.format_name,
            'participationType',v_ctx.participation_type,
            'scoringEngine',v_ctx.scoring_engine
        ),
        'currentValidation',
            CASE WHEN v_existing.id IS NULL THEN NULL
                 ELSE jsonb_build_object(
                    'id',v_existing.id,
                    'version',v_existing.version,
                    'validatedAt',v_existing.validated_at,
                    'contentHash',v_existing.content_hash,
                    'validatorEngine',v_existing.validator_engine
                 )
            END,
        'counts',jsonb_build_object(
            'configs',v_config_count,
            'groups',v_group_count,
            'eligibleUnits',v_eligible_count,
            'assignedUnits',v_unit_count,
            'errors',jsonb_array_length(v_errors),
            'warnings',jsonb_array_length(v_warnings)
        ),
        'errors',v_errors,
        'warnings',v_warnings
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 4. Dispatcher de preview: conservar individual y agregar team handler
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.previsualizar_validacion_salidas_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_tournament_id uuid;
    v_dispatch jsonb;
    v_handler text;
    v_result jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds
     WHERE id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para validar las salidas de esta ronda.'
            USING ERRCODE='42501';
    END IF;

    v_dispatch:=public._resolver_validador_salida_ronda(
        p_tournament_round_id
    );

    IF NOT COALESCE((v_dispatch->>'supported')::boolean,false) THEN
        RETURN jsonb_build_object(
            'schemaVersion',2,
            'ready',false,
            'alreadyValidated',
                COALESCE((
                    public.obtener_estado_validacion_salidas_ronda(
                        p_tournament_round_id
                    )->>'validated'
                )::boolean,false),
            'errors',jsonb_build_array(jsonb_build_object(
                'code',COALESCE(
                    v_dispatch->>'code',
                    'validacion_salida_no_soportada'
                ),
                'message',COALESCE(
                    v_dispatch->>'message',
                    'La ronda no tiene validador de salidas habilitado.'
                ),
                'detail',v_dispatch
            )),
            'warnings','[]'::jsonb,
            'dispatch',v_dispatch
        );
    END IF;

    v_handler:=v_dispatch->>'validationHandler';

    CASE v_handler
        WHEN 'shotgun_v1' THEN
            v_result:=
                public._previsualizar_validacion_salidas_shotgun_v1(
                    p_tournament_round_id
                );

        WHEN 'tee_times_v1' THEN
            v_result:=
                public._previsualizar_validacion_salidas_tee_times_v1(
                    p_tournament_round_id
                );

        WHEN 'shotgun_team_v1' THEN
            v_result:=
                public._previsualizar_validacion_salidas_shotgun_team_v1(
                    p_tournament_round_id
                );

        ELSE
            RETURN jsonb_build_object(
                'schemaVersion',2,
                'ready',false,
                'alreadyValidated',false,
                'errors',jsonb_build_array(jsonb_build_object(
                    'code','handler_validacion_no_implementado',
                    'message','El motor está registrado, pero su handler de validación no está implementado.',
                    'detail',v_dispatch
                )),
                'warnings','[]'::jsonb,
                'dispatch',v_dispatch
            );
    END CASE;

    RETURN v_result || jsonb_build_object(
        'schemaVersion',2,
        'validationHandler',v_handler,
        'dispatch',v_dispatch
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 5. Dispatcher de contrato: conservar motores existentes + equipo Shotgun
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._construir_contrato_salida_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_engine jsonb;
    v_start_format text;
    v_preparation_engine text;
BEGIN
    v_engine:=public.obtener_motor_salida_ronda(
        p_tournament_round_id
    );

    IF NOT COALESCE((v_engine->>'supported')::boolean,false) THEN
        RAISE EXCEPTION
            'No existe un motor de salida activo para esta combinación de formato, participación y puntuación.'
            USING ERRCODE='0A000',
                  DETAIL=v_engine::text;
    END IF;

    v_start_format:=v_engine->>'startFormat';
    v_preparation_engine:=v_engine #>> '{engine,preparationEngine}';

    IF v_start_format='shotgun'
       AND v_preparation_engine='shotgun_v1'
    THEN
        RETURN public._construir_contrato_salida_shotgun_v2(
            p_tournament_round_id
        );
    END IF;

    IF v_start_format='tee_times'
       AND v_preparation_engine='tee_times_v1'
    THEN
        RETURN public._construir_contrato_salida_tee_times_v1(
            p_tournament_round_id
        );
    END IF;

    IF v_start_format='shotgun'
       AND v_preparation_engine='shotgun_team_v1'
    THEN
        RETURN public._construir_contrato_salida_shotgun_team_v1(
            p_tournament_round_id
        );
    END IF;

    RAISE EXCEPTION
        'El motor de preparación % para formato % todavía no tiene constructor implementado.',
        COALESCE(v_preparation_engine,'NULL'),
        COALESCE(v_start_format,'NULL')
        USING ERRCODE='0A000',
              DETAIL=v_engine::text;
END;
$$;

-- ----------------------------------------------------------------------------
-- 6. Documentación
-- ----------------------------------------------------------------------------

COMMENT ON FUNCTION public._construir_contrato_salida_shotgun_team_v1(uuid)
IS 'Contrato común v2 de salidas Shotgun A-Go-Go. La unidad competitiva es TEAM y tournament_group_teams es la fuente autoritativa.';

COMMENT ON FUNCTION public._previsualizar_validacion_salidas_shotgun_team_v1(uuid)
IS 'Valida salidas Shotgun A-Go-Go por equipo, incluyendo unicidad de asignación y HCP competitivo CURRENT.';

COMMIT;
