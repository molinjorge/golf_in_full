-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 323
-- BEST BALL F9 — CAPTURA FISICA POR JUGADOR/HOYO
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.tournament_best_ball_physical_hole_scores (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    physical_reception_id uuid NOT NULL
        REFERENCES public.tournament_scorecard_physical_receptions(id)
        ON DELETE RESTRICT,
    score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id)
        ON DELETE RESTRICT,
    best_ball_scorecard_member_id uuid NOT NULL
        REFERENCES public.tournament_best_ball_scorecard_members(id)
        ON DELETE RESTRICT,
    player_id uuid NOT NULL
        REFERENCES public.players(id)
        ON DELETE RESTRICT,
    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id)
        ON DELETE RESTRICT,
    round_hole_snapshot_id uuid NOT NULL
        REFERENCES public.tournament_round_hole_snapshots(id)
        ON DELETE RESTRICT,
    hole_number integer NOT NULL CHECK (hole_number>0),
    play_sequence integer NOT NULL CHECK (play_sequence>0),
    physical_result_type text NOT NULL
        CHECK (physical_result_type IN ('SCORE','PICKUP')),
    physical_gross_score integer NULL
        CHECK (physical_gross_score IS NULL OR physical_gross_score>0),
    captured_by_auth_user_id uuid NOT NULL,
    updated_by_auth_user_id uuid NOT NULL,
    captured_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT best_ball_physical_result_state_ck CHECK (
        (physical_result_type='SCORE' AND physical_gross_score IS NOT NULL)
        OR
        (physical_result_type='PICKUP' AND physical_gross_score IS NULL)
    ),

    UNIQUE(score_card_id,best_ball_scorecard_member_id,round_hole_snapshot_id),
    UNIQUE(score_card_id,best_ball_scorecard_member_id,play_sequence)
);

CREATE INDEX IF NOT EXISTS ix_best_ball_physical_scores_reception
ON public.tournament_best_ball_physical_hole_scores(physical_reception_id);

CREATE INDEX IF NOT EXISTS ix_best_ball_physical_scores_card
ON public.tournament_best_ball_physical_hole_scores(score_card_id,play_sequence);

ALTER TABLE public.tournament_best_ball_physical_hole_scores ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.tournament_best_ball_physical_hole_scores FROM anon,authenticated;
GRANT ALL ON TABLE public.tournament_best_ball_physical_hole_scores TO service_role;

CREATE TABLE IF NOT EXISTS public.tournament_best_ball_physical_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    score_card_id uuid NOT NULL REFERENCES public.tournament_score_cards(id) ON DELETE RESTRICT,
    physical_reception_id uuid NOT NULL REFERENCES public.tournament_scorecard_physical_receptions(id) ON DELETE RESTRICT,
    best_ball_physical_hole_score_id uuid NULL
        REFERENCES public.tournament_best_ball_physical_hole_scores(id)
        ON DELETE RESTRICT,
    event_type text NOT NULL CHECK (
        event_type IN ('physical_score_entered','physical_score_corrected')
    ),
    actor_auth_user_id uuid NOT NULL,
    old_physical_result_type text NULL
        CHECK (old_physical_result_type IS NULL OR old_physical_result_type IN ('SCORE','PICKUP')),
    new_physical_result_type text NULL
        CHECK (new_physical_result_type IS NULL OR new_physical_result_type IN ('SCORE','PICKUP')),
    old_physical_gross_score integer NULL CHECK (old_physical_gross_score IS NULL OR old_physical_gross_score>0),
    new_physical_gross_score integer NULL CHECK (new_physical_gross_score IS NULL OR new_physical_gross_score>0),
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.tournament_best_ball_physical_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.tournament_best_ball_physical_events FROM anon,authenticated;
GRANT ALL ON TABLE public.tournament_best_ball_physical_events TO service_role;

