-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 326
-- BEST BALL F12 — LEADERBOARD DE RONDA TEAM
-- ============================================================================
-- Consume exclusivamente el resultado oficial F11.
-- No recalcula scores ni persiste rankings.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_leaderboard_best_ball_ronda_326(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_ctx record;
    v_cards integer;
    v_official integer;
    v_categories jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT
      tr.id round_id,tr.tournament_id,tr.round_number,
      v.id validation_id,v.freeze_id,
      v.scoring_engine,v.participation_type
    INTO v_ctx
    FROM public.tournament_rounds tr
    JOIN LATERAL (
      SELECT x.*
      FROM public.tournament_round_start_validations x
      WHERE x.tournament_round_id=tr.id
        AND x.status='valid'
      ORDER BY x.validation_version DESC,x.validated_at DESC,x.id DESC
      LIMIT 1
    ) v ON true
    WHERE tr.id=p_tournament_round_id
    LIMIT 1;

    IF v_ctx.round_id IS NULL
       OR v_ctx.scoring_engine IS DISTINCT FROM 'best_ball'
       OR v_ctx.participation_type IS DISTINCT FROM 'equipo'
    THEN
        RAISE EXCEPTION 'La ronda no corresponde a Best Ball TEAM.'
          USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_ctx.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar este leaderboard Best Ball.'
          USING ERRCODE='42501';
    END IF;

    SELECT count(*) INTO v_cards
    FROM public.tournament_score_cards sc
    WHERE sc.tournament_round_id=v_ctx.round_id
      AND sc.validation_id=v_ctx.validation_id
      AND sc.unit_type='team'
      AND sc.status='issued';

    /*
      F11 es la única autoridad de score oficial. Una tarjeta que todavía no
      tiene físico/conciliación completa no entra al ranking oficial.
      Para no abortar todo el leaderboard por tarjetas aún en proceso,
      primero filtramos por las precondiciones objetivas de F11 y luego
      invocamos F11 sólo para esas tarjetas.
    */
    WITH eligible AS (
      SELECT sc.id score_card_id
      FROM public.tournament_score_cards sc
      JOIN public.tournament_scorecard_physical_receptions pr
        ON pr.score_card_id=sc.id AND pr.status='CAPTURED'
      JOIN public.tournament_scorecard_reconciliations rc
        ON rc.score_card_id=sc.id AND rc.status='COMPLETED'
      WHERE sc.tournament_round_id=v_ctx.round_id
        AND sc.validation_id=v_ctx.validation_id
        AND sc.unit_type='team'
        AND sc.status='issued'
    ),
    official AS (
      SELECT e.score_card_id,
             public.obtener_resultado_oficial_best_ball_325(e.score_card_id) result
      FROM eligible e
    )
    SELECT count(*) INTO v_official FROM official;

    WITH category_catalog AS (
      SELECT
        s.tournament_category_id,
        max(s.category_code) category_code,
        max(s.category_name) category_name,
        min(s.category_display_order) category_display_order,
        bool_or(s.tipo_resultado::text='gross') has_gross,
        bool_or(s.tipo_resultado::text='neto') has_net
      FROM public.tournament_category_classification_snapshots s
      WHERE s.freeze_id=v_ctx.freeze_id
      GROUP BY s.tournament_category_id
    ),
    eligible AS (
      SELECT sc.id score_card_id,sc.tournament_category_id,
             ss.team_name,sc.tournament_team_id,sc.card_folio
      FROM public.tournament_score_cards sc
      JOIN public.tournament_best_ball_scorecard_snapshots ss
        ON ss.score_card_id=sc.id
      JOIN public.tournament_scorecard_physical_receptions pr
        ON pr.score_card_id=sc.id AND pr.status='CAPTURED'
      JOIN public.tournament_scorecard_reconciliations rc
        ON rc.score_card_id=sc.id AND rc.status='COMPLETED'
      WHERE sc.tournament_round_id=v_ctx.round_id
        AND sc.validation_id=v_ctx.validation_id
        AND sc.unit_type='team'
        AND sc.status='issued'
    ),
    official AS (
      SELECT e.*,
             public.obtener_resultado_oficial_best_ball_325(e.score_card_id) result
      FROM eligible e
    ),
    scores AS (
      SELECT
        o.*,
        NULLIF(o.result#>>'{officialTotals,gross}','')::integer gross_total,
        NULLIF(o.result#>>'{officialTotals,net}','')::integer net_total
      FROM official o
    ),
    gross_ranked AS (
      SELECT s.*,
             rank() OVER (
               PARTITION BY s.tournament_category_id
               ORDER BY s.gross_total ASC
             ) gross_rank,
             count(*) OVER (
               PARTITION BY s.tournament_category_id,s.gross_total
             ) gross_tie_count
      FROM scores s
    ),
    ranked AS (
      SELECT g.*,
             rank() OVER (
               PARTITION BY g.tournament_category_id
               ORDER BY g.net_total ASC
             ) net_rank,
             count(*) OVER (
               PARTITION BY g.tournament_category_id,g.net_total
             ) net_tie_count
      FROM gross_ranked g
    ),
    categories AS (
      SELECT
        cc.tournament_category_id,
        cc.category_code,cc.category_name,cc.category_display_order,
        cc.has_gross,cc.has_net,
        COALESCE((
          SELECT jsonb_agg(
            jsonb_build_object(
              'scoreCardId',r.score_card_id,
              'tournamentTeamId',r.tournament_team_id,
              'teamName',r.team_name,
              'cardFolio',r.card_folio,
              'competitionStatus','OFFICIAL',
              'gross',jsonb_build_object(
                'enabled',cc.has_gross,
                'total',r.gross_total,
                'rank',CASE WHEN cc.has_gross THEN r.gross_rank ELSE NULL END,
                'tied',CASE WHEN cc.has_gross THEN r.gross_tie_count>1 ELSE false END,
                'tieCount',CASE WHEN cc.has_gross THEN r.gross_tie_count ELSE NULL END
              ),
              'net',jsonb_build_object(
                'enabled',cc.has_net,
                'total',r.net_total,
                'rank',CASE WHEN cc.has_net THEN r.net_rank ELSE NULL END,
                'tied',CASE WHEN cc.has_net THEN r.net_tie_count>1 ELSE false END,
                'tieCount',CASE WHEN cc.has_net THEN r.net_tie_count ELSE NULL END
              )
            )
            ORDER BY
              CASE WHEN cc.has_net THEN r.net_rank ELSE r.gross_rank END,
              CASE WHEN cc.has_net THEN r.net_total ELSE r.gross_total END,
              r.team_name,r.card_folio
          )
          FROM ranked r
          WHERE r.tournament_category_id=cc.tournament_category_id
        ),'[]'::jsonb) teams
      FROM category_catalog cc
    )
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'tournamentCategoryId',c.tournament_category_id,
        'categoryCode',c.category_code,
        'categoryName',c.category_name,
        'classifications',jsonb_build_object(
          'gross',c.has_gross,
          'net',c.has_net
        ),
        'teams',c.teams
      )
      ORDER BY c.category_display_order,c.category_name
    ),'[]'::jsonb)
    INTO v_categories
    FROM categories c;

    RETURN jsonb_build_object(
      'schemaVersion',1,
      'engine','best_ball',
      'supported',true,
      'round',jsonb_build_object(
        'id',v_ctx.round_id,
        'roundNumber',v_ctx.round_number,
        'tournamentId',v_ctx.tournament_id
      ),
      'competitiveUnit','TEAM',
      'source',jsonb_build_object(
        'rpc','obtener_resultado_oficial_best_ball_325',
        'metricUnit','STROKES',
        'officialOnly',true
      ),
      'status',jsonb_build_object(
        'issuedCards',v_cards,
        'officialCards',v_official,
        'pendingCards',GREATEST(v_cards-v_official,0),
        'complete',(v_cards>0 AND v_official=v_cards)
      ),
      'summary',jsonb_build_object(
        'teamsIssued',v_cards,
        'teamsOfficial',v_official
      ),
      'categories',v_categories
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.obtener_leaderboard_operativo_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_scoring_engine text;
    v_participation_type text;
    v_team_payload jsonb;
BEGIN
    SELECT s.scoring_engine,s.participation_type
      INTO v_scoring_engine,v_participation_type
      FROM public.tournament_round_condition_snapshots s
     WHERE s.tournament_round_id=p_tournament_round_id
     ORDER BY s.created_at DESC,s.id DESC
     LIMIT 1;

    IF v_participation_type='equipo'
       AND v_scoring_engine='best_ball'
    THEN
        RETURN public.obtener_leaderboard_best_ball_ronda_326(
            p_tournament_round_id
        );
    END IF;

    IF v_participation_type='equipo'
       AND v_scoring_engine='team_stroke'
    THEN
        v_team_payload :=
            public.obtener_leaderboard_a_gogo_ronda(
                p_tournament_round_id
            );

        RETURN jsonb_build_object(
            'schemaVersion',1,
            'supported',true,
            'unsupportedReason',NULL,
            'round',v_team_payload->'round',
            'competitiveUnit',v_team_payload->'competitiveUnit',
            'source',jsonb_build_object(
                'rpc','obtener_leaderboard_a_gogo_ronda',
                'metricUnit','STROKES'
            ),
            'status',v_team_payload->'status',
            'summary',v_team_payload->'summary',
            'categories',v_team_payload->'categories'
        );
    END IF;

    RETURN public._obtener_leaderboard_operativo_ronda_pre211(
        p_tournament_round_id
    );
END;
$function$;

COMMIT;
