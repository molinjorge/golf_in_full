-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 320
-- BEST BALL F6 — CAPTURA DIGITAL POR JUGADOR + CONFIRMACION + DISPUTA
-- ============================================================================
-- OBJETIVO
--   1) Habilitar SCORE/PICKUP por jugador en tournament_best_ball_hole_scores.
--   2) Autorizar captura únicamente al marcador vigente de la tarjeta TEAM.
--   3) Confirmación/disputa por el jugador dueño del score.
--   4) SELF_TEAM:
--        - el marcador captura;
--        - cada integrante confirma/disputa su score;
--        - si el score pertenece al propio marcador, debe actuar OTRO integrante.
--   5) Exigir ronda EN_JUEGO para registrar/modificar resultado competitivo.
--   6) Crear auditoría propia Best Ball, sin tocar tournament_scorecard_events.
--
-- NO HACE
--   - No calcula todavía Best Ball Gross/Neto (F7).
--   - No crea tarjeta/payload UI Best Ball (F8).
--   - No toca tablas de score Stroke/Stableford/A-Go-Go.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1. EVENTOS PROPIOS BEST BALL
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_best_ball_scorecard_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id)
        ON DELETE RESTRICT,

    best_ball_hole_score_id uuid NOT NULL
        REFERENCES public.tournament_best_ball_hole_scores(id)
        ON DELETE RESTRICT,

    marker_assignment_id uuid NULL
        REFERENCES public.tournament_scorecard_marker_assignments(id)
        ON DELETE RESTRICT,

    event_type text NOT NULL
        CHECK (
            event_type IN (
                'score_entered',
                'score_corrected',
                'player_confirmed',
                'player_disputed'
            )
        ),

    actor_player_id uuid NOT NULL
        REFERENCES public.players(id)
        ON DELETE RESTRICT,

    old_result_type text NULL
        CHECK (
            old_result_type IS NULL
            OR old_result_type IN ('PENDING','SCORE','PICKUP')
        ),

    new_result_type text NULL
        CHECK (
            new_result_type IS NULL
            OR new_result_type IN ('PENDING','SCORE','PICKUP')
        ),

    old_gross_score integer NULL
        CHECK (old_gross_score IS NULL OR old_gross_score > 0),

    new_gross_score integer NULL
        CHECK (new_gross_score IS NULL OR new_gross_score > 0),

    claimed_result_type text NULL
        CHECK (
            claimed_result_type IS NULL
            OR claimed_result_type IN ('SCORE','PICKUP')
        ),

    claimed_gross_score integer NULL
        CHECK (claimed_gross_score IS NULL OR claimed_gross_score > 0),

    reason text NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS
    ix_best_ball_scorecard_events_card
ON public.tournament_best_ball_scorecard_events(score_card_id,created_at);

CREATE INDEX IF NOT EXISTS
    ix_best_ball_scorecard_events_hole_score
ON public.tournament_best_ball_scorecard_events(
    best_ball_hole_score_id,
    created_at
);

ALTER TABLE public.tournament_best_ball_scorecard_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_best_ball_scorecard_events
FROM anon, authenticated;

GRANT ALL ON TABLE public.tournament_best_ball_scorecard_events
TO service_role;

-- --------------------------------------------------------------------------
-- 2. PROTECCION EXPLICITA: RONDA EN JUEGO
--    PENDING técnico puede existir antes del inicio.
--    SCORE/PICKUP nuevo o modificado exige lifecycle EN_JUEGO.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._bloquear_best_ball_fuera_ronda_en_juego_320()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_started_at timestamptz;
    v_completed_at timestamptz;
