-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 321
-- BEST BALL F7 — CALCULO DERIVADO EN TIEMPO REAL (GROSS / NETO)
-- ============================================================================
-- OBJETIVO
--   1) Derivar Best Gross y Best Net por hoyo desde scores individuales.
--   2) Reutilizar calcular_golpes_handicap_hoyo(...) para golpes recibidos.
--   3) Identificar jugador(es) que aportan el mejor Gross y mejor Neto.
--   4) Exponer empates internos entre integrantes.
--   5) Exponer estado operativo del hoyo:
--        OPEN      = existe PENDING
--        DISPUTED  = existe al menos una disputa
--        COMPLETE  = todos resueltos y existe al menos un SCORE
--        NO_SCORE  = todos resueltos pero todos son PICKUP
--   6) Entregar acumulados PROVISIONALES PARCIALES de ronda.
--
-- PRINCIPIO
--   El score TEAM Best Ball NO se captura ni se persiste.
--   Siempre se deriva de la evidencia individual.
--
-- DISPUTAS
--   Una fila disputed NO participa como candidato de Best Gross/Best Net.
--   El hoyo se marca DISPUTED. Si existen otros SCORE no disputados,
--   se muestran como referencia provisional, nunca como resultado oficial.
--
-- NO HACE
--   - No oficializa resultados (F11).
--   - No crea leaderboard (F12).
--   - No modifica scores individuales ni shared score tables.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_best_ball_digital_tarjeta_321(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_card record;
    v_snapshot record;
    v_player_id uuid;
    v_is_member boolean:=false;
    v_is_marker boolean:=false;
    v_is_admin boolean:=false;

    v_holes_count integer:=0;
    v_distinct_si integer:=0;
    v_min_si integer:=0;
    v_max_si integer:=0;

    v_member_count integer:=0;
    v_bad_rhs integer:=0;

    v_result jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_score_card_id IS NULL THEN
        RAISE EXCEPTION 'score_card_id es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.tournament_team_id,
        sc.card_number,
        sc.card_folio,
        sc.unit_type,
        sc.status,
        sc.validation_id,
        v.participation_type,
        v.scoring_engine
      INTO v_card
      FROM public.tournament_score_cards sc
      JOIN public.tournament_round_start_validations v
        ON v.id=sc.validation_id
     WHERE sc.id=p_score_card_id
       AND sc.status='issued'
     LIMIT 1;

    IF v_card.id IS NULL
       OR v_card.unit_type IS DISTINCT FROM 'team'
       OR v_card.participation_type IS DISTINCT FROM 'equipo'
       OR v_card.scoring_engine IS DISTINCT FROM 'best_ball'
    THEN
        RAISE EXCEPTION
            'La tarjeta indicada no corresponde a Best Ball TEAM.'
            USING ERRCODE='22023';
    END IF;

    SELECT ss.*
      INTO v_snapshot
      FROM public.tournament_best_ball_scorecard_snapshots ss
     WHERE ss.score_card_id=v_card.id
     LIMIT 1;

    IF v_snapshot.id IS NULL THEN
        RAISE EXCEPTION
            'La tarjeta Best Ball no tiene snapshot oficial.'
            USING ERRCODE='55000';
    END IF;

    v_player_id:=public._scorecard_current_player_id();

    IF v_player_id IS NOT NULL THEN
        SELECT EXISTS(
            SELECT 1
            FROM public.tournament_best_ball_scorecard_members bm
            WHERE bm.best_ball_scorecard_snapshot_id=v_snapshot.id
              AND bm.player_id=v_player_id
        )
        INTO v_is_member;

        SELECT EXISTS(
            SELECT 1
            FROM public.tournament_scorecard_marker_assignments ma
            WHERE ma.score_card_id=v_card.id
              AND ma.status='active'
              AND ma.marker_player_id=v_player_id
        )
        INTO v_is_marker;
    END IF;

    v_is_admin:=
        public.puede_administrar_congelamiento_torneo(
            v_card.tournament_id
        );

    IF NOT (v_is_member OR v_is_marker OR v_is_admin) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar el cálculo Best Ball de esta tarjeta.'
            USING ERRCODE='42501';
    END IF;

    SELECT count(*)
      INTO v_member_count
      FROM public.tournament_best_ball_scorecard_members bm
     WHERE bm.best_ball_scorecard_snapshot_id=v_snapshot.id;

    IF v_member_count NOT BETWEEN 2 AND 5 THEN
        RAISE EXCEPTION
            'La tarjeta Best Ball debe tener entre 2 y 5 integrantes congelados.'
            USING ERRCODE='55000',
                  DETAIL=format('member_count=%s',v_member_count);
    END IF;

    -- Verificar integridad de RHS individuales.
    SELECT count(*)
      INTO v_bad_rhs
      FROM public.tournament_best_ball_scorecard_members bm
      LEFT JOIN public.tournament_round_handicap_snapshots rhs
        ON rhs.id=bm.round_handicap_snapshot_id
     WHERE bm.best_ball_scorecard_snapshot_id=v_snapshot.id
       AND (
           rhs.id IS NULL
           OR rhs.tournament_round_id IS DISTINCT FROM v_card.tournament_round_id
           OR rhs.player_id IS DISTINCT FROM bm.player_id
           OR rhs.tournament_registration_id
                IS DISTINCT FROM bm.tournament_registration_id
           OR rhs.playing_handicap IS NULL
       );

    IF v_bad_rhs<>0 THEN
        RAISE EXCEPTION
            'Uno o más integrantes Best Ball no tienen un snapshot de hándicap válido.'
            USING ERRCODE='55000',
                  DETAIL=format('invalid_rhs=%s',v_bad_rhs);
    END IF;

    -- Validar los 18 hoyos / Stroke Index 1..18 a partir de las filas Best Ball.
    SELECT
        count(DISTINCT hs.round_hole_snapshot_id),
        count(DISTINCT rh.stroke_index),
        min(rh.stroke_index),
        max(rh.stroke_index)
      INTO
        v_holes_count,
        v_distinct_si,
        v_min_si,
        v_max_si
      FROM public.tournament_best_ball_hole_scores hs
      JOIN public.tournament_round_hole_snapshots rh
        ON rh.id=hs.round_hole_snapshot_id
     WHERE hs.score_card_id=v_card.id;

    IF v_holes_count<>18
       OR v_distinct_si<>18
       OR v_min_si<>1
       OR v_max_si<>18
    THEN
        RAISE EXCEPTION
            'Los hoyos Best Ball no contienen un Stroke Index completo 1..18.'
            USING ERRCODE='55000',
                  DETAIL=format(
                    'holes=%s; distinct_si=%s; min_si=%s; max_si=%s',
                    v_holes_count,
                    v_distinct_si,
                    v_min_si,
                    v_max_si
                  );
    END IF;

    WITH member_rows AS (
        SELECT
            hs.id AS hole_score_id,
            hs.score_card_id,
            hs.best_ball_scorecard_member_id,
            hs.player_id,
            bm.tournament_registration_id,
            bm.member_order,
            bm.round_handicap_snapshot_id,
            rhs.playing_handicap,
            hs.round_hole_snapshot_id,
            hs.hole_number,
            hs.play_sequence,
            rh.par,
            rh.stroke_index,
            hs.status,
            hs.result_type,
            hs.gross_score,
            hs.player_claimed_result_type,
            hs.player_claimed_gross_score,
            hs.dispute_note,
            public.calcular_golpes_handicap_hoyo(
                rhs.playing_handicap,
                rh.stroke_index,
                18
            ) AS handicap_strokes
        FROM public.tournament_best_ball_hole_scores hs
        JOIN public.tournament_best_ball_scorecard_members bm
          ON bm.id=hs.best_ball_scorecard_member_id
         AND bm.best_ball_scorecard_snapshot_id=v_snapshot.id
        JOIN public.tournament_round_handicap_snapshots rhs
          ON rhs.id=bm.round_handicap_snapshot_id
        JOIN public.tournament_round_hole_snapshots rh
          ON rh.id=hs.round_hole_snapshot_id
        WHERE hs.score_card_id=v_card.id
    ),
    enriched AS (
        SELECT
            mr.*,
            CASE
                WHEN mr.result_type='SCORE'
                 AND mr.status IN ('entered','confirmed')
                    THEN mr.gross_score - mr.handicap_strokes
                ELSE NULL
            END AS net_score,

            CASE
                WHEN mr.result_type='SCORE'
                 AND mr.status IN ('entered','confirmed')
                    THEN true
                ELSE false
            END AS is_countable_candidate
        FROM member_rows mr
    ),
    hole_stats AS (
        SELECT
            e.round_hole_snapshot_id,
            min(e.hole_number) AS hole_number,
            min(e.play_sequence) AS play_sequence,
            min(e.par) AS par,
            min(e.stroke_index) AS stroke_index,

            count(*)::integer AS member_count,

            count(*) FILTER (
                WHERE e.status='pending'
                   OR e.result_type='PENDING'
            )::integer AS pending_count,

            count(*) FILTER (
                WHERE e.status='disputed'
            )::integer AS disputed_count,

            count(*) FILTER (
                WHERE e.result_type='PICKUP'
                  AND e.status IN ('entered','confirmed')
            )::integer AS pickup_count,

            count(*) FILTER (
                WHERE e.result_type='SCORE'
                  AND e.status IN ('entered','confirmed')
            )::integer AS score_count,

            count(*) FILTER (
                WHERE e.status='confirmed'
            )::integer AS confirmed_count,

            min(e.gross_score) FILTER (
                WHERE e.is_countable_candidate
            ) AS best_gross,

            min(e.net_score) FILTER (
                WHERE e.is_countable_candidate
            ) AS best_net
        FROM enriched e
        GROUP BY e.round_hole_snapshot_id
    ),
    hole_results AS (
        SELECT
            s.*,

            CASE
                WHEN s.disputed_count>0 THEN 'DISPUTED'
                WHEN s.pending_count>0 THEN 'OPEN'
                WHEN s.score_count=0 THEN 'NO_SCORE'
                ELSE 'COMPLETE'
            END AS hole_state,

            COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'bestBallScorecardMemberId',
                            e.best_ball_scorecard_member_id,
                        'playerId',e.player_id,
                        'tournamentRegistrationId',
                            e.tournament_registration_id,
                        'memberOrder',e.member_order,
                        'grossScore',e.gross_score
                    )
                    ORDER BY e.member_order,e.player_id
                )
                FROM enriched e
                WHERE e.round_hole_snapshot_id=s.round_hole_snapshot_id
                  AND e.is_countable_candidate
                  AND e.gross_score=s.best_gross
            ),'[]'::jsonb) AS gross_counting_players,

            COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'bestBallScorecardMemberId',
                            e.best_ball_scorecard_member_id,
                        'playerId',e.player_id,
                        'tournamentRegistrationId',
                            e.tournament_registration_id,
                        'memberOrder',e.member_order,
                        'grossScore',e.gross_score,
                        'handicapStrokes',e.handicap_strokes,
                        'netScore',e.net_score
                    )
                    ORDER BY e.member_order,e.player_id
                )
                FROM enriched e
                WHERE e.round_hole_snapshot_id=s.round_hole_snapshot_id
                  AND e.is_countable_candidate
                  AND e.net_score=s.best_net
            ),'[]'::jsonb) AS net_counting_players,

            COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'holeScoreId',e.hole_score_id,
                        'bestBallScorecardMemberId',
                            e.best_ball_scorecard_member_id,
                        'playerId',e.player_id,
                        'tournamentRegistrationId',
                            e.tournament_registration_id,
                        'memberOrder',e.member_order,
                        'roundHandicapSnapshotId',
                            e.round_handicap_snapshot_id,
                        'playingHandicap',e.playing_handicap,
                        'handicapStrokes',e.handicap_strokes,
                        'resultType',e.result_type,
                        'grossScore',e.gross_score,
                        'netScore',e.net_score,
                        'status',e.status,
                        'playerClaimedResultType',
                            e.player_claimed_result_type,
                        'playerClaimedGrossScore',
                            e.player_claimed_gross_score,
                        'disputeNote',e.dispute_note
                    )
                    ORDER BY e.member_order,e.player_id
                )
                FROM enriched e
                WHERE e.round_hole_snapshot_id=s.round_hole_snapshot_id
            ),'[]'::jsonb) AS members
        FROM hole_stats s
    ),
    totals AS (
        SELECT
            count(*)::integer AS holes_total,

            count(*) FILTER (
                WHERE hr.best_gross IS NOT NULL
            )::integer AS holes_with_current_score,

            count(*) FILTER (
                WHERE hr.hole_state='COMPLETE'
            )::integer AS complete_holes,

            count(*) FILTER (
                WHERE hr.hole_state='OPEN'
            )::integer AS open_holes,

            count(*) FILTER (
                WHERE hr.hole_state='DISPUTED'
            )::integer AS disputed_holes,

            count(*) FILTER (
                WHERE hr.hole_state='NO_SCORE'
            )::integer AS no_score_holes,

            sum(hr.best_gross) FILTER (
                WHERE hr.best_gross IS NOT NULL
            )::integer AS provisional_partial_gross_total,

            sum(hr.best_net) FILTER (
                WHERE hr.best_net IS NOT NULL
            )::integer AS provisional_partial_net_total
        FROM hole_results hr
    )
    SELECT jsonb_build_object(
        'scoreCard',jsonb_build_object(
            'scoreCardId',v_card.id,
            'cardNumber',v_card.card_number,
            'cardFolio',v_card.card_folio,
            'competitiveUnit','TEAM',
            'teamId',v_card.tournament_team_id,
            'teamName',v_snapshot.team_name,
            'tournamentId',v_card.tournament_id,
            'tournamentRoundId',v_card.tournament_round_id
        ),

        'access',jsonb_build_object(
            'isTeamMember',v_is_member,
            'isMarker',v_is_marker,
            'isAdmin',v_is_admin
        ),

        'calculation',jsonb_build_object(
            'engine','best_ball',
            'basis','DIGITAL_LIVE',
            'persistedTeamScore',false,
            'handicapMethod','INDIVIDUAL_PLAYING_HANDICAP_BY_STROKE_INDEX',
            'disputedScoresCountAsCandidates',false
        ),

        'summary',jsonb_build_object(
            'holesTotal',t.holes_total,
            'holesWithCurrentScore',t.holes_with_current_score,
            'completeHoles',t.complete_holes,
            'openHoles',t.open_holes,
            'disputedHoles',t.disputed_holes,
            'noScoreHoles',t.no_score_holes,
            'provisionalPartialGrossTotal',
                t.provisional_partial_gross_total,
            'provisionalPartialNetTotal',
                t.provisional_partial_net_total,
            'digitallyResolved',
                (
                    t.holes_total=18
                    AND t.complete_holes=18
                    AND t.open_holes=0
                    AND t.disputed_holes=0
                    AND t.no_score_holes=0
                ),
            'official',false
        ),

        'members',COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'bestBallScorecardMemberId',bm.id,
                    'playerId',bm.player_id,
                    'tournamentRegistrationId',
                        bm.tournament_registration_id,
                    'memberOrder',bm.member_order,
                    'roundHandicapSnapshotId',
                        bm.round_handicap_snapshot_id,
                    'playingHandicap',rhs.playing_handicap,
                    'handicapAllowancePct',
                        rhs.handicap_allowance_pct
                )
                ORDER BY bm.member_order,bm.player_id
            )
            FROM public.tournament_best_ball_scorecard_members bm
            JOIN public.tournament_round_handicap_snapshots rhs
              ON rhs.id=bm.round_handicap_snapshot_id
            WHERE bm.best_ball_scorecard_snapshot_id=v_snapshot.id
        ),'[]'::jsonb),

        'holes',COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'roundHoleSnapshotId',
                        hr.round_hole_snapshot_id,
                    'holeNumber',hr.hole_number,
                    'playSequence',hr.play_sequence,
                    'par',hr.par,
                    'strokeIndex',hr.stroke_index,
                    'state',hr.hole_state,
                    'memberCount',hr.member_count,
                    'pendingCount',hr.pending_count,
                    'disputedCount',hr.disputed_count,
                    'pickupCount',hr.pickup_count,
                    'scoreCount',hr.score_count,
                    'confirmedCount',hr.confirmed_count,

                    'bestGross',hr.best_gross,
                    'grossTie',
                        jsonb_array_length(
                            hr.gross_counting_players
                        )>1,
                    'grossCountingPlayers',
                        hr.gross_counting_players,

                    'bestNet',hr.best_net,
                    'netTie',
                        jsonb_array_length(
                            hr.net_counting_players
                        )>1,
                    'netCountingPlayers',
                        hr.net_counting_players,

                    'members',hr.members
                )
                ORDER BY hr.play_sequence,hr.hole_number
            )
            FROM hole_results hr
        ),'[]'::jsonb)
    )
    INTO v_result
    FROM totals t;

    RETURN v_result;
END;
$function$;

COMMIT;
