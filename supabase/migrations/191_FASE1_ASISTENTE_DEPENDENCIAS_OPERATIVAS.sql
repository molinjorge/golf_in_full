-- 191 FASE 1 — Asistente Operativo: dependencias operativas y acciones disponibles
-- Objetivo:
--   - Mantener intacta la semántica de estado calculada por el contrato v4.
--   - Añadir una capa explícita de disponibilidad operativa por paso.
--   - Evitar que pasos futuros (salidas, tarjetas, captura, cierre, finalización)
--     aparezcan como "siguiente acción" o como bloqueadores mientras no se cumplan
--     sus prerequisitos.
--   - No modificar freeze, snapshots, resultados, Stableford, cierres ni finalización.

BEGIN;

-- Preservar el contrato v4 actual como core interno.
ALTER FUNCTION public.obtener_asistente_operativo_torneo(uuid)
RENAME TO _obtener_asistente_operativo_torneo_v4_191;

REVOKE ALL ON FUNCTION public._obtener_asistente_operativo_torneo_v4_191(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._obtener_asistente_operativo_torneo_v4_191(uuid) FROM anon;
REVOKE ALL ON FUNCTION public._obtener_asistente_operativo_torneo_v4_191(uuid) FROM authenticated;

CREATE OR REPLACE FUNCTION public.obtener_asistente_operativo_torneo(
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
    v_steps jsonb := '[]'::jsonb;
    v_new_steps jsonb := '[]'::jsonb;
    v_blockers jsonb := '[]'::jsonb;
    v_next_action jsonb := NULL;

    v_config_complete boolean := false;
    v_confirmation_complete boolean := false;
    v_registrations_complete boolean := false;
    v_freeze_complete boolean := false;
    v_all_round_closes_complete boolean := true;

    v_round_starts jsonb := '{}'::jsonb;
    v_round_cards jsonb := '{}'::jsonb;
    v_round_scoring jsonb := '{}'::jsonb;

    v_elem jsonb;
    v_code text;
    v_round_id text;
    v_actionable boolean;
    v_waiting_for text;
    v_status text;
    v_action jsonb;
BEGIN
    -- Ejecuta íntegramente el contrato v4 primero. Esto conserva permisos,
    -- cálculo de estados, modalidad configurada y gates competitivos.
    v_result := public._obtener_asistente_operativo_torneo_v4_191(
        p_tournament_id
    );

    v_steps := COALESCE(v_result->'steps', '[]'::jsonb);

    -- Prerequisitos de torneo.
    SELECT COALESCE(bool_or(elem->>'code' = 'TOURNAMENT_CONFIGURATION'
                            AND elem->>'status' = 'COMPLETE'), false)
      INTO v_config_complete
      FROM jsonb_array_elements(v_steps) elem;

    SELECT COALESCE(bool_or(elem->>'code' = 'CONFIGURATION_CONFIRMATION'
                            AND elem->>'status' = 'COMPLETE'), false)
      INTO v_confirmation_complete
      FROM jsonb_array_elements(v_steps) elem;

    SELECT COALESCE(bool_or(elem->>'code' = 'REGISTRATIONS'
                            AND elem->>'status' = 'COMPLETE'), false)
      INTO v_registrations_complete
      FROM jsonb_array_elements(v_steps) elem;

    SELECT COALESCE(bool_or(elem->>'code' = 'FREEZE'
                            AND elem->>'status' = 'COMPLETE'), false)
      INTO v_freeze_complete
      FROM jsonb_array_elements(v_steps) elem;

    -- Estados por ronda usados como prerequisitos de la siguiente fase de esa ronda.
    SELECT COALESCE(jsonb_object_agg(round_id, is_complete), '{}'::jsonb)
      INTO v_round_starts
      FROM (
          SELECT
              elem->>'roundId' AS round_id,
              (elem->>'status' = 'COMPLETE') AS is_complete
          FROM jsonb_array_elements(v_steps) elem
          WHERE elem->>'code' = 'ROUND_STARTS'
            AND elem ? 'roundId'
      ) s;

    SELECT COALESCE(jsonb_object_agg(round_id, is_complete), '{}'::jsonb)
      INTO v_round_cards
      FROM (
          SELECT
              elem->>'roundId' AS round_id,
              (elem->>'status' = 'COMPLETE') AS is_complete
          FROM jsonb_array_elements(v_steps) elem
          WHERE elem->>'code' = 'SCORECARD_EMISSION'
            AND elem ? 'roundId'
      ) s;

    SELECT COALESCE(jsonb_object_agg(round_id, is_complete), '{}'::jsonb)
      INTO v_round_scoring
      FROM (
          SELECT
              elem->>'roundId' AS round_id,
              (elem->>'status' = 'COMPLETE') AS is_complete
          FROM jsonb_array_elements(v_steps) elem
          WHERE elem->>'code' = 'ROUND_SCORING'
            AND elem ? 'roundId'
      ) s;

    SELECT COALESCE(bool_and(elem->>'status' = 'COMPLETE'), false)
      INTO v_all_round_closes_complete
      FROM jsonb_array_elements(v_steps) elem
     WHERE elem->>'code' = 'ROUND_COMPETITIVE_CLOSE';

    -- Añadir availability sin reescribir los estados de negocio existentes.
    FOR v_elem IN
        SELECT elem
        FROM jsonb_array_elements(v_steps) elem
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
                IF NOT v_actionable THEN v_waiting_for := 'TOURNAMENT_CONFIGURATION'; END IF;

            WHEN 'REGISTRATIONS' THEN
                v_actionable := v_config_complete AND v_confirmation_complete;
                IF NOT v_config_complete THEN
                    v_waiting_for := 'TOURNAMENT_CONFIGURATION';
                ELSIF NOT v_confirmation_complete THEN
                    v_waiting_for := 'CONFIGURATION_CONFIRMATION';
                END IF;

            WHEN 'FREEZE' THEN
                v_actionable := v_registrations_complete;
                IF NOT v_actionable THEN v_waiting_for := 'REGISTRATIONS'; END IF;

            WHEN 'ROUND_STARTS' THEN
                v_actionable := v_freeze_complete;
                IF NOT v_actionable THEN v_waiting_for := 'FREEZE'; END IF;

            WHEN 'SCORECARD_EMISSION' THEN
                v_actionable := COALESCE((v_round_starts->>v_round_id)::boolean, false);
                IF NOT v_actionable THEN v_waiting_for := 'ROUND_STARTS'; END IF;

            WHEN 'ROUND_SCORING' THEN
                v_actionable := COALESCE((v_round_cards->>v_round_id)::boolean, false);
                IF NOT v_actionable THEN v_waiting_for := 'SCORECARD_EMISSION'; END IF;

            WHEN 'ROUND_COMPETITIVE_CLOSE' THEN
                v_actionable := COALESCE((v_round_scoring->>v_round_id)::boolean, false);
                IF NOT v_actionable THEN v_waiting_for := 'ROUND_SCORING'; END IF;

            WHEN 'TOURNAMENT_FINALIZATION' THEN
                v_actionable := v_all_round_closes_complete;
                IF NOT v_actionable THEN v_waiting_for := 'ROUND_COMPETITIVE_CLOSE'; END IF;

            ELSE
                v_actionable := true;
        END CASE;

        v_elem := v_elem || jsonb_build_object(
            'availability', jsonb_build_object(
                'actionable', v_actionable,
                'state', CASE WHEN v_actionable THEN 'AVAILABLE' ELSE 'WAITING' END,
                'waitingFor', v_waiting_for
            )
        );

        -- Un paso futuro no debe ofrecer CTA aunque internamente tenga un action.
        IF NOT v_actionable THEN
            v_elem := jsonb_set(v_elem, '{action}', 'null'::jsonb, true);
        END IF;

        v_new_steps := v_new_steps || jsonb_build_array(v_elem);
    END LOOP;

    -- Sólo los bloqueos de pasos actualmente accionables bloquean el avance.
    SELECT COALESCE(jsonb_agg(s.elem ORDER BY s.ord), '[]'::jsonb)
      INTO v_blockers
      FROM jsonb_array_elements(v_new_steps)
           WITH ORDINALITY AS s(elem, ord)
     WHERE s.elem->>'status' = 'BLOCKED'
       AND COALESCE((s.elem #>> '{availability,actionable}')::boolean, false);

    -- Siguiente acción = primera acción disponible en el flujo visual.
    -- No se priorizan bloqueos de fases futuras.
    SELECT s.elem->'action'
      INTO v_next_action
      FROM jsonb_array_elements(v_new_steps)
           WITH ORDINALITY AS s(elem, ord)
     WHERE s.elem->>'status' IN ('BLOCKED', 'PENDING')
       AND COALESCE((s.elem #>> '{availability,actionable}')::boolean, false)
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

    RETURN v_result || jsonb_build_object('schemaVersion', 5);
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_asistente_operativo_torneo(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_asistente_operativo_torneo(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_asistente_operativo_torneo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_asistente_operativo_torneo(uuid) TO service_role;

COMMIT;
