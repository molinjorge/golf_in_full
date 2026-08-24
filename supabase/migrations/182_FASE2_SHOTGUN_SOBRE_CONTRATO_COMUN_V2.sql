-- ============================================================================
-- 182_FASE2_SHOTGUN_SOBRE_CONTRATO_COMUN_V2.sql
-- TEE CENTRAL
--
-- OBJETIVO
-- Hacer que el motor Shotgun actual produzca y consuma el contrato común v2,
-- manteniendo el comportamiento funcional de Stroke Play individual + Shotgun.
--
-- PRINCIPIOS
-- - No se implementa Tee Times todavía.
-- - No se altera la lógica de previsualización ni sus reglas.
-- - No se mutan validaciones históricas.
-- - Nuevas validaciones se persisten con start_contract_version = 2.
-- - El snapshot histórico validado pasa a ser el contrato común v2.
-- - Se mantiene compatibilidad con campos legacy Shotgun en tablas normalizadas.
-- - emitir_tarjetas_score_ronda() continúa funcionando sin cambios.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. CONSTRUCTOR ESPECÍFICO SHOTGUN -> CONTRATO COMÚN V2
--
-- Esta función toma el lugar del antiguo constructor legacy como fuente real.
-- El contrato común contiene únicamente un núcleo compartido más metadata
-- específica del formato.
-- ============================================================================
CREATE OR REPLACE FUNCTION public._construir_contrato_salida_shotgun_v2(
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
          ON rs.tournament_round_id = ctx.round_id
         AND rs.activo
        JOIN public.tournament_round_shift_categories sc
          ON sc.tournament_round_shift_id = rs.id
         AND sc.activo
        JOIN public.tournament_shotgun_category_configs cfg
          ON cfg.tournament_round_shift_category_id = sc.id
         AND cfg.activo
        JOIN public.tournament_shotgun_category_holes sh
          ON sh.tournament_shotgun_category_config_id = cfg.id
         AND sh.activo
        JOIN public.tournament_groups g
          ON g.tournament_shotgun_category_hole_id = sh.id
         AND g.tournament_round_shift_id = rs.id
         AND g.activo
        JOIN public.tournament_round_hole_snapshots hole
          ON hole.tournament_round_id = ctx.round_id
         AND hole.source_hole_id = sh.hoyo_id
    ),
    unit_rows AS (
        SELECT
            gr.*,
            gp.tournament_registration_id AS registration_id,
            gp.orden_en_grupo,

            hs.id AS handicap_snapshot_id,
            rhs.id AS round_handicap_snapshot_id,

            hs.player_id,
            hs.player_name,
            hs.registration_folio,
            hs.category_name,

            rhs.tee_id,
            hs.handicap_index,
            rhs.course_handicap,
            rhs.playing_handicap
        FROM group_rows gr
        JOIN public.tournament_group_players gp
          ON gp.tournament_group_id = gr.group_id
        JOIN public.tournament_round_handicap_snapshots rhs
          ON rhs.tournament_round_id = p_tournament_round_id
         AND rhs.tournament_registration_id = gp.tournament_registration_id
        JOIN public.tournament_handicap_snapshots hs
          ON hs.id = rhs.handicap_snapshot_id
        JOIN public.tournament_registrations reg
          ON reg.id = gp.tournament_registration_id
         AND reg.activo
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
                        SELECT min(u.category_name)
                        FROM unit_rows u
                        WHERE u.group_id = gr.group_id
                    ),

                    -- Núcleo común de ubicación/horario.
                    'sourceFormatSlotId', gr.format_slot_id,
                    'sourceHoleId', gr.hoyo_id,
                    'holeNumber', gr.hole_number,
                    'startAt', gr.hora_salida,
                    'startPosition', gr.posicion_salida,

                    'shiftNumber', gr.numero_turno,
                    'shiftTime', gr.shift_time,
                    'groupLabel', gr.etiqueta,
                    'normalSize', gr.tamano_grupo_normal,
                    'maximumSize', gr.tamano_grupo_maximo,

                    'units', COALESCE((
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'unitType', 'registration',
                                'registrationId', u.registration_id,
                                'teamId', NULL,
                                'playerId', u.player_id,
                                'name', u.player_name,
                                'folio', u.registration_folio,
                                'orderInGroup', u.orden_en_grupo,
                                'handicapSnapshotId', u.handicap_snapshot_id,
                                'roundHandicapSnapshotId',
                                    u.round_handicap_snapshot_id,
                                'teeId', u.tee_id,
                                'handicapIndex', u.handicap_index,
                                'courseHandicap', u.course_handicap,
                                'playingHandicap', u.playing_handicap
                            )
                            ORDER BY u.orden_en_grupo, u.registration_id
                        )
                        FROM unit_rows u
                        WHERE u.group_id = gr.group_id
                    ), '[]'::jsonb),

                    -- Todo lo que sólo pertenece a Shotgun queda encapsulado.
                    'formatMetadata', jsonb_build_object(
                        'startFormat', 'shotgun',
                        'sourceShotgunHoleId', gr.format_slot_id,
                        'startPosition', gr.posicion_salida
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
        'schemaVersion', 2,
        'contract', 'tee_central_round_start',
        'contractVersion', 2,

        'preparationEngine', 'shotgun_v1',
        'validationEngine', 'stroke_individual_shotgun_v1',

        'freezeId', ctx.freeze_id,
        'roundConditionSnapshotId', ctx.round_condition_snapshot_id,

        'tournament', jsonb_build_object(
            'id', ctx.tournament_id
        ),

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


-- ============================================================================
-- 02. DISPATCHER DEL CONTRATO COMÚN
--
-- Ahora el contrato común ya NO se construye a partir del snapshot legacy.
-- Resuelve el motor y despacha al constructor específico.
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
    v_start_format text;
    v_preparation_engine text;
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
                  DETAIL = v_engine::text;
    END IF;

    v_start_format := v_engine->>'startFormat';
    v_preparation_engine :=
        v_engine #>> '{engine,preparationEngine}';

    IF v_start_format = 'shotgun'
       AND v_preparation_engine = 'shotgun_v1'
    THEN
        RETURN public._construir_contrato_salida_shotgun_v2(
            p_tournament_round_id
        );
    END IF;

    RAISE EXCEPTION
        'El motor de preparación % para formato % todavía no tiene constructor de contrato implementado.',
        COALESCE(v_preparation_engine, 'NULL'),
        COALESCE(v_start_format, 'NULL')
        USING ERRCODE = '0A000',
              DETAIL = v_engine::text;
END;
$function$;


-- ============================================================================
-- 03. ADAPTADOR COMÚN -> SNAPSHOT LEGACY
--
-- Conservamos la firma antigua porque puede haber consumidores existentes.
-- A partir de ahora, el snapshot legacy se deriva del contrato común y no
-- al revés.
-- ============================================================================
CREATE OR REPLACE FUNCTION public._adaptar_contrato_salida_a_snapshot_legacy(
    p_contract jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $function$
DECLARE
    v_groups jsonb;
BEGIN
    IF p_contract IS NULL
       OR p_contract->>'contract' IS DISTINCT FROM
          'tee_central_round_start'
    THEN
        RAISE EXCEPTION
            'Contrato de salida inválido o ausente.'
            USING ERRCODE = '22023';
    END IF;

    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'sourceGroupId', g->>'sourceGroupId',
                'sourceConfigId', g->>'sourceConfigId',
                'sourceShiftId', g->>'sourceShiftId',
                'sourceShiftCategoryId',
                    g->>'sourceShiftCategoryId',
                'tournamentCategoryId',
                    g->>'tournamentCategoryId',
                'categoryName', g->>'categoryName',

                'sourceShotgunHoleId',
                    COALESCE(
                        g #>> '{formatMetadata,sourceShotgunHoleId}',
                        g->>'sourceFormatSlotId'
                    ),

                'sourceHoleId', g->>'sourceHoleId',
                'holeNumber',
                    NULLIF(g->>'holeNumber','')::integer,
                'startPosition',
                    g->>'startPosition',
                'startAt', g->>'startAt',
                'shiftNumber',
                    NULLIF(g->>'shiftNumber','')::integer,
                'shiftTime', g->>'shiftTime',
                'groupLabel', g->>'groupLabel',
                'normalSize',
                    NULLIF(g->>'normalSize','')::integer,
                'maximumSize',
                    NULLIF(g->>'maximumSize','')::integer,
                'units', COALESCE(g->'units', '[]'::jsonb)
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
          COALESCE(p_contract->'groups', '[]'::jsonb)
      ) x(g);

    RETURN jsonb_build_object(
        'schemaVersion', 1,
        'validatorEngine',
            p_contract->>'validationEngine',
        'freezeId',
            p_contract->>'freezeId',
        'roundConditionSnapshotId',
            p_contract->>'roundConditionSnapshotId',
        'tournament',
            p_contract->'tournament',
        'round',
            p_contract->'round',
        'format',
            p_contract->'format',
        'groups',
            v_groups
    );
END;
$function$;


-- ============================================================================
-- 04. FIRMA LEGACY PRESERVADA
--
-- Cualquier consumidor antiguo recibe exactamente la forma v1 esperada,
-- pero ésta ya nace desde el contrato común v2.
-- ============================================================================
CREATE OR REPLACE FUNCTION public._construir_fotografia_salida_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT public._adaptar_contrato_salida_a_snapshot_legacy(
        public._construir_contrato_salida_ronda(
            p_tournament_round_id
        )
    );
$function$;


-- ============================================================================
-- 05. VALIDAR SALIDAS CON CONTRATO COMÚN V2
--
-- La previsualización continúa siendo la existente para preservar exactamente
-- las reglas actuales. Si ready=true, la fotografía persistida ya es v2.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.validar_salidas_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_admin_id uuid;
    v_preview jsonb;
    v_snapshot jsonb;
    v_validation_id uuid;
    v_version integer;

    v_config_count integer;
    v_group_count integer;
    v_unit_count integer;

    v_inserted_groups integer;
    v_inserted_units integer;

    v_existing uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds
     WHERE id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para validar las salidas de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(
        p_tournament_round_id
    );

    SELECT id
      INTO v_existing
      FROM public.tournament_round_start_validations
     WHERE tournament_round_id = p_tournament_round_id
       AND status = 'validated';

    IF v_existing IS NOT NULL THEN
        RETURN public.obtener_estado_validacion_salidas_ronda(
            p_tournament_round_id
        );
    END IF;

    -- Las reglas de readiness siguen siendo exactamente las actuales.
    v_preview :=
        public.previsualizar_validacion_salidas_ronda(
            p_tournament_round_id
        );

    IF NOT COALESCE(
        (v_preview->>'ready')::boolean,
        false
    ) THEN
        RAISE EXCEPTION
            'Las salidas de la ronda no están listas para validarse.'
            USING ERRCODE = '23514',
                  DETAIL = (v_preview->'errors')::text,
                  HINT =
                      'Corrige los errores indicados y vuelve a revisar las salidas.';
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

    -- Desde Fase 2 la fuente persistida es el contrato común v2.
    v_snapshot :=
        public._construir_contrato_salida_ronda(
            p_tournament_round_id
        );

    IF v_snapshot IS NULL THEN
        RAISE EXCEPTION
            'No fue posible construir el contrato común de salidas.'
            USING ERRCODE = '55000';
    END IF;

    -- Conserva las advertencias aceptadas dentro del snapshot validado.
    v_snapshot := v_snapshot || jsonb_build_object(
        'warnings',
        COALESCE(v_preview->'warnings', '[]'::jsonb)
    );

    SELECT
        count(DISTINCT NULLIF(g->>'sourceConfigId','')::uuid),
        count(*),
        COALESCE(sum(jsonb_array_length(g->'units')), 0)::integer
      INTO
        v_config_count,
        v_group_count,
        v_unit_count
      FROM jsonb_array_elements(
          v_snapshot->'groups'
      ) AS x(g);

    SELECT COALESCE(max(version), 0) + 1
      INTO v_version
      FROM public.tournament_round_start_validations
     WHERE tournament_round_id = p_tournament_round_id;

    INSERT INTO public.tournament_round_start_validations (
        tournament_id,
        tournament_round_id,
        freeze_id,
        round_condition_snapshot_id,

        version,
        status,

        validator_engine,
        start_format,
        participation_type,
        scoring_engine,

        config_count,
        group_count,
        unit_count,

        validation_snapshot,
        content_hash,
        validated_by,

        start_contract_version
    )
    VALUES (
        v_tournament_id,
        p_tournament_round_id,
        (v_snapshot->>'freezeId')::uuid,
        (v_snapshot->>'roundConditionSnapshotId')::uuid,

        v_version,
        'validated',

        v_snapshot->>'validationEngine',
        v_snapshot #>> '{round,startFormat}',
        v_snapshot #>> '{format,participationType}',
        v_snapshot #>> '{format,scoringEngine}',

        v_config_count,
        v_group_count,
        v_unit_count,

        v_snapshot,
        md5(v_snapshot::text),
        v_admin_id,

        2
    )
    RETURNING id INTO v_validation_id;

    -- ------------------------------------------------------------------------
    -- Grupos normalizados.
    -- Conservamos source_shotgun_hole_id para compatibilidad del motor actual,
    -- pero también persistimos el slot genérico y metadata específica.
    -- ------------------------------------------------------------------------
    INSERT INTO public.tournament_round_start_validation_groups (
        validation_id,

        source_group_id,
        source_config_id,
        source_shift_id,
        source_shift_category_id,

        tournament_category_id,
        category_name,

        source_shotgun_hole_id,
        source_format_slot_id,
        source_format_metadata,

        source_hole_id,
        hole_number,
        start_position,
        start_at,

        shift_number,
        shift_time,

        group_label,
        normal_size,
        maximum_size,
        unit_count
    )
    SELECT
        v_validation_id,

        (g->>'sourceGroupId')::uuid,
        (g->>'sourceConfigId')::uuid,
        (g->>'sourceShiftId')::uuid,
        (g->>'sourceShiftCategoryId')::uuid,

        (g->>'tournamentCategoryId')::uuid,
        g->>'categoryName',

        NULLIF(
            g #>> '{formatMetadata,sourceShotgunHoleId}',
            ''
        )::uuid,

        NULLIF(
            g->>'sourceFormatSlotId',
            ''
        )::uuid,

        COALESCE(
            g->'formatMetadata',
            '{}'::jsonb
        ),

        (g->>'sourceHoleId')::uuid,
        (g->>'holeNumber')::integer,
        NULLIF(g->>'startPosition',''),
        (g->>'startAt')::timestamptz,

        (g->>'shiftNumber')::integer,
        (g->>'shiftTime')::time,

        g->>'groupLabel',
        (g->>'normalSize')::integer,
        (g->>'maximumSize')::integer,
        jsonb_array_length(g->'units')
    FROM jsonb_array_elements(
        v_snapshot->'groups'
    ) AS x(g);

    GET DIAGNOSTICS
        v_inserted_groups = ROW_COUNT;

    -- ------------------------------------------------------------------------
    -- Unidades normalizadas.
    -- El contrato ya contempla teamId, aunque el motor Shotgun actual genera
    -- únicamente unitType=registration.
    -- ------------------------------------------------------------------------
    INSERT INTO public.tournament_round_start_validation_units (
        validation_id,
        validation_group_id,
        unit_type,

        tournament_registration_id,
        tournament_team_id,
        player_id,

        tournament_category_id,
        unit_name,
        unit_folio,
        order_in_group,

        handicap_snapshot_id,
        round_handicap_snapshot_id
    )
    SELECT
        v_validation_id,
        vg.id,
        u->>'unitType',

        NULLIF(u->>'registrationId','')::uuid,
        NULLIF(u->>'teamId','')::uuid,
        NULLIF(u->>'playerId','')::uuid,

        vg.tournament_category_id,
        u->>'name',
        u->>'folio',
        (u->>'orderInGroup')::smallint,

        NULLIF(u->>'handicapSnapshotId','')::uuid,
        NULLIF(u->>'roundHandicapSnapshotId','')::uuid

    FROM jsonb_array_elements(
        v_snapshot->'groups'
    ) AS x(g)

    JOIN public.tournament_round_start_validation_groups vg
      ON vg.validation_id = v_validation_id
     AND vg.source_group_id =
         (g->>'sourceGroupId')::uuid

    CROSS JOIN LATERAL
        jsonb_array_elements(g->'units') AS y(u);

    GET DIAGNOSTICS
        v_inserted_units = ROW_COUNT;

    IF v_inserted_groups <> v_group_count
       OR v_inserted_units <> v_unit_count
    THEN
        RAISE EXCEPTION
            'La validación quedó incompleta y fue revertida automáticamente.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'grupos=%s/%s; unidades=%s/%s',
                      v_inserted_groups,
                      v_group_count,
                      v_inserted_units,
                      v_unit_count
                  );
    END IF;

    RETURN public.obtener_estado_validacion_salidas_ronda(
        p_tournament_round_id
    );
END;
$function$;


-- ============================================================================
-- 06. PRIVILEGIOS HELPERS NUEVOS
-- ============================================================================
REVOKE ALL
ON FUNCTION public._construir_contrato_salida_shotgun_v2(uuid)
FROM PUBLIC, anon, authenticated;

REVOKE ALL
ON FUNCTION public._adaptar_contrato_salida_a_snapshot_legacy(jsonb)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._construir_contrato_salida_shotgun_v2(uuid)
TO service_role;

GRANT EXECUTE
ON FUNCTION public._adaptar_contrato_salida_a_snapshot_legacy(jsonb)
TO service_role;


COMMIT;
