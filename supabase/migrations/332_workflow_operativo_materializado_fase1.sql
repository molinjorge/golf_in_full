-- MIGRACIÓN 332
-- TEE CENTRAL / GOLF IN FULL
-- Workflow operativo materializado — Fase 1
--
-- OBJETIVO
-- 1) Crear una proyección materializada y auditable del estado operativo del torneo y sus rondas.
-- 2) Reconstruir esa proyección desde la evidencia real existente, sin sustituirla.
-- 3) Proveer una RPC ligera de diagnóstico que NO use la cadena histórica del Asistente.
-- 4) NO reemplazar obtener_asistente_operativo_torneo(uuid) en esta fase.
-- 5) NO modificar motores deportivos, Freeze, grupos, salidas, tarjetas, captura, lifecycle,
--    desempates, cortes, publicaciones ni cierres existentes.
--
-- PRINCIPIO
-- Las tablas deportivas siguen siendo la fuente de verdad. El workflow es una proyección derivada.
-- Puede reconstruirse en cualquier momento desde la evidencia real.

BEGIN;

CREATE TABLE IF NOT EXISTS public.tournament_workflow_nodes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
    tournament_round_id uuid NULL REFERENCES public.tournament_rounds(id) ON DELETE CASCADE,
    scope text NOT NULL CHECK (scope IN ('TOURNAMENT','ROUND')),
    code text NOT NULL,
    sequence_no integer NOT NULL,
    status text NOT NULL CHECK (status IN ('PENDING','AVAILABLE','IN_PROGRESS','COMPLETE','BLOCKED','NOT_APPLICABLE')),
    previous_code text NULL,
    next_code text NULL,
    blocked_by_code text NULL,
    evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
    detail text NULL,
    completed_at timestamptz NULL,
    reconciled_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK ((scope='TOURNAMENT' AND tournament_round_id IS NULL) OR (scope='ROUND' AND tournament_round_id IS NOT NULL))
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_workflow_332_tournament_node
ON public.tournament_workflow_nodes(tournament_id, code)
WHERE scope='TOURNAMENT' AND tournament_round_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_workflow_332_round_node
ON public.tournament_workflow_nodes(tournament_id, tournament_round_id, code)
WHERE scope='ROUND' AND tournament_round_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_workflow_332_tournament_sequence
ON public.tournament_workflow_nodes(tournament_id, scope, tournament_round_id, sequence_no);

CREATE TABLE IF NOT EXISTS public.tournament_workflow_node_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    workflow_node_id uuid NOT NULL REFERENCES public.tournament_workflow_nodes(id) ON DELETE CASCADE,
    tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
    tournament_round_id uuid NULL REFERENCES public.tournament_rounds(id) ON DELETE CASCADE,
    code text NOT NULL,
    old_status text NULL,
    new_status text NOT NULL,
    old_evidence jsonb NULL,
    new_evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
    changed_at timestamptz NOT NULL DEFAULT now(),
    change_source text NOT NULL DEFAULT 'RECONCILIATION_332'
);

CREATE INDEX IF NOT EXISTS ix_workflow_events_332_tournament
ON public.tournament_workflow_node_events(tournament_id, changed_at DESC);

