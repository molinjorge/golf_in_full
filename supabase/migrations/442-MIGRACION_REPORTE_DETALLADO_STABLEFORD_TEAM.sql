-- 442-MIGRACION_REPORTE_DETALLADO_STABLEFORD_TEAM.sql
-- TEE CENTRAL / GOLF IN FULL
-- Objetivo:
--   Crear una RPC consolidada para el reporte individual hoyo por hoyo de
--   Stableford por equipos, sin llamadas N×tarjeta desde el frontend.
--
-- Principios:
--   1) SOLO reporte. No modifica motor 434/438, leaderboard, cierres ni publicación.
--   2) Usa exclusivamente snapshots congelados y evidencia oficial conciliada.
--   3) Reutiliza las funciones canónicas:
--        calcular_golpes_handicap_hoyo
--        calcular_puntos_stableford_estandar
--   4) Conserva SCORE/PICKUP. No inventa SIN SCORE, PICKUP ni outcomes.
--   5) Los outcomes se exponen; no se reinterpretan como resultados deportivos.
--   6) Una llamada cliente por ronda/categoría/criterio.
--
-- IMPORTANTE:
--   Esta migración NO corrige la discrepancia preexistente del motor 434 respecto
--   de SIN SCORE intermedio. El reporte replica el contrato competitivo instalado.
--
-- EJECUCIÓN: manual por el usuario.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_reporte_detallado_scores_stableford_team_442(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid,
    p_criterio text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_round record;
    v_rcs record;
    v_engine record;
    v_criterio text;
    v_holes_count integer;
    v_distinct_si integer;
    v_min_si integer;
    v_max_si integer;
    v_category_exists boolean;
    v_gross_enabled boolean;
    v_net_enabled boolean;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL OR p_tournament_category_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id y tournament_category_id son obligatorios.'
            USING ERRCODE='22023';
    END IF;

    v_criterio := upper(btrim(coalesce(p_criterio,'')));
    IF v_criterio NOT IN ('GROSS','NETO') THEN
        RAISE EXCEPTION 'criterio debe ser GROSS o NETO.' USING ERRCODE='22023';
    END IF;

    SELECT tr.id, tr.tournament_id, tr.numero_ronda, tr.fecha
      INTO v_round
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id
       AND tr.activo=true
     LIMIT 1;

    IF v_round.id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe o no está activa.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_round.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para consultar este reporte.'
            USING ERRCODE='42501';
    END IF;

    SELECT rcs.id, rcs.freeze_id, rcs.scoring_engine, rcs.participation_type
      INTO v_rcs
      FROM public.tournament_round_condition_snapshots rcs
     WHERE rcs.tournament_round_id=p_tournament_round_id
     ORDER BY rcs.created_at DESC, rcs.id DESC
     LIMIT 1;

    IF v_rcs.id IS NULL
       OR v_rcs.scoring_engine<>'stableford'
       OR v_rcs.participation_type<>'equipo'
    THEN
        RAISE EXCEPTION 'La ronda indicada no corresponde a Stableford por equipos.'
            USING ERRCODE='0A000';
    END IF;

    SELECT EXISTS(
        SELECT 1
          FROM public.tournament_categories tc
         WHERE tc.id=p_tournament_category_id
           AND tc.tournament_id=v_round.tournament_id
    ) INTO v_category_exists;

    IF NOT v_category_exists THEN
        RAISE EXCEPTION 'La categoría indicada no pertenece al torneo.'
            USING ERRCODE='22023';
    END IF;

    SELECT e.id, e.engine_version, e.points_table_version,
           e.target_score_basis, e.minimum_points, e.maximum_points, e.pickup_points
      INTO v_engine
      FROM public.tournament_stableford_engine_snapshots e
     WHERE e.freeze_id=v_rcs.freeze_id
       AND e.tournament_round_id=p_tournament_round_id
     LIMIT 1;

    IF v_engine.id IS NULL THEN
        RAISE EXCEPTION 'La ronda Stableford no tiene snapshot de versión del motor.'
            USING ERRCODE='55000';
    END IF;

    SELECT count(*), count(DISTINCT rh.stroke_index), min(rh.stroke_index), max(rh.stroke_index)
      INTO v_holes_count, v_distinct_si, v_min_si, v_max_si
      FROM public.tournament_round_hole_snapshots rh
     WHERE rh.tournament_round_id=p_tournament_round_id;

    IF v_holes_count<=0
       OR v_distinct_si<>v_holes_count
       OR v_min_si<>1
       OR v_max_si<>v_holes_count
    THEN
        RAISE EXCEPTION 'El Stroke Index congelado no forma una secuencia completa 1..N.'
            USING ERRCODE='55000';
    END IF;

    SELECT
        EXISTS(
            SELECT 1
              FROM public.tournament_category_classification_snapshots s
             WHERE s.freeze_id=v_rcs.freeze_id
               AND s.tournament_category_id=p_tournament_category_id
               AND s.tipo_resultado::text='gross'
        ),
        EXISTS(
            SELECT 1
              FROM public.tournament_category_classification_snapshots s
             WHERE s.freeze_id=v_rcs.freeze_id
               AND s.tournament_category_id=p_tournament_category_id
               AND s.tipo_resultado::text='neto'
        )
      INTO v_gross_enabled, v_net_enabled;

    IF v_criterio='GROSS' AND NOT v_gross_enabled THEN
        RAISE EXCEPTION 'La categoría no tiene clasificación GROSS configurada.'
            USING ERRCODE='22023';
    END IF;
    IF v_criterio='NETO' AND NOT v_net_enabled THEN
        RAISE EXCEPTION 'La categoría no tiene clasificación NETO configurada.'
            USING ERRCODE='22023';
    END IF;

    RETURN (
      WITH cards AS (
        SELECT
            sc.id AS score_card_id,
            sc.card_number,
            sc.card_folio,
            sc.player_id,
            u.unit_name AS player_name,
            sc.tournament_registration_id,
            coalesce(u.tournament_team_id,sc.tournament_team_id) AS tournament_team_id,
            tt.nombre_equipo AS team_name,
            u.tournament_category_id,
            hs.handicap_index,
            hs.tee_id,
            hs.tee_name,
            rhs.id AS round_handicap_snapshot_id,
            rhs.playing_handicap,
            rhs.freeze_id,
            o.outcome_code,
            o.reason AS outcome_reason,
            o.effective_through_round_hole_snapshot_id,
            pr.status AS physical_status,
            rec.status AS reconciliation_status,
            sr.points AS hio_points
        FROM public.tournament_score_cards sc
        JOIN public.tournament_round_start_validation_units u
          ON u.id=sc.validation_unit_id
         AND u.validation_id=sc.validation_id
        JOIN public.tournament_teams tt
          ON tt.id=coalesce(u.tournament_team_id,sc.tournament_team_id)
         AND tt.tournament_id=v_round.tournament_id
        JOIN public.tournament_handicap_snapshots hs
          ON hs.id=u.handicap_snapshot_id
        JOIN public.tournament_round_handicap_snapshots rhs
          ON rhs.id=u.round_handicap_snapshot_id
        LEFT JOIN public.tournament_scorecard_round_outcomes o
          ON o.score_card_id=sc.id
        LEFT JOIN public.tournament_scorecard_physical_receptions pr
          ON pr.score_card_id=sc.id
        LEFT JOIN public.tournament_scorecard_reconciliations rec
          ON rec.score_card_id=sc.id
        LEFT JOIN public.tournament_stableford_special_rule_snapshots sr
          ON sr.freeze_id=rhs.freeze_id
         AND sr.rule_code='HOLE_IN_ONE_OVERRIDE'
         AND sr.enabled=true
         AND sr.behavior='OVERRIDE'
        WHERE sc.tournament_round_id=p_tournament_round_id
          AND sc.status='issued'
          AND sc.unit_type='registration'
          AND u.tournament_category_id=p_tournament_category_id
          AND coalesce(u.tournament_team_id,sc.tournament_team_id) IS NOT NULL
      ),
      card_counts AS (
        SELECT
            c.score_card_id,
            count(phs.id)::integer AS physical_holes
        FROM cards c
        LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
          ON phs.score_card_id=c.score_card_id
        GROUP BY c.score_card_id
      ),
      card_state AS (
        SELECT
            c.*,
            cc.physical_holes,
            (
                c.physical_status='CAPTURED'
                AND c.reconciliation_status='COMPLETED'
                AND cc.physical_holes=v_holes_count
            ) AS pipeline_ready
        FROM cards c
        JOIN card_counts cc ON cc.score_card_id=c.score_card_id
      ),
      raw_holes AS (
        SELECT
            c.*,
            rh.id AS round_hole_snapshot_id,
            rh.hole_number,
            coalesce(dhs.play_sequence,phs.play_sequence,rh.hole_number) AS play_sequence,
            rh.par,
            rh.stroke_index,
            CASE WHEN res.id IS NOT NULL
                 THEN res.resolved_result_type
                 ELSE phs.physical_result_type
            END AS official_result_type,
            CASE WHEN res.id IS NOT NULL
                 THEN res.resolved_gross_score
                 ELSE phs.physical_gross_score
            END AS official_gross_score,
            CASE WHEN res.id IS NOT NULL
                 THEN res.resolution_source
                 WHEN phs.id IS NOT NULL THEN 'PHYSICAL'
                 ELSE NULL
            END AS official_source,
            public.calcular_golpes_handicap_hoyo(
                c.playing_handicap,
                rh.stroke_index,
                v_holes_count
            ) AS handicap_strokes
        FROM card_state c
        CROSS JOIN public.tournament_round_hole_snapshots rh
        LEFT JOIN public.tournament_scorecard_hole_scores dhs
          ON dhs.score_card_id=c.score_card_id
         AND dhs.round_hole_snapshot_id=rh.id
        LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
          ON phs.score_card_id=c.score_card_id
         AND phs.round_hole_snapshot_id=rh.id
        LEFT JOIN public.tournament_scorecard_hole_resolutions res
          ON res.score_card_id=c.score_card_id
         AND res.round_hole_snapshot_id=rh.id
        WHERE rh.tournament_round_id=p_tournament_round_id
      ),
      validated AS (
        SELECT
            h.*,
            count(*) FILTER (
                WHERE h.official_result_type NOT IN ('SCORE','PICKUP')
                   OR (h.official_result_type='SCORE'
                       AND (h.official_gross_score IS NULL OR h.official_gross_score<=0))
                   OR (h.official_result_type='PICKUP'
                       AND h.official_gross_score IS NOT NULL)
            ) OVER (PARTITION BY h.score_card_id) AS invalid_official_holes,
            sum(h.handicap_strokes) OVER (PARTITION BY h.score_card_id) AS handicap_strokes_total
        FROM raw_holes h
      ),
      calculated AS (
        SELECT
            h.*,
            (
                h.pipeline_ready
                AND h.invalid_official_holes=0
                AND h.handicap_strokes_total=h.playing_handicap
            ) AS official_ready,
            CASE
                WHEN h.pipeline_ready AND h.invalid_official_holes=0
                 AND h.handicap_strokes_total=h.playing_handicap
                 AND h.official_result_type='PICKUP' THEN 0
                WHEN h.pipeline_ready AND h.invalid_official_holes=0
                 AND h.handicap_strokes_total=h.playing_handicap
                 AND h.official_result_type='SCORE'
                    THEN public.calcular_puntos_stableford_estandar(
                        h.official_gross_score,h.par
                    )
                ELSE NULL
            END AS gross_points_base,
            CASE
                WHEN h.pipeline_ready AND h.invalid_official_holes=0
                 AND h.handicap_strokes_total=h.playing_handicap
                 AND h.official_result_type='PICKUP' THEN 0
                WHEN h.pipeline_ready AND h.invalid_official_holes=0
                 AND h.handicap_strokes_total=h.playing_handicap
                 AND h.official_result_type='SCORE'
                    THEN public.calcular_puntos_stableford_estandar(
                        h.official_gross_score-h.handicap_strokes,h.par
                    )
                ELSE NULL
            END AS net_points_base,
            (
                h.pipeline_ready
                AND h.invalid_official_holes=0
                AND h.handicap_strokes_total=h.playing_handicap
                AND h.official_result_type='SCORE'
                AND h.official_gross_score=1
                AND h.hio_points IS NOT NULL
            ) AS hio_override_applied
        FROM validated h
      ),
      final_holes AS (
        SELECT
            c.*,
            CASE WHEN c.hio_override_applied THEN c.hio_points
                 ELSE c.gross_points_base END AS gross_points,
            CASE WHEN c.hio_override_applied THEN c.hio_points
                 ELSE c.net_points_base END AS net_points,
            CASE WHEN c.official_ready AND c.official_result_type='SCORE'
                 THEN c.official_gross_score-c.handicap_strokes
                 ELSE NULL END AS official_net_score,
            CASE
                WHEN c.outcome_code IN ('DNS','DQ','NO_CARD') THEN false
                WHEN c.outcome_code IN ('WD','DNF') THEN
                    c.effective_through_round_hole_snapshot_id IS NOT NULL
                    AND c.play_sequence <= (
                        SELECT bx.play_sequence
                          FROM raw_holes bx
                         WHERE bx.score_card_id=c.score_card_id
                           AND bx.round_hole_snapshot_id=c.effective_through_round_hole_snapshot_id
                         LIMIT 1
                    )
                ELSE true
            END AS outcome_eligible
        FROM calculated c
      ),
      player_rows AS (
        SELECT
            f.score_card_id,
            min(f.card_number) AS card_number,
            min(f.card_folio) AS card_folio,
            (array_agg(f.player_id))[1] AS player_id,
            min(f.player_name) AS player_name,
            (array_agg(f.tournament_registration_id))[1] AS tournament_registration_id,
            (array_agg(f.tournament_team_id))[1] AS tournament_team_id,
            min(f.team_name) AS team_name,
            min(f.handicap_index) AS handicap_index,
            (array_agg(f.tee_id))[1] AS tee_id,
            min(f.tee_name) AS tee_name,
            (array_agg(f.round_handicap_snapshot_id))[1] AS round_handicap_snapshot_id,
            min(f.playing_handicap) AS playing_handicap,
            min(f.outcome_code) AS outcome_code,
            min(f.outcome_reason) AS outcome_reason,
            bool_and(f.official_ready) AS official_ready,
            min(f.physical_status) AS physical_status,
            min(f.reconciliation_status) AS reconciliation_status,
            sum(f.gross_points)::integer AS gross_points_total,
            sum(f.net_points)::integer AS net_points_total,
            count(*) FILTER (WHERE f.official_result_type='PICKUP')::integer AS pickup_holes,
            count(*) FILTER (WHERE f.hio_override_applied)::integer AS hio_overrides_applied,
            jsonb_agg(
                jsonb_build_object(
                    'roundHoleSnapshotId',f.round_hole_snapshot_id,
                    'holeNumber',f.hole_number,
                    'playSequence',f.play_sequence,
                    'par',f.par,
                    'strokeIndex',f.stroke_index,
                    'resultType',f.official_result_type,
                    'grossScore',f.official_gross_score,
                    'officialSource',f.official_source,
                    'handicapStrokes',f.handicap_strokes,
                    'netScore',f.official_net_score,
                    'grossPoints',f.gross_points,
                    'netPoints',f.net_points,
                    'selectedPoints',CASE WHEN v_criterio='GROSS'
                                          THEN f.gross_points ELSE f.net_points END,
                    'holeInOneOverrideApplied',f.hio_override_applied,
                    'outcomeEligible',f.outcome_eligible
                )
                ORDER BY f.play_sequence,f.hole_number
            ) AS holes
        FROM final_holes f
        GROUP BY f.score_card_id
      ),
      team_rows AS (
        SELECT
            p.tournament_team_id,
            min(p.team_name) AS team_name,
            count(*)::integer AS players,
            jsonb_agg(
                jsonb_build_object(
                    'scoreCardId',p.score_card_id,
                    'cardNumber',p.card_number,
                    'cardFolio',p.card_folio,
                    'playerId',p.player_id,
                    'playerName',p.player_name,
                    'tournamentRegistrationId',p.tournament_registration_id,
                    'handicapIndex',p.handicap_index,
                    'teeId',p.tee_id,
                    'teeName',p.tee_name,
                    'roundHandicapSnapshotId',p.round_handicap_snapshot_id,
                    'playingHandicap',p.playing_handicap,
                    'competitionStatus',
                        CASE
                            WHEN p.outcome_code IS NOT NULL THEN p.outcome_code
                            WHEN p.official_ready THEN 'OFFICIAL'
                            WHEN p.physical_status IS DISTINCT FROM 'CAPTURED'
                                THEN 'PHYSICAL_PENDING'
                            WHEN p.reconciliation_status IS DISTINCT FROM 'COMPLETED'
                                THEN 'RECONCILIATION_PENDING'
                            ELSE 'NOT_READY'
                        END,
                    'outcomeCode',p.outcome_code,
                    'outcomeReason',p.outcome_reason,
                    'ready',p.official_ready,
                    'grossPointsTotal',p.gross_points_total,
                    'netPointsTotal',p.net_points_total,
                    'selectedPointsTotal',
                        CASE WHEN v_criterio='GROSS'
                             THEN p.gross_points_total ELSE p.net_points_total END,
                    'pickupHoles',p.pickup_holes,
                    'holeInOneOverridesApplied',p.hio_overrides_applied,
                    'holes',p.holes
                )
                ORDER BY p.player_name,p.player_id
            ) AS player_json
        FROM player_rows p
        GROUP BY p.tournament_team_id
      )
      SELECT jsonb_build_object(
        'schemaVersion',1,
        'supported',true,
        'applicable',true,
        'round',jsonb_build_object(
            'tournamentId',v_round.tournament_id,
            'tournamentRoundId',v_round.id,
            'roundNumber',v_round.numero_ronda,
            'roundDate',v_round.fecha,
            'scoringEngine','stableford',
            'participationType','equipo'
        ),
        'category',jsonb_build_object(
            'tournamentCategoryId',p_tournament_category_id
        ),
        'criterion',v_criterio,
        'classification',jsonb_build_object(
            'grossEnabled',v_gross_enabled,
            'netEnabled',v_net_enabled
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
        'summary',jsonb_build_object(
            'teams',(SELECT count(*)::integer FROM team_rows),
            'players',(SELECT count(*)::integer FROM player_rows),
            'readyPlayers',(SELECT count(*)::integer FROM player_rows WHERE official_ready),
            'pendingPlayers',(SELECT count(*)::integer FROM player_rows WHERE NOT official_ready),
            'holesExpected',v_holes_count
        ),
        'teams',coalesce((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'teamId',t.tournament_team_id,
                    'teamName',t.team_name,
                    'playersCount',t.players,
                    'players',t.player_json
                )
                ORDER BY t.team_name,t.tournament_team_id
            )
            FROM team_rows t
        ),'[]'::jsonb)
      )
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_reporte_detallado_scores_stableford_team_442(uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_reporte_detallado_scores_stableford_team_442(uuid,uuid,text) TO authenticated;

COMMENT ON FUNCTION public.obtener_reporte_detallado_scores_stableford_team_442(uuid,uuid,text)
IS 'Reporte consolidado individual hoyo por hoyo para Stableford TEAM. Usa snapshots congelados y evidencia oficial conciliada; no modifica ni sustituye los motores 434/438.';

COMMIT;
