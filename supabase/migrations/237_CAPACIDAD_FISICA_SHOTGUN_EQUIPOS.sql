-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 237
-- Shotgun por equipos: capacidad física por jugadores activos
--
-- OBJETIVO
--   Corregir el contrato de capacidad de los grupos Shotgun cuando
--   tipo_participacion = 'equipo'.
--
-- REGLA
--   ocupacion_fisica_grupo =
--       SUM(integrantes activos de cada equipo activo asignado)
--
--   ocupacion_fisica_grupo <= tamano_grupo_maximo
--
-- IMPORTANTE
--   - tamano_grupo_normal / tamano_grupo_maximo siguen representando JUGADORES.
--   - Individual conserva peso 1 por inscripción.
--   - Equipos incompletos son válidos: se cuenta su roster activo real.
--   - No se confía en un peso enviado por frontend.
--   - El payload existente de materializar_conformacion_shotgun no cambia.
--   - No modifica scoring, HCP TEAM, tarjetas, resultados, Stroke Play ni Stableford.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. HELPER PRIVADO: integrantes activos reales de un equipo
-- ============================================================================

CREATE OR REPLACE FUNCTION public._integrantes_activos_equipo_237(
    p_tournament_team_id uuid
)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT count(*)::integer
    FROM public.tournament_registrations reg
    WHERE reg.tournament_team_id = p_tournament_team_id
      AND reg.activo = true;
$function$;

REVOKE ALL ON FUNCTION public._integrantes_activos_equipo_237(uuid)
FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 2. TRIGGER EXISTENTE: máximo físico, no máximo de equipos
--
-- Se conserva toda la validación anterior:
--   - grupo existente
--   - Shotgun
--   - torneo por equipos
--   - configuración activa
--   - equipo activo / mismo torneo
--   - categoría coherente
--   - equipo único por ronda
--
-- ÚNICO CAMBIO DE SEMÁNTICA:
--   antes: count(tournament_group_teams) < tamano_grupo_maximo
--   ahora: jugadores activos ya asignados + jugadores activos del nuevo equipo
--          <= tamano_grupo_maximo
-- ============================================================================

CREATE OR REPLACE FUNCTION public.validar_group_team_reglas_shotgun()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_round_id               uuid;
    v_tournament_id          uuid;
    v_tipo_participacion     formato_juego_torneo;
    v_formato_salida         formato_salida_ronda;
    v_shotgun_hole_id        uuid;

    v_categoria_grupo        uuid;
    v_maximo_jugadores       integer;

    v_team_tournament_id     uuid;
    v_team_category_id       uuid;
    v_team_activo            boolean;

    v_num_categorias_torneo  integer;
    v_categoria_unica        uuid;

    v_ocupacion_actual       integer := 0;
    v_integrantes_nuevo      integer := 0;
    v_ocupacion_resultante   integer := 0;

    v_conflicto_ronda        integer;
