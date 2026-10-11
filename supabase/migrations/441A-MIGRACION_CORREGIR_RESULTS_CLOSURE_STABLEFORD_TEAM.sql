-- 441A-MIGRACION_CORREGIR_RESULTS_CLOSURE_STABLEFORD_TEAM.sql
-- TEE CENTRAL / GOLF IN FULL
-- Ejecutar manualmente en Supabase. Lovable NO ejecuta migraciones.
--
-- Corrige exclusivamente la regresión introducida por 441:
-- NO llamar validar_cierre_resultados_ronda() desde Stableford TEAM porque esa
-- función deriva a pre213 y rechaza stableford/equipo.
--
-- Conserva la regla 441:
-- READY + categorías formalmente cerradas => FINAL previo al cierre formal.
-- La publicación NO es requisito para cerrar.
--
-- resultsClosure se arma desde el leaderboard TEAM 438, que ya contiene por
-- equipo memberCards/resolvedMemberCards/unresolvedMemberCards calculados sobre
-- las tarjetas INDIVIDUALES oficiales.

BEGIN;

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
  v_engine text;
  v_participation text;
  v_format_code text;
  v_base jsonb;
  v_lb jsonb;
  v_formal jsonb;
  v_results_close jsonb;
  v_round_closed boolean;
  v_all_closed boolean;
  v_all_published boolean;
  v_base_status text;
  v_total_cards integer;
  v_resolved_cards integer;
  v_unresolved_cards integer;
  v_total_teams integer;
  v_resolved_teams integer;
  v_unresolved_teams integer;
BEGIN
  SELECT s.scoring_engine,s.participation_type,s.format_code
    INTO v_engine,v_participation,v_format_code
  FROM public.tournament_round_condition_snapshots s
  WHERE s.tournament_round_id=p_tournament_round_id
  ORDER BY s.created_at DESC,s.id DESC LIMIT 1;

  IF v_engine='stableford'
     AND v_participation='equipo'
     AND v_format_code='STABLEFORD_EQUIPO'
  THEN
      v_base:=public.obtener_estado_cierre_stableford_team_ronda_437(
          p_tournament_round_id
      );

      -- 438 es la misma fuente deportiva que consume 437 y conserva por equipo
      -- memberCards/resolvedMemberCards/unresolvedMemberCards.
      v_lb:=public.obtener_leaderboard_stableford_team_ronda_438(
          p_tournament_round_id
      );

      SELECT
        COALESCE(sum(COALESCE(NULLIF(x->>'memberCards','')::integer,0)),0)::integer,
        COALESCE(sum(COALESCE(NULLIF(x->>'resolvedMemberCards','')::integer,0)),0)::integer,
        COALESCE(sum(COALESCE(NULLIF(x->>'unresolvedMemberCards','')::integer,0)),0)::integer,
        count(*)::integer,
        count(*) FILTER (
          WHERE COALESCE(NULLIF(x->>'unresolvedMemberCards','')::integer,0)=0
        )::integer,
        count(*) FILTER (
          WHERE COALESCE(NULLIF(x->>'unresolvedMemberCards','')::integer,0)>0
        )::integer
      INTO
        v_total_cards,v_resolved_cards,v_unresolved_cards,
        v_total_teams,v_resolved_teams,v_unresolved_teams
      FROM jsonb_array_elements(COALESCE(v_lb->'categories','[]'::jsonb)) c
      CROSS JOIN LATERAL
        jsonb_array_elements(COALESCE(c->'players','[]'::jsonb)) x;

      v_results_close:=jsonb_build_object(
        'tournamentRoundId',p_tournament_round_id,
        'scoringEngine','stableford',
        'participationType','equipo',
        'competitiveUnit','TEAM',
        'readyToCloseResults',(v_total_cards>0 AND v_unresolved_cards=0),
        'summary',jsonb_build_object(
          'totalCards',v_total_cards,
          'officialCards',v_resolved_cards,
          'resolvedCards',v_resolved_cards,
          'unresolvedCards',v_unresolved_cards,
          'totalTeams',v_total_teams,
          'officialTeams',v_resolved_teams,
          'resolvedTeams',v_resolved_teams,
          'unresolvedTeams',v_unresolved_teams,
          'WD',0,'DNF',0,'DQ',0,'DNS',0,'NO_CARD',0
        ),
        'unresolved','[]'::jsonb
      );

      -- 440 ya hace que esta formalización use la rama TEAM y no pre213.
      v_formal:=public._estado_formalizacion_resultados_ronda_265(
          p_tournament_round_id
      );

      v_round_closed:=COALESCE((v_formal->>'roundClosed')::boolean,false);
      v_all_closed:=COALESCE((v_formal->>'allCategoriesClosed')::boolean,false);
      v_all_published:=COALESCE((v_formal->>'allCategoriesPublished')::boolean,false);
      v_base_status:=v_base#>>'{status,competitiveStatus}';

      v_base:=jsonb_set(v_base,'{resultsClosure}',v_results_close,true);
      v_base:=jsonb_set(v_base,'{formalization}',v_formal,true);
      v_base:=jsonb_set(v_base,'{status,cardsReady}',to_jsonb(v_total_cards>0 AND v_unresolved_cards=0),true);
      v_base:=jsonb_set(v_base,'{status,tiebreaksReady}',to_jsonb(COALESCE(NULLIF(v_base#>>'{status,pendingTiebreakGroups}','')::integer,0)=0),true);
      v_base:=jsonb_set(v_base,'{status,categoryClosuresReady}',to_jsonb(v_all_closed),true);
      v_base:=jsonb_set(v_base,'{status,publicationsReady}',to_jsonb(v_all_published),true);

      IF v_round_closed THEN
          v_base:=jsonb_set(v_base,'{status,competitiveStatus}',to_jsonb('FINAL'::text),true);
          v_base:=jsonb_set(v_base,'{status,competitivelyClosed}','true'::jsonb,true);
          RETURN v_base;
      END IF;

      IF v_base_status='READY' AND NOT v_all_closed THEN
          v_base:=jsonb_set(v_base,'{status,competitiveStatus}',to_jsonb('CATEGORIES_PENDING'::text),true);
          v_base:=jsonb_set(v_base,'{status,competitivelyClosed}','false'::jsonb,true);
          RETURN v_base;
      END IF;

      IF v_base_status='READY' AND v_all_closed THEN
          v_base:=jsonb_set(v_base,'{status,competitiveStatus}',to_jsonb('FINAL'::text),true);
          v_base:=jsonb_set(v_base,'{status,competitivelyClosed}','false'::jsonb,true);
          RETURN v_base;
      END IF;

      RETURN v_base;
  END IF;

  IF NOT (v_engine='best_ball' AND v_participation='equipo') THEN
    RETURN public._obtener_estado_cierre_competitivo_ronda_pre328(
        p_tournament_round_id
    );
  END IF;

  -- Best Ball preservado literalmente respecto de 441.
  v_base:=public._obtener_estado_cierre_best_ball_ronda_328(
      p_tournament_round_id
  );
  v_formal:=public._estado_formalizacion_best_ball_ronda_328(
      p_tournament_round_id
  );

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

COMMENT ON FUNCTION public.obtener_estado_cierre_competitivo_ronda(uuid)
IS '441A: corrige 441 eliminando validar_cierre_resultados_ronda para Stableford TEAM; resultsClosure se deriva del leaderboard TEAM 438. Conserva READY + categorías cerradas => FINAL.';

COMMIT;