BEGIN
    IF TG_OP='INSERT' THEN
        IF COALESCE(NEW.result_type,'PENDING')='PENDING' THEN
            RETURN NEW;
        END IF;
    ELSE
        IF COALESCE(NEW.result_type,'PENDING')='PENDING' THEN
            RETURN NEW;
        END IF;

        -- Si no cambió el resultado competitivo, no bloquear actualizaciones
        -- accesorias posteriores como confirmación/disputa.
        IF OLD.result_type IS NOT DISTINCT FROM NEW.result_type
           AND OLD.gross_score IS NOT DISTINCT FROM NEW.gross_score
        THEN
            RETURN NEW;
        END IF;
    END IF;

    SELECT l.started_at,l.completed_at
      INTO v_started_at,v_completed_at
      FROM public.tournament_round_lifecycle l
     WHERE l.tournament_round_id=NEW.tournament_round_id;

    IF v_started_at IS NULL OR v_completed_at IS NOT NULL THEN
        RAISE EXCEPTION
            'La captura Best Ball sólo está permitida cuando la ronda está EN JUEGO.'
            USING ERRCODE='55000',
                  DETAIL=format(
                    'tournament_round_id=%s; started_at=%s; completed_at=%s',
                    NEW.tournament_round_id,
                    COALESCE(v_started_at::text,'NULL'),
                    COALESCE(v_completed_at::text,'NULL')
                  );
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_best_ball_ronda_en_juego_320
ON public.tournament_best_ball_hole_scores;

CREATE TRIGGER trg_best_ball_ronda_en_juego_320
BEFORE INSERT OR UPDATE
ON public.tournament_best_ball_hole_scores
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_best_ball_fuera_ronda_en_juego_320();

