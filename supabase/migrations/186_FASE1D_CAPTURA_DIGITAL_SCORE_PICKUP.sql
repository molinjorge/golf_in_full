-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 186 Fase 1D
-- Captura digital universal SCORE / PICKUP
-- ============================================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.registrar_resultado_hoyo(
    p_score_card_id uuid,
    p_round_hole_snapshot_id uuid,
    p_result_type text,
    p_gross_score integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_player_id uuid;
    v_card record;
    v_hole record;
    v_assignment record;
    v_old_result_type text;
    v_old_gross integer;
    v_event_type text;
    v_remaining integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    p_result_type := upper(btrim(COALESCE(p_result_type,'')));

    IF p_result_type NOT IN ('SCORE','PICKUP') THEN
        RAISE EXCEPTION 'result_type debe ser SCORE o PICKUP.' USING ERRCODE='22023';
    END IF;

    IF p_result_type='SCORE' AND (p_gross_score IS NULL OR p_gross_score <= 0) THEN
        RAISE EXCEPTION 'SCORE requiere un gross mayor que cero.' USING ERRCODE='22023';
    END IF;

    IF p_result_type='PICKUP' AND p_gross_score IS NOT NULL THEN
        RAISE EXCEPTION 'PICKUP no admite gross_score.' USING ERRCODE='22023';
    END IF;

    v_player_id := public._scorecard_current_player_id();
    IF v_player_id IS NULL THEN
        RAISE EXCEPTION 'El usuario autenticado no está vinculado a un jugador activo.' USING ERRCODE='42501';
    END IF;

    SELECT sc.*, v.scoring_engine
      INTO v_card
      FROM public.tournament_score_cards sc
      JOIN public.tournament_round_start_validations v ON v.id=sc.validation_id
     WHERE sc.id=p_score_card_id AND sc.status='issued'
     LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION 'Tarjeta oficial no encontrada.' USING ERRCODE='22023';
    END IF;

    IF p_result_type='PICKUP' AND COALESCE(v_card.scoring_engine,'') <> 'stableford' THEN
        RAISE EXCEPTION 'PICKUP sólo está permitido en rondas Stableford.' USING ERRCODE='0A000';
    END IF;

    IF v_card.player_id=v_player_id THEN
        RAISE EXCEPTION 'No puedes capturar tu propio resultado.' USING ERRCODE='42501';
    END IF;

    SELECT hs.*
      INTO v_hole
      FROM public.tournament_scorecard_hole_scores hs
     WHERE hs.score_card_id=p_score_card_id
       AND hs.round_hole_snapshot_id=p_round_hole_snapshot_id
     FOR UPDATE;

    IF v_hole.id IS NULL THEN
        RAISE EXCEPTION 'El hoyo indicado no pertenece a la captura de esta tarjeta.' USING ERRCODE='22023';
    END IF;

    SELECT ma.*
      INTO v_assignment
      FROM public.tournament_scorecard_marker_assignments ma
     WHERE ma.score_card_id=p_score_card_id
       AND ma.marker_player_id=v_player_id
       AND ma.status='active'
       AND ma.valid_from_sequence <= v_hole.play_sequence
       AND (ma.valid_to_sequence IS NULL OR ma.valid_to_sequence >= v_hole.play_sequence)
     ORDER BY ma.assigned_at DESC, ma.id DESC
     LIMIT 1;

    IF v_assignment.id IS NULL THEN
        RAISE EXCEPTION 'No eres el marcador vigente de esta tarjeta para este hoyo.' USING ERRCODE='42501';
    END IF;

    IF v_hole.status='confirmed' THEN
        RAISE EXCEPTION 'El jugador ya confirmó este hoyo y el marcador no puede modificarlo.'
            USING ERRCODE='55000', HINT='Las correcciones posteriores requieren el flujo del Comité.';
    END IF;

    v_old_result_type := v_hole.result_type;
    v_old_gross := v_hole.gross_score;
    v_event_type := CASE WHEN v_hole.result_type='PENDING' THEN 'score_entered' ELSE 'score_corrected' END;

    UPDATE public.tournament_scorecard_hole_scores
       SET result_type=p_result_type,
           gross_score=CASE WHEN p_result_type='SCORE' THEN p_gross_score ELSE NULL END,
           status='entered',
           marker_assignment_id=v_assignment.id,
           entered_by_player_id=v_player_id,
           entered_at=now(),
           confirmed_by_player_id=NULL,
           confirmed_at=NULL,
           player_claimed_result_type=NULL,
           player_claimed_gross_score=NULL,
           dispute_note=NULL,
           disputed_at=NULL
     WHERE id=v_hole.id;

    INSERT INTO public.tournament_scorecard_events(
        score_card_id,hole_score_id,marker_assignment_id,event_type,actor_player_id,
        old_result_type,new_result_type,old_gross_score,new_gross_score
    ) VALUES (
        p_score_card_id,v_hole.id,v_assignment.id,v_event_type,v_player_id,
        v_old_result_type,p_result_type,v_old_gross,
        CASE WHEN p_result_type='SCORE' THEN p_gross_score ELSE NULL END
    );

    UPDATE public.tournament_scorecard_capture_sessions
       SET status=CASE WHEN status='ready' THEN 'in_progress' ELSE status END,
           started_at=COALESCE(started_at,now())
     WHERE score_card_id=p_score_card_id;

    SELECT count(*) INTO v_remaining
      FROM public.tournament_scorecard_hole_scores hs
     WHERE hs.score_card_id=p_score_card_id
       AND hs.result_type='PENDING';

    IF v_remaining=0 THEN
        UPDATE public.tournament_scorecard_capture_sessions
           SET status='captured',
               started_at=COALESCE(started_at,now()),
               captured_at=COALESCE(captured_at,now())
         WHERE score_card_id=p_score_card_id;
    END IF;

    RETURN jsonb_build_object(
        'holeScoreId',v_hole.id,'scoreCardId',p_score_card_id,'holeNumber',v_hole.hole_number,
        'playSequence',v_hole.play_sequence,'resultType',p_result_type,
        'grossScore',CASE WHEN p_result_type='SCORE' THEN p_gross_score ELSE NULL END,
        'status','entered'
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.registrar_resultado_hoyo(uuid,uuid,text,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.registrar_resultado_hoyo(uuid,uuid,text,integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.registrar_score_hoyo(
    p_score_card_id uuid,
    p_round_hole_snapshot_id uuid,
    p_gross_score integer
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT public.registrar_resultado_hoyo(p_score_card_id,p_round_hole_snapshot_id,'SCORE',p_gross_score);
$function$;

REVOKE ALL ON FUNCTION public.registrar_score_hoyo(uuid,uuid,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.registrar_score_hoyo(uuid,uuid,integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.confirmar_score_hoyo(p_hole_score_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_player_id uuid;
    v_hole record;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501'; END IF;
    v_player_id := public._scorecard_current_player_id();
    IF v_player_id IS NULL THEN
        RAISE EXCEPTION 'El usuario autenticado no está vinculado a un jugador activo.' USING ERRCODE='42501';
    END IF;

    SELECT hs.*, sc.player_id AS owner_player_id
      INTO v_hole
      FROM public.tournament_scorecard_hole_scores hs
      JOIN public.tournament_score_cards sc ON sc.id=hs.score_card_id AND sc.status='issued'
     WHERE hs.id=p_hole_score_id
     FOR UPDATE OF hs;

    IF v_hole.id IS NULL THEN RAISE EXCEPTION 'Resultado de hoyo no encontrado.' USING ERRCODE='22023'; END IF;
    IF v_hole.owner_player_id <> v_player_id THEN
        RAISE EXCEPTION 'Sólo el dueño de la tarjeta puede confirmar este resultado.' USING ERRCODE='42501';
    END IF;
    IF v_hole.status <> 'entered' OR v_hole.result_type NOT IN ('SCORE','PICKUP') THEN
        RAISE EXCEPTION 'Este hoyo no está disponible para confirmación.' USING ERRCODE='55000';
    END IF;

    UPDATE public.tournament_scorecard_hole_scores
       SET status='confirmed',confirmed_by_player_id=v_player_id,confirmed_at=now()
     WHERE id=p_hole_score_id;

    INSERT INTO public.tournament_scorecard_events(
        score_card_id,hole_score_id,marker_assignment_id,event_type,actor_player_id,
        old_result_type,new_result_type,old_gross_score,new_gross_score
    ) VALUES (
        v_hole.score_card_id,v_hole.id,v_hole.marker_assignment_id,'player_confirmed',v_player_id,
        v_hole.result_type,v_hole.result_type,v_hole.gross_score,v_hole.gross_score
    );

    RETURN jsonb_build_object(
        'holeScoreId',v_hole.id,'scoreCardId',v_hole.score_card_id,'holeNumber',v_hole.hole_number,
        'resultType',v_hole.result_type,'grossScore',v_hole.gross_score,'status','confirmed'
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.disputar_resultado_hoyo(
    p_hole_score_id uuid,
    p_claimed_result_type text,
    p_claimed_gross_score integer DEFAULT NULL,
    p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_player_id uuid;
    v_hole record;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501'; END IF;

    p_claimed_result_type := upper(btrim(COALESCE(p_claimed_result_type,'')));
    IF p_claimed_result_type NOT IN ('SCORE','PICKUP') THEN
        RAISE EXCEPTION 'claimed_result_type debe ser SCORE o PICKUP.' USING ERRCODE='22023';
    END IF;
    IF p_claimed_result_type='SCORE' AND (p_claimed_gross_score IS NULL OR p_claimed_gross_score <= 0) THEN
        RAISE EXCEPTION 'Una reclamación SCORE requiere gross mayor que cero.' USING ERRCODE='22023';
    END IF;
    IF p_claimed_result_type='PICKUP' AND p_claimed_gross_score IS NOT NULL THEN
        RAISE EXCEPTION 'Una reclamación PICKUP no admite gross.' USING ERRCODE='22023';
    END IF;

    v_player_id := public._scorecard_current_player_id();
    IF v_player_id IS NULL THEN
        RAISE EXCEPTION 'El usuario autenticado no está vinculado a un jugador activo.' USING ERRCODE='42501';
    END IF;

    SELECT hs.*, sc.player_id AS owner_player_id, v.scoring_engine
      INTO v_hole
      FROM public.tournament_scorecard_hole_scores hs
      JOIN public.tournament_score_cards sc ON sc.id=hs.score_card_id AND sc.status='issued'
      JOIN public.tournament_round_start_validations v ON v.id=sc.validation_id
     WHERE hs.id=p_hole_score_id
     FOR UPDATE OF hs;

    IF v_hole.id IS NULL THEN RAISE EXCEPTION 'Resultado de hoyo no encontrado.' USING ERRCODE='22023'; END IF;
    IF v_hole.owner_player_id <> v_player_id THEN
        RAISE EXCEPTION 'Sólo el dueño de la tarjeta puede disputar este resultado.' USING ERRCODE='42501';
    END IF;
    IF v_hole.status <> 'entered' OR v_hole.result_type NOT IN ('SCORE','PICKUP') THEN
        RAISE EXCEPTION 'Este hoyo no está disponible para disputa.' USING ERRCODE='55000';
    END IF;
    IF p_claimed_result_type='PICKUP' AND COALESCE(v_hole.scoring_engine,'') <> 'stableford' THEN
        RAISE EXCEPTION 'PICKUP sólo está permitido en rondas Stableford.' USING ERRCODE='0A000';
    END IF;
    IF p_claimed_result_type IS NOT DISTINCT FROM v_hole.result_type
       AND p_claimed_gross_score IS NOT DISTINCT FROM v_hole.gross_score THEN
        RAISE EXCEPTION 'El resultado reclamado coincide con el capturado; puedes confirmarlo.' USING ERRCODE='22023';
    END IF;

    UPDATE public.tournament_scorecard_hole_scores
       SET status='disputed',
           player_claimed_result_type=p_claimed_result_type,
           player_claimed_gross_score=CASE WHEN p_claimed_result_type='SCORE' THEN p_claimed_gross_score ELSE NULL END,
           dispute_note=NULLIF(btrim(COALESCE(p_reason,'')),'') ,
           disputed_at=now(),confirmed_by_player_id=NULL,confirmed_at=NULL
     WHERE id=p_hole_score_id;

    INSERT INTO public.tournament_scorecard_events(
        score_card_id,hole_score_id,marker_assignment_id,event_type,actor_player_id,
        old_result_type,new_result_type,old_gross_score,new_gross_score,
        claimed_result_type,claimed_gross_score,reason
    ) VALUES (
        v_hole.score_card_id,v_hole.id,v_hole.marker_assignment_id,'player_disputed',v_player_id,
        v_hole.result_type,v_hole.result_type,v_hole.gross_score,v_hole.gross_score,
        p_claimed_result_type,
        CASE WHEN p_claimed_result_type='SCORE' THEN p_claimed_gross_score ELSE NULL END,
        NULLIF(btrim(COALESCE(p_reason,'')),'')
    );

    RETURN jsonb_build_object(
        'holeScoreId',v_hole.id,'scoreCardId',v_hole.score_card_id,'holeNumber',v_hole.hole_number,
        'resultType',v_hole.result_type,'grossScore',v_hole.gross_score,
        'playerClaimedResultType',p_claimed_result_type,
        'playerClaimedGrossScore',CASE WHEN p_claimed_result_type='SCORE' THEN p_claimed_gross_score ELSE NULL END,
        'status','disputed'
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.disputar_resultado_hoyo(uuid,text,integer,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.disputar_resultado_hoyo(uuid,text,integer,text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.disputar_score_hoyo(
    p_hole_score_id uuid,
    p_claimed_gross_score integer,
    p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT public.disputar_resultado_hoyo(p_hole_score_id,'SCORE',p_claimed_gross_score,p_reason);
$function$;

REVOKE ALL ON FUNCTION public.disputar_score_hoyo(uuid,integer,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.disputar_score_hoyo(uuid,integer,text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public._tarjeta_tiene_captura_digital_real(p_score_card_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT
        EXISTS (
            SELECT 1 FROM public.tournament_scorecard_capture_sessions cs
            WHERE cs.score_card_id=p_score_card_id
              AND (cs.started_at IS NOT NULL OR cs.status IN ('in_progress','captured'))
        )
        OR EXISTS (
            SELECT 1 FROM public.tournament_scorecard_hole_scores hs
            WHERE hs.score_card_id=p_score_card_id
              AND hs.result_type IN ('SCORE','PICKUP')
        );
$function$;

-- Cambios pequeños y defensivos en RPC existentes.
DO $do$
DECLARE v_def text;
BEGIN
    SELECT pg_get_functiondef('public.asignar_marcador_tarjeta_score(uuid,uuid,integer,text)'::regprocedure) INTO v_def;
    IF position('AND hs.gross_score IS NOT NULL' IN v_def) > 0 THEN
        v_def := replace(v_def,'AND hs.gross_score IS NOT NULL','AND hs.result_type IN (''SCORE'',''PICKUP'')');
        EXECUTE v_def;
    ELSIF position('AND hs.result_type IN (''SCORE'',''PICKUP'')' IN v_def) = 0 THEN
        RAISE EXCEPTION 'No se reconoció el guard de captura en asignar_marcador_tarjeta_score.' USING ERRCODE='55000';
    END IF;
END;
$do$;

DO $do$
DECLARE v_def text;
BEGIN
    SELECT pg_get_functiondef('public.abrir_captura_tarjeta_score(text)'::regprocedure) INTO v_def;
    IF position('''resultType'', hs.result_type' IN v_def)=0 THEN
        v_def := replace(v_def,'''grossScore'', hs.gross_score,','''resultType'', hs.result_type, ''grossScore'', hs.gross_score,');
    END IF;
    IF position('''playerClaimedResultType'',' IN v_def)=0 THEN
        v_def := replace(v_def,'''playerClaimedGrossScore'', CASE','''playerClaimedResultType'', CASE WHEN v_is_owner OR v_is_marker OR v_is_admin THEN hs.player_claimed_result_type ELSE NULL END, ''playerClaimedGrossScore'', CASE');
    END IF;
    EXECUTE v_def;
END;
$do$;

DO $do$
DECLARE v_def text;
BEGIN
    SELECT pg_get_functiondef('public.obtener_detalle_captura_tarjeta_score(uuid)'::regprocedure) INTO v_def;
    v_def := replace(v_def,'AND hs.gross_score IS NOT NULL','AND hs.result_type IN (''SCORE'',''PICKUP'')');
    IF position('''resultType'', hs.result_type' IN v_def)=0 THEN
        v_def := replace(v_def,'''grossScore'', hs.gross_score,','''resultType'', hs.result_type, ''grossScore'', hs.gross_score,');
    END IF;
    IF position('''playerClaimedResultType'',' IN v_def)=0 THEN
        v_def := replace(v_def,'''playerClaimedGrossScore'', CASE','''playerClaimedResultType'', CASE WHEN v_is_owner OR v_is_marker OR v_is_admin THEN hs.player_claimed_result_type ELSE NULL END, ''playerClaimedGrossScore'', CASE');
    END IF;
    EXECUTE v_def;
END;
$do$;

DO $do$
DECLARE v_def text;
BEGIN
    SELECT pg_get_functiondef('public.obtener_mi_panel_scores_ronda(uuid)'::regprocedure) INTO v_def;
    v_def := replace(v_def,'AND hs.gross_score IS NOT NULL','AND hs.result_type IN (''SCORE'',''PICKUP'')');
    EXECUTE v_def;
END;
$do$;

COMMIT;
