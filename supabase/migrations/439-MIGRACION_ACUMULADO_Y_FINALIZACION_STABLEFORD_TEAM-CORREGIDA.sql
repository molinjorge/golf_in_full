-- 439-MIGRACION_ACUMULADO_Y_FINALIZACION_STABLEFORD_TEAM.sql
-- TEE CENTRAL / GOLF IN FULL
-- Ejecutar manualmente en Supabase. Lovable NO ejecuta migraciones.
--
-- Objetivo:
-- 1) Crear clasificación acumulada Stableford TEAM sumando puntos TEAM por ronda.
-- 2) Reutilizar el desempate Stableford multirronda sobre la última ronda.
-- 3) Hacer que la previsualización/finalización reconozca torneos compuestos
--    íntegramente por STABLEFORD_EQUIPO.
--
-- No crea tarjeta TEAM ni modifica resultados deportivos existentes.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_leaderboard_stableford_team_torneo_439(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_rounds jsonb := '[]'::jsonb;
    v_required_rounds integer := 0;
    v_last_round_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para consultar el acumulado Stableford TEAM.'
            USING ERRCODE='42501';
    END IF;

    SELECT count(*)::integer
      INTO v_required_rounds
      FROM public.tournament_rounds tr
      JOIN LATERAL (
        SELECT s.scoring_engine,s.participation_type,s.format_code
        FROM public.tournament_round_condition_snapshots s
        WHERE s.tournament_round_id=tr.id
        ORDER BY s.created_at DESC,s.id DESC
        LIMIT 1
      ) rcs ON true
     WHERE tr.tournament_id=p_tournament_id
       AND tr.activo=true
       AND rcs.scoring_engine='stableford'
       AND rcs.participation_type='equipo'
       AND rcs.format_code='STABLEFORD_EQUIPO';

    IF v_required_rounds=0 THEN
        RAISE EXCEPTION 'El torneo no tiene rondas Stableford por equipos congeladas.'
            USING ERRCODE='55000';
    END IF;

    SELECT tr.id
      INTO v_last_round_id
      FROM public.tournament_rounds tr
      JOIN LATERAL (
        SELECT s.scoring_engine,s.participation_type,s.format_code
        FROM public.tournament_round_condition_snapshots s
        WHERE s.tournament_round_id=tr.id
        ORDER BY s.created_at DESC,s.id DESC
        LIMIT 1
      ) rcs ON true
     WHERE tr.tournament_id=p_tournament_id
       AND tr.activo=true
       AND rcs.scoring_engine='stableford'
       AND rcs.participation_type='equipo'
       AND rcs.format_code='STABLEFORD_EQUIPO'
     ORDER BY tr.numero_ronda DESC,tr.fecha DESC,tr.id DESC
     LIMIT 1;

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
          'tournamentRoundId',tr.id,
          'roundNumber',tr.numero_ronda,
          'roundDate',tr.fecha,
          'leaderboard',public.obtener_leaderboard_stableford_team_ronda_438(tr.id)
        )
        ORDER BY tr.numero_ronda,tr.fecha,tr.id
    ),'[]'::jsonb)
      INTO v_rounds
      FROM public.tournament_rounds tr
      JOIN LATERAL (
        SELECT s.scoring_engine,s.participation_type,s.format_code
        FROM public.tournament_round_condition_snapshots s
        WHERE s.tournament_round_id=tr.id
        ORDER BY s.created_at DESC,s.id DESC
        LIMIT 1
      ) rcs ON true
     WHERE tr.tournament_id=p_tournament_id
       AND tr.activo=true
       AND rcs.scoring_engine='stableford'
       AND rcs.participation_type='equipo'
       AND rcs.format_code='STABLEFORD_EQUIPO';

    RETURN (
      WITH round_teams AS (
        SELECT
          NULLIF(r->>'tournamentRoundId','')::uuid round_id,
          NULLIF(r->>'roundNumber','')::integer round_number,
          NULLIF(r->>'roundDate','')::date round_date,
          NULLIF(c->>'tournamentCategoryId','')::uuid category_id,
          c->>'categoryCode' category_code,
          c->>'categoryName' category_name,
          NULLIF(c->>'categoryDisplayOrder','')::integer category_order,
          NULLIF(p->>'teamId','')::uuid team_id,
          p->>'teamName' team_name,
          COALESCE((p->>'eligibleForRanking')::boolean,false) ready,
          COALESCE((p#>>'{gross,enabled}')::boolean,false) gross_enabled,
          NULLIF(p#>>'{gross,points}','')::integer gross_points,
          COALESCE((p#>>'{net,enabled}')::boolean,false) net_enabled,
          NULLIF(p#>>'{net,points}','')::integer net_points,
          COALESCE(p->'holes','[]'::jsonb) holes
        FROM jsonb_array_elements(v_rounds) r
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(r->'leaderboard'->'categories','[]'::jsonb)) c
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(c->'players','[]'::jsonb)) p
      ),
      team_totals AS (
        SELECT
          rt.team_id,max(rt.team_name) team_name,rt.category_id,
          max(rt.category_code) category_code,max(rt.category_name) category_name,
          max(rt.category_order) category_order,
          count(DISTINCT rt.round_id)::integer rounds_present,
          count(DISTINCT rt.round_id) FILTER(WHERE rt.ready)::integer rounds_ready,
          bool_and(rt.gross_enabled) gross_enabled,
          bool_and(rt.net_enabled) net_enabled,
          sum(rt.gross_points) FILTER(WHERE rt.ready)::integer gross_total,
          sum(rt.net_points) FILTER(WHERE rt.ready)::integer net_total,
          jsonb_agg(jsonb_build_object(
            'tournamentRoundId',rt.round_id,'roundNumber',rt.round_number,
            'roundDate',rt.round_date,'ready',rt.ready,
            'grossPoints',rt.gross_points,'netPoints',rt.net_points
          ) ORDER BY rt.round_number,rt.round_date,rt.round_id) rounds,
          max(rt.gross_points) FILTER(WHERE rt.round_id=v_last_round_id) gross_last,
          max(rt.net_points) FILTER(WHERE rt.round_id=v_last_round_id) net_last,
          max(rt.holes::text) FILTER(WHERE rt.round_id=v_last_round_id)::jsonb last_holes
        FROM round_teams rt
        GROUP BY rt.team_id,rt.category_id
      ),
      eligible AS (
        SELECT tt.*,
          (tt.rounds_present=v_required_rounds AND tt.rounds_ready=v_required_rounds) eligible
        FROM team_totals tt
      ),
      metrics AS (
        SELECT e.*,'gross'::public.tipo_resultado_desempate result_type,e.gross_total metric_total
        FROM eligible e WHERE e.eligible AND e.gross_enabled
        UNION ALL
        SELECT e.*,'neto'::public.tipo_resultado_desempate,e.net_total
        FROM eligible e WHERE e.eligible AND e.net_enabled
      ),
      ranked AS (
        SELECT m.*,
          rank() over(partition by category_id,result_type order by metric_total desc)::integer base_rank,
          count(*) over(partition by category_id,result_type,metric_total)::integer tie_size
        FROM metrics m
      ),
      tied AS (
        SELECT r.*,
          CASE WHEN r.base_rank=1 THEN 'primer_lugar'::public.alcance_desempate
               ELSE 'otros_lugares'::public.alcance_desempate END scope
        FROM ranked r WHERE r.tie_size>1
      ),
      configured AS (
        SELECT t.*,
          COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'ruleId',rr.id,'order',rr.orden,'methodId',rr.tiebreak_method_id,
              'methodCode',tm.code,'methodName',tm.name
            ) ORDER BY rr.orden)
            FROM public.tournament_tiebreak_rules rr
            JOIN public.tiebreak_methods tm ON tm.id=rr.tiebreak_method_id
            WHERE rr.tournament_id=p_tournament_id AND rr.activo
              AND rr.tipo_resultado=t.result_type
              AND (
                (rr.tournament_category_id=t.category_id AND rr.alcance=t.scope)
                OR
                (rr.tournament_category_id=t.category_id AND rr.alcance='todos'::public.alcance_desempate
                  AND NOT EXISTS(
                    SELECT 1 FROM public.tournament_tiebreak_rules x
                    WHERE x.tournament_id=p_tournament_id AND x.activo
                      AND x.tipo_resultado=t.result_type
                      AND x.tournament_category_id=t.category_id AND x.alcance=t.scope))
                OR
                (rr.tournament_category_id IS NULL AND rr.alcance=t.scope
                  AND NOT EXISTS(
                    SELECT 1 FROM public.tournament_tiebreak_rules x
                    WHERE x.tournament_id=p_tournament_id AND x.activo
                      AND x.tipo_resultado=t.result_type
                      AND x.tournament_category_id=t.category_id))
                OR
                (rr.tournament_category_id IS NULL AND rr.alcance='todos'::public.alcance_desempate
                  AND NOT EXISTS(
                    SELECT 1 FROM public.tournament_tiebreak_rules x
                    WHERE x.tournament_id=p_tournament_id AND x.activo
                      AND x.tipo_resultado=t.result_type
                      AND (x.tournament_category_id=t.category_id OR x.alcance=t.scope)))
              )
          ),'[]'::jsonb) rules
        FROM tied t
      ),
      evaluated AS (
        SELECT c.*,
          public.evaluar_secuencia_desempate_stableford_multirronda(
            c.rules,c.result_type,
            jsonb_build_object(
              'tournamentRoundId',v_last_round_id,
              'grossPoints',c.gross_last,'netPoints',c.net_last
            ),
            c.last_holes
          ) evaluation
        FROM configured c
      ),
      steps AS (
        SELECT e.category_id,e.result_type,e.metric_total,e.base_rank,e.tie_size,e.team_id,
          (s->>'order')::integer step_order,
          s->>'methodCode' method_code,s->>'methodName' method_name,
          s->'cumulativeKey' key_json,
          ARRAY(SELECT value::integer FROM jsonb_array_elements_text(s->'cumulativeKey')) key_array
        FROM evaluated e
        CROSS JOIN LATERAL jsonb_array_elements(e.evaluation->'steps') s
        WHERE COALESCE((s->>'automatic')::boolean,false)
      ),
      uniqueness AS (
        SELECT category_id,result_type,metric_total,base_rank,step_order,
          min(method_code) method_code,min(method_name) method_name,
          count(DISTINCT key_json::text) unique_keys,max(tie_size) group_size
        FROM steps
        GROUP BY category_id,result_type,metric_total,base_rank,step_order
      ),
      resolved AS (
        SELECT category_id,result_type,metric_total,base_rank,
          min(step_order) FILTER(WHERE unique_keys=group_size) resolved_step
        FROM uniqueness
        GROUP BY category_id,result_type,metric_total,base_rank
      ),
      tie_resolution AS (
        SELECT e.category_id,e.result_type,e.metric_total,e.base_rank,e.team_id,
          rs.resolved_step,
          st.key_array,
          CASE WHEN rs.resolved_step IS NOT NULL THEN
            row_number() over(
              partition by e.category_id,e.result_type,e.metric_total,e.base_rank
              order by st.key_array asc,e.team_name,e.team_id
            )::integer
          END tie_order
        FROM evaluated e
        LEFT JOIN resolved rs
          ON rs.category_id=e.category_id AND rs.result_type=e.result_type
         AND rs.metric_total=e.metric_total AND rs.base_rank=e.base_rank
        LEFT JOIN steps st
          ON st.category_id=e.category_id AND st.result_type=e.result_type
         AND st.metric_total=e.metric_total AND st.base_rank=e.base_rank
         AND st.team_id=e.team_id AND st.step_order=rs.resolved_step
      ),
      final_metrics AS (
        SELECT r.*,
          CASE WHEN r.tie_size<=1 THEN r.base_rank
               WHEN tr.resolved_step IS NOT NULL THEN r.base_rank+tr.tie_order-1
               ELSE NULL END final_rank,
          CASE WHEN r.tie_size<=1 THEN 'NOT_NEEDED'
               WHEN tr.resolved_step IS NOT NULL THEN 'RESOLVED_AUTOMATIC'
               ELSE 'PENDING' END tiebreak_status
        FROM ranked r
        LEFT JOIN tie_resolution tr
          ON tr.category_id=r.category_id AND tr.result_type=r.result_type
         AND tr.metric_total=r.metric_total AND tr.base_rank=r.base_rank
         AND tr.team_id=r.team_id
      ),
      team_final AS (
        SELECT e.*,
          g.base_rank gross_base_rank,g.tie_size gross_tie_size,g.final_rank gross_final_rank,
          g.tiebreak_status gross_tiebreak_status,
          n.base_rank net_base_rank,n.tie_size net_tie_size,n.final_rank net_final_rank,
          n.tiebreak_status net_tiebreak_status
        FROM eligible e
        LEFT JOIN final_metrics g ON g.team_id=e.team_id AND g.category_id=e.category_id AND g.result_type='gross'
        LEFT JOIN final_metrics n ON n.team_id=e.team_id AND n.category_id=e.category_id AND n.result_type='neto'
      ),
      summary AS (
        SELECT count(*)::integer teams,
          count(*) FILTER(WHERE eligible)::integer ranking_eligible,
          count(*) FILTER(WHERE NOT eligible)::integer pending_teams,
          count(*) FILTER(WHERE eligible AND (
            (gross_enabled AND gross_tie_size>1 AND gross_final_rank IS NULL)
            OR (net_enabled AND net_tie_size>1 AND net_final_rank IS NULL)
          ))::integer teams_with_pending_tie
        FROM team_final
      )
      SELECT jsonb_build_object(
        'supported',true,'applicable',true,'schemaVersion',1,
        'tournamentId',p_tournament_id,'competitiveUnit','TEAM',
        'roundsRequired',v_required_rounds,
        'status',jsonb_build_object(
          'leaderboardStatus',CASE
            WHEN (SELECT pending_teams FROM summary)>0 THEN 'PROVISIONAL'
            WHEN (SELECT teams_with_pending_tie FROM summary)>0 THEN 'READY_FOR_TIEBREAK'
            ELSE 'READY_FOR_PUBLICATION' END
        ),
        'summary',(SELECT jsonb_build_object(
          'teams',teams,'rankingEligible',ranking_eligible,
          'pendingTeams',pending_teams,'teamsWithPendingTie',teams_with_pending_tie
        ) FROM summary),
        'categories',COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'tournamentCategoryId',x.category_id,
            'categoryCode',x.category_code,'categoryName',x.category_name,
            'categoryDisplayOrder',x.category_order,
            'teams',COALESCE((
              SELECT jsonb_agg(jsonb_build_object(
                'competitiveUnit','TEAM','teamId',f.team_id,'teamName',f.team_name,
                'eligibleForRanking',f.eligible,'rounds',f.rounds,
                'gross',jsonb_build_object(
                  'enabled',f.gross_enabled,'points',f.gross_total,
                  'baseRank',f.gross_base_rank,'tieSize',f.gross_tie_size,
                  'finalRank',f.gross_final_rank,'tiebreakStatus',f.gross_tiebreak_status),
                'net',jsonb_build_object(
                  'enabled',f.net_enabled,'points',f.net_total,
                  'baseRank',f.net_base_rank,'tieSize',f.net_tie_size,
                  'finalRank',f.net_final_rank,'tiebreakStatus',f.net_tiebreak_status)
              ) ORDER BY
                COALESCE(f.net_final_rank,f.gross_final_rank,f.net_base_rank,f.gross_base_rank) NULLS LAST,
                f.team_name,f.team_id)
              FROM team_final f WHERE f.category_id IS NOT DISTINCT FROM x.category_id
            ),'[]'::jsonb)
          ) ORDER BY x.category_order NULLS LAST,x.category_name)
          FROM (
            SELECT DISTINCT category_id,category_code,category_name,category_order
            FROM team_final
          ) x
        ),'[]'::jsonb)
      )
    );
