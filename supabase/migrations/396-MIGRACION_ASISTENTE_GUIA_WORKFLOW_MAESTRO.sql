-- 396-MIGRACION_ASISTENTE_GUIA_WORKFLOW_MAESTRO.sql
-- TEE CENTRAL
-- Integra el Asistente Operativo con el evaluador descriptivo 395.
-- PRINCIPIO: el Asistente guía; la aplicación conserva toda autoridad.
BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_asistente_operativo_torneo_396(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_eval jsonb;
    v_old jsonb;
    v_next jsonb;
    v_warnings jsonb := '[]'::jsonb;
    v_terminal text;
    v_message text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(),p_tournament_id)
        OR public.puede_administrar_congelamiento_torneo(p_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar el asistente operativo de este torneo.'
            USING ERRCODE='42501';
    END IF;

    -- Fuente descriptiva nueva. No escribe ni autoriza operaciones.
    v_eval := public.obtener_workflow_evaluado_395(p_tournament_id);
    v_next := v_eval->'nextAction';

    -- Se conserva el warning administrativo de pagos del contrato anterior.
    -- El resultado antiguo NO decide nextAction ni estados de la guía.
    v_old := public._adaptar_asistente_pagos_pendientes_340(p_tournament_id);
    v_warnings := COALESCE(v_old->'warnings','[]'::jsonb);

    v_terminal := v_eval->>'terminalReason';
    v_message := CASE v_terminal
        WHEN 'FINALIZADO' THEN 'El ciclo operativo de este torneo ha concluido. El Asistente ya no tiene acciones pendientes.'
        WHEN 'CANCELADO' THEN 'Este torneo fue cancelado. El Asistente operativo ya no aplica.'
        WHEN 'VENCIDO' THEN 'Este torneo está vencido. El Asistente operativo ya no aplica.'
        ELSE NULL
    END;

    RETURN jsonb_build_object(
        'schemaVersion',396,
        'assistantSource','MASTER_WORKFLOW_EVALUATOR_395',
        'tournamentId',p_tournament_id,
        'assistantOperational',COALESCE((v_eval->>'assistantOperational')::boolean,false),
        'terminalReason',v_terminal,
        'terminalMessage',v_message,
        'nextAction',CASE
            WHEN COALESCE((v_eval->>'assistantOperational')::boolean,false)
                THEN v_next
            ELSE NULL
        END,
        'warnings',v_warnings,
        'summary',jsonb_build_object(
            'warnings',jsonb_array_length(v_warnings)
        ),
        'tournamentNodes',COALESCE(v_eval->'tournamentNodes','[]'::jsonb),
        'rounds',COALESCE(v_eval->'rounds','[]'::jsonb),
        'preferences',COALESCE(v_eval->'preferences','{}'::jsonb),
        'templateCode',v_eval->>'templateCode',
        'templateVersion',v_eval->'templateVersion',
        'authority','APPLICATION',
        'assistantRole','GUIDE_ONLY',
        'writesOperationalState',false
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_asistente_operativo_torneo_396(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_asistente_operativo_torneo_396(uuid) TO authenticated, service_role;

-- Invariantes estructurales sobre dependencias de la nueva RPC de guía.
DO $$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef('public.obtener_asistente_operativo_torneo_396(uuid)'::regprocedure)
      INTO v_def;

    IF position('tournament_workflow_nodes' in lower(v_def)) > 0 THEN
        RAISE EXCEPTION '396: la RPC nueva no debe consultar tournament_workflow_nodes.';
    END IF;

    IF position('reconciliar_workflow_torneo_332' in lower(v_def)) > 0
       OR position('reconstruir_workflow' in lower(v_def)) > 0 THEN
        RAISE EXCEPTION '396: la RPC nueva no debe reconstruir ni reconciliar workflow.';
    END IF;

    IF position('obtener_workflow_evaluado_395' in lower(v_def)) = 0 THEN
        RAISE EXCEPTION '396: falta la dependencia descriptiva del evaluador 395.';
    END IF;
END $$;

COMMIT;
