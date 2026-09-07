-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 260
-- Asistente operativo v13:
-- START_TOURNAMENT antes de captura y guard de ROUND_SCORING
-- ============================================================
--
-- OBJETIVO
-- 1) Corregir el orden del Asistente: INICIAR TORNEO debe aparecer
--    después de tarjetas/preparación y antes de la primera captura.
-- 2) Evitar que ROUND_SCORING sea accionable antes del inicio formal.
-- 3) Preservar íntegramente la lógica existente de Stroke Play,
--    Stableford y A-Go-Go.
--
-- IMPORTANTE
-- - No modifica motores competitivos.
-- - No modifica tablas ni datos.
-- - No altera la regla actual de ARMAR GRUPOS:
--      * cualquier ronda Shotgun individual (Stroke/Stableford) conserva
--        ROUND_GROUPS mediante v6_235;
--      * A-Go-Go TEAM Shotgun conserva HCP TEAM + ROUND_GROUPS.
-- - TEAM + Tee Times sigue fuera de alcance.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._obtener_asistente_operativo_torneo_v13_260(
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
    v_without_start jsonb := '[]'::jsonb;
    v_final_steps jsonb := '[]'::jsonb;

    v_elem jsonb;
    v_start_step jsonb := NULL;
    v_start_state jsonb;
    v_started boolean := false;
    v_current_actionable boolean := false;

    v_pivot_ord bigint;
    v_max_ord bigint;

    v_blockers jsonb := '[]'::jsonb;
    v_next_action jsonb := NULL;
    v_total integer := 0;
    v_completed integer := 0;
BEGIN
    -- Preserva TODO el contrato existente hasta v12.
    v_result :=
        public._obtener_asistente_operativo_torneo_v12_256(
            p_tournament_id
        );

    v_source_steps := COALESCE(v_result->'steps', '[]'::jsonb);

    -- Fuente de verdad del inicio formal.
    v_start_state :=
        public.obtener_estado_inicio_torneo_256(p_tournament_id);

    v_started := COALESCE(
        (v_start_state->>'alreadyStarted')::boolean,
        false
    );

    ---------------------------------------------------------------------------
    -- 1. Retirar temporalmente START_TOURNAMENT de la posición incorrecta
    --    heredada de v12.
    --
    -- 2. Mientras el torneo NO haya iniciado:
    --    si ROUND_SCORING ya sería accionable por sus prerrequisitos anteriores,
    --    convertirlo en WAITING por START_TOURNAMENT.
    --
    --    Si ROUND_SCORING ya estaba esperando Tarjetas u otro prerrequisito,
    --    se conserva exactamente esa espera; no se tapa el problema anterior.
    ---------------------------------------------------------------------------
    FOR v_elem IN
        SELECT elem
        FROM jsonb_array_elements(v_source_steps) AS x(elem)
    LOOP
        IF v_elem->>'code' = 'START_TOURNAMENT' THEN
            v_start_step := v_elem;
            CONTINUE;
        END IF;

        IF v_elem->>'code' = 'ROUND_SCORING'
           AND NOT v_started
        THEN
            v_current_actionable := COALESCE(
                (v_elem #>> '{availability,actionable}')::boolean,
                true
            );

            IF v_current_actionable THEN
                v_elem :=
                    v_elem
                    || jsonb_build_object(
                        'availability',
                        jsonb_build_object(
                            'actionable', false,
                            'state', 'WAITING',
                            'waitingFor', 'START_TOURNAMENT'
                        )
                    );

                v_elem := jsonb_set(
                    v_elem,
                    '{action}',
                    'null'::jsonb,
                    true
                );
            END IF;
        END IF;

        v_without_start :=
            v_without_start || jsonb_build_array(v_elem);
    END LOOP;

    IF v_start_step IS NULL THEN
        RAISE EXCEPTION
            'El contrato v12 no devolvió START_TOURNAMENT.'
            USING ERRCODE = '55000';
    END IF;

    ---------------------------------------------------------------------------
    -- Reinsertar START_TOURNAMENT:
    --   prioridad 1: inmediatamente antes del PRIMER ROUND_SCORING;
    --   fallback: antes de TOURNAMENT_FINALIZATION;
    --   último fallback: al final.
    ---------------------------------------------------------------------------
    SELECT min(ord)
      INTO v_pivot_ord
      FROM jsonb_array_elements(v_without_start)
           WITH ORDINALITY AS s(elem, ord)
     WHERE s.elem->>'code' = 'ROUND_SCORING';

    IF v_pivot_ord IS NULL THEN
        SELECT min(ord)
          INTO v_pivot_ord
          FROM jsonb_array_elements(v_without_start)
               WITH ORDINALITY AS s(elem, ord)
         WHERE s.elem->>'code' = 'TOURNAMENT_FINALIZATION';
    END IF;

    SELECT COALESCE(max(ord), 0)
      INTO v_max_ord
      FROM jsonb_array_elements(v_without_start)
           WITH ORDINALITY AS s(elem, ord);

    WITH expanded AS (
        SELECT elem, ord
        FROM jsonb_array_elements(v_without_start)
             WITH ORDINALITY AS s(elem, ord)
    ),
    combined AS (
        SELECT
            e.elem,
            CASE
                WHEN v_pivot_ord IS NULL THEN e.ord
                WHEN e.ord < v_pivot_ord THEN e.ord
                ELSE e.ord + 1
            END AS sort_key
        FROM expanded e

        UNION ALL

        SELECT
            v_start_step,
            CASE
                WHEN v_pivot_ord IS NULL
                    THEN v_max_ord + 1
                ELSE v_pivot_ord
            END AS sort_key
    )
    SELECT COALESCE(
        jsonb_agg(elem ORDER BY sort_key),
        '[]'::jsonb
    )
      INTO v_final_steps
      FROM combined;

    ---------------------------------------------------------------------------
    -- Recalcular blockers, nextAction y progreso con el orden corregido.
    ---------------------------------------------------------------------------
    SELECT COALESCE(
        jsonb_agg(s.elem ORDER BY s.ord),
        '[]'::jsonb
    )
      INTO v_blockers
      FROM jsonb_array_elements(v_final_steps)
           WITH ORDINALITY AS s(elem, ord)
     WHERE s.elem->>'status' = 'BLOCKED'
       AND COALESCE(
           (s.elem #>> '{availability,actionable}')::boolean,
           true
       );

    SELECT s.elem->'action'
      INTO v_next_action
      FROM jsonb_array_elements(v_final_steps)
           WITH ORDINALITY AS s(elem, ord)
     WHERE s.elem->>'status' IN ('BLOCKED', 'PENDING')
       AND s.elem->'action' IS NOT NULL
       AND s.elem->'action' <> 'null'::jsonb
       AND COALESCE(
           (s.elem #>> '{availability,actionable}')::boolean,
           true
       )
     ORDER BY s.ord
     LIMIT 1;

    SELECT
        count(*)::integer,
        count(*) FILTER (
            WHERE elem->>'status' = 'COMPLETE'
        )::integer
      INTO v_total, v_completed
      FROM jsonb_array_elements(v_final_steps) AS x(elem);

    v_result :=
        jsonb_set(v_result, '{steps}', v_final_steps, true);

    v_result :=
        jsonb_set(v_result, '{blockers}', v_blockers, true);

    v_result :=
        jsonb_set(
            v_result,
            '{summary,blockingIssues}',
            to_jsonb(jsonb_array_length(v_blockers)),
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{progress,completed}',
            to_jsonb(v_completed),
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{progress,total}',
            to_jsonb(v_total),
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{progress,percent}',
            to_jsonb(
                CASE
                    WHEN v_total = 0 THEN 0
                    ELSE round(
                        100.0 * v_completed / v_total,
                        0
                    )
                END
            ),
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{nextAction}',
            COALESCE(v_next_action, 'null'::jsonb),
            true
        );

    RETURN
        v_result
        || jsonb_build_object('schemaVersion', 13);
END;
$function$;

COMMENT ON FUNCTION
public._obtener_asistente_operativo_torneo_v13_260(uuid)
IS
'M260: corrige el orden del Asistente. START_TOURNAMENT se ubica antes del primer ROUND_SCORING y la captura queda en espera hasta el inicio formal, sin alterar motores ni la lógica Shotgun/Stableford/TEAM existente.';

-- Helper interno: no se expone al cliente.
REVOKE ALL
ON FUNCTION public._obtener_asistente_operativo_torneo_v13_260(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._obtener_asistente_operativo_torneo_v13_260(uuid)
TO postgres, service_role;

-- El RPC público conserva firma/ACL y ahora delega en v13.
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
    RETURN
        public._obtener_asistente_operativo_torneo_v13_260(
            p_tournament_id
        );
END;
$function$;

COMMENT ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
IS
'M260: Asistente operativo schemaVersion 13; START_TOURNAMENT antes de captura competitiva.';

COMMIT;
