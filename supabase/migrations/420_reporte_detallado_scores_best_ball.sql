-- TEE CENTRAL
-- Migración 420 — Reporte detallado de scores Best Ball TEAM
-- Ejecutar manualmente en Supabase.
-- Aditiva. No modifica Stroke Play, Stableford ni A-Go-Go.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_reporte_detallado_scores_best_ball_420(
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
    v_lb jsonb;
    v_category jsonb;
    v_round jsonb;
    v_tournament_id uuid;
    v_criterion text;
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

    -- F14/F11 existentes son la autoridad deportiva.
    v_lb := public.obtener_leaderboard_best_ball_ronda_328(p_tournament_round_id);
    v_round := v_lb->'round';
    v_tournament_id := NULLIF(v_round->>'tournamentId','')::uuid;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'No fue posible identificar el torneo Best Ball de la ronda.'
            USING ERRCODE='55000';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para consultar este reporte.'
            USING ERRCODE='42501';
    END IF;

    IF lower(COALESCE(v_round->>'scoringEngine','')) <> 'best_ball'
       OR lower(COALESCE(v_round->>'participationType','')) NOT IN ('equipo','team') THEN
        RAISE EXCEPTION 'La ronda indicada no corresponde a Best Ball TEAM.'
            USING ERRCODE='0A000';
    END IF;

    SELECT c INTO v_category
    FROM jsonb_array_elements(COALESCE(v_lb->'categories','[]'::jsonb)) c
    WHERE NULLIF(c->>'tournamentCategoryId','')::uuid=p_tournament_category_id
    LIMIT 1;

    IF v_category IS NULL THEN
        RAISE EXCEPTION 'La categoría indicada no pertenece al leaderboard Best Ball de esta ronda.'
            USING ERRCODE='22023';
    END IF;

    v_gross_enabled := COALESCE((v_category#>>'{classifications,gross}')::boolean,false);
    v_net_enabled := COALESCE((v_category#>>'{classifications,net}')::boolean,false);

    v_criterion := upper(btrim(COALESCE(p_criterio,'')));
    IF v_criterion IN ('NET','NETO') THEN v_criterion:='NETO';
    ELSIF v_criterion='GROSS' THEN v_criterion:='GROSS';
    ELSIF v_criterion='' THEN
        IF v_gross_enabled AND NOT v_net_enabled THEN v_criterion:='GROSS';
        ELSIF v_net_enabled AND NOT v_gross_enabled THEN v_criterion:='NETO';
        ELSIF v_gross_enabled AND v_net_enabled THEN
            RAISE EXCEPTION 'La categoría clasifica GROSS y NETO; indica p_criterio=GROSS o NETO.'
                USING ERRCODE='22023';
        ELSE
            RAISE EXCEPTION 'La categoría no tiene clasificación Best Ball GROSS/NETO habilitada.'
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
      WITH lb_teams AS (
        SELECT t AS lb,
               NULLIF(t->>'scoreCardId','')::uuid score_card_id,
               NULLIF(t->>'tournamentTeamId','')::uuid tournament_team_id,
               t->>'teamName' team_name,
               t->>'cardFolio' card_folio,
               t->>'competitionStatus' competition_status,
               CASE WHEN v_criterion='GROSS'
                    THEN NULLIF(t#>>'{gross,total}','')::integer
                    ELSE NULLIF(t#>>'{net,total}','')::integer END metric_total,
               CASE WHEN v_criterion='GROSS'
                    THEN NULLIF(t#>>'{gross,rank}','')::integer
                    ELSE NULLIF(t#>>'{net,rank}','')::integer END base_rank,
               CASE WHEN v_criterion='GROSS'
                    THEN COALESCE((t#>>'{gross,tied}')::boolean,false)
                    ELSE COALESCE((t#>>'{net,tied}')::boolean,false) END tied,
               CASE WHEN v_criterion='GROSS'
                    THEN NULLIF(t#>>'{gross,tieCount}','')::integer
                    ELSE NULLIF(t#>>'{net,tieCount}','')::integer END tie_count
        FROM jsonb_array_elements(COALESCE(v_category->'teams','[]'::jsonb)) t
      ),
      official AS (
        SELECT l.*,public.obtener_resultado_oficial_best_ball_325(l.score_card_id) result
        FROM lb_teams l
        WHERE l.score_card_id IS NOT NULL
      ),
      team_snapshot AS (
        SELECT ss.score_card_id,ss.id snapshot_id,ss.team_name
        FROM public.tournament_best_ball_scorecard_snapshots ss
        JOIN public.tournament_score_cards sc ON sc.id=ss.score_card_id
        WHERE sc.tournament_round_id=p_tournament_round_id
          AND sc.tournament_category_id=p_tournament_category_id
          AND sc.status='issued'
      ),
      members AS (
        SELECT ts.score_card_id,
               jsonb_agg(jsonb_build_object(
                   'bestBallScorecardMemberId',bm.id,
                   'memberOrder',bm.member_order,
                   'playerId',bm.player_id,
                   'tournamentRegistrationId',bm.tournament_registration_id,
                   'playerName',hs.player_name,
                   'declaredHandicap',hs.handicap_index,
                   'handicapSource',hs.handicap_source,
                   'handicapSourceDate',hs.handicap_source_date,
                   'handicapStatus',hs.handicap_status,
                   'playingHandicap',rhs.playing_handicap
               ) ORDER BY bm.member_order,bm.player_id) team_members
        FROM team_snapshot ts
        JOIN public.tournament_best_ball_scorecard_members bm
          ON bm.best_ball_scorecard_snapshot_id=ts.snapshot_id
        LEFT JOIN public.tournament_round_handicap_snapshots rhs
          ON rhs.id=bm.round_handicap_snapshot_id
        LEFT JOIN public.tournament_handicap_snapshots hs
          ON hs.id=rhs.handicap_snapshot_id
        GROUP BY ts.score_card_id
      ),
      tiebreaks AS (
        SELECT NULLIF(c->>'tournamentCategoryId','')::uuid category_id,
               c
        FROM jsonb_array_elements(COALESCE(
          public.obtener_desempates_best_ball_ronda_327(p_tournament_round_id)->'categories',
          '[]'::jsonb
        )) c
      ),
      enriched AS (
        SELECT o.*,
               m.team_members,
               COALESCE(o.result->'holes','[]'::jsonb) holes,
               NULLIF(o.result#>>'{officialTotals,gross}','')::integer gross_total,
               NULLIF(o.result#>>'{officialTotals,net}','')::integer net_total,
               tb.c tiebreak_category
        FROM official o
        LEFT JOIN members m ON m.score_card_id=o.score_card_id
        LEFT JOIN tiebreaks tb ON tb.category_id=p_tournament_category_id
      ),
      calculated AS (
        SELECT e.*,
          (SELECT sum(NULLIF(h->>'officialBestGross','')::integer)
           FROM jsonb_array_elements(e.holes) h
           WHERE NULLIF(h->>'holeNumber','')::integer BETWEEN 1 AND 9)::integer gross_out,
          (SELECT sum(NULLIF(h->>'officialBestGross','')::integer)
           FROM jsonb_array_elements(e.holes) h
           WHERE NULLIF(h->>'holeNumber','')::integer BETWEEN 10 AND 18)::integer gross_in,
          (SELECT sum(NULLIF(h->>'officialBestNet','')::integer)
           FROM jsonb_array_elements(e.holes) h
           WHERE NULLIF(h->>'holeNumber','')::integer BETWEEN 1 AND 9)::integer net_out,
          (SELECT sum(NULLIF(h->>'officialBestNet','')::integer)
           FROM jsonb_array_elements(e.holes) h
           WHERE NULLIF(h->>'holeNumber','')::integer BETWEEN 10 AND 18)::integer net_in
        FROM enriched e
      ),
      ranked AS (
        SELECT c.*,
               -- F14 entrega el rank base. F13 conserva la evidencia de desempate.
               -- No se inventa una posición final si el desempate sigue pendiente.
               c.base_rank official_position,
               row_number() OVER (
                 ORDER BY c.base_rank NULLS LAST,c.metric_total NULLS LAST,c.team_name,c.card_folio
               )::integer display_order
        FROM calculated c
      )
      SELECT jsonb_build_object(
        'schemaVersion',1,
        'reportType','DETAILED_SCORES_BEST_BALL',
        'source','OFFICIAL_BEST_BALL_RESULTS',
        'round',v_round,
        'category',jsonb_build_object(
          'tournamentCategoryId',p_tournament_category_id,
          'categoryCode',v_category->>'categoryCode',
          'categoryName',v_category->>'categoryName',
          'categoryDisplayOrder',NULLIF(v_category->>'categoryDisplayOrder','')::integer,
          'grossEnabled',v_gross_enabled,
          'netEnabled',v_net_enabled
        ),
        'competitiveUnit','TEAM',
        'orderCriterion',v_criterion,
        'teams',COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'displayOrder',r.display_order,
            'officialPosition',r.official_position,
            'baseRank',r.base_rank,
            'tied',r.tied,
            'tieCount',r.tie_count,
            'competitionStatus',r.competition_status,
            'scoreCardId',r.score_card_id,
            'tournamentTeamId',r.tournament_team_id,
            'teamName',r.team_name,
            'cardFolio',r.card_folio,
            'members',COALESCE(r.team_members,'[]'::jsonb),
            'gross',jsonb_build_object('out',r.gross_out,'in',r.gross_in,'total',r.gross_total),
            'net',jsonb_build_object('out',r.net_out,'in',r.net_in,'total',r.net_total),
            'metricTotal',r.metric_total,
            'holes',r.holes,
            'tiebreakEvidence',r.tiebreak_category
          ) ORDER BY r.display_order)
          FROM ranked r
        ),'[]'::jsonb)
      )
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_reporte_detallado_scores_best_ball_420(uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_reporte_detallado_scores_best_ball_420(uuid,uuid,text) TO authenticated;

COMMIT;
