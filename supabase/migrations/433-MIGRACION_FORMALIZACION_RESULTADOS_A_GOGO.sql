BEGIN;

-- 433: integra A-Go-Go TEAM al leaderboard operativo común sin recalcular resultados.
CREATE OR REPLACE FUNCTION public.obtener_leaderboard_operativo_ronda(p_tournament_round_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
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

  IF v_engine='team_stroke' AND v_participation='equipo' THEN
    RETURN public.obtener_leaderboard_a_gogo_ronda(p_tournament_round_id);
  END IF;

  RETURN public._obtener_leaderboard_operativo_ronda_pre328(p_tournament_round_id);
END;
$function$;

-- 433: guard explícito para impedir cierre global antes del cierre formal de categorías.
-- Conserva intacto el cierre histórico _pre314 después del nuevo gate.
CREATE OR REPLACE FUNCTION public.cerrar_ronda_competitiva(
    p_tournament_round_id uuid,
    p_notas text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_round public.tournament_rounds%ROWTYPE;
    v_lifecycle public.tournament_round_lifecycle%ROWTYPE;
    v_result jsonb;
    v_admin_id uuid;
    v_formalization jsonb;
    v_supported boolean := false;
    v_all_categories_closed boolean := false;
BEGIN
    SELECT * INTO v_round
    FROM public.tournament_rounds
    WHERE id=p_tournament_round_id AND activo=true;

    IF v_round.id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe o no está activa.' USING ERRCODE='22023';
    END IF;

    INSERT INTO public.tournament_round_lifecycle(tournament_id,tournament_round_id)
    VALUES (v_round.tournament_id,v_round.id)
    ON CONFLICT (tournament_round_id) DO NOTHING;

    SELECT * INTO v_lifecycle
    FROM public.tournament_round_lifecycle
    WHERE tournament_round_id=v_round.id
    FOR UPDATE;

    IF v_lifecycle.started_at IS NULL THEN
        RAISE EXCEPTION 'La ronda debe estar EN JUEGO antes de poder finalizarse.'
        USING ERRCODE='23514', HINT='Ejecuta primero INICIAR RONDA.';
    END IF;

    v_formalization := public._estado_formalizacion_resultados_ronda_265(p_tournament_round_id);
    v_supported := COALESCE((v_formalization->>'supported')::boolean,false);
    v_all_categories_closed := COALESCE((v_formalization->>'allCategoriesClosed')::boolean,false);

    IF v_supported AND NOT v_all_categories_closed THEN
        RAISE EXCEPTION 'La ronda todavía no puede cerrarse: faltan cierres formales de categoría.'
        USING ERRCODE='23514', DETAIL=v_formalization::text,
              HINT='Cierra formalmente todas las categorías antes de cerrar la ronda.';
    END IF;

    v_result := public._cerrar_ronda_competitiva_pre314(p_tournament_round_id,p_notas);

    SELECT au.id INTO v_admin_id
    FROM public.admin_users au
    WHERE au.auth_user_id=auth.uid() AND au.activo=true
    ORDER BY au.id LIMIT 1;

    UPDATE public.tournament_round_lifecycle
    SET completed_at=COALESCE(completed_at,now()),
        completed_by_admin_user_id=COALESCE(completed_by_admin_user_id,v_admin_id),
        completion_source=COALESCE(completion_source,'FORMAL_CLOSE'),
        updated_at=now()
    WHERE tournament_round_id=v_round.id;

    RETURN v_result;
END;
$function$;

DO $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='obtener_leaderboard_operativo_ronda'
    AND p.oid::regprocedure::text='obtener_leaderboard_operativo_ronda(uuid)';
  IF v_def IS NULL OR strpos(v_def,'obtener_leaderboard_a_gogo_ronda')=0
     OR strpos(v_def,'obtener_leaderboard_best_ball_ronda_328')=0
     OR strpos(v_def,'_obtener_leaderboard_operativo_ronda_pre328')=0 THEN
    RAISE EXCEPTION '433: despachador operativo incompleto.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='cerrar_ronda_competitiva'
    AND p.oid::regprocedure::text='cerrar_ronda_competitiva(uuid,text)';
  IF v_def IS NULL OR strpos(v_def,'_estado_formalizacion_resultados_ronda_265')=0
     OR strpos(v_def,'allCategoriesClosed')=0
     OR strpos(v_def,'_cerrar_ronda_competitiva_pre314')=0 THEN
    RAISE EXCEPTION '433: guard de cierre de ronda incompleto.';
  END IF;
END $$;

COMMIT;
