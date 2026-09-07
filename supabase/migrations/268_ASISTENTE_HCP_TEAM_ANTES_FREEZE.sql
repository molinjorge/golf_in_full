-- ============================================================
-- MIGRACIÓN 268
-- ASISTENTE: HCP TEAM ANTES DEL CONGELAMIENTO
-- ============================================================
-- Objetivo:
--   Alinear el orden del Asistente Operativo con el contrato real
--   del congelamiento A-Go-Go:
--
--     Inscripciones cerradas
--       -> Rondas completas
--       -> HCP TEAM CURRENT
--       -> Congelar condiciones
--       -> Armar grupos
--
-- Diagnóstico:
--   El preview de congelamiento (_previsualizar_congelamiento_torneo_pre258)
--   exige, para A-Go-Go/team_stroke:
--     - configuración HCP TEAM válida;
--     - una versión HCP TEAM activa y no STALE por equipo/ronda.
--
--   Sin embargo, el Asistente heredado desde v7_244 colocaba
--   ROUND_TEAM_HCP después de FREEZE y lo hacía accionable sólo
--   cuando FREEZE ya estaba completo, creando una dependencia circular.
--
-- Alcance:
--   - NO cambia el freeze.
--   - NO cambia cálculo ni vigencia HCP TEAM.
--   - NO cambia grupos, salidas, tarjetas, scoring ni resultados.
--   - NO modifica datos.
--   - Sólo corrige orden, disponibilidad, waitingFor y nextAction
--     del Asistente Operativo.
-- ============================================================

