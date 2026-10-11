-- 441-MIGRACION_CIERRE_RONDA_STABLEFORD_TEAM.sql
-- TEE CENTRAL / GOLF IN FULL
-- Ejecutar manualmente en Supabase. Lovable NO ejecuta migraciones.
--
-- Objetivo:
-- Corregir la dependencia circular del cierre de ronda Stableford TEAM.
-- Antes del cierre formal, el estado TEAM 437 devuelve READY; la capa común
-- sólo habilita cerrar cuando recibe FINAL. La rama TEAM sólo convertía a FINAL
-- después de existir el cierre, por lo que nunca podía alcanzarse.
--
-- Regla 441:
-- resultados resueltos + desempates resueltos + categorías formalmente cerradas
-- => competitiveStatus=FINAL (ronda preparada para cierre).
-- La publicación NO es requisito para cerrar la ronda.
-- Se agrega resultsClosure usando el validador común existente para conservar
-- el contrato de Tarjetas / Resueltas / Pendientes / Outcomes.

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
  v_formal jsonb;
  v_results_close jsonb;
  v_round_closed boolean;
  v_all_closed boolean;
  v_all_published boolean;
  v_base_status text;
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
      -- Estado deportivo TEAM: resultados individuales agregados por equipo
      -- y desempates automáticos 438.
      v_base:=public.obtener_estado_cierre_stableford_team_ronda_437(
          p_tournament_round_id
      );

      -- Contrato común de tarjetas/resultados. Stableford TEAM mantiene
      -- tarjetas individuales, por lo que el validador histórico individual
      -- sigue siendo la fuente correcta de conteos y outcomes.
      v_results_close:=public.validar_cierre_resultados_ronda(
          p_tournament_round_id
      );

      -- 440 evita que esta formalización vuelva a caer en pre213 para TEAM.
      v_formal:=public._estado_formalizacion_resultados_ronda_265(
          p_tournament_round_id
      );

      v_round_closed:=COALESCE((v_formal->>'roundClosed')::boolean,false);
      v_all_closed:=COALESCE((v_formal->>'allCategoriesClosed')::boolean,false);
      v_all_published:=COALESCE((v_formal->>'allCategoriesPublished')::boolean,false);
      v_base_status:=v_base#>>'{status,competitiveStatus}';

      v_base:=jsonb_set(v_base,'{resultsClosure}',v_results_close,true);
      v_base:=jsonb_set(v_base,'{formalization}',v_formal,true);
      v_base:=jsonb_set(
          v_base,'{status,cardsReady}',
          to_jsonb(COALESCE((v_results_close->>'readyToCloseResults')::boolean,false)),
          true
      );
      v_base:=jsonb_set(
          v_base,'{status,tiebreaksReady}',
          to_jsonb(COALESCE(NULLIF(v_base#>>'{status,pendingTiebreakGroups}','')::integer,0)=0),
          true
      );
      v_base:=jsonb_set(
          v_base,'{status,categoryClosuresReady}',
          to_jsonb(v_all_closed),true
      );
      v_base:=jsonb_set(
          v_base,'{status,publicationsReady}',
          to_jsonb(v_all_published),true
      );

      -- Si ya existe sello formal, el estado es FINAL y cerrado.
      IF v_round_closed THEN
          v_base:=jsonb_set(
              v_base,'{status,competitiveStatus}',
              to_jsonb('FINAL'::text),true
          );
          v_base:=jsonb_set(
              v_base,'{status,competitivelyClosed}',
              'true'::jsonb,true
          );
          RETURN v_base;
      END IF;

      -- READY significa que resultados y desempates TEAM ya están resueltos.
      -- Aún deben cerrarse formalmente todas las categorías.
      IF v_base_status='READY' AND NOT v_all_closed THEN
          v_base:=jsonb_set(
              v_base,'{status,competitiveStatus}',
              to_jsonb('CATEGORIES_PENDING'::text),true
          );
          v_base:=jsonb_set(
              v_base,'{status,competitivelyClosed}',
              'false'::jsonb,true
          );
          RETURN v_base;
      END IF;

      -- 441: una vez cerradas todas las categorías, la ronda queda PREPARADA
      -- para su cierre formal. La publicación oficial ocurre DESPUÉS del cierre
      -- y por tanto NO participa en esta condición.
      IF v_base_status='READY' AND v_all_closed THEN
          v_base:=jsonb_set(
              v_base,'{status,competitiveStatus}',
              to_jsonb('FINAL'::text),true
          );
          v_base:=jsonb_set(
              v_base,'{status,competitivelyClosed}',
              'false'::jsonb,true
          );
          RETURN v_base;
      END IF;

      -- RESULTS_PENDING / TIEBREAKS_PENDING permanecen sin reinterpretación.
      RETURN v_base;
  END IF;

  IF NOT (v_engine='best_ball' AND v_participation='equipo') THEN
    RETURN public._obtener_estado_cierre_competitivo_ronda_pre328(
        p_tournament_round_id
    );
  END IF;

  -- Rama Best Ball preservada sin cambios.
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
IS '441: Stableford TEAM convierte READY + categorías cerradas en FINAL previo al sello formal; publicación no bloquea cierre; expone resultsClosure común. Best Ball y demás modalidades preservadas.';

COMMIT;
