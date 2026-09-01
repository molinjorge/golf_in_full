-- ============================================================================
-- MIGRACIÓN 212 FASE 9
-- A-Go-Go — desempates por equipo Gross / Neto
-- Proyecto: Tee Central / GOLF IN FULL
--
-- PRINCIPIOS
-- - Reutiliza tournament_tiebreak_rules + tiebreak_methods.
-- - Reutiliza evaluar_secuencia_desempate_tarjeta().
-- - Unidad de resolución = score_card_id del TEAM.
-- - Gross y Neto pueden tener reglas distintas.
-- - Para Neto, distribuye Team Playing Handicap por Stroke Index sólo para
--   construir officialNetScore por hoyo del countback.
-- - Resoluciones manuales reutilizan tablas comunes; player_id queda NULL y
--   player_name_snapshot guarda el nombre del equipo.
-- - Actualiza leaderboard A-Go-Go con finalRank/tiebreakStatus.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_desempates_a_gogo_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_results jsonb;
    v_tournament_id uuid;
    v_round_number integer;
    v_round_date date;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT tournament_id,numero_ronda,fecha
      INTO v_tournament_id,v_round_number,v_round_date
      FROM public.tournament_rounds
     WHERE id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar desempates A-Go-Go.'
            USING ERRCODE='42501';
    END IF;

    v_results :=
        public.obtener_resultados_a_gogo_oficiales_ronda(
            p_tournament_round_id
        );

    RETURN (
        WITH official_teams AS (
            SELECT
                (t->>'scoreCardId')::uuid AS score_card_id,
                sc.card_number,
                sc.card_folio,
                NULLIF(t->>'teamId','')::uuid AS team_id,
                t->>'teamName' AS team_name,
                NULLIF(t->>'tournamentCategoryId','')::uuid
                    AS tournament_category_id,
                t->>'categoryName' AS category_name,
                NULLIF(t->>'categoryDisplayOrder','')::integer
                    AS category_display_order,
                COALESCE(
                    (t#>>'{official,classification,grossEnabled}')::boolean,
                    false
                ) AS gross_enabled,
                COALESCE(
                    (t#>>'{official,classification,netEnabled}')::boolean,
                    false
                ) AS net_enabled,
                NULLIF(
                    t#>>'{official,result,officialGrossTotal}',''
                )::integer AS gross_total,
                NULLIF(
                    t#>>'{official,result,officialNetTotal}',''
                )::integer AS net_total,
                NULLIF(
                    t#>>'{official,handicap,teamPlayingHandicap}',''
                )::integer AS team_playing_handicap,
                t#>'{official,holes}' AS gross_holes
            FROM jsonb_array_elements(
                COALESCE(v_results->'teams','[]'::jsonb)
            ) t
            JOIN public.tournament_score_cards sc
              ON sc.id=(t->>'scoreCardId')::uuid
            WHERE COALESCE((t->>'ready')::boolean,false)=true
        ),

        team_holes AS (
            SELECT
                ot.score_card_id,
                ot.card_number,
                ot.card_folio,
                ot.team_id,
                ot.team_name,
                ot.tournament_category_id,
                ot.category_name,
                ot.category_display_order,
                ot.gross_enabled,
                ot.net_enabled,
                ot.gross_total,
                ot.net_total,
                ot.team_playing_handicap,
                jsonb_agg(
                    jsonb_build_object(
                        'roundHoleSnapshotId',
                            NULLIF(h->>'roundHoleSnapshotId','')::uuid,
                        'holeNumber',
                            NULLIF(h->>'holeNumber','')::integer,
                        'playSequence',
                            NULLIF(h->>'playSequence','')::integer,
                        'par',
                            NULLIF(h->>'par','')::integer,
                        'strokeIndex',
                            NULLIF(h->>'strokeIndex','')::integer,
                        'officialGrossScore',
                            NULLIF(h->>'officialGrossScore','')::integer,
                        'handicapStrokes',
                            public.calcular_golpes_handicap_hoyo(
                                ot.team_playing_handicap,
                                NULLIF(h->>'strokeIndex','')::integer,
                                jsonb_array_length(ot.gross_holes)
                            ),
                        'officialNetScore',
                            NULLIF(h->>'officialGrossScore','')::integer
                            - public.calcular_golpes_handicap_hoyo(
                                ot.team_playing_handicap,
                                NULLIF(h->>'strokeIndex','')::integer,
                                jsonb_array_length(ot.gross_holes)
                              )
                    )
                    ORDER BY
                        NULLIF(h->>'playSequence','')::integer,
                        NULLIF(h->>'holeNumber','')::integer
                ) AS holes
            FROM official_teams ot
            CROSS JOIN LATERAL jsonb_array_elements(ot.gross_holes) h
            GROUP BY
                ot.score_card_id,ot.card_number,ot.card_folio,
                ot.team_id,ot.team_name,ot.tournament_category_id,
                ot.category_name,ot.category_display_order,
                ot.gross_enabled,ot.net_enabled,ot.gross_total,
                ot.net_total,ot.team_playing_handicap
        ),

        metric_rows AS (
            SELECT th.*,
                   'gross'::public.tipo_resultado_desempate AS result_type,
                   th.gross_total AS metric_total
            FROM team_holes th
            WHERE th.gross_enabled

            UNION ALL

            SELECT th.*,
                   'neto'::public.tipo_resultado_desempate AS result_type,
                   th.net_total AS metric_total
            FROM team_holes th
            WHERE th.net_enabled
        ),

        ranked AS (
            SELECT
                mr.*,
                rank() OVER (
                    PARTITION BY mr.tournament_category_id,mr.result_type
                    ORDER BY mr.metric_total ASC
                )::integer AS base_rank,
                count(*) OVER (
                    PARTITION BY
                        mr.tournament_category_id,mr.result_type,mr.metric_total
                )::integer AS tie_size
            FROM metric_rows mr
        ),

        tied AS (
            SELECT
                r.*,
                CASE
                    WHEN r.base_rank=1
                        THEN 'primer_lugar'::public.alcance_desempate
                    ELSE 'otros_lugares'::public.alcance_desempate
                END AS scope
            FROM ranked r
            WHERE r.tie_size>1
        ),

        tie_groups AS (
            SELECT DISTINCT
                tournament_category_id,category_name,category_display_order,
                result_type,metric_total,base_rank,tie_size,scope
            FROM tied
        ),

        configured_groups AS (
            SELECT
                g.*,
                CASE
                    WHEN EXISTS (
                        SELECT 1
                        FROM public.tournament_tiebreak_rules r
                        WHERE r.tournament_id=v_tournament_id
                          AND r.activo=true
                          AND r.tipo_resultado=g.result_type
                          AND r.tournament_category_id=g.tournament_category_id
                          AND r.alcance=g.scope
                    ) THEN 'CATEGORY_SCOPE'
                    WHEN EXISTS (
                        SELECT 1
                        FROM public.tournament_tiebreak_rules r
                        WHERE r.tournament_id=v_tournament_id
                          AND r.activo=true
                          AND r.tipo_resultado=g.result_type
                          AND r.tournament_category_id=g.tournament_category_id
                          AND r.alcance='todos'::public.alcance_desempate
                    ) THEN 'CATEGORY_ALL'
                    WHEN EXISTS (
                        SELECT 1
                        FROM public.tournament_tiebreak_rules r
                        WHERE r.tournament_id=v_tournament_id
                          AND r.activo=true
                          AND r.tipo_resultado=g.result_type
                          AND r.tournament_category_id IS NULL
                          AND r.alcance=g.scope
                    ) THEN 'TOURNAMENT_SCOPE'
                    WHEN EXISTS (
                        SELECT 1
                        FROM public.tournament_tiebreak_rules r
                        WHERE r.tournament_id=v_tournament_id
                          AND r.activo=true
                          AND r.tipo_resultado=g.result_type
                          AND r.tournament_category_id IS NULL
                          AND r.alcance='todos'::public.alcance_desempate
                    ) THEN 'TOURNAMENT_ALL'
                    ELSE 'NONE'
                END AS rule_source
            FROM tie_groups g
        ),

        group_rules AS (
            SELECT
                cg.*,
                COALESCE((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'ruleId',r.id,
                            'order',r.orden,
                            'methodId',r.tiebreak_method_id,
                            'methodCode',m.code,
                            'methodName',m.name
                        )
                        ORDER BY r.orden
                    )
                    FROM public.tournament_tiebreak_rules r
                    JOIN public.tiebreak_methods m
                      ON m.id=r.tiebreak_method_id
                    WHERE r.tournament_id=v_tournament_id
                      AND r.activo=true
                      AND r.tipo_resultado=cg.result_type
                      AND (
                          (cg.rule_source='CATEGORY_SCOPE'
                           AND r.tournament_category_id=cg.tournament_category_id
                           AND r.alcance=cg.scope)
                          OR
                          (cg.rule_source='CATEGORY_ALL'
                           AND r.tournament_category_id=cg.tournament_category_id
                           AND r.alcance='todos'::public.alcance_desempate)
                          OR
                          (cg.rule_source='TOURNAMENT_SCOPE'
                           AND r.tournament_category_id IS NULL
                           AND r.alcance=cg.scope)
                          OR
                          (cg.rule_source='TOURNAMENT_ALL'
                           AND r.tournament_category_id IS NULL
                           AND r.alcance='todos'::public.alcance_desempate)
                      )
                ),'[]'::jsonb) AS rules
            FROM configured_groups cg
        ),

        team_eval AS (
            SELECT
                t.score_card_id,t.card_number,t.card_folio,t.team_id,t.team_name,
                t.tournament_category_id,t.category_name,t.category_display_order,
                t.result_type,t.metric_total,t.base_rank,t.tie_size,t.scope,
                gr.rule_source,gr.rules,
                public.evaluar_secuencia_desempate_tarjeta(
                    gr.rules,t.result_type,t.holes
                ) AS evaluation
            FROM tied t
            JOIN group_rules gr
              ON gr.tournament_category_id=t.tournament_category_id
             AND gr.result_type=t.result_type
             AND gr.metric_total=t.metric_total
             AND gr.base_rank=t.base_rank
        ),

        automatic_steps AS (
            SELECT
                te.tournament_category_id,te.result_type,te.metric_total,
                te.base_rank,te.tie_size,te.score_card_id,
                (s->>'order')::integer AS step_order,
                s->>'methodCode' AS method_code,
                s->>'methodName' AS method_name,
                s->'cumulativeKey' AS cumulative_key_json,
                ARRAY(
                    SELECT value::integer
                    FROM jsonb_array_elements_text(s->'cumulativeKey')
                ) AS cumulative_key
            FROM team_eval te
            CROSS JOIN LATERAL jsonb_array_elements(te.evaluation->'steps') s
            WHERE COALESCE((s->>'automatic')::boolean,false)=true
        ),

        step_uniqueness AS (
            SELECT
                tournament_category_id,result_type,metric_total,base_rank,
                step_order,min(method_code) AS method_code,
                min(method_name) AS method_name,
                count(DISTINCT cumulative_key_json::text) AS unique_keys,
                max(tie_size) AS group_size
            FROM automatic_steps
            GROUP BY
                tournament_category_id,result_type,metric_total,base_rank,step_order
        ),

        resolved_step AS (
            SELECT
                tournament_category_id,result_type,metric_total,base_rank,
                min(step_order) FILTER(WHERE unique_keys=group_size)
                    AS resolved_at_step
            FROM step_uniqueness
            GROUP BY tournament_category_id,result_type,metric_total,base_rank
        ),

        group_state AS (
            SELECT
                gr.*,rs.resolved_at_step,
                COALESCE(bool_or(
                    COALESCE((te.evaluation->>'stoppedAtManual')::boolean,false)
                ),false) AS stopped_at_manual,
                max(te.evaluation->>'manualMethodCode')
                    FILTER(WHERE COALESCE(
                        (te.evaluation->>'stoppedAtManual')::boolean,false
                    )) AS manual_method_code,
                max(te.evaluation->>'manualMethodName')
                    FILTER(WHERE COALESCE(
                        (te.evaluation->>'stoppedAtManual')::boolean,false
                    )) AS manual_method_name
            FROM group_rules gr
            LEFT JOIN resolved_step rs
              ON rs.tournament_category_id=gr.tournament_category_id
             AND rs.result_type=gr.result_type
             AND rs.metric_total=gr.metric_total
             AND rs.base_rank=gr.base_rank
            LEFT JOIN team_eval te
              ON te.tournament_category_id=gr.tournament_category_id
             AND te.result_type=gr.result_type
             AND te.metric_total=gr.metric_total
             AND te.base_rank=gr.base_rank
            GROUP BY
                gr.tournament_category_id,gr.category_name,
                gr.category_display_order,gr.result_type,gr.metric_total,
                gr.base_rank,gr.tie_size,gr.scope,gr.rule_source,gr.rules,
                rs.resolved_at_step
        ),

        group_final AS (
            SELECT
                gs.*,
                su.method_code AS resolved_method_code,
                su.method_name AS resolved_method_name,
                CASE
                    WHEN jsonb_array_length(gs.rules)=0
                        THEN 'CONFIG_MISSING'
                    WHEN gs.resolved_at_step IS NOT NULL
                        THEN 'RESOLVED_AUTOMATIC'
                    WHEN gs.stopped_at_manual
                        THEN 'MANUAL_PENDING'
                    ELSE 'TIE_PERSISTS_AFTER_RULES'
                END AS tiebreak_status
            FROM group_state gs
            LEFT JOIN step_uniqueness su
              ON su.tournament_category_id=gs.tournament_category_id
             AND su.result_type=gs.result_type
             AND su.metric_total=gs.metric_total
             AND su.base_rank=gs.base_rank
             AND su.step_order=gs.resolved_at_step
        ),

        team_resolution AS (
            SELECT
                te.*,gf.tiebreak_status,gf.resolved_at_step,
                step_at_resolution.cumulative_key AS resolution_key,
                CASE
                    WHEN gf.tiebreak_status='RESOLVED_AUTOMATIC'
                    THEN row_number() OVER (
                        PARTITION BY
                            te.tournament_category_id,te.result_type,
                            te.metric_total,te.base_rank
                        ORDER BY
                            step_at_resolution.cumulative_key ASC,
                            te.card_number ASC
                    )::integer
                    ELSE NULL
                END AS tiebreak_order
            FROM team_eval te
            JOIN group_final gf
              ON gf.tournament_category_id=te.tournament_category_id
             AND gf.result_type=te.result_type
             AND gf.metric_total=te.metric_total
             AND gf.base_rank=te.base_rank
            LEFT JOIN LATERAL (
                SELECT ARRAY(
                    SELECT value::integer
                    FROM jsonb_array_elements_text(s->'cumulativeKey')
                ) AS cumulative_key
                FROM jsonb_array_elements(te.evaluation->'steps') s
                WHERE (s->>'order')::integer=gf.resolved_at_step
                  AND COALESCE((s->>'automatic')::boolean,false)=true
                LIMIT 1
            ) step_at_resolution ON true
        ),

        group_counts AS (
            SELECT
                count(*) AS tie_groups,
                count(*) FILTER(
                    WHERE tiebreak_status='RESOLVED_AUTOMATIC'
                ) AS automatic_resolved,
                count(*) FILTER(
                    WHERE tiebreak_status='MANUAL_PENDING'
                ) AS manual_pending,
                count(*) FILTER(
                    WHERE tiebreak_status='CONFIG_MISSING'
                ) AS config_missing,
                count(*) FILTER(
                    WHERE tiebreak_status='TIE_PERSISTS_AFTER_RULES'
                ) AS persists_after_rules
            FROM group_final
        )

        SELECT jsonb_build_object(
            'round',jsonb_build_object(
                'tournamentId',v_tournament_id,
                'tournamentRoundId',p_tournament_round_id,
                'roundNumber',v_round_number,
                'roundDate',v_round_date,
                'participationType','equipo',
                'scoringEngine','team_stroke'
            ),
            'competitiveUnit','TEAM',
            'summary',(
                SELECT jsonb_build_object(
                    'tieGroups',tie_groups,
                    'automaticResolved',automatic_resolved,
                    'manualPending',manual_pending,
                    'configMissing',config_missing,
                    'persistsAfterRules',persists_after_rules,
                    'engineStatus',
                        CASE
                            WHEN tie_groups=0 THEN 'NO_TIES'
                            WHEN config_missing>0 THEN 'CONFIGURATION_REQUIRED'
                            WHEN manual_pending>0 OR persists_after_rules>0
                                THEN 'ACTION_REQUIRED'
                            ELSE 'RESOLVED'
                        END
                )
                FROM group_counts
            ),
            'tieGroups',COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'tournamentCategoryId',gf.tournament_category_id,
                        'categoryName',gf.category_name,
                        'resultType',gf.result_type,
                        'tiedTotal',gf.metric_total,
                        'baseRank',gf.base_rank,
                        'tieSize',gf.tie_size,
                        'scope',gf.scope,
                        'ruleSource',gf.rule_source,
                        'rules',gf.rules,
                        'status',gf.tiebreak_status,
                        'resolvedAtStep',gf.resolved_at_step,
                        'resolvedByMethodCode',gf.resolved_method_code,
                        'resolvedByMethodName',gf.resolved_method_name,
                        'manualMethodCode',gf.manual_method_code,
                        'manualMethodName',gf.manual_method_name,
                        'players',COALESCE((
                            SELECT jsonb_agg(
                                jsonb_build_object(
                                    'competitiveUnit','TEAM',
                                    'scoreCardId',tr.score_card_id,
                                    'cardFolio',tr.card_folio,
                                    'teamId',tr.team_id,
                                    'teamName',tr.team_name,
                                    'playerId',NULL,
                                    'playerName',tr.team_name,
                                    'baseRank',tr.base_rank,
                                    'tiebreakOrder',tr.tiebreak_order,
                                    'finalRank',
                                        CASE
                                            WHEN tr.tiebreak_order IS NOT NULL
                                            THEN tr.base_rank+tr.tiebreak_order-1
                                            ELSE NULL
                                        END,
                                    'resolutionKey',to_jsonb(tr.resolution_key),
                                    'evidence',tr.evaluation->'steps'
                                )
                                ORDER BY
                                    tr.tiebreak_order NULLS LAST,
                                    tr.card_number,tr.team_name
                            )
                            FROM team_resolution tr
                            WHERE tr.tournament_category_id=gf.tournament_category_id
                              AND tr.result_type=gf.result_type
                              AND tr.metric_total=gf.metric_total
                              AND tr.base_rank=gf.base_rank
                        ),'[]'::jsonb)
                    )
                    ORDER BY
                        gf.category_display_order NULLS LAST,
                        gf.category_name NULLS LAST,
                        gf.result_type,gf.base_rank,gf.metric_total
                )
                FROM group_final gf
            ),'[]'::jsonb)
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_desempates_a_gogo_ronda(uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.obtener_desempates_a_gogo_ronda(uuid)
TO authenticated,service_role;


CREATE OR REPLACE FUNCTION public.resolver_desempate_manual_a_gogo_ronda(
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
AS $$
DECLARE
    v_tournament_id uuid;
    v_admin_user_id uuid;
    v_engine jsonb;
    v_group jsonb;
    v_group_status text;
    v_manual_method_code text;
    v_manual_method_name text;
    v_resolution_mode text;
    v_method_code text;
    v_method_name text;
    v_group_size integer;
    v_order_size integer;
    v_distinct_order_size integer;
    v_group_match integer;
    v_resolution_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF NOT public._tipo_resultado_competitivo_ronda(
        p_tournament_round_id,p_tournament_category_id,p_tipo_resultado
    ) THEN
        RAISE EXCEPTION
            'El tipo de resultado % no es competitivo en esta categoría.',
            p_tipo_resultado::text
            USING ERRCODE='22023';
    END IF;

    SELECT tournament_id INTO v_tournament_id
    FROM public.tournament_rounds
    WHERE id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para resolver este desempate.'
            USING ERRCODE='42501';
    END IF;

    SELECT au.id INTO v_admin_user_id
    FROM public.admin_users au
    WHERE au.auth_user_id=auth.uid()
    ORDER BY au.id LIMIT 1;

    IF v_admin_user_id IS NULL THEN
        RAISE EXCEPTION 'No existe admin_user asociado.';
    END IF;

    IF p_score_card_order IS NULL
       OR COALESCE(array_length(p_score_card_order,1),0)<2
    THEN
        RAISE EXCEPTION 'Debe indicar el orden completo de al menos dos equipos empatados.';
    END IF;

    v_engine:=public.obtener_desempates_a_gogo_ronda(p_tournament_round_id);

    SELECT g INTO v_group
    FROM jsonb_array_elements(COALESCE(v_engine->'tieGroups','[]'::jsonb)) g
    WHERE NULLIF(g->>'tournamentCategoryId','')::uuid=p_tournament_category_id
      AND g->>'resultType'=p_tipo_resultado::text
      AND (g->>'baseRank')::integer=p_base_rank
      AND (g->>'tiedTotal')::integer=p_tied_total
    LIMIT 1;

    IF v_group IS NULL THEN
        RAISE EXCEPTION 'No existe actualmente ese grupo de empate A-Go-Go.'
            USING ERRCODE='55000';
    END IF;

    v_group_status:=v_group->>'status';
    v_group_size:=COALESCE((v_group->>'tieSize')::integer,0);

    IF v_group_status NOT IN('MANUAL_PENDING','TIE_PERSISTS_AFTER_RULES') THEN
        RAISE EXCEPTION 'El grupo no requiere resolución manual. Estado: %',
            COALESCE(v_group_status,'NULL') USING ERRCODE='55000';
    END IF;

    SELECT count(*)::integer,count(DISTINCT x)::integer
      INTO v_order_size,v_distinct_order_size
      FROM unnest(p_score_card_order) x;

    IF v_order_size<>v_group_size OR v_distinct_order_size<>v_group_size THEN
        RAISE EXCEPTION
            'El orden debe contener exactamente los % equipos del empate, sin duplicados.',
            v_group_size;
    END IF;

    SELECT count(*)::integer INTO v_group_match
    FROM unnest(p_score_card_order) x
    WHERE EXISTS(
        SELECT 1
        FROM jsonb_array_elements(COALESCE(v_group->'players','[]'::jsonb)) gp
        WHERE (gp->>'scoreCardId')::uuid=x
    );

    IF v_group_match<>v_group_size THEN
        RAISE EXCEPTION 'El orden contiene tarjetas que no pertenecen exactamente al empate.';
    END IF;

    IF EXISTS(
        SELECT 1 FROM public.tournament_tiebreak_resolutions r
        WHERE r.tournament_round_id=p_tournament_round_id
          AND r.tournament_category_id=p_tournament_category_id
          AND r.tipo_resultado=p_tipo_resultado
          AND r.base_rank=p_base_rank
          AND r.tied_total=p_tied_total
          AND r.status='COMPLETED'
    ) THEN
        RAISE EXCEPTION 'Este empate ya tiene resolución manual activa. Debe anularla antes.';
    END IF;

    IF v_group_status='MANUAL_PENDING' THEN
        v_manual_method_code:=v_group->>'manualMethodCode';
        v_manual_method_name:=v_group->>'manualMethodName';

        IF v_manual_method_code IS NULL OR v_manual_method_name IS NULL THEN
            RAISE EXCEPTION 'El motor no devolvió el método manual configurado.';
        END IF;

        v_resolution_mode:='CONFIGURED_MANUAL_METHOD';
        v_method_code:=v_manual_method_code;
        v_method_name:=v_manual_method_name;
    ELSE
        IF char_length(btrim(COALESCE(p_notes,'')))<10 THEN
            RAISE EXCEPTION
                'La resolución administrativa requiere motivo de al menos 10 caracteres.';
        END IF;

        v_resolution_mode:='COMMITTEE_OVERRIDE';
        v_method_code:='COMMITTEE_OVERRIDE';
        v_method_name:='Resolución administrativa';
    END IF;

    INSERT INTO public.tournament_tiebreak_resolutions(
        tournament_id,tournament_round_id,tournament_category_id,
        tipo_resultado,base_rank,tied_total,tie_size,source_engine_status,
        resolution_mode,method_code,method_name,notes,status,
        resolved_by_admin_user_id,resolved_at
    )
    VALUES(
        v_tournament_id,p_tournament_round_id,p_tournament_category_id,
        p_tipo_resultado,p_base_rank,p_tied_total,v_group_size,v_group_status,
        v_resolution_mode,v_method_code,v_method_name,
        NULLIF(btrim(COALESCE(p_notes,'')),''),
        'COMPLETED',v_admin_user_id,now()
    )
    RETURNING id INTO v_resolution_id;

    INSERT INTO public.tournament_tiebreak_resolution_players(
        resolution_id,score_card_id,player_id,player_name_snapshot,
        order_in_tiebreak,final_rank
    )
    SELECT
        v_resolution_id,x.score_card_id,NULL,
        COALESCE(gp->>'teamName',gp->>'playerName','(EQUIPO SIN NOMBRE)'),
        x.ord::integer,p_base_rank+x.ord::integer-1
    FROM unnest(p_score_card_order)
         WITH ORDINALITY AS x(score_card_id,ord)
    JOIN LATERAL(
        SELECT gp
        FROM jsonb_array_elements(COALESCE(v_group->'players','[]'::jsonb)) gp
        WHERE (gp->>'scoreCardId')::uuid=x.score_card_id
        LIMIT 1
    ) q(gp) ON true;

    INSERT INTO public.tournament_tiebreak_resolution_events(
        resolution_id,tournament_id,tournament_round_id,event_type,payload,
        actor_admin_user_id
    )
    VALUES(
        v_resolution_id,v_tournament_id,p_tournament_round_id,
        'MANUAL_TIEBREAK_RESOLVED',
        jsonb_build_object(
            'scoringEngine','team_stroke',
            'competitiveUnit','TEAM',
            'tournamentCategoryId',p_tournament_category_id,
            'resultType',p_tipo_resultado,
            'baseRank',p_base_rank,
            'tiedTotal',p_tied_total,
            'tieSize',v_group_size,
            'sourceEngineStatus',v_group_status,
            'resolutionMode',v_resolution_mode,
            'methodCode',v_method_code,
            'methodName',v_method_name,
            'scoreCardOrder',to_jsonb(p_score_card_order),
            'notes',NULLIF(btrim(COALESCE(p_notes,'')),'')
        ),
        v_admin_user_id
    );

    RETURN jsonb_build_object(
        'resolutionId',v_resolution_id,
        'scoringEngine','team_stroke',
        'competitiveUnit','TEAM',
        'status','COMPLETED',
        'sourceEngineStatus',v_group_status,
        'resolutionMode',v_resolution_mode,
        'methodCode',v_method_code,
        'methodName',v_method_name,
        'teams',(
            SELECT jsonb_agg(
                jsonb_build_object(
                    'scoreCardId',p.score_card_id,
                    'teamName',p.player_name_snapshot,
                    'tiebreakOrder',p.order_in_tiebreak,
                    'finalRank',p.final_rank
                )
                ORDER BY p.order_in_tiebreak
            )
            FROM public.tournament_tiebreak_resolution_players p
            WHERE p.resolution_id=v_resolution_id
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.resolver_desempate_manual_a_gogo_ronda(
    uuid,uuid,public.tipo_resultado_desempate,integer,integer,uuid[],text
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.resolver_desempate_manual_a_gogo_ronda(
    uuid,uuid,public.tipo_resultado_desempate,integer,integer,uuid[],text
) TO authenticated,service_role;


ALTER FUNCTION public.obtener_leaderboard_a_gogo_ronda(uuid)
RENAME TO _obtener_leaderboard_a_gogo_ronda_pre212;

CREATE OR REPLACE FUNCTION public.obtener_leaderboard_a_gogo_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_base jsonb;
    v_ties jsonb;
    v_categories jsonb:='[]'::jsonb;
    v_cat jsonb;
    v_players_out jsonb;
    v_player jsonb;
    v_player_out jsonb;
    v_type text;
    v_metric integer;
    v_rank integer;
    v_score_card_id uuid;
    v_group jsonb;
    v_auto_player jsonb;
    v_manual record;
    v_any_pending boolean:=false;
    v_unresolved integer;
BEGIN
    v_base:=public._obtener_leaderboard_a_gogo_ronda_pre212(
        p_tournament_round_id
    );
    v_ties:=public.obtener_desempates_a_gogo_ronda(
        p_tournament_round_id
    );

    FOR v_cat IN
        SELECT value FROM jsonb_array_elements(
            COALESCE(v_base->'categories','[]'::jsonb)
        )
    LOOP
        v_players_out:='[]'::jsonb;

        FOR v_player IN
            SELECT value FROM jsonb_array_elements(
                COALESCE(v_cat->'players','[]'::jsonb)
            )
        LOOP
            v_player_out:=v_player;
            v_score_card_id:=NULLIF(v_player->>'scoreCardId','')::uuid;

            FOREACH v_type IN ARRAY ARRAY['gross','neto']
            LOOP
                IF v_type='gross' THEN
                    IF NOT COALESCE((v_player#>>'{gross,enabled}')::boolean,false) THEN
                        CONTINUE;
                    END IF;
                    v_metric:=NULLIF(v_player#>>'{gross,total}','')::integer;
                    v_rank:=NULLIF(v_player#>>'{gross,rank}','')::integer;
                ELSE
                    IF NOT COALESCE((v_player#>>'{net,enabled}')::boolean,false) THEN
                        CONTINUE;
                    END IF;
                    v_metric:=NULLIF(v_player#>>'{net,total}','')::integer;
                    v_rank:=NULLIF(v_player#>>'{net,rank}','')::integer;
                END IF;

                IF v_metric IS NULL OR v_rank IS NULL THEN CONTINUE; END IF;

                SELECT g INTO v_group
                FROM jsonb_array_elements(
                    COALESCE(v_ties->'tieGroups','[]'::jsonb)
                ) g
                WHERE NULLIF(g->>'tournamentCategoryId','')::uuid
                      =NULLIF(v_cat->>'tournamentCategoryId','')::uuid
                  AND g->>'resultType'=v_type
                  AND (g->>'tiedTotal')::integer=v_metric
                  AND (g->>'baseRank')::integer=v_rank
                LIMIT 1;

                IF v_group IS NULL THEN CONTINUE; END IF;

                SELECT p INTO v_auto_player
                FROM jsonb_array_elements(
                    COALESCE(v_group->'players','[]'::jsonb)
                ) p
                WHERE (p->>'scoreCardId')::uuid=v_score_card_id
                LIMIT 1;

                SELECT rp.final_rank,r.method_code,r.method_name,r.id AS resolution_id
                  INTO v_manual
                  FROM public.tournament_tiebreak_resolutions r
                  JOIN public.tournament_tiebreak_resolution_players rp
                    ON rp.resolution_id=r.id
                 WHERE r.tournament_round_id=p_tournament_round_id
                   AND r.tournament_category_id=
                       NULLIF(v_cat->>'tournamentCategoryId','')::uuid
                   AND r.tipo_resultado::text=v_type
                   AND r.base_rank=v_rank
                   AND r.tied_total=v_metric
                   AND r.status='COMPLETED'
                   AND rp.score_card_id=v_score_card_id
                 LIMIT 1;

                IF v_type='gross' THEN
                    v_player_out:=jsonb_set(
                        v_player_out,'{gross,finalRank}',
                        to_jsonb(COALESCE(
                            v_manual.final_rank,
                            NULLIF(v_auto_player->>'finalRank','')::integer
                        )),true
                    );
                    v_player_out:=jsonb_set(
                        v_player_out,'{gross,tiebreakStatus}',
                        to_jsonb(CASE
                            WHEN v_manual.final_rank IS NOT NULL
                                THEN 'RESOLVED_MANUAL'
                            ELSE v_group->>'status'
                        END),true
                    );
                ELSE
                    v_player_out:=jsonb_set(
                        v_player_out,'{net,finalRank}',
                        to_jsonb(COALESCE(
                            v_manual.final_rank,
                            NULLIF(v_auto_player->>'finalRank','')::integer
                        )),true
                    );
                    v_player_out:=jsonb_set(
                        v_player_out,'{net,tiebreakStatus}',
                        to_jsonb(CASE
                            WHEN v_manual.final_rank IS NOT NULL
                                THEN 'RESOLVED_MANUAL'
                            ELSE v_group->>'status'
                        END),true
                    );
                END IF;

                IF COALESCE(
                    v_manual.final_rank,
                    NULLIF(v_auto_player->>'finalRank','')::integer
                ) IS NULL THEN
                    v_any_pending:=true;
                END IF;
            END LOOP;

            v_players_out:=v_players_out || jsonb_build_array(v_player_out);
        END LOOP;

        v_cat:=jsonb_set(v_cat,'{players}',v_players_out,true);
        v_categories:=v_categories || jsonb_build_array(v_cat);
    END LOOP;

    v_base:=jsonb_set(v_base,'{categories}',v_categories,true);

    v_unresolved:=COALESCE(
        NULLIF(v_base#>>'{summary,unresolvedParticipants}','')::integer,0
    );

    v_base:=jsonb_set(
        v_base,'{status,leaderboardStatus}',
        to_jsonb(CASE
            WHEN v_unresolved>0 THEN 'PROVISIONAL'
            WHEN v_any_pending THEN 'READY_FOR_TIEBREAK'
            ELSE 'READY_FOR_PUBLICATION'
        END),true
    );

    RETURN v_base;
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_leaderboard_a_gogo_ronda(uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.obtener_leaderboard_a_gogo_ronda(uuid)
TO authenticated,service_role;

COMMIT;
