-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 244
-- A-Go-Go: contrato HCP TEAM obligatorio + Asistente Operativo + reparación
-- controlada de freezes Gross-only históricos sin HCP TEAM
-- ============================================================================
-- OBJETIVO
-- 1) Alinear el freeze con validación/emisión TEAM: todo A-Go-Go/team_stroke
--    debe tener configuración HCP TEAM y versiones CURRENT por ronda/equipo.
-- 2) Mantener la regla: si existe clasificación Neto, GROSS_ONLY no es válido.
-- 3) Agregar al Asistente Operativo un paso HCP TEAM por ronda antes de grupos.
-- 4) Permitir reparar, de forma explícita y auditada, freezes Gross-only ya
--    existentes sin configuración HCP TEAM, creando GROSS_ONLY y versiones 0.
-- 5) No modificar Stroke Play, Stableford, scoring, resultados ni tarjetas.
--
-- IMPORTANTE
-- - La reparación NO se ejecuta automáticamente.
-- - La reparación sólo procede antes de cualquier validación/emisión/tarjeta.
-- - Los grupos Shotgun ya armados pueden existir; no se modifican.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Estado HCP TEAM por ronda para el Asistente Operativo
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._estado_hcp_team_ronda_244(
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
    v_config public.tournament_team_handicap_configs%ROWTYPE;
    v_total integer := 0;
    v_current integer := 0;
    v_missing integer := 0;
    v_stale integer := 0;
    v_status text;
    v_message text;
    v_recommendation text;
BEGIN
    SELECT
        tr.id,
        tr.tournament_id,
        tr.numero_ronda,
        tf.code::text AS format_code,
        tf.tipo_participacion::text AS participation_type,
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

    IF v_round.format_code IS DISTINCT FROM 'A_GOGO'
       OR v_round.participation_type IS DISTINCT FROM 'equipo'
       OR v_round.scoring_engine IS DISTINCT FROM 'team_stroke'
    THEN
        RETURN jsonb_build_object(
            'applicable', false,
            'status', 'NOT_APPLICABLE',
            'roundId', p_tournament_round_id,
            'roundNumber', v_round.numero_ronda,
            'formatCode', v_round.format_code,
            'participationType', v_round.participation_type,
            'scoringEngine', v_round.scoring_engine
        );
    END IF;

    SELECT *
    INTO v_config
    FROM public.tournament_team_handicap_configs c
    WHERE c.tournament_id = v_round.tournament_id
      AND c.active = true
    ORDER BY c.created_at DESC, c.id
    LIMIT 1;

    SELECT count(*)::integer
    INTO v_total
    FROM public.tournament_teams tt
    WHERE tt.tournament_id = v_round.tournament_id
      AND tt.activo = true
      AND EXISTS (
          SELECT 1
          FROM public.tournament_registrations reg
          WHERE reg.tournament_id = v_round.tournament_id
            AND reg.tournament_team_id = tt.id
            AND reg.activo = true
      );

    IF v_config.id IS NULL THEN
        v_current := 0;
        v_missing := v_total;
        v_stale := 0;
    ELSE
        WITH teams AS (
            SELECT tt.id
            FROM public.tournament_teams tt
            WHERE tt.tournament_id = v_round.tournament_id
              AND tt.activo = true
              AND EXISTS (
                  SELECT 1
                  FROM public.tournament_registrations reg
                  WHERE reg.tournament_id = v_round.tournament_id
                    AND reg.tournament_team_id = tt.id
                    AND reg.activo = true
              )
        ), latest_active AS (
            SELECT
                t.id AS team_id,
                hv.id AS version_id,
                hv.config_id,
                hv.is_stale
            FROM teams t
            LEFT JOIN LATERAL (
                SELECT v.*
                FROM public.tournament_round_team_handicap_versions v
                WHERE v.tournament_round_id = p_tournament_round_id
                  AND v.tournament_team_id = t.id
                  AND v.status = 'active'
                ORDER BY v.version DESC, v.created_at DESC, v.id
                LIMIT 1
            ) hv ON true
        )
        SELECT
            count(*) FILTER (
                WHERE version_id IS NOT NULL
                  AND COALESCE(is_stale, false) = false
                  AND config_id = v_config.id
            )::integer,
            count(*) FILTER (
                WHERE version_id IS NULL
            )::integer,
            count(*) FILTER (
                WHERE version_id IS NOT NULL
                  AND (
                      COALESCE(is_stale, false) = true
                      OR config_id IS DISTINCT FROM v_config.id
                  )
            )::integer
        INTO v_current, v_missing, v_stale
        FROM latest_active;
    END IF;

    IF v_config.id IS NULL THEN
        v_status := 'BLOCKED';
        v_message := format(
            'La ronda %s no tiene configuración activa de HCP TEAM.',
            v_round.numero_ronda
        );
        v_recommendation :=
            'Configura HCP TEAM y recalcula los equipos antes de continuar.';
    ELSIF v_total = 0 THEN
        v_status := 'PENDING';
        v_message := format(
            'La ronda %s no tiene equipos activos con integrantes para calcular HCP TEAM.',
            v_round.numero_ronda
        );
        v_recommendation := 'Revisa la composición de equipos del torneo.';
    ELSIF v_missing > 0 OR v_stale > 0 THEN
        v_status := 'PENDING';
        v_message := format(
            'HCP TEAM pendiente en ronda %s: %s CURRENT, %s MISSING y %s STALE.',
            v_round.numero_ronda,
            v_current,
            v_missing,
            v_stale
        );
        v_recommendation :=
            'Recalcula los HCP TEAM pendientes antes de armar/validar salidas.';
    ELSE
        v_status := 'COMPLETE';
        v_message := format(
            'HCP TEAM completo para la ronda %s: %s equipo(s) CURRENT.',
            v_round.numero_ronda,
            v_current
        );
        v_recommendation := NULL;
    END IF;

    RETURN jsonb_build_object(
        'applicable', true,
        'status', v_status,
        'roundId', p_tournament_round_id,
        'roundNumber', v_round.numero_ronda,
        'formatCode', v_round.format_code,
        'participationType', v_round.participation_type,
        'scoringEngine', v_round.scoring_engine,
        'configured', v_config.id IS NOT NULL,
        'configId', v_config.id,
        'method', v_config.method,
        'totalTeams', v_total,
        'currentTeams', v_current,
        'missingTeams', v_missing,
        'staleTeams', v_stale,
        'message', v_message,
        'recommendation', v_recommendation
    );
END;
$function$;

REVOKE ALL ON FUNCTION public._estado_hcp_team_ronda_244(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._estado_hcp_team_ronda_244(uuid) FROM anon;
REVOKE ALL ON FUNCTION public._estado_hcp_team_ronda_244(uuid) FROM authenticated;

-- ---------------------------------------------------------------------------
-- 2. Freeze: todo A-Go-Go TEAM necesita contrato HCP TEAM consistente
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.previsualizar_congelamiento_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base jsonb;
    v_extra_errors jsonb;
    v_extra_count integer;
    v_team_hcp_errors jsonb := '[]'::jsonb;
    v_team_hcp_count integer := 0;
    v_team_hcp_state_errors jsonb := '[]'::jsonb;
    v_team_hcp_state_count integer := 0;
    v_is_team_stroke boolean := false;
    v_has_neto boolean := false;
    v_config public.tournament_team_handicap_configs%ROWTYPE;
    v_range_count integer := 0;
BEGIN
    v_base := public._previsualizar_congelamiento_torneo_core_218(
        p_tournament_id
    );

    SELECT
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'code', 'category_classification_missing',
                    'message', format(
                        'La categoría %s no tiene clasificación competitiva definida (Gross, Neto o ambas).',
                        c.nombre
                    ),
                    'tournamentCategoryId', tc.id
                )
                ORDER BY c.display_order NULLS LAST, c.nombre, tc.id
            ),
            '[]'::jsonb
        ),
        count(*)::integer
    INTO v_extra_errors, v_extra_count
    FROM public.tournament_categories tc
    JOIN public.categories c ON c.id = tc.category_id
    WHERE tc.tournament_id = p_tournament_id
      AND NOT EXISTS (
          SELECT 1
          FROM public.tournament_category_classifications cc
          WHERE cc.tournament_category_id = tc.id
            AND cc.tournament_id = tc.tournament_id
      );

    SELECT EXISTS (
        SELECT 1
        FROM public.tournament_rounds tr
        JOIN public.tournaments t ON t.id = tr.tournament_id
        JOIN public.tournament_formats tf
          ON tf.id = COALESCE(tr.tournament_format_id, t.tournament_format_id)
        WHERE tr.tournament_id = p_tournament_id
          AND tr.activo = true
          AND tf.tipo_participacion::text = 'equipo'
          AND tf.scoring_engine::text = 'team_stroke'
    ) INTO v_is_team_stroke;

    SELECT EXISTS (
        SELECT 1
        FROM public.tournament_category_classifications cc
        WHERE cc.tournament_id = p_tournament_id
          AND cc.tipo_resultado::text = 'neto'
    ) INTO v_has_neto;

    -- 244: TODO team_stroke requiere configuración HCP TEAM, aunque sea Gross.
    -- Para Gross-only, GROSS_ONLY es válido y produce versión auditable 0.
    IF v_is_team_stroke THEN
        SELECT *
        INTO v_config
        FROM public.tournament_team_handicap_configs c
        WHERE c.tournament_id = p_tournament_id
          AND c.active = true
        ORDER BY c.created_at DESC, c.id
        LIMIT 1;

        IF v_config.id IS NULL THEN
            v_team_hcp_errors := v_team_hcp_errors || jsonb_build_array(
                jsonb_build_object(
                    'code', 'team_hcp_config_missing',
                    'message',
                        CASE
                            WHEN v_has_neto THEN
                                'El torneo A-Go-Go incluye clasificación Neto y debe configurar el método de HCP TEAM antes de congelar.'
                            ELSE
                                'El torneo A-Go-Go debe configurar HCP TEAM antes de congelar. Para Gross-only puede utilizar GROSS_ONLY.'
                        END
                )
            );
            v_team_hcp_count := v_team_hcp_count + 1;

        ELSIF v_has_neto AND v_config.method = 'GROSS_ONLY' THEN
            v_team_hcp_errors := v_team_hcp_errors || jsonb_build_array(
                jsonb_build_object(
                    'code', 'team_hcp_gross_only_incompatible',
                    'message', 'El torneo A-Go-Go incluye clasificación Neto; el método HCP TEAM no puede ser GROSS_ONLY.'
                )
            );
            v_team_hcp_count := v_team_hcp_count + 1;

        ELSIF v_config.method = 'AVERAGE_HI_PCT'
              AND (
                  v_config.average_pct IS NULL
                  OR v_config.average_pct < 0
                  OR v_config.average_pct > 100
              ) THEN
            v_team_hcp_errors := v_team_hcp_errors || jsonb_build_array(
                jsonb_build_object(
                    'code', 'team_hcp_average_pct_invalid',
                    'message', 'El método AVERAGE_HI_PCT requiere un porcentaje válido entre 0 y 100 antes de congelar.'
                )
            );
            v_team_hcp_count := v_team_hcp_count + 1;

        ELSIF v_config.method = 'ASSIGNED_TABLE_SUM_HI' THEN
            SELECT count(*)::integer
            INTO v_range_count
            FROM public.tournament_team_handicap_ranges r
            WHERE r.config_id = v_config.id;

            IF v_range_count = 0 THEN
                v_team_hcp_errors := v_team_hcp_errors || jsonb_build_array(
                    jsonb_build_object(
                        'code', 'team_hcp_ranges_missing',
                        'message', 'El método ASSIGNED_TABLE_SUM_HI requiere al menos un rango de HCP TEAM antes de congelar.',
                        'configId', v_config.id
                    )
                );
                v_team_hcp_count := v_team_hcp_count + 1;
            END IF;
        END IF;

        IF v_team_hcp_count = 0 THEN
            WITH team_rounds AS (
                SELECT tr.id AS round_id, tr.numero_ronda
                FROM public.tournament_rounds tr
                JOIN public.tournaments t ON t.id = tr.tournament_id
                JOIN public.tournament_formats tf
                  ON tf.id = COALESCE(tr.tournament_format_id, t.tournament_format_id)
                WHERE tr.tournament_id = p_tournament_id
                  AND tr.activo = true
                  AND tf.tipo_participacion::text = 'equipo'
                  AND tf.scoring_engine::text = 'team_stroke'
            ), active_teams AS (
                SELECT tt.id AS team_id, tt.nombre_equipo
                FROM public.tournament_teams tt
                WHERE tt.tournament_id = p_tournament_id
                  AND tt.activo = true
                  AND EXISTS (
                      SELECT 1
                      FROM public.tournament_registrations reg
                      WHERE reg.tournament_id = p_tournament_id
                        AND reg.tournament_team_id = tt.id
                        AND reg.activo = true
                  )
            ), team_round_state AS (
                SELECT
                    r.round_id,
                    r.numero_ronda,
                    t.team_id,
                    t.nombre_equipo,
                    v.id AS version_id,
                    v.config_id,
                    v.is_stale
                FROM team_rounds r
                CROSS JOIN active_teams t
                LEFT JOIN LATERAL (
                    SELECT hv.*
                    FROM public.tournament_round_team_handicap_versions hv
                    WHERE hv.tournament_round_id = r.round_id
                      AND hv.tournament_team_id = t.team_id
                      AND hv.status = 'active'
                    ORDER BY hv.version DESC, hv.created_at DESC, hv.id
                    LIMIT 1
                ) v ON true
            ), invalid_states AS (
                SELECT
                    s.*,
                    CASE
                        WHEN s.version_id IS NULL THEN 'MISSING'
                        ELSE 'STALE'
                    END AS hcp_state
                FROM team_round_state s
                WHERE s.version_id IS NULL
                   OR COALESCE(s.is_stale, false) = true
                   OR s.config_id IS DISTINCT FROM v_config.id
            )
            SELECT
                COALESCE(
                    jsonb_agg(
                        jsonb_build_object(
                            'code',
                                CASE
                                    WHEN i.hcp_state = 'MISSING'
                                    THEN 'team_hcp_missing_before_freeze'
                                    ELSE 'team_hcp_stale_before_freeze'
                                END,
                            'message',
                                CASE
                                    WHEN i.hcp_state = 'MISSING'
                                    THEN format(
                                        'El equipo %s no tiene HCP TEAM calculado para la ronda %s. Recalcula los HCP TEAM pendientes antes de congelar.',
                                        i.nombre_equipo, i.numero_ronda
                                    )
                                    ELSE format(
                                        'El HCP TEAM del equipo %s está pendiente de recalcular para la ronda %s. Recalcula los HCP TEAM pendientes antes de congelar.',
                                        i.nombre_equipo, i.numero_ronda
                                    )
                                END,
                            'roundId', i.round_id,
                            'teamId', i.team_id,
                            'teamName', i.nombre_equipo,
                            'state', i.hcp_state
                        )
                        ORDER BY i.numero_ronda, i.nombre_equipo, i.team_id
                    ),
                    '[]'::jsonb
                ),
                count(*)::integer
            INTO v_team_hcp_state_errors, v_team_hcp_state_count
            FROM invalid_states i;
        END IF;
    END IF;

    RETURN
        v_base
        || jsonb_build_object(
            'ready',
                COALESCE((v_base->>'ready')::boolean, false)
                AND v_extra_count = 0
                AND v_team_hcp_count = 0
                AND v_team_hcp_state_count = 0,
            'errors',
                COALESCE(v_base->'errors', '[]'::jsonb)
                || v_extra_errors
                || v_team_hcp_errors
                || v_team_hcp_state_errors,
            'counts',
                COALESCE(v_base->'counts', '{}'::jsonb)
                || jsonb_build_object(
                    'errors',
                        COALESCE((v_base #>> '{counts,errors}')::integer, 0)
                        + v_extra_count
                        + v_team_hcp_count
                        + v_team_hcp_state_count
                )
        );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. Asistente Operativo v7: HCP TEAM entre Freeze y Grupos
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._obtener_asistente_operativo_torneo_v7_244(
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
    v_steps_with_hcp jsonb := '[]'::jsonb;
    v_final_steps jsonb := '[]'::jsonb;
    v_blockers jsonb := '[]'::jsonb;
    v_next_action jsonb := NULL;

    v_elem jsonb;
    v_hcp_state jsonb;
    v_hcp_step jsonb;
    v_round_id text;
    v_code text;
    v_status text;
    v_actionable boolean;
    v_waiting_for text;

    v_freeze_complete boolean := false;
    v_round_hcp jsonb := '{}'::jsonb;
    v_round_groups jsonb := '{}'::jsonb;
BEGIN
    v_result := public._obtener_asistente_operativo_torneo_v6_235(
        p_tournament_id
    );

    v_source_steps := COALESCE(v_result->'steps', '[]'::jsonb);

    -- Inserta HCP TEAM inmediatamente antes de ROUND_GROUPS cuando aplica.
    FOR v_elem IN
        SELECT elem FROM jsonb_array_elements(v_source_steps) elem
    LOOP
        IF v_elem->>'code' = 'ROUND_GROUPS'
           AND v_elem ? 'roundId'
        THEN
            v_hcp_state := public._estado_hcp_team_ronda_244(
                (v_elem->>'roundId')::uuid
            );

            IF COALESCE((v_hcp_state->>'applicable')::boolean, false) THEN
                v_hcp_step := jsonb_build_object(
                    'code', 'ROUND_TEAM_HCP',
                    'scope', 'ROUND',
                    'roundId', v_elem->>'roundId',
                    'roundNumber', v_elem->'roundNumber',
                    'title', format(
                        'Ronda %s · HCP TEAM',
                        COALESCE(v_elem->>'roundNumber', '?')
                    ),
                    'status', v_hcp_state->>'status',
                    'message', v_hcp_state->>'message',
                    'recommendation', v_hcp_state->>'recommendation',
                    'details', v_hcp_state - 'message' - 'recommendation' - 'status',
                    'action', jsonb_build_object(
                        'label', 'Revisar HCP TEAM',
                        'target', 'equipos',
                        'roundId', v_elem->>'roundId'
                    ),
                    'requiredRole', 'TOURNAMENT_OPERATOR'
                );

                v_steps_with_hcp :=
                    v_steps_with_hcp || jsonb_build_array(v_hcp_step);
            END IF;
        END IF;

        v_steps_with_hcp :=
            v_steps_with_hcp || jsonb_build_array(v_elem);
    END LOOP;

    SELECT COALESCE(bool_or(
        elem->>'code' = 'FREEZE' AND elem->>'status' = 'COMPLETE'
    ), false)
    INTO v_freeze_complete
    FROM jsonb_array_elements(v_steps_with_hcp) elem;

    SELECT COALESCE(jsonb_object_agg(round_id, is_complete), '{}'::jsonb)
    INTO v_round_hcp
    FROM (
        SELECT
            elem->>'roundId' AS round_id,
            (elem->>'status' = 'COMPLETE') AS is_complete
        FROM jsonb_array_elements(v_steps_with_hcp) elem
        WHERE elem->>'code' = 'ROUND_TEAM_HCP'
          AND elem ? 'roundId'
    ) s;

    SELECT COALESCE(jsonb_object_agg(round_id, is_complete), '{}'::jsonb)
    INTO v_round_groups
    FROM (
        SELECT
            elem->>'roundId' AS round_id,
            (elem->>'status' = 'COMPLETE') AS is_complete
        FROM jsonb_array_elements(v_steps_with_hcp) elem
        WHERE elem->>'code' = 'ROUND_GROUPS'
          AND elem ? 'roundId'
    ) s;

    -- Recalcula sólo las dependencias afectadas. El resto conserva v6.
    FOR v_elem IN
        SELECT elem FROM jsonb_array_elements(v_steps_with_hcp) elem
    LOOP
        v_code := v_elem->>'code';
        v_round_id := v_elem->>'roundId';
        v_status := v_elem->>'status';

        IF v_code = 'ROUND_TEAM_HCP' THEN
            v_actionable := v_freeze_complete;
            v_waiting_for := CASE WHEN v_actionable THEN NULL ELSE 'FREEZE' END;

            v_elem := v_elem || jsonb_build_object(
                'availability', jsonb_build_object(
                    'actionable', v_actionable,
                    'state', CASE WHEN v_actionable THEN 'AVAILABLE' ELSE 'WAITING' END,
                    'waitingFor', v_waiting_for
                )
            );

            IF NOT v_actionable THEN
                v_elem := jsonb_set(v_elem, '{action}', 'null'::jsonb, true);
            END IF;

        ELSIF v_code = 'ROUND_GROUPS'
              AND v_round_hcp ? v_round_id
        THEN
            v_actionable :=
                v_freeze_complete
                AND COALESCE((v_round_hcp->>v_round_id)::boolean, false);

            IF NOT v_freeze_complete THEN
                v_waiting_for := 'FREEZE';
            ELSIF NOT COALESCE((v_round_hcp->>v_round_id)::boolean, false) THEN
                v_waiting_for := 'ROUND_TEAM_HCP';
            ELSE
                v_waiting_for := NULL;
            END IF;

            v_elem := v_elem || jsonb_build_object(
                'availability', jsonb_build_object(
                    'actionable', v_actionable,
                    'state', CASE WHEN v_actionable THEN 'AVAILABLE' ELSE 'WAITING' END,
                    'waitingFor', v_waiting_for
                )
            );

            IF NOT v_actionable THEN
                v_elem := jsonb_set(v_elem, '{action}', 'null'::jsonb, true);
            END IF;

        ELSIF v_code = 'ROUND_STARTS'
              AND v_round_hcp ? v_round_id
        THEN
            v_actionable :=
                COALESCE((v_round_hcp->>v_round_id)::boolean, false)
                AND COALESCE((v_round_groups->>v_round_id)::boolean, false);

            IF NOT COALESCE((v_round_hcp->>v_round_id)::boolean, false) THEN
                v_waiting_for := 'ROUND_TEAM_HCP';
            ELSIF NOT COALESCE((v_round_groups->>v_round_id)::boolean, false) THEN
                v_waiting_for := 'ROUND_GROUPS';
            ELSE
                v_waiting_for := NULL;
            END IF;

            v_elem := v_elem || jsonb_build_object(
                'availability', jsonb_build_object(
                    'actionable', v_actionable,
                    'state', CASE WHEN v_actionable THEN 'AVAILABLE' ELSE 'WAITING' END,
                    'waitingFor', v_waiting_for
                )
            );

            IF NOT v_actionable THEN
                v_elem := jsonb_set(v_elem, '{action}', 'null'::jsonb, true);
            END IF;
        END IF;

        v_final_steps := v_final_steps || jsonb_build_array(v_elem);
    END LOOP;

    SELECT COALESCE(jsonb_agg(s.elem ORDER BY s.ord), '[]'::jsonb)
    INTO v_blockers
    FROM jsonb_array_elements(v_final_steps)
         WITH ORDINALITY AS s(elem, ord)
    WHERE s.elem->>'status' = 'BLOCKED'
      AND COALESCE(
          (s.elem #>> '{availability,actionable}')::boolean,
          false
      );

    SELECT s.elem->'action'
    INTO v_next_action
    FROM jsonb_array_elements(v_final_steps)
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

    v_result := jsonb_set(v_result, '{steps}', v_final_steps, true);
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

    RETURN v_result || jsonb_build_object('schemaVersion', 7);
END;
$function$;

REVOKE ALL ON FUNCTION public._obtener_asistente_operativo_torneo_v7_244(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._obtener_asistente_operativo_torneo_v7_244(uuid) FROM anon;
REVOKE ALL ON FUNCTION public._obtener_asistente_operativo_torneo_v7_244(uuid) FROM authenticated;

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
    RETURN public._obtener_asistente_operativo_torneo_v7_244(
        p_tournament_id
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Reparación explícita para freezes Gross-only ya creados sin HCP TEAM
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reparar_hcp_team_gross_only_freeze_244(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_admin_id uuid;
    v_freeze_id uuid;
    v_config_id uuid;
    v_round record;
    v_round_result jsonb;
    v_round_results jsonb := '[]'::jsonb;
    v_round_count integer := 0;
    v_team_count integer := 0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para reparar este torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT au.id
    INTO v_admin_id
    FROM public.admin_users au
    WHERE au.auth_user_id = auth.uid()
      AND au.activo = true
    ORDER BY au.id
    LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No existe administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_tournament_id::text, 244)
    );

    PERFORM 1
    FROM public.tournaments t
    WHERE t.id = p_tournament_id
      AND t.activo = true
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo no existe o está inactivo.'
            USING ERRCODE = '22023';
    END IF;

    SELECT f.id
    INTO v_freeze_id
    FROM public.tournament_condition_freezes f
    WHERE f.tournament_id = p_tournament_id
    LIMIT 1;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION
            'La reparación 244 sólo aplica a un torneo ya congelado.'
            USING ERRCODE = '55000';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.tournament_round_condition_snapshots rcs
        WHERE rcs.freeze_id = v_freeze_id
    ) THEN
        RAISE EXCEPTION 'El freeze no contiene snapshots de ronda.'
            USING ERRCODE = '55000';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_round_condition_snapshots rcs
        WHERE rcs.freeze_id = v_freeze_id
          AND (
              rcs.format_code IS DISTINCT FROM 'A_GOGO'
              OR rcs.participation_type IS DISTINCT FROM 'equipo'
              OR rcs.scoring_engine IS DISTINCT FROM 'team_stroke'
          )
    ) THEN
        RAISE EXCEPTION
            'La reparación 244 sólo aplica a freezes exclusivamente A_GOGO/equipo/team_stroke.'
            USING ERRCODE = '55000';
    END IF;

    -- Debe ser Gross-only en el snapshot congelado.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_category_classification_snapshots ccs
        WHERE ccs.freeze_id = v_freeze_id
          AND ccs.tipo_resultado::text = 'neto'
    ) THEN
        RAISE EXCEPTION
            'La reparación Gross-only 244 no aplica porque el freeze contiene clasificación Neto.'
            USING ERRCODE = '55000';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.tournament_category_classification_snapshots ccs
        WHERE ccs.freeze_id = v_freeze_id
          AND ccs.tipo_resultado::text = 'gross'
    ) THEN
        RAISE EXCEPTION
            'El freeze no contiene clasificación Gross válida.'
            USING ERRCODE = '55000';
    END IF;

    -- Sólo repara el hueco exacto: nunca hubo configuración/versiones TEAM HCP.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_team_handicap_configs c
        WHERE c.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'El torneo ya tiene o tuvo configuración HCP TEAM; no procede la reparación 244.'
            USING ERRCODE = '55000';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_round_team_handicap_versions v
        WHERE v.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'El torneo ya tiene versiones HCP TEAM; no procede la reparación 244.'
            USING ERRCODE = '55000';
    END IF;

    -- Puede haber grupos armados, pero todavía no debe existir evidencia formal.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_round_start_validations v
        WHERE v.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'Ya existe historial de validación de salidas; no procede la reparación 244.'
            USING ERRCODE = '55000';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_score_card_emissions e
        WHERE e.tournament_id = p_tournament_id
    ) OR EXISTS (
        SELECT 1
        FROM public.tournament_score_cards sc
        WHERE sc.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'Ya existe historial de emisión/tarjetas; no procede la reparación 244.'
            USING ERRCODE = '55000';
    END IF;

    INSERT INTO public.tournament_team_handicap_configs(
        tournament_id,
        method,
        average_pct,
        rounding_mode,
        active,
        created_by,
        updated_by
    )
    VALUES(
        p_tournament_id,
        'GROSS_ONLY',
        NULL,
        'NEAREST_INTEGER',
        true,
        v_admin_id,
        v_admin_id
    )
    RETURNING id INTO v_config_id;

    FOR v_round IN
        SELECT tr.id, tr.numero_ronda
        FROM public.tournament_rounds tr
        WHERE tr.tournament_id = p_tournament_id
          AND tr.activo = true
        ORDER BY tr.numero_ronda, tr.id
    LOOP
        v_round_result := public.recalcular_handicaps_equipos_a_gogo_ronda(
            v_round.id
        );

        v_round_results := v_round_results || jsonb_build_array(
            jsonb_build_object(
                'roundId', v_round.id,
                'roundNumber', v_round.numero_ronda,
                'result', v_round_result
            )
        );

        v_round_count := v_round_count + 1;
        v_team_count := v_team_count
            + COALESCE((v_round_result->>'recalculatedCount')::integer, 0);
    END LOOP;

    INSERT INTO public.audit_log(
        tabla,
        registro_id,
        accion,
        realizado_por,
        datos_nuevos
    )
    VALUES(
        'tournament_team_handicap_configs',
        v_config_id,
        'INSERT',
        v_admin_id,
        jsonb_build_object(
            'repairCode', 'MIGRATION_244_GROSS_ONLY_FREEZE_REPAIR',
            'tournamentId', p_tournament_id,
            'freezeId', v_freeze_id,
            'configId', v_config_id,
            'method', 'GROSS_ONLY',
            'roundsRecalculated', v_round_count,
            'teamVersionsCreated', v_team_count,
            'reason',
                'Reparación controlada de freeze A-Go-Go Gross-only creado sin contrato HCP TEAM, antes de validación/emisión.'
        )
    );

    RETURN jsonb_build_object(
        'ok', true,
        'repairCode', 'MIGRATION_244_GROSS_ONLY_FREEZE_REPAIR',
        'tournamentId', p_tournament_id,
        'freezeId', v_freeze_id,
        'configId', v_config_id,
        'method', 'GROSS_ONLY',
        'roundsRecalculated', v_round_count,
        'teamVersionsCreated', v_team_count,
        'roundResults', v_round_results
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.reparar_hcp_team_gross_only_freeze_244(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reparar_hcp_team_gross_only_freeze_244(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.reparar_hcp_team_gross_only_freeze_244(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reparar_hcp_team_gross_only_freeze_244(uuid) TO service_role;

COMMIT;
