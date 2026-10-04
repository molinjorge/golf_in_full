-- TEE CENTRAL / GOLF IN FULL
-- Migración 423
-- Infraestructura transversal de captura pública por QR para tarjetas oficiales
-- NO ejecutar desde IA. Ejecutar manualmente en Supabase SQL Editor.
--
-- Alcance:
--   * acceso/control QR común por tournament_score_cards.qr_token
--   * un solo dispositivo escritor por tarjeta (lease 5 min, heartbeat)
--   * captura/corrección QR para stroke, stableford, team_stroke (A-Go-Go) y best_ball
--   * inconformidad QR sin atribuir identidad humana
--   * auditoría QR y compatibilidad con conciliación
--   * NO elimina asignaciones de marcador legacy
--   * NO crea sesiones deportivas faltantes
--   * NO cambia reglas deportivas de cálculo
--
-- Rollout seguro:
--   Esta migración NO deshabilita globalmente la captura legacy solo por
--   usar_tarjeta_digital=true, porque existen torneos históricos/activos con ese
--   valor heredado. Sí impide escritura legacy mientras exista un control QR
--   vigente sobre la tarjeta. La exclusividad total del nuevo flujo se activa
--   desde la UI/ruta QR cuando el torneo sea operado con el nuevo mecanismo.

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. Preflight mínimo
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.tournament_score_cards') IS NULL
     OR to_regclass('public.tournament_score_card_emissions') IS NULL
     OR to_regclass('public.tournament_scorecard_capture_sessions') IS NULL
     OR to_regclass('public.tournament_scorecard_hole_scores') IS NULL
     OR to_regclass('public.tournament_scorecard_events') IS NULL
     OR to_regclass('public.tournament_best_ball_hole_scores') IS NULL
     OR to_regclass('public.tournament_best_ball_scorecard_events') IS NULL
  THEN
    RAISE EXCEPTION '423 abortada: falta infraestructura de tarjetas/captura esperada.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='tournaments'
      AND column_name='usar_tarjeta_digital' AND data_type='boolean'
  ) THEN
    RAISE EXCEPTION '423 abortada: tournaments.usar_tarjeta_digital no existe o no es boolean.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. Control técnico exclusivo del dispositivo (separado de capture_sessions)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tournament_scorecard_qr_capture_controls (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  score_card_id uuid NOT NULL REFERENCES public.tournament_score_cards(id) ON DELETE CASCADE,
  capture_session_id uuid NOT NULL REFERENCES public.tournament_scorecard_capture_sessions(id) ON DELETE CASCADE,
  control_token_hash text NOT NULL,
  acquired_at timestamptz NOT NULL DEFAULT now(),
  last_heartbeat_at timestamptz NOT NULL DEFAULT now(),
  last_activity_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  released_at timestamptz NULL,
  release_reason text NULL,
  released_by_admin_user_id uuid NULL,
  CONSTRAINT tournament_scorecard_qr_controls_hash_ck CHECK (length(control_token_hash)=64),
  CONSTRAINT tournament_scorecard_qr_controls_release_reason_ck CHECK (
    release_reason IS NULL OR release_reason IN ('voluntary','expired','committee')
  ),
  CONSTRAINT tournament_scorecard_qr_controls_release_ck CHECK (
    (released_at IS NULL AND release_reason IS NULL AND released_by_admin_user_id IS NULL)
    OR
    (released_at IS NOT NULL AND release_reason IS NOT NULL
      AND ((release_reason='committee' AND released_by_admin_user_id IS NOT NULL)
        OR (release_reason IN ('voluntary','expired') AND released_by_admin_user_id IS NULL)))
  ),
  CONSTRAINT tournament_scorecard_qr_controls_expiry_ck CHECK (expires_at > acquired_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS tournament_scorecard_qr_controls_one_active_uk
  ON public.tournament_scorecard_qr_capture_controls(score_card_id)
  WHERE released_at IS NULL;

CREATE INDEX IF NOT EXISTS tournament_scorecard_qr_controls_session_idx
  ON public.tournament_scorecard_qr_capture_controls(capture_session_id);

ALTER TABLE public.tournament_scorecard_qr_capture_controls ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.tournament_scorecard_qr_capture_controls FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.tournament_scorecard_qr_capture_controls IS
'423: lease técnico exclusivo por dispositivo para captura pública QR. No representa identidad humana ni sustituye capture_sessions.';

-- -----------------------------------------------------------------------------
-- 2. Trazabilidad de origen QR sin reclasificar historia
--    Las columnas nuevas quedan NULL en filas legacy; no se hace backfill.
-- -----------------------------------------------------------------------------
ALTER TABLE public.tournament_scorecard_hole_scores
  ADD COLUMN IF NOT EXISTS entry_source text NULL,
  ADD COLUMN IF NOT EXISTS qr_capture_control_id uuid NULL
    REFERENCES public.tournament_scorecard_qr_capture_controls(id);

ALTER TABLE public.tournament_best_ball_hole_scores
  ADD COLUMN IF NOT EXISTS entry_source text NULL,
  ADD COLUMN IF NOT EXISTS qr_capture_control_id uuid NULL
    REFERENCES public.tournament_scorecard_qr_capture_controls(id);

ALTER TABLE public.tournament_scorecard_events
  ADD COLUMN IF NOT EXISTS actor_source text NULL,
  ADD COLUMN IF NOT EXISTS qr_capture_control_id uuid NULL
    REFERENCES public.tournament_scorecard_qr_capture_controls(id);

ALTER TABLE public.tournament_best_ball_scorecard_events
  ADD COLUMN IF NOT EXISTS actor_source text NULL,
  ADD COLUMN IF NOT EXISTS qr_capture_control_id uuid NULL
    REFERENCES public.tournament_scorecard_qr_capture_controls(id);

-- Best Ball históricamente exige actor_player_id NOT NULL. QR necesita actor técnico.
ALTER TABLE public.tournament_best_ball_scorecard_events
  ALTER COLUMN actor_player_id DROP NOT NULL;

-- Valores de origen: NULL = legacy/pre-423; qr_public = captura QR 423.
ALTER TABLE public.tournament_scorecard_hole_scores
  DROP CONSTRAINT IF EXISTS tournament_scorecard_hole_scores_entry_source_ck;
ALTER TABLE public.tournament_scorecard_hole_scores
  ADD CONSTRAINT tournament_scorecard_hole_scores_entry_source_ck
  CHECK (entry_source IS NULL OR entry_source='qr_public');

ALTER TABLE public.tournament_best_ball_hole_scores
  DROP CONSTRAINT IF EXISTS tournament_best_ball_hole_scores_entry_source_ck;
ALTER TABLE public.tournament_best_ball_hole_scores
  ADD CONSTRAINT tournament_best_ball_hole_scores_entry_source_ck
  CHECK (entry_source IS NULL OR entry_source='qr_public');

ALTER TABLE public.tournament_scorecard_events
  DROP CONSTRAINT IF EXISTS tournament_scorecard_events_actor_source_ck;
ALTER TABLE public.tournament_scorecard_events
  ADD CONSTRAINT tournament_scorecard_events_actor_source_ck
  CHECK (actor_source IS NULL OR actor_source='qr_public');

ALTER TABLE public.tournament_best_ball_scorecard_events
  DROP CONSTRAINT IF EXISTS tournament_best_ball_scorecard_events_actor_source_ck;
ALTER TABLE public.tournament_best_ball_scorecard_events
  ADD CONSTRAINT tournament_best_ball_scorecard_events_actor_source_ck
  CHECK (actor_source IS NULL OR actor_source='qr_public');

-- -----------------------------------------------------------------------------
-- 3. CHECK de estados: conserva legacy y agrega únicamente QR_PUBLIC
-- -----------------------------------------------------------------------------
ALTER TABLE public.tournament_scorecard_hole_scores
  DROP CONSTRAINT tournament_scorecard_hole_scores_state_ck;
ALTER TABLE public.tournament_scorecard_hole_scores
  ADD CONSTRAINT tournament_scorecard_hole_scores_state_ck CHECK (
    (status='pending' AND result_type='PENDING' AND gross_score IS NULL
      AND marker_assignment_id IS NULL AND entered_by_player_id IS NULL AND entered_at IS NULL
      AND confirmed_by_player_id IS NULL AND confirmed_at IS NULL
      AND player_claimed_result_type IS NULL AND player_claimed_gross_score IS NULL
      AND dispute_note IS NULL AND disputed_at IS NULL
      AND entry_source IS NULL AND qr_capture_control_id IS NULL)
    OR
    (status='entered' AND result_type IN ('SCORE','PICKUP')
      AND ((result_type='SCORE' AND gross_score IS NOT NULL) OR (result_type='PICKUP' AND gross_score IS NULL))
      AND entered_at IS NOT NULL AND confirmed_by_player_id IS NULL AND confirmed_at IS NULL
      AND player_claimed_result_type IS NULL AND player_claimed_gross_score IS NULL
      AND dispute_note IS NULL AND disputed_at IS NULL
      AND (
        (entry_source IS NULL AND marker_assignment_id IS NOT NULL AND entered_by_player_id IS NOT NULL AND qr_capture_control_id IS NULL)
        OR
        (entry_source='qr_public' AND marker_assignment_id IS NULL AND entered_by_player_id IS NULL AND qr_capture_control_id IS NOT NULL)
      ))
    OR
    (status='confirmed' AND result_type IN ('SCORE','PICKUP')
      AND ((result_type='SCORE' AND gross_score IS NOT NULL) OR (result_type='PICKUP' AND gross_score IS NULL))
      AND entered_at IS NOT NULL AND confirmed_by_player_id IS NOT NULL AND confirmed_at IS NOT NULL
      AND player_claimed_result_type IS NULL AND player_claimed_gross_score IS NULL
      AND dispute_note IS NULL AND disputed_at IS NULL
      AND (
        (entry_source IS NULL AND marker_assignment_id IS NOT NULL AND entered_by_player_id IS NOT NULL AND qr_capture_control_id IS NULL)
        OR
        (entry_source='qr_public' AND marker_assignment_id IS NULL AND entered_by_player_id IS NULL AND qr_capture_control_id IS NOT NULL)
      ))
    OR
    (status='disputed' AND result_type IN ('SCORE','PICKUP')
      AND ((result_type='SCORE' AND gross_score IS NOT NULL) OR (result_type='PICKUP' AND gross_score IS NULL))
      AND entered_at IS NOT NULL AND confirmed_by_player_id IS NULL AND confirmed_at IS NULL
      AND player_claimed_result_type IN ('SCORE','PICKUP')
      AND ((player_claimed_result_type='SCORE' AND player_claimed_gross_score IS NOT NULL)
        OR (player_claimed_result_type='PICKUP' AND player_claimed_gross_score IS NULL))
      AND (player_claimed_result_type IS DISTINCT FROM result_type OR player_claimed_gross_score IS DISTINCT FROM gross_score)
      AND disputed_at IS NOT NULL
      AND (
        (entry_source IS NULL AND marker_assignment_id IS NOT NULL AND entered_by_player_id IS NOT NULL AND qr_capture_control_id IS NULL)
        OR
        (entry_source='qr_public' AND marker_assignment_id IS NULL AND entered_by_player_id IS NULL AND qr_capture_control_id IS NOT NULL)
      ))
  );

ALTER TABLE public.tournament_best_ball_hole_scores
  DROP CONSTRAINT tournament_best_ball_hole_scores_state_ck;
ALTER TABLE public.tournament_best_ball_hole_scores
  ADD CONSTRAINT tournament_best_ball_hole_scores_state_ck CHECK (
    (status='pending' AND result_type='PENDING' AND gross_score IS NULL
      AND marker_assignment_id IS NULL AND entered_by_player_id IS NULL AND entered_at IS NULL
      AND confirmed_by_player_id IS NULL AND confirmed_at IS NULL
      AND player_claimed_result_type IS NULL AND player_claimed_gross_score IS NULL
      AND dispute_note IS NULL AND disputed_at IS NULL
      AND entry_source IS NULL AND qr_capture_control_id IS NULL)
    OR
    (status='entered' AND result_type IN ('SCORE','PICKUP')
      AND ((result_type='SCORE' AND gross_score IS NOT NULL) OR (result_type='PICKUP' AND gross_score IS NULL))
      AND entered_at IS NOT NULL AND confirmed_by_player_id IS NULL AND confirmed_at IS NULL
      AND player_claimed_result_type IS NULL AND player_claimed_gross_score IS NULL
      AND dispute_note IS NULL AND disputed_at IS NULL
      AND (
        (entry_source IS NULL AND marker_assignment_id IS NOT NULL AND entered_by_player_id IS NOT NULL AND qr_capture_control_id IS NULL)
        OR
        (entry_source='qr_public' AND marker_assignment_id IS NULL AND entered_by_player_id IS NULL AND qr_capture_control_id IS NOT NULL)
      ))
    OR
    (status='confirmed' AND result_type IN ('SCORE','PICKUP')
      AND ((result_type='SCORE' AND gross_score IS NOT NULL) OR (result_type='PICKUP' AND gross_score IS NULL))
      AND entered_at IS NOT NULL AND confirmed_by_player_id IS NOT NULL AND confirmed_at IS NOT NULL
      AND player_claimed_result_type IS NULL AND player_claimed_gross_score IS NULL
      AND dispute_note IS NULL AND disputed_at IS NULL
      AND (
        (entry_source IS NULL AND marker_assignment_id IS NOT NULL AND entered_by_player_id IS NOT NULL AND qr_capture_control_id IS NULL)
        OR
        (entry_source='qr_public' AND marker_assignment_id IS NULL AND entered_by_player_id IS NULL AND qr_capture_control_id IS NOT NULL)
      ))
    OR
    (status='disputed' AND result_type IN ('SCORE','PICKUP')
      AND ((result_type='SCORE' AND gross_score IS NOT NULL) OR (result_type='PICKUP' AND gross_score IS NULL))
      AND entered_at IS NOT NULL AND confirmed_by_player_id IS NULL AND confirmed_at IS NULL
      AND player_claimed_result_type IN ('SCORE','PICKUP')
      AND ((player_claimed_result_type='SCORE' AND player_claimed_gross_score IS NOT NULL)
        OR (player_claimed_result_type='PICKUP' AND player_claimed_gross_score IS NULL))
      AND (player_claimed_result_type IS DISTINCT FROM result_type OR player_claimed_gross_score IS DISTINCT FROM gross_score)
      AND disputed_at IS NOT NULL
      AND (
        (entry_source IS NULL AND marker_assignment_id IS NOT NULL AND entered_by_player_id IS NOT NULL AND qr_capture_control_id IS NULL)
        OR
        (entry_source='qr_public' AND marker_assignment_id IS NULL AND entered_by_player_id IS NULL AND qr_capture_control_id IS NOT NULL)
      ))
  );

-- -----------------------------------------------------------------------------
-- 4. Eventos QR e inconformidad QR
-- -----------------------------------------------------------------------------
ALTER TABLE public.tournament_scorecard_events
  DROP CONSTRAINT tournament_scorecard_events_one_actor_ck;
ALTER TABLE public.tournament_scorecard_events
  ADD CONSTRAINT tournament_scorecard_events_one_actor_ck CHECK (
    (actor_source IS NULL AND num_nonnulls(actor_player_id,actor_admin_user_id)=1 AND qr_capture_control_id IS NULL)
    OR
    (actor_source='qr_public' AND actor_player_id IS NULL AND actor_admin_user_id IS NULL AND qr_capture_control_id IS NOT NULL)
  );

ALTER TABLE public.tournament_scorecard_events
  DROP CONSTRAINT tournament_scorecard_events_event_type_check;
ALTER TABLE public.tournament_scorecard_events
  ADD CONSTRAINT tournament_scorecard_events_event_type_check CHECK (
    event_type IN ('score_entered','score_corrected','player_confirmed','player_disputed','qr_disputed','marker_changed')
  );

ALTER TABLE public.tournament_best_ball_scorecard_events
  DROP CONSTRAINT tournament_best_ball_scorecard_events_event_type_check;
ALTER TABLE public.tournament_best_ball_scorecard_events
  ADD CONSTRAINT tournament_best_ball_scorecard_events_event_type_check CHECK (
    event_type IN ('score_entered','score_corrected','player_confirmed','player_disputed','qr_disputed')
  );

ALTER TABLE public.tournament_best_ball_scorecard_events
  DROP CONSTRAINT IF EXISTS tournament_best_ball_scorecard_events_actor_423_ck;
ALTER TABLE public.tournament_best_ball_scorecard_events
  ADD CONSTRAINT tournament_best_ball_scorecard_events_actor_423_ck CHECK (
    (actor_source IS NULL AND actor_player_id IS NOT NULL AND qr_capture_control_id IS NULL)
    OR
    (actor_source='qr_public' AND actor_player_id IS NULL AND qr_capture_control_id IS NOT NULL)
  );

-- Best Ball: bitácora inmutable a partir de 423.
CREATE OR REPLACE FUNCTION public._impedir_mutacion_evento_best_ball_423()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
BEGIN
  RAISE EXCEPTION 'La bitácora digital Best Ball es inmutable.' USING ERRCODE='55000';
END;
$$;

DROP TRIGGER IF EXISTS trg_impedir_mutacion_evento_best_ball_423 ON public.tournament_best_ball_scorecard_events;
CREATE TRIGGER trg_impedir_mutacion_evento_best_ball_423
BEFORE UPDATE OR DELETE ON public.tournament_best_ball_scorecard_events
FOR EACH ROW EXECUTE FUNCTION public._impedir_mutacion_evento_best_ball_423();

-- -----------------------------------------------------------------------------
-- 5. Helpers internos. Nunca públicos.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._qr_hash_control_token_423(p_token text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path TO 'public','pg_temp'
AS $$
  SELECT encode(extensions.digest(p_token,'sha256'),'hex');
$$;

CREATE OR REPLACE FUNCTION public._qr_lock_card_423(p_score_card_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_score_card_id::text,18401));
END;
$$;

CREATE OR REPLACE FUNCTION public._qr_validar_control_423(
  p_score_card_id uuid,
  p_control_token text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_id uuid;
BEGIN
  IF p_control_token IS NULL OR length(p_control_token)<32 THEN
    RAISE EXCEPTION 'Control de captura inválido.' USING ERRCODE='42501';
  END IF;

  PERFORM public._qr_lock_card_423(p_score_card_id);

  UPDATE public.tournament_scorecard_qr_capture_controls
     SET released_at=now(), release_reason='expired'
   WHERE score_card_id=p_score_card_id
     AND released_at IS NULL
     AND expires_at<=now();

  SELECT id INTO v_id
    FROM public.tournament_scorecard_qr_capture_controls
   WHERE score_card_id=p_score_card_id
     AND released_at IS NULL
     AND expires_at>now()
     AND control_token_hash=public._qr_hash_control_token_423(p_control_token)
   FOR UPDATE;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'Este dispositivo no tiene el control activo de la captura.' USING ERRCODE='42501';
  END IF;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public._qr_hash_control_token_423(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._qr_lock_card_423(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._qr_validar_control_423(uuid,text) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 6. Lectura pública común por QR
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_tarjeta_publica_qr_423(
  p_qr_token text,
  p_control_token text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_card record;
  v_session record;
  v_engine text;
  v_participation text;
  v_control_state text:='free';
  v_scores jsonb;
BEGIN
  IF p_qr_token IS NULL OR p_qr_token !~ '^[0-9a-fA-F]{64}$' THEN
    RETURN jsonb_build_object('captureState','invalid');
  END IF;

  SELECT sc.id,sc.tournament_id,sc.tournament_round_id,sc.validation_id,sc.unit_type,
         sc.tournament_registration_id,sc.tournament_team_id,sc.player_id,
         t.usar_tarjeta_digital,e.status AS emission_status,
         v.scoring_engine,v.participation_type
    INTO v_card
    FROM public.tournament_score_cards sc
    JOIN public.tournament_score_card_emissions e ON e.id=sc.emission_id
    JOIN public.tournaments t ON t.id=sc.tournament_id
    JOIN public.tournament_round_start_validations v ON v.id=sc.validation_id
   WHERE lower(sc.qr_token)=lower(p_qr_token)
     AND sc.status='issued'
   LIMIT 1;

  IF v_card.id IS NULL OR v_card.emission_status<>'issued' THEN
    RETURN jsonb_build_object('captureState','invalid');
  END IF;

  IF NOT COALESCE(v_card.usar_tarjeta_digital,false) THEN
    RETURN jsonb_build_object('captureState','digital_disabled');
  END IF;

  SELECT * INTO v_session
    FROM public.tournament_scorecard_capture_sessions
   WHERE score_card_id=v_card.id;

  IF v_session.id IS NULL THEN
    RETURN jsonb_build_object(
      'captureState','not_initialized',
      'scoreCardId',v_card.id,
      'engine',v_card.scoring_engine,
      'participationType',v_card.participation_type,
      'unitType',v_card.unit_type
    );
  END IF;

  PERFORM public._qr_lock_card_423(v_card.id);
  UPDATE public.tournament_scorecard_qr_capture_controls
     SET released_at=now(),release_reason='expired'
   WHERE score_card_id=v_card.id AND released_at IS NULL AND expires_at<=now();

  IF EXISTS (
    SELECT 1 FROM public.tournament_scorecard_qr_capture_controls c
    WHERE c.score_card_id=v_card.id AND c.released_at IS NULL AND c.expires_at>now()
  ) THEN
    IF p_control_token IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.tournament_scorecard_qr_capture_controls c
      WHERE c.score_card_id=v_card.id AND c.released_at IS NULL AND c.expires_at>now()
        AND c.control_token_hash=public._qr_hash_control_token_423(p_control_token)
    ) THEN v_control_state:='mine'; ELSE v_control_state:='busy'; END IF;
  END IF;

  IF v_card.scoring_engine='best_ball' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'holeScoreId',hs.id,
      'bestBallScorecardMemberId',hs.best_ball_scorecard_member_id,
      'playerId',hs.player_id,
      'roundHoleSnapshotId',hs.round_hole_snapshot_id,
      'holeNumber',hs.hole_number,
      'playSequence',hs.play_sequence,
      'status',hs.status,'resultType',hs.result_type,'grossScore',hs.gross_score,
      'claimedResultType',hs.player_claimed_result_type,
      'claimedGrossScore',hs.player_claimed_gross_score,
      'disputeNote',hs.dispute_note
    ) ORDER BY hs.play_sequence,hs.best_ball_scorecard_member_id),'[]'::jsonb)
      INTO v_scores
      FROM public.tournament_best_ball_hole_scores hs
     WHERE hs.score_card_id=v_card.id;
  ELSE
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'holeScoreId',hs.id,
      'roundHoleSnapshotId',hs.round_hole_snapshot_id,
      'holeNumber',hs.hole_number,
      'playSequence',hs.play_sequence,
      'status',hs.status,'resultType',hs.result_type,'grossScore',hs.gross_score,
      'claimedResultType',hs.player_claimed_result_type,
      'claimedGrossScore',hs.player_claimed_gross_score,
      'disputeNote',hs.dispute_note
    ) ORDER BY hs.play_sequence),'[]'::jsonb)
      INTO v_scores
      FROM public.tournament_scorecard_hole_scores hs
     WHERE hs.score_card_id=v_card.id;
  END IF;

  RETURN jsonb_build_object(
    'captureState',CASE WHEN v_session.status IN ('ready','in_progress','captured') THEN 'open' ELSE 'closed' END,
    'controlState',v_control_state,
    'scoreCardId',v_card.id,
    'tournamentId',v_card.tournament_id,
    'tournamentRoundId',v_card.tournament_round_id,
    'engine',v_card.scoring_engine,
    'participationType',v_card.participation_type,
    'unitType',v_card.unit_type,
    'captureSessionStatus',v_session.status,
    'scores',v_scores
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 7. INICIAR / HEARTBEAT / DEJAR DE MARCAR
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.iniciar_captura_qr_423(p_qr_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_card record; v_session record; v_plain text; v_control uuid;
BEGIN
  IF p_qr_token IS NULL OR p_qr_token !~ '^[0-9a-fA-F]{64}$' THEN
    RAISE EXCEPTION 'QR inválido.' USING ERRCODE='22023';
  END IF;

  SELECT sc.id,sc.tournament_id,sc.tournament_round_id,t.usar_tarjeta_digital,e.status emission_status
    INTO v_card
    FROM public.tournament_score_cards sc
    JOIN public.tournament_score_card_emissions e ON e.id=sc.emission_id
    JOIN public.tournaments t ON t.id=sc.tournament_id
   WHERE lower(sc.qr_token)=lower(p_qr_token) AND sc.status='issued'
   LIMIT 1;

  IF v_card.id IS NULL OR v_card.emission_status<>'issued' THEN RAISE EXCEPTION 'QR no válido.' USING ERRCODE='22023'; END IF;
  IF NOT COALESCE(v_card.usar_tarjeta_digital,false) THEN RAISE EXCEPTION 'Este torneo no utiliza captura digital.' USING ERRCODE='55000'; END IF;

  SELECT * INTO v_session FROM public.tournament_scorecard_capture_sessions WHERE score_card_id=v_card.id;
  IF v_session.id IS NULL THEN RAISE EXCEPTION 'La captura digital de esta tarjeta no ha sido inicializada.' USING ERRCODE='55000'; END IF;
  PERFORM public._exigir_torneo_en_curso_scorecard_256(v_card.id,'inicio de captura QR');
  IF public._captura_ronda_cerrada_390(v_card.tournament_round_id) THEN
    RAISE EXCEPTION 'La captura digital de la ronda está cerrada.' USING ERRCODE='55000';
  END IF;

  PERFORM public._qr_lock_card_423(v_card.id);
  UPDATE public.tournament_scorecard_qr_capture_controls
     SET released_at=now(),release_reason='expired'
   WHERE score_card_id=v_card.id AND released_at IS NULL AND expires_at<=now();

  IF EXISTS (SELECT 1 FROM public.tournament_scorecard_qr_capture_controls WHERE score_card_id=v_card.id AND released_at IS NULL AND expires_at>now()) THEN
    RETURN jsonb_build_object('status','busy');
  END IF;

  v_plain:=encode(extensions.gen_random_bytes(32),'hex');
  INSERT INTO public.tournament_scorecard_qr_capture_controls(
    score_card_id,capture_session_id,control_token_hash,expires_at
  ) VALUES(v_card.id,v_session.id,public._qr_hash_control_token_423(v_plain),now()+interval '5 minutes')
  RETURNING id INTO v_control;

  RETURN jsonb_build_object('status','acquired','controlToken',v_plain,'controlId',v_control,'expiresAt',now()+interval '5 minutes');
END;
$$;

CREATE OR REPLACE FUNCTION public.renovar_control_captura_qr_423(p_qr_token text,p_control_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_card uuid; v_control uuid; v_exp timestamptz;
BEGIN
  SELECT id INTO v_card FROM public.tournament_score_cards WHERE lower(qr_token)=lower(p_qr_token) AND status='issued' LIMIT 1;
  IF v_card IS NULL THEN RAISE EXCEPTION 'QR inválido.' USING ERRCODE='22023'; END IF;
  v_control:=public._qr_validar_control_423(v_card,p_control_token);
  v_exp:=now()+interval '5 minutes';
  UPDATE public.tournament_scorecard_qr_capture_controls
     SET last_heartbeat_at=now(),expires_at=v_exp
   WHERE id=v_control;
  RETURN jsonb_build_object('status','renewed','expiresAt',v_exp);
END;
$$;

CREATE OR REPLACE FUNCTION public.dejar_de_marcar_qr_423(p_qr_token text,p_control_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_card uuid; v_control uuid;
BEGIN
  SELECT id INTO v_card FROM public.tournament_score_cards WHERE lower(qr_token)=lower(p_qr_token) AND status='issued' LIMIT 1;
  IF v_card IS NULL THEN RAISE EXCEPTION 'QR inválido.' USING ERRCODE='22023'; END IF;
  PERFORM public._qr_lock_card_423(v_card);

  SELECT id INTO v_control
    FROM public.tournament_scorecard_qr_capture_controls
   WHERE score_card_id=v_card AND released_at IS NULL
     AND control_token_hash=public._qr_hash_control_token_423(p_control_token)
   FOR UPDATE;

  IF v_control IS NULL THEN RETURN jsonb_build_object('status','already_released'); END IF;
  UPDATE public.tournament_scorecard_qr_capture_controls
     SET released_at=now(),release_reason='voluntary'
   WHERE id=v_control;
  RETURN jsonb_build_object('status','released');
END;
$$;

-- -----------------------------------------------------------------------------
-- 8. Captura/corrección QR universal por motor
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_resultado_hoyo_qr_423(
  p_qr_token text,
  p_control_token text,
  p_round_hole_snapshot_id uuid,
  p_result_type text,
  p_gross_score integer DEFAULT NULL,
  p_best_ball_scorecard_member_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_card record; v_control uuid; v_hole record; v_event text; v_pending int;
  v_result text:=upper(btrim(COALESCE(p_result_type,'')));
BEGIN
  SELECT sc.id,sc.tournament_id,sc.tournament_round_id,sc.validation_id,t.usar_tarjeta_digital,
         e.status emission_status,v.scoring_engine,v.participation_type
    INTO v_card
    FROM public.tournament_score_cards sc
    JOIN public.tournament_score_card_emissions e ON e.id=sc.emission_id
    JOIN public.tournaments t ON t.id=sc.tournament_id
    JOIN public.tournament_round_start_validations v ON v.id=sc.validation_id
   WHERE lower(sc.qr_token)=lower(p_qr_token) AND sc.status='issued' LIMIT 1;

  IF v_card.id IS NULL OR v_card.emission_status<>'issued' THEN RAISE EXCEPTION 'QR inválido.' USING ERRCODE='22023'; END IF;
  IF NOT COALESCE(v_card.usar_tarjeta_digital,false) THEN RAISE EXCEPTION 'Captura digital deshabilitada.' USING ERRCODE='55000'; END IF;
  v_control:=public._qr_validar_control_423(v_card.id,p_control_token);

  IF v_card.scoring_engine='best_ball' THEN
    IF p_best_ball_scorecard_member_id IS NULL THEN RAISE EXCEPTION 'Best Ball requiere integrante.' USING ERRCODE='22023'; END IF;
    IF v_result NOT IN ('SCORE','PICKUP') THEN RAISE EXCEPTION 'Resultado Best Ball inválido.' USING ERRCODE='22023'; END IF;

    SELECT * INTO v_hole FROM public.tournament_best_ball_hole_scores
     WHERE score_card_id=v_card.id
       AND best_ball_scorecard_member_id=p_best_ball_scorecard_member_id
       AND round_hole_snapshot_id=p_round_hole_snapshot_id FOR UPDATE;
    IF v_hole.id IS NULL THEN RAISE EXCEPTION 'El hoyo/integrante no pertenece a esta tarjeta.' USING ERRCODE='22023'; END IF;
    IF v_hole.status IN ('confirmed','disputed') THEN RAISE EXCEPTION 'El hoyo ya no admite edición QR; requiere Comité.' USING ERRCODE='55000'; END IF;
    IF v_result='SCORE' AND (p_gross_score IS NULL OR p_gross_score<=0) THEN RAISE EXCEPTION 'SCORE requiere gross mayor que cero.' USING ERRCODE='22023'; END IF;
    IF v_result='PICKUP' THEN p_gross_score:=NULL; END IF;
    v_event:=CASE WHEN v_hole.status='pending' THEN 'score_entered' ELSE 'score_corrected' END;

    UPDATE public.tournament_best_ball_hole_scores SET
      result_type=v_result,gross_score=p_gross_score,status='entered',
      marker_assignment_id=NULL,entered_by_player_id=NULL,entered_at=COALESCE(entered_at,now()),
      confirmed_by_player_id=NULL,confirmed_at=NULL,
      player_claimed_result_type=NULL,player_claimed_gross_score=NULL,dispute_note=NULL,disputed_at=NULL,
      entry_source='qr_public',qr_capture_control_id=v_control,updated_at=now()
    WHERE id=v_hole.id;

    INSERT INTO public.tournament_best_ball_scorecard_events(
      score_card_id,best_ball_hole_score_id,marker_assignment_id,event_type,actor_player_id,
      old_result_type,new_result_type,old_gross_score,new_gross_score,
      actor_source,qr_capture_control_id
    ) VALUES(
      v_card.id,v_hole.id,NULL,v_event,NULL,
      v_hole.result_type,v_result,v_hole.gross_score,p_gross_score,
      'qr_public',v_control
    );

    SELECT count(*) INTO v_pending FROM public.tournament_best_ball_hole_scores WHERE score_card_id=v_card.id AND status='pending';
  ELSE
    IF v_card.scoring_engine='team_stroke' AND v_result<>'SCORE' THEN RAISE EXCEPTION 'A-Go-Go solo admite SCORE.' USING ERRCODE='22023'; END IF;
    IF v_card.scoring_engine='stroke' AND v_result<>'SCORE' THEN RAISE EXCEPTION 'Stroke Play solo admite SCORE.' USING ERRCODE='22023'; END IF;
    IF v_card.scoring_engine='stableford' AND v_result NOT IN ('SCORE','PICKUP') THEN RAISE EXCEPTION 'Stableford admite SCORE o PICKUP.' USING ERRCODE='22023'; END IF;
    IF v_card.scoring_engine NOT IN ('stroke','stableford','team_stroke') THEN RAISE EXCEPTION 'Motor no habilitado para captura QR 423.' USING ERRCODE='22023'; END IF;

    SELECT * INTO v_hole FROM public.tournament_scorecard_hole_scores
     WHERE score_card_id=v_card.id AND round_hole_snapshot_id=p_round_hole_snapshot_id FOR UPDATE;
    IF v_hole.id IS NULL THEN RAISE EXCEPTION 'El hoyo no pertenece a esta tarjeta.' USING ERRCODE='22023'; END IF;
    IF v_hole.status IN ('confirmed','disputed') THEN RAISE EXCEPTION 'El hoyo ya no admite edición QR; requiere Comité.' USING ERRCODE='55000'; END IF;
    IF v_result='SCORE' AND (p_gross_score IS NULL OR p_gross_score<=0) THEN RAISE EXCEPTION 'SCORE requiere gross mayor que cero.' USING ERRCODE='22023'; END IF;
    IF v_result='PICKUP' THEN p_gross_score:=NULL; END IF;
    v_event:=CASE WHEN v_hole.status='pending' THEN 'score_entered' ELSE 'score_corrected' END;

    UPDATE public.tournament_scorecard_hole_scores SET
      result_type=v_result,gross_score=p_gross_score,status='entered',
      marker_assignment_id=NULL,entered_by_player_id=NULL,entered_at=COALESCE(entered_at,now()),
      confirmed_by_player_id=NULL,confirmed_at=NULL,
      player_claimed_result_type=NULL,player_claimed_gross_score=NULL,dispute_note=NULL,disputed_at=NULL,
      entry_source='qr_public',qr_capture_control_id=v_control,updated_at=now()
    WHERE id=v_hole.id;

    INSERT INTO public.tournament_scorecard_events(
      score_card_id,hole_score_id,marker_assignment_id,event_type,actor_player_id,actor_admin_user_id,
      old_gross_score,new_gross_score,old_result_type,new_result_type,
      actor_source,qr_capture_control_id
    ) VALUES(
      v_card.id,v_hole.id,NULL,v_event,NULL,NULL,
      v_hole.gross_score,p_gross_score,v_hole.result_type,v_result,
      'qr_public',v_control
    );

    SELECT count(*) INTO v_pending FROM public.tournament_scorecard_hole_scores WHERE score_card_id=v_card.id AND status='pending';
  END IF;

  UPDATE public.tournament_scorecard_capture_sessions
     SET status=CASE WHEN v_pending=0 THEN 'captured' ELSE 'in_progress' END,
         started_at=COALESCE(started_at,now()),
         captured_at=CASE WHEN v_pending=0 THEN COALESCE(captured_at,now()) ELSE NULL END,
         updated_at=now()
   WHERE score_card_id=v_card.id;

  UPDATE public.tournament_scorecard_qr_capture_controls
     SET last_activity_at=now(),last_heartbeat_at=now(),expires_at=now()+interval '5 minutes'
   WHERE id=v_control;

  RETURN jsonb_build_object('status','saved','eventType',v_event,'remainingPending',v_pending);
END;
$$;

-- -----------------------------------------------------------------------------
-- 9. Inconformidad QR universal. Una vez disputado, QR ya no puede reescribir.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_inconformidad_qr_423(
  p_qr_token text,
  p_control_token text,
  p_round_hole_snapshot_id uuid,
  p_claimed_result_type text,
  p_claimed_gross_score integer DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_best_ball_scorecard_member_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_card record; v_control uuid; v_hole record; v_claim text:=upper(btrim(COALESCE(p_claimed_result_type,'')));
BEGIN
  IF length(COALESCE(p_note,''))>280 THEN RAISE EXCEPTION 'La observación no puede exceder 280 caracteres.' USING ERRCODE='22023'; END IF;

  SELECT sc.id,sc.validation_id,t.usar_tarjeta_digital,e.status emission_status,v.scoring_engine
    INTO v_card
    FROM public.tournament_score_cards sc
    JOIN public.tournament_score_card_emissions e ON e.id=sc.emission_id
    JOIN public.tournaments t ON t.id=sc.tournament_id
    JOIN public.tournament_round_start_validations v ON v.id=sc.validation_id
   WHERE lower(sc.qr_token)=lower(p_qr_token) AND sc.status='issued' LIMIT 1;

  IF v_card.id IS NULL OR v_card.emission_status<>'issued' THEN RAISE EXCEPTION 'QR inválido.' USING ERRCODE='22023'; END IF;
  IF NOT COALESCE(v_card.usar_tarjeta_digital,false) THEN RAISE EXCEPTION 'Captura digital deshabilitada.' USING ERRCODE='55000'; END IF;
  v_control:=public._qr_validar_control_423(v_card.id,p_control_token);

  IF v_claim NOT IN ('SCORE','PICKUP') THEN RAISE EXCEPTION 'Resultado reclamado inválido.' USING ERRCODE='22023'; END IF;
  IF v_claim='SCORE' AND (p_claimed_gross_score IS NULL OR p_claimed_gross_score<=0) THEN RAISE EXCEPTION 'SCORE reclamado requiere gross mayor que cero.' USING ERRCODE='22023'; END IF;
  IF v_claim='PICKUP' THEN p_claimed_gross_score:=NULL; END IF;

  IF v_card.scoring_engine='best_ball' THEN
    IF p_best_ball_scorecard_member_id IS NULL THEN RAISE EXCEPTION 'Best Ball requiere integrante.' USING ERRCODE='22023'; END IF;
    SELECT * INTO v_hole FROM public.tournament_best_ball_hole_scores
     WHERE score_card_id=v_card.id AND best_ball_scorecard_member_id=p_best_ball_scorecard_member_id
       AND round_hole_snapshot_id=p_round_hole_snapshot_id FOR UPDATE;
    IF v_hole.id IS NULL OR v_hole.status<>'entered' THEN RAISE EXCEPTION 'Solo puede registrarse inconformidad sobre un resultado capturado y no cerrado.' USING ERRCODE='55000'; END IF;
    IF v_claim IS NOT DISTINCT FROM v_hole.result_type AND p_claimed_gross_score IS NOT DISTINCT FROM v_hole.gross_score THEN
      RAISE EXCEPTION 'La inconformidad debe proponer un resultado diferente.' USING ERRCODE='22023';
    END IF;

    UPDATE public.tournament_best_ball_hole_scores SET
      status='disputed',player_claimed_result_type=v_claim,player_claimed_gross_score=p_claimed_gross_score,
      dispute_note=NULLIF(btrim(COALESCE(p_note,'')),''),disputed_at=now(),
      entry_source='qr_public',qr_capture_control_id=v_control,updated_at=now()
    WHERE id=v_hole.id;

    INSERT INTO public.tournament_best_ball_scorecard_events(
      score_card_id,best_ball_hole_score_id,marker_assignment_id,event_type,actor_player_id,
      old_result_type,new_result_type,old_gross_score,new_gross_score,
      claimed_result_type,claimed_gross_score,reason,actor_source,qr_capture_control_id
    ) VALUES(
      v_card.id,v_hole.id,NULL,'qr_disputed',NULL,
      v_hole.result_type,v_hole.result_type,v_hole.gross_score,v_hole.gross_score,
      v_claim,p_claimed_gross_score,NULLIF(btrim(COALESCE(p_note,'')),''),'qr_public',v_control
    );
  ELSE
    SELECT * INTO v_hole FROM public.tournament_scorecard_hole_scores
     WHERE score_card_id=v_card.id AND round_hole_snapshot_id=p_round_hole_snapshot_id FOR UPDATE;
    IF v_hole.id IS NULL OR v_hole.status<>'entered' THEN RAISE EXCEPTION 'Solo puede registrarse inconformidad sobre un resultado capturado y no cerrado.' USING ERRCODE='55000'; END IF;
    IF v_claim IS NOT DISTINCT FROM v_hole.result_type AND p_claimed_gross_score IS NOT DISTINCT FROM v_hole.gross_score THEN
      RAISE EXCEPTION 'La inconformidad debe proponer un resultado diferente.' USING ERRCODE='22023';
    END IF;

    UPDATE public.tournament_scorecard_hole_scores SET
      status='disputed',player_claimed_result_type=v_claim,player_claimed_gross_score=p_claimed_gross_score,
      dispute_note=NULLIF(btrim(COALESCE(p_note,'')),''),disputed_at=now(),
      entry_source='qr_public',qr_capture_control_id=v_control,updated_at=now()
    WHERE id=v_hole.id;

    INSERT INTO public.tournament_scorecard_events(
      score_card_id,hole_score_id,marker_assignment_id,event_type,actor_player_id,actor_admin_user_id,
      old_gross_score,new_gross_score,claimed_gross_score,reason,
      old_result_type,new_result_type,claimed_result_type,actor_source,qr_capture_control_id
    ) VALUES(
      v_card.id,v_hole.id,NULL,'qr_disputed',NULL,NULL,
      v_hole.gross_score,v_hole.gross_score,p_claimed_gross_score,NULLIF(btrim(COALESCE(p_note,'')),''),
      v_hole.result_type,v_hole.result_type,v_claim,'qr_public',v_control
    );
  END IF;

  UPDATE public.tournament_scorecard_qr_capture_controls
     SET last_activity_at=now(),last_heartbeat_at=now(),expires_at=now()+interval '5 minutes'
   WHERE id=v_control;

  RETURN jsonb_build_object('status','disputed');
END;
$$;

-- -----------------------------------------------------------------------------
-- 10. Liberación administrativa del control
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.liberar_control_captura_qr_admin_423(p_score_card_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_tournament uuid; v_admin uuid; v_count int;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501'; END IF;
  SELECT tournament_id INTO v_tournament FROM public.tournament_score_cards WHERE id=p_score_card_id;
  IF v_tournament IS NULL THEN RAISE EXCEPTION 'Tarjeta inexistente.' USING ERRCODE='22023'; END IF;
  IF NOT public.puede_administrar_congelamiento_torneo(v_tournament) THEN RAISE EXCEPTION 'Sin permiso administrativo.' USING ERRCODE='42501'; END IF;
  v_admin:=public._scorecard_current_admin_id();
  PERFORM public._qr_lock_card_423(p_score_card_id);
  UPDATE public.tournament_scorecard_qr_capture_controls
     SET released_at=now(),release_reason='committee',released_by_admin_user_id=v_admin
   WHERE score_card_id=p_score_card_id AND released_at IS NULL;
  GET DIAGNOSTICS v_count=ROW_COUNT;
  RETURN jsonb_build_object('released',v_count>0);
END;
$$;

-- -----------------------------------------------------------------------------
-- 11. Protección de doble escritor mientras existe lease QR vigente.
--     Se implementa en tabla para cubrir RPC legacy sin reescribirlas.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._bloquear_escritura_legacy_con_control_qr_423()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
BEGIN
  IF TG_OP='UPDATE'
     AND NEW.status IN ('entered','confirmed','disputed')
     AND NEW.entry_source IS NULL
     AND OLD.entry_source IS NULL
     AND EXISTS (
       SELECT 1 FROM public.tournament_scorecard_qr_capture_controls c
       WHERE c.score_card_id=NEW.score_card_id AND c.released_at IS NULL AND c.expires_at>now()
     )
  THEN
    -- Confirmación/disputa del jugador no compiten con captura si no cambian el resultado base.
    IF NEW.result_type IS DISTINCT FROM OLD.result_type OR NEW.gross_score IS DISTINCT FROM OLD.gross_score
       OR OLD.status='pending' THEN
      RAISE EXCEPTION 'La tarjeta está siendo capturada por QR desde otro dispositivo.' USING ERRCODE='55000';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_bloquear_escritura_legacy_con_control_qr_423 ON public.tournament_scorecard_hole_scores;
CREATE TRIGGER trg_bloquear_escritura_legacy_con_control_qr_423
BEFORE UPDATE ON public.tournament_scorecard_hole_scores
FOR EACH ROW EXECUTE FUNCTION public._bloquear_escritura_legacy_con_control_qr_423();

DROP TRIGGER IF EXISTS trg_bloquear_escritura_legacy_best_ball_con_control_qr_423 ON public.tournament_best_ball_hole_scores;
CREATE TRIGGER trg_bloquear_escritura_legacy_best_ball_con_control_qr_423
BEFORE UPDATE ON public.tournament_best_ball_hole_scores
FOR EACH ROW EXECUTE FUNCTION public._bloquear_escritura_legacy_con_control_qr_423();

-- -----------------------------------------------------------------------------
-- 12. Conciliación: reconocer qr_disputed como historial de inconformidad.
--     Reescritura textual controlada de las funciones existentes para no cambiar
--     sus firmas ni su lógica restante. Aborta si no encuentra el patrón esperado.
-- -----------------------------------------------------------------------------
DO $patch$
DECLARE r record; v_def text; v_new text;
BEGIN
  FOR r IN
    SELECT p.oid,p.proname
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND p.proname IN (
        'obtener_conciliacion_tarjeta_score',
        'finalizar_conciliacion_tarjeta_score',
        'resolver_hoyo_conciliacion_resultado',
        'obtener_score_oficial_tarjeta',
        'obtener_resultados_oficiales_ronda',
        'obtener_best_ball_digital_tarjeta_321',
        'obtener_conciliacion_best_ball_324',
        'resolver_conciliacion_best_ball_324',
        'finalizar_conciliacion_best_ball_324',
        'obtener_resultado_oficial_best_ball_325'
      )
  LOOP
    v_def:=pg_get_functiondef(r.oid);
    v_new:=replace(v_def, $$event_type='player_disputed'$$, $$event_type IN ('player_disputed','qr_disputed')$$);
    v_new:=replace(v_new, $$event_type = 'player_disputed'$$, $$event_type IN ('player_disputed','qr_disputed')$$);
    IF v_new IS DISTINCT FROM v_def THEN
      EXECUTE v_new;
    END IF;
  END LOOP;
END $patch$;

-- -----------------------------------------------------------------------------
-- 13. Permisos: público solo por RPC token-scoped. Helpers/tablas siguen cerrados.
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.obtener_tarjeta_publica_qr_423(text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.iniciar_captura_qr_423(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.renovar_control_captura_qr_423(text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dejar_de_marcar_qr_423(text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.registrar_resultado_hoyo_qr_423(text,text,uuid,text,integer,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.registrar_inconformidad_qr_423(text,text,uuid,text,integer,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.liberar_control_captura_qr_admin_423(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.obtener_tarjeta_publica_qr_423(text,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.iniciar_captura_qr_423(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.renovar_control_captura_qr_423(text,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dejar_de_marcar_qr_423(text,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_resultado_hoyo_qr_423(text,text,uuid,text,integer,uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_inconformidad_qr_423(text,text,uuid,text,integer,text,uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.liberar_control_captura_qr_admin_423(uuid) TO authenticated;

-- No se concede acceso directo a tablas.
REVOKE ALL ON TABLE public.tournament_scorecard_qr_capture_controls FROM anon, authenticated;

COMMIT;
