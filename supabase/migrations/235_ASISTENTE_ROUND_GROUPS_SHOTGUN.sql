-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 235
-- Asistente Operativo: etapa ROUND_GROUPS para rondas Shotgun
--
-- OBJETIVO
--   Modelar explícitamente:
--       FREEZE -> ROUND_GROUPS -> ROUND_STARTS
--   sin modificar la conformación Shotgun ni la validación de salidas.
--
-- PRINCIPIOS
--   - Sólo rondas Shotgun reciben ROUND_GROUPS.
--   - Individual: unidad competitiva = inscripción activa.
--   - Equipos: unidad competitiva = equipo activo.
--   - Equipos incompletos siguen siendo válidos.
--   - La ausencia de configuración Shotgun es PENDING, no BLOCKED:
--     se resuelve precisamente desde "Armar grupos".
--   - No cambia el flujo de rondas no-Shotgun.
--   - No modifica frontend; target='armar-grupos' ya existe.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. HELPER PRIVADO DE ÁMBITO RONDA
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

    IF v_round.start_format <> 'shotgun' THEN
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
    ELSE
        -- Motor/modalidad desconocida para esta fase: no fingir conformación.
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
        v_recommendation := 'Completa la conformación de grupos antes de revisar y validar las salidas.';
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
        'message', v_message,
        'recommendation', v_recommendation
    );
END;
$function$;

REVOKE ALL ON FUNCTION public._estado_conformacion_grupos_ronda_235(uuid)
FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 2. ASISTENTE v6
--
-- Se conserva la fuente de estados de negocio usada por v5:
--   _obtener_asistente_operativo_torneo_v4_191(...)
--
-- La nueva capa:
--   a) inserta ROUND_GROUPS inmediatamente antes de ROUND_STARTS sólo si
--      startFormat='shotgun';
--   b) aplica la misma lógica de availability del contrato v5;
--   c) cambia únicamente la dependencia de ROUND_STARTS en Shotgun:
--        ROUND_GROUPS COMPLETE -> ROUND_STARTS disponible.
-- ============================================================================

