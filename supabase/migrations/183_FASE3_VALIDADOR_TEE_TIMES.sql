-- ============================================================================
-- 183_FASE3_VALIDADOR_TEE_TIMES.sql
-- TEE CENTRAL
--
-- OBJETIVO
-- Implementar y habilitar el handler de validación para:
--   Tee Times + individual + Stroke
--
-- Esta fase habilita:
--   REVISAR SALIDAS
--   VALIDAR Y CERRAR SALIDAS
--
-- para Tee Times mediante la misma API pública ya desacoplada en 182 Fase 4.
--
-- NO habilita todavía la emisión de tarjetas.
--
-- PRINCIPIOS
-- - Reutiliza reglas competitivas comunes del validador Shotgun cuando aplican.
-- - Encapsula reglas físicas específicas de Tee Times.
-- - No usa campos Shotgun.
-- - La fotografía definitiva la sigue construyendo
--   _construir_contrato_salida_ronda(), ya compatible con Tee Times desde 183 F2.
-- - No modifica históricos.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. ORDEN DE CATEGORÍAS TEE TIMES
--
-- sequence_order debe ser único dentro del turno. Como la relación al turno
-- vive en tournament_round_shift_categories, se protege mediante trigger
-- (no mediante un índice con subquery).
-- ============================================================================

-- ============================================================================
-- 02. GUARD DE SEQUENCE_ORDER ÚNICO POR TURNO
-- ============================================================================
CREATE OR REPLACE FUNCTION public.validar_orden_categoria_tee_times()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_shift_id uuid;
BEGIN
    IF NOT NEW.activo THEN
        RETURN NEW;
    END IF;

    SELECT sc.tournament_round_shift_id
      INTO v_shift_id
      FROM public.tournament_round_shift_categories sc
     WHERE sc.id = NEW.tournament_round_shift_category_id;

    IF v_shift_id IS NULL THEN
        RAISE EXCEPTION
            'La categoría-turno indicada no existe.'
            USING ERRCODE = '23503';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_tee_time_category_configs cfg
        JOIN public.tournament_round_shift_categories sc
          ON sc.id = cfg.tournament_round_shift_category_id
        WHERE cfg.activo
          AND sc.tournament_round_shift_id = v_shift_id
          AND cfg.sequence_order = NEW.sequence_order
          AND cfg.id IS DISTINCT FROM NEW.id
    ) THEN
        RAISE EXCEPTION
            'Ya existe otra categoría Tee Times activa con el mismo orden dentro del turno.'
            USING ERRCODE = '23505';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_validar_orden_categoria_tee_times
ON public.tournament_tee_time_category_configs;

CREATE TRIGGER trg_validar_orden_categoria_tee_times
BEFORE INSERT OR UPDATE
ON public.tournament_tee_time_category_configs
FOR EACH ROW
EXECUTE FUNCTION public.validar_orden_categoria_tee_times();


