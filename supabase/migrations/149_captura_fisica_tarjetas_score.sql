-- MIGRACIÓN 149 — RECEPCIÓN Y CAPTURA FÍSICA DE TARJETAS DE SCORE
BEGIN;

DO $$
BEGIN
    IF to_regclass('public.tournament_score_cards') IS NULL
       OR to_regclass('public.tournament_scorecard_hole_scores') IS NULL
       OR to_regclass('public.tournament_round_hole_snapshots') IS NULL
       OR to_regclass('public.tournament_scorecard_capture_sessions') IS NULL
    THEN
        RAISE EXCEPTION
            'Migración 149 requiere tarjetas oficiales, snapshots de hoyo y núcleo de captura digital.';
    END IF;

    IF to_regprocedure('public.puede_administrar_congelamiento_torneo(uuid)') IS NULL THEN
        RAISE EXCEPTION
            'Migración 149 requiere public.puede_administrar_congelamiento_torneo(uuid).';
    END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.tournament_scorecard_physical_receptions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    score_card_id uuid NOT NULL UNIQUE
        REFERENCES public.tournament_score_cards(id) ON DELETE RESTRICT,
    tournament_id uuid NOT NULL,
    tournament_round_id uuid NOT NULL,
    status text NOT NULL DEFAULT 'RECEIVED'
        CHECK (status IN ('RECEIVED', 'IN_CAPTURE', 'CAPTURED', 'VOIDED')),
    player_signature_present boolean NOT NULL DEFAULT false,
    marker_signature_present boolean NOT NULL DEFAULT false,
    notes text NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    received_by_auth_user_id uuid NOT NULL,
    capture_started_at timestamptz NULL,
    capture_started_by_auth_user_id uuid NULL,
    capture_completed_at timestamptz NULL,
    capture_completed_by_auth_user_id uuid NULL,
    voided_at timestamptz NULL,
    voided_by_auth_user_id uuid NULL,
    void_reason text NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_scorecard_physical_receptions_state_ck CHECK (
        (status = 'RECEIVED'
            AND capture_started_at IS NULL
            AND capture_completed_at IS NULL
            AND voided_at IS NULL
            AND void_reason IS NULL)
        OR
        (status = 'IN_CAPTURE'
            AND capture_started_at IS NOT NULL
            AND capture_completed_at IS NULL
            AND voided_at IS NULL
            AND void_reason IS NULL)
        OR
        (status = 'CAPTURED'
            AND capture_started_at IS NOT NULL
            AND capture_completed_at IS NOT NULL
            AND voided_at IS NULL
            AND void_reason IS NULL)
        OR
        (status = 'VOIDED'
            AND voided_at IS NOT NULL
            AND voided_by_auth_user_id IS NOT NULL
            AND nullif(btrim(void_reason), '') IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_scorecard_physical_receptions_round
    ON public.tournament_scorecard_physical_receptions(tournament_round_id, status);

CREATE TABLE IF NOT EXISTS public.tournament_scorecard_physical_hole_scores (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    physical_reception_id uuid NOT NULL
        REFERENCES public.tournament_scorecard_physical_receptions(id) ON DELETE RESTRICT,
    score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id) ON DELETE RESTRICT,
    tournament_round_id uuid NOT NULL,
    round_hole_snapshot_id uuid NOT NULL
        REFERENCES public.tournament_round_hole_snapshots(id) ON DELETE RESTRICT,
    hole_number integer NOT NULL CHECK (hole_number > 0),
    play_sequence integer NOT NULL CHECK (play_sequence > 0),
    physical_gross_score integer NOT NULL CHECK (physical_gross_score > 0),
    captured_at timestamptz NOT NULL DEFAULT now(),
    captured_by_auth_user_id uuid NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by_auth_user_id uuid NOT NULL,
    CONSTRAINT uq_scorecard_physical_hole UNIQUE (score_card_id, round_hole_snapshot_id),
    CONSTRAINT uq_scorecard_physical_play_sequence UNIQUE (score_card_id, play_sequence)
);

CREATE INDEX IF NOT EXISTS idx_scorecard_physical_holes_reception
    ON public.tournament_scorecard_physical_hole_scores(physical_reception_id, play_sequence);

CREATE TABLE IF NOT EXISTS public.tournament_scorecard_physical_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id) ON DELETE RESTRICT,
    physical_reception_id uuid NULL
        REFERENCES public.tournament_scorecard_physical_receptions(id) ON DELETE RESTRICT,
    physical_hole_score_id uuid NULL
        REFERENCES public.tournament_scorecard_physical_hole_scores(id) ON DELETE RESTRICT,
    event_type text NOT NULL CHECK (
        event_type IN (
            'physical_card_received',
            'physical_capture_started',
            'physical_score_entered',
            'physical_score_corrected',
            'physical_capture_completed',
            'physical_card_voided'
        )
    ),
    actor_auth_user_id uuid NOT NULL,
    old_physical_gross_score integer NULL,
    new_physical_gross_score integer NULL,
    reason text NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_scorecard_physical_events_values_ck CHECK (
        (event_type = 'physical_score_entered'
            AND old_physical_gross_score IS NULL
            AND new_physical_gross_score IS NOT NULL)
        OR
        (event_type = 'physical_score_corrected'
            AND old_physical_gross_score IS NOT NULL
            AND new_physical_gross_score IS NOT NULL)
        OR
        (event_type NOT IN ('physical_score_entered', 'physical_score_corrected')
            AND old_physical_gross_score IS NULL
            AND new_physical_gross_score IS NULL)
    )
);