BEGIN
    IF new.activo = false THEN
        RETURN new;
    END IF;

    SELECT
        tr.id,
        tr.tournament_id,
        tf.tipo_participacion,
        tr.formato_salida,
        g.tournament_shotgun_category_hole_id
    INTO
        v_round_id,
        v_tournament_id,
        v_tipo_participacion,
        v_formato_salida,
        v_shotgun_hole_id
    FROM public.tournament_groups g
    JOIN public.tournament_round_shifts trs
      ON trs.id = g.tournament_round_shift_id
    JOIN public.tournament_rounds tr
      ON tr.id = trs.tournament_round_id
    JOIN public.tournaments t
      ON t.id = tr.tournament_id
    JOIN public.tournament_formats tf
      ON tf.id = t.tournament_format_id
    WHERE g.id = new.tournament_group_id;

    IF v_round_id IS NULL THEN
        RAISE EXCEPTION
            'El grupo indicado no existe.';
    END IF;

    IF v_formato_salida IS DISTINCT FROM
       'shotgun'::formato_salida_ronda
       OR v_shotgun_hole_id IS NULL
    THEN
        RAISE EXCEPTION
            'La asignación mediante tournament_group_teams corresponde al nuevo modelo Shotgun.';
    END IF;

    IF v_tipo_participacion IS DISTINCT FROM 'equipo' THEN
        RAISE EXCEPTION
            'Este torneo es individual. Los participantes se asignan mediante tournament_group_players.';
    END IF;

    SELECT
        cfg.tamano_grupo_maximo,
        sc.tournament_category_id
    INTO
        v_maximo_jugadores,
        v_categoria_grupo
    FROM public.tournament_shotgun_category_holes sh
    JOIN public.tournament_shotgun_category_configs cfg
      ON cfg.id = sh.tournament_shotgun_category_config_id
    JOIN public.tournament_round_shift_categories sc
      ON sc.id = cfg.tournament_round_shift_category_id
    WHERE sh.id = v_shotgun_hole_id
      AND sh.activo = true
      AND cfg.activo = true
      AND sc.activo = true;

    IF v_maximo_jugadores IS NULL THEN
        RAISE EXCEPTION
            'No existe una configuración Shotgun activa para este grupo.';
    END IF;

    SELECT
        tt.tournament_id,
        tt.tournament_category_id,
        tt.activo
    INTO
        v_team_tournament_id,
        v_team_category_id,
        v_team_activo
    FROM public.tournament_teams tt
    WHERE tt.id = new.tournament_team_id;

    IF v_team_tournament_id IS NULL THEN
        RAISE EXCEPTION
            'El equipo indicado no existe.';
    END IF;

    IF v_team_activo = false THEN
        RAISE EXCEPTION
            'El equipo indicado está desactivado.';
    END IF;

    IF v_team_tournament_id IS DISTINCT FROM v_tournament_id THEN
        RAISE EXCEPTION
            'El equipo y el grupo pertenecen a torneos diferentes.';
    END IF;

    ---------------------------------------------------------------------------
    -- CATEGORÍA DEL EQUIPO
    ---------------------------------------------------------------------------
    IF v_team_category_id IS NULL THEN
        SELECT
            count(*),
            min(tc.id::text)::uuid
        INTO
            v_num_categorias_torneo,
            v_categoria_unica
        FROM public.tournament_categories tc
        WHERE tc.tournament_id = v_tournament_id;

        IF v_num_categorias_torneo <> 1 THEN
            RAISE EXCEPTION
                'El equipo no tiene categoría asignada y el torneo tiene más de una categoría.';
        END IF;

        IF v_categoria_unica IS DISTINCT FROM v_categoria_grupo THEN
            RAISE EXCEPTION
                'La categoría única del torneo no coincide con la categoría configurada para el grupo.';
        END IF;

    ELSIF v_team_category_id IS DISTINCT FROM v_categoria_grupo THEN
        RAISE EXCEPTION
            'El equipo no pertenece a la categoría configurada para este grupo.';
    END IF;

    ---------------------------------------------------------------------------
    -- CAPACIDAD FÍSICA DEL GRUPO
    --
    -- Excluye la misma asociación durante UPDATE y suma roster activo real.
    ---------------------------------------------------------------------------
    SELECT COALESCE(
        sum(public._integrantes_activos_equipo_237(gt.tournament_team_id)),
        0
    )::integer
    INTO v_ocupacion_actual
    FROM public.tournament_group_teams gt
    WHERE gt.tournament_group_id = new.tournament_group_id
      AND gt.activo = true
      AND gt.id IS DISTINCT FROM new.id;

    v_integrantes_nuevo :=
        public._integrantes_activos_equipo_237(new.tournament_team_id);

    v_ocupacion_resultante :=
        COALESCE(v_ocupacion_actual, 0) + COALESCE(v_integrantes_nuevo, 0);

    IF v_ocupacion_resultante > v_maximo_jugadores THEN
        RAISE EXCEPTION
            'El grupo excedería su máximo físico de % jugadores: ocupación actual %, equipo entrante %, resultado %.',
            v_maximo_jugadores,
            v_ocupacion_actual,
            v_integrantes_nuevo,
            v_ocupacion_resultante;
    END IF;

    ---------------------------------------------------------------------------
    -- EQUIPO ÚNICO POR RONDA
    ---------------------------------------------------------------------------
    SELECT count(*)
    INTO v_conflicto_ronda
    FROM public.tournament_group_teams gt
    JOIN public.tournament_groups g
      ON g.id = gt.tournament_group_id
    JOIN public.tournament_round_shifts trs
      ON trs.id = g.tournament_round_shift_id
    JOIN public.tournament_rounds tr
      ON tr.id = trs.tournament_round_id
    WHERE tr.id = v_round_id
      AND g.activo = true
      AND gt.activo = true
      AND gt.tournament_team_id = new.tournament_team_id
      AND gt.id IS DISTINCT FROM new.id;

    IF v_conflicto_ronda > 0 THEN
        RAISE EXCEPTION
            'Este equipo ya está asignado a otro grupo activo en esta ronda.';
    END IF;

    RETURN new;