-- ============================================================================
-- 03. HANDLER ESPECÍFICO TEE TIMES
-- ============================================================================
CREATE OR REPLACE FUNCTION public._previsualizar_validacion_salidas_tee_times_v1(
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
    v_shift_config_count integer := 0;
    v_category_config_count integer := 0;
    v_group_count integer := 0;
    v_unit_count integer := 0;
    v_eligible_count integer := 0;

    v_existing record;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
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

        COALESCE(
            tr.tournament_format_id,
            t.tournament_format_id
        ) AS live_format_id

      INTO v_ctx

      FROM public.tournament_rounds tr

      JOIN public.tournaments t
        ON t.id = tr.tournament_id

      LEFT JOIN public.tournament_condition_freezes f
        ON f.tournament_id = tr.tournament_id

      LEFT JOIN public.tournament_round_condition_snapshots rcs
        ON rcs.freeze_id = f.id
       AND rcs.tournament_round_id = tr.id

     WHERE tr.id = p_tournament_round_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_ctx.tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para validar las salidas de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        v.id,
        v.version,
        v.validated_at,
        v.validated_by,
        v.content_hash,
        v.validator_engine
      INTO v_existing
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_round_id = p_tournament_round_id
       AND v.status = 'validated'
     ORDER BY v.version DESC
     LIMIT 1;

    -- ------------------------------------------------------------------------
    -- PRECONDICIONES COMUNES
    -- ------------------------------------------------------------------------
    IF NOT v_ctx.round_active THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'ronda_inactiva',
                'message',
                    'La ronda está inactiva y no puede validarse.'
            )
        );
    END IF;

    IF v_ctx.freeze_id IS NULL THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'torneo_no_congelado',
                'message',
                    'Las condiciones y hándicaps del torneo deben congelarse antes de validar salidas.'
            )
        );
    ELSIF v_ctx.round_condition_snapshot_id IS NULL THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'ronda_sin_snapshot',
                'message',
                    'La ronda no forma parte de las condiciones congeladas del torneo.'
            )
        );
    END IF;

    IF COALESCE(v_ctx.live_start_format, '') <> 'tee_times' THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'ronda_no_tee_times',
                'message',
                    'Este validador requiere formato de salida Tee Times.'
            )
        );
    END IF;

    IF COALESCE(v_ctx.participation_type, '') <> 'individual'
       OR COALESCE(v_ctx.scoring_engine, '') <> 'stroke'
    THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'modalidad_no_soportada',
                'message',
                    'Esta versión valida Tee Times únicamente para Stroke Play individual.',
                'detail',
                    jsonb_build_object(
                        'participationType',
                            v_ctx.participation_type,
                        'scoringEngine',
                            v_ctx.scoring_engine
                    )
            )
        );
    END IF;

    IF v_ctx.frozen_format_id IS DISTINCT FROM v_ctx.live_format_id THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'formato_distinto_del_congelado',
                'message',
                    'El formato efectivo vivo de la ronda no coincide con el formato congelado.'
            )
        );
    END IF;

    IF v_ctx.tournament_status NOT IN (
        'inscripcion_cerrada',
        'en_curso'
    ) THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'estatus_torneo_no_operativo',
                'message',
                    format(
                        'El torneo tiene estatus %s. Debes cerrar las inscripciones antes de validar y cerrar las salidas.',
                        v_ctx.tournament_status
                    )
            )
        );
    END IF;

    IF jsonb_array_length(
        COALESCE(v_ctx.freeze_warnings, '[]'::jsonb)
    ) > 0 THEN
        v_warnings := v_warnings || jsonb_build_array(
            jsonb_build_object(
                'code', 'congelamiento_con_advertencias',
                'message',
                    'El congelamiento del torneo contiene advertencias que deben revisarse.',
                'detail',
                    v_ctx.freeze_warnings
            )
        );
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_round_hole_snapshots rhs
     WHERE rhs.tournament_round_id = p_tournament_round_id;

    IF v_ctx.freeze_id IS NOT NULL AND v_n <> 18 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'snapshot_hoyos_incompleto',
                'message',
                    format(
                        'La ronda tiene %s hoyos congelados; se requieren 18.',
                        v_n
                    )
            )
        );
    END IF;

    -- ------------------------------------------------------------------------
    -- TURNOS / CONFIGURACIÓN TEE TIMES
    -- ------------------------------------------------------------------------
    SELECT count(*)
      INTO v_n
      FROM public.tournament_round_shifts rs
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND rs.activo;

    IF v_n = 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'sin_turnos_activos',
                'message',
                    'La ronda no tiene turnos activos.'
            )
        );
    END IF;

    SELECT count(*)
      INTO v_shift_config_count
      FROM public.tournament_tee_time_shift_configs cfg
      JOIN public.tournament_round_shifts rs
        ON rs.id = cfg.tournament_round_shift_id
       AND rs.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND cfg.activo;

    -- Cada turno activo debe tener exactamente una config Tee Times.
    SELECT count(*)
      INTO v_n
      FROM public.tournament_round_shifts rs
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND rs.activo
       AND NOT EXISTS (
           SELECT 1
           FROM public.tournament_tee_time_shift_configs cfg
           WHERE cfg.tournament_round_shift_id = rs.id
             AND cfg.activo
       );

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'turno_sin_configuracion_tee_times',
                'message',
                    format(
                        '%s turno(s) activos no tienen configuración Tee Times.',
                        v_n
                    )
            )
        );
    END IF;

    -- Cada config de turno debe tener 1 o 2 streams activos.
    SELECT count(*)
      INTO v_n
      FROM public.tournament_tee_time_shift_configs cfg
      JOIN public.tournament_round_shifts rs
        ON rs.id = cfg.tournament_round_shift_id
       AND rs.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND cfg.activo
       AND (
           SELECT count(*)
           FROM public.tournament_tee_time_shift_start_holes sh
           WHERE sh.tournament_tee_time_shift_config_id = cfg.id
             AND sh.activo
       ) NOT BETWEEN 1 AND 2;

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'configuracion_tee_times_sin_stream_valido',
                'message',
                    format(
                        '%s configuración(es) Tee Times no tienen uno o dos tees de inicio activos.',
                        v_n
                    )
            )
        );
    END IF;

    SELECT count(*)
      INTO v_category_config_count
      FROM public.tournament_tee_time_category_configs cfg
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id
       AND sc.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = sc.tournament_round_shift_id
       AND rs.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND cfg.activo;

    -- Sólo exigir config a categoría-turno con elegibles congelados.
    SELECT count(*)
      INTO v_n
      FROM public.tournament_round_shift_categories sc
      JOIN public.tournament_round_shifts rs
        ON rs.id = sc.tournament_round_shift_id
       AND rs.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND sc.activo
       AND EXISTS (
           SELECT 1
           FROM public.tournament_handicap_snapshots hs
           JOIN public.tournament_round_handicap_snapshots rhs
             ON rhs.handicap_snapshot_id = hs.id
            AND rhs.tournament_round_id =
                p_tournament_round_id
           JOIN public.tournament_registrations reg
             ON reg.id = hs.tournament_registration_id
            AND reg.activo
           WHERE hs.freeze_id = v_ctx.freeze_id
             AND hs.tournament_category_id =
                 sc.tournament_category_id
       )
       AND NOT EXISTS (
           SELECT 1
           FROM public.tournament_tee_time_category_configs cfg
           WHERE cfg.tournament_round_shift_category_id = sc.id
             AND cfg.activo
       );

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code',
                    'categoria_turno_sin_configuracion',
                'message',
                    format(
                        '%s asignación(es) de categoría a turno con participantes elegibles no tienen configuración Tee Times activa.',
                        v_n
                    )
            )
        );
    END IF;

    -- sequence_order único por turno.
    SELECT count(*)
      INTO v_n
      FROM (
          SELECT
              sc.tournament_round_shift_id,
              cfg.sequence_order
          FROM public.tournament_tee_time_category_configs cfg
          JOIN public.tournament_round_shift_categories sc
            ON sc.id = cfg.tournament_round_shift_category_id
           AND sc.activo
          JOIN public.tournament_round_shifts rs
            ON rs.id = sc.tournament_round_shift_id
           AND rs.activo
          WHERE rs.tournament_round_id =
              p_tournament_round_id
            AND cfg.activo
          GROUP BY
              sc.tournament_round_shift_id,
              cfg.sequence_order
          HAVING count(*) > 1
      ) x;

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code',
                    'orden_categoria_duplicado',
                'message',
                    format(
                        '%s orden(es) de categoría Tee Times están duplicados dentro de un turno.',
                        v_n
                    )
            )
        );
    END IF;

    -- ------------------------------------------------------------------------
    -- PARTICIPANTES ELEGIBLES / TURNO ÚNICO
    -- ------------------------------------------------------------------------
    SELECT count(*)
      INTO v_eligible_count
      FROM public.tournament_round_handicap_snapshots rhs
      JOIN public.tournament_registrations reg
        ON reg.id = rhs.tournament_registration_id
       AND reg.activo
     WHERE rhs.tournament_round_id = p_tournament_round_id;

    IF v_eligible_count = 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'sin_participantes_elegibles',
                'message',
                    'La ronda no tiene participantes activos con hándicap congelado.'
            )
        );
    END IF;

    SELECT count(*)
      INTO v_n
      FROM (
          SELECT
              hs.tournament_registration_id
          FROM public.tournament_handicap_snapshots hs
          JOIN public.tournament_round_handicap_snapshots rhs
            ON rhs.handicap_snapshot_id = hs.id
           AND rhs.tournament_round_id =
               p_tournament_round_id
          JOIN public.tournament_registrations reg
            ON reg.id = hs.tournament_registration_id
           AND reg.activo
          LEFT JOIN public.tournament_round_shift_categories sc
            ON sc.tournament_category_id =
               hs.tournament_category_id
           AND sc.activo
          LEFT JOIN public.tournament_round_shifts rs
            ON rs.id = sc.tournament_round_shift_id
           AND rs.tournament_round_id =
               p_tournament_round_id
           AND rs.activo
          GROUP BY hs.tournament_registration_id
          HAVING count(rs.id) <> 1
      ) x;

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'participante_sin_turno_unico',
                'message',
                    format(
                        '%s participante(s) no pertenecen exactamente a un turno activo de su categoría.',
                        v_n
                    )
            )
        );
    END IF;

    -- ------------------------------------------------------------------------
    -- GRUPOS TEE TIMES
    -- ------------------------------------------------------------------------
    SELECT count(*)
      INTO v_group_count
      FROM public.tournament_tee_time_groups ttg
      JOIN public.tournament_groups g
        ON g.id = ttg.tournament_group_id
       AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id
       AND rs.activo
     WHERE rs.tournament_round_id =
         p_tournament_round_id
       AND ttg.activo;

    -- Todo grupo activo de la ronda debe ser Tee Times y tener metadata.
    SELECT count(*)
      INTO v_n
      FROM public.tournament_groups g
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id
       AND rs.activo
      LEFT JOIN public.tournament_tee_time_groups ttg
        ON ttg.tournament_group_id = g.id
       AND ttg.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND g.activo
       AND ttg.id IS NULL;

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'grupo_fuera_de_configuracion_activa',
                'message',
                    format(
                        '%s grupo(s) activos de la ronda no tienen metadata Tee Times activa.',
                        v_n
                    )
            )
        );
    END IF;

    -- Ningún grupo Tee Times puede contener campos Shotgun.
    SELECT count(*)
      INTO v_n
      FROM public.tournament_tee_time_groups ttg
      JOIN public.tournament_groups g
        ON g.id = ttg.tournament_group_id
       AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id
       AND rs.activo
     WHERE rs.tournament_round_id =
         p_tournament_round_id
       AND ttg.activo
       AND (
           g.tournament_shotgun_category_hole_id IS NOT NULL
           OR g.posicion_salida IS NOT NULL
       );

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'campos_shotgun_en_tee_times',
                'message',
                    format(
                        '%s grupo(s) Tee Times contienen campos exclusivos de Shotgun.',
                        v_n
                    )
            )
        );
    END IF;

    -- Cadena activa y consistente:
    -- grupo -> metadata -> category config -> shift-category
    --                    -> start hole -> shift config
    SELECT count(*)
      INTO v_n
      FROM public.tournament_tee_time_groups ttg

      JOIN public.tournament_groups g
        ON g.id = ttg.tournament_group_id
       AND g.activo

      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id
       AND rs.activo

      LEFT JOIN public.tournament_tee_time_category_configs cc
        ON cc.id =
           ttg.tournament_tee_time_category_config_id
       AND cc.activo

      LEFT JOIN public.tournament_round_shift_categories sc
        ON sc.id = cc.tournament_round_shift_category_id
       AND sc.activo

      LEFT JOIN public.tournament_tee_time_shift_start_holes sh
        ON sh.id =
           ttg.tournament_tee_time_start_hole_id
       AND sh.activo

      LEFT JOIN public.tournament_tee_time_shift_configs tc
        ON tc.id =
           sh.tournament_tee_time_shift_config_id
       AND tc.activo

     WHERE rs.tournament_round_id =
         p_tournament_round_id
       AND ttg.activo
       AND (
           cc.id IS NULL
           OR sc.id IS NULL
           OR sh.id IS NULL
           OR tc.id IS NULL
           OR sc.tournament_round_shift_id
              IS DISTINCT FROM rs.id
           OR tc.tournament_round_shift_id
              IS DISTINCT FROM rs.id
           OR g.hoyo_id
              IS DISTINCT FROM sh.hoyo_id
       );

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code',
                    'grupo_tee_times_inconsistente',
                'message',
                    format(
                        '%s grupo(s) Tee Times tienen categoría, turno o tee de inicio inconsistentes.',
                        v_n
                    )
            )
        );
    END IF;

    -- Slots físicos duplicados.
    SELECT count(*)
      INTO v_n
      FROM (
          SELECT
              ttg.tournament_tee_time_start_hole_id,
              ttg.sequence_number
          FROM public.tournament_tee_time_groups ttg
          JOIN public.tournament_groups g
            ON g.id = ttg.tournament_group_id
           AND g.activo
          JOIN public.tournament_round_shifts rs
            ON rs.id = g.tournament_round_shift_id
           AND rs.activo
          WHERE rs.tournament_round_id =
              p_tournament_round_id
            AND ttg.activo
          GROUP BY
              ttg.tournament_tee_time_start_hole_id,
              ttg.sequence_number
          HAVING count(*) > 1
      ) x;

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'slot_tee_time_duplicado',
                'message',
                    format(
                        '%s slot(s) Tee Times están ocupados por más de un grupo.',
                        v_n
                    )
            )
        );
    END IF;

    -- Hora real debe coincidir EXACTAMENTE con la hora derivada.
    SELECT count(*)
      INTO v_n
      FROM public.tournament_tee_time_groups ttg
      JOIN public.tournament_groups g
        ON g.id = ttg.tournament_group_id
       AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id
       AND rs.activo
     WHERE rs.tournament_round_id =
         p_tournament_round_id
       AND ttg.activo
       AND g.hora_salida IS DISTINCT FROM
           public.hora_salida_tee_time(
               ttg.tournament_tee_time_start_hole_id,
               ttg.sequence_number
           );

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'hora_tee_time_inconsistente',
                'message',
                    format(
                        '%s grupo(s) tienen una hora distinta de la secuencia Tee Times configurada.',
                        v_n
                    )
            )
        );
    END IF;

    -- Grupos vacíos.
    SELECT count(*)
      INTO v_n
      FROM public.tournament_tee_time_groups ttg
      JOIN public.tournament_groups g
        ON g.id = ttg.tournament_group_id
       AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id
       AND rs.activo
     WHERE rs.tournament_round_id =
         p_tournament_round_id
       AND ttg.activo
       AND NOT EXISTS (
           SELECT 1
           FROM public.tournament_group_players gp
           WHERE gp.tournament_group_id = g.id
       );

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'grupo_vacio',
                'message',
                    format(
                        '%s grupo(s) activos no contienen participantes.',
                        v_n
                    )
            )
        );
    END IF;

    -- Máximo por categoría.
    SELECT count(*)
      INTO v_n
      FROM (
          SELECT
              g.id
          FROM public.tournament_tee_time_groups ttg
          JOIN public.tournament_groups g
            ON g.id = ttg.tournament_group_id
           AND g.activo
          JOIN public.tournament_round_shifts rs
            ON rs.id = g.tournament_round_shift_id
           AND rs.activo
          JOIN public.tournament_tee_time_category_configs cc
            ON cc.id =
               ttg.tournament_tee_time_category_config_id
           AND cc.activo
          LEFT JOIN public.tournament_group_players gp
            ON gp.tournament_group_id = g.id
          WHERE rs.tournament_round_id =
              p_tournament_round_id
            AND ttg.activo
          GROUP BY
              g.id,
              cc.tamano_grupo_maximo
          HAVING count(gp.id) >
                 cc.tamano_grupo_maximo
      ) x;

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'grupo_excede_maximo',
                'message',
                    format(
                        '%s grupo(s) exceden el tamaño máximo configurado.',
                        v_n
                    )
            )
        );
    END IF;

    -- Orden interno de jugadores.
    SELECT count(*)
      INTO v_n
      FROM (
          SELECT
              gp.tournament_group_id
          FROM public.tournament_group_players gp
          JOIN public.tournament_groups g
            ON g.id = gp.tournament_group_id
           AND g.activo
          JOIN public.tournament_round_shifts rs
            ON rs.id = g.tournament_round_shift_id
           AND rs.activo
          JOIN public.tournament_tee_time_groups ttg
            ON ttg.tournament_group_id = g.id
           AND ttg.activo
          WHERE rs.tournament_round_id =
              p_tournament_round_id
          GROUP BY gp.tournament_group_id
          HAVING bool_or(
                     gp.orden_en_grupo IS NULL
                 )
              OR count(*) <>
                 count(DISTINCT gp.orden_en_grupo)
      ) x;

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'orden_grupo_invalido',
                'message',
                    format(
                        '%s grupo(s) tienen posiciones de participante nulas o duplicadas.',
                        v_n
                    )
            )
        );
    END IF;

    -- Categoría del jugador debe coincidir con categoría del bloque.
    SELECT count(*)
      INTO v_n
      FROM public.tournament_group_players gp

      JOIN public.tournament_groups g
        ON g.id = gp.tournament_group_id
       AND g.activo

      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id
       AND rs.activo

      JOIN public.tournament_tee_time_groups ttg
        ON ttg.tournament_group_id = g.id
       AND ttg.activo

      JOIN public.tournament_tee_time_category_configs cc
        ON cc.id =
           ttg.tournament_tee_time_category_config_id
       AND cc.activo

      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cc.tournament_round_shift_category_id
       AND sc.activo

      JOIN public.tournament_handicap_snapshots hs
        ON hs.tournament_registration_id =
           gp.tournament_registration_id
       AND hs.freeze_id = v_ctx.freeze_id

     WHERE rs.tournament_round_id =
         p_tournament_round_id
       AND hs.tournament_category_id
           IS DISTINCT FROM
           sc.tournament_category_id;

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code',
                    'categoria_asignada_incorrecta',
                'message',
                    format(
                        '%s participante(s) están en un grupo de otra categoría.',
                        v_n
                    )
            )
        );
    END IF;

    -- Asignaciones deben ser activas y tener snapshot.
    SELECT count(*)
      INTO v_n
      FROM public.tournament_group_players gp
      JOIN public.tournament_groups g
        ON g.id = gp.tournament_group_id
       AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id
       AND rs.activo
      JOIN public.tournament_tee_time_groups ttg
        ON ttg.tournament_group_id = g.id
       AND ttg.activo
      LEFT JOIN public.tournament_registrations reg
        ON reg.id = gp.tournament_registration_id
      LEFT JOIN public.tournament_round_handicap_snapshots rhs
        ON rhs.tournament_round_id =
           p_tournament_round_id
       AND rhs.tournament_registration_id =
           gp.tournament_registration_id
     WHERE rs.tournament_round_id =
         p_tournament_round_id
       AND (
           reg.id IS NULL
           OR NOT COALESCE(reg.activo,false)
           OR rhs.id IS NULL
       );

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'asignacion_no_elegible',
                'message',
                    format(
                        '%s asignación(es) corresponden a inscripciones inactivas, inexistentes o sin snapshot de ronda.',
                        v_n
                    )
            )
        );
    END IF;

    -- Cada elegible exactamente una vez.
    WITH assigned AS (
        SELECT
            gp.tournament_registration_id,
            count(*) AS n
        FROM public.tournament_group_players gp
        JOIN public.tournament_groups g
          ON g.id = gp.tournament_group_id
         AND g.activo
        JOIN public.tournament_round_shifts rs
          ON rs.id = g.tournament_round_shift_id
         AND rs.activo
        JOIN public.tournament_tee_time_groups ttg
          ON ttg.tournament_group_id = g.id
         AND ttg.activo
        WHERE rs.tournament_round_id =
            p_tournament_round_id
        GROUP BY gp.tournament_registration_id
    ),
    eligible AS (
        SELECT rhs.tournament_registration_id
        FROM public.tournament_round_handicap_snapshots rhs
        JOIN public.tournament_registrations reg
          ON reg.id = rhs.tournament_registration_id
         AND reg.activo
        WHERE rhs.tournament_round_id =
            p_tournament_round_id
    )
    SELECT count(*)
      INTO v_n
      FROM eligible e
      LEFT JOIN assigned a
        ON a.tournament_registration_id =
           e.tournament_registration_id
     WHERE COALESCE(a.n,0) <> 1;

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code', 'participante_sin_grupo_unico',
                'message',
                    format(
                        '%s participante(s) elegibles no están asignados exactamente una vez.',
                        v_n
                    )
            )
        );
    END IF;

    -- No debe haber equipos en modalidad individual.
    SELECT count(*)
      INTO v_n
      FROM public.tournament_group_teams gt
      JOIN public.tournament_groups g
        ON g.id = gt.tournament_group_id
       AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id
       AND rs.activo
     WHERE rs.tournament_round_id =
         p_tournament_round_id
       AND gt.activo;

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code',
                    'unidades_equipo_en_modalidad_individual',
                'message',
                    format(
                        '%s asignación(es) de equipo existen en una modalidad individual.',
                        v_n
                    )
            )
        );
    END IF;

    -- Bloques de categoría deben respetar sequence_order en cada stream:
    -- una categoría anterior no puede tener una secuencia posterior al inicio
    -- de una categoría configurada después.
    SELECT count(*)
      INTO v_n
      FROM (
          WITH spans AS (
              SELECT
                  sh.tournament_tee_time_shift_config_id,
                  ttg.tournament_tee_time_start_hole_id,
                  cc.sequence_order,
                  min(ttg.sequence_number) AS min_seq,
                  max(ttg.sequence_number) AS max_seq
              FROM public.tournament_tee_time_groups ttg
              JOIN public.tournament_groups g
                ON g.id = ttg.tournament_group_id
               AND g.activo
              JOIN public.tournament_round_shifts rs
                ON rs.id = g.tournament_round_shift_id
               AND rs.activo
              JOIN public.tournament_tee_time_category_configs cc
                ON cc.id =
                   ttg.tournament_tee_time_category_config_id
               AND cc.activo
              JOIN public.tournament_tee_time_shift_start_holes sh
                ON sh.id =
                   ttg.tournament_tee_time_start_hole_id
               AND sh.activo
              WHERE rs.tournament_round_id =
                  p_tournament_round_id
                AND ttg.activo
              GROUP BY
                  sh.tournament_tee_time_shift_config_id,
                  ttg.tournament_tee_time_start_hole_id,
                  cc.sequence_order
          )
          SELECT 1
          FROM spans a
          JOIN spans b
            ON b.tournament_tee_time_shift_config_id =
               a.tournament_tee_time_shift_config_id
           AND b.tournament_tee_time_start_hole_id =
               a.tournament_tee_time_start_hole_id
           AND a.sequence_order < b.sequence_order
          WHERE a.max_seq >= b.min_seq
      ) x;

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code',
                    'orden_categorias_inconsistente',
                'message',
                    format(
                        '%s relación(es) entre bloques de categoría no respetan el orden configurado.',
                        v_n
                    )
            )
        );
    END IF;

    -- Conteo de unidades realmente asignadas.
    SELECT count(*)
      INTO v_unit_count
      FROM public.tournament_group_players gp
      JOIN public.tournament_groups g
        ON g.id = gp.tournament_group_id
       AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id
       AND rs.activo
      JOIN public.tournament_tee_time_groups ttg
        ON ttg.tournament_group_id = g.id
       AND ttg.activo
     WHERE rs.tournament_round_id =
         p_tournament_round_id;

    -- ------------------------------------------------------------------------
    -- SNAPSHOT / DISTANCIAS
    -- ------------------------------------------------------------------------
    SELECT count(*)
      INTO v_n
      FROM public.tournament_round_handicap_snapshots rhs
      JOIN public.tournament_registrations reg
        ON reg.id = rhs.tournament_registration_id
       AND reg.activo
      JOIN public.tournament_round_hole_snapshots hole
        ON hole.tournament_round_id =
           rhs.tournament_round_id
     WHERE rhs.tournament_round_id =
         p_tournament_round_id
       AND (
           NOT (
               hole.tee_distances_yards
               ? rhs.tee_id::text
           )
           OR hole.tee_distances_yards
              ->rhs.tee_id::text =
              'null'::jsonb
       );

    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code',
                    'distancia_congelada_faltante',
                'message',
                    format(
                        '%s combinación(es) participante-hoyo no tienen distancia congelada.',
                        v_n
                    )
            )
        );
    END IF;

    -- Retirados congelados: warning igual que Shotgun.
    SELECT count(*)
      INTO v_n
      FROM public.tournament_handicap_snapshots hs
     WHERE hs.freeze_id = v_ctx.freeze_id
       AND EXISTS (
           SELECT 1
           FROM public.tournament_round_handicap_snapshots rhs
           WHERE rhs.handicap_snapshot_id = hs.id
             AND rhs.tournament_round_id =
                 p_tournament_round_id
       )
       AND NOT EXISTS (
           SELECT 1
           FROM public.tournament_registrations reg
           WHERE reg.id =
               hs.tournament_registration_id
             AND reg.activo
       );

    IF v_n > 0 THEN
        v_warnings := v_warnings || jsonb_build_array(
            jsonb_build_object(
                'code',
                    'inscripciones_retiradas_excluidas',
                'message',
                    format(
                        '%s inscripción(es) congeladas están retiradas y se excluyen de la salida.',
                        v_n
                    )
            )
        );
    END IF;

    -- Grupos por debajo del tamaño normal: warning.
    SELECT count(*)
      INTO v_n
      FROM (
          SELECT
              g.id
          FROM public.tournament_tee_time_groups ttg
          JOIN public.tournament_groups g
            ON g.id = ttg.tournament_group_id
           AND g.activo
          JOIN public.tournament_round_shifts rs
            ON rs.id = g.tournament_round_shift_id
           AND rs.activo
          JOIN public.tournament_tee_time_category_configs cc
            ON cc.id =
               ttg.tournament_tee_time_category_config_id
           AND cc.activo
          LEFT JOIN public.tournament_group_players gp
            ON gp.tournament_group_id = g.id
          WHERE rs.tournament_round_id =
              p_tournament_round_id
            AND ttg.activo
          GROUP BY
              g.id,
              cc.tamano_grupo_normal
          HAVING count(gp.id) > 0
             AND count(gp.id) <
                 cc.tamano_grupo_normal
      ) x;

    IF v_n > 0 THEN
        v_warnings := v_warnings || jsonb_build_array(
            jsonb_build_object(
                'code', 'grupos_incompletos',
                'message',
                    format(
                        '%s grupo(s) están por debajo del tamaño normal configurado.',
                        v_n
                    )
            )
        );
    END IF;

    RETURN jsonb_build_object(
        'schemaVersion', 1,
        'validatorEngine',
            'stroke_individual_tee_times_v1',
        'generatedAt',
            now(),

        'ready',
            jsonb_array_length(v_errors) = 0,

        'alreadyValidated',
            v_existing.id IS NOT NULL,

        'tournament',
            jsonb_build_object(
                'id',
                    v_ctx.tournament_id,
                'name',
                    v_ctx.tournament_name,
                'status',
                    v_ctx.tournament_status
            ),

        'round',
            jsonb_build_object(
                'id',
                    v_ctx.round_id,
                'number',
                    v_ctx.numero_ronda,
                'date',
                    v_ctx.fecha,
                'startFormat',
                    v_ctx.live_start_format
            ),

        'format',
            jsonb_build_object(
                'code',
                    v_ctx.format_code,
                'name',
                    v_ctx.format_name,
                'participationType',
                    v_ctx.participation_type,
                'scoringEngine',
                    v_ctx.scoring_engine
            ),

        'currentValidation',
            CASE
                WHEN v_existing.id IS NULL
                THEN NULL
                ELSE jsonb_build_object(
                    'id',
                        v_existing.id,
                    'version',
                        v_existing.version,
                    'validatedAt',
                        v_existing.validated_at,
                    'contentHash',
                        v_existing.content_hash,
                    'validatorEngine',
                        v_existing.validator_engine
                )
            END,

        'counts',
            jsonb_build_object(
                'shiftConfigs',
                    v_shift_config_count,
                'configs',
                    v_category_config_count,
                'groups',
                    v_group_count,
                'eligibleUnits',
                    v_eligible_count,
                'assignedUnits',
                    v_unit_count,
                'errors',
                    jsonb_array_length(v_errors),
                'warnings',
                    jsonb_array_length(v_warnings)
            ),

        'errors',
            v_errors,

        'warnings',
            v_warnings
    );