CREATE OR REPLACE FUNCTION public._impedir_mutacion_evento_scorecard_fisico()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'Los eventos de captura física son inmutables.'
        USING ERRCODE = '55000';
END;
$$;

DROP TRIGGER IF EXISTS trg_impedir_mutacion_evento_scorecard_fisico
    ON public.tournament_scorecard_physical_events;

CREATE TRIGGER trg_impedir_mutacion_evento_scorecard_fisico
BEFORE UPDATE OR DELETE
ON public.tournament_scorecard_physical_events
FOR EACH ROW
EXECUTE FUNCTION public._impedir_mutacion_evento_scorecard_fisico();

ALTER TABLE public.tournament_scorecard_physical_receptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_scorecard_physical_hole_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_scorecard_physical_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_scorecard_physical_receptions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.tournament_scorecard_physical_hole_scores FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.tournament_scorecard_physical_events FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._obtener_score_card_para_captura_fisica(p_score_card_id uuid)
RETURNS public.tournament_score_cards
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_card public.tournament_score_cards;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;
    IF p_score_card_id IS NULL THEN
        RAISE EXCEPTION 'score_card_id es obligatorio.' USING ERRCODE = '22023';
    END IF;

    SELECT *
      INTO v_card
      FROM public.tournament_score_cards
     WHERE id = p_score_card_id
       AND status = 'issued'
     LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta oficial indicada no existe o no está emitida.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_card.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para capturar esta tarjeta física.'
            USING ERRCODE = '42501';
    END IF;

    RETURN v_card;
END;
$$;

