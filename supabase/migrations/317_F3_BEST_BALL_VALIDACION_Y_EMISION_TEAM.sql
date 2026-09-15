-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 317 - BEST BALL F3
-- Validacion Shotgun TEAM + emision oficial de tarjeta TEAM Best Ball
--
-- ALCANCE:
--   * Activa Best Ball SOLO cuando ya existen sus handlers propios.
--   * Reutiliza la infraestructura fisica Shotgun TEAM ya existente.
--   * NO reutiliza HCP TEAM de A-Go-Go.
--   * NO inicializa captura de scores.
--   * NO modifica tablas de scores Stroke/Stableford/A-Go-Go.
--   * Mantiene A-Go-Go en sus funciones internas actuales; solo agrega ramas
--     explicitas en dispatchers comunes.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 0. Precondiciones estrictas de F1/F2
-- --------------------------------------------------------------------------
DO $block$
DECLARE
    v_n integer;
BEGIN
    SELECT count(*) INTO v_n
    FROM public.tournament_start_engine_registry r
    WHERE r.start_format::text='shotgun'
      AND r.participation_type='equipo'
      AND r.scoring_engine='best_ball'
      AND r.preparation_engine='shotgun_team_v1'
      AND r.validation_engine='best_ball_team_shotgun_v1'
      AND r.contract_version=2
      AND r.activo=false
      AND r.supports_start_validation=false
      AND r.start_validation_handler IS NULL
      AND r.supports_scorecard_emission=false
      AND r.scorecard_unit_type IS NULL
      AND r.scorecard_emission_engine IS NULL;

    IF v_n<>1 THEN
        RAISE EXCEPTION
            'Migracion 317 abortada: el registro reservado Best Ball de F1 no coincide con el estado esperado.'
            USING ERRCODE='55000';
    END IF;

    IF to_regclass('public.tournament_best_ball_scorecard_snapshots') IS NULL
       OR to_regclass('public.tournament_best_ball_scorecard_members') IS NULL
    THEN
        RAISE EXCEPTION
            'Migracion 317 abortada: falta infraestructura Best Ball de F2.'
            USING ERRCODE='55000';
    END IF;
END;
$block$;