CREATE OR REPLACE FUNCTION public._validar_best_ball_physical_hole_score_323()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_ctx record;
BEGIN
    SELECT
        sc.id score_card_id,
        sc.tournament_round_id,
        sc.tournament_team_id,
        sc.status card_status,
        v.scoring_engine,
        v.participation_type,
        pr.id reception_id,
        pr.score_card_id reception_card_id,
        ss.id snapshot_id,
        bm.id member_id,
        bm.player_id member_player_id,
        hs.id digital_hole_score_id,
        hs.hole_number,
        hs.play_sequence
      INTO v_ctx
      FROM public.tournament_score_cards sc
      JOIN public.tournament_round_start_validations v ON v.id=sc.validation_id
      JOIN public.tournament_scorecard_physical_receptions pr ON pr.id=NEW.physical_reception_id
      JOIN public.tournament_best_ball_scorecard_snapshots ss ON ss.score_card_id=sc.id
      JOIN public.tournament_best_ball_scorecard_members bm
        ON bm.id=NEW.best_ball_scorecard_member_id
       AND bm.best_ball_scorecard_snapshot_id=ss.id
      JOIN public.tournament_best_ball_hole_scores hs
        ON hs.score_card_id=sc.id
       AND hs.best_ball_scorecard_member_id=bm.id
       AND hs.round_hole_snapshot_id=NEW.round_hole_snapshot_id
     WHERE sc.id=NEW.score_card_id
     LIMIT 1;

    IF v_ctx.score_card_id IS NULL
       OR v_ctx.card_status<>'issued'
       OR v_ctx.scoring_engine<>'best_ball'
       OR v_ctx.participation_type<>'equipo'
       OR v_ctx.reception_card_id IS DISTINCT FROM NEW.score_card_id
       OR v_ctx.tournament_round_id IS DISTINCT FROM NEW.tournament_round_id
       OR v_ctx.member_player_id IS DISTINCT FROM NEW.player_id
       OR v_ctx.digital_hole_score_id IS NULL
       OR v_ctx.hole_number IS DISTINCT FROM NEW.hole_number
       OR v_ctx.play_sequence IS DISTINCT FROM NEW.play_sequence
    THEN
        RAISE EXCEPTION 'La fila física Best Ball no corresponde al contexto congelado de tarjeta/integrante/hoyo.'
            USING ERRCODE='23514';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_validar_best_ball_physical_323
ON public.tournament_best_ball_physical_hole_scores;

CREATE TRIGGER trg_validar_best_ball_physical_323
BEFORE INSERT OR UPDATE
ON public.tournament_best_ball_physical_hole_scores
FOR EACH ROW EXECUTE FUNCTION public._validar_best_ball_physical_hole_score_323();

-- Reutilizar protecciones compatibles ya existentes.
CREATE TRIGGER trg_best_ball_physical_cancelado_323
BEFORE INSERT OR UPDATE OR DELETE ON public.tournament_best_ball_physical_hole_scores
FOR EACH ROW EXECUTE FUNCTION public._bloquear_mutacion_scorecard_cancelado_233();

CREATE TRIGGER trg_best_ball_physical_vencido_323
BEFORE INSERT OR UPDATE OR DELETE ON public.tournament_best_ball_physical_hole_scores
FOR EACH ROW EXECUTE FUNCTION public._bloquear_mutacion_scorecard_torneo_vencido_295();

CREATE TRIGGER trg_best_ball_physical_ronda_cerrada_323
BEFORE INSERT OR UPDATE OR DELETE ON public.tournament_best_ball_physical_hole_scores
FOR EACH ROW EXECUTE FUNCTION public.proteger_datos_ronda_competitiva_cerrada();

CREATE TRIGGER trg_best_ball_physical_inicio_323
BEFORE INSERT OR UPDATE ON public.tournament_best_ball_physical_hole_scores
FOR EACH ROW EXECUTE FUNCTION public._bloquear_fisico_antes_inicio_256();