END;
$function$;

COMMENT ON FUNCTION public.obtener_leaderboard_stableford_team_torneo_439(uuid)
IS '439: clasificación acumulada Stableford TEAM; suma puntos TEAM de todas las rondas requeridas y reutiliza desempate Stableford multirronda sobre la última ronda.';

-- Sustitución controlada del preview histórico.
-- Se conserva su contrato y gates; únicamente se agrega STABLEFORD_TEAM.
CREATE OR REPLACE FUNCTION public._previsualizar_finalizacion_torneo_pre314(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
    v_existing public.tournament_competitive_finalizations%ROWTYPE;
    v_total_rounds integer := 0;
    v_closed_rounds integer := 0;
    v_pending_rounds integer := 0;
    v_rounds jsonb := '[]'::jsonb;
    v_frozen_active_rounds integer := 0;
    v_stableford_individual_rounds integer := 0;
    v_stableford_team_rounds integer := 0;
    v_stableford_other_rounds integer := 0;
    v_non_stableford_rounds integer := 0;
    v_competition_mode text := 'LEGACY_OR_NON_STABLEFORD';
    v_aggregate_required boolean := false;
    v_aggregate_ready boolean := true;
    v_aggregate_status text := 'NOT_REQUIRED';
    v_aggregate_leaderboard jsonb := NULL;
    v_ready_to_finalize boolean := false;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF NOT (public.is_superadmin(auth.uid())
       OR public.is_tournament_organizer(auth.uid(),p_tournament_id)) THEN
        RAISE EXCEPTION 'Sólo el organizador asignado o el Superadmin pueden consultar la finalización del torneo.'
            USING ERRCODE='42501';
    END IF;

    SELECT * INTO v_t FROM public.tournaments WHERE id=p_tournament_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='22023';
    END IF;

    SELECT * INTO v_existing
    FROM public.tournament_competitive_finalizations f
    WHERE f.tournament_id=p_tournament_id;

    SELECT count(*)::integer,
           count(*) FILTER(WHERE c.id IS NOT NULL AND c.competitive_status='FINAL')::integer,
           count(*) FILTER(WHERE c.id IS NULL OR c.competitive_status<>'FINAL')::integer,
           COALESCE(jsonb_agg(jsonb_build_object(
             'tournamentRoundId',tr.id,'roundNumber',tr.numero_ronda,'roundDate',tr.fecha,
             'active',tr.activo,'closed',c.id IS NOT NULL,
             'competitiveStatus',c.competitive_status,'closureId',c.id,
             'closedAt',c.closed_at,'closedByAdminUserId',c.closed_by_admin_user_id
           ) ORDER BY tr.numero_ronda,tr.fecha,tr.id),'[]'::jsonb)
      INTO v_total_rounds,v_closed_rounds,v_pending_rounds,v_rounds
      FROM public.tournament_rounds tr
      LEFT JOIN public.tournament_round_competitive_closures c
        ON c.tournament_round_id=tr.id
     WHERE tr.tournament_id=p_tournament_id AND tr.activo=true;

    WITH active_round_modes AS (
      SELECT tr.id tournament_round_id,s.scoring_engine,s.participation_type
      FROM public.tournament_rounds tr
      LEFT JOIN LATERAL (
        SELECT rcs.scoring_engine,rcs.participation_type
        FROM public.tournament_round_condition_snapshots rcs
        WHERE rcs.tournament_round_id=tr.id
        ORDER BY rcs.created_at DESC,rcs.id DESC LIMIT 1
      ) s ON true
      WHERE tr.tournament_id=p_tournament_id AND tr.activo=true
    )
    SELECT
      count(*) FILTER(WHERE scoring_engine IS NOT NULL)::integer,
      count(*) FILTER(WHERE scoring_engine='stableford' AND participation_type='individual')::integer,
      count(*) FILTER(WHERE scoring_engine='stableford' AND participation_type='equipo')::integer,
      count(*) FILTER(WHERE scoring_engine='stableford'
                        AND participation_type IS DISTINCT FROM 'individual'
                        AND participation_type IS DISTINCT FROM 'equipo')::integer,
      count(*) FILTER(WHERE scoring_engine IS NOT NULL AND scoring_engine<>'stableford')::integer
    INTO v_frozen_active_rounds,v_stableford_individual_rounds,v_stableford_team_rounds,
         v_stableford_other_rounds,v_non_stableford_rounds
    FROM active_round_modes;

    IF v_total_rounds>0
       AND v_frozen_active_rounds=v_total_rounds
       AND v_stableford_individual_rounds=v_total_rounds THEN
        v_competition_mode:='STABLEFORD_INDIVIDUAL';
        v_aggregate_required:=true;
        v_aggregate_leaderboard:=public.obtener_leaderboard_stableford_torneo(p_tournament_id);
        v_aggregate_status:=COALESCE(v_aggregate_leaderboard#>>'{status,leaderboardStatus}','UNKNOWN');
        v_aggregate_ready:=v_aggregate_status='READY_FOR_PUBLICATION';

    ELSIF v_total_rounds>0
       AND v_frozen_active_rounds=v_total_rounds
       AND v_stableford_team_rounds=v_total_rounds THEN
        v_competition_mode:='STABLEFORD_TEAM';
        v_aggregate_required:=true;
        v_aggregate_leaderboard:=public.obtener_leaderboard_stableford_team_torneo_439(p_tournament_id);
        v_aggregate_status:=COALESCE(v_aggregate_leaderboard#>>'{status,leaderboardStatus}','UNKNOWN');
        v_aggregate_ready:=v_aggregate_status='READY_FOR_PUBLICATION';

    ELSIF v_stableford_individual_rounds>0
       OR v_stableford_team_rounds>0
       OR v_stableford_other_rounds>0 THEN
        v_competition_mode:='MIXED_OR_UNSUPPORTED';
        v_aggregate_required:=true;
        v_aggregate_ready:=false;
        v_aggregate_status:='UNSUPPORTED_TOURNAMENT_COMPOSITION';
    ELSE
        v_competition_mode:='LEGACY_OR_NON_STABLEFORD';
        v_aggregate_required:=false;
        v_aggregate_ready:=true;
        v_aggregate_status:='NOT_REQUIRED';
        v_aggregate_leaderboard:=NULL;
    END IF;

    v_ready_to_finalize:=(
      v_t.estatus='en_curso'::public.estatus_torneo
      AND v_total_rounds>0
      AND v_pending_rounds=0
      AND v_aggregate_ready
    );

    RETURN jsonb_build_object(
      'schemaVersion',2,'tournamentId',p_tournament_id,'tournamentName',v_t.nombre,
      'estatus',v_t.estatus::text,
      'alreadyFinalized',(v_existing.id IS NOT NULL OR v_t.estatus='finalizado'::public.estatus_torneo),
      'readyToFinalize',v_ready_to_finalize,
      'summary',jsonb_build_object('activeRounds',v_total_rounds,'closedRounds',v_closed_rounds,'pendingRounds',v_pending_rounds),
      'competition',jsonb_build_object(
        'mode',v_competition_mode,'frozenActiveRounds',v_frozen_active_rounds,
        'stablefordIndividualRounds',v_stableford_individual_rounds,
        'stablefordTeamRounds',v_stableford_team_rounds,
        'stablefordOtherRounds',v_stableford_other_rounds,
        'nonStablefordRounds',v_non_stableford_rounds),
      'aggregateCompetition',jsonb_build_object(
        'required',v_aggregate_required,'ready',v_aggregate_ready,
        'leaderboardStatus',v_aggregate_status,'leaderboard',v_aggregate_leaderboard),
      'rounds',v_rounds,
      'finalization',CASE WHEN v_existing.id IS NULL THEN NULL ELSE jsonb_build_object(
        'id',v_existing.id,'status',v_existing.status,'finalizedAt',v_existing.finalized_at,
        'finalizedByAdminUserId',v_existing.finalized_by_admin_user_id,
        'notes',v_existing.notes,'snapshot',v_existing.finalization_snapshot) END
    );
END;
$function$;

COMMENT ON FUNCTION public._previsualizar_finalizacion_torneo_pre314(uuid)
IS '439: preview histórico ampliado para STABLEFORD_TEAM; conserva gates y contratos previos.';

COMMIT;
