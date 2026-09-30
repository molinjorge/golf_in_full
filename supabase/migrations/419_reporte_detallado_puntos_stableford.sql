-- TEE CENTRAL
-- Migración 419 — Reporte detallado de puntos Stableford Individual
-- Ejecutar manualmente en Supabase.
-- Aditiva. No modifica Stroke Play, Best Ball ni A-Go-Go.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_reporte_detallado_scores_stableford_419(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid,
    p_criterio text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_round record;
    v_results jsonb;
    v_leaderboard jsonb;
    v_category jsonb;
    v_criterion text;
    v_gross_enabled boolean := false;
    v_net_enabled boolean := false;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL OR p_tournament_category_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id y tournament_category_id son obligatorios.'
            USING ERRCODE='22023';
    END IF;

    SELECT tr.id,tr.tournament_id,tr.numero_ronda,tr.fecha,
           t.nombre AS tournament_name,
           rcs.scoring_engine::text AS scoring_engine,
           rcs.participation_type::text AS participation_type
      INTO v_round
      FROM public.tournament_rounds tr
      JOIN public.tournaments t ON t.id=tr.tournament_id
      LEFT JOIN LATERAL (
          SELECT x.scoring_engine,x.participation_type
          FROM public.tournament_round_condition_snapshots x
          WHERE x.tournament_round_id=tr.id
          ORDER BY x.created_at DESC,x.id DESC
          LIMIT 1
      ) rcs ON true
     WHERE tr.id=p_tournament_round_id
     LIMIT 1;

    IF v_round.id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.' USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_round.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para consultar este reporte.'
            USING ERRCODE='42501';
    END IF;

    IF lower(COALESCE(v_round.scoring_engine,'')) <> 'stableford'
       OR lower(COALESCE(v_round.participation_type,'')) <> 'individual' THEN
        RAISE EXCEPTION
          'La migración 419 soporta únicamente Stableford Individual. Modalidad recibida: scoring_engine=%, participation_type=%.',
          COALESCE(v_round.scoring_engine,'NULL'),COALESCE(v_round.participation_type,'NULL')
          USING ERRCODE='0A000';
    END IF;

    -- Fuentes oficiales existentes: no se reproducen reglas Stableford ni desempates.
    v_results := public.obtener_resultados_stableford_oficiales_ronda(p_tournament_round_id);
    v_leaderboard := public.obtener_leaderboard_stableford_ronda(p_tournament_round_id);

    SELECT c INTO v_category
      FROM jsonb_array_elements(COALESCE(v_leaderboard->'categories','[]'::jsonb)) c
     WHERE NULLIF(c->>'tournamentCategoryId','')::uuid=p_tournament_category_id
     LIMIT 1;

    IF v_category IS NULL THEN
        RAISE EXCEPTION 'La categoría indicada no pertenece al leaderboard Stableford de esta ronda.'
            USING ERRCODE='22023';
    END IF;

    SELECT EXISTS(
        SELECT 1 FROM jsonb_array_elements(COALESCE(v_category->'players','[]'::jsonb)) p
        WHERE COALESCE((p#>>'{gross,enabled}')::boolean,false)
    ), EXISTS(
        SELECT 1 FROM jsonb_array_elements(COALESCE(v_category->'players','[]'::jsonb)) p
        WHERE COALESCE((p#>>'{net,enabled}')::boolean,false)
    )
    INTO v_gross_enabled,v_net_enabled;

    v_criterion:=upper(btrim(COALESCE(p_criterio,'')));
    IF v_criterion IN ('NET','NETO') THEN v_criterion:='NETO';
    ELSIF v_criterion='GROSS' THEN v_criterion:='GROSS';
    ELSIF v_criterion='' THEN
        IF v_gross_enabled AND NOT v_net_enabled THEN v_criterion:='GROSS';
        ELSIF v_net_enabled AND NOT v_gross_enabled THEN v_criterion:='NETO';
        ELSIF v_gross_enabled AND v_net_enabled THEN
            RAISE EXCEPTION 'La categoría clasifica GROSS y NETO; indica p_criterio=GROSS o NETO.'
                USING ERRCODE='22023';
        ELSE
            RAISE EXCEPTION 'La categoría no tiene clasificación Stableford GROSS/NETO habilitada.'
                USING ERRCODE='23514';
        END IF;
    ELSE
        RAISE EXCEPTION 'Criterio inválido. Usa GROSS o NETO.' USING ERRCODE='22023';
    END IF;

    IF v_criterion='GROSS' AND NOT v_gross_enabled THEN
        RAISE EXCEPTION 'La categoría no tiene clasificación GROSS habilitada.' USING ERRCODE='23514';
    END IF;
    IF v_criterion='NETO' AND NOT v_net_enabled THEN
        RAISE EXCEPTION 'La categoría no tiene clasificación NETO habilitada.' USING ERRCODE='23514';
    END IF;

    RETURN (
      WITH lb_players AS (
        SELECT p AS lb,
               NULLIF(p->>'scoreCardId','')::uuid AS score_card_id,
               NULLIF(p->>'playerId','')::uuid AS player_id,
               p->>'playerName' AS player_name,
               NULLIF(p->>'playingHandicap','')::integer AS playing_handicap,
               p->>'competitionStatus' AS competition_status,
               p->>'outcomeReason' AS outcome_reason,
               CASE WHEN v_criterion='GROSS'
                    THEN NULLIF(p#>>'{gross,points}','')::integer
                    ELSE NULLIF(p#>>'{net,points}','')::integer END AS leaderboard_points,
               CASE WHEN v_criterion='GROSS'
                    THEN NULLIF(p#>>'{gross,baseRank}','')::integer
                    ELSE NULLIF(p#>>'{net,baseRank}','')::integer END AS base_rank,
               CASE WHEN v_criterion='GROSS'
                    THEN NULLIF(p#>>'{gross,tieSize}','')::integer
                    ELSE NULLIF(p#>>'{net,tieSize}','')::integer END AS tie_size,
               CASE WHEN v_criterion='GROSS'
                    THEN NULLIF(p#>>'{gross,finalRank}','')::integer
                    ELSE NULLIF(p#>>'{net,finalRank}','')::integer END AS final_rank,
               CASE WHEN v_criterion='GROSS'
                    THEN p#>>'{gross,tiebreakStatus}'
                    ELSE p#>>'{net,tiebreakStatus}' END AS tiebreak_status,
               CASE WHEN v_criterion='GROSS'
                    THEN p#>>'{gross,tiebreakMethodCode}'
                    ELSE p#>>'{net,tiebreakMethodCode}' END AS tiebreak_method_code,
               CASE WHEN v_criterion='GROSS'
                    THEN p#>>'{gross,tiebreakMethodName}'
                    ELSE p#>>'{net,tiebreakMethodName}' END AS tiebreak_method_name
          FROM jsonb_array_elements(COALESCE(v_category->'players','[]'::jsonb)) p
      ),
      official_cards AS (
        SELECT c AS card,
               NULLIF(c->>'scoreCardId','')::uuid AS score_card_id,
               NULLIF(c->>'cardNumber','')::integer AS card_number,
               c->>'cardFolio' AS card_folio,
               NULLIF(c->>'playerId','')::uuid AS player_id,
               c->>'playerName' AS player_name,
               NULLIF(c->>'playingHandicap','')::integer AS playing_handicap,
               COALESCE((c->>'ready')::boolean,false) AS official_ready,
               c->>'competitionStatus' AS result_status,
               NULLIF(c->>'grossPointsTotal','')::integer AS gross_points_total,
               NULLIF(c->>'netPointsTotal','')::integer AS net_points_total,
               COALESCE(c->'holes','[]'::jsonb) AS holes
          FROM jsonb_array_elements(COALESCE(v_results->'cards','[]'::jsonb)) c
         WHERE NULLIF(c->>'tournamentCategoryId','')::uuid=p_tournament_category_id
      ),
      frozen_handicaps AS (
        SELECT sc.id AS score_card_id,
               hs.handicap_index AS declared_handicap,
               hs.handicap_source,
               hs.handicap_source_date,
               hs.handicap_status
          FROM public.tournament_score_cards sc
          JOIN public.tournament_round_start_validation_units u
            ON u.id=sc.validation_unit_id AND u.validation_id=sc.validation_id
          JOIN public.tournament_handicap_snapshots hs ON hs.id=u.handicap_snapshot_id
         WHERE sc.tournament_round_id=p_tournament_round_id
           AND sc.status='issued'
      ),
      assembled AS (
        SELECT lb.score_card_id,oc.card_number,oc.card_folio,
               COALESCE(lb.player_id,oc.player_id) AS player_id,
               COALESCE(lb.player_name,oc.player_name) AS player_name,
               fh.declared_handicap,fh.handicap_source,fh.handicap_source_date,fh.handicap_status,
               COALESCE(lb.playing_handicap,oc.playing_handicap) AS playing_handicap,
               lb.competition_status,lb.outcome_reason,
               oc.official_ready,oc.result_status,
               lb.leaderboard_points,lb.base_rank,lb.tie_size,lb.final_rank,
               lb.tiebreak_status,lb.tiebreak_method_code,lb.tiebreak_method_name,
               oc.gross_points_total,oc.net_points_total,oc.holes,
               (SELECT sum(NULLIF(h->>'grossPoints','')::integer)
                  FROM jsonb_array_elements(oc.holes) h
                 WHERE NULLIF(h->>'holeNumber','')::integer BETWEEN 1 AND 9)::integer AS gross_out,
               (SELECT sum(NULLIF(h->>'grossPoints','')::integer)
                  FROM jsonb_array_elements(oc.holes) h
                 WHERE NULLIF(h->>'holeNumber','')::integer BETWEEN 10 AND 18)::integer AS gross_in,
               (SELECT sum(NULLIF(h->>'netPoints','')::integer)
                  FROM jsonb_array_elements(oc.holes) h
                 WHERE NULLIF(h->>'holeNumber','')::integer BETWEEN 1 AND 9)::integer AS net_out,
               (SELECT sum(NULLIF(h->>'netPoints','')::integer)
                  FROM jsonb_array_elements(oc.holes) h
                 WHERE NULLIF(h->>'holeNumber','')::integer BETWEEN 10 AND 18)::integer AS net_in
          FROM lb_players lb
          LEFT JOIN official_cards oc ON oc.score_card_id=lb.score_card_id
          LEFT JOIN frozen_handicaps fh ON fh.score_card_id=lb.score_card_id
      ),
      ordered AS (
        SELECT a.*,
               COALESCE(a.final_rank,a.base_rank) AS official_position,
               row_number() OVER (
                 ORDER BY CASE WHEN COALESCE(a.final_rank,a.base_rank) IS NULL THEN 1 ELSE 0 END,
                          COALESCE(a.final_rank,a.base_rank) NULLS LAST,
                          a.card_number NULLS LAST,a.player_name
               )::integer AS display_order
          FROM assembled a
      )
      SELECT jsonb_build_object(
        'schemaVersion',1,
        'reportType','DETAILED_POINTS_STABLEFORD',
        'source','OFFICIAL_STABLEFORD_RESULTS',
        'round',jsonb_build_object(
          'tournamentId',v_round.tournament_id,
          'tournamentName',v_round.tournament_name,
          'tournamentRoundId',v_round.id,
          'roundNumber',v_round.numero_ronda,
          'roundDate',v_round.fecha,
          'scoringEngine',v_round.scoring_engine,
          'participationType',v_round.participation_type
        ),
        'category',jsonb_build_object(
          'tournamentCategoryId',p_tournament_category_id,
          'categoryCode',v_category->>'categoryCode',
          'categoryName',v_category->>'categoryName',
          'categoryDisplayOrder',NULLIF(v_category->>'categoryDisplayOrder','')::integer,
          'grossEnabled',v_gross_enabled,
          'netEnabled',v_net_enabled
        ),
        'orderCriterion',v_criterion,
        'metrics',jsonb_build_object('gross',v_gross_enabled,'net',v_net_enabled),
        'players',COALESCE((
          SELECT jsonb_agg(
            jsonb_build_object(
              'displayOrder',o.display_order,
              'officialPosition',o.official_position,
              'baseRank',o.base_rank,
              'tieSize',o.tie_size,
              'finalRank',o.final_rank,
              'tiebreakStatus',o.tiebreak_status,
              'tiebreakMethodCode',o.tiebreak_method_code,
              'tiebreakMethodName',o.tiebreak_method_name,
              'scoreCardId',o.score_card_id,
              'cardFolio',o.card_folio,
              'playerId',o.player_id,
              'playerName',o.player_name,
              'declaredHandicap',o.declared_handicap,
              'handicapSource',o.handicap_source,
              'handicapSourceDate',o.handicap_source_date,
              'handicapStatus',o.handicap_status,
              'playingHandicap',o.playing_handicap,
              'competitionStatus',o.competition_status,
              'outcomeReason',o.outcome_reason,
              'officialReady',o.official_ready,
              'resultStatus',o.result_status,
              'gross',jsonb_build_object('out',o.gross_out,'in',o.gross_in,'total',o.gross_points_total),
              'net',jsonb_build_object('out',o.net_out,'in',o.net_in,'total',o.net_points_total),
              'leaderboardPoints',o.leaderboard_points,
              'holes',o.holes
            ) ORDER BY o.display_order
          ) FROM ordered o
        ),'[]'::jsonb)
      )
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_reporte_detallado_scores_stableford_419(uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_reporte_detallado_scores_stableford_419(uuid,uuid,text) TO authenticated;

COMMIT;