CREATE OR REPLACE FUNCTION public._obtener_score_card_best_ball_fisica_323(
    p_score_card_id uuid
)
RETURNS public.tournament_score_cards
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_card public.tournament_score_cards;
    v_ok boolean;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT sc.* INTO v_card
      FROM public.tournament_score_cards sc
      JOIN public.tournament_round_start_validations v ON v.id=sc.validation_id
     WHERE sc.id=p_score_card_id
       AND sc.status='issued'
       AND sc.unit_type='team'
       AND v.participation_type='equipo'
       AND v.scoring_engine='best_ball'
     LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION 'Tarjeta Best Ball TEAM no encontrada o no emitida.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_card.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para capturar esta tarjeta física.'
            USING ERRCODE='42501';
    END IF;

    SELECT
        EXISTS(SELECT 1 FROM public.tournament_scorecard_capture_sessions cs WHERE cs.score_card_id=v_card.id)
        AND EXISTS(SELECT 1 FROM public.tournament_best_ball_scorecard_snapshots ss WHERE ss.score_card_id=v_card.id)
        AND NOT EXISTS(
            SELECT 1
            FROM public.tournament_best_ball_scorecard_members bm
            JOIN public.tournament_best_ball_scorecard_snapshots ss
              ON ss.id=bm.best_ball_scorecard_snapshot_id
            WHERE ss.score_card_id=v_card.id
            GROUP BY ss.id
            HAVING count(*) NOT BETWEEN 2 AND 5
        )
      INTO v_ok;

    IF NOT COALESCE(v_ok,false) THEN
        RAISE EXCEPTION 'La estructura Best Ball de la tarjeta no está inicializada correctamente.'
            USING ERRCODE='55000';
    END IF;

    RETURN v_card;
END;
$function$;