CREATE OR REPLACE FUNCTION public._obtener_asistente_operativo_torneo_v6_235(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_result jsonb;
    v_source_steps jsonb := '[]'::jsonb;
    v_steps_with_groups jsonb := '[]'::jsonb;
    v_new_steps jsonb := '[]'::jsonb;
    v_blockers jsonb := '[]'::jsonb;
    v_next_action jsonb := NULL;

    v_config_complete boolean := false;
    v_confirmation_complete boolean := false;
    v_registrations_complete boolean := false;
    v_freeze_complete boolean := false;
    v_all_round_closes_complete boolean := true;

    v_round_groups jsonb := '{}'::jsonb;
    v_round_starts jsonb := '{}'::jsonb;
    v_round_cards jsonb := '{}'::jsonb;
    v_round_scoring jsonb := '{}'::jsonb;

    v_elem jsonb;
    v_code text;
    v_round_id text;
    v_actionable boolean;
    v_waiting_for text;
    v_status text;

    v_groups_state jsonb;
    v_groups_step jsonb;
BEGIN
    -- Mismo contrato base que consumía obtener_asistente_operativo_torneo antes
    -- de esta migración. Conserva permisos y cálculo de todos los estados previos.
    v_result := public._obtener_asistente_operativo_torneo_v4_191(
        p_tournament_id
    );

    v_source_steps := COALESCE(v_result->'steps', '[]'::jsonb);

    ---------------------------------------------------------------------------
    -- Insertar ROUND_GROUPS antes de ROUND_STARTS únicamente en Shotgun.
    ---------------------------------------------------------------------------
    FOR v_elem IN
        SELECT elem
        FROM jsonb_array_elements(v_source_steps) elem
    LOOP
        IF v_elem->>'code' = 'ROUND_STARTS'
           AND lower(COALESCE(v_elem #>> '{details,startFormat}', '')) = 'shotgun'
           AND v_elem ? 'roundId'
        THEN
            v_groups_state :=
                public._estado_conformacion_grupos_ronda_235(
                    (v_elem->>'roundId')::uuid
                );

            v_groups_step := jsonb_build_object(
                'code', 'ROUND_GROUPS',
                'scope', 'ROUND',
                'roundId', v_elem->>'roundId',
                'roundNumber', v_elem->'roundNumber',
                'title', format(
                    'Ronda %s · Armar grupos',
                    COALESCE(v_elem->>'roundNumber', '?')
                ),
                'status', v_groups_state->>'status',
                'message', v_groups_state->>'message',
                'recommendation', v_groups_state->>'recommendation',
                'details', v_groups_state - 'message' - 'recommendation' - 'status',
                'action', jsonb_build_object(
                    'label', 'Armar grupos',
                    'target', 'armar-grupos',
                    'roundId', v_elem->>'roundId'
                ),
                'requiredRole', 'TOURNAMENT_OPERATOR'
            );

            v_steps_with_groups :=
                v_steps_with_groups || jsonb_build_array(v_groups_step);
        END IF;

        v_steps_with_groups :=
            v_steps_with_groups || jsonb_build_array(v_elem);
    END LOOP;

    ---------------------------------------------------------------------------
    -- Prerrequisitos de torneo (idénticos al contrato v5).
    ---------------------------------------------------------------------------
    SELECT COALESCE(bool_or(elem->>'code' = 'TOURNAMENT_CONFIGURATION'
                            AND elem->>'status' = 'COMPLETE'), false)
      INTO v_config_complete
      FROM jsonb_array_elements(v_steps_with_groups) elem;

    SELECT COALESCE(bool_or(elem->>'code' = 'CONFIGURATION_CONFIRMATION'
                            AND elem->>'status' = 'COMPLETE'), false)
      INTO v_confirmation_complete
      FROM jsonb_array_elements(v_steps_with_groups) elem;

    SELECT COALESCE(bool_or(elem->>'code' = 'REGISTRATIONS'
                            AND elem->>'status' = 'COMPLETE'), false)
      INTO v_registrations_complete
      FROM jsonb_array_elements(v_steps_with_groups) elem;

    SELECT COALESCE(bool_or(elem->>'code' = 'FREEZE'
                            AND elem->>'status' = 'COMPLETE'), false)
      INTO v_freeze_complete
      FROM jsonb_array_elements(v_steps_with_groups) elem;

    ---------------------------------------------------------------------------
    -- Estados por ronda.
    ---------------------------------------------------------------------------
    SELECT COALESCE(jsonb_object_agg(round_id, is_complete), '{}'::jsonb)
      INTO v_round_groups
      FROM (
          SELECT
              elem->>'roundId' AS round_id,
              (elem->>'status' = 'COMPLETE') AS is_complete
          FROM jsonb_array_elements(v_steps_with_groups) elem
          WHERE elem->>'code' = 'ROUND_GROUPS'
            AND elem ? 'roundId'
      ) s;

    SELECT COALESCE(jsonb_object_agg(round_id, is_complete), '{}'::jsonb)
      INTO v_round_starts
      FROM (
          SELECT
              elem->>'roundId' AS round_id,
              (elem->>'status' = 'COMPLETE') AS is_complete
          FROM jsonb_array_elements(v_steps_with_groups) elem
          WHERE elem->>'code' = 'ROUND_STARTS'
            AND elem ? 'roundId'
      ) s;

    SELECT COALESCE(jsonb_object_agg(round_id, is_complete), '{}'::jsonb)
      INTO v_round_cards
      FROM (
          SELECT
              elem->>'roundId' AS round_id,
              (elem->>'status' = 'COMPLETE') AS is_complete
          FROM jsonb_array_elements(v_steps_with_groups) elem
          WHERE elem->>'code' = 'SCORECARD_EMISSION'
            AND elem ? 'roundId'
      ) s;

    SELECT COALESCE(jsonb_object_agg(round_id, is_complete), '{}'::jsonb)
      INTO v_round_scoring
      FROM (
          SELECT
              elem->>'roundId' AS round_id,
              (elem->>'status' = 'COMPLETE') AS is_complete
          FROM jsonb_array_elements(v_steps_with_groups) elem
          WHERE elem->>'code' = 'ROUND_SCORING'
            AND elem ? 'roundId'
      ) s;

    SELECT COALESCE(bool_and(elem->>'status' = 'COMPLETE'), false)
      INTO v_all_round_closes_complete
      FROM jsonb_array_elements(v_steps_with_groups) elem
     WHERE elem->>'code' = 'ROUND_COMPETITIVE_CLOSE';

    ---------------------------------------------------------------------------
    -- Availability: mismo modelo v5 + nueva dependencia ROUND_GROUPS.
    ---------------------------------------------------------------------------
    FOR v_elem IN
        SELECT elem
        FROM jsonb_array_elements(v_steps_with_groups) elem
    LOOP
        v_code := v_elem->>'code';
        v_round_id := v_elem->>'roundId';
        v_status := v_elem->>'status';
        v_actionable := true;
        v_waiting_for := NULL;

        CASE v_code
            WHEN 'TOURNAMENT_CONFIGURATION' THEN
                v_actionable := true;

            WHEN 'CONFIGURATION_CONFIRMATION' THEN
                v_actionable := v_config_complete;
                IF NOT v_actionable THEN
                    v_waiting_for := 'TOURNAMENT_CONFIGURATION';
                END IF;

            WHEN 'REGISTRATIONS' THEN
                v_actionable := v_config_complete AND v_confirmation_complete;
                IF NOT v_config_complete THEN
                    v_waiting_for := 'TOURNAMENT_CONFIGURATION';
                ELSIF NOT v_confirmation_complete THEN
                    v_waiting_for := 'CONFIGURATION_CONFIRMATION';
                END IF;

            WHEN 'FREEZE' THEN
                v_actionable := v_registrations_complete;
                IF NOT v_actionable THEN
                    v_waiting_for := 'REGISTRATIONS';
                END IF;

            WHEN 'ROUND_GROUPS' THEN
                v_actionable := v_freeze_complete;
                IF NOT v_actionable THEN
                    v_waiting_for := 'FREEZE';
                END IF;

            WHEN 'ROUND_STARTS' THEN
                IF v_round_groups ? v_round_id THEN
                    v_actionable :=
                        COALESCE((v_round_groups->>v_round_id)::boolean, false);
                    IF NOT v_actionable THEN
                        v_waiting_for := 'ROUND_GROUPS';
                    END IF;
                ELSE
                    -- No-Shotgun: preservar exactamente el contrato anterior.
                    v_actionable := v_freeze_complete;
                    IF NOT v_actionable THEN
                        v_waiting_for := 'FREEZE';
                    END IF;
                END IF;

            WHEN 'SCORECARD_EMISSION' THEN
                v_actionable :=
                    COALESCE((v_round_starts->>v_round_id)::boolean, false);
                IF NOT v_actionable THEN
                    v_waiting_for := 'ROUND_STARTS';
                END IF;

            WHEN 'ROUND_SCORING' THEN
                v_actionable :=
                    COALESCE((v_round_cards->>v_round_id)::boolean, false);
                IF NOT v_actionable THEN
                    v_waiting_for := 'SCORECARD_EMISSION';
                END IF;

            WHEN 'ROUND_COMPETITIVE_CLOSE' THEN
                v_actionable :=
                    COALESCE((v_round_scoring->>v_round_id)::boolean, false);
                IF NOT v_actionable THEN
                    v_waiting_for := 'ROUND_SCORING';
                END IF;

            WHEN 'TOURNAMENT_FINALIZATION' THEN
                v_actionable := v_all_round_closes_complete;
                IF NOT v_actionable THEN
                    v_waiting_for := 'ROUND_COMPETITIVE_CLOSE';
                END IF;

            ELSE
                v_actionable := true;
        END CASE;

        v_elem := v_elem || jsonb_build_object(
            'availability', jsonb_build_object(
                'actionable', v_actionable,
                'state',
                    CASE
                        WHEN v_actionable THEN 'AVAILABLE'
                        ELSE 'WAITING'
                    END,
                'waitingFor', v_waiting_for
            )
        );

        IF NOT v_actionable THEN
            v_elem := jsonb_set(
                v_elem,
                '{action}',
                'null'::jsonb,
                true
            );
        END IF;

        v_new_steps := v_new_steps || jsonb_build_array(v_elem);
    END LOOP;

    ---------------------------------------------------------------------------
    -- Blockers accionables y siguiente acción: mismo criterio v5.
    ---------------------------------------------------------------------------
    SELECT COALESCE(jsonb_agg(s.elem ORDER BY s.ord), '[]'::jsonb)
      INTO v_blockers
      FROM jsonb_array_elements(v_new_steps)
           WITH ORDINALITY AS s(elem, ord)
     WHERE s.elem->>'status' = 'BLOCKED'
       AND COALESCE(
           (s.elem #>> '{availability,actionable}')::boolean,
           false
       );

    SELECT s.elem->'action'
      INTO v_next_action
      FROM jsonb_array_elements(v_new_steps)
           WITH ORDINALITY AS s(elem, ord)
     WHERE s.elem->>'status' IN ('BLOCKED', 'PENDING')
       AND COALESCE(
           (s.elem #>> '{availability,actionable}')::boolean,
           false
       )
       AND s.elem->'action' IS NOT NULL
       AND s.elem->'action' <> 'null'::jsonb
     ORDER BY s.ord
     LIMIT 1;

    v_result := jsonb_set(v_result, '{steps}', v_new_steps, true);
    v_result := jsonb_set(v_result, '{blockers}', v_blockers, true);
    v_result := jsonb_set(
        v_result,
        '{summary,blockingIssues}',
        to_jsonb(jsonb_array_length(v_blockers)),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{nextAction}',
        COALESCE(v_next_action, 'null'::jsonb),
        true
    );

    RETURN v_result || jsonb_build_object('schemaVersion', 6);
END;
$function$;

REVOKE ALL ON FUNCTION public._obtener_asistente_operativo_torneo_v6_235(uuid)
FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 3. RPC PÚBLICA: MISMA FIRMA, NUEVO CONTRATO v6
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_asistente_operativo_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RETURN public._obtener_asistente_operativo_torneo_v6_235(
        p_tournament_id
    );
END;
$function$;

-- Mantener exposición únicamente para operadores autenticados / service role.
REVOKE ALL ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
TO authenticated, service_role;

COMMIT;
