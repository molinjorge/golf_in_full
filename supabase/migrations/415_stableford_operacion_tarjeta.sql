-- TEE CENTRAL — MIGRACIÓN 415
-- Stableford Individual: información operativa de HCP, ventajas y puntos por hoyo.
-- IMPORTANTE: ejecutar manualmente en Supabase SQL Editor.
-- No modifica ningún motor distinto de Stableford Individual.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_operacion_stableford_tarjeta_415(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_guard jsonb;
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
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_score_card_id IS NULL THEN
        RAISE EXCEPTION 'score_card_id es obligatorio.' USING ERRCODE='22023';
    END IF;

    -- Reutiliza el guard de lectura vigente de la tarjeta. No abre permisos nuevos.
    v_guard := public.obtener_detalle_captura_tarjeta_score(p_score_card_id);

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
        RAISE EXCEPTION 'La consulta 415 corresponde únicamente a Stableford Individual.'
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
        RAISE EXCEPTION 'La consulta 415 corresponde únicamente a Stableford Individual.'
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
                            ELSE public.calcular_puntos_stableford_estandar(
                                     h.digital_gross_score,
                                     h.par
                                 )
                        END
                    ELSE NULL
                END AS digital_gross_points,
                CASE
                    WHEN h.digital_result_type='PICKUP' THEN 0
                    WHEN h.digital_result_type='SCORE' AND h.digital_gross_score IS NOT NULL THEN
                        CASE
                            WHEN h.digital_gross_score=1 AND v_hio_points IS NOT NULL THEN v_hio_points
                            ELSE public.calcular_puntos_stableford_estandar(
                                     h.digital_gross_score-h.handicap_strokes,
                                     h.par
                                 )
                        END
                    ELSE NULL
                END AS digital_net_points,
                CASE
                    WHEN h.physical_result_type='PICKUP' THEN 0
                    WHEN h.physical_result_type='SCORE' AND h.physical_gross_score IS NOT NULL THEN
                        CASE
                            WHEN h.physical_gross_score=1 AND v_hio_points IS NOT NULL THEN v_hio_points
                            ELSE public.calcular_puntos_stableford_estandar(
                                     h.physical_gross_score,
                                     h.par
                                 )
                        END
                    ELSE NULL
                END AS physical_gross_points,
                CASE
                    WHEN h.physical_result_type='PICKUP' THEN 0
                    WHEN h.physical_result_type='SCORE' AND h.physical_gross_score IS NOT NULL THEN
                        CASE
                            WHEN h.physical_gross_score=1 AND v_hio_points IS NOT NULL THEN v_hio_points
                            ELSE public.calcular_puntos_stableford_estandar(
                                     h.physical_gross_score-h.handicap_strokes,
                                     h.par
                                 )
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
                        'digitalNetPoints',s.digital_net_points,
                        'physicalResultType',COALESCE(s.physical_result_type,'PENDING'),
                        'physicalGrossScore',s.physical_gross_score,
                        'physicalGrossPoints',s.physical_gross_points,
                        'physicalNetPoints',s.physical_net_points
                    )
                    ORDER BY s.play_sequence,s.hole_number
                )
                FROM scored s
            ),'[]'::jsonb)
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_operacion_stableford_tarjeta_415(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_operacion_stableford_tarjeta_415(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_operacion_stableford_tarjeta_415(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_operacion_stableford_tarjeta_415(uuid) TO service_role;

COMMIT;
