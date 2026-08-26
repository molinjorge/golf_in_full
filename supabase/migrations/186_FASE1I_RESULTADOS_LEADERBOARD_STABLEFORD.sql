-- TEE CENTRAL / GOLF IN FULL
-- Migración 186 Fase 1I
-- Resultados oficiales de ronda + leaderboard Stableford Individual
--
-- No modifica las RPC históricas de Stroke Play.
-- Stableford ordena puntos DESCENDENTE y respeta las clasificaciones
-- Gross/Net congeladas por categoría. Los empates quedan marcados como
-- pendientes; el desempate se implementará en una fase posterior.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_resultados_stableford_oficiales_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_round record;
    v_rcs public.tournament_round_condition_snapshots;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id es obligatorio.' USING ERRCODE='22023';
    END IF;

    SELECT tr.id,tr.tournament_id,tr.numero_ronda,tr.fecha
      INTO v_round
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id
     LIMIT 1;

    IF v_round.id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.' USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_round.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para consultar resultados de esta ronda.'
            USING ERRCODE='42501';
    END IF;

    SELECT * INTO v_rcs
      FROM public.tournament_round_condition_snapshots
     WHERE tournament_round_id=p_tournament_round_id
     ORDER BY created_at DESC,id DESC
     LIMIT 1;

    IF v_rcs.id IS NULL OR v_rcs.scoring_engine<>'stableford' OR v_rcs.participation_type<>'individual' THEN
        RAISE EXCEPTION 'La ronda indicada no corresponde a Stableford Individual.' USING ERRCODE='0A000';
    END IF;

    RETURN (
        WITH cards AS (
            SELECT sc.id AS score_card_id,sc.card_number,sc.card_folio,
                   u.player_id,u.tournament_registration_id,u.tournament_category_id,
                   u.unit_name AS player_name,
                   c.codigo AS category_code,c.nombre AS category_name,c.display_order AS category_display_order,
                   rhs.tee_id,rhs.playing_handicap,
                   COALESCE((SELECT rhts.tee_name FROM public.tournament_round_handicap_tee_snapshots rhts
                             WHERE rhts.round_handicap_snapshot_id=rhs.id AND rhts.tee_id=rhs.tee_id
                             ORDER BY rhts.created_at DESC,rhts.id DESC LIMIT 1),hs.tee_name) AS tee_name,
                   o.outcome_code,o.reason AS outcome_reason
            FROM public.tournament_score_cards sc
            JOIN public.tournament_round_start_validation_units u
              ON u.id=sc.validation_unit_id AND u.validation_id=sc.validation_id
            LEFT JOIN public.tournament_categories tc ON tc.id=u.tournament_category_id
            LEFT JOIN public.categories c ON c.id=tc.category_id
            LEFT JOIN public.tournament_handicap_snapshots hs ON hs.id=u.handicap_snapshot_id
            LEFT JOIN public.tournament_round_handicap_snapshots rhs ON rhs.id=u.round_handicap_snapshot_id
            LEFT JOIN public.tournament_scorecard_round_outcomes o ON o.score_card_id=sc.id
            WHERE sc.tournament_round_id=p_tournament_round_id AND sc.status='issued'
        ),
        evaluated AS (
            SELECT c.*,
                   CASE WHEN c.outcome_code IS NOT NULL THEN false
                        WHEN pr.status='CAPTURED' AND rec.status='COMPLETED' THEN true
                        ELSE false END AS candidate_ready,
                   COALESCE(pr.status,'NOT_RECEIVED') AS physical_status,
                   COALESCE(rec.status,'NOT_STARTED') AS reconciliation_status
            FROM cards c
            LEFT JOIN public.tournament_scorecard_physical_receptions pr ON pr.score_card_id=c.score_card_id
            LEFT JOIN public.tournament_scorecard_reconciliations rec ON rec.score_card_id=c.score_card_id
        ),
        calculated AS (
            SELECT e.*,
                   CASE WHEN e.candidate_ready THEN public.obtener_resultado_stableford_oficial_tarjeta(e.score_card_id) ELSE NULL END AS sf
            FROM evaluated e
        ),
        final AS (
            SELECT x.*,
                   COALESCE((x.sf#>>'{result,ready}')::boolean,false) AS official_ready,
                   NULLIF(x.sf#>>'{result,grossPointsTotal}','')::integer AS gross_points_total,
                   NULLIF(x.sf#>>'{result,netPointsTotal}','')::integer AS net_points_total,
                   COALESCE((x.sf#>>'{classification,grossEnabled}')::boolean,false) AS gross_enabled,
                   COALESCE((x.sf#>>'{classification,netEnabled}')::boolean,false) AS net_enabled,
                   COALESCE(x.sf->'holes','[]'::jsonb) AS holes,
                   CASE WHEN x.outcome_code IS NOT NULL THEN x.outcome_code
                        WHEN COALESCE((x.sf#>>'{result,ready}')::boolean,false) THEN 'OFFICIAL'
                        WHEN x.physical_status<>'CAPTURED' THEN 'PHYSICAL_PENDING'
                        WHEN x.reconciliation_status<>'COMPLETED' THEN 'RECONCILIATION_PENDING'
                        ELSE 'NOT_READY' END AS competition_status
            FROM calculated x
        ),
        summary AS (
            SELECT count(*) total_cards,
                   count(*) FILTER(WHERE official_ready) official_cards,
                   count(*) FILTER(WHERE NOT official_ready AND outcome_code IS NULL) pending_cards,
                   count(*) FILTER(WHERE outcome_code IN ('WD','DNF','DQ','DNS','NO_CARD')) terminal_exceptions
            FROM final
        )
        SELECT jsonb_build_object(
            'round',jsonb_build_object('tournamentId',v_round.tournament_id,'tournamentRoundId',v_round.id,
                                       'roundNumber',v_round.numero_ronda,'roundDate',v_round.fecha,
                                       'scoringEngine','stableford','participationType','individual'),
            'summary',(SELECT jsonb_build_object('totalCards',total_cards,'officialCards',official_cards,
                                                 'pendingCards',pending_cards,'terminalExceptions',terminal_exceptions) FROM summary),
            'cards',COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'scoreCardId',f.score_card_id,'cardNumber',f.card_number,'cardFolio',f.card_folio,
                'playerId',f.player_id,'playerName',f.player_name,
                'tournamentRegistrationId',f.tournament_registration_id,'tournamentCategoryId',f.tournament_category_id,
                'categoryCode',f.category_code,'categoryName',f.category_name,'categoryDisplayOrder',f.category_display_order,
                'teeId',f.tee_id,'teeName',f.tee_name,'playingHandicap',f.playing_handicap,
                'competitionStatus',f.competition_status,'outcomeReason',f.outcome_reason,
                'ready',f.official_ready,'grossEnabled',f.gross_enabled,'netEnabled',f.net_enabled,
                'grossPointsTotal',f.gross_points_total,'netPointsTotal',f.net_points_total,'holes',f.holes
            ) ORDER BY f.category_display_order NULLS LAST,f.category_name NULLS LAST,f.card_number,f.player_name) FROM final f),'[]'::jsonb)
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_resultados_stableford_oficiales_ronda(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_resultados_stableford_oficiales_ronda(uuid) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.obtener_leaderboard_stableford_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_results jsonb;
    v_round jsonb;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501'; END IF;
    v_results:=public.obtener_resultados_stableford_oficiales_ronda(p_tournament_round_id);
    v_round:=v_results->'round';

    RETURN (
      WITH raw AS (
        SELECT (c->>'scoreCardId')::uuid score_card_id,(c->>'cardNumber')::integer card_number,c->>'cardFolio' card_folio,
               NULLIF(c->>'playerId','')::uuid player_id,c->>'playerName' player_name,
               NULLIF(c->>'tournamentCategoryId','')::uuid tournament_category_id,c->>'categoryCode' category_code,
               c->>'categoryName' category_name,NULLIF(c->>'categoryDisplayOrder','')::integer category_display_order,
               NULLIF(c->>'teeId','')::uuid tee_id,c->>'teeName' tee_name,NULLIF(c->>'playingHandicap','')::integer playing_handicap,
               c->>'competitionStatus' competition_status,c->>'outcomeReason' outcome_reason,
               COALESCE((c->>'ready')::boolean,false) official_ready,
               COALESCE((c->>'grossEnabled')::boolean,false) gross_enabled,COALESCE((c->>'netEnabled')::boolean,false) net_enabled,
               NULLIF(c->>'grossPointsTotal','')::integer gross_points_total,NULLIF(c->>'netPointsTotal','')::integer net_points_total
        FROM jsonb_array_elements(v_results->'cards') c
      ),
      gross_ranked AS (
        SELECT score_card_id,rank() over(partition by tournament_category_id order by gross_points_total DESC)::integer rank,
               count(*) over(partition by tournament_category_id,gross_points_total)::integer tie_size
        FROM raw WHERE official_ready AND gross_enabled
      ),
      net_ranked AS (
        SELECT score_card_id,rank() over(partition by tournament_category_id order by net_points_total DESC)::integer rank,
               count(*) over(partition by tournament_category_id,net_points_total)::integer tie_size
        FROM raw WHERE official_ready AND net_enabled
      ),
      combined AS (
        SELECT r.*,g.rank gross_rank,g.tie_size gross_tie_size,n.rank net_rank,n.tie_size net_tie_size
        FROM raw r LEFT JOIN gross_ranked g USING(score_card_id) LEFT JOIN net_ranked n USING(score_card_id)
      ),
      cats AS (
        SELECT tournament_category_id,category_code,category_name,category_display_order,
               bool_or(COALESCE(gross_tie_size,0)>1) FILTER(WHERE gross_enabled AND official_ready) has_gross_ties,
               bool_or(COALESCE(net_tie_size,0)>1) FILTER(WHERE net_enabled AND official_ready) has_net_ties
        FROM combined GROUP BY tournament_category_id,category_code,category_name,category_display_order
      )
      SELECT jsonb_build_object(
        'round',v_round,
        'status',jsonb_build_object(
            'hasAnyTies',COALESCE((SELECT bool_or(COALESCE(has_gross_ties,false) OR COALESCE(has_net_ties,false)) FROM cats),false),
            'tiebreakImplemented',false,
            'leaderboardStatus',CASE
                WHEN EXISTS(SELECT 1 FROM combined WHERE NOT official_ready AND competition_status NOT IN ('WD','DNF','DQ','DNS','NO_CARD')) THEN 'PROVISIONAL'
                WHEN COALESCE((SELECT bool_or(COALESCE(has_gross_ties,false) OR COALESCE(has_net_ties,false)) FROM cats),false) THEN 'READY_FOR_TIEBREAK'
                ELSE 'READY_FOR_PUBLICATION' END),
        'categories',COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'tournamentCategoryId',c.tournament_category_id,'categoryCode',c.category_code,'categoryName',c.category_name,
            'categoryDisplayOrder',c.category_display_order,'hasGrossTies',COALESCE(c.has_gross_ties,false),
            'hasNetTies',COALESCE(c.has_net_ties,false),
            'players',COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'scoreCardId',p.score_card_id,'cardFolio',p.card_folio,'playerId',p.player_id,'playerName',p.player_name,
                'teeId',p.tee_id,'teeName',p.tee_name,'playingHandicap',p.playing_handicap,
                'competitionStatus',p.competition_status,'outcomeReason',p.outcome_reason,'eligibleForRanking',p.official_ready,
                'gross',jsonb_build_object('enabled',p.gross_enabled,'points',p.gross_points_total,'rank',p.gross_rank,
                    'tieSize',CASE WHEN p.gross_enabled THEN p.gross_tie_size ELSE NULL END,
                    'tiebreakPending',p.gross_enabled AND COALESCE(p.gross_tie_size,0)>1),
                'net',jsonb_build_object('enabled',p.net_enabled,'points',p.net_points_total,'rank',p.net_rank,
                    'tieSize',CASE WHEN p.net_enabled THEN p.net_tie_size ELSE NULL END,
                    'tiebreakPending',p.net_enabled AND COALESCE(p.net_tie_size,0)>1)
            ) ORDER BY CASE WHEN p.official_ready THEN 0 ELSE 1 END,p.net_rank NULLS LAST,p.gross_rank NULLS LAST,p.card_number,p.player_name)
            FROM combined p WHERE p.tournament_category_id IS NOT DISTINCT FROM c.tournament_category_id),'[]'::jsonb)
        ) ORDER BY c.category_display_order NULLS LAST,c.category_name NULLS LAST) FROM cats c),'[]'::jsonb)
      )
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_leaderboard_stableford_ronda(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_leaderboard_stableford_ronda(uuid) TO authenticated,service_role;

COMMIT;