CREATE OR REPLACE FUNCTION public._obtener_asistente_operativo_torneo_v20_268(
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
    v_steps_without_hcp jsonb := '[]'::jsonb;
    v_final_steps jsonb := '[]'::jsonb;
    v_hcp_steps jsonb := '[]'::jsonb;

    v_elem jsonb;
    v_hcp_elem jsonb;

    v_registrations_complete boolean := false;
    v_round_configuration_complete boolean := false;
    v_all_hcp_complete boolean := true;
    v_has_hcp_steps boolean := false;

    v_original_freeze_actionable boolean := false;
    v_original_freeze_waiting_for text;

    v_blockers jsonb := '[]'::jsonb;
    v_next_action jsonb := NULL;
    v_total integer := 0;
    v_completed integer := 0;
BEGIN
    -- Partimos del contrato público interno vigente hasta 266.
    v_result :=
        public._obtener_asistente_operativo_torneo_v19_266(
            p_tournament_id
        );

    v_source_steps := COALESCE(v_result->'steps','[]'::jsonb);

    -- Estado de prerrequisitos anteriores al HCP TEAM.
    SELECT COALESCE(bool_or(
        elem->>'code'='REGISTRATIONS'
        AND elem->>'status'='COMPLETE'
    ), false)
    INTO v_registrations_complete
    FROM jsonb_array_elements(v_source_steps) x(elem);

    SELECT COALESCE(bool_or(
        elem->>'code'='ROUND_CONFIGURATION'
        AND elem->>'status'='COMPLETE'
    ), false)
    INTO v_round_configuration_complete
    FROM jsonb_array_elements(v_source_steps) x(elem);

    -- Extraer los pasos HCP TEAM de su posición heredada.
    FOR v_elem IN
        SELECT elem
        FROM jsonb_array_elements(v_source_steps) x(elem)
    LOOP
        IF v_elem->>'code'='ROUND_TEAM_HCP' THEN
            v_has_hcp_steps := true;

            -- HCP TEAM sólo debe ser accionable cuando ya cerraron
            -- inscripciones y la configuración estructural de rondas
            -- está completa. Ya NO depende de FREEZE.
            IF v_elem->>'status'='COMPLETE' THEN
                v_elem := jsonb_set(
                    v_elem,
                    '{availability}',
                    jsonb_build_object(
                        'actionable',false,
                        'state','COMPLETE',
                        'waitingFor',NULL
                    ),
                    true
                );
                v_elem := jsonb_set(
                    v_elem,
                    '{action}',
                    'null'::jsonb,
                    true
                );

            ELSIF NOT v_registrations_complete THEN
                v_elem := jsonb_set(
                    v_elem,
                    '{availability}',
                    jsonb_build_object(
                        'actionable',false,
                        'state','WAITING',
                        'waitingFor','REGISTRATIONS'
                    ),
                    true
                );
                v_elem := jsonb_set(
                    v_elem,
                    '{action}',
                    'null'::jsonb,
                    true
                );

            ELSIF NOT v_round_configuration_complete THEN
                v_elem := jsonb_set(
                    v_elem,
                    '{availability}',
                    jsonb_build_object(
                        'actionable',false,
                        'state','WAITING',
                        'waitingFor','ROUND_CONFIGURATION'
                    ),
                    true
                );
                v_elem := jsonb_set(
                    v_elem,
                    '{action}',
                    'null'::jsonb,
                    true
                );

            ELSE
                v_elem := jsonb_set(
                    v_elem,
                    '{availability}',
                    jsonb_build_object(
                        'actionable',true,
                        'state','AVAILABLE',
                        'waitingFor',NULL
                    ),
                    true
                );

                -- Restaurar acción si una versión heredada la anuló
                -- exclusivamente por esperar FREEZE.
                IF v_elem->'action' IS NULL
                   OR v_elem->'action'='null'::jsonb
                THEN
                    v_elem := jsonb_set(
                        v_elem,
                        '{action}',
                        jsonb_build_object(
                            'label','Revisar HCP TEAM',
                            'target','equipos',
                            'roundId',v_elem->>'roundId'
                        ),
                        true
                    );
                END IF;
            END IF;

            v_hcp_steps :=
                v_hcp_steps || jsonb_build_array(v_elem);
        ELSE
            v_steps_without_hcp :=
                v_steps_without_hcp || jsonb_build_array(v_elem);
        END IF;
    END LOOP;

    IF v_has_hcp_steps THEN
        SELECT COALESCE(bool_and(elem->>'status'='COMPLETE'), false)
        INTO v_all_hcp_complete
        FROM jsonb_array_elements(v_hcp_steps) x(elem);
    ELSE
        v_all_hcp_complete := true;
    END IF;

    -- Reconstruir únicamente el orden:
    -- insertar todos los ROUND_TEAM_HCP inmediatamente antes de FREEZE.
    FOR v_elem IN
        SELECT elem
        FROM jsonb_array_elements(v_steps_without_hcp) x(elem)
    LOOP
        IF v_elem->>'code'='FREEZE' AND v_has_hcp_steps THEN
            FOR v_hcp_elem IN
                SELECT elem
                FROM jsonb_array_elements(v_hcp_steps) h(elem)
            LOOP
                v_final_steps :=
                    v_final_steps || jsonb_build_array(v_hcp_elem);
            END LOOP;

            -- Si FREEZE ya estaba COMPLETE, no crear deuda retroactiva.
            IF v_elem->>'status'<>'COMPLETE'
               AND NOT v_all_hcp_complete
            THEN
                v_original_freeze_actionable := COALESCE(
                    (v_elem#>>'{availability,actionable}')::boolean,
                    false
                );
                v_original_freeze_waiting_for :=
                    NULLIF(v_elem#>>'{availability,waitingFor}','');

                -- Sólo sustituir la dependencia si FREEZE ya había
                -- superado sus prerrequisitos anteriores.
                IF v_original_freeze_actionable
                   OR v_original_freeze_waiting_for IS NULL
                THEN
                    v_elem := jsonb_set(
                        v_elem,
                        '{availability}',
                        jsonb_build_object(
                            'actionable',false,
                            'state','WAITING',
                            'waitingFor','ROUND_TEAM_HCP'
                        ),
                        true
                    );
                    v_elem := jsonb_set(
                        v_elem,
                        '{action}',
                        'null'::jsonb,
                        true
                    );
                    v_elem := jsonb_set(
                        v_elem,
                        '{message}',
                        to_jsonb(
                            'El congelamiento espera a que todos los HCP TEAM requeridos estén vigentes.'::text
                        ),
                        true
                    );
                    v_elem := jsonb_set(
                        v_elem,
                        '{recommendation}',
                        to_jsonb(
                            'Completa o recalcula primero los HCP TEAM pendientes de todas las rondas A-Go-Go.'::text
                        ),
                        true
                    );
                END IF;
            END IF;
        END IF;

        v_final_steps :=
            v_final_steps || jsonb_build_array(v_elem);
    END LOOP;

    -- Recalcular blockers, nextAction y progreso sobre el nuevo orden.
    SELECT COALESCE(
        jsonb_agg(s.elem ORDER BY s.ord),
        '[]'::jsonb
    )
    INTO v_blockers
    FROM jsonb_array_elements(v_final_steps)
         WITH ORDINALITY AS s(elem,ord)
    WHERE s.elem->>'status'='BLOCKED'
      AND COALESCE(
          (s.elem#>>'{availability,actionable}')::boolean,
          true
      );

    SELECT s.elem->'action'
    INTO v_next_action
    FROM jsonb_array_elements(v_final_steps)
         WITH ORDINALITY AS s(elem,ord)
    WHERE s.elem->>'status' IN('BLOCKED','PENDING')
      AND s.elem->'action' IS NOT NULL
      AND s.elem->'action'<>'null'::jsonb
      AND COALESCE(
          (s.elem#>>'{availability,actionable}')::boolean,
          true
      )
    ORDER BY s.ord
    LIMIT 1;

    SELECT
        count(*)::integer,
        count(*) FILTER(
            WHERE elem->>'status'='COMPLETE'
        )::integer
    INTO v_total,v_completed
    FROM jsonb_array_elements(v_final_steps) x(elem);

    v_result := jsonb_set(v_result,'{steps}',v_final_steps,true);
    v_result := jsonb_set(v_result,'{blockers}',v_blockers,true);
    v_result := jsonb_set(
        v_result,
        '{summary,blockingIssues}',
        to_jsonb(jsonb_array_length(v_blockers)),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{progress,completed}',
        to_jsonb(v_completed),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{progress,total}',
        to_jsonb(v_total),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{progress,percent}',
        to_jsonb(
            CASE
                WHEN v_total=0 THEN 0
                ELSE round(100.0*v_completed/v_total,0)
            END
        ),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{nextAction}',
        COALESCE(v_next_action,'null'::jsonb),
        true
    );

    RETURN v_result || jsonb_build_object('schemaVersion',20);
END;
$function$;

-- El RPC público pasa a delegar en v20.
CREATE OR REPLACE FUNCTION public.obtener_asistente_operativo_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT public._obtener_asistente_operativo_torneo_v20_268(
        p_tournament_id
    );
$function$;

-- Seguridad del helper interno.
REVOKE ALL ON FUNCTION
    public._obtener_asistente_operativo_torneo_v20_268(uuid)
FROM PUBLIC;

REVOKE ALL ON FUNCTION
    public._obtener_asistente_operativo_torneo_v20_268(uuid)
FROM anon;

REVOKE ALL ON FUNCTION
    public._obtener_asistente_operativo_torneo_v20_268(uuid)
FROM authenticated;

GRANT EXECUTE ON FUNCTION
    public._obtener_asistente_operativo_torneo_v20_268(uuid)
TO postgres;

GRANT EXECUTE ON FUNCTION
    public._obtener_asistente_operativo_torneo_v20_268(uuid)
TO service_role;

-- Preservar acceso del RPC público.
REVOKE ALL ON FUNCTION
    public.obtener_asistente_operativo_torneo(uuid)
FROM PUBLIC;

REVOKE ALL ON FUNCTION
    public.obtener_asistente_operativo_torneo(uuid)
FROM anon;

GRANT EXECUTE ON FUNCTION
    public.obtener_asistente_operativo_torneo(uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION
    public.obtener_asistente_operativo_torneo(uuid)
TO service_role;
