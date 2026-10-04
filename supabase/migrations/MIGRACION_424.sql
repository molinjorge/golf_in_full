-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 424
-- Lectura pública enriquecida de tarjeta digital por QR
--
-- OBJETIVO
--   Evolucionar exclusivamente la lectura pública de la tarjeta digital.
--   NO modifica captura, control exclusivo, heartbeat, inconformidad,
--   conciliación ni motores deportivos.
--
-- PRINCIPIOS
--   * unit_type='registration' => tarjeta individual.
--   * unit_type='team'         => tarjeta de equipo.
--   * Stableford TEAM futuro seguirá usando tarjetas individuales
--     (unit_type='registration'); el score TEAM será derivado por el motor.
--   * No se exponen correo, teléfono, fecha de nacimiento ni auth.user_id.
--   * VENTAJA/puntos Stableford NO se calculan aquí; quedan para Fase 2.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_tarjeta_publica_qr_424(
  p_qr_token text,
  p_control_token text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_card record;
  v_session record;
  v_control_state text := 'free';
  v_scores jsonb := '[]'::jsonb;
  v_holes jsonb := '[]'::jsonb;
  v_player jsonb;
  v_team jsonb;
  v_members jsonb := '[]'::jsonb;
  v_completed integer := 0;
  v_expected integer := 18;
BEGIN
  IF p_qr_token IS NULL OR p_qr_token !~ '^[0-9a-fA-F]{64}$' THEN
    RETURN jsonb_build_object('captureState','invalid');
  END IF;

  SELECT
    sc.id,
    sc.tournament_id,
    sc.tournament_round_id,
    sc.validation_id,
    sc.validation_group_id,
    sc.validation_unit_id,
    sc.unit_type,
    sc.tournament_registration_id,
    sc.tournament_team_id,
    sc.player_id,
    sc.card_folio,
    sc.card_number,
    t.nombre AS tournament_name,
    t.usar_tarjeta_digital,
    r.numero_ronda,
    r.fecha AS round_date,
    e.status AS emission_status,
    v.scoring_engine,
    v.participation_type,
    v.start_format,
    u.unit_name,
    u.unit_folio,
    u.order_in_group,
    u.handicap_snapshot_id,
    u.round_handicap_snapshot_id,
    g.hole_number AS start_hole_number,
    g.start_position,
    g.start_at,
    g.shift_number,
    g.shift_time,
    g.group_label,
    g.category_name
  INTO v_card
  FROM public.tournament_score_cards sc
  JOIN public.tournament_score_card_emissions e
    ON e.id = sc.emission_id
  JOIN public.tournaments t
    ON t.id = sc.tournament_id
  JOIN public.tournament_rounds r
    ON r.id = sc.tournament_round_id
  JOIN public.tournament_round_start_validations v
    ON v.id = sc.validation_id
  LEFT JOIN public.tournament_round_start_validation_units u
    ON u.id = sc.validation_unit_id
  LEFT JOIN public.tournament_round_start_validation_groups g
    ON g.id = sc.validation_group_id
  WHERE lower(sc.qr_token) = lower(p_qr_token)
    AND sc.status = 'issued'
  LIMIT 1;

  IF v_card.id IS NULL OR v_card.emission_status <> 'issued' THEN
    RETURN jsonb_build_object('captureState','invalid');
  END IF;

  IF NOT COALESCE(v_card.usar_tarjeta_digital,false) THEN
    RETURN jsonb_build_object('captureState','digital_disabled');
  END IF;

  -- Identidad deportiva de la unidad de la tarjeta.
  IF v_card.unit_type = 'registration' THEN
    SELECT jsonb_strip_nulls(jsonb_build_object(
      'name', COALESCE(v_card.unit_name, hs.player_name),
      'registrationFolio', COALESCE(v_card.unit_folio, hs.registration_folio),
      'handicapIndex', hs.handicap_index,
      'courseHandicap', rhs.course_handicap,
      'playingHandicap', rhs.playing_handicap,
      'coursePar', rhs.course_par,
      'courseRating', rhs.course_rating,
      'slopeRating', rhs.slope_rating,
      'handicapAllowancePct', rhs.handicap_allowance_pct,
      'teeName', hs.tee_name
    ))
    INTO v_player
    FROM (SELECT 1) x
    LEFT JOIN public.tournament_handicap_snapshots hs
      ON hs.id = v_card.handicap_snapshot_id
    LEFT JOIN public.tournament_round_handicap_snapshots rhs
      ON rhs.id = v_card.round_handicap_snapshot_id;

  ELSIF v_card.unit_type = 'team' THEN
    IF v_card.scoring_engine = 'best_ball' THEN
      SELECT COALESCE(jsonb_agg(
        jsonb_strip_nulls(jsonb_build_object(
          'bestBallScorecardMemberId', m.id,
          'memberOrder', m.member_order,
          'name', hs.player_name,
          'handicapIndex', hs.handicap_index,
          'courseHandicap', rhs.course_handicap,
          'playingHandicap', rhs.playing_handicap,
          'teeName', hs.tee_name
        ))
        ORDER BY m.member_order
      ), '[]'::jsonb)
      INTO v_members
      FROM public.tournament_best_ball_scorecard_snapshots bbs
      JOIN public.tournament_best_ball_scorecard_members m
        ON m.best_ball_scorecard_snapshot_id = bbs.id
      LEFT JOIN public.tournament_round_handicap_snapshots rhs
        ON rhs.id = m.round_handicap_snapshot_id
      LEFT JOIN public.tournament_handicap_snapshots hs
        ON hs.id = rhs.handicap_snapshot_id
      WHERE bbs.score_card_id = v_card.id;

      SELECT jsonb_strip_nulls(jsonb_build_object(
        'name', COALESCE(bbs.team_name, v_card.unit_name),
        'members', v_members
      ))
      INTO v_team
      FROM public.tournament_best_ball_scorecard_snapshots bbs
      WHERE bbs.score_card_id = v_card.id
      LIMIT 1;

      IF v_team IS NULL THEN
        v_team := jsonb_build_object(
          'name', v_card.unit_name,
          'members', v_members
        );
      END IF;
    ELSE
      SELECT
        COALESCE(
          (
            SELECT jsonb_agg(
              jsonb_strip_nulls(jsonb_build_object(
                'memberOrder', ordinality,
                'name', elem->>'name',
                'handicapIndex',
                  CASE
                    WHEN (elem->>'handicapIndex') ~ '^-?[0-9]+([.][0-9]+)?$'
                    THEN (elem->>'handicapIndex')::numeric
                    ELSE NULL
                  END
              ))
              ORDER BY ordinality
            )
            FROM jsonb_array_elements(COALESCE(ts.members_snapshot,'[]'::jsonb))
                 WITH ORDINALITY AS a(elem, ordinality)
          ),
          '[]'::jsonb
        ),
        jsonb_strip_nulls(jsonb_build_object(
          'name', COALESCE(ts.team_name, v_card.unit_name),
          'playingHandicap', ts.team_playing_handicap
        ))
      INTO v_members, v_team
      FROM public.tournament_team_scorecard_snapshots ts
      WHERE ts.score_card_id = v_card.id
      LIMIT 1;

      IF v_team IS NULL THEN
        v_team := jsonb_build_object('name', v_card.unit_name);
      END IF;
      v_team := v_team || jsonb_build_object('members', COALESCE(v_members,'[]'::jsonb));
    END IF;
  END IF;

  -- La identidad y los hoyos estructurales se devuelven aun sin sesión iniciada.
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'roundHoleSnapshotId', h.id,
      'holeNumber', h.hole_number,
      'par', h.par,
      'strokeIndex', h.stroke_index
    )
    ORDER BY h.hole_number
  ), '[]'::jsonb)
  INTO v_holes
  FROM public.tournament_round_hole_snapshots h
  WHERE h.tournament_round_id = v_card.tournament_round_id
    AND h.round_condition_snapshot_id = (
      SELECT rv.round_condition_snapshot_id
      FROM public.tournament_round_start_validations rv
      WHERE rv.id = v_card.validation_id
    );

  SELECT * INTO v_session
  FROM public.tournament_scorecard_capture_sessions
  WHERE score_card_id = v_card.id;

  IF v_session.id IS NULL THEN
    RETURN jsonb_strip_nulls(jsonb_build_object(
      'captureState','not_initialized',
      'controlState','free',
      'card', jsonb_build_object(
        'tournamentName',v_card.tournament_name,
        'roundNumber',v_card.numero_ronda,
        'roundDate',v_card.round_date,
        'folio',COALESCE(v_card.card_folio, v_card.card_number::text),
        'unitType',v_card.unit_type,
        'engine',v_card.scoring_engine,
        'participationType',v_card.participation_type,
        'startFormat',v_card.start_format,
        'start',jsonb_strip_nulls(jsonb_build_object(
          'holeNumber',v_card.start_hole_number,
          'position',v_card.start_position,
          'startAt',v_card.start_at,
          'shiftNumber',v_card.shift_number,
          'shiftTime',v_card.shift_time,
          'groupLabel',v_card.group_label,
          'categoryName',v_card.category_name,
          'orderInGroup',v_card.order_in_group
        ))
      ),
      'player',v_player,
      'team',v_team,
      'progress',jsonb_build_object('completed',0,'expected',jsonb_array_length(v_holes)),
      'holes',v_holes
    ));
  END IF;

  -- Conserva exactamente el modelo de control de 423.
  PERFORM public._qr_lock_card_423(v_card.id);

  UPDATE public.tournament_scorecard_qr_capture_controls
     SET released_at = now(),
         release_reason = 'expired'
   WHERE score_card_id = v_card.id
     AND released_at IS NULL
     AND expires_at <= now();

  IF EXISTS (
    SELECT 1
    FROM public.tournament_scorecard_qr_capture_controls c
    WHERE c.score_card_id = v_card.id
      AND c.released_at IS NULL
      AND c.expires_at > now()
  ) THEN
    IF p_control_token IS NOT NULL AND EXISTS (
      SELECT 1
      FROM public.tournament_scorecard_qr_capture_controls c
      WHERE c.score_card_id = v_card.id
        AND c.released_at IS NULL
        AND c.expires_at > now()
        AND c.control_token_hash = public._qr_hash_control_token_423(p_control_token)
    ) THEN
      v_control_state := 'mine';
    ELSE
      v_control_state := 'busy';
    END IF;
  END IF;

  v_expected := COALESCE(v_session.holes_expected, 18);

  IF v_card.scoring_engine = 'best_ball' THEN
    SELECT
      COALESCE(jsonb_agg(
        jsonb_strip_nulls(jsonb_build_object(
          'holeScoreId', hs.id,
          'bestBallScorecardMemberId', hs.best_ball_scorecard_member_id,
          'roundHoleSnapshotId', hs.round_hole_snapshot_id,
          'holeNumber', hs.hole_number,
          'playSequence', hs.play_sequence,
          'par', h.par,
          'strokeIndex', h.stroke_index,
          'status', hs.status,
          'resultType', hs.result_type,
          'grossScore', hs.gross_score,
          'claimedResultType', hs.player_claimed_result_type,
          'claimedGrossScore', hs.player_claimed_gross_score,
          'disputeNote', hs.dispute_note
        ))
        ORDER BY hs.play_sequence, hs.best_ball_scorecard_member_id
      ), '[]'::jsonb),
      count(*) FILTER (WHERE hs.status <> 'pending')
    INTO v_scores, v_completed
    FROM public.tournament_best_ball_hole_scores hs
    LEFT JOIN public.tournament_round_hole_snapshots h
      ON h.id = hs.round_hole_snapshot_id
    WHERE hs.score_card_id = v_card.id;

    -- Para Best Ball el avance se expresa sobre resultados miembro-hoyo.
    SELECT count(*) INTO v_expected
    FROM public.tournament_best_ball_hole_scores
    WHERE score_card_id = v_card.id;
  ELSE
    SELECT
      COALESCE(jsonb_agg(
        jsonb_strip_nulls(jsonb_build_object(
          'holeScoreId', hs.id,
          'roundHoleSnapshotId', hs.round_hole_snapshot_id,
          'holeNumber', hs.hole_number,
          'playSequence', hs.play_sequence,
          'par', h.par,
          'strokeIndex', h.stroke_index,
          'status', hs.status,
          'resultType', hs.result_type,
          'grossScore', hs.gross_score,
          'claimedResultType', hs.player_claimed_result_type,
          'claimedGrossScore', hs.player_claimed_gross_score,
          'disputeNote', hs.dispute_note
        ))
        ORDER BY hs.play_sequence
      ), '[]'::jsonb),
      count(*) FILTER (WHERE hs.status <> 'pending')
    INTO v_scores, v_completed
    FROM public.tournament_scorecard_hole_scores hs
    LEFT JOIN public.tournament_round_hole_snapshots h
      ON h.id = hs.round_hole_snapshot_id
    WHERE hs.score_card_id = v_card.id;
  END IF;

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'captureState',
      CASE
        WHEN v_session.status IN ('ready','in_progress','captured') THEN 'open'
        ELSE 'closed'
      END,
    'controlState',v_control_state,
    'captureSessionStatus',v_session.status,
    'card',jsonb_build_object(
      'tournamentName',v_card.tournament_name,
      'roundNumber',v_card.numero_ronda,
      'roundDate',v_card.round_date,
      'folio',COALESCE(v_card.card_folio, v_card.card_number::text),
      'unitType',v_card.unit_type,
      'engine',v_card.scoring_engine,
      'participationType',v_card.participation_type,
      'startFormat',v_card.start_format,
      'start',jsonb_strip_nulls(jsonb_build_object(
        'holeNumber',v_card.start_hole_number,
        'position',v_card.start_position,
        'startAt',v_card.start_at,
        'shiftNumber',v_card.shift_number,
        'shiftTime',v_card.shift_time,
        'groupLabel',v_card.group_label,
        'categoryName',v_card.category_name,
        'orderInGroup',v_card.order_in_group
      ))
    ),
    'player',v_player,
    'team',v_team,
    'progress',jsonb_build_object(
      'completed',COALESCE(v_completed,0),
      'expected',COALESCE(v_expected,0)
    ),
    'holes',v_scores
  ));
END;
$function$;

COMMENT ON FUNCTION public.obtener_tarjeta_publica_qr_424(text,text)
IS '424: lectura pública enriquecida de tarjeta digital por QR. Identidad deportiva, salida, PAR/SI, progreso y resultados; no implementa lógica Stableford de ventaja/puntos.';

REVOKE ALL ON FUNCTION public.obtener_tarjeta_publica_qr_424(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_tarjeta_publica_qr_424(text,text) TO anon;
GRANT EXECUTE ON FUNCTION public.obtener_tarjeta_publica_qr_424(text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_tarjeta_publica_qr_424(text,text) TO service_role;

COMMIT;
