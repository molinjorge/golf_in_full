-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 324
-- BEST BALL F10 — CONCILIACION POR JUGADOR / HOYO
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.tournament_best_ball_hole_resolutions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reconciliation_id uuid NOT NULL
        REFERENCES public.tournament_scorecard_reconciliations(id) ON DELETE RESTRICT,
    score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id) ON DELETE RESTRICT,
    best_ball_scorecard_member_id uuid NOT NULL
        REFERENCES public.tournament_best_ball_scorecard_members(id) ON DELETE RESTRICT,
    player_id uuid NOT NULL REFERENCES public.players(id) ON DELETE RESTRICT,
    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,
    round_hole_snapshot_id uuid NOT NULL
        REFERENCES public.tournament_round_hole_snapshots(id) ON DELETE RESTRICT,
    hole_number integer NOT NULL CHECK(hole_number>0),
    play_sequence integer NOT NULL CHECK(play_sequence>0),

    digital_result_type_snapshot text NULL
        CHECK(digital_result_type_snapshot IS NULL OR digital_result_type_snapshot IN ('SCORE','PICKUP')),
    digital_gross_snapshot integer NULL CHECK(digital_gross_snapshot IS NULL OR digital_gross_snapshot>0),
    player_claim_result_type_snapshot text NULL
        CHECK(player_claim_result_type_snapshot IS NULL OR player_claim_result_type_snapshot IN ('SCORE','PICKUP')),
    player_claim_gross_snapshot integer NULL CHECK(player_claim_gross_snapshot IS NULL OR player_claim_gross_snapshot>0),
    physical_result_type_snapshot text NULL
        CHECK(physical_result_type_snapshot IS NULL OR physical_result_type_snapshot IN ('SCORE','PICKUP')),
    physical_gross_snapshot integer NULL CHECK(physical_gross_snapshot IS NULL OR physical_gross_snapshot>0),

    resolution_source text NOT NULL
        CHECK(resolution_source IN ('DIGITAL','PHYSICAL','PLAYER_CLAIM','MANUAL')),
    resolved_result_type text NOT NULL CHECK(resolved_result_type IN ('SCORE','PICKUP')),
    resolved_gross_score integer NULL CHECK(resolved_gross_score IS NULL OR resolved_gross_score>0),
    reason text NULL,

    resolved_by_admin_user_id uuid NOT NULL,
    resolved_at timestamptz NOT NULL DEFAULT now(),
    updated_by_admin_user_id uuid NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT best_ball_resolution_state_ck CHECK (
       (resolved_result_type='SCORE' AND resolved_gross_score IS NOT NULL)
       OR
       (resolved_result_type='PICKUP' AND resolved_gross_score IS NULL)
    ),

    UNIQUE(score_card_id,best_ball_scorecard_member_id,round_hole_snapshot_id),
    UNIQUE(score_card_id,best_ball_scorecard_member_id,play_sequence)
);

CREATE INDEX IF NOT EXISTS ix_best_ball_resolutions_rec
ON public.tournament_best_ball_hole_resolutions(reconciliation_id);

ALTER TABLE public.tournament_best_ball_hole_resolutions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.tournament_best_ball_hole_resolutions FROM anon,authenticated;
GRANT ALL ON TABLE public.tournament_best_ball_hole_resolutions TO service_role;

CREATE TABLE IF NOT EXISTS public.tournament_best_ball_reconciliation_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reconciliation_id uuid NOT NULL
        REFERENCES public.tournament_scorecard_reconciliations(id) ON DELETE RESTRICT,
    score_card_id uuid NOT NULL REFERENCES public.tournament_score_cards(id) ON DELETE RESTRICT,
    best_ball_hole_resolution_id uuid NULL
        REFERENCES public.tournament_best_ball_hole_resolutions(id) ON DELETE RESTRICT,
    event_type text NOT NULL CHECK(event_type IN ('member_hole_resolved','member_hole_resolution_changed')),
    actor_admin_user_id uuid NOT NULL,
    old_resolved_result_type text NULL,
    new_resolved_result_type text NULL,
    old_resolved_gross_score integer NULL,
    new_resolved_gross_score integer NULL,
    old_resolution_source text NULL,
    new_resolution_source text NULL,
    reason text NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.tournament_best_ball_reconciliation_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.tournament_best_ball_reconciliation_events FROM anon,authenticated;