ALTER TABLE public.tournament_workflow_nodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_workflow_node_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_workflow_nodes FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.tournament_workflow_node_events FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._upsert_workflow_node_332(
    p_tournament_id uuid,
    p_round_id uuid,
    p_scope text,
    p_code text,
    p_sequence integer,
    p_status text,
    p_previous_code text,
    p_next_code text,
    p_blocked_by_code text,
    p_evidence jsonb,
    p_detail text,
    p_completed_at timestamptz
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_id uuid;
    v_old_status text;
    v_old_evidence jsonb;
BEGIN
    SELECT id,status,evidence INTO v_id,v_old_status,v_old_evidence
    FROM public.tournament_workflow_nodes
    WHERE tournament_id=p_tournament_id
      AND scope=p_scope
      AND code=p_code
      AND tournament_round_id IS NOT DISTINCT FROM p_round_id
    FOR UPDATE;

    IF v_id IS NULL THEN
        INSERT INTO public.tournament_workflow_nodes(
            tournament_id,tournament_round_id,scope,code,sequence_no,status,
            previous_code,next_code,blocked_by_code,evidence,detail,completed_at,reconciled_at
        ) VALUES (
            p_tournament_id,p_round_id,p_scope,p_code,p_sequence,p_status,
            p_previous_code,p_next_code,p_blocked_by_code,COALESCE(p_evidence,'{}'::jsonb),p_detail,p_completed_at,now()
        ) RETURNING id INTO v_id;

        INSERT INTO public.tournament_workflow_node_events(
            workflow_node_id,tournament_id,tournament_round_id,code,old_status,new_status,old_evidence,new_evidence
        ) VALUES (
            v_id,p_tournament_id,p_round_id,p_code,NULL,p_status,NULL,COALESCE(p_evidence,'{}'::jsonb)
        );
    ELSE
        UPDATE public.tournament_workflow_nodes
        SET sequence_no=p_sequence,
            status=p_status,
            previous_code=p_previous_code,
            next_code=p_next_code,
            blocked_by_code=p_blocked_by_code,
            evidence=COALESCE(p_evidence,'{}'::jsonb),
            detail=p_detail,
            completed_at=p_completed_at,
            reconciled_at=now(),
            updated_at=now()
        WHERE id=v_id;

        IF v_old_status IS DISTINCT FROM p_status OR v_old_evidence IS DISTINCT FROM COALESCE(p_evidence,'{}'::jsonb) THEN
            INSERT INTO public.tournament_workflow_node_events(
                workflow_node_id,tournament_id,tournament_round_id,code,old_status,new_status,old_evidence,new_evidence
            ) VALUES (
                v_id,p_tournament_id,p_round_id,p_code,v_old_status,p_status,v_old_evidence,COALESCE(p_evidence,'{}'::jsonb)
            );
        END IF;
    END IF;

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.reconstruir_workflow_torneo_332(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    t public.tournaments%ROWTYPE;
    r public.tournament_rounds%ROWTYPE;
    v_prev_complete boolean;
    v_status text;
    v_block text;
    v_freeze_count integer;
    v_reg_count integer;
    v_group_count integer;
    v_validation_count integer;
    v_emission_count integer;
    v_capture_count integer;
    v_cut_rule_count integer;
    v_cut_status_count integer;
    v_lifecycle_started timestamptz;
    v_lifecycle_completed timestamptz;
    v_round_close timestamptz;
    v_finalized_at timestamptz;
    v_nodes integer;
BEGIN
    SELECT * INTO t FROM public.tournaments WHERE id=p_tournament_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Torneo no encontrado'; END IF;

    -- Limpia nodos de rondas que ya no existen o están inactivas; conserva historial de eventos.
    DELETE FROM public.tournament_workflow_nodes n
    WHERE n.tournament_id=p_tournament_id
      AND n.scope='ROUND'
      AND NOT EXISTS (
          SELECT 1 FROM public.tournament_rounds rr
          WHERE rr.id=n.tournament_round_id AND rr.tournament_id=p_tournament_id AND rr.activo=true
      );

    SELECT count(*) INTO v_reg_count FROM public.tournament_registrations WHERE tournament_id=p_tournament_id;
    SELECT count(*) INTO v_freeze_count FROM public.tournament_condition_freezes WHERE tournament_id=p_tournament_id;
    SELECT max(finalized_at) INTO v_finalized_at FROM public.tournament_competitive_finalizations
      WHERE tournament_id=p_tournament_id AND status='FINALIZED';

    -- 10 CONFIGURATION
    v_status := CASE WHEN t.configuracion_finalizada_at IS NOT NULL THEN 'COMPLETE' ELSE 'AVAILABLE' END;
    PERFORM public._upsert_workflow_node_332(p_tournament_id,NULL,'TOURNAMENT','CONFIGURATION',10,v_status,NULL,'REGISTRATIONS',NULL,
      jsonb_build_object('configuracion_finalizada_at',t.configuracion_finalizada_at,'tournament_status',t.estatus::text),
      CASE WHEN v_status='COMPLETE' THEN 'Configuración finalizada.' ELSE 'Configuración pendiente.' END,t.configuracion_finalizada_at);

    -- 20 REGISTRATIONS: se considera completa al cerrar inscripciones o avanzar más allá.
    v_status := CASE
      WHEN t.estatus::text IN ('inscripcion_cerrada','en_curso','finalizado','cancelado') THEN 'COMPLETE'
      WHEN t.configuracion_finalizada_at IS NULL THEN 'BLOCKED'
      ELSE 'AVAILABLE' END;
    v_block := CASE WHEN t.configuracion_finalizada_at IS NULL THEN 'CONFIGURATION' END;
    PERFORM public._upsert_workflow_node_332(p_tournament_id,NULL,'TOURNAMENT','REGISTRATIONS',20,v_status,'CONFIGURATION','FREEZE',v_block,
      jsonb_build_object('registration_count',v_reg_count,'tournament_status',t.estatus::text),
      CASE WHEN v_status='COMPLETE' THEN 'Inscripciones cerradas o ciclo ya avanzado.' WHEN v_status='BLOCKED' THEN 'Requiere configuración finalizada.' ELSE 'Inscripciones disponibles.' END,NULL);

    -- 30 FREEZE
    v_status := CASE WHEN v_freeze_count>0 THEN 'COMPLETE'
      WHEN t.estatus::text NOT IN ('inscripcion_cerrada','en_curso','finalizado','cancelado') THEN 'BLOCKED'
      ELSE 'AVAILABLE' END;
    v_block := CASE WHEN v_freeze_count=0 AND t.estatus::text NOT IN ('inscripcion_cerrada','en_curso','finalizado','cancelado') THEN 'REGISTRATIONS' END;
    PERFORM public._upsert_workflow_node_332(p_tournament_id,NULL,'TOURNAMENT','FREEZE',30,v_status,'REGISTRATIONS','START_TOURNAMENT',v_block,
      jsonb_build_object('freeze_count',v_freeze_count),
      CASE WHEN v_freeze_count>0 THEN 'Condiciones congeladas.' WHEN v_status='BLOCKED' THEN 'Requiere cierre de inscripciones.' ELSE 'Freeze disponible.' END,
      (SELECT max(frozen_at) FROM public.tournament_condition_freezes WHERE tournament_id=p_tournament_id));

    -- 40 START_TOURNAMENT
    v_status := CASE WHEN t.estatus::text IN ('en_curso','finalizado') THEN 'COMPLETE'
      WHEN v_freeze_count=0 THEN 'BLOCKED' ELSE 'AVAILABLE' END;
    v_block := CASE WHEN v_freeze_count=0 THEN 'FREEZE' END;
    PERFORM public._upsert_workflow_node_332(p_tournament_id,NULL,'TOURNAMENT','START_TOURNAMENT',40,v_status,'FREEZE','TOURNAMENT_FINALIZATION',v_block,
      jsonb_build_object('tournament_status',t.estatus::text),
      CASE WHEN v_status='COMPLETE' THEN 'Torneo iniciado.' WHEN v_status='BLOCKED' THEN 'Requiere Freeze.' ELSE 'Inicio sujeto a validaciones operativas existentes.' END,NULL);

    -- RONDAS ACTIVAS
    v_prev_complete := true;
    FOR r IN SELECT * FROM public.tournament_rounds WHERE tournament_id=p_tournament_id AND activo=true ORDER BY numero_ronda,id LOOP
        SELECT count(*) INTO v_group_count
        FROM public.tournament_groups g JOIN public.tournament_round_shifts s ON s.id=g.tournament_round_shift_id
        WHERE s.tournament_round_id=r.id AND g.activo=true;

        SELECT count(*) INTO v_validation_count FROM public.tournament_round_start_validations
        WHERE tournament_round_id=r.id AND status='validated' AND reopened_at IS NULL;

        SELECT count(*) INTO v_emission_count FROM public.tournament_score_card_emissions
        WHERE tournament_round_id=r.id AND status='issued' AND voided_at IS NULL;

        SELECT count(*) INTO v_capture_count FROM public.tournament_scorecard_capture_sessions
        WHERE tournament_round_id=r.id AND status IN ('ready','in_progress','captured');

        SELECT started_at,completed_at INTO v_lifecycle_started,v_lifecycle_completed
        FROM public.tournament_round_lifecycle WHERE tournament_round_id=r.id LIMIT 1;

        SELECT max(closed_at) INTO v_round_close FROM public.tournament_round_competitive_closures
        WHERE tournament_round_id=r.id AND competitive_status='FINAL';

        SELECT count(*) INTO v_cut_rule_count FROM public.tournament_cut_rules
        WHERE despues_de_ronda_id=r.id AND activo=true;
        SELECT count(*) INTO v_cut_status_count FROM public.tournament_cut_player_statuses
        WHERE cut_after_round_id=r.id;

        -- ROUND_CONFIGURATION: existencia activa y campo/formato definidos.
        v_status := CASE WHEN r.campo_golf_id IS NOT NULL AND r.formato_salida IS NOT NULL THEN 'COMPLETE' ELSE 'AVAILABLE' END;
        PERFORM public._upsert_workflow_node_332(p_tournament_id,r.id,'ROUND','ROUND_CONFIGURATION',100+r.numero_ronda*100,v_status,NULL,'ROUND_GROUPS',NULL,
          jsonb_build_object('round_number',r.numero_ronda,'date',r.fecha,'start_format',r.formato_salida::text,'course_id',r.campo_golf_id),
          CASE WHEN v_status='COMPLETE' THEN 'Ronda configurada.' ELSE 'Configuración de ronda pendiente.' END,NULL);

        -- ROUND_GROUPS: la evidencia común es la materialización de grupos.
        v_status := CASE WHEN v_group_count>0 THEN 'COMPLETE' WHEN v_freeze_count=0 THEN 'BLOCKED' ELSE 'AVAILABLE' END;
        v_block := CASE WHEN v_group_count=0 AND v_freeze_count=0 THEN 'FREEZE' END;
        PERFORM public._upsert_workflow_node_332(p_tournament_id,r.id,'ROUND','ROUND_GROUPS',110+r.numero_ronda*100,v_status,'ROUND_CONFIGURATION','ROUND_STARTS',v_block,
          jsonb_build_object('group_count',v_group_count,'start_format',r.formato_salida::text),
          CASE WHEN v_group_count>0 THEN 'Grupos materializados.' WHEN v_status='BLOCKED' THEN 'Requiere Freeze.' ELSE 'Armado de grupos disponible.' END,NULL);

        -- ROUND_STARTS
        v_status := CASE WHEN v_validation_count>0 THEN 'COMPLETE' WHEN v_group_count=0 THEN 'BLOCKED' ELSE 'AVAILABLE' END;
        v_block := CASE WHEN v_validation_count=0 AND v_group_count=0 THEN 'ROUND_GROUPS' END;
        PERFORM public._upsert_workflow_node_332(p_tournament_id,r.id,'ROUND','ROUND_STARTS',120+r.numero_ronda*100,v_status,'ROUND_GROUPS','SCORECARD_EMISSION',v_block,
          jsonb_build_object('active_validations',v_validation_count),
          CASE WHEN v_validation_count>0 THEN 'Salidas validadas.' WHEN v_status='BLOCKED' THEN 'Requiere grupos.' ELSE 'Validación de salidas disponible.' END,NULL);

        -- SCORECARD_EMISSION
        v_status := CASE WHEN v_emission_count>0 THEN 'COMPLETE' WHEN v_validation_count=0 THEN 'BLOCKED' ELSE 'AVAILABLE' END;
        v_block := CASE WHEN v_emission_count=0 AND v_validation_count=0 THEN 'ROUND_STARTS' END;
        PERFORM public._upsert_workflow_node_332(p_tournament_id,r.id,'ROUND','SCORECARD_EMISSION',130+r.numero_ronda*100,v_status,'ROUND_STARTS','ROUND_SCORING_INIT',v_block,
          jsonb_build_object('active_emissions',v_emission_count),
          CASE WHEN v_emission_count>0 THEN 'Tarjetas emitidas.' WHEN v_status='BLOCKED' THEN 'Requiere salidas validadas.' ELSE 'Emisión disponible.' END,NULL);

        -- ROUND_SCORING_INIT
        v_status := CASE WHEN v_capture_count>0 THEN 'COMPLETE' WHEN v_emission_count=0 THEN 'BLOCKED' ELSE 'AVAILABLE' END;
        v_block := CASE WHEN v_capture_count=0 AND v_emission_count=0 THEN 'SCORECARD_EMISSION' END;
        PERFORM public._upsert_workflow_node_332(p_tournament_id,r.id,'ROUND','ROUND_SCORING_INIT',140+r.numero_ronda*100,v_status,'SCORECARD_EMISSION','ROUND_PLAY',v_block,
          jsonb_build_object('capture_sessions',v_capture_count),
          CASE WHEN v_capture_count>0 THEN 'Captura inicializada.' WHEN v_status='BLOCKED' THEN 'Requiere tarjetas emitidas.' ELSE 'Inicialización de captura disponible.' END,NULL);

        -- ROUND_PLAY. Respeta dependencia de ronda anterior, además de lifecycle 314.
        v_status := CASE WHEN v_lifecycle_completed IS NOT NULL THEN 'COMPLETE'
          WHEN v_lifecycle_started IS NOT NULL THEN 'IN_PROGRESS'
          WHEN NOT v_prev_complete THEN 'BLOCKED'
          WHEN v_capture_count=0 THEN 'BLOCKED'
          ELSE 'AVAILABLE' END;
        v_block := CASE WHEN v_lifecycle_started IS NULL AND NOT v_prev_complete THEN 'PREVIOUS_ROUND_CLOSE'
                        WHEN v_lifecycle_started IS NULL AND v_capture_count=0 THEN 'ROUND_SCORING_INIT' END;
        PERFORM public._upsert_workflow_node_332(p_tournament_id,r.id,'ROUND','ROUND_PLAY',150+r.numero_ronda*100,v_status,'ROUND_SCORING_INIT','ROUND_COMPETITIVE_CLOSE',v_block,
          jsonb_build_object('started_at',v_lifecycle_started,'completed_at',v_lifecycle_completed,'previous_round_complete',v_prev_complete),
          CASE WHEN v_lifecycle_completed IS NOT NULL THEN 'Ronda finalizada.' WHEN v_lifecycle_started IS NOT NULL THEN 'Ronda en juego.' WHEN v_status='BLOCKED' THEN 'Ronda bloqueada por antecedente operativo.' ELSE 'Ronda disponible para iniciar.' END,v_lifecycle_completed);

        -- ROUND_COMPETITIVE_CLOSE
        v_status := CASE WHEN v_round_close IS NOT NULL THEN 'COMPLETE'
          WHEN v_lifecycle_started IS NULL THEN 'BLOCKED' ELSE 'AVAILABLE' END;
        v_block := CASE WHEN v_round_close IS NULL AND v_lifecycle_started IS NULL THEN 'ROUND_PLAY' END;
        PERFORM public._upsert_workflow_node_332(p_tournament_id,r.id,'ROUND','ROUND_COMPETITIVE_CLOSE',160+r.numero_ronda*100,v_status,'ROUND_PLAY',CASE WHEN v_cut_rule_count>0 THEN 'ROUND_CUT' ELSE NULL END,v_block,
          jsonb_build_object('closed_at',v_round_close),
          CASE WHEN v_round_close IS NOT NULL THEN 'Cierre competitivo registrado.' WHEN v_status='BLOCKED' THEN 'Requiere ronda iniciada y requisitos de cierre.' ELSE 'Cierre sujeto a validaciones deportivas existentes.' END,v_round_close);

        -- ROUND_CUT sólo cuando existe regla activa configurada para esa ronda.
        IF v_cut_rule_count>0 THEN
            v_status := CASE WHEN v_cut_status_count>0 THEN 'COMPLETE' WHEN v_round_close IS NULL THEN 'BLOCKED' ELSE 'AVAILABLE' END;
            v_block := CASE WHEN v_cut_status_count=0 AND v_round_close IS NULL THEN 'ROUND_COMPETITIVE_CLOSE' END;
            PERFORM public._upsert_workflow_node_332(p_tournament_id,r.id,'ROUND','ROUND_CUT',170+r.numero_ronda*100,v_status,'ROUND_COMPETITIVE_CLOSE',NULL,v_block,
              jsonb_build_object('active_cut_rules',v_cut_rule_count,'cut_status_rows',v_cut_status_count),
              CASE WHEN v_cut_status_count>0 THEN 'Corte materializado.' WHEN v_status='BLOCKED' THEN 'Requiere cierre de ronda.' ELSE 'Corte configurado y pendiente de aplicación.' END,NULL);
        ELSE
            DELETE FROM public.tournament_workflow_nodes WHERE tournament_id=p_tournament_id AND tournament_round_id=r.id AND code='ROUND_CUT';
        END IF;

        v_prev_complete := (v_round_close IS NOT NULL);
    END LOOP;

    -- 900 TOURNAMENT_FINALIZATION: proyección; la RPC real sigue siendo la autoridad.
    v_status := CASE WHEN v_finalized_at IS NOT NULL OR t.estatus::text='finalizado' THEN 'COMPLETE'
      WHEN EXISTS (SELECT 1 FROM public.tournament_rounds rr WHERE rr.tournament_id=p_tournament_id AND rr.activo=true)
       AND NOT EXISTS (
          SELECT 1 FROM public.tournament_rounds rr
          WHERE rr.tournament_id=p_tournament_id AND rr.activo=true
            AND NOT EXISTS (SELECT 1 FROM public.tournament_round_competitive_closures c WHERE c.tournament_round_id=rr.id AND c.competitive_status='FINAL')
       ) THEN 'AVAILABLE'
      ELSE 'BLOCKED' END;
    v_block := CASE WHEN v_status='BLOCKED' THEN 'ROUND_COMPETITIVE_CLOSE' END;
    PERFORM public._upsert_workflow_node_332(p_tournament_id,NULL,'TOURNAMENT','TOURNAMENT_FINALIZATION',900,v_status,'START_TOURNAMENT',NULL,v_block,
      jsonb_build_object('finalized_at',v_finalized_at,'tournament_status',t.estatus::text),
      CASE WHEN v_status='COMPLETE' THEN 'Torneo finalizado.' WHEN v_status='AVAILABLE' THEN 'Todas las rondas tienen cierre competitivo; finalización sujeta a validaciones existentes.' ELSE 'Existen rondas pendientes de cierre.' END,v_finalized_at);

    SELECT count(*) INTO v_nodes FROM public.tournament_workflow_nodes WHERE tournament_id=p_tournament_id;
    RETURN jsonb_build_object('ok',true,'tournament_id',p_tournament_id,'node_count',v_nodes,'reconciled_at',now());
END;
$$;

CREATE OR REPLACE FUNCTION public.obtener_workflow_materializado_332(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_result jsonb;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
    IF NOT public.puede_ver_congelamiento_torneo(p_tournament_id) THEN RAISE EXCEPTION 'Sin permisos para consultar este torneo'; END IF;

    SELECT jsonb_build_object(
      'tournament_id',p_tournament_id,
      'nodes',COALESCE(jsonb_agg(jsonb_build_object(
          'id',n.id,'scope',n.scope,'round_id',n.tournament_round_id,'code',n.code,
          'sequence',n.sequence_no,'status',n.status,'previous_code',n.previous_code,
          'next_code',n.next_code,'blocked_by_code',n.blocked_by_code,
          'detail',n.detail,'evidence',n.evidence,'completed_at',n.completed_at,
          'reconciled_at',n.reconciled_at
      ) ORDER BY n.sequence_no,n.code),'[]'::jsonb)
    ) INTO v_result
    FROM public.tournament_workflow_nodes n WHERE n.tournament_id=p_tournament_id;

    RETURN COALESCE(v_result,jsonb_build_object('tournament_id',p_tournament_id,'nodes','[]'::jsonb));
END;
$$;

-- Función administrativa explícita para reconstrucción manual/diagnóstica.
CREATE OR REPLACE FUNCTION public.reconciliar_workflow_torneo_332(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN RAISE EXCEPTION 'Sin permisos para administrar este torneo'; END IF;
    RETURN public.reconstruir_workflow_torneo_332(p_tournament_id);
END;
$$;

REVOKE ALL ON FUNCTION public._upsert_workflow_node_332(uuid,uuid,text,text,integer,text,text,text,text,jsonb,text,timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reconstruir_workflow_torneo_332(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.obtener_workflow_materializado_332(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_workflow_materializado_332(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.reconciliar_workflow_torneo_332(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reconciliar_workflow_torneo_332(uuid) TO authenticated;

-- Backfill/reconciliación inicial de torneos NO cancelados.
DO $$
DECLARE v_t record;
BEGIN
  FOR v_t IN SELECT id FROM public.tournaments WHERE estatus IS DISTINCT FROM 'cancelado'::public.estatus_torneo LOOP
    PERFORM public.reconstruir_workflow_torneo_332(v_t.id);
  END LOOP;
END;
$$;

COMMIT;