END;
$function$;

-- ============================================================================
-- 3. ROUND_GROUPS: no declarar COMPLETE si existe sobrecupo físico
-- ============================================================================

CREATE OR REPLACE FUNCTION public._estado_conformacion_grupos_ronda_235(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_round record;
    v_tipo_participacion text;

    v_shift_count integer := 0;
    v_shift_category_count integer := 0;
    v_config_count integer := 0;
    v_group_count integer := 0;

    v_total_units integer := 0;
    v_assigned_units integer := 0;
    v_unassigned_units integer := 0;

    v_category_count integer := 0;
    v_single_category_id uuid := NULL;

    v_overcapacity_groups integer := 0;
    v_max_physical_occupancy integer := 0;

    v_status text;
    v_message text;
    v_recommendation text;
BEGIN
    SELECT
        tr.id,
        tr.tournament_id,
        tr.numero_ronda,
        tr.formato_salida::text AS start_format,
        tf.tipo_participacion::text AS tipo_participacion,
        tf.scoring_engine::text AS scoring_engine
    INTO v_round
    FROM public.tournament_rounds tr
    JOIN public.tournaments t
      ON t.id = tr.tournament_id
    JOIN public.tournament_formats tf
      ON tf.id = COALESCE(tr.tournament_format_id, t.tournament_format_id)
    WHERE tr.id = p_tournament_round_id
      AND tr.activo = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La ronda indicada no existe o no está activa.'
            USING ERRCODE = '22023';
    END IF;

    IF v_round.start_format IS DISTINCT FROM 'shotgun' THEN
        RETURN jsonb_build_object(
            'applicable', false,
            'status', 'NOT_APPLICABLE',
            'roundId', p_tournament_round_id,
            'roundNumber', v_round.numero_ronda,
            'startFormat', v_round.start_format
        );
    END IF;

    v_tipo_participacion := v_round.tipo_participacion;

    SELECT count(*)::integer
    INTO v_shift_count
    FROM public.tournament_round_shifts s
    WHERE s.tournament_round_id = p_tournament_round_id
      AND s.activo = true;

    SELECT
        count(*)::integer,
        count(DISTINCT sc.tournament_category_id)::integer,
        CASE
            WHEN count(DISTINCT sc.tournament_category_id) = 1
            THEN min(sc.tournament_category_id::text)::uuid
            ELSE NULL
        END
    INTO
        v_shift_category_count,
        v_category_count,
        v_single_category_id
    FROM public.tournament_round_shift_categories sc
    JOIN public.tournament_round_shifts s
      ON s.id = sc.tournament_round_shift_id
    WHERE s.tournament_round_id = p_tournament_round_id
      AND s.activo = true
      AND sc.activo = true;

    SELECT count(*)::integer
    INTO v_config_count
    FROM public.tournament_shotgun_category_configs cfg
    JOIN public.tournament_round_shift_categories sc
      ON sc.id = cfg.tournament_round_shift_category_id
    JOIN public.tournament_round_shifts s
      ON s.id = sc.tournament_round_shift_id
    WHERE s.tournament_round_id = p_tournament_round_id
      AND s.activo = true
      AND sc.activo = true
      AND cfg.activo = true;

    SELECT count(*)::integer
    INTO v_group_count
    FROM public.tournament_groups g
    JOIN public.tournament_round_shifts s
      ON s.id = g.tournament_round_shift_id
    WHERE s.tournament_round_id = p_tournament_round_id
      AND s.activo = true
      AND g.activo = true;

    IF v_tipo_participacion = 'individual' THEN
        SELECT count(*)::integer
        INTO v_total_units
        FROM public.tournament_registrations reg
        WHERE reg.tournament_id = v_round.tournament_id
          AND reg.activo = true
          AND EXISTS (
              SELECT 1
              FROM public.tournament_round_shift_categories sc
              JOIN public.tournament_round_shifts s
                ON s.id = sc.tournament_round_shift_id
              WHERE s.tournament_round_id = p_tournament_round_id
                AND s.activo = true
                AND sc.activo = true
                AND sc.tournament_category_id = reg.tournament_category_id
          );

        SELECT count(*)::integer
        INTO v_assigned_units
        FROM public.tournament_registrations reg
        WHERE reg.tournament_id = v_round.tournament_id
          AND reg.activo = true
          AND EXISTS (
              SELECT 1
              FROM public.tournament_round_shift_categories sc
              JOIN public.tournament_round_shifts s
                ON s.id = sc.tournament_round_shift_id
              WHERE s.tournament_round_id = p_tournament_round_id
                AND s.activo = true
                AND sc.activo = true
                AND sc.tournament_category_id = reg.tournament_category_id
          )
          AND EXISTS (
              SELECT 1
              FROM public.tournament_group_players gp
              JOIN public.tournament_groups g
                ON g.id = gp.tournament_group_id
              JOIN public.tournament_round_shifts s
                ON s.id = g.tournament_round_shift_id
              WHERE gp.tournament_registration_id = reg.id
                AND g.activo = true
                AND s.activo = true
                AND s.tournament_round_id = p_tournament_round_id
          );

    ELSIF v_tipo_participacion = 'equipo' THEN
        SELECT count(*)::integer
        INTO v_total_units
        FROM public.tournament_teams tt
        WHERE tt.tournament_id = v_round.tournament_id
          AND tt.activo = true
          AND (
              EXISTS (
                  SELECT 1
                  FROM public.tournament_round_shift_categories sc
                  JOIN public.tournament_round_shifts s
                    ON s.id = sc.tournament_round_shift_id
                  WHERE s.tournament_round_id = p_tournament_round_id
                    AND s.activo = true
                    AND sc.activo = true
                    AND sc.tournament_category_id = tt.tournament_category_id
              )
              OR (
                  tt.tournament_category_id IS NULL
                  AND v_category_count = 1
                  AND v_single_category_id IS NOT NULL
              )
          );

        SELECT count(*)::integer
        INTO v_assigned_units
        FROM public.tournament_teams tt
        WHERE tt.tournament_id = v_round.tournament_id
          AND tt.activo = true
          AND (
              EXISTS (
                  SELECT 1
                  FROM public.tournament_round_shift_categories sc
                  JOIN public.tournament_round_shifts s
                    ON s.id = sc.tournament_round_shift_id
                  WHERE s.tournament_round_id = p_tournament_round_id
                    AND s.activo = true
                    AND sc.activo = true
                    AND sc.tournament_category_id = tt.tournament_category_id
              )
              OR (
                  tt.tournament_category_id IS NULL
                  AND v_category_count = 1
                  AND v_single_category_id IS NOT NULL
              )
          )
          AND EXISTS (
              SELECT 1
              FROM public.tournament_group_teams gt
              JOIN public.tournament_groups g
                ON g.id = gt.tournament_group_id
              JOIN public.tournament_round_shifts s
                ON s.id = g.tournament_round_shift_id
              WHERE gt.tournament_team_id = tt.id
                AND gt.activo = true
                AND g.activo = true
                AND s.activo = true
                AND s.tournament_round_id = p_tournament_round_id
          );

        -- Verificación física de todos los grupos activos de la ronda.
        WITH physical AS (
            SELECT
                g.id AS group_id,
                cfg.tamano_grupo_maximo AS max_players,
                COALESCE(
                    sum(
                        public._integrantes_activos_equipo_237(
                            gt.tournament_team_id
                        )
                    ) FILTER (WHERE gt.activo = true),
                    0
                )::integer AS physical_occupancy
            FROM public.tournament_groups g
            JOIN public.tournament_round_shifts s
              ON s.id = g.tournament_round_shift_id
            JOIN public.tournament_shotgun_category_holes sh
              ON sh.id = g.tournament_shotgun_category_hole_id
            JOIN public.tournament_shotgun_category_configs cfg
              ON cfg.id = sh.tournament_shotgun_category_config_id
            LEFT JOIN public.tournament_group_teams gt
              ON gt.tournament_group_id = g.id
             AND gt.activo = true
            WHERE s.tournament_round_id = p_tournament_round_id
              AND s.activo = true
              AND g.activo = true
              AND sh.activo = true
              AND cfg.activo = true
            GROUP BY g.id, cfg.tamano_grupo_maximo
        )
        SELECT
            count(*) FILTER (
                WHERE physical_occupancy > max_players
            )::integer,
            COALESCE(max(physical_occupancy), 0)::integer
        INTO
            v_overcapacity_groups,
            v_max_physical_occupancy
        FROM physical;
    ELSE
        v_total_units := 0;
        v_assigned_units := 0;
    END IF;

    v_unassigned_units := GREATEST(v_total_units - v_assigned_units, 0);

    IF v_shift_count = 0 THEN
        v_status := 'BLOCKED';
        v_message := format(
            'La ronda %s no tiene turnos activos para preparar los grupos Shotgun.',
            v_round.numero_ronda
        );
        v_recommendation := 'Revisa la configuración estructural de la ronda.';

    ELSIF v_shift_category_count = 0 THEN
        v_status := 'BLOCKED';
        v_message := format(
            'La ronda %s no tiene categorías activas asignadas a sus turnos.',
            v_round.numero_ronda
        );
        v_recommendation := 'Revisa la configuración de categorías por turno.';

    ELSIF v_config_count = 0 THEN
        v_status := 'PENDING';
        v_message := format(
            'La ronda %s todavía no tiene configuración Shotgun materializada para conformar sus grupos.',
            v_round.numero_ronda
        );
        v_recommendation := 'Configura el Shotgun y conforma los grupos de la ronda.';

    ELSIF v_tipo_participacion = 'equipo'
          AND v_overcapacity_groups > 0
    THEN
        v_status := 'PENDING';
        v_message := format(
            'La ronda %s tiene %s grupo(s) que exceden la capacidad física máxima de jugadores.',
            v_round.numero_ronda,
            v_overcapacity_groups
        );
        v_recommendation :=
            'Redistribuye los equipos entre más posiciones de salida antes de continuar.';

    ELSIF v_group_count > 0 AND v_unassigned_units = 0 THEN
        v_status := 'COMPLETE';
        v_message := format(
            'Los grupos de la ronda %s están conformados: %s unidad(es) competitiva(s) asignada(s).',
            v_round.numero_ronda,
            v_assigned_units
        );
        v_recommendation := NULL;

    ELSE
        v_status := 'PENDING';
        v_message := format(
            'La ronda %s aún tiene %s de %s unidad(es) competitiva(s) sin grupo de salida.',
            v_round.numero_ronda,
            v_unassigned_units,
            v_total_units
        );
        v_recommendation :=
            'Completa la conformación de grupos antes de revisar y validar las salidas.';
    END IF;

    RETURN jsonb_build_object(
        'applicable', true,
        'status', v_status,
        'roundId', p_tournament_round_id,
        'roundNumber', v_round.numero_ronda,
        'startFormat', v_round.start_format,
        'tipoParticipacion', v_tipo_participacion,
        'scoringEngine', v_round.scoring_engine,
        'unitKind', CASE
            WHEN v_tipo_participacion = 'equipo' THEN 'TEAM'
            WHEN v_tipo_participacion = 'individual' THEN 'PLAYER'
            ELSE 'UNKNOWN'
        END,
        'shiftCount', v_shift_count,
        'shiftCategoryCount', v_shift_category_count,
        'shotgunConfigCount', v_config_count,
        'shotgunConfigured', v_config_count > 0,
        'activeGroups', v_group_count,
        'totalUnits', v_total_units,
        'assignedUnits', v_assigned_units,
        'unassignedUnits', v_unassigned_units,
        'overCapacityGroups', v_overcapacity_groups,
        'maxPhysicalOccupancy', v_max_physical_occupancy,
        'message', v_message,
        'recommendation', v_recommendation
    );
END;
$function$;

REVOKE ALL ON FUNCTION public._estado_conformacion_grupos_ronda_235(uuid)
FROM PUBLIC, anon, authenticated;

COMMIT;