GRANT ALL ON TABLE public.tournament_best_ball_reconciliation_events TO service_role;

CREATE OR REPLACE FUNCTION public.iniciar_conciliacion_best_ball_324(p_score_card_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
 v_card public.tournament_score_cards;
 v_reception public.tournament_scorecard_physical_receptions;
 v_rec public.tournament_scorecard_reconciliations;
 v_admin uuid;
BEGIN
 v_card:=public._obtener_score_card_best_ball_fisica_323(p_score_card_id);
 v_admin:=public._scorecard_current_admin_id();
 IF v_admin IS NULL THEN RAISE EXCEPTION 'Administrador activo requerido.' USING ERRCODE='42501'; END IF;

 SELECT * INTO v_reception FROM public.tournament_scorecard_physical_receptions
 WHERE score_card_id=v_card.id LIMIT 1;
 IF v_reception.id IS NULL OR v_reception.status<>'CAPTURED' THEN
   RAISE EXCEPTION 'La conciliación Best Ball sólo inicia después de finalizar la captura física.' USING ERRCODE='55000';
 END IF;

 SELECT * INTO v_rec FROM public.tournament_scorecard_reconciliations
 WHERE score_card_id=v_card.id FOR UPDATE;

 IF v_rec.id IS NOT NULL THEN
   IF v_rec.status='VOIDED' THEN RAISE EXCEPTION 'La conciliación está anulada.' USING ERRCODE='55000'; END IF;
   IF v_rec.status='PENDING' THEN
     UPDATE public.tournament_scorecard_reconciliations
     SET status='IN_REVIEW',started_at=now(),started_by_admin_user_id=v_admin,updated_at=now()
     WHERE id=v_rec.id RETURNING * INTO v_rec;
     INSERT INTO public.tournament_scorecard_reconciliation_events(
       reconciliation_id,score_card_id,event_type,actor_admin_user_id
     ) VALUES(v_rec.id,v_card.id,'reconciliation_started',v_admin);
   END IF;
   RETURN jsonb_build_object('reconciliationId',v_rec.id,'scoreCardId',v_card.id,'status',v_rec.status,'alreadyExisted',true);
 END IF;

 INSERT INTO public.tournament_scorecard_reconciliations(
   score_card_id,tournament_id,tournament_round_id,status,started_at,started_by_admin_user_id
 ) VALUES(v_card.id,v_card.tournament_id,v_card.tournament_round_id,'IN_REVIEW',now(),v_admin)
 RETURNING * INTO v_rec;

 INSERT INTO public.tournament_scorecard_reconciliation_events(
   reconciliation_id,score_card_id,event_type,actor_admin_user_id
 ) VALUES(v_rec.id,v_card.id,'reconciliation_started',v_admin);

 RETURN jsonb_build_object('reconciliationId',v_rec.id,'scoreCardId',v_card.id,'status',v_rec.status,'alreadyExisted',false);
END;
$function$;

CREATE OR REPLACE FUNCTION public.obtener_conciliacion_best_ball_324(p_score_card_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
 v_card public.tournament_score_cards;
 v_rec public.tournament_scorecard_reconciliations;
BEGIN
 v_card:=public._obtener_score_card_best_ball_fisica_323(p_score_card_id);
 SELECT * INTO v_rec FROM public.tournament_scorecard_reconciliations WHERE score_card_id=v_card.id LIMIT 1;

 RETURN jsonb_build_object(
  'scoreCardId',v_card.id,
  'reconciliation',CASE WHEN v_rec.id IS NULL THEN NULL ELSE jsonb_build_object(
    'id',v_rec.id,'status',v_rec.status,'startedAt',v_rec.started_at,'completedAt',v_rec.completed_at,'notes',v_rec.notes
  ) END,
  'evidence',COALESCE((
   SELECT jsonb_agg(jsonb_build_object(
    'bestBallScorecardMemberId',d.best_ball_scorecard_member_id,
    'playerId',d.player_id,
    'playerName',btrim(concat_ws(' ',p.nombres,p.apellidos)),
    'roundHoleSnapshotId',d.round_hole_snapshot_id,
    'holeNumber',d.hole_number,'playSequence',d.play_sequence,
    'digitalResultType',NULLIF(d.result_type,'PENDING'),
    'digitalGrossScore',d.gross_score,'digitalStatus',d.status,
    'playerClaimResultType',d.player_claimed_result_type,
    'playerClaimGrossScore',d.player_claimed_gross_score,
    'physicalResultType',ph.physical_result_type,
    'physicalGrossScore',ph.physical_gross_score,
    'comparisonStatus',CASE
      WHEN ph.id IS NULL THEN 'PENDIENTE_CAPTURA_FISICA'
      WHEN d.result_type='PENDING' THEN 'SIN_CAPTURA_DIGITAL'
      WHEN d.result_type IS NOT DISTINCT FROM ph.physical_result_type
       AND d.gross_score IS NOT DISTINCT FROM ph.physical_gross_score THEN 'COINCIDE'
      ELSE 'DIFERENCIA' END,
    'disputeStatus',CASE WHEN d.status='disputed' THEN 'ACTIVE' ELSE 'NONE' END,
    'resolution',CASE WHEN r.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id',r.id,'source',r.resolution_source,'resultType',r.resolved_result_type,
      'grossScore',r.resolved_gross_score,'reason',r.reason,'resolvedAt',r.resolved_at
    ) END
   ) ORDER BY d.play_sequence,bm.member_order,d.player_id)
   FROM public.tournament_best_ball_hole_scores d
   JOIN public.tournament_best_ball_scorecard_members bm ON bm.id=d.best_ball_scorecard_member_id
   LEFT JOIN public.players p ON p.id=d.player_id
   LEFT JOIN public.tournament_best_ball_physical_hole_scores ph
     ON ph.score_card_id=d.score_card_id
    AND ph.best_ball_scorecard_member_id=d.best_ball_scorecard_member_id
    AND ph.round_hole_snapshot_id=d.round_hole_snapshot_id
   LEFT JOIN public.tournament_best_ball_hole_resolutions r
     ON r.score_card_id=d.score_card_id
    AND r.best_ball_scorecard_member_id=d.best_ball_scorecard_member_id
    AND r.round_hole_snapshot_id=d.round_hole_snapshot_id
   WHERE d.score_card_id=v_card.id
  ),'[]'::jsonb)
 );
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolver_conciliacion_best_ball_324(
 p_score_card_id uuid,
 p_best_ball_scorecard_member_id uuid,
 p_round_hole_snapshot_id uuid,
 p_resolution_source text,
 p_manual_result_type text DEFAULT NULL,
 p_manual_gross_score integer DEFAULT NULL,
 p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
 v_card public.tournament_score_cards;
 v_rec public.tournament_scorecard_reconciliations;
 v_d public.tournament_best_ball_hole_scores;
 v_ph public.tournament_best_ball_physical_hole_scores;
 v_existing public.tournament_best_ball_hole_resolutions;
 v_saved public.tournament_best_ball_hole_resolutions;
 v_admin uuid;
 v_source text;
 v_type text;
 v_gross integer;
 v_needs boolean;
 v_event text;
BEGIN
 v_card:=public._obtener_score_card_best_ball_fisica_323(p_score_card_id);
 v_admin:=public._scorecard_current_admin_id();
 IF v_admin IS NULL THEN RAISE EXCEPTION 'Administrador activo requerido.' USING ERRCODE='42501'; END IF;

 SELECT * INTO v_rec FROM public.tournament_scorecard_reconciliations
 WHERE score_card_id=v_card.id FOR UPDATE;
 IF v_rec.id IS NULL OR v_rec.status<>'IN_REVIEW' THEN
   RAISE EXCEPTION 'La conciliación Best Ball no admite resoluciones en su estado actual.' USING ERRCODE='55000';
 END IF;

 SELECT * INTO v_d FROM public.tournament_best_ball_hole_scores
 WHERE score_card_id=v_card.id
   AND best_ball_scorecard_member_id=p_best_ball_scorecard_member_id
   AND round_hole_snapshot_id=p_round_hole_snapshot_id LIMIT 1;
 IF v_d.id IS NULL THEN RAISE EXCEPTION 'Integrante/hoyo Best Ball inválido.' USING ERRCODE='22023'; END IF;

 SELECT * INTO v_ph FROM public.tournament_best_ball_physical_hole_scores
 WHERE score_card_id=v_card.id
   AND best_ball_scorecard_member_id=p_best_ball_scorecard_member_id
   AND round_hole_snapshot_id=p_round_hole_snapshot_id LIMIT 1;
 IF v_ph.id IS NULL THEN RAISE EXCEPTION 'No existe evidencia física para este integrante/hoyo.' USING ERRCODE='55000'; END IF;

 v_needs := v_d.status='disputed'
    OR v_d.result_type='PENDING'
    OR v_d.result_type IS DISTINCT FROM v_ph.physical_result_type
    OR v_d.gross_score IS DISTINCT FROM v_ph.physical_gross_score;

 IF NOT v_needs THEN
   RAISE EXCEPTION 'Este resultado individual coincide y no requiere resolución explícita.' USING ERRCODE='22023';
 END IF;

 v_source:=upper(btrim(COALESCE(p_resolution_source,'')));
 IF v_source NOT IN ('DIGITAL','PHYSICAL','PLAYER_CLAIM','MANUAL') THEN
   RAISE EXCEPTION 'resolution_source inválido.' USING ERRCODE='22023';
 END IF;

 IF v_source='DIGITAL' THEN
   v_type:=NULLIF(v_d.result_type,'PENDING'); v_gross:=v_d.gross_score;
 ELSIF v_source='PHYSICAL' THEN
   v_type:=v_ph.physical_result_type; v_gross:=v_ph.physical_gross_score;
 ELSIF v_source='PLAYER_CLAIM' THEN
   v_type:=v_d.player_claimed_result_type; v_gross:=v_d.player_claimed_gross_score;
 ELSE
   v_type:=upper(btrim(COALESCE(p_manual_result_type,''))); v_gross:=p_manual_gross_score;
 END IF;

 IF v_type NOT IN ('SCORE','PICKUP') THEN
   RAISE EXCEPTION 'La fuente seleccionada no contiene un resultado válido.' USING ERRCODE='22023';
 END IF;
 IF v_type='SCORE' AND (v_gross IS NULL OR v_gross<=0) THEN
   RAISE EXCEPTION 'SCORE resuelto requiere gross mayor que cero.' USING ERRCODE='22023';
 END IF;
 IF v_type='PICKUP' THEN v_gross:=NULL; END IF;
 IF v_source='MANUAL' AND length(btrim(COALESCE(p_reason,'')))<5 THEN
   RAISE EXCEPTION 'MANUAL requiere motivo de al menos 5 caracteres.' USING ERRCODE='22023';
 END IF;

 SELECT * INTO v_existing FROM public.tournament_best_ball_hole_resolutions
 WHERE score_card_id=v_card.id
   AND best_ball_scorecard_member_id=p_best_ball_scorecard_member_id
   AND round_hole_snapshot_id=p_round_hole_snapshot_id
 FOR UPDATE;

 IF v_existing.id IS NULL THEN
   INSERT INTO public.tournament_best_ball_hole_resolutions(
    reconciliation_id,score_card_id,best_ball_scorecard_member_id,player_id,
    tournament_round_id,round_hole_snapshot_id,hole_number,play_sequence,
    digital_result_type_snapshot,digital_gross_snapshot,
    player_claim_result_type_snapshot,player_claim_gross_snapshot,
    physical_result_type_snapshot,physical_gross_snapshot,
    resolution_source,resolved_result_type,resolved_gross_score,reason,
    resolved_by_admin_user_id,updated_by_admin_user_id
   ) VALUES(
    v_rec.id,v_card.id,v_d.best_ball_scorecard_member_id,v_d.player_id,
    v_card.tournament_round_id,v_d.round_hole_snapshot_id,v_d.hole_number,v_d.play_sequence,
    NULLIF(v_d.result_type,'PENDING'),v_d.gross_score,
    v_d.player_claimed_result_type,v_d.player_claimed_gross_score,
    v_ph.physical_result_type,v_ph.physical_gross_score,
    v_source,v_type,v_gross,NULLIF(btrim(COALESCE(p_reason,'')),''),
    v_admin,v_admin
   ) RETURNING * INTO v_saved;
   v_event:='member_hole_resolved';
 ELSE
   UPDATE public.tournament_best_ball_hole_resolutions SET
    digital_result_type_snapshot=NULLIF(v_d.result_type,'PENDING'),
    digital_gross_snapshot=v_d.gross_score,
    player_claim_result_type_snapshot=v_d.player_claimed_result_type,
    player_claim_gross_snapshot=v_d.player_claimed_gross_score,
    physical_result_type_snapshot=v_ph.physical_result_type,
    physical_gross_snapshot=v_ph.physical_gross_score,
    resolution_source=v_source,resolved_result_type=v_type,resolved_gross_score=v_gross,
    reason=NULLIF(btrim(COALESCE(p_reason,'')),''),
    updated_by_admin_user_id=v_admin,updated_at=now()
   WHERE id=v_existing.id RETURNING * INTO v_saved;
   v_event:='member_hole_resolution_changed';
 END IF;

 INSERT INTO public.tournament_best_ball_reconciliation_events(
  reconciliation_id,score_card_id,best_ball_hole_resolution_id,event_type,actor_admin_user_id,
  old_resolved_result_type,new_resolved_result_type,old_resolved_gross_score,new_resolved_gross_score,
  old_resolution_source,new_resolution_source,reason
 ) VALUES(
  v_rec.id,v_card.id,v_saved.id,v_event,v_admin,
  CASE WHEN v_existing.id IS NULL THEN NULL ELSE v_existing.resolved_result_type END,
  v_saved.resolved_result_type,
  CASE WHEN v_existing.id IS NULL THEN NULL ELSE v_existing.resolved_gross_score END,
  v_saved.resolved_gross_score,
  CASE WHEN v_existing.id IS NULL THEN NULL ELSE v_existing.resolution_source END,
  v_saved.resolution_source,v_saved.reason
 );

 RETURN jsonb_build_object(
  'reconciliationId',v_rec.id,'resolutionId',v_saved.id,
  'bestBallScorecardMemberId',v_saved.best_ball_scorecard_member_id,
  'playerId',v_saved.player_id,'roundHoleSnapshotId',v_saved.round_hole_snapshot_id,
  'holeNumber',v_saved.hole_number,'resolutionSource',v_saved.resolution_source,
  'resolvedResultType',v_saved.resolved_result_type,'resolvedGrossScore',v_saved.resolved_gross_score
 );
END;
$function$;

CREATE OR REPLACE FUNCTION public.finalizar_conciliacion_best_ball_324(
 p_score_card_id uuid,p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
 v_card public.tournament_score_cards;
 v_rec public.tournament_scorecard_reconciliations;
 v_admin uuid;
 v_total integer; v_missing_physical integer; v_review integer; v_unresolved integer;
BEGIN
 v_card:=public._obtener_score_card_best_ball_fisica_323(p_score_card_id);
 v_admin:=public._scorecard_current_admin_id();
 IF v_admin IS NULL THEN RAISE EXCEPTION 'Administrador activo requerido.' USING ERRCODE='42501'; END IF;

 SELECT * INTO v_rec FROM public.tournament_scorecard_reconciliations
 WHERE score_card_id=v_card.id FOR UPDATE;
 IF v_rec.id IS NULL THEN RAISE EXCEPTION 'Primero debe iniciarse la conciliación Best Ball.' USING ERRCODE='55000'; END IF;
 IF v_rec.status='COMPLETED' THEN
   RETURN jsonb_build_object('reconciliationId',v_rec.id,'scoreCardId',v_card.id,'status','COMPLETED','alreadyCompleted',true);
 END IF;
 IF v_rec.status<>'IN_REVIEW' THEN RAISE EXCEPTION 'La conciliación no puede finalizar en su estado actual.' USING ERRCODE='55000'; END IF;

 WITH e AS (
  SELECT d.id,d.best_ball_scorecard_member_id,d.round_hole_snapshot_id,
         d.result_type,d.gross_score,d.status,
         ph.id physical_id,ph.physical_result_type,ph.physical_gross_score,
         r.id resolution_id,
         (d.status='disputed'
          OR d.result_type='PENDING'
          OR d.result_type IS DISTINCT FROM ph.physical_result_type
          OR d.gross_score IS DISTINCT FROM ph.physical_gross_score) needs_review
  FROM public.tournament_best_ball_hole_scores d
  LEFT JOIN public.tournament_best_ball_physical_hole_scores ph
    ON ph.score_card_id=d.score_card_id
   AND ph.best_ball_scorecard_member_id=d.best_ball_scorecard_member_id
   AND ph.round_hole_snapshot_id=d.round_hole_snapshot_id
  LEFT JOIN public.tournament_best_ball_hole_resolutions r
    ON r.score_card_id=d.score_card_id
   AND r.best_ball_scorecard_member_id=d.best_ball_scorecard_member_id
   AND r.round_hole_snapshot_id=d.round_hole_snapshot_id
  WHERE d.score_card_id=v_card.id
 )
 SELECT count(*),count(*) FILTER(WHERE physical_id IS NULL),
        count(*) FILTER(WHERE needs_review),
        count(*) FILTER(WHERE needs_review AND resolution_id IS NULL)
 INTO v_total,v_missing_physical,v_review,v_unresolved FROM e;

 IF v_total<=0 THEN RAISE EXCEPTION 'No existe estructura Best Ball para conciliar.' USING ERRCODE='55000'; END IF;
 IF v_missing_physical>0 THEN
   RAISE EXCEPTION 'Faltan % resultados físicos individuales.',v_missing_physical USING ERRCODE='55000';
 END IF;
 IF v_unresolved>0 THEN
   RAISE EXCEPTION 'Quedan % resultados individuales por resolver.',v_unresolved USING ERRCODE='55000';
 END IF;

 UPDATE public.tournament_scorecard_reconciliations
 SET status='COMPLETED',completed_at=now(),completed_by_admin_user_id=v_admin,
     notes=COALESCE(NULLIF(btrim(COALESCE(p_notes,'')),''),notes),updated_at=now()
 WHERE id=v_rec.id RETURNING * INTO v_rec;

 INSERT INTO public.tournament_scorecard_reconciliation_events(
  reconciliation_id,score_card_id,event_type,actor_admin_user_id,reason
 ) VALUES(v_rec.id,v_card.id,'reconciliation_completed',v_admin,NULLIF(btrim(COALESCE(p_notes,'')),''));

 RETURN jsonb_build_object(
  'reconciliationId',v_rec.id,'scoreCardId',v_card.id,'status','COMPLETED',
  'individualResultsTotal',v_total,'reviewResults',v_review,
  'resolvedReviewResults',v_review,'completedAt',v_rec.completed_at
 );
END;
$function$;

COMMIT;
