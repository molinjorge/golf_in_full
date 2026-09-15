-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 328
-- BEST BALL F14 — CONTRATO OPERATIVO + VALIDACION + CIERRE/PUBLICACION
-- ============================================================================
-- PRINCIPIO:
--   Best Ball se integra al ciclo común SIN reescribir Stroke, Stableford
--   ni A-Go-Go. Las funciones previas quedan detrás de wrappers pre328.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1) Leaderboard Best Ball enriquecido para el contrato competitivo común.
--    F12 (326) sigue siendo autoridad de ranking; aquí sólo se agregan
--    metadatos/summary necesarios para cierre y formalización.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_leaderboard_best_ball_ronda_328(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_base jsonb;
    v_tournament_id uuid;
    v_validation_id uuid;
    v_freeze_id uuid;
    v_categories jsonb;
BEGIN
    v_base := public.obtener_leaderboard_best_ball_ronda_326(p_tournament_round_id);
    v_tournament_id := NULLIF(v_base#>>'{round,tournamentId}','')::uuid;

    SELECT v.id,v.freeze_id
      INTO v_validation_id,v_freeze_id
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_round_id=p_tournament_round_id
       AND v.status='valid'
     ORDER BY v.validation_version DESC,v.validated_at DESC,v.id DESC
     LIMIT 1;

    WITH base_categories AS (
      SELECT c,
             NULLIF(c->>'tournamentCategoryId','')::uuid category_id
      FROM jsonb_array_elements(COALESCE(v_base->'categories','[]'::jsonb)) c
    ),
    catalog AS (
      SELECT s.tournament_category_id,
             min(s.category_display_order) category_display_order
      FROM public.tournament_category_classification_snapshots s
      WHERE s.freeze_id=v_freeze_id
      GROUP BY s.tournament_category_id
    ),
    issued AS (
      SELECT sc.id score_card_id,sc.tournament_category_id,
             sc.tournament_team_id,sc.card_folio,
             ss.team_name,
             o.outcome_code
      FROM public.tournament_score_cards sc
      JOIN public.tournament_best_ball_scorecard_snapshots ss
        ON ss.score_card_id=sc.id
      LEFT JOIN public.tournament_scorecard_round_outcomes o
        ON o.score_card_id=sc.id
      WHERE sc.tournament_round_id=p_tournament_round_id
        AND sc.validation_id=v_validation_id
        AND sc.unit_type='team'
        AND sc.status='issued'
    ),
    official AS (
      SELECT DISTINCT
        NULLIF(t->>'scoreCardId','')::uuid score_card_id,
        bc.category_id
      FROM base_categories bc
      CROSS JOIN LATERAL jsonb_array_elements(COALESCE(bc.c->'teams','[]'::jsonb)) t
    ),
    counts AS (
      SELECT
        i.tournament_category_id category_id,
        count(*)::integer total_participants,
        count(*) FILTER(WHERE o.score_card_id IS NOT NULL)::integer ranked_participants,
        count(*) FILTER(
          WHERE o.score_card_id IS NOT NULL
             OR i.outcome_code IN('WD','DNF','DQ','DNS','NO_CARD')
        )::integer resolved_participants,
        count(*) FILTER(
          WHERE o.score_card_id IS NULL
            AND COALESCE(i.outcome_code NOT IN('WD','DNF','DQ','DNS','NO_CARD'),true)
        )::integer unresolved_participants,
        count(*) FILTER(
          WHERE i.outcome_code IN('WD','DNF','DQ','DNS','NO_CARD')
        )::integer terminal_exceptions
      FROM issued i
      LEFT JOIN official o ON o.score_card_id=i.score_card_id
      GROUP BY i.tournament_category_id
    )
    SELECT COALESCE(jsonb_agg(
      jsonb_set(
        jsonb_set(
          bc.c,
          '{categoryDisplayOrder}',
          to_jsonb(cat.category_display_order),
          true
        ),
        '{summary}',
        jsonb_build_object(
          'totalParticipants',COALESCE(ct.total_participants,0),
          'rankedParticipants',COALESCE(ct.ranked_participants,0),
          'resolvedParticipants',COALESCE(ct.resolved_participants,0),
          'unresolvedParticipants',COALESCE(ct.unresolved_participants,0),
          'terminalExceptions',COALESCE(ct.terminal_exceptions,0)
        ),
        true
      )
      ORDER BY cat.category_display_order NULLS LAST,bc.c->>'categoryName'
    ),'[]'::jsonb)
    INTO v_categories
    FROM base_categories bc
    LEFT JOIN catalog cat ON cat.tournament_category_id=bc.category_id
    LEFT JOIN counts ct ON ct.category_id=bc.category_id;

    v_base := jsonb_set(v_base,'{categories}',v_categories,true);
    v_base := jsonb_set(v_base,'{round,scoringEngine}',to_jsonb('best_ball'::text),true);
    v_base := jsonb_set(v_base,'{round,participationType}',to_jsonb('equipo'::text),true);
    v_base := jsonb_set(v_base,'{round,competitiveUnit}',to_jsonb('TEAM'::text),true);
    v_base := jsonb_set(v_base,'{source,rpc}',to_jsonb('obtener_leaderboard_best_ball_ronda_328'::text),true);

    RETURN v_base;
END;
$function$;

-- --------------------------------------------------------------------------
-- 2) Validador de cierre de resultados Best Ball.
--    Outcome terminal común resuelve una tarjeta TEAM sin resultado oficial.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validar_cierre_resultados_best_ball_328(
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
    v_lb := public.obtener_leaderboard_best_ball_ronda_328(p_tournament_round_id);
    v_tournament_id := NULLIF(v_lb#>>'{round,tournamentId}','')::uuid;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
      RAISE EXCEPTION 'No tienes permiso administrativo para validar esta ronda.'
        USING ERRCODE='42501';
    END IF;

    RETURN (
      WITH cats AS (
        SELECT c
        FROM jsonb_array_elements(COALESCE(v_lb->'categories','[]'::jsonb)) c
      ),
      totals AS (
        SELECT
          COALESCE(sum(NULLIF(c#>>'{summary,totalParticipants}','')::integer),0)::integer total_teams,
          COALESCE(sum(NULLIF(c#>>'{summary,rankedParticipants}','')::integer),0)::integer official_teams,
          COALESCE(sum(NULLIF(c#>>'{summary,resolvedParticipants}','')::integer),0)::integer resolved_teams,
          COALESCE(sum(NULLIF(c#>>'{summary,unresolvedParticipants}','')::integer),0)::integer unresolved_teams,
          COALESCE(sum(NULLIF(c#>>'{summary,terminalExceptions}','')::integer),0)::integer terminal_exceptions
        FROM cats
      )
      SELECT jsonb_build_object(
        'tournamentId',v_tournament_id,
        'tournamentRoundId',p_tournament_round_id,
        'scoringEngine','best_ball',
        'participationType','equipo',
        'competitiveUnit','TEAM',
        'readyToCloseResults',(total_teams>0 AND unresolved_teams=0),
        'summary',jsonb_build_object(
          'totalCards',total_teams,
          'officialCards',official_teams,
          'terminalExceptions',terminal_exceptions,
          'resolvedCards',resolved_teams,
          'unresolvedCards',unresolved_teams,
          'totalTeams',total_teams,
          'officialTeams',official_teams,
          'resolvedTeams',resolved_teams,
          'unresolvedTeams',unresolved_teams
        )
      )
      FROM totals
    );
END;
$function$;

-- --------------------------------------------------------------------------
-- 3) Estado base de cierre Best Ball: mismo contrato TEAM probado en A-Go-Go,
--    pero con validador y motor de desempates Best Ball.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._obtener_estado_cierre_best_ball_ronda_328(
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
    v_results_close jsonb;
    v_tiebreak_engine jsonb;
    v_manual_resolutions jsonb;
    v_cards_ready boolean;
BEGIN
    SELECT tr.tournament_id,tr.numero_ronda,tr.fecha
      INTO v_tournament_id,v_round_number,v_round_date
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
      RAISE EXCEPTION 'La ronda indicada no existe.' USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
      RAISE EXCEPTION 'No tienes permiso administrativo para consultar el cierre competitivo.'
        USING ERRCODE='42501';
    END IF;

    v_results_close := public.validar_cierre_resultados_best_ball_328(p_tournament_round_id);
    v_tiebreak_engine := public.obtener_desempates_best_ball_ronda_327(p_tournament_round_id);
    v_manual_resolutions := public.obtener_resoluciones_desempate_ronda(p_tournament_round_id);
    v_cards_ready := COALESCE((v_results_close->>'readyToCloseResults')::boolean,false);

    RETURN (
      WITH tie_groups AS (
        SELECT g,
          NULLIF(g->>'tournamentCategoryId','')::uuid tournament_category_id,
          g->>'resultType' result_type,
          NULLIF(g->>'baseRank','')::integer base_rank,
          NULLIF(g->>'tiedTotal','')::integer tied_total,
          NULLIF(g->>'tieSize','')::integer tie_size,
          g->>'status' engine_status,
          g->>'categoryName' category_name
        FROM jsonb_array_elements(COALESCE(v_tiebreak_engine->'tieGroups','[]'::jsonb)) g
      ),
      manual_active AS (
        SELECT
          NULLIF(r->>'resolutionId','')::uuid resolution_id,
          NULLIF(r->>'tournamentCategoryId','')::uuid tournament_category_id,
          r->>'resultType' result_type,
          NULLIF(r->>'baseRank','')::integer base_rank,
          NULLIF(r->>'tiedTotal','')::integer tied_total,
          r->>'methodCode' method_code,r->>'methodName' method_name,
          r->>'resolutionMode' resolution_mode,r->>'resolvedAt' resolved_at
        FROM jsonb_array_elements(COALESCE(v_manual_resolutions->'resolutions','[]'::jsonb)) r
        WHERE r->>'status'='COMPLETED'
      ),
      effective AS (
        SELECT tg.*,ma.resolution_id,ma.method_code manual_method_code,
               ma.method_name manual_method_name,ma.resolution_mode,ma.resolved_at,
          CASE WHEN tg.engine_status='RESOLVED_AUTOMATIC' THEN true
               WHEN ma.resolution_id IS NOT NULL THEN true ELSE false END resolved_effectively,
          CASE WHEN tg.engine_status='RESOLVED_AUTOMATIC' THEN 'AUTOMATIC'
               WHEN ma.resolution_id IS NOT NULL THEN 'MANUAL' ELSE 'PENDING' END resolution_source
        FROM tie_groups tg
        LEFT JOIN manual_active ma
          ON ma.tournament_category_id=tg.tournament_category_id
         AND ma.result_type=tg.result_type
         AND ma.base_rank=tg.base_rank
         AND ma.tied_total=tg.tied_total
      ),
      ts AS (
        SELECT count(*)::integer tie_groups,
          count(*) FILTER(WHERE resolved_effectively)::integer resolved_groups,
          count(*) FILTER(WHERE engine_status='RESOLVED_AUTOMATIC')::integer automatic_resolved,
          count(*) FILTER(WHERE resolution_source='MANUAL')::integer manual_resolved,
          count(*) FILTER(WHERE NOT resolved_effectively)::integer pending_groups,
          count(*) FILTER(WHERE NOT resolved_effectively AND engine_status='CONFIG_MISSING')::integer config_missing,
          count(*) FILTER(WHERE NOT resolved_effectively AND engine_status='MANUAL_PENDING')::integer manual_pending,
          count(*) FILTER(WHERE NOT resolved_effectively AND engine_status='TIE_PERSISTS_AFTER_RULES')::integer persists_after_rules
        FROM effective
      )
      SELECT jsonb_build_object(
        'round',jsonb_build_object(
          'tournamentId',v_tournament_id,'tournamentRoundId',p_tournament_round_id,
          'roundNumber',v_round_number,'roundDate',v_round_date,
          'scoringEngine','best_ball','participationType','equipo','competitiveUnit','TEAM'
        ),
        'status',jsonb_build_object(
          'cardsReady',v_cards_ready,
          'tiebreaksReady',(pending_groups=0),
          'competitivelyClosed',(v_cards_ready AND pending_groups=0),
          'competitiveStatus',CASE WHEN NOT v_cards_ready THEN 'PROVISIONAL'
                                   WHEN pending_groups>0 THEN 'TIEBREAKS_PENDING'
                                   ELSE 'FINAL' END
        ),
        'resultsClosure',v_results_close,
        'tiebreakSummary',jsonb_build_object(
          'tieGroups',tie_groups,'resolvedGroups',resolved_groups,
          'automaticResolved',automatic_resolved,'manualResolved',manual_resolved,
          'pendingGroups',pending_groups,'configMissing',config_missing,
          'manualPending',manual_pending,'persistsAfterRules',persists_after_rules
        ),
        'pendingTiebreaks',COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'competitiveUnit','TEAM','tournamentCategoryId',e.tournament_category_id,
            'categoryName',e.category_name,'resultType',e.result_type,
            'baseRank',e.base_rank,'tiedTotal',e.tied_total,'tieSize',e.tie_size,
            'engineStatus',e.engine_status
          ) ORDER BY e.category_name,e.result_type,e.base_rank)
          FROM effective e WHERE NOT e.resolved_effectively
        ),'[]'::jsonb),
        'resolvedTiebreaks',COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'competitiveUnit','TEAM','tournamentCategoryId',e.tournament_category_id,
            'categoryName',e.category_name,'resultType',e.result_type,
            'baseRank',e.base_rank,'tiedTotal',e.tied_total,'tieSize',e.tie_size,
            'resolutionSource',e.resolution_source,'engineStatus',e.engine_status,
            'manualResolutionId',e.resolution_id,'manualResolutionMode',e.resolution_mode,
            'manualMethodCode',e.manual_method_code,'manualMethodName',e.manual_method_name,
            'manualResolvedAt',e.resolved_at
          ) ORDER BY e.category_name,e.result_type,e.base_rank)
          FROM effective e WHERE e.resolved_effectively
        ),'[]'::jsonb)
      )
      FROM ts
    );
END;
$function$;

-- --------------------------------------------------------------------------
-- 4) Formalización Best Ball, aislada de _estado_formalizacion...265.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._estado_formalizacion_best_ball_ronda_328(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_round record;
    v_operational jsonb;
    v_base_state jsonb;
    v_round_closed boolean;
    v_total integer:=0; v_ready integer:=0; v_closed integer:=0; v_published integer:=0;
    v_categories jsonb:='[]'::jsonb;
BEGIN
    SELECT tr.id,tr.tournament_id,tr.numero_ronda,tr.fecha INTO v_round
    FROM public.tournament_rounds tr
    WHERE tr.id=p_tournament_round_id AND tr.activo=true;
    IF NOT FOUND THEN RAISE EXCEPTION 'La ronda indicada no existe o no está activa.' USING ERRCODE='22023'; END IF;

    v_operational:=public.obtener_leaderboard_best_ball_ronda_328(p_tournament_round_id);
    v_base_state:=public._obtener_estado_cierre_best_ball_ronda_328(p_tournament_round_id);

    SELECT EXISTS(
      SELECT 1 FROM public.tournament_round_competitive_closures rc
      WHERE rc.tournament_round_id=p_tournament_round_id AND rc.competitive_status='FINAL'
    ) INTO v_round_closed;

    IF v_round_closed THEN
      SELECT count(*)::integer,count(*)::integer,count(*)::integer,count(*)::integer,
        COALESCE(jsonb_agg(jsonb_build_object(
          'tournamentCategoryId',NULLIF(c->>'tournamentCategoryId','')::uuid,
          'categoryCode',c->>'categoryCode','categoryName',c->>'categoryName',
          'competitiveReady',true,'formallyClosed',true,'published',true,
          'grandfatheredByRoundClosure',true
        ) ORDER BY NULLIF(c->>'categoryDisplayOrder','')::integer NULLS LAST,c->>'categoryName'),'[]'::jsonb)
      INTO v_total,v_ready,v_closed,v_published,v_categories
      FROM jsonb_array_elements(COALESCE(v_operational->'categories','[]'::jsonb)) c;

      RETURN jsonb_build_object(
        'applicable',true,'supported',true,'roundClosed',true,
        'grandfatheredByRoundClosure',true,'tournamentRoundId',p_tournament_round_id,
        'roundNumber',v_round.numero_ronda,'scoringEngine','best_ball',
        'participationType','equipo','baseCompetitiveStatus',v_base_state#>>'{status,competitiveStatus}',
        'totalCategories',v_total,'readyCategories',v_ready,'closedCategories',v_closed,
        'publishedCategories',v_published,'allCategoriesReady',true,
        'allCategoriesClosed',true,'allCategoriesPublished',true,'categories',v_categories
      );
    END IF;

    WITH cb AS (
      SELECT NULLIF(c->>'tournamentCategoryId','')::uuid category_id,
             c->>'categoryCode' category_code,c->>'categoryName' category_name,
             NULLIF(c->>'categoryDisplayOrder','')::integer display_order,
             COALESCE(NULLIF(c#>>'{summary,totalParticipants}','')::integer,0) total_participants,
             COALESCE(NULLIF(c#>>'{summary,unresolvedParticipants}','')::integer,0) unresolved_participants
      FROM jsonb_array_elements(COALESCE(v_operational->'categories','[]'::jsonb)) c
    ),
    pt AS (
      SELECT NULLIF(g->>'tournamentCategoryId','')::uuid category_id,count(*)::integer pending
      FROM jsonb_array_elements(COALESCE(v_base_state->'pendingTiebreaks','[]'::jsonb)) g
      GROUP BY NULLIF(g->>'tournamentCategoryId','')::uuid
    ),
    s AS (
      SELECT cb.*,COALESCE(pt.pending,0) pending,
             cl.id closure_id,cl.competitive_status closure_status,cl.closed_at,
             pub.id publication_id,pub.publication_status,pub.published_at,
             (cb.total_participants>0 AND cb.unresolved_participants=0 AND COALESCE(pt.pending,0)=0) competitive_ready,
             (cl.id IS NOT NULL AND cl.competitive_status='FINAL') formally_closed,
             (pub.id IS NOT NULL AND pub.publication_status='PUBLISHED') published
      FROM cb
      LEFT JOIN pt ON pt.category_id IS NOT DISTINCT FROM cb.category_id
      LEFT JOIN public.tournament_round_category_competitive_closures cl
        ON cl.tournament_round_id=p_tournament_round_id
       AND cl.tournament_category_id IS NOT DISTINCT FROM cb.category_id
      LEFT JOIN public.tournament_round_category_publications pub
        ON pub.tournament_round_id=p_tournament_round_id
       AND pub.tournament_category_id IS NOT DISTINCT FROM cb.category_id
       AND pub.publication_status='PUBLISHED'
    )
    SELECT count(*)::integer,
           count(*) FILTER(WHERE competitive_ready)::integer,
           count(*) FILTER(WHERE formally_closed)::integer,
           count(*) FILTER(WHERE published)::integer,
           COALESCE(jsonb_agg(jsonb_build_object(
             'tournamentCategoryId',category_id,'categoryCode',category_code,'categoryName',category_name,
             'totalParticipants',total_participants,'unresolvedParticipants',unresolved_participants,
             'pendingTieGroups',pending,'competitiveReady',competitive_ready,
             'formallyClosed',formally_closed,'closureId',closure_id,'closureStatus',closure_status,'closedAt',closed_at,
             'published',published,'publicationId',publication_id,'publicationStatus',publication_status,'publishedAt',published_at
           ) ORDER BY display_order NULLS LAST,category_name),'[]'::jsonb)
    INTO v_total,v_ready,v_closed,v_published,v_categories
    FROM s;

    RETURN jsonb_build_object(
      'applicable',true,'supported',true,'roundClosed',false,'grandfatheredByRoundClosure',false,
      'tournamentRoundId',p_tournament_round_id,'roundNumber',v_round.numero_ronda,
      'scoringEngine','best_ball','participationType','equipo',
      'baseCompetitiveStatus',v_base_state#>>'{status,competitiveStatus}',
      'totalCategories',v_total,'readyCategories',v_ready,'closedCategories',v_closed,
      'publishedCategories',v_published,
      'allCategoriesReady',(v_total>0 AND v_ready=v_total),
      'allCategoriesClosed',(v_total>0 AND v_closed=v_total),
      'allCategoriesPublished',(v_total>0 AND v_published=v_total),
      'categories',v_categories
    );
END;
$function$;

-- --------------------------------------------------------------------------
-- 5) Guardamos dispatchers actuales y agregamos SOLO la rama Best Ball.
-- --------------------------------------------------------------------------
DO $do$
BEGIN
  IF to_regprocedure('public._obtener_leaderboard_operativo_ronda_pre328(uuid)') IS NULL THEN
    EXECUTE 'CREATE FUNCTION public._obtener_leaderboard_operativo_ronda_pre328(uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO public,pg_temp AS $f$ SELECT public.obtener_leaderboard_operativo_ronda($1) $f$';
  END IF;
  IF to_regprocedure('public._obtener_estado_cierre_competitivo_ronda_pre328(uuid)') IS NULL THEN
    EXECUTE 'CREATE FUNCTION public._obtener_estado_cierre_competitivo_ronda_pre328(uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO public,pg_temp AS $f$ SELECT public.obtener_estado_cierre_competitivo_ronda($1) $f$';
  END IF;
END
$do$;

CREATE OR REPLACE FUNCTION public.obtener_leaderboard_operativo_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_engine text; v_participation text;
BEGIN
  SELECT s.scoring_engine,s.participation_type INTO v_engine,v_participation
  FROM public.tournament_round_condition_snapshots s
  WHERE s.tournament_round_id=p_tournament_round_id
  ORDER BY s.created_at DESC,s.id DESC LIMIT 1;

  IF v_engine='best_ball' AND v_participation='equipo' THEN
    RETURN public.obtener_leaderboard_best_ball_ronda_328(p_tournament_round_id);
  END IF;

  RETURN public._obtener_leaderboard_operativo_ronda_pre328(p_tournament_round_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.obtener_estado_cierre_competitivo_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_engine text; v_participation text;
  v_base jsonb; v_formal jsonb;
  v_round_closed boolean; v_all_closed boolean; v_all_published boolean;
  v_base_status text;
BEGIN
  SELECT s.scoring_engine,s.participation_type INTO v_engine,v_participation
  FROM public.tournament_round_condition_snapshots s
  WHERE s.tournament_round_id=p_tournament_round_id
  ORDER BY s.created_at DESC,s.id DESC LIMIT 1;

  IF NOT (v_engine='best_ball' AND v_participation='equipo') THEN
    RETURN public._obtener_estado_cierre_competitivo_ronda_pre328(p_tournament_round_id);
  END IF;

  v_base:=public._obtener_estado_cierre_best_ball_ronda_328(p_tournament_round_id);
  v_formal:=public._estado_formalizacion_best_ball_ronda_328(p_tournament_round_id);

  v_round_closed:=COALESCE((v_formal->>'roundClosed')::boolean,false);
  v_all_closed:=COALESCE((v_formal->>'allCategoriesClosed')::boolean,false);
  v_all_published:=COALESCE((v_formal->>'allCategoriesPublished')::boolean,false);
  v_base_status:=v_base#>>'{status,competitiveStatus}';

  v_base:=jsonb_set(v_base,'{formalization}',v_formal,true);
  v_base:=jsonb_set(v_base,'{status,categoryClosuresReady}',to_jsonb(v_all_closed),true);
  v_base:=jsonb_set(v_base,'{status,publicationsReady}',to_jsonb(v_all_published),true);

  IF v_round_closed THEN
    v_base:=jsonb_set(v_base,'{status,competitiveStatus}',to_jsonb('FINAL'::text),true);
    v_base:=jsonb_set(v_base,'{status,competitivelyClosed}','true'::jsonb,true);
    RETURN v_base;
  END IF;

  IF v_base_status='FINAL' AND NOT v_all_closed THEN
    v_base:=jsonb_set(v_base,'{status,competitiveStatus}',to_jsonb('CATEGORIES_PENDING'::text),true);
    v_base:=jsonb_set(v_base,'{status,competitivelyClosed}','false'::jsonb,true);
    RETURN v_base;
  END IF;

  IF v_base_status='FINAL' AND v_all_closed AND NOT v_all_published THEN
    v_base:=jsonb_set(v_base,'{status,competitiveStatus}',to_jsonb('PUBLICATIONS_PENDING'::text),true);
    v_base:=jsonb_set(v_base,'{status,competitivelyClosed}','false'::jsonb,true);
    RETURN v_base;
  END IF;

  RETURN v_base;
END;
$function$;

COMMIT;
