-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 425
-- Cierre explícito de captura digital por QR por tarjeta
-- ============================================================================
-- OBJETIVO
-- 1) Separar "DEJAR DE MARCAR" (liberar el dispositivo) de "CERRAR CAPTURA"
--    (declarar terminada la responsabilidad de captura digital de la tarjeta).
-- 2) Permitir cerrar únicamente cuando la tarjeta está completa.
-- 3) Una tarjeta cerrada queda pública en modo lectura para cualquier dispositivo.
-- 4) Impedir adquirir/renovar control o escribir por QR mientras esté cerrada.
-- 5) Permitir reapertura únicamente a un administrador autorizado.
-- 6) Mantener trazabilidad de cierres y reaperturas.
--
-- IMPORTANTE
-- - NO sustituye recepción/captura de tarjeta física ni conciliación.
-- - NO cambia la semántica existente de capture_sessions.status='captured': ese
--   estado sigue significando que ya no hay resultados pendientes.
-- - El cierre explícito se guarda aparte en digital_closed_at.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1. Estado persistente del cierre digital sobre la sesión existente
-- --------------------------------------------------------------------------
ALTER TABLE public.tournament_scorecard_capture_sessions
  ADD COLUMN IF NOT EXISTS digital_closed_at timestamptz,
  ADD COLUMN IF NOT EXISTS digital_closed_by_control_id uuid,
  ADD COLUMN IF NOT EXISTS digital_reopened_at timestamptz,
  ADD COLUMN IF NOT EXISTS digital_reopened_by_admin_user_id uuid;

-- digital_closed_by_control_id se conserva como UUID de auditoría. No se agrega FK
-- para evitar crear un ciclo de borrado entre capture_sessions y qr_capture_controls.

