BEGIN;

-- ============================================================================
-- MIGRACIÓN 141
-- CORRECCIÓN DEL VALIDADOR DE SALIDAS POR RONDA
--
-- Corrige dos problemas detectados después de la Migración 140:
--
-- 1. Una categoría asignada a un turno pero SIN participantes elegibles
--    congelados no debe requerir configuración Shotgun. La Migración 140
--    exigía configuración a todas las categorías activas del turno y por eso
--    categorías sin inscripciones bloqueaban indebidamente la validación.
--
-- 2. Corrige textos con mojibake UTF-8 (por ejemplo "categorÃ­a") en las RPC
--    de revisión y validación.
--
-- NO modifica:
-- - tablas;
-- - RLS;
-- - triggers;
-- - fotografías históricas;
-- - lógica de configuración/hoyos/grupos para categorías que sí tienen
--   participantes elegibles;
-- - emisión de tarjetas, PDF, folios o QR.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Preview de validación.
--    Cambio funcional puntual:
--    categoria_turno_sin_configuracion sólo considera asignaciones de categoría
--    que tengan al menos un participante elegible congelado en esa ronda.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.previsualizar_validacion_salidas_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
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
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    SELECT tr.id AS round_id,
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
           COALESCE(tr.tournament_format_id, t.tournament_format_id) AS live_format_id
      INTO v_ctx
      FROM public.tournament_rounds tr
      JOIN public.tournaments t ON t.id = tr.tournament_id
      LEFT JOIN public.tournament_condition_freezes f
        ON f.tournament_id = tr.tournament_id
      LEFT JOIN public.tournament_round_condition_snapshots rcs
        ON rcs.freeze_id = f.id
       AND rcs.tournament_round_id = tr.id
     WHERE tr.id = p_tournament_round_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La ronda indicada no existe.' USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_ctx.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para validar las salidas de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    SELECT v.id, v.version, v.validated_at, v.validated_by,
           v.content_hash, v.validator_engine
      INTO v_existing
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_round_id = p_tournament_round_id
       AND v.status = 'validated';

    IF NOT v_ctx.round_active THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'ronda_inactiva',
            'message', 'La ronda está inactiva y no puede validarse.'
        ));
    END IF;

    IF v_ctx.freeze_id IS NULL THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'torneo_no_congelado',
            'message', 'Las condiciones y hándicaps del torneo deben congelarse antes de validar salidas.'
        ));
    ELSIF v_ctx.round_condition_snapshot_id IS NULL THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'ronda_sin_snapshot',
            'message', 'La ronda no forma parte de las condiciones congeladas del torneo.'
        ));
    END IF;

    IF COALESCE(v_ctx.live_start_format, '') <> 'shotgun' THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'ronda_no_shotgun',
            'message', 'El primer validador habilitado requiere salida Shotgun.'
        ));
    END IF;

    IF COALESCE(v_ctx.participation_type, '') <> 'individual'
       OR COALESCE(v_ctx.scoring_engine, '') <> 'stroke' THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'modalidad_no_soportada',
            'message', 'Esta versión valida únicamente Stroke Play individual con salida Shotgun.',
            'detail', jsonb_build_object(
                'participationType', v_ctx.participation_type,
                'scoringEngine', v_ctx.scoring_engine
            )
        ));
    END IF;

    IF v_ctx.frozen_format_id IS DISTINCT FROM v_ctx.live_format_id THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'formato_distinto_del_congelado',
            'message', 'El formato efectivo vivo de la ronda no coincide con el formato congelado.'
        ));
    END IF;

    IF v_ctx.tournament_status NOT IN ('inscripcion_cerrada', 'en_curso') THEN
        v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
            'code', 'estatus_torneo_no_operativo',
            'message', format(
                'El torneo tiene estatus %s; normalmente las salidas se validan con inscripciones cerradas.',
                v_ctx.tournament_status
            )
        ));
    END IF;

    IF jsonb_array_length(COALESCE(v_ctx.freeze_warnings, '[]'::jsonb)) > 0 THEN
        v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
            'code', 'congelamiento_con_advertencias',
            'message', 'El congelamiento del torneo contiene advertencias que deben revisarse.',
            'detail', v_ctx.freeze_warnings
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_round_hole_snapshots rhs
     WHERE rhs.tournament_round_id = p_tournament_round_id;
    IF v_ctx.freeze_id IS NOT NULL AND v_n <> 18 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'snapshot_hoyos_incompleto',
            'message', format('La ronda tiene %s hoyos congelados; se requieren 18.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_config_count
      FROM public.tournament_shotgun_category_configs cfg
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = sc.tournament_round_shift_id AND rs.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND cfg.activo;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_round_shifts rs
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND rs.activo;
    IF v_n = 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'sin_turnos_activos',
            'message', 'La ronda no tiene turnos activos.'
        ));
    END IF;

    -- MIGRACIÓN 141:
    -- Sólo se exige configuración Shotgun a una categoría-turno si existe al
    -- menos un participante elegible congelado de esa categoría en la ronda.
    -- Una categoría activa sin inscripciones elegibles no bloquea la validación.
    SELECT count(*)
      INTO v_n
      FROM public.tournament_round_shift_categories sc
      JOIN public.tournament_round_shifts rs
        ON rs.id = sc.tournament_round_shift_id AND rs.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND sc.activo
       AND EXISTS (
           SELECT 1
           FROM public.tournament_handicap_snapshots hs
           JOIN public.tournament_round_handicap_snapshots rhs
             ON rhs.handicap_snapshot_id = hs.id
            AND rhs.tournament_round_id = p_tournament_round_id
           JOIN public.tournament_registrations reg
             ON reg.id = hs.tournament_registration_id
            AND reg.activo
           WHERE hs.freeze_id = v_ctx.freeze_id
             AND hs.tournament_category_id = sc.tournament_category_id
       )
       AND NOT EXISTS (
           SELECT 1
           FROM public.tournament_shotgun_category_configs cfg
           WHERE cfg.tournament_round_shift_category_id = sc.id
             AND cfg.activo
       );
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'categoria_turno_sin_configuracion',
            'message', format('%s asignación(es) de categoría a turno con participantes elegibles no tienen configuración Shotgun activa.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_shotgun_category_configs cfg
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = sc.tournament_round_shift_id AND rs.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND cfg.activo
       AND NOT EXISTS (
           SELECT 1
           FROM public.tournament_shotgun_category_holes sh
           WHERE sh.tournament_shotgun_category_config_id = cfg.id
             AND sh.activo
       );
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'configuracion_sin_hoyos',
            'message', format('%s configuración(es) Shotgun activas no tienen hoyos habilitados.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_eligible_count
      FROM public.tournament_round_handicap_snapshots rhs
      JOIN public.tournament_registrations reg
        ON reg.id = rhs.tournament_registration_id AND reg.activo
     WHERE rhs.tournament_round_id = p_tournament_round_id;
    IF v_eligible_count = 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'sin_participantes_elegibles',
            'message', 'La ronda no tiene participantes activos con hándicap congelado.'
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM (
          SELECT hs.tournament_registration_id
          FROM public.tournament_handicap_snapshots hs
          JOIN public.tournament_round_handicap_snapshots rhs
            ON rhs.handicap_snapshot_id = hs.id
           AND rhs.tournament_round_id = p_tournament_round_id
          JOIN public.tournament_registrations reg
            ON reg.id = hs.tournament_registration_id AND reg.activo
          LEFT JOIN public.tournament_round_shift_categories sc
            ON sc.tournament_category_id = hs.tournament_category_id AND sc.activo
          LEFT JOIN public.tournament_round_shifts rs
            ON rs.id = sc.tournament_round_shift_id
           AND rs.tournament_round_id = p_tournament_round_id
           AND rs.activo
          GROUP BY hs.tournament_registration_id
          HAVING count(rs.id) <> 1
      ) x;
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'participante_sin_turno_unico',
            'message', format('%s participante(s) no pertenecen exactamente a un turno activo de su categoría.', v_n)
        ));
    END IF;

    WITH assigned AS (
        SELECT gp.tournament_registration_id, count(*) AS n
        FROM public.tournament_group_players gp
        JOIN public.tournament_groups g ON g.id = gp.tournament_group_id AND g.activo
        JOIN public.tournament_round_shifts rs
          ON rs.id = g.tournament_round_shift_id AND rs.activo
        JOIN public.tournament_shotgun_category_holes sh
          ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
        JOIN public.tournament_shotgun_category_configs cfg
          ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
        JOIN public.tournament_round_shift_categories sc
          ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
        WHERE rs.tournament_round_id = p_tournament_round_id
        GROUP BY gp.tournament_registration_id
    ), eligible AS (
        SELECT rhs.tournament_registration_id
        FROM public.tournament_round_handicap_snapshots rhs
        JOIN public.tournament_registrations reg
          ON reg.id = rhs.tournament_registration_id AND reg.activo
        WHERE rhs.tournament_round_id = p_tournament_round_id
    )
    SELECT count(*)
      INTO v_n
      FROM eligible e
      LEFT JOIN assigned a ON a.tournament_registration_id = e.tournament_registration_id
     WHERE COALESCE(a.n, 0) <> 1;
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'participante_sin_grupo_unico',
            'message', format('%s participante(s) elegibles no están asignados exactamente una vez.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_group_players gp
      JOIN public.tournament_groups g ON g.id = gp.tournament_group_id AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id AND rs.activo
      LEFT JOIN public.tournament_registrations reg
        ON reg.id = gp.tournament_registration_id
      LEFT JOIN public.tournament_round_handicap_snapshots rhs
        ON rhs.tournament_round_id = p_tournament_round_id
       AND rhs.tournament_registration_id = gp.tournament_registration_id
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND (reg.id IS NULL OR NOT COALESCE(reg.activo, false) OR rhs.id IS NULL);
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'asignacion_no_elegible',
            'message', format('%s asignación(es) corresponden a inscripciones inactivas, inexistentes o sin snapshot de ronda.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_group_teams gt
      JOIN public.tournament_groups g
        ON g.id = gt.tournament_group_id AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id AND rs.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND gt.activo;
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'unidades_equipo_en_modalidad_individual',
            'message', format('%s asignación(es) de equipo existen en una modalidad individual.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_group_players gp
      JOIN public.tournament_groups g ON g.id = gp.tournament_group_id AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id AND rs.activo
      JOIN public.tournament_shotgun_category_holes sh
        ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
      JOIN public.tournament_shotgun_category_configs cfg
        ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
      JOIN public.tournament_handicap_snapshots hs
        ON hs.tournament_registration_id = gp.tournament_registration_id
       AND hs.freeze_id = v_ctx.freeze_id
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND hs.tournament_category_id IS DISTINCT FROM sc.tournament_category_id;
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'categoria_asignada_incorrecta',
            'message', format('%s participante(s) están en un grupo de otra categoría.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_group_count
      FROM public.tournament_groups g
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id AND rs.activo
      JOIN public.tournament_shotgun_category_holes sh
        ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
      JOIN public.tournament_shotgun_category_configs cfg
        ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND g.activo;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_groups g
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id AND rs.activo
      LEFT JOIN public.tournament_shotgun_category_holes sh
        ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
      LEFT JOIN public.tournament_shotgun_category_configs cfg
        ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
      LEFT JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND g.activo
       AND (
           sh.id IS NULL
           OR cfg.id IS NULL
           OR sc.id IS NULL
           OR sc.tournament_round_shift_id IS DISTINCT FROM rs.id
       );
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'grupo_fuera_de_configuracion_activa',
            'message', format('%s grupo(s) activos no pertenecen a una cadena Shotgun activa y consistente.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_groups g
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id AND rs.activo
      JOIN public.tournament_shotgun_category_holes sh
        ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
      JOIN public.tournament_shotgun_category_configs cfg
        ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND g.activo
       AND NOT EXISTS (
           SELECT 1 FROM public.tournament_group_players gp
           WHERE gp.tournament_group_id = g.id
       );
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'grupo_vacio',
            'message', format('%s grupo(s) activos no contienen participantes.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM (
          SELECT g.id
          FROM public.tournament_groups g
          JOIN public.tournament_round_shifts rs
            ON rs.id = g.tournament_round_shift_id AND rs.activo
          JOIN public.tournament_shotgun_category_holes sh
            ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
          JOIN public.tournament_shotgun_category_configs cfg
            ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
          JOIN public.tournament_round_shift_categories sc
            ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
          LEFT JOIN public.tournament_group_players gp
            ON gp.tournament_group_id = g.id
          WHERE rs.tournament_round_id = p_tournament_round_id AND g.activo
          GROUP BY g.id, cfg.tamano_grupo_maximo
          HAVING count(gp.id) > cfg.tamano_grupo_maximo
      ) x;
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'grupo_excede_maximo',
            'message', format('%s grupo(s) exceden el tamaño máximo configurado.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM (
          SELECT cfg.id, sh.id, g.posicion_salida
          FROM public.tournament_groups g
          JOIN public.tournament_round_shifts rs
            ON rs.id = g.tournament_round_shift_id AND rs.activo
          JOIN public.tournament_shotgun_category_holes sh
            ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
          JOIN public.tournament_shotgun_category_configs cfg
            ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
          JOIN public.tournament_round_shift_categories sc
            ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
          WHERE rs.tournament_round_id = p_tournament_round_id AND g.activo
          GROUP BY cfg.id, sh.id, g.posicion_salida
          HAVING count(*) > 1
      ) x;
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'posicion_salida_duplicada',
            'message', format('%s posición(es) físicas de salida están ocupadas por más de un grupo.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_groups g
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id AND rs.activo
      JOIN public.tournament_shotgun_category_holes sh
        ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
      JOIN public.tournament_shotgun_category_configs cfg
        ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND g.activo
       AND (
           g.hoyo_id IS DISTINCT FROM sh.hoyo_id
           OR g.tournament_round_shift_id IS DISTINCT FROM sc.tournament_round_shift_id
           OR g.posicion_salida IS NULL
           OR g.posicion_salida NOT IN ('A', 'B')
           OR (g.posicion_salida = 'B' AND NOT sh.salida_doble)
           OR g.hora_salida IS NULL
       );
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'grupo_salida_inconsistente',
            'message', format('%s grupo(s) tienen hoyo, turno, posición u hora inconsistentes.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM (
          SELECT gp.tournament_group_id
          FROM public.tournament_group_players gp
          JOIN public.tournament_groups g ON g.id = gp.tournament_group_id AND g.activo
          JOIN public.tournament_round_shifts rs
            ON rs.id = g.tournament_round_shift_id AND rs.activo
          WHERE rs.tournament_round_id = p_tournament_round_id
          GROUP BY gp.tournament_group_id
          HAVING bool_or(gp.orden_en_grupo IS NULL)
             OR count(*) <> count(DISTINCT gp.orden_en_grupo)
      ) x;
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'orden_grupo_invalido',
            'message', format('%s grupo(s) tienen posiciones de participante nulas o duplicadas.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_unit_count
      FROM public.tournament_group_players gp
      JOIN public.tournament_groups g ON g.id = gp.tournament_group_id AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id AND rs.activo
      JOIN public.tournament_shotgun_category_holes sh
        ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
      JOIN public.tournament_shotgun_category_configs cfg
        ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND sc.tournament_round_shift_id = rs.id;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_round_handicap_snapshots rhs
      JOIN public.tournament_registrations reg
        ON reg.id = rhs.tournament_registration_id AND reg.activo
      JOIN public.tournament_round_hole_snapshots hole
        ON hole.tournament_round_id = rhs.tournament_round_id
     WHERE rhs.tournament_round_id = p_tournament_round_id
       AND (
           NOT (hole.tee_distances_yards ? rhs.tee_id::text)
           OR hole.tee_distances_yards->rhs.tee_id::text = 'null'::jsonb
       );
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'distancia_congelada_faltante',
            'message', format('%s combinación(es) participante-hoyo no tienen distancia congelada.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_handicap_snapshots hs
     WHERE hs.freeze_id = v_ctx.freeze_id
       AND EXISTS (
           SELECT 1
           FROM public.tournament_round_handicap_snapshots rhs
           WHERE rhs.handicap_snapshot_id = hs.id
             AND rhs.tournament_round_id = p_tournament_round_id
       )
       AND NOT EXISTS (
           SELECT 1
           FROM public.tournament_registrations reg
           WHERE reg.id = hs.tournament_registration_id AND reg.activo
       );
    IF v_n > 0 THEN
        v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
            'code', 'inscripciones_retiradas_excluidas',
            'message', format('%s inscripción(es) congeladas están retiradas y se excluyen de la salida.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM (
          SELECT g.id
          FROM public.tournament_groups g
          JOIN public.tournament_round_shifts rs
            ON rs.id = g.tournament_round_shift_id AND rs.activo
          JOIN public.tournament_shotgun_category_holes sh
            ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
          JOIN public.tournament_shotgun_category_configs cfg
            ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
          JOIN public.tournament_round_shift_categories sc
            ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
          LEFT JOIN public.tournament_group_players gp ON gp.tournament_group_id = g.id
          WHERE rs.tournament_round_id = p_tournament_round_id AND g.activo
          GROUP BY g.id, cfg.tamano_grupo_normal
          HAVING count(gp.id) > 0 AND count(gp.id) < cfg.tamano_grupo_normal
      ) x;
    IF v_n > 0 THEN
        v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
            'code', 'grupos_incompletos',
            'message', format('%s grupo(s) están por debajo del tamaño normal configurado.', v_n)
        ));
    END IF;

    RETURN jsonb_build_object(
        'schemaVersion', 1,
        'validatorEngine', 'stroke_individual_shotgun_v1',
        'generatedAt', now(),
        'ready', jsonb_array_length(v_errors) = 0,
        'alreadyValidated', v_existing.id IS NOT NULL,
        'tournament', jsonb_build_object(
            'id', v_ctx.tournament_id,
            'name', v_ctx.tournament_name,
            'status', v_ctx.tournament_status
        ),
        'round', jsonb_build_object(
            'id', v_ctx.round_id,
            'number', v_ctx.numero_ronda,
            'date', v_ctx.fecha,
            'startFormat', v_ctx.live_start_format
        ),
        'format', jsonb_build_object(
            'code', v_ctx.format_code,
            'name', v_ctx.format_name,
            'participationType', v_ctx.participation_type,
            'scoringEngine', v_ctx.scoring_engine
        ),
        'currentValidation', CASE WHEN v_existing.id IS NULL THEN NULL ELSE
            jsonb_build_object(
                'id', v_existing.id,
                'version', v_existing.version,
                'validatedAt', v_existing.validated_at,
                'contentHash', v_existing.content_hash,
                'validatorEngine', v_existing.validator_engine
            ) END,
        'counts', jsonb_build_object(
            'configs', v_config_count,
            'groups', v_group_count,
            'eligibleUnits', v_eligible_count,
            'assignedUnits', v_unit_count,
            'errors', jsonb_array_length(v_errors),
            'warnings', jsonb_array_length(v_warnings)
        ),
        'errors', v_errors,
        'warnings', v_warnings
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2. Validación/cierre.
--    Sin cambios funcionales: se recrea únicamente para corregir textos UTF-8.
-- ---------------------------------------------------------------------------

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
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    SELECT tournament_id INTO v_tournament_id
    FROM public.tournament_rounds
    WHERE id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.' USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para validar las salidas de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(p_tournament_round_id);

    SELECT id INTO v_existing
    FROM public.tournament_round_start_validations
    WHERE tournament_round_id = p_tournament_round_id
      AND status = 'validated';

    IF v_existing IS NOT NULL THEN
        RETURN public.obtener_estado_validacion_salidas_ronda(p_tournament_round_id);
    END IF;

    v_preview := public.previsualizar_validacion_salidas_ronda(p_tournament_round_id);
    IF NOT COALESCE((v_preview->>'ready')::boolean, false) THEN
        RAISE EXCEPTION 'Las salidas de la ronda no están listas para validarse.'
            USING ERRCODE = '23514',
                  DETAIL = (v_preview->'errors')::text,
                  HINT = 'Corrige los errores indicados y vuelve a revisar las salidas.';
    END IF;

    SELECT au.id INTO v_admin_id
    FROM public.admin_users au
    WHERE au.auth_user_id = auth.uid() AND au.activo
    ORDER BY au.id
    LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    v_snapshot := public._construir_fotografia_salida_ronda(p_tournament_round_id);
    IF v_snapshot IS NULL THEN
        RAISE EXCEPTION 'No fue posible construir la fotografía de salidas.'
            USING ERRCODE = '55000';
    END IF;

    -- Conserva también las advertencias aceptadas en esa versión. No se agrega
    -- generatedAt para que el mismo contenido produzca siempre el mismo hash.
    v_snapshot := v_snapshot || jsonb_build_object(
        'warnings', COALESCE(v_preview->'warnings', '[]'::jsonb)
    );

    SELECT count(DISTINCT (g->>'sourceConfigId')::uuid),
           count(*),
           COALESCE(sum(jsonb_array_length(g->'units')), 0)::integer
      INTO v_config_count, v_group_count, v_unit_count
      FROM jsonb_array_elements(v_snapshot->'groups') AS x(g);

    SELECT COALESCE(max(version), 0) + 1
      INTO v_version
      FROM public.tournament_round_start_validations
     WHERE tournament_round_id = p_tournament_round_id;

    INSERT INTO public.tournament_round_start_validations (
        tournament_id, tournament_round_id,
        freeze_id, round_condition_snapshot_id,
        version, status,
        validator_engine, start_format, participation_type, scoring_engine,
        config_count, group_count, unit_count,
        validation_snapshot, content_hash, validated_by
    ) VALUES (
        v_tournament_id,
        p_tournament_round_id,
        (v_snapshot->>'freezeId')::uuid,
        (v_snapshot->>'roundConditionSnapshotId')::uuid,
        v_version,
        'validated',
        v_snapshot->>'validatorEngine',
        v_snapshot #>> '{round,startFormat}',
        v_snapshot #>> '{format,participationType}',
        v_snapshot #>> '{format,scoringEngine}',
        v_config_count,
        v_group_count,
        v_unit_count,
        v_snapshot,
        md5(v_snapshot::text),
        v_admin_id
    ) RETURNING id INTO v_validation_id;

    INSERT INTO public.tournament_round_start_validation_groups (
        validation_id, source_group_id, source_config_id,
        source_shift_id, source_shift_category_id,
        tournament_category_id, category_name,
        source_shotgun_hole_id, source_hole_id, hole_number,
        start_position, start_at, shift_number, shift_time,
        group_label, normal_size, maximum_size, unit_count
    )
    SELECT v_validation_id,
           (g->>'sourceGroupId')::uuid,
           (g->>'sourceConfigId')::uuid,
           (g->>'sourceShiftId')::uuid,
           (g->>'sourceShiftCategoryId')::uuid,
           (g->>'tournamentCategoryId')::uuid,
           g->>'categoryName',
           (g->>'sourceShotgunHoleId')::uuid,
           (g->>'sourceHoleId')::uuid,
           (g->>'holeNumber')::integer,
           g->>'startPosition',
           (g->>'startAt')::timestamptz,
           (g->>'shiftNumber')::integer,
           (g->>'shiftTime')::time,
           g->>'groupLabel',
           (g->>'normalSize')::integer,
           (g->>'maximumSize')::integer,
           jsonb_array_length(g->'units')
    FROM jsonb_array_elements(v_snapshot->'groups') AS x(g);
    GET DIAGNOSTICS v_inserted_groups = ROW_COUNT;

    INSERT INTO public.tournament_round_start_validation_units (
        validation_id, validation_group_id, unit_type,
        tournament_registration_id, tournament_team_id, player_id,
        tournament_category_id, unit_name, unit_folio, order_in_group,
        handicap_snapshot_id, round_handicap_snapshot_id
    )
    SELECT v_validation_id,
           vg.id,
           u->>'unitType',
           (u->>'registrationId')::uuid,
           NULL,
           (u->>'playerId')::uuid,
           vg.tournament_category_id,
           u->>'name',
           u->>'folio',
           (u->>'orderInGroup')::smallint,
           (u->>'handicapSnapshotId')::uuid,
           (u->>'roundHandicapSnapshotId')::uuid
    FROM jsonb_array_elements(v_snapshot->'groups') AS x(g)
    JOIN public.tournament_round_start_validation_groups vg
      ON vg.validation_id = v_validation_id
     AND vg.source_group_id = (g->>'sourceGroupId')::uuid
    CROSS JOIN LATERAL jsonb_array_elements(g->'units') AS y(u);
    GET DIAGNOSTICS v_inserted_units = ROW_COUNT;

    IF v_inserted_groups <> v_group_count
       OR v_inserted_units <> v_unit_count THEN
        RAISE EXCEPTION 'La validación quedó incompleta y fue revertida automáticamente.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'grupos=%s/%s; unidades=%s/%s',
                      v_inserted_groups, v_group_count,
                      v_inserted_units, v_unit_count
                  );
    END IF;

    RETURN public.obtener_estado_validacion_salidas_ronda(p_tournament_round_id);
END;
$function$;

COMMIT;
