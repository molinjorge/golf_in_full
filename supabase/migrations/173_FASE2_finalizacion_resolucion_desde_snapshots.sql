-- ============================================================================
-- 173_fase2_finalizacion_resolucion_desde_snapshots.sql
-- Tee Central / GOLF IN FULL
--
-- MIGRACIÓN 173 — FASE 2
-- FINALIZACIÓN Y RESOLUCIÓN DE CONCILIACIÓN SIN DEPENDENCIA DIGITAL
--
-- REGLA FUNCIONAL:
-- - Tarjeta física: OBLIGATORIA.
-- - Captura digital: OPCIONAL.
-- - Físico sin digital = SIN_CAPTURA_DIGITAL y NO requiere resolución.
-- - Diferencia digital/físico o disputa pendiente = requiere resolución.
-- - Falta de físico = bloquea la finalización y NO puede resolverse por otra fuente.
--
-- ALCANCE:
-- - finalizar_conciliacion_tarjeta_score(uuid,text)
-- - resolver_hoyo_conciliacion_score(uuid,uuid,text,integer,text)
-- - No modifica todavía obtener_resultados_oficiales_ronda ni leaderboard.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. FINALIZAR CONCILIACIÓN
-- ============================================================================

CREATE OR REPLACE FUNCTION public.finalizar_conciliacion_tarjeta_score(
    p_score_card_id uuid,
    p_notes text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_card record;
    v_rec public.tournament_scorecard_reconciliations;
    v_admin_id uuid;

    v_holes_total integer := 0;
    v_missing_physical integer := 0;
    v_review_total integer := 0;
    v_unresolved integer := 0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id
    INTO v_card
    FROM public.tournament_score_cards sc
    WHERE sc.id=p_score_card_id
      AND sc.status='issued'
    LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION
            'La tarjeta oficial indicada no existe o no está emitida.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_card.tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para finalizar esta conciliación.'
            USING ERRCODE='42501';
    END IF;

    v_admin_id := public._scorecard_current_admin_id();

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE='42501';
    END IF;

    SELECT *
    INTO v_rec
    FROM public.tournament_scorecard_reconciliations
    WHERE score_card_id=v_card.id
    FOR UPDATE;

    IF v_rec.id IS NULL THEN
        RAISE EXCEPTION
            'Primero debe iniciarse la conciliación de esta tarjeta.'
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
        RAISE EXCEPTION
            'La conciliación no puede finalizar en su estado actual.'
            USING ERRCODE='55000';
    END IF;

    WITH evidence AS (
        SELECT
            rh.id AS round_hole_snapshot_id,
            hs.id AS hole_score_id,

            hs.gross_score AS digital_gross_score,
            hs.status AS digital_status,

            phs.physical_gross_score,

            ld.created_at AS last_disputed_at,
            lc.created_at AS last_confirmed_at,

            CASE
                WHEN phs.physical_gross_score IS NULL
                    THEN 'PENDIENTE_CAPTURA_FISICA'
                WHEN hs.gross_score IS NULL
                    THEN 'SIN_CAPTURA_DIGITAL'
                WHEN hs.gross_score=phs.physical_gross_score
                    THEN 'COINCIDE'
                ELSE 'DIFERENCIA'
            END AS comparison_status,

            CASE
                WHEN ld.created_at IS NULL THEN 'NONE'
                WHEN hs.status='disputed' THEN 'ACTIVE'
                WHEN lc.created_at IS NULL
                     OR lc.created_at < ld.created_at
                    THEN 'HISTORICAL_PENDING'
                ELSE 'HISTORICAL_RESOLVED'
            END AS dispute_status

        FROM public.tournament_round_hole_snapshots rh

        LEFT JOIN public.tournament_scorecard_hole_scores hs
          ON hs.score_card_id=v_card.id
         AND hs.round_hole_snapshot_id=rh.id

        LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
          ON phs.score_card_id=v_card.id
         AND phs.round_hole_snapshot_id=rh.id

        LEFT JOIN LATERAL (
            SELECT e.created_at
            FROM public.tournament_scorecard_events e
            WHERE hs.id IS NOT NULL
              AND e.hole_score_id=hs.id
              AND e.event_type='player_disputed'
            ORDER BY e.created_at DESC,e.id DESC
            LIMIT 1
        ) ld ON true

        LEFT JOIN LATERAL (
            SELECT e.created_at
            FROM public.tournament_scorecard_events e
            WHERE hs.id IS NOT NULL
              AND e.hole_score_id=hs.id
              AND e.event_type='player_confirmed'
            ORDER BY e.created_at DESC,e.id DESC
            LIMIT 1
        ) lc ON true

        WHERE rh.tournament_round_id=v_card.tournament_round_id
    ),
    review_holes AS (
        SELECT round_hole_snapshot_id
        FROM evidence
        WHERE comparison_status='DIFERENCIA'
           OR dispute_status IN ('ACTIVE','HISTORICAL_PENDING')
    )
    SELECT
        (SELECT count(*) FROM evidence),
        (SELECT count(*) FROM evidence
          WHERE physical_gross_score IS NULL),
        (SELECT count(*) FROM review_holes),
        (
            SELECT count(*)
            FROM review_holes rh
            LEFT JOIN public.tournament_scorecard_hole_resolutions r
              ON r.score_card_id=v_card.id
             AND r.round_hole_snapshot_id=rh.round_hole_snapshot_id
            WHERE r.id IS NULL
        )
    INTO
        v_holes_total,
        v_missing_physical,
        v_review_total,
        v_unresolved;

    IF v_holes_total <= 0 THEN
        RAISE EXCEPTION
            'No se puede finalizar la conciliación: la ronda no tiene hoyos congelados.'
            USING ERRCODE='55000';
    END IF;

    -- La tarjeta física es obligatoria. Una resolución no sustituye un hoyo
    -- físico faltante.
    IF v_missing_physical > 0 THEN
        RAISE EXCEPTION
            'No se puede finalizar la conciliación: faltan % hoyo(s) de captura física.',
            v_missing_physical
            USING ERRCODE='55000',
                  DETAIL=format(
                      'holes_total=%s; missing_physical=%s',
                      v_holes_total,v_missing_physical
                  );
    END IF;

    IF v_unresolved > 0 THEN
        RAISE EXCEPTION
            'No se puede finalizar la conciliación: quedan % hoyo(s) por resolver.',
            v_unresolved
            USING ERRCODE='55000',
                  DETAIL=format(
                      'review_total=%s; unresolved=%s',
                      v_review_total,v_unresolved
                  );
    END IF;

    UPDATE public.tournament_scorecard_reconciliations
    SET status='COMPLETED',
        completed_at=now(),
        completed_by_admin_user_id=v_admin_id,
        notes=COALESCE(
            nullif(btrim(COALESCE(p_notes,'')),''),
            notes
        ),
        updated_at=now()
    WHERE id=v_rec.id
    RETURNING * INTO v_rec;

    INSERT INTO public.tournament_scorecard_reconciliation_events(
        reconciliation_id,
        score_card_id,
        event_type,
        actor_admin_user_id,
        reason
    )
    VALUES (
        v_rec.id,
        v_card.id,
        'reconciliation_completed',
        v_admin_id,
        nullif(btrim(COALESCE(p_notes,'')),'')
    );

    RETURN jsonb_build_object(
        'reconciliationId',v_rec.id,
        'scoreCardId',v_card.id,
        'status',v_rec.status,
        'alreadyCompleted',false,
        'holesTotal',v_holes_total,
        'physicalHoles',v_holes_total,
        'reviewHoles',v_review_total,
        'resolvedReviewHoles',v_review_total,
        'completedAt',v_rec.completed_at
    );
END;
$function$;


-- ============================================================================
-- 2. RESOLVER HOYO
-- ============================================================================

CREATE OR REPLACE FUNCTION public.resolver_hoyo_conciliacion_score(
    p_score_card_id uuid,
    p_round_hole_snapshot_id uuid,
    p_resolution_source text,
    p_manual_gross_score integer DEFAULT NULL::integer,
    p_reason text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
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
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_resolution_source NOT IN (
        'DIGITAL','PHYSICAL','PLAYER_CLAIM','MANUAL'
    ) THEN
        RAISE EXCEPTION
            'resolution_source inválido.'
            USING ERRCODE='22023';
    END IF;

    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id
    INTO v_card
    FROM public.tournament_score_cards sc
    WHERE sc.id=p_score_card_id
      AND sc.status='issued'
    LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION
            'La tarjeta oficial indicada no existe o no está emitida.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_card.tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para resolver esta conciliación.'
            USING ERRCODE='42501';
    END IF;

    v_admin_id := public._scorecard_current_admin_id();

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE='42501';
    END IF;

    SELECT *
    INTO v_rec
    FROM public.tournament_scorecard_reconciliations
    WHERE score_card_id=v_card.id
    FOR UPDATE;

    IF v_rec.id IS NULL THEN
        RAISE EXCEPTION
            'Primero debe iniciarse la conciliación de esta tarjeta.'
            USING ERRCODE='55000';
    END IF;

    IF v_rec.status <> 'IN_REVIEW' THEN
        RAISE EXCEPTION
            'La conciliación no admite resolución de hoyos en su estado actual.'
            USING ERRCODE='55000',
                  DETAIL=format(
                      'reconciliation_status=%s',
                      v_rec.status
                  );
    END IF;

    -- El hoyo pertenece a la tarjeta si el snapshot pertenece a SU ronda.
    -- Digital y físico son evidencias opcionales/obligatorias respectivamente,
    -- no el esqueleto de pertenencia.
    SELECT
        rh.id AS round_hole_snapshot_id,
        rh.hole_number,

        COALESCE(
            hs.play_sequence,
            phs.play_sequence,
            rh.hole_number
        ) AS play_sequence,

        hs.id AS hole_score_id,
        hs.gross_score AS digital_gross_score,
        hs.status AS digital_status,
        hs.player_claimed_gross_score AS active_claimed_gross_score,

        phs.physical_gross_score

    INTO v_hole

    FROM public.tournament_round_hole_snapshots rh

    LEFT JOIN public.tournament_scorecard_hole_scores hs
      ON hs.score_card_id=v_card.id
     AND hs.round_hole_snapshot_id=rh.id

    LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
      ON phs.score_card_id=v_card.id
     AND phs.round_hole_snapshot_id=rh.id

    WHERE rh.id=p_round_hole_snapshot_id
      AND rh.tournament_round_id=v_card.tournament_round_id
    LIMIT 1;

    IF v_hole.round_hole_snapshot_id IS NULL THEN
        RAISE EXCEPTION
            'El hoyo indicado no pertenece a la ronda de esta tarjeta.'
            USING ERRCODE='22023';
    END IF;

    -- Sólo pueden existir eventos de disputa/confirmación si hubo fila digital.
    IF v_hole.hole_score_id IS NOT NULL THEN
        SELECT
            e.claimed_gross_score,
            e.created_at
        INTO
            v_last_claim,
            v_last_dispute_at
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
    ELSE
        v_last_claim := NULL;
        v_last_dispute_at := NULL;
        v_last_confirmed_at := NULL;
    END IF;

    v_comparison_status := CASE
        WHEN v_hole.physical_gross_score IS NULL
            THEN 'PENDIENTE_CAPTURA_FISICA'
        WHEN v_hole.digital_gross_score IS NULL
            THEN 'SIN_CAPTURA_DIGITAL'
        WHEN v_hole.digital_gross_score=v_hole.physical_gross_score
            THEN 'COINCIDE'
        ELSE 'DIFERENCIA'
    END;

    v_dispute_status := CASE
        WHEN v_last_dispute_at IS NULL THEN 'NONE'
        WHEN v_hole.digital_status='disputed' THEN 'ACTIVE'
        WHEN v_last_confirmed_at IS NULL
             OR v_last_confirmed_at < v_last_dispute_at
            THEN 'HISTORICAL_PENDING'
        ELSE 'HISTORICAL_RESOLVED'
    END;

    v_needs_review := (
        v_comparison_status='DIFERENCIA'
        OR v_dispute_status IN ('ACTIVE','HISTORICAL_PENDING')
    );

    -- Falta de físico no se "resuelve": se corrige completando la captura física.
    IF v_hole.physical_gross_score IS NULL THEN
        RAISE EXCEPTION
            'No puede resolverse un hoyo sin captura física finalizada.'
            USING ERRCODE='55000';
    END IF;

    -- Físico sin digital es válido y no necesita resolución explícita.
    IF NOT v_needs_review THEN
        RAISE EXCEPTION
            'Este hoyo no requiere una resolución explícita.'
            USING ERRCODE='22023',
                  DETAIL=format(
                      'comparison_status=%s; dispute_status=%s',
                      v_comparison_status,v_dispute_status
                  );
    END IF;

    v_resolved := CASE p_resolution_source
        WHEN 'DIGITAL'
            THEN v_hole.digital_gross_score
        WHEN 'PHYSICAL'
            THEN v_hole.physical_gross_score
        WHEN 'PLAYER_CLAIM'
            THEN COALESCE(
                v_hole.active_claimed_gross_score,
                v_last_claim
            )
        WHEN 'MANUAL'
            THEN p_manual_gross_score
    END;

    IF v_resolved IS NULL OR v_resolved <= 0 THEN
        RAISE EXCEPTION
            'La fuente seleccionada no tiene un valor válido para este hoyo.'
            USING ERRCODE='22023';
    END IF;

    IF p_resolution_source='MANUAL'
       AND length(btrim(COALESCE(p_reason,''))) < 5
    THEN
        RAISE EXCEPTION
            'MANUAL requiere un motivo de al menos 5 caracteres.'
            USING ERRCODE='22023';
    END IF;

    SELECT *
    INTO v_existing
    FROM public.tournament_scorecard_hole_resolutions
    WHERE score_card_id=v_card.id
      AND round_hole_snapshot_id=p_round_hole_snapshot_id
    FOR UPDATE;

    IF v_existing.id IS NULL THEN

        INSERT INTO public.tournament_scorecard_hole_resolutions(
            reconciliation_id,
            score_card_id,
            tournament_round_id,
            round_hole_snapshot_id,
            hole_number,
            play_sequence,
            digital_gross_snapshot,
            player_claim_gross_snapshot,
            physical_gross_snapshot,
            resolution_source,
            resolved_gross_score,
            reason,
            resolved_by_admin_user_id,
            updated_by_admin_user_id
        )
        VALUES (
            v_rec.id,
            v_card.id,
            v_card.tournament_round_id,
            p_round_hole_snapshot_id,
            v_hole.hole_number,
            v_hole.play_sequence,
            v_hole.digital_gross_score,
            COALESCE(
                v_hole.active_claimed_gross_score,
                v_last_claim
            ),
            v_hole.physical_gross_score,
            p_resolution_source,
            v_resolved,
            nullif(btrim(COALESCE(p_reason,'')),''),
            v_admin_id,
            v_admin_id
        )
        RETURNING * INTO v_saved;

        v_event_type := 'hole_resolved';

    ELSE

        UPDATE public.tournament_scorecard_hole_resolutions
        SET digital_gross_snapshot=v_hole.digital_gross_score,
            player_claim_gross_snapshot=COALESCE(
                v_hole.active_claimed_gross_score,
                v_last_claim
            ),
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
        reconciliation_id,
        score_card_id,
        hole_resolution_id,
        event_type,
        actor_admin_user_id,
        old_resolved_gross_score,
        new_resolved_gross_score,
        old_resolution_source,
        new_resolution_source,
        reason
    )
    VALUES (
        v_rec.id,
        v_card.id,
        v_saved.id,
        v_event_type,
        v_admin_id,

        CASE
            WHEN v_existing.id IS NULL
                THEN NULL
            ELSE v_existing.resolved_gross_score
        END,

        v_saved.resolved_gross_score,

        CASE
            WHEN v_existing.id IS NULL
                THEN NULL
            ELSE v_existing.resolution_source
        END,

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
$function$;

COMMIT;