-- --------------------------------------------------------------------------
-- 1. Validador propio Best Ball Shotgun TEAM
--    Misma estructura fisica de grupos TEAM que A-Go-Go, pero SIN HCP TEAM.
--    Best Ball exige:
--      * modalidad congelada equipo + best_ball;
--      * cada equipo activo asignado exactamente una vez;
--      * 2 a 5 integrantes activos por equipo;
--      * todos los integrantes con HCP individual congelado de ESA ronda;
--      * ninguna inscripcion activa queda fuera de equipo activo.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._previsualizar_validacion_salidas_best_ball_shotgun_v1(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
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
        COALESCE(tr.tournament_format_id,t.tournament_format_id) AS live_format_id
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
        RAISE EXCEPTION 'La ronda indicada no existe.' USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_ctx.tournament_id) THEN
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
            'message','La ronda esta inactiva.'
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
            'message','Best Ball TEAM requiere salida Shotgun en esta fase.'
        ));
    END IF;

    IF COALESCE(v_ctx.participation_type,'') <> 'equipo'
       OR COALESCE(v_ctx.scoring_engine,'') <> 'best_ball'
    THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','modalidad_no_soportada',
            'message','Este validador corresponde unicamente a Best Ball por equipos.'
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
      ON sc.id=cfg.tournament_round_shift_category_id AND sc.activo
    JOIN public.tournament_round_shifts rs
      ON rs.id=sc.tournament_round_shift_id AND rs.activo
    WHERE rs.tournament_round_id=p_tournament_round_id
      AND cfg.activo;

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
          ON g.id=gt.tournament_group_id AND g.activo
        JOIN public.tournament_round_shifts rs
          ON rs.id=g.tournament_round_shift_id AND rs.activo
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
                '%s equipo(s) activos no estan asignados exactamente una vez.',
                v_n
            )
        ));
    END IF;

    -- No debe haber jugadores como unidad competitiva en grupos TEAM.
    SELECT count(*) INTO v_n
    FROM public.tournament_group_players gp
    JOIN public.tournament_groups g ON g.id=gp.tournament_group_id AND g.activo
    JOIN public.tournament_round_shifts rs
      ON rs.id=g.tournament_round_shift_id AND rs.activo
    WHERE rs.tournament_round_id=p_tournament_round_id;

    IF v_n>0 THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','unidades_individuales_en_modalidad_equipo',
            'message',format(
                '%s asignacion(es) individuales existen en una ronda Best Ball TEAM.',
                v_n
            )
        ));
    END IF;

    -- Asignaciones TEAM deben apuntar a equipos activos del torneo.
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
                '%s asignacion(es) apuntan a equipos inexistentes, inactivos o de otro torneo.',
                v_n
            )
        ));
    END IF;

    -- Categoria del equipo debe coincidir con categoria del grupo.
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
                '%s equipo(s) estan asignados a un grupo de otra categoria.',
                v_n
            )
        ));
    END IF;

    -- Best Ball F3: cada equipo debe tener 2..5 integrantes activos.
    SELECT count(*) INTO v_n
    FROM (
        SELECT tt.id
        FROM public.tournament_teams tt
        LEFT JOIN public.tournament_registrations reg
          ON reg.tournament_team_id=tt.id
         AND reg.tournament_id=v_ctx.tournament_id
         AND reg.activo=true
        WHERE tt.tournament_id=v_ctx.tournament_id
          AND tt.activo=true
        GROUP BY tt.id
        HAVING count(reg.id) NOT BETWEEN 2 AND 5
    ) invalid_teams;

    IF v_n>0 THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','tamano_equipo_best_ball_invalido',
            'message',format(
                '%s equipo(s) no tienen entre 2 y 5 integrantes activos.',
                v_n
            )
        ));
    END IF;

    -- Toda inscripcion activa debe pertenecer a un equipo activo del torneo.
    SELECT count(*) INTO v_n
    FROM public.tournament_registrations reg
    LEFT JOIN public.tournament_teams tt
      ON tt.id=reg.tournament_team_id
     AND tt.tournament_id=v_ctx.tournament_id
     AND tt.activo=true
    WHERE reg.tournament_id=v_ctx.tournament_id
      AND reg.activo=true
      AND tt.id IS NULL;

    IF v_n>0 THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','inscripciones_sin_equipo_best_ball',
            'message',format(
                '%s inscripcion(es) activas no pertenecen a un equipo activo.',
                v_n
            )
        ));
    END IF;

    -- Cada integrante activo debe tener HCP individual congelado de ESTA ronda.
    SELECT count(*) INTO v_n
    FROM public.tournament_registrations reg
    JOIN public.tournament_teams tt
      ON tt.id=reg.tournament_team_id
     AND tt.tournament_id=v_ctx.tournament_id
     AND tt.activo=true
    LEFT JOIN public.tournament_round_handicap_snapshots rhs
      ON rhs.round_condition_snapshot_id=v_ctx.round_condition_snapshot_id
     AND rhs.tournament_round_id=p_tournament_round_id
     AND rhs.tournament_registration_id=reg.id
     AND rhs.player_id=reg.player_id
    WHERE reg.tournament_id=v_ctx.tournament_id
      AND reg.activo=true
      AND rhs.id IS NULL;

    IF v_n>0 THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','hcp_individual_ronda_faltante',
            'message',format(
                '%s integrante(s) Best Ball no tienen HCP individual congelado para esta ronda.',
                v_n
            )
        ));
    END IF;

    -- Grupos activos no pueden quedar vacios.
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

    -- Maximo de equipos por grupo: se conserva la regla fisica Shotgun TEAM.
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
          ON gt.tournament_group_id=g.id AND gt.activo
        WHERE rs.tournament_round_id=p_tournament_round_id
          AND g.activo
        GROUP BY g.id,cfg.tamano_grupo_maximo
        HAVING count(gt.id)>cfg.tamano_grupo_maximo
    ) x;

    IF v_n>0 THEN
        v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
            'code','grupo_excede_maximo',
            'message',format('%s grupo(s) exceden el maximo de equipos.',v_n)
        ));
    END IF;

    -- Orden TEAM interno unico.
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
        'validatorEngine','best_ball_team_shotgun_v1',
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
$function$;

