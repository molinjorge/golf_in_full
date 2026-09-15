-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 327
-- BEST BALL F13 — DESEMPATES GROSS/NET + RESOLUCION MANUAL TEAM
-- ============================================================================
-- AISLAMIENTO:
--   * No modifica Stroke, Stableford ni A-Go-Go.
--   * Reutiliza reglas, metodos, evaluador y tablas comunes de resoluciones.
--   * El desempate Best Ball consume exclusivamente F11/F12.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_desempates_best_ball_ronda_327(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_round_number integer;
    v_round_date date;
    v_engine text;
    v_participation text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT tr.tournament_id,tr.numero_ronda,tr.fecha,
           rcs.scoring_engine,rcs.participation_type
      INTO v_tournament_id,v_round_number,v_round_date,v_engine,v_participation
      FROM public.tournament_rounds tr
      JOIN LATERAL (
        SELECT x.scoring_engine,x.participation_type
        FROM public.tournament_round_condition_snapshots x
        WHERE x.tournament_round_id=tr.id
        ORDER BY x.created_at DESC,x.id DESC LIMIT 1
      ) rcs ON true
     WHERE tr.id=p_tournament_round_id;

    IF v_tournament_id IS NULL OR v_engine<>'best_ball' OR v_participation<>'equipo' THEN
        RAISE EXCEPTION 'La ronda no corresponde a Best Ball TEAM.' USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para consultar desempates.'
          USING ERRCODE='42501';
    END IF;

    RETURN (
      WITH lb AS (
        SELECT public.obtener_leaderboard_best_ball_ronda_326(p_tournament_round_id) j
      ),
      category_flags AS (
        SELECT
          NULLIF(c->>'tournamentCategoryId','')::uuid category_id,
          c->>'categoryName' category_name,
          row_number() over () category_order,
          COALESCE((c#>>'{classifications,gross}')::boolean,false) gross_enabled,
          COALESCE((c#>>'{classifications,net}')::boolean,false) net_enabled
        FROM lb CROSS JOIN LATERAL jsonb_array_elements(COALESCE(j->'categories','[]'::jsonb)) c
      ),
      team_rows AS (
        SELECT
          cf.category_id,cf.category_name,cf.category_order,
          cf.gross_enabled,cf.net_enabled,
          NULLIF(t->>'scoreCardId','')::uuid score_card_id,
          NULLIF(t->>'tournamentTeamId','')::uuid team_id,
          t->>'teamName' team_name,
          t->>'cardFolio' card_folio,
          NULLIF(t#>>'{gross,total}','')::integer gross_total,
          NULLIF(t#>>'{net,total}','')::integer net_total
        FROM lb
        JOIN category_flags cf ON true
        JOIN LATERAL jsonb_array_elements(COALESCE((
          SELECT c->'teams'
          FROM jsonb_array_elements(COALESCE(lb.j->'categories','[]'::jsonb)) c
          WHERE NULLIF(c->>'tournamentCategoryId','')::uuid=cf.category_id
          LIMIT 1
        ),'[]'::jsonb)) t ON true
      ),
      official AS (
        SELECT tr.*,public.obtener_resultado_oficial_best_ball_325(tr.score_card_id) result
        FROM team_rows tr
      ),
      team_holes AS (
        SELECT o.*,
          (
            SELECT jsonb_agg(jsonb_build_object(
              'holeNumber',NULLIF(h->>'holeNumber','')::integer,
              'playSequence',NULLIF(h->>'playSequence','')::integer,
              'strokeIndex',NULLIF(h->>'strokeIndex','')::integer,
              -- Contrato exacto esperado por calcular_clave_metodo_desempate.
              'officialGrossScore',NULLIF(h->>'officialBestGross','')::integer,
              'officialNetScore',NULLIF(h->>'officialBestNet','')::integer
            ) ORDER BY NULLIF(h->>'playSequence','')::integer,
                       NULLIF(h->>'holeNumber','')::integer)
            FROM jsonb_array_elements(COALESCE(o.result->'holes','[]'::jsonb)) h
          ) holes
        FROM official o
      ),
      metric_rows AS (
        SELECT th.*,'gross'::public.tipo_resultado_desempate result_type,
               th.gross_total metric_total
        FROM team_holes th WHERE th.gross_enabled
        UNION ALL
        SELECT th.*,'neto'::public.tipo_resultado_desempate,
               th.net_total
        FROM team_holes th WHERE th.net_enabled
      ),
      ranked AS (
        SELECT mr.*,
          rank() OVER(PARTITION BY category_id,result_type ORDER BY metric_total)::integer base_rank,
          count(*) OVER(PARTITION BY category_id,result_type,metric_total)::integer tie_size
        FROM metric_rows mr
      ),
      tied AS (
        SELECT r.*,
          CASE WHEN base_rank=1
               THEN 'primer_lugar'::public.alcance_desempate
               ELSE 'otros_lugares'::public.alcance_desempate END scope
        FROM ranked r WHERE tie_size>1
      ),
      groups AS (
        SELECT DISTINCT category_id,category_name,category_order,result_type,
               metric_total,base_rank,tie_size,scope
        FROM tied
      ),
      configured AS (
        SELECT g.*,
          CASE
            WHEN EXISTS(SELECT 1 FROM public.tournament_tiebreak_rules r
              WHERE r.tournament_id=v_tournament_id AND r.activo
                AND r.tipo_resultado=g.result_type AND r.tournament_category_id=g.category_id
                AND r.alcance=g.scope) THEN 'CATEGORY_SCOPE'
            WHEN EXISTS(SELECT 1 FROM public.tournament_tiebreak_rules r
              WHERE r.tournament_id=v_tournament_id AND r.activo
                AND r.tipo_resultado=g.result_type AND r.tournament_category_id=g.category_id
                AND r.alcance='todos'::public.alcance_desempate) THEN 'CATEGORY_ALL'
            WHEN EXISTS(SELECT 1 FROM public.tournament_tiebreak_rules r
              WHERE r.tournament_id=v_tournament_id AND r.activo
                AND r.tipo_resultado=g.result_type AND r.tournament_category_id IS NULL
                AND r.alcance=g.scope) THEN 'TOURNAMENT_SCOPE'
            WHEN EXISTS(SELECT 1 FROM public.tournament_tiebreak_rules r
              WHERE r.tournament_id=v_tournament_id AND r.activo
                AND r.tipo_resultado=g.result_type AND r.tournament_category_id IS NULL
                AND r.alcance='todos'::public.alcance_desempate) THEN 'TOURNAMENT_ALL'
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
                (cg.rule_source='CATEGORY_SCOPE' AND r.tournament_category_id=cg.category_id AND r.alcance=cg.scope) OR
                (cg.rule_source='CATEGORY_ALL' AND r.tournament_category_id=cg.category_id AND r.alcance='todos'::public.alcance_desempate) OR
                (cg.rule_source='TOURNAMENT_SCOPE' AND r.tournament_category_id IS NULL AND r.alcance=cg.scope) OR
                (cg.rule_source='TOURNAMENT_ALL' AND r.tournament_category_id IS NULL AND r.alcance='todos'::public.alcance_desempate)
              )
          ),'[]'::jsonb) rules
        FROM configured cg
      ),
      team_eval AS (
        SELECT t.*,gr.rule_source,gr.rules,
          public.evaluar_secuencia_desempate_tarjeta(gr.rules,t.result_type,t.holes) evaluation
        FROM tied t
        JOIN group_rules gr
          ON gr.category_id=t.category_id AND gr.result_type=t.result_type
         AND gr.metric_total=t.metric_total AND gr.base_rank=t.base_rank
      ),
      automatic_steps AS (
        SELECT te.category_id,te.result_type,te.metric_total,te.base_rank,te.tie_size,
               te.score_card_id,(s->>'order')::integer step_order,
               s->>'methodCode' method_code,s->>'methodName' method_name,
               s->'cumulativeKey' cumulative_key_json,
               ARRAY(SELECT value::integer FROM jsonb_array_elements_text(s->'cumulativeKey')) cumulative_key
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
          max(te.evaluation->>'manualMethodCode') FILTER(WHERE COALESCE((te.evaluation->>'stoppedAtManual')::boolean,false)) manual_method_code,
          max(te.evaluation->>'manualMethodName') FILTER(WHERE COALESCE((te.evaluation->>'stoppedAtManual')::boolean,false)) manual_method_name
        FROM group_rules gr
        LEFT JOIN resolved_step rs
          ON rs.category_id=gr.category_id AND rs.result_type=gr.result_type
         AND rs.metric_total=gr.metric_total AND rs.base_rank=gr.base_rank
        LEFT JOIN team_eval te
          ON te.category_id=gr.category_id AND te.result_type=gr.result_type
         AND te.metric_total=gr.metric_total AND te.base_rank=gr.base_rank
        GROUP BY gr.category_id,gr.category_name,gr.category_order,gr.result_type,
                 gr.metric_total,gr.base_rank,gr.tie_size,gr.scope,gr.rule_source,gr.rules,
                 rs.resolved_at_step
      ),
      group_final AS (
        SELECT gs.*,su.method_code resolved_method_code,su.method_name resolved_method_name,
          CASE WHEN jsonb_array_length(gs.rules)=0 THEN 'CONFIG_MISSING'
               WHEN gs.resolved_at_step IS NOT NULL THEN 'RESOLVED_AUTOMATIC'
               WHEN gs.stopped_at_manual THEN 'MANUAL_PENDING'
               ELSE 'TIE_PERSISTS_AFTER_RULES' END tiebreak_status
        FROM group_state gs
        LEFT JOIN step_uniqueness su
          ON su.category_id=gs.category_id AND su.result_type=gs.result_type
         AND su.metric_total=gs.metric_total AND su.base_rank=gs.base_rank
         AND su.step_order=gs.resolved_at_step
      ),
      team_resolution AS (
        SELECT te.*,gf.tiebreak_status,gf.resolved_at_step,
               sr.cumulative_key resolution_key,
          CASE WHEN gf.tiebreak_status='RESOLVED_AUTOMATIC'
               THEN row_number() OVER(
                 PARTITION BY te.category_id,te.result_type,te.metric_total,te.base_rank
                 ORDER BY sr.cumulative_key ASC,te.card_folio ASC,te.score_card_id
               )::integer END tiebreak_order
        FROM team_eval te
        JOIN group_final gf
          ON gf.category_id=te.category_id AND gf.result_type=te.result_type
         AND gf.metric_total=te.metric_total AND gf.base_rank=te.base_rank
        LEFT JOIN LATERAL (
          SELECT ARRAY(SELECT value::integer FROM jsonb_array_elements_text(s->'cumulativeKey')) cumulative_key
          FROM jsonb_array_elements(te.evaluation->'steps') s
          WHERE (s->>'order')::integer=gf.resolved_at_step
            AND COALESCE((s->>'automatic')::boolean,false)
          LIMIT 1
        ) sr ON true
      ),
      counts AS (
        SELECT count(*) tie_groups,
          count(*) FILTER(WHERE tiebreak_status='RESOLVED_AUTOMATIC') automatic_resolved,
          count(*) FILTER(WHERE tiebreak_status='MANUAL_PENDING') manual_pending,
          count(*) FILTER(WHERE tiebreak_status='CONFIG_MISSING') config_missing,
          count(*) FILTER(WHERE tiebreak_status='TIE_PERSISTS_AFTER_RULES') persists_after_rules
        FROM group_final
      )
      SELECT jsonb_build_object(
        'round',jsonb_build_object(
          'tournamentId',v_tournament_id,'tournamentRoundId',p_tournament_round_id,
          'roundNumber',v_round_number,'roundDate',v_round_date,
          'participationType','equipo','scoringEngine','best_ball'
        ),
        'competitiveUnit','TEAM',
        'summary',(SELECT jsonb_build_object(
          'tieGroups',tie_groups,'automaticResolved',automatic_resolved,
          'manualPending',manual_pending,'configMissing',config_missing,
          'persistsAfterRules',persists_after_rules,
          'engineStatus',CASE WHEN tie_groups=0 THEN 'NO_TIES'
             WHEN config_missing>0 THEN 'CONFIGURATION_REQUIRED'
             WHEN manual_pending>0 OR persists_after_rules>0 THEN 'ACTION_REQUIRED'
             ELSE 'RESOLVED' END) FROM counts),
        'tieGroups',COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'tournamentCategoryId',gf.category_id,'categoryName',gf.category_name,
            'resultType',gf.result_type,'tiedTotal',gf.metric_total,
            'baseRank',gf.base_rank,'tieSize',gf.tie_size,'scope',gf.scope,
            'ruleSource',gf.rule_source,'rules',gf.rules,'status',gf.tiebreak_status,
            'resolvedAtStep',gf.resolved_at_step,
            'resolvedByMethodCode',gf.resolved_method_code,
            'resolvedByMethodName',gf.resolved_method_name,
            'manualMethodCode',gf.manual_method_code,'manualMethodName',gf.manual_method_name,
            'players',COALESCE((
              SELECT jsonb_agg(jsonb_build_object(
                'competitiveUnit','TEAM','scoreCardId',tr.score_card_id,
                'cardFolio',tr.card_folio,'teamId',tr.team_id,'teamName',tr.team_name,
                'playerId',NULL,'playerName',tr.team_name,'baseRank',tr.base_rank,
                'tiebreakOrder',tr.tiebreak_order,
                'finalRank',CASE WHEN tr.tiebreak_order IS NOT NULL
                                 THEN tr.base_rank+tr.tiebreak_order-1 END,
                'resolutionKey',to_jsonb(tr.resolution_key),
                'evidence',tr.evaluation->'steps'
              ) ORDER BY tr.tiebreak_order NULLS LAST,tr.card_folio,tr.team_name)
              FROM team_resolution tr
              WHERE tr.category_id=gf.category_id AND tr.result_type=gf.result_type
                AND tr.metric_total=gf.metric_total AND tr.base_rank=gf.base_rank
            ),'[]'::jsonb)
          ) ORDER BY gf.category_order,gf.category_name,gf.result_type,gf.base_rank,gf.metric_total)
          FROM group_final gf
        ),'[]'::jsonb)
      )
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolver_desempate_manual_best_ball_ronda_327(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid,
    p_tipo_resultado public.tipo_resultado_desempate,
    p_base_rank integer,
    p_tied_total integer,
    p_score_card_order uuid[],
    p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_admin_user_id uuid;
    v_engine jsonb;
    v_group jsonb;
    v_group_status text;
    v_method_code text;
    v_method_name text;
    v_resolution_mode text;
    v_group_size integer;
    v_order_size integer;
    v_distinct_order_size integer;
    v_group_match integer;
    v_resolution_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501'; END IF;

    IF NOT public._tipo_resultado_competitivo_ronda(
      p_tournament_round_id,p_tournament_category_id,p_tipo_resultado
    ) THEN
      RAISE EXCEPTION 'El tipo de resultado % no es competitivo en esta categoría.',p_tipo_resultado
        USING ERRCODE='22023';
    END IF;

    SELECT tournament_id INTO v_tournament_id
    FROM public.tournament_rounds WHERE id=p_tournament_round_id;
    IF v_tournament_id IS NULL THEN RAISE EXCEPTION 'La ronda indicada no existe.'; END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
      RAISE EXCEPTION 'No tienes permiso administrativo para resolver este desempate.'
        USING ERRCODE='42501';
    END IF;

    SELECT id INTO v_admin_user_id FROM public.admin_users
    WHERE auth_user_id=auth.uid() AND activo ORDER BY id LIMIT 1;
    IF v_admin_user_id IS NULL THEN RAISE EXCEPTION 'No existe admin_user asociado.'; END IF;

    IF p_score_card_order IS NULL OR COALESCE(array_length(p_score_card_order,1),0)<2 THEN
      RAISE EXCEPTION 'Debe indicar el orden completo de al menos dos equipos empatados.';
    END IF;

    v_engine:=public.obtener_desempates_best_ball_ronda_327(p_tournament_round_id);

    SELECT g INTO v_group
    FROM jsonb_array_elements(COALESCE(v_engine->'tieGroups','[]'::jsonb)) g
    WHERE NULLIF(g->>'tournamentCategoryId','')::uuid=p_tournament_category_id
      AND g->>'resultType'=p_tipo_resultado::text
      AND (g->>'baseRank')::integer=p_base_rank
      AND (g->>'tiedTotal')::integer=p_tied_total
    LIMIT 1;

    IF v_group IS NULL THEN
      RAISE EXCEPTION 'No existe actualmente ese grupo de empate Best Ball.' USING ERRCODE='55000';
    END IF;

    v_group_status:=v_group->>'status';
    v_group_size:=COALESCE((v_group->>'tieSize')::integer,0);

    IF v_group_status NOT IN('MANUAL_PENDING','TIE_PERSISTS_AFTER_RULES') THEN
      RAISE EXCEPTION 'El grupo no requiere resolución manual. Estado: %',COALESCE(v_group_status,'NULL')
        USING ERRCODE='55000';
    END IF;

    SELECT count(*)::integer,count(DISTINCT x)::integer
      INTO v_order_size,v_distinct_order_size FROM unnest(p_score_card_order) x;
    IF v_order_size<>v_group_size OR v_distinct_order_size<>v_group_size THEN
      RAISE EXCEPTION 'El orden debe contener exactamente los % equipos del empate, sin duplicados.',v_group_size;
    END IF;

    SELECT count(*)::integer INTO v_group_match
    FROM unnest(p_score_card_order) x
    WHERE EXISTS(
      SELECT 1 FROM jsonb_array_elements(COALESCE(v_group->'players','[]'::jsonb)) gp
      WHERE (gp->>'scoreCardId')::uuid=x
    );
    IF v_group_match<>v_group_size THEN
      RAISE EXCEPTION 'El orden contiene tarjetas que no pertenecen exactamente al empate.';
    END IF;

    IF EXISTS(
      SELECT 1 FROM public.tournament_tiebreak_resolutions r
      WHERE r.tournament_round_id=p_tournament_round_id
        AND r.tournament_category_id=p_tournament_category_id
        AND r.tipo_resultado=p_tipo_resultado AND r.base_rank=p_base_rank
        AND r.tied_total=p_tied_total AND r.status='COMPLETED'
    ) THEN
      RAISE EXCEPTION 'Este empate ya tiene resolución manual activa. Debe anularla antes.';
    END IF;

    IF v_group_status='MANUAL_PENDING' THEN
      v_method_code:=v_group->>'manualMethodCode';
      v_method_name:=v_group->>'manualMethodName';
      IF v_method_code IS NULL OR v_method_name IS NULL THEN
        RAISE EXCEPTION 'El motor no devolvió el método manual configurado.';
      END IF;
      v_resolution_mode:='CONFIGURED_MANUAL_METHOD';
    ELSE
      IF char_length(btrim(COALESCE(p_notes,'')))<10 THEN
        RAISE EXCEPTION 'La resolución administrativa requiere motivo de al menos 10 caracteres.';
      END IF;
      v_resolution_mode:='COMMITTEE_OVERRIDE';
      v_method_code:='COMMITTEE_OVERRIDE';
      v_method_name:='Resolución administrativa';
    END IF;

    INSERT INTO public.tournament_tiebreak_resolutions(
      tournament_id,tournament_round_id,tournament_category_id,tipo_resultado,
      base_rank,tied_total,tie_size,source_engine_status,resolution_mode,
      method_code,method_name,notes,status,resolved_by_admin_user_id,resolved_at
    ) VALUES(
      v_tournament_id,p_tournament_round_id,p_tournament_category_id,p_tipo_resultado,
      p_base_rank,p_tied_total,v_group_size,v_group_status,v_resolution_mode,
      v_method_code,v_method_name,NULLIF(btrim(COALESCE(p_notes,'')),''),
      'COMPLETED',v_admin_user_id,now()
    ) RETURNING id INTO v_resolution_id;

    INSERT INTO public.tournament_tiebreak_resolution_players(
      resolution_id,score_card_id,player_id,player_name_snapshot,order_in_tiebreak,final_rank
    )
    SELECT v_resolution_id,x.score_card_id,NULL,
           COALESCE(gp->>'teamName',gp->>'playerName','(EQUIPO SIN NOMBRE)'),
           x.ord::integer,p_base_rank+x.ord::integer-1
    FROM unnest(p_score_card_order) WITH ORDINALITY x(score_card_id,ord)
    JOIN LATERAL(
      SELECT gp FROM jsonb_array_elements(COALESCE(v_group->'players','[]'::jsonb)) gp
      WHERE (gp->>'scoreCardId')::uuid=x.score_card_id LIMIT 1
    ) q(gp) ON true;

    INSERT INTO public.tournament_tiebreak_resolution_events(
      resolution_id,tournament_id,tournament_round_id,event_type,payload,actor_admin_user_id
    ) VALUES(
      v_resolution_id,v_tournament_id,p_tournament_round_id,'MANUAL_TIEBREAK_RESOLVED',
      jsonb_build_object(
        'scoringEngine','best_ball','competitiveUnit','TEAM',
        'tournamentCategoryId',p_tournament_category_id,'resultType',p_tipo_resultado,
        'baseRank',p_base_rank,'tiedTotal',p_tied_total,'tieSize',v_group_size,
        'sourceEngineStatus',v_group_status,'resolutionMode',v_resolution_mode,
        'methodCode',v_method_code,'methodName',v_method_name,
        'scoreCardOrder',to_jsonb(p_score_card_order),
        'notes',NULLIF(btrim(COALESCE(p_notes,'')),'')
      ),v_admin_user_id
    );

    RETURN jsonb_build_object(
      'resolutionId',v_resolution_id,'scoringEngine','best_ball',
      'competitiveUnit','TEAM','status','COMPLETED',
      'sourceEngineStatus',v_group_status,'resolutionMode',v_resolution_mode,
      'methodCode',v_method_code,'methodName',v_method_name,
      'teams',(SELECT jsonb_agg(jsonb_build_object(
        'scoreCardId',p.score_card_id,'teamName',p.player_name_snapshot,
        'tiebreakOrder',p.order_in_tiebreak,'finalRank',p.final_rank
      ) ORDER BY p.order_in_tiebreak)
      FROM public.tournament_tiebreak_resolution_players p
      WHERE p.resolution_id=v_resolution_id)
    );
END;
$function$;

COMMIT;
