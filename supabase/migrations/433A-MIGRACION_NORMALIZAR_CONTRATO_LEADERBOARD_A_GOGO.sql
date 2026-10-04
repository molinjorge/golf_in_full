-- 433A-MIGRACION_NORMALIZAR_CONTRATO_LEADERBOARD_A_GOGO.sql
-- Corrección directa de 433.
-- A-Go-Go ya devuelve el leaderboard TEAM correcto, pero su JSON histórico no
-- incluye la bandera superior "supported". El contrato común 265 exige esa
-- bandera y, al faltar, interpreta supported=false.
--
-- Esta corrección SOLO normaliza el adaptador operativo.
-- No modifica motor A-Go-Go, resultados, rankings, desempates, cierres,
-- publicaciones, HCP TEAM, tarjetas, QR ni captura.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_leaderboard_operativo_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_engine text;
    v_participation text;
    v_result jsonb;
BEGIN
    SELECT s.scoring_engine, s.participation_type
      INTO v_engine, v_participation
      FROM public.tournament_round_condition_snapshots s
     WHERE s.tournament_round_id=p_tournament_round_id
     ORDER BY s.created_at DESC, s.id DESC
     LIMIT 1;

    IF v_engine='best_ball' AND v_participation='equipo' THEN
        RETURN public.obtener_leaderboard_best_ball_ronda_328(
            p_tournament_round_id
        );
    END IF;

    IF v_engine='team_stroke' AND v_participation='equipo' THEN
        v_result :=
            public.obtener_leaderboard_a_gogo_ronda(
                p_tournament_round_id
            );

        -- 433A: normalización del contrato común.
        -- No se toca ninguna propiedad deportiva del leaderboard.
        RETURN COALESCE(v_result,'{}'::jsonb)
               || jsonb_build_object(
                    'supported',true,
                    'applicable',true
                  );
    END IF;

    RETURN public._obtener_leaderboard_operativo_ronda_pre328(
        p_tournament_round_id
    );
END;
$function$;

DO $$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(p.oid)
      INTO v_def
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public'
       AND p.proname='obtener_leaderboard_operativo_ronda'
       AND p.oid::regprocedure::text=
           'obtener_leaderboard_operativo_ronda(uuid)';

    IF v_def IS NULL
       OR strpos(v_def,'obtener_leaderboard_best_ball_ronda_328')=0
       OR strpos(v_def,'obtener_leaderboard_a_gogo_ronda')=0
       OR strpos(v_def,'''supported'',true')=0
       OR strpos(v_def,'''applicable'',true')=0
       OR strpos(v_def,'_obtener_leaderboard_operativo_ronda_pre328')=0
    THEN
        RAISE EXCEPTION
            '433A: el adaptador operativo no quedó con el contrato esperado.';
    END IF;
END
$$;

COMMIT;
