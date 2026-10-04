-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 426
-- Adaptador QR para reutilizar la operación Stableford Individual existente
-- ============================================================================
-- OBJETIVO
-- 1) NO crear un segundo motor Stableford ni una segunda tarjeta digital.
-- 2) Extraer la lógica deportiva ya existente en la RPC 415 a un núcleo privado.
-- 3) Mantener la RPC autenticada 415 con el mismo contrato y guard vigente.
-- 4) Permitir que la lectura pública QR reutilice ese mismo núcleo deportivo.
-- 5) No exponer por QR datos de captura física.
--
-- IMPORTANTE
-- - No cambia fórmulas, Playing Handicap, distribución por Stroke Index,
--   SCORE/PICKUP, puntos Stableford, clasificaciones ni reglas especiales.
-- - No cambia las escrituras QR 423 ni el cierre 425.
-- - Lovable NO ejecuta esta migración. Debe ejecutarse manualmente en Supabase.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1. Núcleo privado de la operación Stableford existente.
--    Es la lógica deportiva de obtener_operacion_stableford_tarjeta_415,
--    desacoplada únicamente de su guard de autenticación.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._obtener_operacion_stableford_tarjeta_core_426(
  p_score_card_id uuid,
  p_include_physical boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_card record;
    v_unit record;
    v_rhs public.tournament_round_handicap_snapshots%ROWTYPE;
    v_rcs public.tournament_round_condition_snapshots%ROWTYPE;
    v_engine public.tournament_stableford_engine_snapshots%ROWTYPE;
    v_holes_count integer;
    v_handicap_strokes_total integer;
    v_hio_points integer;
    v_classifications jsonb;
BEGIN
    IF p_score_card_id IS NULL THEN
        RAISE EXCEPTION 'score_card_id es obligatorio.' USING ERRCODE='22023';
    END IF;

    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.validation_id,
        sc.validation_unit_id,
        sc.card_number,
        sc.card_folio,
        sc.unit_type
      INTO v_card
      FROM public.tournament_score_cards sc
     WHERE sc.id=p_score_card_id
       AND sc.status='issued'
     LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta oficial indicada no existe o no está emitida.'
            USING ERRCODE='22023';
    END IF;

    IF v_card.unit_type IS DISTINCT FROM 'registration' THEN
        RAISE EXCEPTION 'La consulta corresponde únicamente a Stableford Individual.'
            USING ERRCODE='0A000';
    END IF;

    SELECT
        u.id,
        u.player_id,
        u.tournament_registration_id,
        u.tournament_category_id,
        u.unit_name,
        u.round_handicap_snapshot_id
      INTO v_unit
      FROM public.tournament_round_start_validation_units u
     WHERE u.id=v_card.validation_unit_id
       AND u.validation_id=v_card.validation_id
     LIMIT 1;

    IF v_unit.id IS NULL OR v_unit.round_handicap_snapshot_id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta no tiene snapshot de hándicap de ronda.'
            USING ERRCODE='55000';
    END IF;

    SELECT *
      INTO v_rhs
      FROM public.tournament_round_handicap_snapshots rhs
     WHERE rhs.id=v_unit.round_handicap_snapshot_id
     LIMIT 1;

    IF v_rhs.id IS NULL OR v_rhs.playing_handicap IS NULL THEN
        RAISE EXCEPTION 'No existe un Playing Handicap congelado válido para la tarjeta.'
            USING ERRCODE='55000';
    END IF;

    SELECT *
      INTO v_rcs
      FROM public.tournament_round_condition_snapshots rcs
     WHERE rcs.id=v_rhs.round_condition_snapshot_id
     LIMIT 1;

    IF v_rcs.id IS NULL
       OR v_rcs.scoring_engine IS DISTINCT FROM 'stableford'
       OR v_rcs.participation_type IS DISTINCT FROM 'individual'
    THEN
        RAISE EXCEPTION 'La consulta corresponde únicamente a Stableford Individual.'
            USING ERRCODE='0A000';
    END IF;

    SELECT *
      INTO v_engine
      FROM public.tournament_stableford_engine_snapshots ses
     WHERE ses.freeze_id=v_rhs.freeze_id
       AND ses.tournament_round_id=v_card.tournament_round_id
     LIMIT 1;

    IF v_engine.id IS NULL THEN
        RAISE EXCEPTION 'La ronda Stableford no tiene snapshot de versión del motor.'
            USING ERRCODE='55000';
    END IF;

    SELECT count(*)::integer
      INTO v_holes_count
      FROM public.tournament_round_hole_snapshots rh
     WHERE rh.round_condition_snapshot_id=v_rhs.round_condition_snapshot_id;

    IF v_holes_count <= 0 THEN
        RAISE EXCEPTION 'La ronda Stableford no tiene hoyos congelados.'
            USING ERRCODE='55000';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM public.tournament_round_hole_snapshots rh
         WHERE rh.round_condition_snapshot_id=v_rhs.round_condition_snapshot_id
           AND (rh.stroke_index IS NULL
                OR rh.stroke_index < 1
                OR rh.stroke_index > v_holes_count)
    ) OR (
        SELECT count(DISTINCT rh.stroke_index)
          FROM public.tournament_round_hole_snapshots rh
         WHERE rh.round_condition_snapshot_id=v_rhs.round_condition_snapshot_id
    ) <> v_holes_count
    THEN
        RAISE EXCEPTION 'El Stroke Index congelado no forma una secuencia completa 1..N.'
            USING ERRCODE='55000';
    END IF;

    SELECT sum(public.calcular_golpes_handicap_hoyo(
                   v_rhs.playing_handicap,
                   rh.stroke_index,
                   v_holes_count
               ))::integer
      INTO v_handicap_strokes_total
      FROM public.tournament_round_hole_snapshots rh
     WHERE rh.round_condition_snapshot_id=v_rhs.round_condition_snapshot_id;

    IF v_handicap_strokes_total IS DISTINCT FROM v_rhs.playing_handicap THEN
        RAISE EXCEPTION 'La distribución por Stroke Index no suma el Playing Handicap.'
            USING ERRCODE='55000',
                  DETAIL=format('playing_handicap=%s; distributed=%s',
                                v_rhs.playing_handicap,
                                v_handicap_strokes_total);
    END IF;

    SELECT s.points
      INTO v_hio_points
      FROM public.tournament_stableford_special_rule_snapshots s
     WHERE s.freeze_id=v_rhs.freeze_id
       AND s.rule_code='HOLE_IN_ONE_OVERRIDE'
       AND s.enabled=true
       AND s.behavior='OVERRIDE'
     LIMIT 1;

    SELECT COALESCE(
               jsonb_agg(x.tipo_resultado ORDER BY x.tipo_resultado),
               '[]'::jsonb
           )
      INTO v_classifications
      FROM (
          SELECT DISTINCT s.tipo_resultado::text AS tipo_resultado
            FROM public.tournament_category_classification_snapshots s
           WHERE s.freeze_id=v_rhs.freeze_id
             AND s.tournament_category_id=v_unit.tournament_category_id
      ) x;

    RETURN (
        WITH hole_base AS (
            SELECT
                rh.id AS round_hole_snapshot_id,
                rh.hole_number,
                COALESCE(hs.play_sequence, phs.play_sequence, rh.hole_number) AS play_sequence,
                rh.par,
                rh.stroke_index,
                public.calcular_golpes_handicap_hoyo(
                    v_rhs.playing_handicap,
                    rh.stroke_index,
                    v_holes_count
                ) AS handicap_strokes,
                hs.result_type AS digital_result_type,
                hs.gross_score AS digital_gross_score,
                hs.status AS digital_status,
                phs.physical_result_type,
                phs.physical_gross_score
            FROM public.tournament_round_hole_snapshots rh
            LEFT JOIN public.tournament_scorecard_hole_scores hs
              ON hs.score_card_id=v_card.id
             AND hs.round_hole_snapshot_id=rh.id
            LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
              ON phs.score_card_id=v_card.id
             AND phs.round_hole_snapshot_id=rh.id
            WHERE rh.round_condition_snapshot_id=v_rhs.round_condition_snapshot_id
        ),
        scored AS (
            SELECT
                h.*,
                CASE
                    WHEN h.digital_result_type='PICKUP' THEN 0
                    WHEN h.digital_result_type='SCORE' AND h.digital_gross_score IS NOT NULL THEN
                        CASE
                            WHEN h.digital_gross_score=1 AND v_hio_points IS NOT NULL THEN v_hio_points
                            ELSE public.calcular_puntos_stableford_estandar(h.digital_gross_score,h.par)
                        END
                    ELSE NULL
                END AS digital_gross_points,
                CASE
                    WHEN h.digital_result_type='PICKUP' THEN 0
                    WHEN h.digital_result_type='SCORE' AND h.digital_gross_score IS NOT NULL THEN
                        CASE
                            WHEN h.digital_gross_score=1 AND v_hio_points IS NOT NULL THEN v_hio_points
                            ELSE public.calcular_puntos_stableford_estandar(
                                     h.digital_gross_score-h.handicap_strokes,h.par)
                        END
                    ELSE NULL
                END AS digital_net_points,
                CASE
                    WHEN h.physical_result_type='PICKUP' THEN 0
                    WHEN h.physical_result_type='SCORE' AND h.physical_gross_score IS NOT NULL THEN
                        CASE
                            WHEN h.physical_gross_score=1 AND v_hio_points IS NOT NULL THEN v_hio_points
                            ELSE public.calcular_puntos_stableford_estandar(h.physical_gross_score,h.par)
                        END
                    ELSE NULL
                END AS physical_gross_points,
                CASE
                    WHEN h.physical_result_type='PICKUP' THEN 0
                    WHEN h.physical_result_type='SCORE' AND h.physical_gross_score IS NOT NULL THEN
                        CASE
                            WHEN h.physical_gross_score=1 AND v_hio_points IS NOT NULL THEN v_hio_points
                            ELSE public.calcular_puntos_stableford_estandar(
                                     h.physical_gross_score-h.handicap_strokes,h.par)
                        END
                    ELSE NULL
                END AS physical_net_points
            FROM hole_base h
        )
        SELECT jsonb_build_object(
            'schemaVersion',1,
            'scoringEngine','stableford',
            'participationType','individual',
            'scoreCard',jsonb_build_object(
                'id',v_card.id,
                'cardNumber',v_card.card_number,
                'folio',v_card.card_folio,
                'playerId',v_unit.player_id,
                'playerName',v_unit.unit_name,
                'tournamentRegistrationId',v_unit.tournament_registration_id,
                'tournamentCategoryId',v_unit.tournament_category_id,
                'tournamentId',v_card.tournament_id,
                'tournamentRoundId',v_card.tournament_round_id
            ),
            'handicap',jsonb_build_object(
                'roundHandicapSnapshotId',v_rhs.id,
                'playingHandicap',v_rhs.playing_handicap,
                'handicapStrokesTotal',v_handicap_strokes_total
            ),
            'classification',jsonb_build_object(
                'configuredResultTypes',v_classifications,
                'grossEnabled',v_classifications ? 'gross',
                'netEnabled',v_classifications ? 'neto'
            ),
            'engine',jsonb_build_object(
                'engineSnapshotId',v_engine.id,
                'engineVersion',v_engine.engine_version,
                'pointsTableVersion',v_engine.points_table_version,
                'targetScoreBasis',v_engine.target_score_basis,
                'minimumPoints',v_engine.minimum_points,
                'maximumPoints',v_engine.maximum_points,
                'pickupPoints',v_engine.pickup_points
            ),
            'specialRules',jsonb_build_object(
                'holeInOneOverrideEnabled',(v_hio_points IS NOT NULL),
                'holeInOneOverridePoints',v_hio_points
            ),
            'holes',COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'roundHoleSnapshotId',s.round_hole_snapshot_id,
                        'holeNumber',s.hole_number,
                        'playSequence',s.play_sequence,
                        'par',s.par,
                        'strokeIndex',s.stroke_index,
                        'handicapStrokes',s.handicap_strokes,
                        'digitalResultType',COALESCE(s.digital_result_type,'PENDING'),
                        'digitalGrossScore',s.digital_gross_score,
                        'digitalStatus',s.digital_status,
                        'digitalGrossPoints',s.digital_gross_points,
                        'digitalNetPoints',s.digital_net_points
                    )
                    || CASE WHEN p_include_physical THEN
                        jsonb_build_object(
                            'physicalResultType',COALESCE(s.physical_result_type,'PENDING'),
                            'physicalGrossScore',s.physical_gross_score,
                            'physicalGrossPoints',s.physical_gross_points,
                            'physicalNetPoints',s.physical_net_points
                        )
                       ELSE '{}'::jsonb END
                    ORDER BY s.play_sequence,s.hole_number
                )
                FROM scored s
            ),'[]'::jsonb)
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public._obtener_operacion_stableford_tarjeta_core_426(uuid,boolean)
  FROM PUBLIC, anon, authenticated;

