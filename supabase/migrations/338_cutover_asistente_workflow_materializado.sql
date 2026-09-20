BEGIN;

-- 338: Cutover del Asistente Operativo al workflow materializado 337.
-- No modifica motores deportivos ni sus RPC. El Asistente reconcilia la
-- proyección y adapta sus nodos al contrato JSON consumido por el frontend.

CREATE OR REPLACE FUNCTION public._adaptar_asistente_workflow_338(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
    v_workflow jsonb;
    v_steps jsonb := '[]'::jsonb;
    v_blockers jsonb := '[]'::jsonb;
    v_rounds jsonb := '[]'::jsonb;
    v_node record;
    v_step jsonb;
    v_action jsonb;
    v_target text;
    v_title text;
    v_ui_status text;
    v_next_action jsonb := NULL;
    v_first_available_action jsonb := NULL;
    v_first_in_progress_action jsonb := NULL;
    v_first_blocked_action jsonb := NULL;
    v_completed integer := 0;
    v_total integer := 0;
    v_registration_count integer := 0;
    v_active_rounds integer := 0;
    v_blocking integer := 0;
    v_stage text := 'CONFIGURATION';
    v_is_superadmin boolean := false;
    v_is_organizer boolean := false;
    v_can_manage boolean := false;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT * INTO v_t
      FROM public.tournaments
     WHERE id=p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='22023';
    END IF;

    v_is_superadmin := public.is_superadmin(auth.uid());
    v_is_organizer := public.is_tournament_organizer(auth.uid(),p_tournament_id);
    v_can_manage := public.puede_administrar_congelamiento_torneo(p_tournament_id);

    IF NOT (v_is_superadmin OR v_is_organizer OR v_can_manage) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar el asistente operativo de este torneo.'
            USING ERRCODE='42501';
    END IF;

    -- Reconciliación controlada: 337 actualiza sólo la proyección workflow.
    v_workflow := public.reconciliar_workflow_torneo_332(p_tournament_id);

    SELECT count(*)::integer INTO v_registration_count
      FROM public.tournament_registrations
     WHERE tournament_id=p_tournament_id AND activo=true;

    SELECT count(*)::integer INTO v_active_rounds
      FROM public.tournament_rounds
     WHERE tournament_id=p_tournament_id AND activo=true;

    FOR v_node IN
        SELECT n.*,
               r.numero_ronda,
               r.fecha AS round_date,
               r.formato_salida::text AS start_format
          FROM public.tournament_workflow_nodes n
          LEFT JOIN public.tournament_rounds r
            ON r.id=n.tournament_round_id
         WHERE n.tournament_id=p_tournament_id
         ORDER BY n.sequence_no,n.code
    LOOP
        v_total := v_total + 1;
        IF v_node.status='COMPLETE' THEN
            v_completed := v_completed + 1;
        END IF;

        -- Compatibilidad visual: el frontend histórico usa COMPLETE/PENDING/BLOCKED.
        -- workflowStatus conserva la semántica materializada completa.
        v_ui_status := CASE v_node.status
            WHEN 'COMPLETE' THEN 'COMPLETE'
            WHEN 'BLOCKED' THEN 'BLOCKED'
            ELSE 'PENDING'
        END;

        v_title := CASE v_node.code
            WHEN 'CONFIGURATION' THEN 'Configuración del torneo'
            WHEN 'HANDICAP_RANGES' THEN 'Franjas de hándicap'
            WHEN 'TIEBREAK_CONFIGURATION' THEN 'Configuración de desempates'
            WHEN 'REGISTRATIONS' THEN 'Inscripciones'
            WHEN 'FREEZE' THEN 'Congelar condiciones y hándicaps'
            WHEN 'START_TOURNAMENT' THEN 'Iniciar torneo'
            WHEN 'TOURNAMENT_FINALIZATION' THEN 'Finalizar torneo'
            WHEN 'ROUND_CONFIGURATION' THEN format('Ronda %s · Configuración',v_node.numero_ronda)
            WHEN 'ROUND_TEAM_HCP' THEN format('Ronda %s · HCP de equipos',v_node.numero_ronda)
            WHEN 'ROUND_GROUPS' THEN format('Ronda %s · Grupos',v_node.numero_ronda)
            WHEN 'ROUND_STARTS' THEN format('Ronda %s · Salidas',v_node.numero_ronda)
            WHEN 'SCORECARD_EMISSION' THEN format('Ronda %s · Tarjetas',v_node.numero_ronda)
            WHEN 'ROUND_SCORING_INIT' THEN format('Ronda %s · Inicialización de captura',v_node.numero_ronda)
            WHEN 'ROUND_PLAY' THEN format('Ronda %s · Estado de juego',v_node.numero_ronda)
            WHEN 'ROUND_PHYSICAL_CAPTURE' THEN format('Ronda %s · Captura física',v_node.numero_ronda)
            WHEN 'ROUND_RECONCILIATION' THEN format('Ronda %s · Conciliación',v_node.numero_ronda)
            WHEN 'ROUND_RESULTS' THEN format('Ronda %s · Resultados',v_node.numero_ronda)
            WHEN 'ROUND_CATEGORY_CLOSURE' THEN format('Ronda %s · Cierre de categorías',v_node.numero_ronda)
            WHEN 'ROUND_RESULTS_PUBLICATION' THEN format('Ronda %s · Publicación de resultados',v_node.numero_ronda)
            WHEN 'ROUND_COMPETITIVE_CLOSE' THEN format('Ronda %s · Cierre competitivo',v_node.numero_ronda)
            ELSE replace(initcap(lower(v_node.code)),'_',' ')
        END;

        v_target := CASE v_node.code
            WHEN 'CONFIGURATION' THEN 'configuracion'
            WHEN 'HANDICAP_RANGES' THEN 'categorias'
            WHEN 'TIEBREAK_CONFIGURATION' THEN 'desempates'
            WHEN 'REGISTRATIONS' THEN 'inscripciones'
            WHEN 'FREEZE' THEN 'condiciones-handicaps'
            WHEN 'START_TOURNAMENT' THEN 'tarjetas-resultados'
            WHEN 'TOURNAMENT_FINALIZATION' THEN 'resultados'
            WHEN 'ROUND_CONFIGURATION' THEN 'rondas'
            WHEN 'ROUND_TEAM_HCP' THEN 'equipos'
            WHEN 'ROUND_GROUPS' THEN 'grupos'
            WHEN 'ROUND_STARTS' THEN 'salidas'
            WHEN 'SCORECARD_EMISSION' THEN 'tarjetas'
            WHEN 'ROUND_SCORING_INIT' THEN 'captura-resultados'
            WHEN 'ROUND_PLAY' THEN 'tarjetas-resultados'
            WHEN 'ROUND_PHYSICAL_CAPTURE' THEN 'captura-resultados'
            WHEN 'ROUND_RECONCILIATION' THEN 'captura-resultados'
            WHEN 'ROUND_RESULTS' THEN 'resultados'
            WHEN 'ROUND_CATEGORY_CLOSURE' THEN 'resultados'
            WHEN 'ROUND_RESULTS_PUBLICATION' THEN 'resultados'
            WHEN 'ROUND_COMPETITIVE_CLOSE' THEN 'resultados'
            ELSE NULL
        END;

        IF v_target IS NULL OR v_node.status='COMPLETE' THEN
            v_action := NULL;
        ELSE
            v_action := jsonb_strip_nulls(jsonb_build_object(
                'label', CASE v_node.code
                    WHEN 'CONFIGURATION' THEN 'Revisar configuración'
                    WHEN 'HANDICAP_RANGES' THEN 'Revisar categorías'
                    WHEN 'TIEBREAK_CONFIGURATION' THEN 'Revisar desempates'
                    WHEN 'REGISTRATIONS' THEN 'Ir a inscripciones'
                    WHEN 'FREEZE' THEN 'Revisar congelamiento'
                    WHEN 'START_TOURNAMENT' THEN 'Revisar inicio del torneo'
                    WHEN 'TOURNAMENT_FINALIZATION' THEN 'Revisar finalización'
                    WHEN 'ROUND_CONFIGURATION' THEN 'Revisar ronda'
                    WHEN 'ROUND_TEAM_HCP' THEN 'Revisar HCP de equipos'
                    WHEN 'ROUND_GROUPS' THEN 'Revisar grupos'
                    WHEN 'ROUND_STARTS' THEN 'Revisar salidas'
                    WHEN 'SCORECARD_EMISSION' THEN 'Revisar tarjetas'
                    WHEN 'ROUND_SCORING_INIT' THEN 'Revisar captura'
                    WHEN 'ROUND_PLAY' THEN 'Revisar ronda'
                    WHEN 'ROUND_PHYSICAL_CAPTURE' THEN 'Revisar captura física'
                    WHEN 'ROUND_RECONCILIATION' THEN 'Revisar conciliación'
                    WHEN 'ROUND_RESULTS' THEN 'Revisar resultados'
                    WHEN 'ROUND_CATEGORY_CLOSURE' THEN 'Revisar cierre de categorías'
                    WHEN 'ROUND_RESULTS_PUBLICATION' THEN 'Revisar publicación'
                    WHEN 'ROUND_COMPETITIVE_CLOSE' THEN 'Revisar cierre de ronda'
                    ELSE 'Revisar'
                END,
                'target',v_target,
                'roundId',v_node.tournament_round_id
            ));
        END IF;

        v_step := jsonb_strip_nulls(jsonb_build_object(
            'code',v_node.code,
            'scope',v_node.scope,
            'roundId',v_node.tournament_round_id,
            'roundNumber',v_node.numero_ronda,
            'title',v_title,
            'status',v_ui_status,
            'workflowStatus',v_node.status,
            'message',v_node.detail,
            'recommendation',CASE
                WHEN v_node.status='BLOCKED' AND v_node.blocked_by_code IS NOT NULL
                    THEN format('Completa primero: %s.',replace(v_node.blocked_by_code,'_',' '))
                ELSE NULL
            END,
            'details',jsonb_build_object(
                'evidence',COALESCE(v_node.evidence,'{}'::jsonb),
                'sequence',v_node.sequence_no,
                'previousCode',v_node.previous_code,
                'nextCode',v_node.next_code,
                'blockedByCode',v_node.blocked_by_code,
                'completedAt',v_node.completed_at,
                'reconciledAt',v_node.reconciled_at,
                'roundDate',v_node.round_date,
                'startFormat',v_node.start_format
            ),
            'action',v_action,
            'requiredRole','TOURNAMENT_OPERATOR'
        ));

        v_steps := v_steps || jsonb_build_array(v_step);

        IF v_node.status='BLOCKED' THEN
            v_blocking := v_blocking + 1;
            v_blockers := v_blockers || jsonb_build_array(v_step);
        END IF;

        -- Prioridad 338: primer AVAILABLE por secuencia; si no existe,
        -- primer IN_PROGRESS; por último primer BLOCKED. Así una ronda abierta
        -- no oculta Resultados cuando Resultados ya está AVAILABLE.
        IF v_action IS NOT NULL THEN
            IF v_node.status='AVAILABLE' AND v_first_available_action IS NULL THEN
                v_first_available_action := v_action;
            ELSIF v_node.status='IN_PROGRESS' AND v_first_in_progress_action IS NULL THEN
                v_first_in_progress_action := v_action;
            ELSIF v_node.status='BLOCKED' AND v_first_blocked_action IS NULL THEN
                v_first_blocked_action := v_action;
            END IF;
        END IF;
    END LOOP;

    v_next_action := COALESCE(
        v_first_available_action,
        v_first_in_progress_action,
        v_first_blocked_action
    );

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'roundId',r.id,
               'roundNumber',r.numero_ronda,
               'roundDate',r.fecha,
               'startFormat',r.formato_salida::text,
               'workflowStatus',COALESCE(play.status,'PENDING'),
               'formallyClosed',COALESCE(close_node.status='COMPLETE',false)
           ) ORDER BY r.numero_ronda,r.id),'[]'::jsonb)
      INTO v_rounds
      FROM public.tournament_rounds r
      LEFT JOIN public.tournament_workflow_nodes play
        ON play.tournament_id=p_tournament_id
       AND play.tournament_round_id=r.id
       AND play.code='ROUND_PLAY'
      LEFT JOIN public.tournament_workflow_nodes close_node
        ON close_node.tournament_id=p_tournament_id
       AND close_node.tournament_round_id=r.id
       AND close_node.code='ROUND_COMPETITIVE_CLOSE'
     WHERE r.tournament_id=p_tournament_id
       AND r.activo=true;

    IF v_t.estatus::text='finalizado' THEN
        v_stage := 'FINALIZED';
    ELSIF EXISTS (
        SELECT 1 FROM public.tournament_workflow_nodes
         WHERE tournament_id=p_tournament_id
           AND code IN ('ROUND_RESULTS','ROUND_CATEGORY_CLOSURE','ROUND_RESULTS_PUBLICATION','ROUND_COMPETITIVE_CLOSE')
           AND status IN ('AVAILABLE','IN_PROGRESS')
    ) THEN
        v_stage := 'RESULTS';
    ELSIF EXISTS (
        SELECT 1 FROM public.tournament_workflow_nodes
         WHERE tournament_id=p_tournament_id
           AND code IN ('ROUND_PLAY','ROUND_PHYSICAL_CAPTURE','ROUND_RECONCILIATION')
           AND status IN ('AVAILABLE','IN_PROGRESS')
    ) THEN
        v_stage := 'SCORING';
    ELSIF EXISTS (
        SELECT 1 FROM public.tournament_workflow_nodes
         WHERE tournament_id=p_tournament_id
           AND scope='ROUND'
           AND status IN ('AVAILABLE','IN_PROGRESS')
    ) THEN
        v_stage := 'ROUND_PREPARATION';
    ELSIF EXISTS (
        SELECT 1 FROM public.tournament_workflow_nodes
         WHERE tournament_id=p_tournament_id AND code='REGISTRATIONS'
           AND status IN ('AVAILABLE','IN_PROGRESS')
    ) THEN
        v_stage := 'REGISTRATIONS';
    ELSE
        v_stage := 'CONFIGURATION';
    END IF;

    RETURN jsonb_build_object(
        'schemaVersion',338,
        'assistantSource','MATERIALIZED_WORKFLOW_337',
        'tournamentId',p_tournament_id,
        'tournamentName',v_t.nombre,
        'stage',v_stage,
        'status',jsonb_build_object(
            'tournamentStatus',v_t.estatus::text,
            'serviceStatus',v_t.estado_servicio::text,
            'active',v_t.activo,
            'configurationFinalized',v_t.configuracion_finalizada_at IS NOT NULL,
            'configurationConfirmationRequired',false
        ),
        'actor',jsonb_build_object(
            'isSuperadmin',v_is_superadmin,
            'isTournamentOrganizer',v_is_organizer,
            'canManageTournament',v_can_manage
        ),
        'progress',jsonb_build_object(
            'completed',v_completed,
            'total',v_total,
            'percent',CASE WHEN v_total=0 THEN 0 ELSE round(100.0*v_completed/v_total,0) END
        ),
        'summary',jsonb_build_object(
            'blockingIssues',v_blocking,
            'warnings',0,
            'registrations',v_registration_count,
            'activeRounds',v_active_rounds
        ),
        'nextAction',COALESCE(v_next_action,'null'::jsonb),
        'blockers',v_blockers,
        'warnings','[]'::jsonb,
        'steps',v_steps,
        'rounds',v_rounds,
        'workflow',COALESCE(v_workflow,'{}'::jsonb)
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.obtener_asistente_operativo_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT public._adaptar_asistente_workflow_338(p_tournament_id);
$function$;

GRANT EXECUTE ON FUNCTION public.obtener_asistente_operativo_torneo(uuid) TO authenticated;

COMMIT;
