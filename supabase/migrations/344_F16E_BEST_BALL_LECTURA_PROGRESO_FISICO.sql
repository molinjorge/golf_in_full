-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 344
-- BEST BALL F16E — LECTURA Y PROGRESO DE CAPTURA FISICA
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Detalle completo de captura física Best Ball.
--    La estructura se obtiene del snapshot/tarjeta Best Ball ya emitida.
--    NO se leen ni se exponen los scores digitales capturados.
-- ----------------------------------------------------------------------------

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
    v_snapshot public.tournament_best_ball_scorecard_snapshots;
BEGIN
    v_card := public._obtener_score_card_best_ball_fisica_323(p_score_card_id);

    SELECT *
      INTO v_snapshot
      FROM public.tournament_best_ball_scorecard_snapshots
     WHERE score_card_id = v_card.id
     LIMIT 1;

    IF v_snapshot.id IS NULL THEN
        RAISE EXCEPTION 'Snapshot Best Ball no encontrado para la tarjeta.'
            USING ERRCODE='55000';
    END IF;

    SELECT *
      INTO v_reception
      FROM public.tournament_scorecard_physical_receptions
     WHERE score_card_id = v_card.id
     LIMIT 1;

    RETURN jsonb_build_object(
        'schemaVersion', 2,
        'engine', 'best_ball',
        'scoreCardId', v_card.id,
        'cardNumber', v_card.card_number,
        'cardFolio', v_card.card_folio,
        'tournamentId', v_card.tournament_id,
        'tournamentRoundId', v_card.tournament_round_id,
        'team', jsonb_build_object(
            'tournamentTeamId', v_snapshot.tournament_team_id,
            'teamName', v_snapshot.team_name
        ),
        'received', v_reception.id IS NOT NULL,
        'reception', CASE
            WHEN v_reception.id IS NULL THEN NULL
            ELSE jsonb_build_object(
                'id', v_reception.id,
                'status', v_reception.status,
                'playerSignaturePresent', v_reception.player_signature_present,
                'markerSignaturePresent', v_reception.marker_signature_present,
                'notes', v_reception.notes,
                'receivedAt', v_reception.received_at,
                'captureStartedAt', v_reception.capture_started_at,
                'captureCompletedAt', v_reception.capture_completed_at
            )
        END,

        'members', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'bestBallScorecardMemberId', bm.id,
                    'playerId', bm.player_id,
                    'tournamentRegistrationId', bm.tournament_registration_id,
                    'memberOrder', bm.member_order,
                    'playerName', btrim(concat_ws(' ', p.nombres, p.apellidos))
                )
                ORDER BY bm.member_order, bm.player_id
            )
            FROM public.tournament_best_ball_scorecard_members bm
            LEFT JOIN public.players p ON p.id = bm.player_id
            WHERE bm.best_ball_scorecard_snapshot_id = v_snapshot.id
        ), '[]'::jsonb),

        'holes', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'roundHoleSnapshotId', h.round_hole_snapshot_id,
                    'holeNumber', h.hole_number,
                    'playSequence', h.play_sequence,
                    'members', h.members
                )
                ORDER BY h.play_sequence, h.hole_number
            )
            FROM (
                SELECT
                    hs.round_hole_snapshot_id,
                    hs.hole_number,
                    hs.play_sequence,
                    jsonb_agg(
                        jsonb_build_object(
                            'bestBallScorecardMemberId', bm.id,
                            'playerId', bm.player_id,
                            'playerName', btrim(concat_ws(' ', p.nombres, p.apellidos)),
                            'memberOrder', bm.member_order,
                            'physicalHoleScoreId', ph.id,
                            'physicalResultType', ph.physical_result_type,
                            'physicalGrossScore', ph.physical_gross_score,
                            'capturedAt', ph.captured_at,
                            'updatedAt', ph.updated_at
                        )
                        ORDER BY bm.member_order, bm.player_id
                    ) AS members
                FROM public.tournament_best_ball_hole_scores hs
                JOIN public.tournament_best_ball_scorecard_members bm
                  ON bm.id = hs.best_ball_scorecard_member_id
                 AND bm.best_ball_scorecard_snapshot_id = v_snapshot.id
                LEFT JOIN public.players p ON p.id = bm.player_id
                LEFT JOIN public.tournament_best_ball_physical_hole_scores ph
                  ON ph.score_card_id = v_card.id
                 AND ph.best_ball_scorecard_member_id = bm.id
                 AND ph.round_hole_snapshot_id = hs.round_hole_snapshot_id
                WHERE hs.score_card_id = v_card.id
                GROUP BY
                    hs.round_hole_snapshot_id,
                    hs.hole_number,
                    hs.play_sequence
            ) h
        ), '[]'::jsonb),

        -- Compatibilidad con el contrato 323 original.
        'physicalResults', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'id', ph.id,
                    'bestBallScorecardMemberId', ph.best_ball_scorecard_member_id,
                    'playerId', ph.player_id,
                    'playerName', btrim(concat_ws(' ', p.nombres, p.apellidos)),
                    'roundHoleSnapshotId', ph.round_hole_snapshot_id,
                    'holeNumber', ph.hole_number,
                    'playSequence', ph.play_sequence,
                    'physicalResultType', ph.physical_result_type,
                    'physicalGrossScore', ph.physical_gross_score,
                    'capturedAt', ph.captured_at,
                    'updatedAt', ph.updated_at
                )
                ORDER BY ph.play_sequence, bm.member_order, ph.player_id
            )
            FROM public.tournament_best_ball_physical_hole_scores ph
            JOIN public.tournament_best_ball_scorecard_members bm
              ON bm.id = ph.best_ball_scorecard_member_id
            LEFT JOIN public.players p ON p.id = ph.player_id
            WHERE ph.score_card_id = v_card.id
        ), '[]'::jsonb),

        'progress', jsonb_build_object(
            'memberCount', (
                SELECT count(*)::integer
                FROM public.tournament_best_ball_scorecard_members bm
                WHERE bm.best_ball_scorecard_snapshot_id = v_snapshot.id
            ),
            'holesExpected', (
                SELECT count(DISTINCT hs.round_hole_snapshot_id)::integer
                FROM public.tournament_best_ball_hole_scores hs
                WHERE hs.score_card_id = v_card.id
            ),
            'resultsExpected', (
                SELECT count(*)::integer
                FROM public.tournament_best_ball_hole_scores hs
                WHERE hs.score_card_id = v_card.id
            ),
            'resultsCaptured', (
                SELECT count(*)::integer
                FROM public.tournament_best_ball_physical_hole_scores ph
                WHERE ph.score_card_id = v_card.id
            )
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_captura_fisica_best_ball_323(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_captura_fisica_best_ball_323(uuid) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. Listado administrativo común de captura física.
--    Para Best Ball el progreso se mide por PLAYER/HOYO.
--    Las demás modalidades conservan su conteo anterior por HOYO.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_tarjetas_captura_fisica_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id es obligatorio.'
            USING ERRCODE = '22023';
    END IF;

    SELECT sc.tournament_id
      INTO v_tournament_id
      FROM public.tournament_score_cards sc
     WHERE sc.tournament_round_id = p_tournament_round_id
       AND sc.status = 'issued'
     ORDER BY sc.card_number NULLS LAST, sc.id
     LIMIT 1;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda no tiene tarjetas oficiales emitidas.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar la captura física de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    RETURN jsonb_build_object(
        'tournamentRoundId', p_tournament_round_id,
        'tournamentId', v_tournament_id,
        'cards',
        COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'scoreCardId', q.score_card_id,
                    'cardNumber', q.card_number,
                    'cardFolio', q.card_folio,

                    -- Se conserva la forma histórica del contrato común.
                    -- En TEAM, displayName ya representa la unidad/equipo.
                    'player', jsonb_build_object(
                        'playerId', q.player_id,
                        'displayName', q.unit_name
                    ),

                    'category', jsonb_build_object(
                        'tournamentCategoryId', q.tournament_category_id,
                        'name', q.category_name
                    ),

                    'marker', CASE
                        WHEN q.marker_player_id IS NULL THEN NULL
                        ELSE jsonb_build_object(
                            'playerId', q.marker_player_id,
                            'displayName', q.marker_name
                        )
                    END,

                    'physical', jsonb_build_object(
                        'received', (q.physical_reception_id IS NOT NULL),
                        'physicalReceptionId', q.physical_reception_id,
                        'status', COALESCE(q.physical_status, 'NOT_RECEIVED'),
                        'playerSignaturePresent',
                            COALESCE(q.player_signature_present, false),
                        'markerSignaturePresent',
                            COALESCE(q.marker_signature_present, false),
                        'receivedAt', q.received_at,
                        'captureStartedAt', q.capture_started_at,
                        'captureCompletedAt', q.capture_completed_at,
                        'holesExpected', q.holes_expected,
                        'physicalHolesCaptured', q.physical_holes_captured
                    )
                )
                ORDER BY q.card_number NULLS LAST, q.score_card_id
            )
            FROM (
                SELECT
                    sc.id AS score_card_id,
                    sc.card_number,
                    sc.card_folio,

                    u.player_id,
                    u.unit_name,
                    u.tournament_category_id,
                    g.category_name,

                    ma.marker_player_id,
                    mu.unit_name AS marker_name,

                    pr.id AS physical_reception_id,
                    pr.status AS physical_status,
                    pr.player_signature_present,
                    pr.marker_signature_present,
                    pr.received_at,
                    pr.capture_started_at,
                    pr.capture_completed_at,

                    CASE
                        WHEN v.scoring_engine = 'best_ball'
                         AND v.participation_type = 'equipo'
                        THEN COALESCE(bb_expected.results_expected, 0)
                        ELSE cs.holes_expected
                    END AS holes_expected,

                    CASE
                        WHEN v.scoring_engine = 'best_ball'
                         AND v.participation_type = 'equipo'
                        THEN COALESCE(bb_captured.results_captured, 0)
                        ELSE COALESCE(ph.physical_holes_captured, 0)
                    END AS physical_holes_captured

                FROM public.tournament_score_cards sc

                JOIN public.tournament_round_start_validations v
                  ON v.id = sc.validation_id

                JOIN public.tournament_round_start_validation_units u
                  ON u.id = sc.validation_unit_id
                 AND u.validation_id = sc.validation_id

                JOIN public.tournament_round_start_validation_groups g
                  ON g.id = sc.validation_group_id
                 AND g.validation_id = sc.validation_id

                LEFT JOIN public.tournament_scorecard_capture_sessions cs
                  ON cs.score_card_id = sc.id

                LEFT JOIN public.tournament_scorecard_physical_receptions pr
                  ON pr.score_card_id = sc.id

                LEFT JOIN LATERAL (
                    SELECT count(*)::integer AS physical_holes_captured
                    FROM public.tournament_scorecard_physical_hole_scores phs
                    WHERE phs.score_card_id = sc.id
                ) ph ON true

                LEFT JOIN LATERAL (
                    SELECT count(*)::integer AS results_expected
                    FROM public.tournament_best_ball_hole_scores bhs
                    WHERE bhs.score_card_id = sc.id
                ) bb_expected ON true

                LEFT JOIN LATERAL (
                    SELECT count(*)::integer AS results_captured
                    FROM public.tournament_best_ball_physical_hole_scores bph
                    WHERE bph.score_card_id = sc.id
                ) bb_captured ON true

                LEFT JOIN public.tournament_scorecard_marker_assignments ma
                  ON ma.score_card_id = sc.id
                 AND ma.status = 'active'

                LEFT JOIN public.tournament_score_cards msc
                  ON msc.id = ma.marker_score_card_id
                 AND msc.status = 'issued'

                LEFT JOIN public.tournament_round_start_validation_units mu
                  ON mu.id = msc.validation_unit_id
                 AND mu.validation_id = msc.validation_id

                WHERE sc.tournament_round_id = p_tournament_round_id
                  AND sc.status = 'issued'
            ) q
        ), '[]'::jsonb)
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_tarjetas_captura_fisica_ronda(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_tarjetas_captura_fisica_ronda(uuid) TO authenticated, service_role;

COMMIT;
