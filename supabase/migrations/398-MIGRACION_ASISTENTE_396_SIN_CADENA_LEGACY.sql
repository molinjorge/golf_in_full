-- 398-MIGRACION_ASISTENTE_396_SIN_CADENA_LEGACY.sql
-- TEE CENTRAL
-- Corrige exclusivamente la capa de guía 396.
-- Elimina la llamada indirecta al Asistente legacy 340 -> 338 -> reconciliación.
-- Conserva el warning administrativo de pagos pendientes mediante lectura directa.
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
    v_next jsonb;
    v_warnings jsonb := '[]'::jsonb;
    v_warning jsonb;
    v_pending integer := 0;
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

    -- Única fuente descriptiva del siguiente paso.
    v_eval := public.obtener_workflow_evaluado_395(p_tournament_id);
    v_next := v_eval->'nextAction';

    -- Warning administrativo de pagos: lectura directa, sin invocar
    -- el Asistente legacy ni reconciliar/reconstruir workflow.
    SELECT count(*)::integer
      INTO v_pending
      FROM public.tournament_registrations tr
     WHERE tr.tournament_id=p_tournament_id
       AND tr.activo=true
       AND tr.estado_pago='PENDIENTE';

    IF v_pending > 0 THEN
        v_warning := jsonb_build_object(
            'code','PENDING_PAYMENTS',
            'severity','WARNING',
            'blocking',false,
            'title','Pagos pendientes',
            'message',CASE
                WHEN v_pending=1 THEN 'Hay 1 jugador inscrito con pago pendiente.'
                ELSE format('Hay %s jugadores inscritos con pago pendiente.',v_pending)
            END,
            'recommendation','Registra el pago durante el check-in cuando corresponda.',
            'count',v_pending,
            'target','inscripciones'
        );
        v_warnings := jsonb_build_array(v_warning);
    END IF;

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
            WHEN COALESCE((v_eval->>'assistantOperational')::boolean,false) THEN v_next
            ELSE NULL
        END,
        'warnings',v_warnings,
        'summary',jsonb_build_object('warnings',jsonb_array_length(v_warnings)),
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

DO $$
DECLARE v_def text;
BEGIN
    SELECT pg_get_functiondef('public.obtener_asistente_operativo_torneo_396(uuid)'::regprocedure) INTO v_def;

    IF position('_adaptar_asistente_pagos_pendientes_340' in v_def)>0
       OR position('_adaptar_asistente_workflow_338' in v_def)>0
       OR position('reconciliar_workflow_torneo_332' in v_def)>0
       OR position('tournament_workflow_nodes' in v_def)>0 THEN
        RAISE EXCEPTION '398: la RPC 396 conserva una dependencia legacy no permitida.';
    END IF;

    IF position('obtener_workflow_evaluado_395' in v_def)=0 THEN
        RAISE EXCEPTION '398: falta el evaluador descriptivo 395.';
    END IF;
END $$;

COMMIT;
