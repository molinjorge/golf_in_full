-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 186 Fase 1E
-- Captura física + conciliación + resolución SCORE/PICKUP
--
-- OBJETIVO
--   1) Agregar captura física genérica SCORE/PICKUP.
--   2) Mantener guardar_score_fisico_hoyo(...) como wrapper SCORE.
--   3) Comparar evidencia digital/física por tipo de resultado + gross.
--   4) Resolver discrepancias a SCORE o PICKUP.
--   5) Mantener resolver_hoyo_conciliacion_score(...) como wrapper SCORE.
--   6) Finalizar conciliación considerando PICKUP físico como evidencia válida.
--
-- NO HACE
--   - No calcula puntos Stableford.
--   - No modifica resultados oficiales/leaderboard.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Generalizar bitácora física para eventos SCORE/PICKUP futuros.
-- ----------------------------------------------------------------------------

ALTER TABLE public.tournament_scorecard_physical_events
    DROP CONSTRAINT IF EXISTS tournament_scorecard_physical_events_values_ck;

ALTER TABLE public.tournament_scorecard_physical_events
    ADD CONSTRAINT tournament_scorecard_physical_events_values_ck
    CHECK (
        (
            event_type = 'physical_score_entered'
            AND old_physical_result_type IS NULL
            AND old_physical_gross_score IS NULL
            AND new_physical_result_type IN ('SCORE','PICKUP')
            AND (
                (new_physical_result_type='SCORE' AND new_physical_gross_score IS NOT NULL)
                OR
                (new_physical_result_type='PICKUP' AND new_physical_gross_score IS NULL)
            )
        )
        OR
        (
            event_type = 'physical_score_corrected'
            AND old_physical_result_type IN ('SCORE','PICKUP')
            AND new_physical_result_type IN ('SCORE','PICKUP')
            AND (
                (old_physical_result_type='SCORE' AND old_physical_gross_score IS NOT NULL)
                OR
                (old_physical_result_type='PICKUP' AND old_physical_gross_score IS NULL)
            )
            AND (
                (new_physical_result_type='SCORE' AND new_physical_gross_score IS NOT NULL)
                OR
                (new_physical_result_type='PICKUP' AND new_physical_gross_score IS NULL)
            )
        )
        OR
        (
            event_type NOT IN ('physical_score_entered','physical_score_corrected')
            AND old_physical_result_type IS NULL
            AND new_physical_result_type IS NULL
            AND old_physical_gross_score IS NULL
            AND new_physical_gross_score IS NULL
        )
    );

