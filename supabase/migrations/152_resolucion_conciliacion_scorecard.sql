-- ============================================================================
-- 152_resolucion_conciliacion_scorecard.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 152 — RESOLUCIÓN DE CONCILIACIÓN
-- ============================================================================

BEGIN;

DO $$
BEGIN
    IF to_regclass('public.tournament_score_cards') IS NULL
       OR to_regclass('public.tournament_scorecard_hole_scores') IS NULL
       OR to_regclass('public.tournament_scorecard_events') IS NULL
       OR to_regclass('public.tournament_scorecard_physical_receptions') IS NULL
       OR to_regclass('public.tournament_scorecard_physical_hole_scores') IS NULL
       OR to_regclass('public.tournament_round_hole_snapshots') IS NULL
    THEN
        RAISE EXCEPTION 'Migración 152 requiere núcleo digital, captura física y Migración 149.';
    END IF;

    IF to_regprocedure('public.obtener_conciliacion_tarjeta_score(uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migración 152 requiere obtener_conciliacion_tarjeta_score(uuid).';
    END IF;

    IF to_regprocedure('public.puede_administrar_congelamiento_torneo(uuid)') IS NULL
       OR to_regprocedure('public._scorecard_current_admin_id()') IS NULL
    THEN
        RAISE EXCEPTION 'Migración 152 requiere helpers administrativos existentes.';
    END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.tournament_scorecard_reconciliations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    score_card_id uuid NOT NULL UNIQUE
        REFERENCES public.tournament_score_cards(id) ON DELETE RESTRICT,
    tournament_id uuid NOT NULL,
    tournament_round_id uuid NOT NULL,
    status text NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','IN_REVIEW','COMPLETED','VOIDED')),
    started_at timestamptz NULL,
    started_by_admin_user_id uuid NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    completed_at timestamptz NULL,
    completed_by_admin_user_id uuid NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    voided_at timestamptz NULL,
    voided_by_admin_user_id uuid NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    void_reason text NULL,
    notes text NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_scorecard_reconciliations_state_ck CHECK (
        (status='PENDING' AND completed_at IS NULL AND voided_at IS NULL)
        OR
        (status='IN_REVIEW' AND started_at IS NOT NULL
         AND started_by_admin_user_id IS NOT NULL
         AND completed_at IS NULL AND voided_at IS NULL)
        OR
        (status='COMPLETED' AND started_at IS NOT NULL
         AND started_by_admin_user_id IS NOT NULL
         AND completed_at IS NOT NULL
         AND completed_by_admin_user_id IS NOT NULL
         AND voided_at IS NULL)
        OR
        (status='VOIDED' AND voided_at IS NOT NULL
         AND voided_by_admin_user_id IS NOT NULL
         AND nullif(btrim(void_reason),'') IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_scorecard_reconciliations_round_status
ON public.tournament_scorecard_reconciliations(tournament_round_id,status);

CREATE TABLE IF NOT EXISTS public.tournament_scorecard_hole_resolutions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reconciliation_id uuid NOT NULL
        REFERENCES public.tournament_scorecard_reconciliations(id) ON DELETE RESTRICT,
    score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id) ON DELETE RESTRICT,
    tournament_round_id uuid NOT NULL,
    round_hole_snapshot_id uuid NOT NULL
        REFERENCES public.tournament_round_hole_snapshots(id) ON DELETE RESTRICT,
    hole_number integer NOT NULL CHECK (hole_number > 0),
    play_sequence integer NOT NULL CHECK (play_sequence > 0),
    digital_gross_snapshot integer NULL CHECK (digital_gross_snapshot IS NULL OR digital_gross_snapshot > 0),
    player_claim_gross_snapshot integer NULL CHECK (player_claim_gross_snapshot IS NULL OR player_claim_gross_snapshot > 0),
    physical_gross_snapshot integer NULL CHECK (physical_gross_snapshot IS NULL OR physical_gross_snapshot > 0),
    resolution_source text NOT NULL CHECK (
        resolution_source IN ('DIGITAL','PHYSICAL','PLAYER_CLAIM','MANUAL')
    ),
    resolved_gross_score integer NOT NULL CHECK (resolved_gross_score > 0),
    reason text NULL,
    resolved_by_admin_user_id uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    resolved_at timestamptz NOT NULL DEFAULT now(),
    updated_by_admin_user_id uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_scorecard_hole_resolution UNIQUE(score_card_id,round_hole_snapshot_id),
    CONSTRAINT tournament_scorecard_hole_resolutions_manual_reason_ck CHECK (
        resolution_source <> 'MANUAL'
        OR nullif(btrim(reason),'') IS NOT NULL
    )
);

CREATE INDEX IF NOT EXISTS idx_scorecard_hole_resolutions_reconciliation
ON public.tournament_scorecard_hole_resolutions(reconciliation_id,play_sequence);

CREATE TABLE IF NOT EXISTS public.tournament_scorecard_reconciliation_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reconciliation_id uuid NOT NULL
        REFERENCES public.tournament_scorecard_reconciliations(id) ON DELETE RESTRICT,
    score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id) ON DELETE RESTRICT,
    hole_resolution_id uuid NULL
        REFERENCES public.tournament_scorecard_hole_resolutions(id) ON DELETE RESTRICT,
    event_type text NOT NULL CHECK (
        event_type IN (
            'reconciliation_started',
            'hole_resolved',
            'hole_resolution_changed',
            'reconciliation_completed',
            'reconciliation_voided'
        )
    ),
    actor_admin_user_id uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    old_resolved_gross_score integer NULL,
    new_resolved_gross_score integer NULL,
    old_resolution_source text NULL,
    new_resolution_source text NULL,
    reason text NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public._impedir_mutacion_evento_conciliacion_score()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'Los eventos de conciliación son inmutables.'
        USING ERRCODE='55000';
