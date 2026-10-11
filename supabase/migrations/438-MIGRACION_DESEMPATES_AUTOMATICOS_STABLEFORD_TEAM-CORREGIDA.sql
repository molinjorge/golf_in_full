-- 438-MIGRACION_DESEMPATES_AUTOMATICOS_STABLEFORD_TEAM.sql
-- TEE CENTRAL / GOLF IN FULL
-- Ejecutar manualmente en Supabase. Lovable NO ejecuta migraciones.
--
-- Objetivo:
-- Aplicar automáticamente a Stableford por equipos las MISMAS reglas de
-- desempate Stableford ya configuradas en el torneo, usando los puntos TEAM
-- hoyo por hoyo producidos por el motor 434.
--
-- No crea tarjeta TEAM. No modifica scores. No requiere intervención del
-- organizador cuando las reglas automáticas resuelven el empate.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_desempates_stableford_team_ronda_438(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_lb jsonb;
    v_tournament_id uuid;
BEGIN
    v_lb:=public.obtener_leaderboard_stableford_team_ronda_437(p_tournament_round_id);
    v_tournament_id:=NULLIF(v_lb#>>'{round,tournamentId}','')::uuid;

    RETURN (
      WITH teams AS (
        SELECT
          NULLIF(c->>'tournamentCategoryId','')::uuid category_id,
          c->>'categoryCode' category_code,
          c->>'categoryName' category_name,
          NULLIF(c->>'categoryDisplayOrder','')::integer category_order,
          NULLIF(p->>'teamId','')::uuid team_id,
          p->>'teamName' team_name,
          COALESCE((p->>'eligibleForRanking')::boolean,false) ready,
          COALESCE(p->'holes','[]'::jsonb) holes,
          COALESCE((p#>>'{gross,enabled}')::boolean,false) gross_enabled,
          NULLIF(p#>>'{gross,points}','')::integer gross_points,
          NULLIF(p#>>'{gross,baseRank}','')::integer gross_rank,
          COALESCE(NULLIF(p#>>'{gross,tieSize}','')::integer,0) gross_tie_size,
          COALESCE((p#>>'{net,enabled}')::boolean,false) net_enabled,
          NULLIF(p#>>'{net,points}','')::integer net_points,
          NULLIF(p#>>'{net,baseRank}','')::integer net_rank,
          COALESCE(NULLIF(p#>>'{net,tieSize}','')::integer,0) net_tie_size
        FROM jsonb_array_elements(COALESCE(v_lb->'categories','[]'::jsonb)) c
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(c->'players','[]'::jsonb)) p
      ),
      tied AS (
        SELECT t.*,'gross'::public.tipo_resultado_desempate result_type,
               gross_points metric_total,gross_rank base_rank,gross_tie_size tie_size
        FROM teams t WHERE ready AND gross_enabled AND gross_tie_size>1
        UNION ALL
        SELECT t.*,'neto'::public.tipo_resultado_desempate,
               net_points,net_rank,net_tie_size
        FROM teams t WHERE ready AND net_enabled AND net_tie_size>1
      ),
      groups AS (
        SELECT DISTINCT category_id,category_code,category_name,category_order,
               result_type,metric_total,base_rank,tie_size,
               CASE WHEN base_rank=1
                    THEN 'primer_lugar'::public.alcance_desempate
                    ELSE 'otros_lugares'::public.alcance_desempate END scope
        FROM tied
      ),
      configured AS (
        SELECT g.*,
          CASE
            WHEN EXISTS(SELECT 1 FROM public.tournament_tiebreak_rules r
              WHERE r.tournament_id=v_tournament_id AND r.activo
                AND r.tipo_resultado=g.result_type
                AND r.tournament_category_id=g.category_id AND r.alcance=g.scope)
              THEN 'CATEGORY_SCOPE'
            WHEN EXISTS(SELECT 1 FROM public.tournament_tiebreak_rules r
              WHERE r.tournament_id=v_tournament_id AND r.activo
                AND r.tipo_resultado=g.result_type
                AND r.tournament_category_id=g.category_id
                AND r.alcance='todos'::public.alcance_desempate)
              THEN 'CATEGORY_ALL'
            WHEN EXISTS(SELECT 1 FROM public.tournament_tiebreak_rules r
              WHERE r.tournament_id=v_tournament_id AND r.activo
                AND r.tipo_resultado=g.result_type
                AND r.tournament_category_id IS NULL AND r.alcance=g.scope)
              THEN 'TOURNAMENT_SCOPE'
            WHEN EXISTS(SELECT 1 FROM public.tournament_tiebreak_rules r
              WHERE r.tournament_id=v_tournament_id AND r.activo
                AND r.tipo_resultado=g.result_type
                AND r.tournament_category_id IS NULL
                AND r.alcance='todos'::public.alcance_desempate)
              THEN 'TOURNAMENT_ALL'
            ELSE 'NONE'
          END rule_source
        FROM groups g
      ),
      group_rules AS (
        SELECT cg.*,
          COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'ruleId',r.id,'order',r.orden,'methodId',r.tiebreak_method_id,
              'methodCode',m.code,'methodName',m.name
            ) ORDER BY r.orden)
            FROM public.tournament_tiebreak_rules r
            JOIN public.tiebreak_methods m ON m.id=r.tiebreak_method_id
            WHERE r.tournament_id=v_tournament_id AND r.activo
              AND r.tipo_resultado=cg.result_type
              AND (
                (cg.rule_source='CATEGORY_SCOPE' AND r.tournament_category_id=cg.category_id AND r.alcance=cg.scope)
                OR (cg.rule_source='CATEGORY_ALL' AND r.tournament_category_id=cg.category_id AND r.alcance='todos'::public.alcance_desempate)
                OR (cg.rule_source='TOURNAMENT_SCOPE' AND r.tournament_category_id IS NULL AND r.alcance=cg.scope)
                OR (cg.rule_source='TOURNAMENT_ALL' AND r.tournament_category_id IS NULL AND r.alcance='todos'::public.alcance_desempate)
              )
          ),'[]'::jsonb) rules
        FROM configured cg
      ),
      team_eval AS (
        SELECT t.category_id,t.category_code,t.category_name,t.category_order,
               t.team_id,t.team_name,t.result_type,t.metric_total,t.base_rank,t.tie_size,
               gr.scope,gr.rule_source,gr.rules,
               public.evaluar_secuencia_desempate_stableford(
                 gr.rules,t.result_type,t.holes
               ) evaluation
        FROM tied t
        JOIN group_rules gr
          ON gr.category_id=t.category_id
         AND gr.result_type=t.result_type
         AND gr.metric_total=t.metric_total
         AND gr.base_rank=t.base_rank
      ),
      automatic_steps AS (
        SELECT te.category_id,te.result_type,te.metric_total,te.base_rank,te.tie_size,
               te.team_id,(s->>'order')::integer step_order,
               s->>'methodCode' method_code,s->>'methodName' method_name,
               s->'cumulativeKey' cumulative_key_json,
               ARRAY(SELECT value::integer
                     FROM jsonb_array_elements_text(s->'cumulativeKey')) cumulative_key
        FROM team_eval te
        CROSS JOIN LATERAL jsonb_array_elements(te.evaluation->'steps') s
        WHERE COALESCE((s->>'automatic')::boolean,false)
      ),
      step_uniqueness AS (
        SELECT category_id,result_type,metric_total,base_rank,step_order,
               min(method_code) method_code,min(method_name) method_name,
               count(DISTINCT cumulative_key_json::text) unique_keys,
               max(tie_size) group_size
        FROM automatic_steps
        GROUP BY category_id,result_type,metric_total,base_rank,step_order
      ),
      resolved_step AS (
        SELECT category_id,result_type,metric_total,base_rank,
               min(step_order) FILTER(WHERE unique_keys=group_size) resolved_at_step
        FROM step_uniqueness
        GROUP BY category_id,result_type,metric_total,base_rank
      ),
      group_state AS (
        SELECT gr.*,rs.resolved_at_step,
               COALESCE(bool_or(COALESCE((te.evaluation->>'stoppedAtManual')::boolean,false)),false) stopped_at_manual,
               max(te.evaluation->>'manualMethodCode') FILTER(
                 WHERE COALESCE((te.evaluation->>'stoppedAtManual')::boolean,false)
               ) manual_method_code,
               max(te.evaluation->>'manualMethodName') FILTER(
                 WHERE COALESCE((te.evaluation->>'stoppedAtManual')::boolean,false)
               ) manual_method_name
        FROM group_rules gr
        LEFT JOIN resolved_step rs
          ON rs.category_id=gr.category_id AND rs.result_type=gr.result_type
         AND rs.metric_total=gr.metric_total AND rs.base_rank=gr.base_rank
        LEFT JOIN team_eval te
          ON te.category_id=gr.category_id AND te.result_type=gr.result_type
         AND te.metric_total=gr.metric_total AND te.base_rank=gr.base_rank
        GROUP BY gr.category_id,gr.category_code,gr.category_name,gr.category_order,
                 gr.result_type,gr.metric_total,gr.base_rank,gr.tie_size,gr.scope,
                 gr.rule_source,gr.rules,rs.resolved_at_step
      ),
      group_final AS (
        SELECT gs.*,su.method_code resolved_method_code,su.method_name resolved_method_name,
          CASE
            WHEN jsonb_array_length(gs.rules)=0 THEN 'CONFIG_MISSING'
            WHEN gs.resolved_at_step IS NOT NULL THEN 'RESOLVED_AUTOMATIC'
            WHEN gs.stopped_at_manual THEN 'MANUAL_PENDING'
            ELSE 'TIE_PERSISTS_AFTER_RULES'
          END status
        FROM group_state gs
        LEFT JOIN step_uniqueness su
          ON su.category_id=gs.category_id AND su.result_type=gs.result_type
         AND su.metric_total=gs.metric_total AND su.base_rank=gs.base_rank
         AND su.step_order=gs.resolved_at_step
      ),
      team_resolution AS (
        SELECT te.*,gf.status,gf.resolved_at_step,
               step_at_resolution.cumulative_key resolution_key,
               CASE WHEN gf.status='RESOLVED_AUTOMATIC'
                    THEN row_number() OVER(
                      PARTITION BY te.category_id,te.result_type,te.metric_total,te.base_rank
                      ORDER BY step_at_resolution.cumulative_key ASC,te.team_name,te.team_id
                    )::integer
               END tiebreak_order
        FROM team_eval te
        JOIN group_final gf
          ON gf.category_id=te.category_id AND gf.result_type=te.result_type
         AND gf.metric_total=te.metric_total AND gf.base_rank=te.base_rank
        LEFT JOIN LATERAL (
          SELECT ARRAY(SELECT value::integer
                       FROM jsonb_array_elements_text(s->'cumulativeKey')) cumulative_key
          FROM jsonb_array_elements(te.evaluation->'steps') s
          WHERE (s->>'order')::integer=gf.resolved_at_step
            AND COALESCE((s->>'automatic')::boolean,false)
          LIMIT 1
        ) step_at_resolution ON true
      )
      SELECT jsonb_build_object(
        'supported',true,'applicable',true,'competitiveUnit','TEAM',
        'summary',jsonb_build_object(
          'tieGroups',(SELECT count(*) FROM group_final),
          'automaticResolved',(SELECT count(*) FROM group_final WHERE status='RESOLVED_AUTOMATIC'),
          'pending',(SELECT count(*) FROM group_final WHERE status<>'RESOLVED_AUTOMATIC'),
          'engineStatus',CASE
            WHEN NOT EXISTS(SELECT 1 FROM group_final) THEN 'NO_TIES'
            WHEN EXISTS(SELECT 1 FROM group_final WHERE status<>'RESOLVED_AUTOMATIC') THEN 'ACTION_REQUIRED'
            ELSE 'RESOLVED' END
        ),
        'tieGroups',COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'competitiveUnit','TEAM',
            'tournamentCategoryId',gf.category_id,
            'categoryCode',gf.category_code,'categoryName',gf.category_name,
            'resultType',gf.result_type,'tiedPoints',gf.metric_total,
            'baseRank',gf.base_rank,'tieSize',gf.tie_size,'scope',gf.scope,
            'ruleSource',gf.rule_source,'rules',gf.rules,'status',gf.status,
            'resolvedAtStep',gf.resolved_at_step,
            'resolvedByMethodCode',gf.resolved_method_code,
            'resolvedByMethodName',gf.resolved_method_name,
            'teams',COALESCE((
              SELECT jsonb_agg(jsonb_build_object(
                'teamId',tr.team_id,'teamName',tr.team_name,
                'baseRank',tr.base_rank,'tiebreakOrder',tr.tiebreak_order,
                'finalRank',CASE WHEN tr.tiebreak_order IS NOT NULL
                                 THEN tr.base_rank+tr.tiebreak_order-1 END,
                'comparisonKey',to_jsonb(tr.resolution_key),
                'evidence',tr.evaluation->'steps'
              ) ORDER BY tr.tiebreak_order NULLS LAST,tr.team_name,tr.team_id)
              FROM team_resolution tr
              WHERE tr.category_id=gf.category_id AND tr.result_type=gf.result_type
                AND tr.metric_total=gf.metric_total AND tr.base_rank=gf.base_rank
            ),'[]'::jsonb)
          ) ORDER BY gf.category_order NULLS LAST,gf.category_name,gf.result_type,gf.base_rank)
          FROM group_final gf
        ),'[]'::jsonb)
      ));
END;
$function$;

COMMENT ON FUNCTION public.obtener_desempates_stableford_team_ronda_438(uuid)
IS '438: desempates automáticos Stableford TEAM reutilizando reglas y evaluador Stableford existentes sobre puntos TEAM por hoyo del motor 434.';

-- Wrapper del leaderboard: conserva 437 como base y aplica únicamente el
-- resultado de desempate TEAM sobre finalRank/tiebreakStatus.
CREATE OR REPLACE FUNCTION public.obtener_leaderboard_stableford_team_ronda_438(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_lb jsonb;
    v_tb jsonb;
    v_categories jsonb;
BEGIN
    v_lb:=public.obtener_leaderboard_stableford_team_ronda_437(p_tournament_round_id);
    v_tb:=public.obtener_desempates_stableford_team_ronda_438(p_tournament_round_id);

    SELECT COALESCE(jsonb_agg(
      c - 'players' || jsonb_build_object('players',COALESCE((
        SELECT jsonb_agg(
          p
          || jsonb_build_object(
            'gross',
            CASE
              WHEN COALESCE(NULLIF(p#>>'{gross,tieSize}','')::integer,0)<=1 THEN p->'gross'
              ELSE (p->'gross') || jsonb_build_object(
                'finalRank',(
                  SELECT NULLIF(t#>>'{finalRank}','')::integer
                  FROM jsonb_array_elements(COALESCE(v_tb->'tieGroups','[]'::jsonb)) g
                  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(g->'teams','[]'::jsonb)) t
                  WHERE NULLIF(g->>'tournamentCategoryId','')::uuid=NULLIF(c->>'tournamentCategoryId','')::uuid
                    AND g->>'resultType'='gross'
                    AND NULLIF(g->>'baseRank','')::integer=NULLIF(p#>>'{gross,baseRank}','')::integer
                    AND NULLIF(t->>'teamId','')::uuid=NULLIF(p->>'teamId','')::uuid
                  LIMIT 1
                ),
                'tiebreakStatus',COALESCE((
                  SELECT g->>'status'
                  FROM jsonb_array_elements(COALESCE(v_tb->'tieGroups','[]'::jsonb)) g
                  WHERE NULLIF(g->>'tournamentCategoryId','')::uuid=NULLIF(c->>'tournamentCategoryId','')::uuid
                    AND g->>'resultType'='gross'
                    AND NULLIF(g->>'baseRank','')::integer=NULLIF(p#>>'{gross,baseRank}','')::integer
                  LIMIT 1
                ),'PENDING')
              ) END,
            'net',
            CASE
              WHEN COALESCE(NULLIF(p#>>'{net,tieSize}','')::integer,0)<=1 THEN p->'net'
              ELSE (p->'net') || jsonb_build_object(
                'finalRank',(
                  SELECT NULLIF(t#>>'{finalRank}','')::integer
                  FROM jsonb_array_elements(COALESCE(v_tb->'tieGroups','[]'::jsonb)) g
                  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(g->'teams','[]'::jsonb)) t
                  WHERE NULLIF(g->>'tournamentCategoryId','')::uuid=NULLIF(c->>'tournamentCategoryId','')::uuid
                    AND g->>'resultType'='neto'
                    AND NULLIF(g->>'baseRank','')::integer=NULLIF(p#>>'{net,baseRank}','')::integer
                    AND NULLIF(t->>'teamId','')::uuid=NULLIF(p->>'teamId','')::uuid
                  LIMIT 1
                ),
                'tiebreakStatus',COALESCE((
                  SELECT g->>'status'
                  FROM jsonb_array_elements(COALESCE(v_tb->'tieGroups','[]'::jsonb)) g
                  WHERE NULLIF(g->>'tournamentCategoryId','')::uuid=NULLIF(c->>'tournamentCategoryId','')::uuid
                    AND g->>'resultType'='neto'
                    AND NULLIF(g->>'baseRank','')::integer=NULLIF(p#>>'{net,baseRank}','')::integer
                  LIMIT 1
                ),'PENDING')
              ) END
          )
          ORDER BY p->>'teamName'
        )
        FROM jsonb_array_elements(COALESCE(c->'players','[]'::jsonb)) p
      ),'[]'::jsonb))
      ORDER BY NULLIF(c->>'categoryDisplayOrder','')::integer NULLS LAST,c->>'categoryName'
    ),'[]'::jsonb)
    INTO v_categories
    FROM jsonb_array_elements(COALESCE(v_lb->'categories','[]'::jsonb)) c;

    RETURN v_lb
      || jsonb_build_object(
           'categories',v_categories,
           'tiebreaks',v_tb,
           'status',(v_lb->'status') || jsonb_build_object(
             'unresolvedTieEntries',COALESCE(NULLIF(v_tb#>>'{summary,pending}','')::integer,0),
             'leaderboardStatus',CASE
               WHEN COALESCE(NULLIF(v_lb#>>'{summary,unresolvedParticipants}','')::integer,0)>0
                 THEN 'PROVISIONAL'
               WHEN COALESCE(NULLIF(v_tb#>>'{summary,pending}','')::integer,0)>0
                 THEN 'READY_FOR_TIEBREAK'
               ELSE 'READY_FOR_PUBLICATION' END
           )
         );
END;
$function$;

COMMENT ON FUNCTION public.obtener_leaderboard_stableford_team_ronda_438(uuid)
IS '438: leaderboard Stableford TEAM con desempates automáticos aplicados a finalRank.';

-- Dispatcher operativo: únicamente cambia la rama Stableford TEAM de 437 a 438.
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
    v_engine text;
    v_participation text;
    v_format_code text;
    v_result jsonb;
BEGIN
    SELECT s.scoring_engine,s.participation_type,s.format_code
      INTO v_engine,v_participation,v_format_code
      FROM public.tournament_round_condition_snapshots s
     WHERE s.tournament_round_id=p_tournament_round_id
     ORDER BY s.created_at DESC,s.id DESC LIMIT 1;

    IF v_engine='best_ball' AND v_participation='equipo' THEN
        RETURN public.obtener_leaderboard_best_ball_ronda_328(p_tournament_round_id);
    END IF;
    IF v_engine='team_stroke' AND v_participation='equipo' THEN
        v_result:=public.obtener_leaderboard_a_gogo_ronda(p_tournament_round_id);
        RETURN COALESCE(v_result,'{}'::jsonb)||jsonb_build_object('supported',true,'applicable',true);
    END IF;
    IF v_engine='stableford' AND v_participation='equipo'
       AND v_format_code='STABLEFORD_EQUIPO' THEN
        RETURN public.obtener_leaderboard_stableford_team_ronda_438(p_tournament_round_id);
    END IF;
    RETURN public._obtener_leaderboard_operativo_ronda_pre328(p_tournament_round_id);
END;
$function$;

-- Estado competitivo: toma los pendientes REALES después del desempate automático.
CREATE OR REPLACE FUNCTION public.obtener_estado_cierre_stableford_team_ronda_437(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_lb jsonb;
    v_tb jsonb;
    v_unresolved integer;
    v_pending_count integer;
    v_pending jsonb;
BEGIN
    v_lb:=public.obtener_leaderboard_stableford_team_ronda_438(p_tournament_round_id);
    v_tb:=COALESCE(v_lb->'tiebreaks','{}'::jsonb);
    v_unresolved:=COALESCE(NULLIF(v_lb#>>'{summary,unresolvedParticipants}','')::integer,0);
    v_pending_count:=COALESCE(NULLIF(v_tb#>>'{summary,pending}','')::integer,0);

    SELECT COALESCE(jsonb_agg(g),'[]'::jsonb)
      INTO v_pending
      FROM jsonb_array_elements(COALESCE(v_tb->'tieGroups','[]'::jsonb)) g
     WHERE g->>'status'<>'RESOLVED_AUTOMATIC';

    RETURN jsonb_build_object(
      'supported',true,'applicable',true,'round',v_lb->'round','summary',v_lb->'summary',
      'tiebreaks',v_tb,'pendingTiebreaks',v_pending,
      'status',jsonb_build_object(
        'competitiveStatus',CASE
          WHEN v_unresolved>0 THEN 'RESULTS_PENDING'
          WHEN v_pending_count>0 THEN 'TIEBREAKS_PENDING'
          ELSE 'READY' END,
        'competitivelyClosed',false,
        'unresolvedParticipants',v_unresolved,
        'pendingTiebreakGroups',v_pending_count
      )
    );
END;
$function$;

COMMENT ON FUNCTION public.obtener_estado_cierre_stableford_team_ronda_437(uuid)
IS '438: estado de cierre Stableford TEAM descuenta desempates resueltos automáticamente; solo deja pendientes reales.';

COMMIT;