-- ----------------------------------------------------------------------------
-- 2. Captura física genérica
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.guardar_resultado_fisico_hoyo(
    p_score_card_id uuid,
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
    v_existing public.tournament_scorecard_physical_hole_scores;
    v_saved public.tournament_scorecard_physical_hole_scores;
    v_new_gross integer;
BEGIN
    v_card := public._obtener_score_card_para_captura_fisica(p_score_card_id);

    p_physical_result_type :=
        upper(btrim(COALESCE(p_physical_result_type,'')));

    IF p_physical_result_type NOT IN ('SCORE','PICKUP') THEN
        RAISE EXCEPTION 'physical_result_type debe ser SCORE o PICKUP.'
            USING ERRCODE='22023';
    END IF;

    IF p_physical_result_type='SCORE'
       AND (p_physical_gross_score IS NULL OR p_physical_gross_score <= 0)
    THEN
        RAISE EXCEPTION 'SCORE físico requiere un gross mayor que cero.'
            USING ERRCODE='22023';
    END IF;

    IF p_physical_result_type='PICKUP'
       AND p_physical_gross_score IS NOT NULL
    THEN
        RAISE EXCEPTION 'PICKUP físico no admite gross.'
            USING ERRCODE='22023';
    END IF;

    v_new_gross :=
        CASE
            WHEN p_physical_result_type='SCORE' THEN p_physical_gross_score
            ELSE NULL
        END;

    IF p_physical_result_type='PICKUP'
       AND NOT EXISTS (
            SELECT 1
            FROM public.tournament_score_cards sc
            JOIN public.tournament_round_start_validations v
              ON v.id=sc.validation_id
            WHERE sc.id=v_card.id
              AND v.scoring_engine='stableford'
       )
    THEN
        RAISE EXCEPTION 'PICKUP físico sólo está permitido en Stableford.'
            USING ERRCODE='0A000';
    END IF;

    SELECT *
      INTO v_reception
      FROM public.tournament_scorecard_physical_receptions
     WHERE score_card_id=v_card.id
     FOR UPDATE;

    IF v_reception.id IS NULL THEN
        RAISE EXCEPTION
            'Primero debe registrarse la recepción de la tarjeta física.'
            USING ERRCODE='55000';
    END IF;

    IF v_reception.status IN ('CAPTURED','VOIDED') THEN
        RAISE EXCEPTION
            'La captura física ya no admite edición directa.'
            USING ERRCODE='55000';
    END IF;

    SELECT rhs.id,
           rhs.hole_number,
           COALESCE(hs.play_sequence,rhs.hole_number) AS play_sequence
      INTO v_hole
      FROM public.tournament_round_hole_snapshots rhs
      LEFT JOIN public.tournament_scorecard_hole_scores hs
        ON hs.score_card_id=v_card.id
       AND hs.round_hole_snapshot_id=rhs.id
     WHERE rhs.id=p_round_hole_snapshot_id
       AND rhs.tournament_round_id=v_card.tournament_round_id
     LIMIT 1;

    IF v_hole.id IS NULL THEN
        RAISE EXCEPTION
            'El hoyo indicado no pertenece a la ronda de esta tarjeta.'
            USING ERRCODE='22023';
    END IF;

    IF v_reception.status='RECEIVED' THEN
        UPDATE public.tournament_scorecard_physical_receptions
           SET status='IN_CAPTURE',
               capture_started_at=now(),
               capture_started_by_auth_user_id=auth.uid(),
               updated_at=now()
         WHERE id=v_reception.id
         RETURNING * INTO v_reception;

        INSERT INTO public.tournament_scorecard_physical_events(
            score_card_id,
            physical_reception_id,
            event_type,
            actor_auth_user_id
        )
        VALUES(
            v_card.id,
            v_reception.id,
            'physical_capture_started',
            auth.uid()
        );
    END IF;

    SELECT *
      INTO v_existing
      FROM public.tournament_scorecard_physical_hole_scores
     WHERE score_card_id=v_card.id
       AND round_hole_snapshot_id=p_round_hole_snapshot_id
     FOR UPDATE;

    IF v_existing.id IS NULL THEN
        INSERT INTO public.tournament_scorecard_physical_hole_scores(
            physical_reception_id,
            score_card_id,
            tournament_round_id,
            round_hole_snapshot_id,
            hole_number,
            play_sequence,
            physical_result_type,
            physical_gross_score,
            captured_by_auth_user_id,
            updated_by_auth_user_id
        )
        VALUES(
            v_reception.id,
            v_card.id,
            v_card.tournament_round_id,
            p_round_hole_snapshot_id,
            v_hole.hole_number,
            v_hole.play_sequence,
            p_physical_result_type,
            v_new_gross,
            auth.uid(),
            auth.uid()
        )
        RETURNING * INTO v_saved;

        INSERT INTO public.tournament_scorecard_physical_events(
            score_card_id,
            physical_reception_id,
            physical_hole_score_id,
            event_type,
            actor_auth_user_id,
            new_physical_result_type,
            new_physical_gross_score
        )
        VALUES(
            v_card.id,
            v_reception.id,
            v_saved.id,
            'physical_score_entered',
            auth.uid(),
            p_physical_result_type,
            CASE WHEN p_physical_result_type='SCORE'
                 THEN p_physical_gross_score ELSE NULL END
        );
    ELSE
        IF v_existing.physical_result_type IS NOT DISTINCT FROM p_physical_result_type
           AND v_existing.physical_gross_score IS NOT DISTINCT FROM v_new_gross
        THEN
            RETURN jsonb_build_object(
                'scoreCardId',v_card.id,
                'physicalReceptionId',v_reception.id,
                'physicalHoleScoreId',v_existing.id,
                'physicalResultType',v_existing.physical_result_type,
                'physicalGrossScore',v_existing.physical_gross_score,
                'changed',false
            );
        END IF;

        UPDATE public.tournament_scorecard_physical_hole_scores
           SET physical_result_type=p_physical_result_type,
               physical_gross_score=v_new_gross,
               updated_at=now(),
               updated_by_auth_user_id=auth.uid()
         WHERE id=v_existing.id
         RETURNING * INTO v_saved;

        INSERT INTO public.tournament_scorecard_physical_events(
            score_card_id,
            physical_reception_id,
            physical_hole_score_id,
            event_type,
            actor_auth_user_id,
            old_physical_result_type,
            new_physical_result_type,
            old_physical_gross_score,
            new_physical_gross_score
        )
        VALUES(
            v_card.id,
            v_reception.id,
            v_saved.id,
            'physical_score_corrected',
            auth.uid(),
            v_existing.physical_result_type,
            v_saved.physical_result_type,
            v_existing.physical_gross_score,
            v_saved.physical_gross_score
        );
    END IF;

    RETURN jsonb_build_object(
        'scoreCardId',v_card.id,
        'physicalReceptionId',v_reception.id,
        'physicalHoleScoreId',v_saved.id,
        'holeNumber',v_saved.hole_number,
        'playSequence',v_saved.play_sequence,
        'physicalResultType',v_saved.physical_result_type,
        'physicalGrossScore',v_saved.physical_gross_score,
        'status',v_reception.status,
        'changed',true
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.guardar_resultado_fisico_hoyo(uuid,uuid,text,integer)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.guardar_resultado_fisico_hoyo(uuid,uuid,text,integer)
TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.guardar_score_fisico_hoyo(
    p_score_card_id uuid,
    p_round_hole_snapshot_id uuid,
    p_physical_gross_score integer
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
    SELECT public.guardar_resultado_fisico_hoyo(
        p_score_card_id,
        p_round_hole_snapshot_id,
        'SCORE',
        p_physical_gross_score
    );
$function$;

-- ----------------------------------------------------------------------------
-- 3. Lectura física: exponer physicalResultType
-- ----------------------------------------------------------------------------

DO $do$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(
        'public.obtener_captura_fisica_tarjeta(uuid)'::regprocedure
    ) INTO v_def;

    IF position('''physicalResultType'', phs.physical_result_type' IN v_def)=0 THEN
        v_def := replace(
            v_def,
            '''physicalGrossScore'', phs.physical_gross_score,',
            '''physicalResultType'', phs.physical_result_type,
                        ''physicalGrossScore'', phs.physical_gross_score,'
        );
        EXECUTE v_def;
    END IF;
END;
$do$;

-- ----------------------------------------------------------------------------
-- 4. Conciliación: comparar tipo + gross
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_conciliacion_tarjeta_score(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_card record;
    v_reception record;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT sc.id,sc.tournament_id,sc.tournament_round_id,
           sc.card_number,sc.card_folio,sc.status,
           u.unit_name AS player_name,g.category_name
      INTO v_card
      FROM public.tournament_score_cards sc
      JOIN public.tournament_round_start_validation_units u
        ON u.id=sc.validation_unit_id
       AND u.validation_id=sc.validation_id
      JOIN public.tournament_round_start_validation_groups g
        ON g.id=sc.validation_group_id
       AND g.validation_id=sc.validation_id
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
            'No tienes permiso administrativo para consultar la conciliación de esta tarjeta.'
            USING ERRCODE='42501';
    END IF;

    SELECT pr.id,pr.status,pr.player_signature_present,
           pr.marker_signature_present,pr.received_at,pr.capture_completed_at
      INTO v_reception
      FROM public.tournament_scorecard_physical_receptions pr
     WHERE pr.score_card_id=v_card.id
     LIMIT 1;

    IF v_reception.id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta física todavía no ha sido recibida.'
            USING ERRCODE='55000';
    END IF;

    IF v_reception.status <> 'CAPTURED' THEN
        RAISE EXCEPTION
            'La comparación DIGITAL vs FÍSICO sólo está disponible después de finalizar la captura física.'
            USING ERRCODE='55000';
    END IF;

    RETURN (
        WITH hole_evidence AS (
            SELECT
                hs.id AS hole_score_id,
                rh.id AS round_hole_snapshot_id,
                rh.hole_number,
                COALESCE(hs.play_sequence,phs.play_sequence,rh.hole_number) AS play_sequence,
                rh.par,
                rh.stroke_index,

                hs.result_type AS digital_result_type,
                hs.gross_score AS digital_gross_score,
                hs.status AS digital_status,
                hs.player_claimed_result_type AS active_claimed_result_type,
                hs.player_claimed_gross_score AS active_claimed_gross_score,
                hs.dispute_note AS active_dispute_note,
                hs.disputed_at AS active_disputed_at,

                phs.physical_result_type,
                phs.physical_gross_score,
                phs.updated_at AS physical_updated_at,

                ld.claimed_result_type AS last_dispute_claimed_result_type,
                ld.claimed_gross_score AS last_dispute_claimed_gross_score,
                ld.reason AS last_dispute_reason,
                ld.created_at AS last_disputed_at,
                lc.created_at AS last_confirmed_at,

                CASE
                    WHEN ld.created_at IS NULL THEN 'NONE'
                    WHEN hs.status='disputed' THEN 'ACTIVE'
                    WHEN lc.created_at IS NULL OR lc.created_at < ld.created_at
                        THEN 'HISTORICAL_PENDING'
                    ELSE 'HISTORICAL_RESOLVED'
                END AS dispute_status,

                CASE
                    WHEN phs.id IS NULL THEN 'PENDIENTE_CAPTURA_FISICA'
                    WHEN hs.result_type='PENDING' THEN 'SIN_CAPTURA_DIGITAL'
                    WHEN hs.result_type IS NOT DISTINCT FROM phs.physical_result_type
                     AND hs.gross_score IS NOT DISTINCT FROM phs.physical_gross_score
                        THEN 'COINCIDE'
                    ELSE 'DIFERENCIA'
                END AS comparison_status

            FROM public.tournament_round_hole_snapshots rh
            LEFT JOIN public.tournament_scorecard_hole_scores hs
              ON hs.score_card_id=v_card.id
             AND hs.round_hole_snapshot_id=rh.id
            LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
              ON phs.score_card_id=v_card.id
             AND phs.round_hole_snapshot_id=rh.id
            LEFT JOIN LATERAL (
                SELECT e.claimed_result_type,e.claimed_gross_score,
                       e.reason,e.created_at
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
        enriched AS (
            SELECT he.*,
                   (
                       he.comparison_status='DIFERENCIA'
                       OR he.dispute_status IN ('ACTIVE','HISTORICAL_PENDING')
                       OR he.comparison_status='PENDIENTE_CAPTURA_FISICA'
                   ) AS needs_review
            FROM hole_evidence he
        )
        SELECT jsonb_build_object(
            'scoreCard',jsonb_build_object(
                'scoreCardId',v_card.id,
                'cardNumber',v_card.card_number,
                'cardFolio',v_card.card_folio,
                'playerName',v_card.player_name,
                'categoryName',v_card.category_name,
                'tournamentId',v_card.tournament_id,
                'tournamentRoundId',v_card.tournament_round_id
            ),
            'physicalCapture',jsonb_build_object(
                'physicalReceptionId',v_reception.id,
                'status',v_reception.status,
                'playerSignaturePresent',v_reception.player_signature_present,
                'markerSignaturePresent',v_reception.marker_signature_present,
                'receivedAt',v_reception.received_at,
                'captureCompletedAt',v_reception.capture_completed_at
            ),
            'summary',jsonb_build_object(
                'holesTotal',count(*),
                'coinciden',count(*) FILTER (WHERE comparison_status='COINCIDE'),
                'diferencias',count(*) FILTER (WHERE comparison_status='DIFERENCIA'),
                'sinCapturaDigital',count(*) FILTER (WHERE comparison_status='SIN_CAPTURA_DIGITAL'),
                'pendientesFisicos',count(*) FILTER (WHERE comparison_status='PENDIENTE_CAPTURA_FISICA'),
                'inconformidadesActivas',count(*) FILTER (WHERE dispute_status='ACTIVE'),
                'inconformidadesHistoricasPendientes',
                    count(*) FILTER (WHERE dispute_status='HISTORICAL_PENDING'),
                'inconformidadesHistoricasResueltas',
                    count(*) FILTER (WHERE dispute_status='HISTORICAL_RESOLVED'),
                'requierenRevision',count(*) FILTER (WHERE needs_review)
            ),
            'holes',COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'holeScoreId',hole_score_id,
                        'roundHoleSnapshotId',round_hole_snapshot_id,
                        'holeNumber',hole_number,
                        'playSequence',play_sequence,
                        'par',par,
                        'strokeIndex',stroke_index,
                        'digitalResultType',digital_result_type,
                        'digitalGrossScore',digital_gross_score,
                        'digitalStatus',digital_status,
                        'activeClaimedResultType',active_claimed_result_type,
                        'activeClaimedGrossScore',active_claimed_gross_score,
                        'activeDisputeNote',active_dispute_note,
                        'activeDisputedAt',active_disputed_at,
                        'lastDisputeClaimedResultType',last_dispute_claimed_result_type,
                        'lastDisputeClaimedGrossScore',last_dispute_claimed_gross_score,
                        'lastDisputeReason',last_dispute_reason,
                        'lastDisputedAt',last_disputed_at,
                        'lastConfirmedAt',last_confirmed_at,
                        'physicalResultType',physical_result_type,
                        'physicalGrossScore',physical_gross_score,
                        'physicalUpdatedAt',physical_updated_at,
                        'comparisonStatus',comparison_status,
                        'disputeStatus',dispute_status,
                        'hadDisputeHistory',(last_disputed_at IS NOT NULL),
                        'needsReview',needs_review
                    )
                    ORDER BY play_sequence,hole_number
                ),
                '[]'::jsonb
            )
        )
        FROM enriched
    );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. Resolución universal
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.resolver_hoyo_conciliacion_resultado(
    p_score_card_id uuid,
    p_round_hole_snapshot_id uuid,
    p_resolution_source text,
    p_manual_result_type text DEFAULT NULL,
    p_manual_gross_score integer DEFAULT NULL,
    p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_card record;
    v_rec public.tournament_scorecard_reconciliations;
    v_hole record;
    v_admin_id uuid;
    v_last_claim_type text;
    v_last_claim_gross integer;
    v_last_dispute_at timestamptz;
    v_last_confirmed_at timestamptz;
    v_comparison_status text;
    v_dispute_status text;
    v_needs_review boolean;
    v_resolved_type text;
    v_resolved_gross integer;
    v_existing public.tournament_scorecard_hole_resolutions;
    v_saved public.tournament_scorecard_hole_resolutions;
    v_event_type text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    p_resolution_source := upper(btrim(COALESCE(p_resolution_source,'')));

    IF p_resolution_source NOT IN ('DIGITAL','PHYSICAL','PLAYER_CLAIM','MANUAL') THEN
        RAISE EXCEPTION 'resolution_source inválido.'
            USING ERRCODE='22023';
    END IF;

    SELECT sc.id,sc.tournament_id,sc.tournament_round_id
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

    SELECT *
      INTO v_rec
      FROM public.tournament_scorecard_reconciliations
     WHERE score_card_id=v_card.id
     FOR UPDATE;

    IF v_rec.id IS NULL OR v_rec.status<>'IN_REVIEW' THEN
        RAISE EXCEPTION
            'La conciliación no admite resolución de hoyos en su estado actual.'
            USING ERRCODE='55000';
    END IF;

    SELECT
        rh.id AS round_hole_snapshot_id,
        rh.hole_number,
        COALESCE(hs.play_sequence,phs.play_sequence,rh.hole_number) AS play_sequence,
        hs.id AS hole_score_id,
        hs.result_type AS digital_result_type,
        hs.gross_score AS digital_gross_score,
        hs.status AS digital_status,
        hs.player_claimed_result_type AS active_claimed_result_type,
        hs.player_claimed_gross_score AS active_claimed_gross_score,
        phs.id AS physical_hole_score_id,
        phs.physical_result_type,
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
        RAISE EXCEPTION 'El hoyo indicado no pertenece a la ronda.'
            USING ERRCODE='22023';
    END IF;

    IF v_hole.hole_score_id IS NOT NULL THEN
        SELECT e.claimed_result_type,e.claimed_gross_score,e.created_at
          INTO v_last_claim_type,v_last_claim_gross,v_last_dispute_at
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
    END IF;

    v_comparison_status := CASE
        WHEN v_hole.physical_hole_score_id IS NULL THEN 'PENDIENTE_CAPTURA_FISICA'
        WHEN v_hole.digital_result_type='PENDING' THEN 'SIN_CAPTURA_DIGITAL'
        WHEN v_hole.digital_result_type IS NOT DISTINCT FROM v_hole.physical_result_type
         AND v_hole.digital_gross_score IS NOT DISTINCT FROM v_hole.physical_gross_score
            THEN 'COINCIDE'
        ELSE 'DIFERENCIA'
    END;

    v_dispute_status := CASE
        WHEN v_last_dispute_at IS NULL THEN 'NONE'
        WHEN v_hole.digital_status='disputed' THEN 'ACTIVE'
        WHEN v_last_confirmed_at IS NULL OR v_last_confirmed_at<v_last_dispute_at
            THEN 'HISTORICAL_PENDING'
        ELSE 'HISTORICAL_RESOLVED'
    END;

    v_needs_review :=
        v_comparison_status='DIFERENCIA'
        OR v_dispute_status IN ('ACTIVE','HISTORICAL_PENDING');

    IF v_hole.physical_hole_score_id IS NULL THEN
        RAISE EXCEPTION
            'No puede resolverse un hoyo sin captura física finalizada.'
            USING ERRCODE='55000';
    END IF;

    IF NOT v_needs_review THEN
        RAISE EXCEPTION 'Este hoyo no requiere una resolución explícita.'
            USING ERRCODE='22023';
    END IF;

    IF p_resolution_source='DIGITAL' THEN
        v_resolved_type := NULLIF(v_hole.digital_result_type,'PENDING');
        v_resolved_gross := v_hole.digital_gross_score;
    ELSIF p_resolution_source='PHYSICAL' THEN
        v_resolved_type := v_hole.physical_result_type;
        v_resolved_gross := v_hole.physical_gross_score;
    ELSIF p_resolution_source='PLAYER_CLAIM' THEN
        v_resolved_type := COALESCE(
            v_hole.active_claimed_result_type,
            v_last_claim_type
        );
        v_resolved_gross := COALESCE(
            v_hole.active_claimed_gross_score,
            v_last_claim_gross
        );
    ELSE
        v_resolved_type := upper(btrim(COALESCE(p_manual_result_type,'')));
        v_resolved_gross := p_manual_gross_score;
    END IF;

    IF v_resolved_type NOT IN ('SCORE','PICKUP') THEN
        RAISE EXCEPTION 'La fuente seleccionada no tiene un resultado válido.'
            USING ERRCODE='22023';
    END IF;

    IF v_resolved_type='SCORE'
       AND (v_resolved_gross IS NULL OR v_resolved_gross<=0)
    THEN
        RAISE EXCEPTION 'SCORE resuelto requiere gross mayor que cero.'
            USING ERRCODE='22023';
    END IF;

    IF v_resolved_type='PICKUP' THEN
        v_resolved_gross := NULL;
    END IF;

    IF p_resolution_source='MANUAL'
       AND length(btrim(COALESCE(p_reason,'')))<5
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
            digital_result_type_snapshot,
            digital_gross_snapshot,
            player_claim_result_type_snapshot,
            player_claim_gross_snapshot,
            physical_result_type_snapshot,
            physical_gross_snapshot,
            resolution_source,
            resolved_result_type,
            resolved_gross_score,
            reason,
            resolved_by_admin_user_id,
            updated_by_admin_user_id
        )
        VALUES(
            v_rec.id,
            v_card.id,
            v_card.tournament_round_id,
            p_round_hole_snapshot_id,
            v_hole.hole_number,
            v_hole.play_sequence,
            NULLIF(v_hole.digital_result_type,'PENDING'),
            v_hole.digital_gross_score,
            COALESCE(v_hole.active_claimed_result_type,v_last_claim_type),
            COALESCE(v_hole.active_claimed_gross_score,v_last_claim_gross),
            v_hole.physical_result_type,
            v_hole.physical_gross_score,
            p_resolution_source,
            v_resolved_type,
            v_resolved_gross,
            NULLIF(btrim(COALESCE(p_reason,'')),''),
            v_admin_id,
            v_admin_id
        )
        RETURNING * INTO v_saved;

        v_event_type := 'hole_resolved';
    ELSE
        UPDATE public.tournament_scorecard_hole_resolutions
           SET digital_result_type_snapshot=NULLIF(v_hole.digital_result_type,'PENDING'),
               digital_gross_snapshot=v_hole.digital_gross_score,
               player_claim_result_type_snapshot=
                   COALESCE(v_hole.active_claimed_result_type,v_last_claim_type),
               player_claim_gross_snapshot=
                   COALESCE(v_hole.active_claimed_gross_score,v_last_claim_gross),
               physical_result_type_snapshot=v_hole.physical_result_type,
               physical_gross_snapshot=v_hole.physical_gross_score,
               resolution_source=p_resolution_source,
               resolved_result_type=v_resolved_type,
               resolved_gross_score=v_resolved_gross,
               reason=NULLIF(btrim(COALESCE(p_reason,'')),''),
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
        old_resolved_result_type,
        new_resolved_result_type,
        old_resolved_gross_score,
        new_resolved_gross_score,
        old_resolution_source,
        new_resolution_source,
        reason
    )
    VALUES(
        v_rec.id,
        v_card.id,
        v_saved.id,
        v_event_type,
        v_admin_id,
        CASE WHEN v_existing.id IS NULL THEN NULL ELSE v_existing.resolved_result_type END,
        v_saved.resolved_result_type,
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
        'resolvedResultType',v_saved.resolved_result_type,
        'resolvedGrossScore',v_saved.resolved_gross_score,
        'reason',v_saved.reason,
        'comparisonStatus',v_comparison_status,
        'disputeStatus',v_dispute_status
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.resolver_hoyo_conciliacion_resultado(uuid,uuid,text,text,integer,text)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolver_hoyo_conciliacion_resultado(uuid,uuid,text,text,integer,text)
TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.resolver_hoyo_conciliacion_score(
    p_score_card_id uuid,
    p_round_hole_snapshot_id uuid,
    p_resolution_source text,
    p_manual_gross_score integer DEFAULT NULL,
    p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
    SELECT public.resolver_hoyo_conciliacion_resultado(
        p_score_card_id,
        p_round_hole_snapshot_id,
        p_resolution_source,
        CASE WHEN upper(COALESCE(p_resolution_source,''))='MANUAL'
             THEN 'SCORE' ELSE NULL END,
        p_manual_gross_score,
        p_reason
    );
$function$;

-- ----------------------------------------------------------------------------
-- 6. Finalización de conciliación: físico válido por fila, no por gross
-- ----------------------------------------------------------------------------

DO $do$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(
        'public.finalizar_conciliacion_tarjeta_score(uuid,text)'::regprocedure
    ) INTO v_def;

    v_def := replace(
        v_def,
        'phs.physical_gross_score,',
        'phs.id AS physical_hole_score_id,
            phs.physical_result_type,
            phs.physical_gross_score,'
    );

    v_def := replace(
        v_def,
        'WHEN phs.physical_gross_score IS NULL',
        'WHEN phs.id IS NULL'
    );

    v_def := replace(
        v_def,
        'WHEN hs.gross_score IS NULL',
        'WHEN hs.result_type = ''PENDING'''
    );

    v_def := replace(
        v_def,
        'WHEN hs.gross_score=phs.physical_gross_score',
        'WHEN hs.result_type IS NOT DISTINCT FROM phs.physical_result_type
                 AND hs.gross_score IS NOT DISTINCT FROM phs.physical_gross_score'
    );

    v_def := replace(
        v_def,
        'WHERE physical_gross_score IS NULL',
        'WHERE physical_hole_score_id IS NULL'
    );

    EXECUTE v_def;
END;
$do$;

-- ----------------------------------------------------------------------------
-- 7. Lectura de resoluciones: exponer tipos
-- ----------------------------------------------------------------------------

DO $do$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(
        'public.obtener_resoluciones_conciliacion_tarjeta_score(uuid)'::regprocedure
    ) INTO v_def;

    IF position('''resolvedResultType'',r.resolved_result_type' IN v_def)=0 THEN
        v_def := replace(
            v_def,
            '''digitalGrossSnapshot'',r.digital_gross_snapshot,',
            '''digitalResultTypeSnapshot'',r.digital_result_type_snapshot,
                    ''digitalGrossSnapshot'',r.digital_gross_snapshot,'
        );
        v_def := replace(
            v_def,
            '''playerClaimGrossSnapshot'',r.player_claim_gross_snapshot,',
            '''playerClaimResultTypeSnapshot'',r.player_claim_result_type_snapshot,
                    ''playerClaimGrossSnapshot'',r.player_claim_gross_snapshot,'
        );
        v_def := replace(
            v_def,
            '''physicalGrossSnapshot'',r.physical_gross_snapshot,',
            '''physicalResultTypeSnapshot'',r.physical_result_type_snapshot,
                    ''physicalGrossSnapshot'',r.physical_gross_snapshot,'
        );
        v_def := replace(
            v_def,
            '''resolvedGrossScore'',r.resolved_gross_score,',
            '''resolvedResultType'',r.resolved_result_type,
                    ''resolvedGrossScore'',r.resolved_gross_score,'
        );
        EXECUTE v_def;
    END IF;
END;
$do$;

COMMIT;

-- ============================================================================
-- FIN MIGRACIÓN 186 FASE 1E
-- ============================================================================