END;
$$;

DROP TRIGGER IF EXISTS trg_impedir_mutacion_evento_conciliacion_score
ON public.tournament_scorecard_reconciliation_events;

CREATE TRIGGER trg_impedir_mutacion_evento_conciliacion_score
BEFORE UPDATE OR DELETE ON public.tournament_scorecard_reconciliation_events
FOR EACH ROW
EXECUTE FUNCTION public._impedir_mutacion_evento_conciliacion_score();

ALTER TABLE public.tournament_scorecard_reconciliations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_scorecard_hole_resolutions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_scorecard_reconciliation_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_scorecard_reconciliations FROM PUBLIC,anon,authenticated;
REVOKE ALL ON TABLE public.tournament_scorecard_hole_resolutions FROM PUBLIC,anon,authenticated;
REVOKE ALL ON TABLE public.tournament_scorecard_reconciliation_events FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.iniciar_conciliacion_tarjeta_score(p_score_card_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_card record;
    v_reception record;
    v_admin_id uuid;
    v_rec public.tournament_scorecard_reconciliations;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT sc.id,sc.tournament_id,sc.tournament_round_id
    INTO v_card
    FROM public.tournament_score_cards sc
    WHERE sc.id=p_score_card_id AND sc.status='issued'
    LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta oficial indicada no existe o no está emitida.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_card.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para conciliar esta tarjeta.'
            USING ERRCODE='42501';
    END IF;

    v_admin_id := public._scorecard_current_admin_id();
    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE='42501';
    END IF;

    SELECT * INTO v_reception
    FROM public.tournament_scorecard_physical_receptions
    WHERE score_card_id=v_card.id
    LIMIT 1;

    IF v_reception.id IS NULL OR v_reception.status <> 'CAPTURED' THEN
        RAISE EXCEPTION 'La conciliación sólo puede iniciar después de finalizar la captura física.'
            USING ERRCODE='55000';
    END IF;

    SELECT * INTO v_rec
    FROM public.tournament_scorecard_reconciliations
    WHERE score_card_id=v_card.id
    FOR UPDATE;

    IF v_rec.id IS NOT NULL THEN
        IF v_rec.status='VOIDED' THEN
            RAISE EXCEPTION 'La conciliación de esta tarjeta está anulada.'
                USING ERRCODE='55000';
        END IF;

        IF v_rec.status='PENDING' THEN
            UPDATE public.tournament_scorecard_reconciliations
            SET status='IN_REVIEW',
                started_at=now(),
                started_by_admin_user_id=v_admin_id,
                updated_at=now()
            WHERE id=v_rec.id
            RETURNING * INTO v_rec;

            INSERT INTO public.tournament_scorecard_reconciliation_events(
                reconciliation_id,score_card_id,event_type,actor_admin_user_id
            ) VALUES (
                v_rec.id,v_card.id,'reconciliation_started',v_admin_id
            );
        END IF;

        RETURN jsonb_build_object(
            'reconciliationId',v_rec.id,
            'scoreCardId',v_card.id,
            'status',v_rec.status,
            'alreadyExisted',true
        );
    END IF;

    INSERT INTO public.tournament_scorecard_reconciliations(
        score_card_id,tournament_id,tournament_round_id,status,
        started_at,started_by_admin_user_id
    ) VALUES (
        v_card.id,v_card.tournament_id,v_card.tournament_round_id,
        'IN_REVIEW',now(),v_admin_id
    )
    RETURNING * INTO v_rec;

    INSERT INTO public.tournament_scorecard_reconciliation_events(
        reconciliation_id,score_card_id,event_type,actor_admin_user_id
    ) VALUES (
        v_rec.id,v_card.id,'reconciliation_started',v_admin_id
    );

    RETURN jsonb_build_object(
        'reconciliationId',v_rec.id,
        'scoreCardId',v_card.id,
        'status',v_rec.status,
        'alreadyExisted',false
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.resolver_hoyo_conciliacion_score(
    p_score_card_id uuid,
    p_round_hole_snapshot_id uuid,
    p_resolution_source text,
    p_manual_gross_score integer DEFAULT NULL,
    p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_card record;
    v_rec public.tournament_scorecard_reconciliations;
    v_hole record;
    v_admin_id uuid;
    v_last_claim integer;
    v_last_dispute_at timestamptz;
    v_last_confirmed_at timestamptz;
    v_comparison_status text;
    v_dispute_status text;
    v_needs_review boolean;
    v_resolved integer;
    v_existing public.tournament_scorecard_hole_resolutions;
    v_saved public.tournament_scorecard_hole_resolutions;
    v_event_type text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_resolution_source NOT IN ('DIGITAL','PHYSICAL','PLAYER_CLAIM','MANUAL') THEN
        RAISE EXCEPTION 'resolution_source inválido.' USING ERRCODE='22023';
    END IF;

    SELECT sc.id,sc.tournament_id,sc.tournament_round_id
    INTO v_card
    FROM public.tournament_score_cards sc
    WHERE sc.id=p_score_card_id AND sc.status='issued'
    LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta oficial indicada no existe o no está emitida.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_card.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para resolver esta conciliación.'
            USING ERRCODE='42501';
    END IF;

    v_admin_id := public._scorecard_current_admin_id();
    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE='42501';
    END IF;

    SELECT * INTO v_rec
    FROM public.tournament_scorecard_reconciliations
    WHERE score_card_id=v_card.id
    FOR UPDATE;

    IF v_rec.id IS NULL THEN
        RAISE EXCEPTION 'Primero debe iniciarse la conciliación de esta tarjeta.'
            USING ERRCODE='55000';
    END IF;

    IF v_rec.status <> 'IN_REVIEW' THEN
        RAISE EXCEPTION 'La conciliación no admite resolución de hoyos en su estado actual.'
            USING ERRCODE='55000',
                  DETAIL=format('reconciliation_status=%s',v_rec.status);
    END IF;

    SELECT
        hs.id AS hole_score_id,
        hs.round_hole_snapshot_id,
        hs.hole_number,
        hs.play_sequence,
        hs.gross_score AS digital_gross_score,
        hs.status AS digital_status,
        hs.player_claimed_gross_score AS active_claimed_gross_score,
        phs.physical_gross_score
    INTO v_hole
    FROM public.tournament_scorecard_hole_scores hs
    LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
      ON phs.score_card_id=hs.score_card_id
     AND phs.round_hole_snapshot_id=hs.round_hole_snapshot_id
    WHERE hs.score_card_id=v_card.id
      AND hs.round_hole_snapshot_id=p_round_hole_snapshot_id
    LIMIT 1;

    IF v_hole.hole_score_id IS NULL THEN
        RAISE EXCEPTION 'El hoyo indicado no pertenece a esta tarjeta.'
            USING ERRCODE='22023';
    END IF;

    SELECT e.claimed_gross_score,e.created_at
    INTO v_last_claim,v_last_dispute_at
    FROM public.tournament_scorecard_events e
    WHERE e.hole_score_id=v_hole.hole_score_id
      AND e.event_type='player_disputed'
    ORDER BY e.created_at DESC,e.id DESC
    LIMIT 1;

    SELECT e.created_at
    INTO v_last_confirmed_at
    FROM public.tournament_scorecard_events e
    WHERE e.hole_score_id=v_hole.hole_score_id
      AND e.event_type='player_confirmed'
    ORDER BY e.created_at DESC,e.id DESC
    LIMIT 1;

    v_comparison_status := CASE
        WHEN v_hole.physical_gross_score IS NULL THEN 'PENDIENTE_CAPTURA_FISICA'
        WHEN v_hole.digital_gross_score IS NULL THEN 'SIN_CAPTURA_DIGITAL'
        WHEN v_hole.digital_gross_score=v_hole.physical_gross_score THEN 'COINCIDE'
        ELSE 'DIFERENCIA'
    END;

    v_dispute_status := CASE
        WHEN v_last_dispute_at IS NULL THEN 'NONE'
        WHEN v_hole.digital_status='disputed' THEN 'ACTIVE'
        WHEN v_last_confirmed_at IS NULL OR v_last_confirmed_at < v_last_dispute_at
            THEN 'HISTORICAL_PENDING'
        ELSE 'HISTORICAL_RESOLVED'
    END;

    v_needs_review := (
        v_comparison_status='DIFERENCIA'
        OR v_dispute_status IN ('ACTIVE','HISTORICAL_PENDING')
        OR v_comparison_status='PENDIENTE_CAPTURA_FISICA'
    );

    IF NOT v_needs_review THEN
        RAISE EXCEPTION 'Este hoyo no requiere una resolución explícita.'
            USING ERRCODE='22023',
                  DETAIL=format(
                      'comparison_status=%s; dispute_status=%s',
                      v_comparison_status,v_dispute_status
                  );
    END IF;

    IF v_hole.physical_gross_score IS NULL THEN
        RAISE EXCEPTION 'No puede resolverse un hoyo sin captura física finalizada.'
            USING ERRCODE='55000';
    END IF;

    v_resolved := CASE p_resolution_source
        WHEN 'DIGITAL' THEN v_hole.digital_gross_score
        WHEN 'PHYSICAL' THEN v_hole.physical_gross_score
        WHEN 'PLAYER_CLAIM' THEN COALESCE(v_hole.active_claimed_gross_score,v_last_claim)
        WHEN 'MANUAL' THEN p_manual_gross_score
    END;

    IF v_resolved IS NULL OR v_resolved <= 0 THEN
        RAISE EXCEPTION 'La fuente seleccionada no tiene un valor válido para este hoyo.'
            USING ERRCODE='22023';
    END IF;

    IF p_resolution_source='MANUAL'
       AND length(btrim(COALESCE(p_reason,''))) < 5 THEN
        RAISE EXCEPTION 'MANUAL requiere un motivo de al menos 5 caracteres.'
            USING ERRCODE='22023';
    END IF;

    SELECT * INTO v_existing
    FROM public.tournament_scorecard_hole_resolutions
    WHERE score_card_id=v_card.id
      AND round_hole_snapshot_id=p_round_hole_snapshot_id
    FOR UPDATE;

    IF v_existing.id IS NULL THEN
        INSERT INTO public.tournament_scorecard_hole_resolutions(
            reconciliation_id,score_card_id,tournament_round_id,
            round_hole_snapshot_id,hole_number,play_sequence,
            digital_gross_snapshot,player_claim_gross_snapshot,physical_gross_snapshot,
            resolution_source,resolved_gross_score,reason,
            resolved_by_admin_user_id,updated_by_admin_user_id
        ) VALUES (
            v_rec.id,v_card.id,v_card.tournament_round_id,
            p_round_hole_snapshot_id,v_hole.hole_number,v_hole.play_sequence,
            v_hole.digital_gross_score,
            COALESCE(v_hole.active_claimed_gross_score,v_last_claim),
            v_hole.physical_gross_score,
            p_resolution_source,v_resolved,
            nullif(btrim(COALESCE(p_reason,'')),''),
            v_admin_id,v_admin_id
        )
        RETURNING * INTO v_saved;

        v_event_type := 'hole_resolved';
    ELSE
        UPDATE public.tournament_scorecard_hole_resolutions
        SET digital_gross_snapshot=v_hole.digital_gross_score,
            player_claim_gross_snapshot=COALESCE(v_hole.active_claimed_gross_score,v_last_claim),
            physical_gross_snapshot=v_hole.physical_gross_score,
            resolution_source=p_resolution_source,
            resolved_gross_score=v_resolved,
            reason=nullif(btrim(COALESCE(p_reason,'')),''),
            updated_by_admin_user_id=v_admin_id,
            updated_at=now()
        WHERE id=v_existing.id
        RETURNING * INTO v_saved;

        v_event_type := 'hole_resolution_changed';
    END IF;

    INSERT INTO public.tournament_scorecard_reconciliation_events(
        reconciliation_id,score_card_id,hole_resolution_id,event_type,
        actor_admin_user_id,
        old_resolved_gross_score,new_resolved_gross_score,
        old_resolution_source,new_resolution_source,reason
    ) VALUES (
        v_rec.id,v_card.id,v_saved.id,v_event_type,v_admin_id,
        CASE WHEN v_existing.id IS NULL THEN NULL ELSE v_existing.resolved_gross_score END,
        v_saved.resolved_gross_score,
        CASE WHEN v_existing.id IS NULL THEN NULL ELSE v_existing.resolution_source END,
        v_saved.resolution_source,
        v_saved.reason
    );

    RETURN jsonb_build_object(
        'reconciliationId',v_rec.id,
        'holeResolutionId',v_saved.id,
        'scoreCardId',v_card.id,
        'roundHoleSnapshotId',v_saved.round_hole_snapshot_id,
        'holeNumber',v_saved.hole_number,
        'resolutionSource',v_saved.resolution_source,
        'resolvedGrossScore',v_saved.resolved_gross_score,
        'reason',v_saved.reason,
        'comparisonStatus',v_comparison_status,
        'disputeStatus',v_dispute_status
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.obtener_resoluciones_conciliacion_tarjeta_score(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_card record;
    v_rec public.tournament_scorecard_reconciliations;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT sc.id,sc.tournament_id,sc.tournament_round_id
    INTO v_card
    FROM public.tournament_score_cards sc
    WHERE sc.id=p_score_card_id AND sc.status='issued'
    LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta oficial indicada no existe o no está emitida.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_card.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para consultar estas resoluciones.'
            USING ERRCODE='42501';
    END IF;

    SELECT * INTO v_rec
    FROM public.tournament_scorecard_reconciliations
    WHERE score_card_id=v_card.id
    LIMIT 1;

    RETURN jsonb_build_object(
        'scoreCardId',v_card.id,
        'reconciliation',
        CASE WHEN v_rec.id IS NULL THEN NULL ELSE jsonb_build_object(
            'id',v_rec.id,
            'status',v_rec.status,
            'startedAt',v_rec.started_at,
            'completedAt',v_rec.completed_at,
            'notes',v_rec.notes
        ) END,
        'resolutions',
        COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'id',r.id,
                    'roundHoleSnapshotId',r.round_hole_snapshot_id,
                    'holeNumber',r.hole_number,
                    'playSequence',r.play_sequence,
                    'digitalGrossSnapshot',r.digital_gross_snapshot,
                    'playerClaimGrossSnapshot',r.player_claim_gross_snapshot,
                    'physicalGrossSnapshot',r.physical_gross_snapshot,
                    'resolutionSource',r.resolution_source,
                    'resolvedGrossScore',r.resolved_gross_score,
                    'reason',r.reason,
                    'resolvedAt',r.resolved_at,
                    'updatedAt',r.updated_at
                )
                ORDER BY r.play_sequence
            )
            FROM public.tournament_scorecard_hole_resolutions r
            WHERE r.score_card_id=v_card.id
        ),'[]'::jsonb)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.finalizar_conciliacion_tarjeta_score(
    p_score_card_id uuid,
    p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_card record;
    v_rec public.tournament_scorecard_reconciliations;
    v_admin_id uuid;
    v_review_total integer := 0;
    v_unresolved integer := 0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT sc.id,sc.tournament_id,sc.tournament_round_id
    INTO v_card
    FROM public.tournament_score_cards sc
    WHERE sc.id=p_score_card_id AND sc.status='issued'
    LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta oficial indicada no existe o no está emitida.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_card.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para finalizar esta conciliación.'
            USING ERRCODE='42501';
    END IF;

    v_admin_id := public._scorecard_current_admin_id();

    SELECT * INTO v_rec
    FROM public.tournament_scorecard_reconciliations
    WHERE score_card_id=v_card.id
    FOR UPDATE;

    IF v_rec.id IS NULL THEN
        RAISE EXCEPTION 'Primero debe iniciarse la conciliación de esta tarjeta.'
            USING ERRCODE='55000';
    END IF;

    IF v_rec.status='COMPLETED' THEN
        RETURN jsonb_build_object(
            'reconciliationId',v_rec.id,
            'scoreCardId',v_card.id,
            'status','COMPLETED',
            'alreadyCompleted',true
        );
    END IF;

    IF v_rec.status <> 'IN_REVIEW' THEN
        RAISE EXCEPTION 'La conciliación no puede finalizar en su estado actual.'
            USING ERRCODE='55000';
    END IF;

    WITH evidence AS (
        SELECT
            hs.id AS hole_score_id,
            hs.round_hole_snapshot_id,
            hs.gross_score AS digital_gross_score,
            hs.status AS digital_status,
            phs.physical_gross_score,
            ld.created_at AS last_disputed_at,
            lc.created_at AS last_confirmed_at,
            CASE
                WHEN phs.physical_gross_score IS NULL THEN 'PENDIENTE_CAPTURA_FISICA'
                WHEN hs.gross_score IS NULL THEN 'SIN_CAPTURA_DIGITAL'
                WHEN hs.gross_score=phs.physical_gross_score THEN 'COINCIDE'
                ELSE 'DIFERENCIA'
            END AS comparison_status,
            CASE
                WHEN ld.created_at IS NULL THEN 'NONE'
                WHEN hs.status='disputed' THEN 'ACTIVE'
                WHEN lc.created_at IS NULL OR lc.created_at < ld.created_at
                    THEN 'HISTORICAL_PENDING'
                ELSE 'HISTORICAL_RESOLVED'
            END AS dispute_status
        FROM public.tournament_scorecard_hole_scores hs
        LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
          ON phs.score_card_id=hs.score_card_id
         AND phs.round_hole_snapshot_id=hs.round_hole_snapshot_id
        LEFT JOIN LATERAL (
            SELECT e.created_at
            FROM public.tournament_scorecard_events e
            WHERE e.hole_score_id=hs.id AND e.event_type='player_disputed'
            ORDER BY e.created_at DESC,e.id DESC
            LIMIT 1
        ) ld ON true
        LEFT JOIN LATERAL (
            SELECT e.created_at
            FROM public.tournament_scorecard_events e
            WHERE e.hole_score_id=hs.id AND e.event_type='player_confirmed'
            ORDER BY e.created_at DESC,e.id DESC
            LIMIT 1
        ) lc ON true
        WHERE hs.score_card_id=v_card.id
    ),
    review_holes AS (
        SELECT round_hole_snapshot_id
        FROM evidence
        WHERE comparison_status='DIFERENCIA'
           OR dispute_status IN ('ACTIVE','HISTORICAL_PENDING')
           OR comparison_status='PENDIENTE_CAPTURA_FISICA'
    )
    SELECT
        count(*),
        count(*) FILTER (WHERE r.id IS NULL)
    INTO v_review_total,v_unresolved
    FROM review_holes rh
    LEFT JOIN public.tournament_scorecard_hole_resolutions r
      ON r.score_card_id=v_card.id
     AND r.round_hole_snapshot_id=rh.round_hole_snapshot_id;

    IF v_unresolved > 0 THEN
        RAISE EXCEPTION
            'No se puede finalizar la conciliación: quedan % hoyo(s) por resolver.',
            v_unresolved
            USING ERRCODE='55000',
                  DETAIL=format('review_total=%s; unresolved=%s',v_review_total,v_unresolved);
    END IF;

    UPDATE public.tournament_scorecard_reconciliations
    SET status='COMPLETED',
        completed_at=now(),
        completed_by_admin_user_id=v_admin_id,
        notes=COALESCE(nullif(btrim(COALESCE(p_notes,'')),''),notes),
        updated_at=now()
    WHERE id=v_rec.id
    RETURNING * INTO v_rec;

    INSERT INTO public.tournament_scorecard_reconciliation_events(
        reconciliation_id,score_card_id,event_type,actor_admin_user_id,reason
    ) VALUES (
        v_rec.id,v_card.id,'reconciliation_completed',v_admin_id,
        nullif(btrim(COALESCE(p_notes,'')),'')
    );

    RETURN jsonb_build_object(
        'reconciliationId',v_rec.id,
        'scoreCardId',v_card.id,
        'status',v_rec.status,
        'alreadyCompleted',false,
        'reviewHoles',v_review_total,
        'resolvedReviewHoles',v_review_total,
        'completedAt',v_rec.completed_at
    );
END;
$$;

REVOKE ALL ON FUNCTION public.iniciar_conciliacion_tarjeta_score(uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.iniciar_conciliacion_tarjeta_score(uuid)
TO authenticated;

REVOKE ALL ON FUNCTION public.resolver_hoyo_conciliacion_score(uuid,uuid,text,integer,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.resolver_hoyo_conciliacion_score(uuid,uuid,text,integer,text)
TO authenticated;

REVOKE ALL ON FUNCTION public.obtener_resoluciones_conciliacion_tarjeta_score(uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_resoluciones_conciliacion_tarjeta_score(uuid)
TO authenticated;

REVOKE ALL ON FUNCTION public.finalizar_conciliacion_tarjeta_score(uuid,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.finalizar_conciliacion_tarjeta_score(uuid,text)
TO authenticated;

COMMIT;
