-- 400-MIGRACION_CORREGIR_EVIDENCIA_CORTES_EVALUADOR.sql
-- TEE CENTRAL
-- Corrige las referencias descriptivas del evaluador 395 al módulo de cortes.
-- No modifica reglas de corte ni datos operativos.
-- La aplicabilidad se identifica por despues_de_ronda_id.
-- Las decisiones se leen de tournament_cut_player_statuses, que ya contiene
-- tournament_id y cut_after_round_id.
BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_workflow_evaluado_395(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path TO 'public','pg_temp'
AS $wf400$
DECLARE
  v_t public.tournaments%ROWTYPE;
  v_template jsonb;
  v_open jsonb := '{}'::jsonb;
  v_freeze jsonb := '{}'::jsonb;
  v_expired boolean := false;
  v_terminal boolean := false;
  v_round record;
  v_node record;
  v_applicable boolean;
  v_complete boolean;
  v_status text;
  v_evidence jsonb;
  v_rounds jsonb := '[]'::jsonb;
  v_tournament_nodes jsonb := '[]'::jsonb;
  v_round_nodes jsonb;
  v_next jsonb := NULL;
  v_groups jsonb;
  v_preview jsonb;
  v_validation jsonb;
  v_emission jsonb;
  v_capture jsonb;
  v_capture_close jsonb;
  v_competitive jsonb;
  v_formalization jsonb;
  v_lifecycle record;
  v_has_scoring_snapshot boolean := false;
  v_engine text;
  v_team_total integer;
  v_team_current integer;
  v_cut_total integer;
  v_cut_decided integer;
  v_tie_pending boolean;
BEGIN
  IF p_tournament_id IS NULL THEN
    RAISE EXCEPTION 'tournament_id es obligatorio.' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_t FROM public.tournaments WHERE id=p_tournament_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Torneo no encontrado.' USING ERRCODE='P0002'; END IF;

  -- Conserva la autorización real existente para consultar el torneo.
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
  END IF;
  IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
    RAISE EXCEPTION 'No tienes permiso para consultar este torneo.' USING ERRCODE='42501';
  END IF;

  v_template := public.obtener_plantilla_workflow_394(p_tournament_id);
  v_expired := COALESCE(public.torneo_esta_vencido_295(p_tournament_id),false);
  v_terminal := (v_t.estatus::text IN ('finalizado','cancelado')) OR v_expired;

  -- Estados de configuración ya existentes. Sólo lectura.
  v_open := public._estado_apertura_inscripciones_379(p_tournament_id);
  v_freeze := public.obtener_estado_congelamiento_torneo(p_tournament_id);

  -- Nodos de ámbito TORNEO.
  FOR v_node IN
    SELECT n.*
      FROM public.workflow_master_nodes n
      JOIN public.workflow_master_templates mt ON mt.id=n.template_id
     WHERE mt.template_code='TEE_CENTRAL_STANDARD'
       AND mt.version=v_t.workflow_template_version
       AND mt.active=true AND n.active=true AND n.scope='TOURNAMENT'
     ORDER BY n.sequence_no
  LOOP
    v_applicable := true;
    v_complete := false;
    v_evidence := '{}'::jsonb;

    CASE v_node.completion_rule
      WHEN 'TOURNAMENT_CONFIGURATION_COMPLETE' THEN
        v_complete := COALESCE((v_open->>'baseConfigurationReady')::boolean,false);
        v_evidence := jsonb_build_object('baseConfigurationReady',v_complete,
          'usarTarjetaDigital',v_t.usar_tarjeta_digital,
          'usarEstacionesDigitalesPremios',v_t.usar_estaciones_digitales_premios);
      WHEN 'HANDICAP_RANGES_COMPLETE' THEN
        v_complete := COALESCE((v_open->>'handicapRangesReady')::boolean,false);
        v_evidence := jsonb_build_object('handicapRangesReady',v_complete);
      WHEN 'TIEBREAK_CONFIGURATION_COMPLETE' THEN
        v_complete := COALESCE((v_open->>'tiebreakReady')::boolean,false);
        v_evidence := jsonb_build_object('tiebreakReady',v_complete);
      WHEN 'ROUND_STRUCTURE_COMPLETE' THEN
        v_complete := COALESCE((v_open->>'roundStructureReady')::boolean,false);
        v_evidence := jsonb_build_object('roundStructureReady',v_complete,
          'declaredRounds',v_open->'declaredRounds','activeRounds',v_open->'activeRounds');
      WHEN 'REGISTRATIONS_OPENED' THEN
        v_complete := v_t.estatus::text IN ('inscripciones_abiertas','inscripcion_cerrada','en_curso','finalizado');
        v_evidence := jsonb_build_object('tournamentStatus',v_t.estatus::text);
      WHEN 'REGISTRATIONS_CLOSED' THEN
        v_complete := v_t.estatus::text IN ('inscripcion_cerrada','en_curso','finalizado');
        v_evidence := jsonb_build_object('tournamentStatus',v_t.estatus::text);
      WHEN 'TOURNAMENT_FROZEN' THEN
        v_complete := COALESCE((v_freeze->>'frozen')::boolean,false);
        v_evidence := jsonb_build_object('frozen',v_complete,'freezeId',v_freeze->'freezeId');
      WHEN 'TOURNAMENT_STARTED' THEN
        v_complete := v_t.estatus::text IN ('en_curso','finalizado');
        v_evidence := jsonb_build_object('tournamentStatus',v_t.estatus::text);
      WHEN 'TOURNAMENT_FINALIZED' THEN
        v_complete := v_t.estatus::text='finalizado';
        v_evidence := jsonb_build_object('tournamentStatus',v_t.estatus::text);
      ELSE
        v_complete := false;
        v_evidence := jsonb_build_object('unmappedCompletionRule',v_node.completion_rule);
    END CASE;

    v_status := CASE WHEN NOT v_applicable THEN 'NOT_APPLICABLE' WHEN v_complete THEN 'COMPLETE' ELSE 'PENDING' END;
    v_tournament_nodes := v_tournament_nodes || jsonb_build_array(jsonb_build_object(
      'code',v_node.code,'sequenceNo',v_node.sequence_no,'scope','TOURNAMENT','title',v_node.title,
      'actionLabel',v_node.action_label,'navigationTarget',v_node.navigation_target,
      'isActionable',v_node.is_actionable,'isRequired',v_node.is_required,'applicable',v_applicable,
      'status',v_status,'complete',v_complete,'evidence',v_evidence));

    IF v_next IS NULL AND NOT v_terminal AND v_applicable AND NOT v_complete AND v_node.is_actionable THEN
      v_next := jsonb_build_object('code',v_node.code,'sequenceNo',v_node.sequence_no,'scope','TOURNAMENT',
        'title',v_node.title,'actionLabel',v_node.action_label,'navigationTarget',v_node.navigation_target);
    END IF;
  END LOOP;

  -- Nodos por cada ronda activa declarada.
  FOR v_round IN
    SELECT r.id,r.numero_ronda,r.tournament_format_id
      FROM public.tournament_rounds r
     WHERE r.tournament_id=p_tournament_id AND r.activo=true
     ORDER BY r.numero_ronda
  LOOP
    v_round_nodes := '[]'::jsonb;
    SELECT tf.scoring_engine::text INTO v_engine
      FROM public.tournament_formats tf
     WHERE tf.id=COALESCE(v_round.tournament_format_id,v_t.tournament_format_id);

    v_groups := public._estado_conformacion_grupos_ronda_235(v_round.id);
    v_preview := public.previsualizar_validacion_salidas_ronda(v_round.id);
    v_validation := public.obtener_estado_validacion_salidas_ronda(v_round.id);
    v_emission := public.obtener_estado_emision_tarjetas_ronda(v_round.id);
    v_capture := public.obtener_estado_captura_conciliacion_ronda_264(v_round.id);
    v_capture_close := public.obtener_estado_cierre_captura_ronda_389(v_round.id);

    SELECT l.started_at,l.completed_at INTO v_lifecycle
      FROM public.tournament_round_lifecycle l WHERE l.tournament_round_id=v_round.id;

    -- La evidencia competitiva exige snapshot congelado. El Asistente es guía:
    -- antes de que exista, las fases futuras permanecen PENDING sin forzar
    -- ni simular ninguna operación deportiva.
    SELECT EXISTS(
      SELECT 1
        FROM public.tournament_round_condition_snapshots s
       WHERE s.tournament_round_id=v_round.id
         AND s.scoring_engine IS NOT NULL
    ) INTO v_has_scoring_snapshot;

    IF v_has_scoring_snapshot THEN
      v_competitive := public.obtener_estado_competitivo_categorias_ronda(v_round.id);
      v_formalization := public._estado_formalizacion_resultados_ronda_265(v_round.id);
      v_tie_pending := jsonb_path_exists(
        COALESCE(v_competitive,'{}'::jsonb),
        '$.** ? (@ == "MANUAL_PENDING" || @ == "TIE_PERSISTS_AFTER_RULES")'
      );
    ELSE
      v_competitive := '{}'::jsonb;
      v_formalization := '{}'::jsonb;
      v_tie_pending := false;
    END IF;

    FOR v_node IN
      SELECT n.*
        FROM public.workflow_master_nodes n
        JOIN public.workflow_master_templates mt ON mt.id=n.template_id
       WHERE mt.template_code='TEE_CENTRAL_STANDARD'
         AND mt.version=v_t.workflow_template_version
         AND mt.active=true AND n.active=true AND n.scope='ROUND'
       ORDER BY n.sequence_no
    LOOP
      v_applicable := true;
      CASE v_node.applicability_rule
        WHEN 'DIGITAL_SCORECARD_ENABLED' THEN v_applicable := v_t.usar_tarjeta_digital;
        WHEN 'TEAM_HCP_REQUIRED' THEN v_applicable := (v_engine='team_stroke');
        WHEN 'WHEN_GROUPS_REQUIRED' THEN v_applicable := COALESCE((v_groups->>'applicable')::boolean,false);
        WHEN 'MANUAL_TIEBREAK_PENDING' THEN v_applicable := v_tie_pending;
        WHEN 'CUT_REQUIRED' THEN
          SELECT EXISTS(SELECT 1 FROM public.tournament_cut_rules cr WHERE cr.despues_de_ronda_id=v_round.id AND cr.activo=true) INTO v_applicable;
        ELSE v_applicable := true;
      END CASE;

      v_complete := false;
      v_evidence := '{}'::jsonb;

      IF NOT v_applicable THEN
        v_complete := false;
      ELSE
        CASE v_node.completion_rule
          WHEN 'TEAM_HCP_COMPLETE' THEN
            SELECT count(*) INTO v_team_total FROM public.tournament_teams tt WHERE tt.tournament_id=p_tournament_id AND tt.activo=true;
            SELECT count(DISTINCT tt.id) INTO v_team_current
              FROM public.tournament_teams tt
              JOIN public.tournament_round_team_handicap_versions hv ON hv.tournament_team_id=tt.id AND hv.tournament_round_id=v_round.id AND hv.status='active' AND hv.is_stale=false
             WHERE tt.tournament_id=p_tournament_id AND tt.activo=true;
            v_complete := v_team_total>0 AND v_team_current=v_team_total;
            v_evidence := jsonb_build_object('teams',v_team_total,'currentTeamHandicaps',v_team_current,'scoringEngine',v_engine);
          WHEN 'ROUND_GROUPS_COMPLETE' THEN
            v_complete := COALESCE(v_groups->>'status','') IN ('COMPLETE','NOT_APPLICABLE');
            v_evidence := v_groups;
          WHEN 'ROUND_STARTS_PREPARED' THEN
            v_complete := COALESCE((v_preview->>'ready')::boolean,false) OR COALESCE((v_preview->>'alreadyValidated')::boolean,false);
            v_evidence := jsonb_build_object('ready',v_preview->'ready','alreadyValidated',v_preview->'alreadyValidated');
          WHEN 'ROUND_STARTS_VALIDATED' THEN
            v_complete := COALESCE((v_validation->>'validated')::boolean,false);
            v_evidence := v_validation;
          WHEN 'SCORECARDS_EMITTED' THEN
            v_complete := COALESCE((v_emission->>'issued')::boolean,false);
            v_evidence := v_emission;
          WHEN 'ROUND_STARTED' THEN
            v_complete := v_lifecycle.started_at IS NOT NULL;
            v_evidence := jsonb_build_object('startedAt',v_lifecycle.started_at,'completedAt',v_lifecycle.completed_at);
          WHEN 'INFORMATIONAL_UNTIL_CAPTURE_CLOSE' THEN
            v_complete := COALESCE((v_capture_close->>'captureClosed')::boolean,false);
            v_evidence := jsonb_build_object('informational',true,'captureClosed',v_complete);
          WHEN 'PHYSICAL_CAPTURE_COMPLETE' THEN
            v_complete := COALESCE((v_capture#>>'{physicalCapture,complete}')::boolean,false);
            v_evidence := COALESCE(v_capture->'physicalCapture','{}'::jsonb);
          WHEN 'RECONCILIATION_COMPLETE' THEN
            v_complete := COALESCE((v_capture#>>'{reconciliation,complete}')::boolean,false);
            v_evidence := COALESCE(v_capture->'reconciliation','{}'::jsonb);
          WHEN 'CAPTURE_CLOSED' THEN
            v_complete := COALESCE((v_capture_close->>'captureClosed')::boolean,false);
            v_evidence := v_capture_close;
          WHEN 'RESULTS_READY' THEN
            v_complete := COALESCE((v_formalization->>'allCategoriesReady')::boolean,false);
            v_evidence := jsonb_build_object('allCategoriesReady',v_formalization->'allCategoriesReady');
          WHEN 'NO_MANUAL_TIEBREAK_PENDING' THEN
            v_complete := NOT v_tie_pending;
            v_evidence := jsonb_build_object('manualTiebreakPending',v_tie_pending);
          WHEN 'ALL_CATEGORIES_CLOSED' THEN
            v_complete := COALESCE((v_formalization->>'allCategoriesClosed')::boolean,false);
            v_evidence := jsonb_build_object('allCategoriesClosed',v_formalization->'allCategoriesClosed','closedCategories',v_formalization->'closedCategories','totalCategories',v_formalization->'totalCategories');
          WHEN 'RESULTS_PUBLISHED' THEN
            v_complete := COALESCE((v_formalization->>'allCategoriesPublished')::boolean,false);
            v_evidence := jsonb_build_object('allCategoriesPublished',v_formalization->'allCategoriesPublished','publishedCategories',v_formalization->'publishedCategories','totalCategories',v_formalization->'totalCategories');
          WHEN 'ROUND_CLOSED' THEN
            v_complete := v_lifecycle.completed_at IS NOT NULL OR EXISTS(SELECT 1 FROM public.tournament_round_competitive_closures c WHERE c.tournament_round_id=v_round.id AND c.competitive_status='FINAL');
            v_evidence := jsonb_build_object('completedAt',v_lifecycle.completed_at);
          WHEN 'CUT_COMPLETE' THEN
            SELECT count(*) INTO v_cut_total FROM public.tournament_registrations reg WHERE reg.tournament_id=p_tournament_id AND reg.activo=true;
            SELECT count(DISTINCT cps.tournament_registration_id) INTO v_cut_decided
              FROM public.tournament_cut_player_statuses cps
             WHERE cps.tournament_id=p_tournament_id
               AND cps.cut_after_round_id=v_round.id
               AND cps.cut_status IN ('MC','QUALIFIED');
            v_complete := v_cut_total>0 AND v_cut_decided>=v_cut_total;
            v_evidence := jsonb_build_object('activeRegistrations',v_cut_total,'cutDecisions',v_cut_decided);
          ELSE
            v_complete := false;
            v_evidence := jsonb_build_object('unmappedCompletionRule',v_node.completion_rule);
        END CASE;
      END IF;

      v_status := CASE
        WHEN NOT v_applicable THEN 'NOT_APPLICABLE'
        WHEN v_complete THEN 'COMPLETE'
        WHEN NOT v_node.is_actionable THEN 'INFORMATIONAL'
        ELSE 'PENDING' END;

      v_round_nodes := v_round_nodes || jsonb_build_array(jsonb_build_object(
        'code',v_node.code,'sequenceNo',v_node.sequence_no,'scope','ROUND','roundId',v_round.id,'roundNumber',v_round.numero_ronda,
        'title',v_node.title,'actionLabel',v_node.action_label,'navigationTarget',v_node.navigation_target,
        'isActionable',v_node.is_actionable,'isRequired',v_node.is_required,'applicable',v_applicable,
        'status',v_status,'complete',v_complete,'evidence',v_evidence));

      -- El Asistente sólo guía: primer paso accionable, aplicable y no completo.
      -- No se usa esta selección para autorizar ni bloquear nada.
      IF v_next IS NULL AND NOT v_terminal AND v_applicable AND NOT v_complete AND v_node.is_actionable THEN
        v_next := jsonb_build_object('code',v_node.code,'sequenceNo',v_node.sequence_no,'scope','ROUND',
          'roundId',v_round.id,'roundNumber',v_round.numero_ronda,'title',v_node.title,
          'actionLabel',v_node.action_label,'navigationTarget',v_node.navigation_target);
      END IF;
    END LOOP;

    v_rounds := v_rounds || jsonb_build_array(jsonb_build_object('roundId',v_round.id,'roundNumber',v_round.numero_ronda,'nodes',v_round_nodes));
  END LOOP;

  -- IMPORTANTE: esta función es descriptiva y no reemplaza todavía al Asistente.
  RETURN jsonb_build_object(
    'ok',true,
    'schemaVersion',395,
    'tournamentId',p_tournament_id,
    'tournamentStatus',v_t.estatus::text,
    'expired',v_expired,
    'assistantOperational',NOT v_terminal,
    'terminalReason',CASE WHEN v_t.estatus::text='finalizado' THEN 'FINALIZADO' WHEN v_t.estatus::text='cancelado' THEN 'CANCELADO' WHEN v_expired THEN 'VENCIDO' ELSE NULL END,
    'templateCode','TEE_CENTRAL_STANDARD',
    'templateVersion',v_t.workflow_template_version,
    'preferences',jsonb_build_object('usarTarjetaDigital',v_t.usar_tarjeta_digital,'usarEstacionesDigitalesPremios',v_t.usar_estaciones_digitales_premios,'usarControlAccesoQr',v_t.usar_control_acceso_qr),
    'tournamentNodes',v_tournament_nodes,
    'rounds',v_rounds,
    'nextAction',CASE WHEN v_terminal THEN NULL ELSE v_next END,
    'authority','APPLICATION',
    'assistantRole','GUIDE_ONLY',
    'writesOperationalState',false
  );
END;
$wf400$;

COMMIT;