-- --------------------------------------------------------------------------
-- 2. Constructor propio del contrato Best Ball Shotgun TEAM
--    Congela TEAM como unidad de salida; NO incrusta HCP TEAM.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._construir_contrato_salida_best_ball_shotgun_v1(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
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
      ON f.tournament_id=tr.tournament_id
    JOIN public.tournament_round_condition_snapshots rcs
      ON rcs.freeze_id=f.id
     AND rcs.tournament_round_id=tr.id
    WHERE tr.id=p_tournament_round_id
      AND rcs.participation_type='equipo'
      AND rcs.scoring_engine='best_ball'
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
      ON rs.tournament_round_id=ctx.round_id AND rs.activo
    JOIN public.tournament_round_shift_categories sc
      ON sc.tournament_round_shift_id=rs.id AND sc.activo
    JOIN public.tournament_shotgun_category_configs cfg
      ON cfg.tournament_round_shift_category_id=sc.id AND cfg.activo
    JOIN public.tournament_shotgun_category_holes sh
      ON sh.tournament_shotgun_category_config_id=cfg.id AND sh.activo
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
        tt.tournament_category_id AS team_category_id
    FROM group_rows gr
    JOIN public.tournament_group_teams gt
      ON gt.tournament_group_id=gr.group_id AND gt.activo=true
    JOIN public.tournament_teams tt
      ON tt.id=gt.tournament_team_id AND tt.activo=true
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
                            'roundHandicapSnapshotId',NULL
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
            ORDER BY gr.numero_turno,gr.hole_number,gr.posicion_salida,gr.group_id
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
    'validationEngine','best_ball_team_shotgun_v1',
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
$function$;

-- --------------------------------------------------------------------------
-- 3. Dispatcher comun de constructor: rama Best Ball explicita.
--    La rama A-Go-Go existente NO cambia internamente.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._construir_contrato_salida_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_engine jsonb;
    v_start_format text;
    v_preparation_engine text;
    v_scoring_engine text;
BEGIN
    v_engine:=public.obtener_motor_salida_ronda(p_tournament_round_id);

    IF NOT COALESCE((v_engine->>'supported')::boolean,false) THEN
        RAISE EXCEPTION
            'No existe un motor de salida activo para esta combinacion de formato, participacion y puntuacion.'
            USING ERRCODE='0A000', DETAIL=v_engine::text;
    END IF;

    v_start_format:=v_engine->>'startFormat';
    v_preparation_engine:=v_engine #>> '{engine,preparationEngine}';
    v_scoring_engine:=v_engine #>> '{format,scoringEngine}';

    IF v_start_format='shotgun'
       AND v_preparation_engine='shotgun_v1'
    THEN
        RETURN public._construir_contrato_salida_shotgun_v2(p_tournament_round_id);
    END IF;

    IF v_start_format='tee_times'
       AND v_preparation_engine='tee_times_v1'
    THEN
        RETURN public._construir_contrato_salida_tee_times_v1(p_tournament_round_id);
    END IF;

    IF v_start_format='shotgun'
       AND v_preparation_engine='shotgun_team_v1'
       AND v_scoring_engine='best_ball'
    THEN
        RETURN public._construir_contrato_salida_best_ball_shotgun_v1(
            p_tournament_round_id
        );
    END IF;

    IF v_start_format='shotgun'
       AND v_preparation_engine='shotgun_team_v1'
       AND v_scoring_engine='team_stroke'
    THEN
        RETURN public._construir_contrato_salida_shotgun_team_v1(
            p_tournament_round_id
        );
    END IF;

    RAISE EXCEPTION
        'El motor de preparacion % para formato % y scoring % todavia no tiene constructor implementado.',
        COALESCE(v_preparation_engine,'NULL'),
        COALESCE(v_start_format,'NULL'),
        COALESCE(v_scoring_engine,'NULL')
        USING ERRCODE='0A000', DETAIL=v_engine::text;
END;
$function$;

-- --------------------------------------------------------------------------
-- 4. Dispatcher comun de previsualizacion: agrega handler Best Ball.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.previsualizar_validacion_salidas_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_dispatch jsonb;
    v_handler text;
    v_result jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT tournament_id INTO v_tournament_id
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

    v_dispatch:=public._resolver_validador_salida_ronda(p_tournament_round_id);

    IF NOT COALESCE((v_dispatch->>'supported')::boolean,false) THEN
        RETURN jsonb_build_object(
            'schemaVersion',2,
            'ready',false,
            'alreadyValidated',COALESCE((
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
            v_result:=public._previsualizar_validacion_salidas_shotgun_v1(
                p_tournament_round_id
            );
        WHEN 'tee_times_v1' THEN
            v_result:=public._previsualizar_validacion_salidas_tee_times_v1(
                p_tournament_round_id
            );
        WHEN 'shotgun_team_v1' THEN
            v_result:=public._previsualizar_validacion_salidas_shotgun_team_v1(
                p_tournament_round_id
            );
        WHEN 'shotgun_best_ball_v1' THEN
            v_result:=public._previsualizar_validacion_salidas_best_ball_shotgun_v1(
                p_tournament_round_id
            );
        ELSE
            RETURN jsonb_build_object(
                'schemaVersion',2,
                'ready',false,
                'alreadyValidated',false,
                'errors',jsonb_build_array(jsonb_build_object(
                    'code','handler_validacion_no_implementado',
                    'message','El motor esta registrado, pero su handler de validacion no esta implementado.',
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
$function$;

-- --------------------------------------------------------------------------
-- 5. Emisor propio Best Ball TEAM.
--    Emision + tarjetas + snapshot + integrantes = UNA transaccion.
--    NO inicializa scores: eso corresponde a F4.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._emitir_tarjetas_best_ball_ronda_317(
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
    v_validation public.tournament_round_start_validations%ROWTYPE;
    v_emission_id uuid;
    v_inserted integer:=0;
    v_bad integer:=0;
    v_card_count integer:=0;
    v_snapshot_count integer:=0;
    v_expected_members integer:=0;
    v_inserted_members integer:=0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT tournament_id,numero_ronda
      INTO v_tournament_id,v_round_number
      FROM public.tournament_rounds
     WHERE id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.' USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para emitir tarjetas Best Ball.'
            USING ERRCODE='42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(p_tournament_round_id);

    IF public._ronda_tiene_tarjetas_emitidas(p_tournament_round_id) THEN
        RETURN public.obtener_estado_emision_tarjetas_ronda(p_tournament_round_id);
    END IF;

    SELECT au.id INTO v_admin_id
    FROM public.admin_users au
    WHERE au.auth_user_id=auth.uid() AND au.activo
    ORDER BY au.id
    LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No existe administrador activo asociado.';
    END IF;

    SELECT * INTO v_validation
    FROM public.tournament_round_start_validations
    WHERE tournament_round_id=p_tournament_round_id
      AND status='validated'
    ORDER BY version DESC
    LIMIT 1
    FOR UPDATE;

    IF v_validation.id IS NULL THEN
        RAISE EXCEPTION
            'Las salidas deben estar validadas antes de emitir.'
            USING ERRCODE='23514';
    END IF;

    IF v_validation.start_format IS DISTINCT FROM 'shotgun'
       OR v_validation.participation_type IS DISTINCT FROM 'equipo'
       OR v_validation.scoring_engine IS DISTINCT FROM 'best_ball'
       OR v_validation.validator_engine IS DISTINCT FROM 'best_ball_team_shotgun_v1'
    THEN
        RAISE EXCEPTION
            'Esta emision corresponde unicamente a Best Ball Shotgun TEAM.'
            USING ERRCODE='0A000';
    END IF;

    SELECT public._contar_unidades_invalidas_emision_tarjetas(
        v_validation.id,'team'
    ) INTO v_bad;

    IF v_bad>0 THEN
        RAISE EXCEPTION
            'La validacion contiene unidades incompatibles con tarjeta TEAM.'
            USING ERRCODE='23514';
    END IF;

    -- Blindaje previo: 2..5 integrantes activos por cada TEAM validado.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_round_start_validation_units u
        LEFT JOIN LATERAL (
            SELECT count(*)::integer AS n
            FROM public.tournament_registrations reg
            WHERE reg.tournament_id=v_tournament_id
              AND reg.tournament_team_id=u.tournament_team_id
              AND reg.activo=true
        ) x ON true
        WHERE u.validation_id=v_validation.id
          AND u.unit_type='team'
          AND x.n NOT BETWEEN 2 AND 5
    ) THEN
        RAISE EXCEPTION
            'Uno o mas equipos Best Ball ya no tienen entre 2 y 5 integrantes activos. Revalida antes de emitir.'
            USING ERRCODE='23514';
    END IF;

    -- Blindaje previo: HCP individual congelado exacto para todos los miembros.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_round_start_validation_units u
        JOIN public.tournament_registrations reg
          ON reg.tournament_id=v_tournament_id
         AND reg.tournament_team_id=u.tournament_team_id
         AND reg.activo=true
        LEFT JOIN public.tournament_round_handicap_snapshots rhs
          ON rhs.round_condition_snapshot_id=v_validation.round_condition_snapshot_id
         AND rhs.tournament_round_id=p_tournament_round_id
         AND rhs.tournament_registration_id=reg.id
         AND rhs.player_id=reg.player_id
        WHERE u.validation_id=v_validation.id
          AND u.unit_type='team'
          AND rhs.id IS NULL
    ) THEN
        RAISE EXCEPTION
            'Falta HCP individual congelado de uno o mas integrantes Best Ball.'
            USING ERRCODE='23514';
    END IF;

    INSERT INTO public.tournament_score_card_emissions(
        tournament_id,tournament_round_id,validation_id,validation_version,
        status,card_count,issued_by
    )
    VALUES(
        v_tournament_id,p_tournament_round_id,v_validation.id,
        v_validation.version,'issued',v_validation.unit_count,v_admin_id
    )
    RETURNING id INTO v_emission_id;

    WITH ordered_units AS (
        SELECT
            u.id AS validation_unit_id,
            u.validation_group_id,
            u.tournament_team_id,
            u.tournament_category_id,
            row_number() OVER(
                ORDER BY
                    g.shift_number,
                    g.hole_number,
                    g.start_position,
                    u.order_in_group,
                    u.id
            )::integer AS card_number
        FROM public.tournament_round_start_validation_units u
        JOIN public.tournament_round_start_validation_groups g
          ON g.id=u.validation_group_id
         AND g.validation_id=u.validation_id
        WHERE u.validation_id=v_validation.id
          AND u.unit_type='team'
    )
    INSERT INTO public.tournament_score_cards(
        emission_id,tournament_id,tournament_round_id,
        validation_id,validation_version,
        validation_group_id,validation_unit_id,
        unit_type,tournament_registration_id,tournament_team_id,player_id,
        tournament_category_id,card_number,card_folio,status
    )
    SELECT
        v_emission_id,v_tournament_id,p_tournament_round_id,
        v_validation.id,v_validation.version,
        ou.validation_group_id,ou.validation_unit_id,
        'team',NULL,ou.tournament_team_id,NULL,
        ou.tournament_category_id,ou.card_number,
        'R'||lpad(v_round_number::text,2,'0')||
        '-V'||lpad(v_validation.version::text,2,'0')||
        '-'||lpad(ou.card_number::text,4,'0'),
        'issued'
    FROM ordered_units ou
    ORDER BY ou.card_number;

    GET DIAGNOSTICS v_inserted=ROW_COUNT;

    IF v_inserted<>v_validation.unit_count THEN
        RAISE EXCEPTION
            'La emision Best Ball TEAM quedo incompleta y fue revertida.'
            USING ERRCODE='55000';
    END IF;

    SELECT count(*) INTO v_card_count
    FROM public.tournament_score_cards sc
    WHERE sc.emission_id=v_emission_id
      AND sc.status='issued'
      AND sc.unit_type='team';

    INSERT INTO public.tournament_best_ball_scorecard_snapshots(
        score_card_id,tournament_id,tournament_round_id,tournament_team_id,
        team_name
    )
    SELECT
        sc.id,sc.tournament_id,sc.tournament_round_id,sc.tournament_team_id,
        tt.nombre_equipo
    FROM public.tournament_score_cards sc
    JOIN public.tournament_teams tt
      ON tt.id=sc.tournament_team_id
     AND tt.tournament_id=sc.tournament_id
     AND tt.activo=true
    WHERE sc.emission_id=v_emission_id
      AND sc.status='issued'
      AND sc.unit_type='team';

    GET DIAGNOSTICS v_snapshot_count=ROW_COUNT;

    IF v_snapshot_count<>v_card_count THEN
        RAISE EXCEPTION
            'El snapshot Best Ball quedo incompleto y toda la emision fue revertida.'
            USING ERRCODE='55000';
    END IF;

    SELECT count(*)::integer INTO v_expected_members
    FROM public.tournament_score_cards sc
    JOIN public.tournament_registrations reg
      ON reg.tournament_id=sc.tournament_id
     AND reg.tournament_team_id=sc.tournament_team_id
     AND reg.activo=true
    WHERE sc.emission_id=v_emission_id
      AND sc.status='issued'
      AND sc.unit_type='team';

    WITH member_source AS (
        SELECT
            ss.id AS snapshot_id,
            reg.id AS registration_id,
            reg.player_id,
            rhs.id AS round_handicap_snapshot_id,
            row_number() OVER(
                PARTITION BY ss.id
                ORDER BY
                    CASE WHEN reg.player_id=tt.captain_player_id THEN 0 ELSE 1 END,
                    p.apellidos,
                    p.nombres,
                    reg.id
            )::smallint AS member_order
        FROM public.tournament_best_ball_scorecard_snapshots ss
        JOIN public.tournament_score_cards sc
          ON sc.id=ss.score_card_id
         AND sc.emission_id=v_emission_id
        JOIN public.tournament_teams tt
          ON tt.id=ss.tournament_team_id
        JOIN public.tournament_registrations reg
          ON reg.tournament_id=ss.tournament_id
         AND reg.tournament_team_id=ss.tournament_team_id
         AND reg.activo=true
        JOIN public.players p
          ON p.id=reg.player_id
         AND p.activo=true
        JOIN public.tournament_round_handicap_snapshots rhs
          ON rhs.round_condition_snapshot_id=v_validation.round_condition_snapshot_id
         AND rhs.tournament_round_id=ss.tournament_round_id
         AND rhs.tournament_registration_id=reg.id
         AND rhs.player_id=reg.player_id
    )
    INSERT INTO public.tournament_best_ball_scorecard_members(
        best_ball_scorecard_snapshot_id,
        tournament_registration_id,
        player_id,
        round_handicap_snapshot_id,
        member_order
    )
    SELECT
        snapshot_id,registration_id,player_id,
        round_handicap_snapshot_id,member_order
    FROM member_source
    ORDER BY snapshot_id,member_order;

    GET DIAGNOSTICS v_inserted_members=ROW_COUNT;

    IF v_inserted_members<>v_expected_members THEN
        RAISE EXCEPTION
            'Los integrantes Best Ball quedaron incompletos y toda la emision fue revertida.'
            USING ERRCODE='55000',
                  DETAIL=format(
                      'integrantes_insertados=%s; integrantes_esperados=%s',
                      v_inserted_members,v_expected_members
                  );
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_best_ball_scorecard_snapshots ss
        LEFT JOIN public.tournament_best_ball_scorecard_members m
          ON m.best_ball_scorecard_snapshot_id=ss.id
        JOIN public.tournament_score_cards sc
          ON sc.id=ss.score_card_id
        WHERE sc.emission_id=v_emission_id
        GROUP BY ss.id
        HAVING count(m.id) NOT BETWEEN 2 AND 5
    ) THEN
        RAISE EXCEPTION
            'Una tarjeta Best Ball no quedo con 2 a 5 integrantes; toda la emision fue revertida.'
            USING ERRCODE='55000';
    END IF;

    -- F3 termina aqui deliberadamente: NO inicializar captura de scores.
    RETURN public.obtener_estado_emision_tarjetas_ronda(p_tournament_round_id);
END;
$function$;

-- --------------------------------------------------------------------------
-- 6. Dispatcher comun de emision: discrimina por emission engine.
--    A-Go-Go conserva exactamente su emisor actual.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.emitir_tarjetas_score_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_capability jsonb;
    v_emission_engine text;
BEGIN
    v_capability:=public._resolver_capacidad_emision_tarjetas_ronda(
        p_tournament_round_id
    );

    IF NOT COALESCE((v_capability->>'supported')::boolean,false) THEN
        -- Preserva comportamiento historico para motores individuales.
        RETURN public._emitir_tarjetas_score_ronda_individual_208(
            p_tournament_round_id
        );
    END IF;

    v_emission_engine:=v_capability->>'scorecardEmissionEngine';

    IF v_emission_engine='official_scorecard_best_ball_team_v1' THEN
        RETURN public._emitir_tarjetas_best_ball_ronda_317(
            p_tournament_round_id
        );
    END IF;

    IF v_emission_engine='official_scorecard_team_v1'
       AND v_capability->>'unitType'='team'
    THEN
        RETURN public._emitir_tarjetas_equipo_a_gogo_ronda_246(
            p_tournament_round_id
        );
    END IF;

    RETURN public._emitir_tarjetas_score_ronda_individual_208(
        p_tournament_round_id
    );
END;
$function$;

-- --------------------------------------------------------------------------
-- 7. Activar Best Ball SOLO ahora que sus handlers existen.
-- --------------------------------------------------------------------------
UPDATE public.tournament_start_engine_registry
   SET activo=true,
       supports_start_validation=true,
       start_validation_handler='shotgun_best_ball_v1',
       supports_scorecard_emission=true,
       scorecard_unit_type='team',
       scorecard_emission_engine='official_scorecard_best_ball_team_v1',
       updated_at=now()
 WHERE start_format::text='shotgun'
   AND participation_type='equipo'
   AND scoring_engine='best_ball'
   AND preparation_engine='shotgun_team_v1'
   AND validation_engine='best_ball_team_shotgun_v1'
   AND contract_version=2;

DO $block$
DECLARE
    v_n integer;
BEGIN
    SELECT count(*) INTO v_n
    FROM public.tournament_start_engine_registry r
    WHERE r.start_format::text='shotgun'
      AND r.participation_type='equipo'
      AND r.scoring_engine='best_ball'
      AND r.preparation_engine='shotgun_team_v1'
      AND r.validation_engine='best_ball_team_shotgun_v1'
      AND r.contract_version=2
      AND r.activo=true
      AND r.supports_start_validation=true
      AND r.start_validation_handler='shotgun_best_ball_v1'
      AND r.supports_scorecard_emission=true
      AND r.scorecard_unit_type='team'
      AND r.scorecard_emission_engine='official_scorecard_best_ball_team_v1';

    IF v_n<>1 THEN
        RAISE EXCEPTION
            'Migracion 317 abortada: Best Ball no quedo activado con el contrato F3 esperado.'
            USING ERRCODE='55000';
    END IF;
END;
$block$;

COMMIT;