-- --------------------------------------------------------------------------
-- 2. Bitácora inmutable de cierre/reapertura
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tournament_scorecard_qr_capture_closure_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  score_card_id uuid NOT NULL
    REFERENCES public.tournament_score_cards(id) ON DELETE RESTRICT,
  capture_session_id uuid NOT NULL
    REFERENCES public.tournament_scorecard_capture_sessions(id) ON DELETE RESTRICT,
  event_type text NOT NULL
    CHECK (event_type IN ('capture_closed','capture_reopened')),
  qr_capture_control_id uuid
    REFERENCES public.tournament_scorecard_qr_capture_controls(id) ON DELETE SET NULL,
  actor_admin_user_id uuid,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tournament_scorecard_qr_capture_closure_events_actor_ck CHECK (
    (event_type='capture_closed' AND qr_capture_control_id IS NOT NULL AND actor_admin_user_id IS NULL)
    OR
    (event_type='capture_reopened' AND qr_capture_control_id IS NULL AND actor_admin_user_id IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_scorecard_qr_capture_closure_events_card_created
  ON public.tournament_scorecard_qr_capture_closure_events(score_card_id,created_at DESC);

ALTER TABLE public.tournament_scorecard_qr_capture_closure_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.tournament_scorecard_qr_capture_closure_events FROM PUBLIC, anon, authenticated;

-- 423 solo admitía voluntary/expired/committee. 425 agrega capture_closed para
-- distinguir la liberación causada por el cierre formal de la captura.
ALTER TABLE public.tournament_scorecard_qr_capture_controls
  DROP CONSTRAINT IF EXISTS tournament_scorecard_qr_controls_release_ck;
ALTER TABLE public.tournament_scorecard_qr_capture_controls
  DROP CONSTRAINT IF EXISTS tournament_scorecard_qr_controls_release_reason_ck;
ALTER TABLE public.tournament_scorecard_qr_capture_controls
  ADD CONSTRAINT tournament_scorecard_qr_controls_release_reason_ck
  CHECK (release_reason IS NULL OR release_reason IN ('voluntary','expired','committee','capture_closed'));
ALTER TABLE public.tournament_scorecard_qr_capture_controls
  ADD CONSTRAINT tournament_scorecard_qr_controls_release_ck
  CHECK (
    (released_at IS NULL AND release_reason IS NULL AND released_by_admin_user_id IS NULL)
    OR
    (released_at IS NOT NULL AND release_reason IS NOT NULL AND (
      (release_reason='committee' AND released_by_admin_user_id IS NOT NULL)
      OR
      (release_reason IN ('voluntary','expired','capture_closed') AND released_by_admin_user_id IS NULL)
    ))
  );

-- La bitácora no se edita ni se borra.
CREATE OR REPLACE FUNCTION public._impedir_mutacion_qr_capture_closure_event_425()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
BEGIN
  RAISE EXCEPTION 'La bitácora de cierre de captura QR es inmutable.' USING ERRCODE='55000';
END;
$$;

DROP TRIGGER IF EXISTS trg_impedir_mutacion_qr_capture_closure_event_425
  ON public.tournament_scorecard_qr_capture_closure_events;
CREATE TRIGGER trg_impedir_mutacion_qr_capture_closure_event_425
BEFORE UPDATE OR DELETE ON public.tournament_scorecard_qr_capture_closure_events
FOR EACH ROW EXECUTE FUNCTION public._impedir_mutacion_qr_capture_closure_event_425();

REVOKE ALL ON FUNCTION public._impedir_mutacion_qr_capture_closure_event_425() FROM PUBLIC, anon, authenticated;

-- --------------------------------------------------------------------------
-- 3. Iniciar control QR: bloquear si la tarjeta ya fue cerrada explícitamente
-- --------------------------------------------------------------------------
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
  IF v_session.digital_closed_at IS NOT NULL THEN
    RAISE EXCEPTION 'La captura digital de esta tarjeta está cerrada. Solo un operador autorizado puede reabrirla.' USING ERRCODE='55000';
  END IF;

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

-- --------------------------------------------------------------------------
-- 4. Cerrar captura digital desde el dispositivo que tiene el control
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerrar_captura_digital_qr_425(
  p_qr_token text,
  p_control_token text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_card record;
  v_session public.tournament_scorecard_capture_sessions;
  v_control uuid;
  v_pending integer := 0;
  v_expected integer := 0;
  v_completed integer := 0;
BEGIN
  IF p_qr_token IS NULL OR p_qr_token !~ '^[0-9a-fA-F]{64}$' THEN
    RAISE EXCEPTION 'QR inválido.' USING ERRCODE='22023';
  END IF;

  SELECT sc.id,sc.tournament_id,sc.tournament_round_id,t.usar_tarjeta_digital,
         e.status AS emission_status,v.scoring_engine
    INTO v_card
    FROM public.tournament_score_cards sc
    JOIN public.tournament_score_card_emissions e ON e.id=sc.emission_id
    JOIN public.tournaments t ON t.id=sc.tournament_id
    JOIN public.tournament_round_start_validations v ON v.id=sc.validation_id
   WHERE lower(sc.qr_token)=lower(p_qr_token)
     AND sc.status='issued'
   LIMIT 1;

  IF v_card.id IS NULL OR v_card.emission_status<>'issued' THEN
    RAISE EXCEPTION 'QR inválido.' USING ERRCODE='22023';
  END IF;
  IF NOT COALESCE(v_card.usar_tarjeta_digital,false) THEN
    RAISE EXCEPTION 'Captura digital deshabilitada.' USING ERRCODE='55000';
  END IF;

  -- Valida el token y toma el mismo lock por tarjeta utilizado por 423.
  v_control := public._qr_validar_control_423(v_card.id,p_control_token);

  SELECT * INTO v_session
  FROM public.tournament_scorecard_capture_sessions
  WHERE score_card_id=v_card.id
  FOR UPDATE;

  IF v_session.id IS NULL THEN
    RAISE EXCEPTION 'La captura digital de esta tarjeta no ha sido inicializada.' USING ERRCODE='55000';
  END IF;
  IF v_session.digital_closed_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status','already_closed',
      'scoreCardId',v_card.id,
      'closedAt',v_session.digital_closed_at
    );
  END IF;

  IF v_card.scoring_engine='best_ball' THEN
    SELECT count(*),count(*) FILTER (WHERE status<>'pending'),count(*) FILTER (WHERE status='pending')
      INTO v_expected,v_completed,v_pending
      FROM public.tournament_best_ball_hole_scores
     WHERE score_card_id=v_card.id;
  ELSE
    SELECT count(*),count(*) FILTER (WHERE status<>'pending'),count(*) FILTER (WHERE status='pending')
      INTO v_expected,v_completed,v_pending
      FROM public.tournament_scorecard_hole_scores
     WHERE score_card_id=v_card.id;
  END IF;

  IF v_expected<=0 OR v_pending>0 OR v_completed<>v_expected OR v_session.status<>'captured' THEN
    RAISE EXCEPTION 'No se puede cerrar la captura digital: faltan resultados por capturar.'
      USING ERRCODE='55000',
            DETAIL=format('completed=%s; expected=%s; pending=%s; session_status=%s',v_completed,v_expected,v_pending,v_session.status);
  END IF;

  UPDATE public.tournament_scorecard_capture_sessions
     SET digital_closed_at=now(),
         digital_closed_by_control_id=v_control,
         digital_reopened_at=NULL,
         digital_reopened_by_admin_user_id=NULL,
         updated_at=now()
   WHERE id=v_session.id
   RETURNING * INTO v_session;

  INSERT INTO public.tournament_scorecard_qr_capture_closure_events(
    score_card_id,capture_session_id,event_type,qr_capture_control_id
  ) VALUES(
    v_card.id,v_session.id,'capture_closed',v_control
  );

  -- Cerrar captura también termina la posesión del dispositivo.
  UPDATE public.tournament_scorecard_qr_capture_controls
     SET released_at=now(),release_reason='capture_closed',last_activity_at=now()
   WHERE id=v_control AND released_at IS NULL;

  RETURN jsonb_build_object(
    'status','closed',
    'scoreCardId',v_card.id,
    'completed',v_completed,
    'expected',v_expected,
    'closedAt',v_session.digital_closed_at
  );
END;
$$;

-- --------------------------------------------------------------------------
-- 5. Reapertura exclusivamente administrativa
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reabrir_captura_digital_qr_admin_425(
  p_score_card_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_card record;
  v_session public.tournament_scorecard_capture_sessions;
  v_admin uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
  END IF;

  SELECT id,tournament_id,tournament_round_id
    INTO v_card
    FROM public.tournament_score_cards
   WHERE id=p_score_card_id AND status='issued'
   LIMIT 1;

  IF v_card.id IS NULL THEN
    RAISE EXCEPTION 'Tarjeta inexistente o no emitida.' USING ERRCODE='22023';
  END IF;
  IF NOT public.puede_administrar_congelamiento_torneo(v_card.tournament_id) THEN
    RAISE EXCEPTION 'Sin permiso administrativo para reabrir la captura digital.' USING ERRCODE='42501';
  END IF;
  IF public._captura_ronda_cerrada_390(v_card.tournament_round_id) THEN
    RAISE EXCEPTION 'La captura de la ronda está cerrada y la tarjeta no puede reabrirse.' USING ERRCODE='55000';
  END IF;

  v_admin:=public._scorecard_current_admin_id();
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'El usuario autenticado no tiene un administrador activo asociado.' USING ERRCODE='42501';
  END IF;

  PERFORM public._qr_lock_card_423(v_card.id);

  SELECT * INTO v_session
    FROM public.tournament_scorecard_capture_sessions
   WHERE score_card_id=v_card.id
   FOR UPDATE;

  IF v_session.id IS NULL THEN
    RAISE EXCEPTION 'La captura digital de esta tarjeta no ha sido inicializada.' USING ERRCODE='55000';
  END IF;
  IF v_session.digital_closed_at IS NULL THEN
    RETURN jsonb_build_object('status','already_open','scoreCardId',v_card.id);
  END IF;

  -- Por seguridad no debe sobrevivir ningún lease al cambio de estado.
  UPDATE public.tournament_scorecard_qr_capture_controls
     SET released_at=now(),release_reason='committee',released_by_admin_user_id=v_admin
   WHERE score_card_id=v_card.id AND released_at IS NULL;

  UPDATE public.tournament_scorecard_capture_sessions
     SET digital_closed_at=NULL,
         digital_closed_by_control_id=NULL,
         digital_reopened_at=now(),
         digital_reopened_by_admin_user_id=v_admin,
         updated_at=now()
   WHERE id=v_session.id
   RETURNING * INTO v_session;

  INSERT INTO public.tournament_scorecard_qr_capture_closure_events(
    score_card_id,capture_session_id,event_type,actor_admin_user_id,reason
  ) VALUES(
    v_card.id,v_session.id,'capture_reopened',v_admin,NULLIF(btrim(COALESCE(p_reason,'')),'')
  );

  RETURN jsonb_build_object(
    'status','reopened',
    'scoreCardId',v_card.id,
    'reopenedAt',v_session.digital_reopened_at
  );
END;
$$;

-- --------------------------------------------------------------------------
-- 6. Lectura pública 425: conserva íntegro el contrato 424 y agrega cierre
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_tarjeta_publica_qr_425(
  p_qr_token text,
  p_control_token text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_payload jsonb;
  v_card_id uuid;
  v_session record;
BEGIN
  v_payload := public.obtener_tarjeta_publica_qr_424(p_qr_token,p_control_token);

  IF COALESCE(v_payload->>'captureState','') IN ('invalid','digital_disabled','not_initialized') THEN
    RETURN v_payload;
  END IF;

  SELECT sc.id INTO v_card_id
    FROM public.tournament_score_cards sc
   WHERE lower(sc.qr_token)=lower(p_qr_token)
     AND sc.status='issued'
   LIMIT 1;

  IF v_card_id IS NULL THEN
    RETURN jsonb_build_object('captureState','invalid');
  END IF;

  SELECT cs.digital_closed_at,cs.digital_reopened_at,cs.status
    INTO v_session
    FROM public.tournament_scorecard_capture_sessions cs
   WHERE cs.score_card_id=v_card_id;

  v_payload := v_payload || jsonb_build_object(
    'digitalCapture',jsonb_strip_nulls(jsonb_build_object(
      'closed',v_session.digital_closed_at IS NOT NULL,
      'closedAt',v_session.digital_closed_at,
      'lastReopenedAt',v_session.digital_reopened_at
    ))
  );

  IF v_session.digital_closed_at IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object(
      'captureState','closed',
      'controlState','free'
    );
  END IF;

  RETURN v_payload;
END;
$$;

-- --------------------------------------------------------------------------
-- 7. Permisos RPC
-- --------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.cerrar_captura_digital_qr_425(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cerrar_captura_digital_qr_425(text,text) TO anon, authenticated;

REVOKE ALL ON FUNCTION public.obtener_tarjeta_publica_qr_425(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_tarjeta_publica_qr_425(text,text) TO anon, authenticated;

REVOKE ALL ON FUNCTION public.reabrir_captura_digital_qr_admin_425(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reabrir_captura_digital_qr_admin_425(uuid,text) TO authenticated;

-- Mantener permisos públicos existentes de iniciar_captura_qr_423.
REVOKE ALL ON FUNCTION public.iniciar_captura_qr_423(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.iniciar_captura_qr_423(text) TO anon, authenticated;

COMMIT;