-- --------------------------------------------------------------------------
-- 3. HELPER DE AUTORIZACION PARA CONFIRMAR/DISPUTAR
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._puede_confirmar_disputar_best_ball_320(
    p_hole_score_id uuid,
    p_player_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_ctx record;
BEGIN
    IF p_hole_score_id IS NULL OR p_player_id IS NULL THEN
        RETURN false;
    END IF;

    SELECT
        hs.player_id AS subject_player_id,
        hs.score_card_id,
        hs.marker_assignment_id,
        ma.marker_player_id,
        ma.assignment_source,
        ss.id AS snapshot_id
      INTO v_ctx
      FROM public.tournament_best_ball_hole_scores hs
      JOIN public.tournament_best_ball_scorecard_snapshots ss
        ON ss.score_card_id=hs.score_card_id
      LEFT JOIN public.tournament_scorecard_marker_assignments ma
        ON ma.id=hs.marker_assignment_id
     WHERE hs.id=p_hole_score_id
     LIMIT 1;

    IF v_ctx.score_card_id IS NULL
       OR v_ctx.marker_assignment_id IS NULL
    THEN
        RETURN false;
    END IF;

    -- Caso normal: el propio jugador valida su score.
    -- También aplica en self_team cuando el subject NO es el marcador.
    IF p_player_id=v_ctx.subject_player_id
       AND p_player_id IS DISTINCT FROM v_ctx.marker_player_id
    THEN
        RETURN true;
    END IF;

    -- SELF_TEAM y score del propio marcador:
    -- debe validar otro integrante congelado de la tarjeta.
    IF v_ctx.assignment_source='self_team'
       AND v_ctx.subject_player_id=v_ctx.marker_player_id
       AND p_player_id<>v_ctx.marker_player_id
       AND EXISTS(
           SELECT 1
           FROM public.tournament_best_ball_scorecard_members bm
           WHERE bm.best_ball_scorecard_snapshot_id=v_ctx.snapshot_id
             AND bm.player_id=p_player_id
       )
    THEN
        RETURN true;
    END IF;

    RETURN false;
END;
$function$;

-- --------------------------------------------------------------------------
-- 4. CAPTURA DIGITAL BEST BALL
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.registrar_resultado_hoyo_best_ball_320(
    p_score_card_id uuid,
    p_best_ball_scorecard_member_id uuid,
    p_round_hole_snapshot_id uuid,
    p_result_type text,
    p_gross_score integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
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
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    p_result_type:=upper(btrim(COALESCE(p_result_type,'')));

    IF p_result_type NOT IN ('SCORE','PICKUP') THEN
        RAISE EXCEPTION 'result_type debe ser SCORE o PICKUP.'
            USING ERRCODE='22023';
    END IF;

    IF p_result_type='SCORE'
       AND (p_gross_score IS NULL OR p_gross_score<=0)
    THEN
        RAISE EXCEPTION 'SCORE requiere gross mayor que cero.'
            USING ERRCODE='22023';
    END IF;

    IF p_result_type='PICKUP' AND p_gross_score IS NOT NULL THEN
        RAISE EXCEPTION 'PICKUP no admite gross_score.'
            USING ERRCODE='22023';
    END IF;

    v_player_id:=public._scorecard_current_player_id();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no está vinculado a un jugador activo.'
            USING ERRCODE='42501';
    END IF;

    SELECT
        sc.*,
        v.scoring_engine,
        v.participation_type
      INTO v_card
      FROM public.tournament_score_cards sc
      JOIN public.tournament_round_start_validations v
        ON v.id=sc.validation_id
     WHERE sc.id=p_score_card_id
       AND sc.status='issued'
     LIMIT 1;

    IF v_card.id IS NULL
       OR v_card.unit_type IS DISTINCT FROM 'team'
       OR v_card.scoring_engine IS DISTINCT FROM 'best_ball'
       OR v_card.participation_type IS DISTINCT FROM 'equipo'
    THEN
        RAISE EXCEPTION 'La tarjeta no corresponde a Best Ball TEAM.'
            USING ERRCODE='22023';
    END IF;

    SELECT hs.*
      INTO v_hole
      FROM public.tournament_best_ball_hole_scores hs
     WHERE hs.score_card_id=p_score_card_id
       AND hs.best_ball_scorecard_member_id=p_best_ball_scorecard_member_id
       AND hs.round_hole_snapshot_id=p_round_hole_snapshot_id
     FOR UPDATE;

    IF v_hole.id IS NULL THEN
        RAISE EXCEPTION
            'El jugador/hoyo indicado no pertenece a esta tarjeta Best Ball.'
            USING ERRCODE='22023';
    END IF;

    SELECT ma.*
      INTO v_assignment
      FROM public.tournament_scorecard_marker_assignments ma
     WHERE ma.score_card_id=p_score_card_id
       AND ma.marker_player_id=v_player_id
       AND ma.status='active'
       AND ma.valid_from_sequence<=v_hole.play_sequence
       AND (
           ma.valid_to_sequence IS NULL
           OR ma.valid_to_sequence>=v_hole.play_sequence
       )
     ORDER BY ma.assigned_at DESC,ma.id DESC
     LIMIT 1;

    IF v_assignment.id IS NULL THEN
        RAISE EXCEPTION
            'No eres el marcador vigente de este equipo para este hoyo.'
            USING ERRCODE='42501';
    END IF;

    IF v_hole.status='confirmed' THEN
        RAISE EXCEPTION
            'Este resultado ya fue confirmado y requiere flujo del Comité para corregirse.'
            USING ERRCODE='55000';
    END IF;

    IF v_hole.status='disputed' THEN
        RAISE EXCEPTION
            'Este resultado está en disputa y no puede ser sobrescrito por el marcador.'
            USING ERRCODE='55000';
    END IF;

    v_old_result_type:=v_hole.result_type;
    v_old_gross:=v_hole.gross_score;
    v_event_type:=CASE
        WHEN v_hole.result_type='PENDING' THEN 'score_entered'
        ELSE 'score_corrected'
    END;

    UPDATE public.tournament_best_ball_hole_scores
       SET result_type=p_result_type,
           gross_score=CASE
               WHEN p_result_type='SCORE' THEN p_gross_score
               ELSE NULL
           END,
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

    INSERT INTO public.tournament_best_ball_scorecard_events(
        score_card_id,
        best_ball_hole_score_id,
        marker_assignment_id,
        event_type,
        actor_player_id,
        old_result_type,
        new_result_type,
        old_gross_score,
        new_gross_score
    )
    VALUES(
        p_score_card_id,
        v_hole.id,
        v_assignment.id,
        v_event_type,
        v_player_id,
        v_old_result_type,
        p_result_type,
        v_old_gross,
        CASE WHEN p_result_type='SCORE' THEN p_gross_score ELSE NULL END
    );

    UPDATE public.tournament_scorecard_capture_sessions
       SET status=CASE
               WHEN status='ready' THEN 'in_progress'
               ELSE status
           END,
           started_at=COALESCE(started_at,now()),
           captured_at=NULL
     WHERE score_card_id=p_score_card_id;

    SELECT count(*)
      INTO v_remaining
      FROM public.tournament_best_ball_hole_scores hs
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
        'holeScoreId',v_hole.id,
        'scoreCardId',p_score_card_id,
        'bestBallScorecardMemberId',p_best_ball_scorecard_member_id,
        'playerId',v_hole.player_id,
        'holeNumber',v_hole.hole_number,
        'playSequence',v_hole.play_sequence,
        'resultType',p_result_type,
        'grossScore',
            CASE WHEN p_result_type='SCORE' THEN p_gross_score ELSE NULL END,
        'status','entered'
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_score_hoyo_best_ball_320(
    p_score_card_id uuid,
    p_best_ball_scorecard_member_id uuid,
    p_round_hole_snapshot_id uuid,
    p_gross_score integer
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
    SELECT public.registrar_resultado_hoyo_best_ball_320(
        p_score_card_id,
        p_best_ball_scorecard_member_id,
        p_round_hole_snapshot_id,
        'SCORE',
        p_gross_score
    );
$function$;

CREATE OR REPLACE FUNCTION public.registrar_pickup_hoyo_best_ball_320(
    p_score_card_id uuid,
    p_best_ball_scorecard_member_id uuid,
    p_round_hole_snapshot_id uuid
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
    SELECT public.registrar_resultado_hoyo_best_ball_320(
        p_score_card_id,
        p_best_ball_scorecard_member_id,
        p_round_hole_snapshot_id,
        'PICKUP',
        NULL
    );
$function$;

-- --------------------------------------------------------------------------
-- 5. CONFIRMACION BEST BALL
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.confirmar_resultado_hoyo_best_ball_320(
    p_hole_score_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_player_id uuid;
    v_hole record;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    v_player_id:=public._scorecard_current_player_id();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no está vinculado a un jugador activo.'
            USING ERRCODE='42501';
    END IF;

    SELECT hs.*
      INTO v_hole
      FROM public.tournament_best_ball_hole_scores hs
     WHERE hs.id=p_hole_score_id
     FOR UPDATE;

    IF v_hole.id IS NULL THEN
        RAISE EXCEPTION 'Resultado Best Ball no encontrado.'
            USING ERRCODE='22023';
    END IF;

    IF v_hole.status<>'entered'
       OR v_hole.result_type NOT IN ('SCORE','PICKUP')
    THEN
        RAISE EXCEPTION
            'Este resultado no está disponible para confirmación.'
            USING ERRCODE='55000';
    END IF;

    IF NOT public._puede_confirmar_disputar_best_ball_320(
        v_hole.id,
        v_player_id
    ) THEN
        RAISE EXCEPTION
            'No eres el jugador autorizado para confirmar este resultado Best Ball.'
            USING ERRCODE='42501';
    END IF;

    UPDATE public.tournament_best_ball_hole_scores
       SET status='confirmed',
           confirmed_by_player_id=v_player_id,
           confirmed_at=now()
     WHERE id=v_hole.id;

    INSERT INTO public.tournament_best_ball_scorecard_events(
        score_card_id,
        best_ball_hole_score_id,
        marker_assignment_id,
        event_type,
        actor_player_id,
        old_result_type,
        new_result_type,
        old_gross_score,
        new_gross_score
    )
    VALUES(
        v_hole.score_card_id,
        v_hole.id,
        v_hole.marker_assignment_id,
        'player_confirmed',
        v_player_id,
        v_hole.result_type,
        v_hole.result_type,
        v_hole.gross_score,
        v_hole.gross_score
    );

    RETURN jsonb_build_object(
        'holeScoreId',v_hole.id,
        'scoreCardId',v_hole.score_card_id,
        'playerId',v_hole.player_id,
        'holeNumber',v_hole.hole_number,
        'resultType',v_hole.result_type,
        'grossScore',v_hole.gross_score,
        'confirmedByPlayerId',v_player_id,
        'status','confirmed'
    );
END;
$function$;

-- --------------------------------------------------------------------------
-- 6. DISPUTA BEST BALL
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.disputar_resultado_hoyo_best_ball_320(
    p_hole_score_id uuid,
    p_claimed_result_type text,
    p_claimed_gross_score integer DEFAULT NULL,
    p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_player_id uuid;
    v_hole record;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    p_claimed_result_type:=
        upper(btrim(COALESCE(p_claimed_result_type,'')));

    IF p_claimed_result_type NOT IN ('SCORE','PICKUP') THEN
        RAISE EXCEPTION
            'claimed_result_type debe ser SCORE o PICKUP.'
            USING ERRCODE='22023';
    END IF;

    IF p_claimed_result_type='SCORE'
       AND (
           p_claimed_gross_score IS NULL
           OR p_claimed_gross_score<=0
       )
    THEN
        RAISE EXCEPTION
            'Una reclamación SCORE requiere gross mayor que cero.'
            USING ERRCODE='22023';
    END IF;

    IF p_claimed_result_type='PICKUP'
       AND p_claimed_gross_score IS NOT NULL
    THEN
        RAISE EXCEPTION
            'Una reclamación PICKUP no admite gross.'
            USING ERRCODE='22023';
    END IF;

    v_player_id:=public._scorecard_current_player_id();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no está vinculado a un jugador activo.'
            USING ERRCODE='42501';
    END IF;

    SELECT hs.*
      INTO v_hole
      FROM public.tournament_best_ball_hole_scores hs
     WHERE hs.id=p_hole_score_id
     FOR UPDATE;

    IF v_hole.id IS NULL THEN
        RAISE EXCEPTION 'Resultado Best Ball no encontrado.'
            USING ERRCODE='22023';
    END IF;

    IF v_hole.status<>'entered'
       OR v_hole.result_type NOT IN ('SCORE','PICKUP')
    THEN
        RAISE EXCEPTION
            'Este resultado no está disponible para disputa.'
            USING ERRCODE='55000';
    END IF;

    IF NOT public._puede_confirmar_disputar_best_ball_320(
        v_hole.id,
        v_player_id
    ) THEN
        RAISE EXCEPTION
            'No eres el jugador autorizado para disputar este resultado Best Ball.'
            USING ERRCODE='42501';
    END IF;

    IF p_claimed_result_type IS NOT DISTINCT FROM v_hole.result_type
       AND p_claimed_gross_score IS NOT DISTINCT FROM v_hole.gross_score
    THEN
        RAISE EXCEPTION
            'El resultado reclamado coincide con el capturado; puedes confirmarlo.'
            USING ERRCODE='22023';
    END IF;

    UPDATE public.tournament_best_ball_hole_scores
       SET status='disputed',
           player_claimed_result_type=p_claimed_result_type,
           player_claimed_gross_score=CASE
               WHEN p_claimed_result_type='SCORE'
                   THEN p_claimed_gross_score
               ELSE NULL
           END,
           dispute_note=NULLIF(
               btrim(COALESCE(p_reason,'')),
               ''
           ),
           disputed_at=now(),
           confirmed_by_player_id=NULL,
           confirmed_at=NULL
     WHERE id=v_hole.id;

    INSERT INTO public.tournament_best_ball_scorecard_events(
        score_card_id,
        best_ball_hole_score_id,
        marker_assignment_id,
        event_type,
        actor_player_id,
        old_result_type,
        new_result_type,
        old_gross_score,
        new_gross_score,
        claimed_result_type,
        claimed_gross_score,
        reason
    )
    VALUES(
        v_hole.score_card_id,
        v_hole.id,
        v_hole.marker_assignment_id,
        'player_disputed',
        v_player_id,
        v_hole.result_type,
        v_hole.result_type,
        v_hole.gross_score,
        v_hole.gross_score,
        p_claimed_result_type,
        CASE
            WHEN p_claimed_result_type='SCORE'
                THEN p_claimed_gross_score
            ELSE NULL
        END,
        NULLIF(btrim(COALESCE(p_reason,'')),'')
    );

    RETURN jsonb_build_object(
        'holeScoreId',v_hole.id,
        'scoreCardId',v_hole.score_card_id,
        'playerId',v_hole.player_id,
        'holeNumber',v_hole.hole_number,
        'resultType',v_hole.result_type,
        'grossScore',v_hole.gross_score,
        'playerClaimedResultType',p_claimed_result_type,
        'playerClaimedGrossScore',
            CASE
                WHEN p_claimed_result_type='SCORE'
                    THEN p_claimed_gross_score
                ELSE NULL
            END,
        'disputedByPlayerId',v_player_id,
        'status','disputed'
    );
END;
$function$;

COMMIT;