END;
$function$;


-- ============================================================================
-- 04. HABILITAR HANDLER TEE TIMES EN EL REGISTRO
-- ============================================================================
UPDATE public.tournament_start_engine_registry
SET
    supports_start_validation = true,
    start_validation_handler = 'tee_times_v1',
    updated_at = now()
WHERE start_format =
        'tee_times'::public.formato_salida_ronda
  AND participation_type = 'individual'
  AND scoring_engine = 'stroke'
  AND preparation_engine = 'tee_times_v1'
  AND validation_engine =
      'stroke_individual_tee_times_v1'
  AND activo;


-- ============================================================================
-- 05. EXTENDER DISPATCHER PÚBLICO
--
-- Conserva la misma firma/API.
-- ============================================================================
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
    v_tournament_id uuid;
    v_round record;
    v_dispatch jsonb;
    v_handler text;
    v_result jsonb;
    v_state jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        tr.tournament_id,
        tr.numero_ronda,
        tr.fecha,
        tr.formato_salida::text AS start_format,
        t.nombre AS tournament_name,
        t.estatus::text AS tournament_status,
        tf.id AS tournament_format_id,
        tf.code AS format_code,
        tf.name AS format_name,
        tf.tipo_participacion::text
            AS participation_type,
        tf.scoring_engine::text
            AS scoring_engine
      INTO v_round
      FROM public.tournament_rounds tr
      JOIN public.tournaments t
        ON t.id = tr.tournament_id
      LEFT JOIN public.tournament_formats tf
        ON tf.id = COALESCE(
            tr.tournament_format_id,
            t.tournament_format_id
        )
     WHERE tr.id = p_tournament_round_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    v_tournament_id := v_round.tournament_id;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para validar las salidas de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    v_dispatch :=
        public._resolver_validador_salida_ronda(
            p_tournament_round_id
        );

    IF NOT COALESCE(
        (v_dispatch->>'supported')::boolean,
        false
    ) THEN
        v_state :=
            public.obtener_estado_validacion_salidas_ronda(
                p_tournament_round_id
            );

        RETURN jsonb_build_object(
            'schemaVersion', 2,
            'validatorEngine', NULL,
            'validationHandler', NULL,
            'generatedAt', now(),
            'ready', false,
            'alreadyValidated',
                COALESCE(
                    (v_state->>'validated')::boolean,
                    false
                ),

            'tournament',
                jsonb_build_object(
                    'id',
                        v_tournament_id,
                    'name',
                        v_round.tournament_name,
                    'status',
                        v_round.tournament_status
                ),

            'round',
                jsonb_build_object(
                    'id',
                        p_tournament_round_id,
                    'number',
                        v_round.numero_ronda,
                    'date',
                        v_round.fecha,
                    'startFormat',
                        v_round.start_format
                ),

            'format',
                jsonb_build_object(
                    'tournamentFormatId',
                        v_round.tournament_format_id,
                    'code',
                        v_round.format_code,
                    'name',
                        v_round.format_name,
                    'participationType',
                        v_round.participation_type,
                    'scoringEngine',
                        v_round.scoring_engine
                ),

            'counts',
                jsonb_build_object(
                    'configs', 0,
                    'groups', 0,
                    'eligibleUnits', 0,
                    'assignedUnits', 0,
                    'errors', 1,
                    'warnings', 0
                ),

            'errors',
                jsonb_build_array(
                    jsonb_build_object(
                        'code',
                            COALESCE(
                                v_dispatch->>'code',
                                'validacion_salida_no_soportada'
                            ),
                        'message',
                            COALESCE(
                                v_dispatch->>'message',
                                'La ronda todavía no tiene un validador de salidas habilitado.'
                            ),
                        'detail',
                            v_dispatch
                    )
                ),

            'warnings',
                '[]'::jsonb,

            'dispatch',
                v_dispatch
        );
    END IF;

    v_handler :=
        v_dispatch->>'validationHandler';

    CASE v_handler

        WHEN 'shotgun_v1' THEN
            v_result :=
                public._previsualizar_validacion_salidas_shotgun_v1(
                    p_tournament_round_id
                );

        WHEN 'tee_times_v1' THEN
            v_result :=
                public._previsualizar_validacion_salidas_tee_times_v1(
                    p_tournament_round_id
                );

        ELSE
            RETURN jsonb_build_object(
                'schemaVersion', 2,
                'validatorEngine',
                    v_dispatch->>'validationEngine',
                'validationHandler',
                    v_handler,
                'generatedAt',
                    now(),
                'ready',
                    false,
                'alreadyValidated',
                    false,

                'tournament',
                    jsonb_build_object(
                        'id',
                            v_tournament_id,
                        'name',
                            v_round.tournament_name,
                        'status',
                            v_round.tournament_status
                    ),

                'round',
                    jsonb_build_object(
                        'id',
                            p_tournament_round_id,
                        'number',
                            v_round.numero_ronda,
                        'date',
                            v_round.fecha,
                        'startFormat',
                            v_round.start_format
                    ),

                'format',
                    jsonb_build_object(
                        'code',
                            v_round.format_code,
                        'name',
                            v_round.format_name,
                        'participationType',
                            v_round.participation_type,
                        'scoringEngine',
                            v_round.scoring_engine
                    ),

                'counts',
                    jsonb_build_object(
                        'configs', 0,
                        'groups', 0,
                        'eligibleUnits', 0,
                        'assignedUnits', 0,
                        'errors', 1,
                        'warnings', 0
                    ),

                'errors',
                    jsonb_build_array(
                        jsonb_build_object(
                            'code',
                                'handler_validacion_no_implementado',
                            'message',
                                'El motor está registrado, pero su handler de validación aún no está implementado.',
                            'detail',
                                v_dispatch
                        )
                    ),

                'warnings',
                    '[]'::jsonb,

                'dispatch',
                    v_dispatch
            );
    END CASE;

    RETURN v_result || jsonb_build_object(
        'schemaVersion', 2,
        'validationHandler', v_handler,
        'dispatch', v_dispatch
    );
END;
$function$;


-- ============================================================================
-- 06. PRIVILEGIOS
-- ============================================================================
REVOKE ALL
ON FUNCTION public._previsualizar_validacion_salidas_tee_times_v1(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._previsualizar_validacion_salidas_tee_times_v1(uuid)
TO service_role;


COMMIT;