REVOKE ALL ON FUNCTION public._obtener_score_card_para_captura_fisica(uuid)
    FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.recibir_tarjeta_fisica_score(
    p_score_card_id uuid,
    p_player_signature_present boolean,
    p_marker_signature_present boolean,
    p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_card public.tournament_score_cards;
    v_reception public.tournament_scorecard_physical_receptions;
BEGIN
    v_card := public._obtener_score_card_para_captura_fisica(p_score_card_id);

    SELECT * INTO v_reception
      FROM public.tournament_scorecard_physical_receptions
     WHERE score_card_id = v_card.id
     LIMIT 1;

    IF v_reception.id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'scoreCardId', v_card.id,
            'physicalReceptionId', v_reception.id,
            'status', v_reception.status,
            'alreadyReceived', true
        );
    END IF;

    INSERT INTO public.tournament_scorecard_physical_receptions (
        score_card_id, tournament_id, tournament_round_id,
        player_signature_present, marker_signature_present,
        notes, received_by_auth_user_id
    )
    VALUES (
        v_card.id, v_card.tournament_id, v_card.tournament_round_id,
        COALESCE(p_player_signature_present, false),
        COALESCE(p_marker_signature_present, false),
        nullif(btrim(p_notes), ''),
        auth.uid()
    )
    RETURNING * INTO v_reception;

    INSERT INTO public.tournament_scorecard_physical_events (
        score_card_id, physical_reception_id, event_type, actor_auth_user_id
    )
    VALUES (
        v_card.id, v_reception.id, 'physical_card_received', auth.uid()
    );

    RETURN jsonb_build_object(
        'scoreCardId', v_card.id,
        'physicalReceptionId', v_reception.id,
        'status', v_reception.status,
        'alreadyReceived', false
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.guardar_score_fisico_hoyo(
    p_score_card_id uuid,
    p_round_hole_snapshot_id uuid,
    p_physical_gross_score integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_card public.tournament_score_cards;
    v_reception public.tournament_scorecard_physical_receptions;
    v_hole record;
    v_existing public.tournament_scorecard_physical_hole_scores;
    v_saved public.tournament_scorecard_physical_hole_scores;
BEGIN
    v_card := public._obtener_score_card_para_captura_fisica(p_score_card_id);

    IF p_physical_gross_score IS NULL OR p_physical_gross_score <= 0 THEN
        RAISE EXCEPTION 'El score físico debe ser un entero mayor a cero.'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_reception
      FROM public.tournament_scorecard_physical_receptions
     WHERE score_card_id = v_card.id
     FOR UPDATE;

    IF v_reception.id IS NULL THEN
        RAISE EXCEPTION 'Primero debe registrarse la recepción de la tarjeta física.'
            USING ERRCODE = '55000';
    END IF;

    IF v_reception.status IN ('CAPTURED', 'VOIDED') THEN
        RAISE EXCEPTION 'La captura física ya no admite edición directa.'
            USING ERRCODE = '55000';
    END IF;

    SELECT rhs.id, rhs.hole_number,
           COALESCE(hs.play_sequence, rhs.hole_number) AS play_sequence
      INTO v_hole
      FROM public.tournament_round_hole_snapshots rhs
      LEFT JOIN public.tournament_scorecard_hole_scores hs
        ON hs.score_card_id = v_card.id
       AND hs.round_hole_snapshot_id = rhs.id
     WHERE rhs.id = p_round_hole_snapshot_id
       AND rhs.tournament_round_id = v_card.tournament_round_id
     LIMIT 1;

    IF v_hole.id IS NULL THEN
        RAISE EXCEPTION 'El hoyo indicado no pertenece a la ronda de esta tarjeta.'
            USING ERRCODE = '22023';
    END IF;

    IF v_reception.status = 'RECEIVED' THEN
        UPDATE public.tournament_scorecard_physical_receptions
           SET status = 'IN_CAPTURE',
               capture_started_at = now(),
               capture_started_by_auth_user_id = auth.uid(),
               updated_at = now()
         WHERE id = v_reception.id
         RETURNING * INTO v_reception;

        INSERT INTO public.tournament_scorecard_physical_events (
            score_card_id, physical_reception_id, event_type, actor_auth_user_id
        )
        VALUES (
            v_card.id, v_reception.id, 'physical_capture_started', auth.uid()
        );
    END IF;

    SELECT * INTO v_existing
      FROM public.tournament_scorecard_physical_hole_scores
     WHERE score_card_id = v_card.id
       AND round_hole_snapshot_id = p_round_hole_snapshot_id
     FOR UPDATE;

    IF v_existing.id IS NULL THEN
        INSERT INTO public.tournament_scorecard_physical_hole_scores (
            physical_reception_id, score_card_id, tournament_round_id,
            round_hole_snapshot_id, hole_number, play_sequence,
            physical_gross_score, captured_by_auth_user_id, updated_by_auth_user_id
        )
        VALUES (
            v_reception.id, v_card.id, v_card.tournament_round_id,
            p_round_hole_snapshot_id, v_hole.hole_number, v_hole.play_sequence,
            p_physical_gross_score, auth.uid(), auth.uid()
        )
        RETURNING * INTO v_saved;

        INSERT INTO public.tournament_scorecard_physical_events (
            score_card_id, physical_reception_id, physical_hole_score_id,
            event_type, actor_auth_user_id, new_physical_gross_score
        )
        VALUES (
            v_card.id, v_reception.id, v_saved.id,
            'physical_score_entered', auth.uid(), p_physical_gross_score
        );
    ELSE
        IF v_existing.physical_gross_score = p_physical_gross_score THEN
            RETURN jsonb_build_object(
                'scoreCardId', v_card.id,
                'physicalReceptionId', v_reception.id,
                'physicalHoleScoreId', v_existing.id,
                'physicalGrossScore', v_existing.physical_gross_score,
                'changed', false
            );
        END IF;

        UPDATE public.tournament_scorecard_physical_hole_scores
           SET physical_gross_score = p_physical_gross_score,
               updated_at = now(),
               updated_by_auth_user_id = auth.uid()
         WHERE id = v_existing.id
         RETURNING * INTO v_saved;

        INSERT INTO public.tournament_scorecard_physical_events (
            score_card_id, physical_reception_id, physical_hole_score_id,
            event_type, actor_auth_user_id,
            old_physical_gross_score, new_physical_gross_score
        )
        VALUES (
            v_card.id, v_reception.id, v_saved.id,
            'physical_score_corrected', auth.uid(),
            v_existing.physical_gross_score, p_physical_gross_score
        );
    END IF;

    RETURN jsonb_build_object(
        'scoreCardId', v_card.id,
        'physicalReceptionId', v_reception.id,
        'physicalHoleScoreId', v_saved.id,
        'holeNumber', v_saved.hole_number,
        'playSequence', v_saved.play_sequence,
        'physicalGrossScore', v_saved.physical_gross_score,
        'status', v_reception.status,
        'changed', true
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.finalizar_captura_fisica_tarjeta(p_score_card_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_card public.tournament_score_cards;
    v_reception public.tournament_scorecard_physical_receptions;
    v_expected integer;
    v_captured integer;
BEGIN
    v_card := public._obtener_score_card_para_captura_fisica(p_score_card_id);

    SELECT * INTO v_reception
      FROM public.tournament_scorecard_physical_receptions
     WHERE score_card_id = v_card.id
     FOR UPDATE;

    IF v_reception.id IS NULL THEN
        RAISE EXCEPTION 'Primero debe registrarse la recepción de la tarjeta física.'
            USING ERRCODE = '55000';
    END IF;

    IF v_reception.status = 'VOIDED' THEN
        RAISE EXCEPTION 'La recepción física está anulada.'
            USING ERRCODE = '55000';
    END IF;

    IF v_reception.status = 'CAPTURED' THEN
        RETURN jsonb_build_object(
            'scoreCardId', v_card.id,
            'physicalReceptionId', v_reception.id,
            'status', 'CAPTURED',
            'alreadyCompleted', true
        );
    END IF;

    SELECT cs.holes_expected INTO v_expected
      FROM public.tournament_scorecard_capture_sessions cs
     WHERE cs.score_card_id = v_card.id
     LIMIT 1;

    IF v_expected IS NULL THEN
        SELECT count(*) INTO v_expected
          FROM public.tournament_round_hole_snapshots rhs
         WHERE rhs.tournament_round_id = v_card.tournament_round_id;
    END IF;

    SELECT count(*) INTO v_captured
      FROM public.tournament_scorecard_physical_hole_scores
     WHERE score_card_id = v_card.id;

    IF v_captured <> v_expected THEN
        RAISE EXCEPTION
            'No se puede finalizar: hay % hoyos físicos capturados de % esperados.',
            v_captured, v_expected
            USING ERRCODE = '55000';
    END IF;

    UPDATE public.tournament_scorecard_physical_receptions
       SET status = 'CAPTURED',
           capture_started_at = COALESCE(capture_started_at, now()),
           capture_started_by_auth_user_id = COALESCE(capture_started_by_auth_user_id, auth.uid()),
           capture_completed_at = now(),
           capture_completed_by_auth_user_id = auth.uid(),
           updated_at = now()
     WHERE id = v_reception.id
     RETURNING * INTO v_reception;

    INSERT INTO public.tournament_scorecard_physical_events (
        score_card_id, physical_reception_id, event_type, actor_auth_user_id
    )
    VALUES (
        v_card.id, v_reception.id, 'physical_capture_completed', auth.uid()
    );

    RETURN jsonb_build_object(
        'scoreCardId', v_card.id,
        'physicalReceptionId', v_reception.id,
        'status', v_reception.status,
        'alreadyCompleted', false,
        'capturedHoles', v_captured,
        'expectedHoles', v_expected,
        'completedAt', v_reception.capture_completed_at
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.obtener_captura_fisica_tarjeta(p_score_card_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_card public.tournament_score_cards;
    v_reception public.tournament_scorecard_physical_receptions;
BEGIN
    v_card := public._obtener_score_card_para_captura_fisica(p_score_card_id);

    SELECT * INTO v_reception
      FROM public.tournament_scorecard_physical_receptions
     WHERE score_card_id = v_card.id
     LIMIT 1;

    RETURN jsonb_build_object(
        'scoreCardId', v_card.id,
        'cardFolio', v_card.card_folio,
        'tournamentId', v_card.tournament_id,
        'tournamentRoundId', v_card.tournament_round_id,
        'received', (v_reception.id IS NOT NULL),
        'reception',
            CASE WHEN v_reception.id IS NULL THEN NULL ELSE jsonb_build_object(
                'id', v_reception.id,
                'status', v_reception.status,
                'playerSignaturePresent', v_reception.player_signature_present,
                'markerSignaturePresent', v_reception.marker_signature_present,
                'notes', v_reception.notes,
                'receivedAt', v_reception.received_at,
                'captureStartedAt', v_reception.capture_started_at,
                'captureCompletedAt', v_reception.capture_completed_at
            ) END,
        'physicalHoles',
            COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', phs.id,
                        'roundHoleSnapshotId', phs.round_hole_snapshot_id,
                        'holeNumber', phs.hole_number,
                        'playSequence', phs.play_sequence,
                        'physicalGrossScore', phs.physical_gross_score,
                        'capturedAt', phs.captured_at,
                        'updatedAt', phs.updated_at
                    )
                    ORDER BY phs.play_sequence
                )
                FROM public.tournament_scorecard_physical_hole_scores phs
                WHERE phs.score_card_id = v_card.id
            ), '[]'::jsonb)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.recibir_tarjeta_fisica_score(uuid, boolean, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recibir_tarjeta_fisica_score(uuid, boolean, boolean, text) TO authenticated;

REVOKE ALL ON FUNCTION public.guardar_score_fisico_hoyo(uuid, uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.guardar_score_fisico_hoyo(uuid, uuid, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.finalizar_captura_fisica_tarjeta(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalizar_captura_fisica_tarjeta(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.obtener_captura_fisica_tarjeta(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_captura_fisica_tarjeta(uuid) TO authenticated;

COMMIT;