-- --------------------------------------------------------------------------
-- 2. La RPC 415 conserva su nombre, firma, autenticación, permisos y contrato.
--    Solo delega el cálculo al núcleo único 426.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_operacion_stableford_tarjeta_415(
  p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_guard jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
  END IF;

  IF p_score_card_id IS NULL THEN
    RAISE EXCEPTION 'score_card_id es obligatorio.' USING ERRCODE='22023';
  END IF;

  -- Conserva exactamente el guard de lectura autenticada anterior.
  v_guard := public.obtener_detalle_captura_tarjeta_score(p_score_card_id);

  RETURN public._obtener_operacion_stableford_tarjeta_core_426(
    p_score_card_id,
    true
  );
END;
$$;

-- --------------------------------------------------------------------------
-- 3. Lectura pública QR 426.
--    Parte de 425 y, solo para Stableford Individual, agrega la misma operación
--    deportiva del núcleo compartido, excluyendo datos de captura física.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_tarjeta_publica_qr_426(
  p_qr_token text,
  p_control_token text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_payload jsonb;
  v_card record;
  v_operation jsonb;
BEGIN
  v_payload := public.obtener_tarjeta_publica_qr_425(p_qr_token,p_control_token);

  IF COALESCE(v_payload->>'captureState','') IN ('invalid','digital_disabled','not_initialized') THEN
    RETURN v_payload;
  END IF;

  SELECT
      sc.id,
      sc.unit_type,
      v.scoring_engine,
      v.participation_type
    INTO v_card
    FROM public.tournament_score_cards sc
    JOIN public.tournament_round_start_validations v
      ON v.id=sc.validation_id
   WHERE lower(sc.qr_token)=lower(p_qr_token)
     AND sc.status='issued'
   LIMIT 1;

  IF v_card.id IS NULL THEN
    RETURN jsonb_build_object('captureState','invalid');
  END IF;

  IF v_card.scoring_engine='stableford'
     AND v_card.participation_type='individual'
     AND v_card.unit_type='registration'
  THEN
    v_operation := public._obtener_operacion_stableford_tarjeta_core_426(
      v_card.id,
      false
    );

    v_payload := v_payload || jsonb_build_object(
      'digitalOperation',v_operation
    );
  END IF;

  RETURN v_payload;
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_tarjeta_publica_qr_426(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_tarjeta_publica_qr_426(text,text) TO anon, authenticated;

COMMENT ON FUNCTION public._obtener_operacion_stableford_tarjeta_core_426(uuid,boolean)
IS 'Núcleo único de operación Stableford Individual extraído de 415. No concede acceso por sí mismo.';
COMMENT ON FUNCTION public.obtener_tarjeta_publica_qr_426(text,text)
IS 'Lectura pública QR 425 enriquecida con la operación Stableford Individual existente, sin exponer captura física.';

COMMIT;