CREATE OR REPLACE FUNCTION public.recibir_tarjeta_fisica_best_ball_323(
    p_score_card_id uuid,
    p_player_signature_present boolean,
    p_marker_signature_present boolean,
    p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_card public.tournament_score_cards;
    v_reception public.tournament_scorecard_physical_receptions;
BEGIN
    v_card:=public._obtener_score_card_best_ball_fisica_323(p_score_card_id);

    SELECT * INTO v_reception
      FROM public.tournament_scorecard_physical_receptions
     WHERE score_card_id=v_card.id
     LIMIT 1;

    IF v_reception.id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'scoreCardId',v_card.id,
            'physicalReceptionId',v_reception.id,
            'status',v_reception.status,
            'alreadyReceived',true
        );
    END IF;

    INSERT INTO public.tournament_scorecard_physical_receptions(
        score_card_id,tournament_id,tournament_round_id,
        player_signature_present,marker_signature_present,
        notes,received_by_auth_user_id
    )
    VALUES(
        v_card.id,v_card.tournament_id,v_card.tournament_round_id,
        COALESCE(p_player_signature_present,false),
        COALESCE(p_marker_signature_present,false),
        NULLIF(btrim(COALESCE(p_notes,'')),''),
        auth.uid()
    )
    RETURNING * INTO v_reception;

    INSERT INTO public.tournament_scorecard_physical_events(
        score_card_id,physical_reception_id,event_type,actor_auth_user_id
    )
    VALUES(
        v_card.id,v_reception.id,'physical_card_received',auth.uid()
    );

    RETURN jsonb_build_object(
        'scoreCardId',v_card.id,
        'physicalReceptionId',v_reception.id,
        'status',v_reception.status,
        'alreadyReceived',false
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.guardar_resultado_fisico_hoyo_best_ball_323(
    p_score_card_id uuid,
    p_best_ball_scorecard_member_id uuid,
    p_round_hole_snapshot_id uuid,
    p_physical_result_type text,
    p_physical_gross_score integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_card public.tournament_score_cards;
    v_reception public.tournament_scorecard_physical_receptions;
    v_hole record;
    v_existing public.tournament_best_ball_physical_hole_scores;
    v_saved public.tournament_best_ball_physical_hole_scores;
    v_player_id uuid;
    v_new_gross integer;
BEGIN
    v_card:=public._obtener_score_card_best_ball_fisica_323(p_score_card_id);

    p_physical_result_type:=upper(btrim(COALESCE(p_physical_result_type,'')));

    IF p_physical_result_type NOT IN ('SCORE','PICKUP') THEN
        RAISE EXCEPTION 'physical_result_type debe ser SCORE o PICKUP.'
            USING ERRCODE='22023';
    END IF;

    IF p_physical_result_type='SCORE'
       AND (p_physical_gross_score IS NULL OR p_physical_gross_score<=0)
    THEN
        RAISE EXCEPTION 'SCORE físico requiere gross mayor que cero.'
            USING ERRCODE='22023';
    END IF;

    IF p_physical_result_type='PICKUP' AND p_physical_gross_score IS NOT NULL THEN
        RAISE EXCEPTION 'PICKUP físico no admite gross.'
            USING ERRCODE='22023';
    END IF;

    v_new_gross:=CASE WHEN p_physical_result_type='SCORE'
                      THEN p_physical_gross_score ELSE NULL END;

    SELECT * INTO v_reception
      FROM public.tournament_scorecard_physical_receptions
     WHERE score_card_id=v_card.id
     FOR UPDATE;

    IF v_reception.id IS NULL THEN
        RAISE EXCEPTION 'Primero debe registrarse la recepción física Best Ball.'
            USING ERRCODE='55000';
    END IF;

    IF v_reception.status IN ('CAPTURED','VOIDED') THEN
        RAISE EXCEPTION 'La captura física ya no admite edición directa.'
            USING ERRCODE='55000';
    END IF;

    SELECT
        hs.player_id,hs.hole_number,hs.play_sequence
      INTO v_hole
      FROM public.tournament_best_ball_hole_scores hs
     WHERE hs.score_card_id=v_card.id
       AND hs.best_ball_scorecard_member_id=p_best_ball_scorecard_member_id
       AND hs.round_hole_snapshot_id=p_round_hole_snapshot_id
     LIMIT 1;

    IF v_hole.player_id IS NULL THEN
        RAISE EXCEPTION 'El integrante/hoyo indicado no pertenece a esta tarjeta Best Ball.'
            USING ERRCODE='22023';
    END IF;

    v_player_id:=v_hole.player_id;

    IF v_reception.status='RECEIVED' THEN
        UPDATE public.tournament_scorecard_physical_receptions
           SET status='IN_CAPTURE',
               capture_started_at=now(),
               capture_started_by_auth_user_id=auth.uid(),
               updated_at=now()
         WHERE id=v_reception.id
         RETURNING * INTO v_reception;

        INSERT INTO public.tournament_scorecard_physical_events(
            score_card_id,physical_reception_id,event_type,actor_auth_user_id
        )
        VALUES(v_card.id,v_reception.id,'physical_capture_started',auth.uid());
    END IF;

    SELECT * INTO v_existing
      FROM public.tournament_best_ball_physical_hole_scores
     WHERE score_card_id=v_card.id
       AND best_ball_scorecard_member_id=p_best_ball_scorecard_member_id
       AND round_hole_snapshot_id=p_round_hole_snapshot_id
     FOR UPDATE;

    IF v_existing.id IS NULL THEN
        INSERT INTO public.tournament_best_ball_physical_hole_scores(
            physical_reception_id,score_card_id,best_ball_scorecard_member_id,
            player_id,tournament_round_id,round_hole_snapshot_id,
            hole_number,play_sequence,physical_result_type,
            physical_gross_score,captured_by_auth_user_id,updated_by_auth_user_id
        )
        VALUES(
            v_reception.id,v_card.id,p_best_ball_scorecard_member_id,
            v_player_id,v_card.tournament_round_id,p_round_hole_snapshot_id,
            v_hole.hole_number,v_hole.play_sequence,p_physical_result_type,
            v_new_gross,auth.uid(),auth.uid()
        )
        RETURNING * INTO v_saved;

        INSERT INTO public.tournament_best_ball_physical_events(
            score_card_id,physical_reception_id,best_ball_physical_hole_score_id,
            event_type,actor_auth_user_id,new_physical_result_type,new_physical_gross_score
        )
        VALUES(
            v_card.id,v_reception.id,v_saved.id,'physical_score_entered',
            auth.uid(),p_physical_result_type,v_new_gross
        );
    ELSE
        IF v_existing.physical_result_type IS NOT DISTINCT FROM p_physical_result_type
           AND v_existing.physical_gross_score IS NOT DISTINCT FROM v_new_gross
        THEN
            RETURN jsonb_build_object(
                'scoreCardId',v_card.id,'physicalReceptionId',v_reception.id,
                'bestBallPhysicalHoleScoreId',v_existing.id,
                'physicalResultType',v_existing.physical_result_type,
                'physicalGrossScore',v_existing.physical_gross_score,
                'changed',false
            );
        END IF;

        UPDATE public.tournament_best_ball_physical_hole_scores
           SET physical_result_type=p_physical_result_type,
               physical_gross_score=v_new_gross,
               updated_at=now(),
               updated_by_auth_user_id=auth.uid()
         WHERE id=v_existing.id
         RETURNING * INTO v_saved;

        INSERT INTO public.tournament_best_ball_physical_events(
            score_card_id,physical_reception_id,best_ball_physical_hole_score_id,
            event_type,actor_auth_user_id,
            old_physical_result_type,new_physical_result_type,
            old_physical_gross_score,new_physical_gross_score
        )
        VALUES(
            v_card.id,v_reception.id,v_saved.id,'physical_score_corrected',auth.uid(),
            v_existing.physical_result_type,v_saved.physical_result_type,
            v_existing.physical_gross_score,v_saved.physical_gross_score
        );
    END IF;

    RETURN jsonb_build_object(
        'scoreCardId',v_card.id,
        'physicalReceptionId',v_reception.id,
        'bestBallPhysicalHoleScoreId',v_saved.id,
        'bestBallScorecardMemberId',p_best_ball_scorecard_member_id,
        'playerId',v_player_id,
        'holeNumber',v_saved.hole_number,
        'playSequence',v_saved.play_sequence,
        'physicalResultType',v_saved.physical_result_type,
        'physicalGrossScore',v_saved.physical_gross_score,
        'status',v_reception.status,
        'changed',true
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.finalizar_captura_fisica_best_ball_323(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_card public.tournament_score_cards;
    v_reception public.tournament_scorecard_physical_receptions;
    v_members integer;
    v_expected integer;
    v_captured integer;
BEGIN
    v_card:=public._obtener_score_card_best_ball_fisica_323(p_score_card_id);

    SELECT * INTO v_reception
      FROM public.tournament_scorecard_physical_receptions
     WHERE score_card_id=v_card.id
     FOR UPDATE;

    IF v_reception.id IS NULL THEN
        RAISE EXCEPTION 'Primero debe registrarse la recepción física Best Ball.'
            USING ERRCODE='55000';
    END IF;

    IF v_reception.status='VOIDED' THEN
        RAISE EXCEPTION 'La recepción física está anulada.' USING ERRCODE='55000';
    END IF;

    IF v_reception.status='CAPTURED' THEN
        RETURN jsonb_build_object(
            'scoreCardId',v_card.id,'physicalReceptionId',v_reception.id,
            'status','CAPTURED','alreadyCompleted',true
        );
    END IF;

    SELECT count(*) INTO v_members
      FROM public.tournament_best_ball_scorecard_members bm
      JOIN public.tournament_best_ball_scorecard_snapshots ss
        ON ss.id=bm.best_ball_scorecard_snapshot_id
     WHERE ss.score_card_id=v_card.id;

    v_expected:=v_members*18;

    SELECT count(*) INTO v_captured
      FROM public.tournament_best_ball_physical_hole_scores
     WHERE score_card_id=v_card.id;

    IF v_captured<>v_expected THEN
        RAISE EXCEPTION
            'No se puede finalizar Best Ball: hay % resultados físicos capturados de % esperados.',
            v_captured,v_expected
            USING ERRCODE='55000';
    END IF;

    UPDATE public.tournament_scorecard_physical_receptions
       SET status='CAPTURED',
           capture_started_at=COALESCE(capture_started_at,now()),
           capture_started_by_auth_user_id=COALESCE(capture_started_by_auth_user_id,auth.uid()),
           capture_completed_at=now(),
           capture_completed_by_auth_user_id=auth.uid(),
           updated_at=now()
     WHERE id=v_reception.id
     RETURNING * INTO v_reception;

    INSERT INTO public.tournament_scorecard_physical_events(
        score_card_id,physical_reception_id,event_type,actor_auth_user_id
    )
    VALUES(v_card.id,v_reception.id,'physical_capture_completed',auth.uid());

    RETURN jsonb_build_object(
        'scoreCardId',v_card.id,
        'physicalReceptionId',v_reception.id,
        'status','CAPTURED',
        'alreadyCompleted',false,
        'memberCount',v_members,
        'capturedResults',v_captured,
        'expectedResults',v_expected,
        'completedAt',v_reception.capture_completed_at
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.obtener_captura_fisica_best_ball_323(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_card public.tournament_score_cards;
    v_reception public.tournament_scorecard_physical_receptions;
BEGIN
    v_card:=public._obtener_score_card_best_ball_fisica_323(p_score_card_id);

    SELECT * INTO v_reception
      FROM public.tournament_scorecard_physical_receptions
     WHERE score_card_id=v_card.id;

    RETURN jsonb_build_object(
        'scoreCardId',v_card.id,
        'cardFolio',v_card.card_folio,
        'tournamentId',v_card.tournament_id,
        'tournamentRoundId',v_card.tournament_round_id,
        'received',v_reception.id IS NOT NULL,
        'reception',CASE WHEN v_reception.id IS NULL THEN NULL ELSE jsonb_build_object(
            'id',v_reception.id,
            'status',v_reception.status,
            'playerSignaturePresent',v_reception.player_signature_present,
            'markerSignaturePresent',v_reception.marker_signature_present,
            'notes',v_reception.notes,
            'receivedAt',v_reception.received_at,
            'captureStartedAt',v_reception.capture_started_at,
            'captureCompletedAt',v_reception.capture_completed_at
        ) END,
        'physicalResults',COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'id',ph.id,
                    'bestBallScorecardMemberId',ph.best_ball_scorecard_member_id,
                    'playerId',ph.player_id,
                    'playerName',btrim(concat_ws(' ',p.nombres,p.apellidos)),
                    'roundHoleSnapshotId',ph.round_hole_snapshot_id,
                    'holeNumber',ph.hole_number,
                    'playSequence',ph.play_sequence,
                    'physicalResultType',ph.physical_result_type,
                    'physicalGrossScore',ph.physical_gross_score,
                    'capturedAt',ph.captured_at,
                    'updatedAt',ph.updated_at
                )
                ORDER BY ph.play_sequence,bm.member_order,ph.player_id
            )
            FROM public.tournament_best_ball_physical_hole_scores ph
            JOIN public.tournament_best_ball_scorecard_members bm
              ON bm.id=ph.best_ball_scorecard_member_id
            LEFT JOIN public.players p ON p.id=ph.player_id
            WHERE ph.score_card_id=v_card.id
        ),'[]'::jsonb)
    );
END;
$function$;

COMMIT;
