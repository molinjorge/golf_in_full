-- MIGRACIÓN 388
-- TEE CENTRAL / GOLF IN FULL
-- HCP INMUTABLE EN RESULTADOS PUBLICADOS
-- Alcance histórico: únicamente POLLA SEPTIEMBRE, 24.
-- Alcance futuro: cierres competitivos INDIVIDUALES.
-- EJECUCIÓN: manual por el usuario en Supabase PROD.

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Helper puro: incorpora HCP congelado de ronda a players[]
--    de un leaderboard individual. No consulta el catálogo actual.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._materializar_hcp_leaderboard_388(
    p_tournament_round_id uuid,
    p_leaderboard_category jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_players jsonb;
    v_total integer;
    v_matched integer;
BEGIN
    IF p_tournament_round_id IS NULL OR p_leaderboard_category IS NULL THEN
        RETURN p_leaderboard_category;
    END IF;

    -- Solo aplica a estructuras con players[].
    IF jsonb_typeof(p_leaderboard_category->'players') IS DISTINCT FROM 'array' THEN
        RETURN p_leaderboard_category;
    END IF;

    SELECT count(*)
      INTO v_total
      FROM jsonb_array_elements(p_leaderboard_category->'players') p
     WHERE NULLIF(p->>'playerId','') IS NOT NULL;

    SELECT count(*)
      INTO v_matched
      FROM jsonb_array_elements(p_leaderboard_category->'players') p
      JOIN public.tournament_round_handicap_snapshots hs
        ON hs.tournament_round_id = p_tournament_round_id
       AND hs.player_id = NULLIF(p->>'playerId','')::uuid
     WHERE NULLIF(p->>'playerId','') IS NOT NULL;

    IF v_total <> v_matched THEN
        RAISE EXCEPTION
            'No se puede congelar el HCP publicado: % participantes con playerId, % snapshots HCP encontrados.',
            v_total, v_matched
            USING ERRCODE='23514';
    END IF;

    SELECT jsonb_agg(
               p.elem ||
               jsonb_build_object(
                   'playingHandicap', hs.playing_handicap,
                   'courseHandicap', hs.course_handicap
               )
               ORDER BY p.ord
           )
      INTO v_players
      FROM jsonb_array_elements(p_leaderboard_category->'players')
           WITH ORDINALITY AS p(elem, ord)
      LEFT JOIN public.tournament_round_handicap_snapshots hs
        ON hs.tournament_round_id = p_tournament_round_id
       AND hs.player_id = NULLIF(p.elem->>'playerId','')::uuid;

    RETURN jsonb_set(
        p_leaderboard_category,
        '{players}',
        COALESCE(v_players, '[]'::jsonb),
        false
    );
END;
$function$;

REVOKE ALL ON FUNCTION public._materializar_hcp_leaderboard_388(uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._materializar_hcp_leaderboard_388(uuid,jsonb) FROM anon;
REVOKE ALL ON FUNCTION public._materializar_hcp_leaderboard_388(uuid,jsonb) FROM authenticated;

-- ---------------------------------------------------------------------
-- 2. Trigger permanente.
--    Antes de insertar un cierre competitivo INDIVIDUAL, materializa
--    playingHandicap y courseHandicap dentro del snapshot oficial.
--    TEAM queda expresamente fuera.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._trg_materializar_hcp_cierre_388()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_participation_type text;
    v_lb jsonb;
BEGIN
    v_participation_type :=
        NEW.closure_snapshot->'round'->>'participationType';

    IF v_participation_type IS DISTINCT FROM 'individual' THEN
        RETURN NEW;
    END IF;

    v_lb := NEW.closure_snapshot->'leaderboardCategory';

    IF v_lb IS NULL THEN
        RAISE EXCEPTION
            'Cierre individual sin leaderboardCategory; no se puede congelar HCP.'
            USING ERRCODE='23514';
    END IF;

    v_lb := public._materializar_hcp_leaderboard_388(
        NEW.tournament_round_id,
        v_lb
    );

    NEW.closure_snapshot := jsonb_set(
        NEW.closure_snapshot,
        '{leaderboardCategory}',
        v_lb,
        false
    );

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_materializar_hcp_cierre_388
ON public.tournament_round_category_competitive_closures;

CREATE TRIGGER trg_materializar_hcp_cierre_388
BEFORE INSERT ON public.tournament_round_category_competitive_closures
FOR EACH ROW
EXECUTE FUNCTION public._trg_materializar_hcp_cierre_388();

-- ---------------------------------------------------------------------
-- 3. Corrección única y controlada:
--    POLLA SEPTIEMBRE, 24 / Ronda 1.
--    No toca ningún torneo anterior.
-- ---------------------------------------------------------------------
DO $do$
DECLARE
    v_tournament_id constant uuid :=
        '0d9ea628-10a1-4214-a078-e73bb5f59313';
    v_round_id constant uuid :=
        '42a4aa4d-75d8-4d35-8301-cb20091afaaa';
    v_closure_id uuid;
    v_closure_snapshot jsonb;
    v_new_closure_snapshot jsonb;
    v_lb jsonb;
    v_publication_count integer;
BEGIN
    SELECT c.id, c.closure_snapshot
      INTO v_closure_id, v_closure_snapshot
      FROM public.tournament_round_category_competitive_closures c
     WHERE c.tournament_id = v_tournament_id
       AND c.tournament_round_id = v_round_id
     FOR UPDATE;

    IF v_closure_id IS NULL THEN
        RAISE EXCEPTION
            'No se encontró el cierre competitivo de POLLA SEPTIEMBRE, 24.'
            USING ERRCODE='23514';
    END IF;

    IF v_closure_snapshot->'round'->>'participationType'
       IS DISTINCT FROM 'individual' THEN
        RAISE EXCEPTION
            'POLLA SEPTIEMBRE, 24 no aparece como participación individual.'
            USING ERRCODE='23514';
    END IF;

    v_lb := public._materializar_hcp_leaderboard_388(
        v_round_id,
        v_closure_snapshot->'leaderboardCategory'
    );

    v_new_closure_snapshot := jsonb_set(
        v_closure_snapshot,
        '{leaderboardCategory}',
        v_lb,
        false
    );

    UPDATE public.tournament_round_category_competitive_closures
       SET closure_snapshot = v_new_closure_snapshot
     WHERE id = v_closure_id;

    SELECT count(*)
      INTO v_publication_count
      FROM public.tournament_round_category_publications p
     WHERE p.tournament_id = v_tournament_id
       AND p.tournament_round_id = v_round_id
       AND p.category_closure_id = v_closure_id
       AND p.publication_status = 'PUBLISHED';

    IF v_publication_count <> 1 THEN
        RAISE EXCEPTION
            'Se esperaba exactamente 1 publicación oficial para POLLA SEPTIEMBRE, 24; encontradas: %.',
            v_publication_count
            USING ERRCODE='23514';
    END IF;

    UPDATE public.tournament_round_category_publications p
       SET publication_snapshot = jsonb_set(
           p.publication_snapshot,
           '{closureSnapshot}',
           v_new_closure_snapshot,
           false
       )
     WHERE p.tournament_id = v_tournament_id
       AND p.tournament_round_id = v_round_id
       AND p.category_closure_id = v_closure_id
       AND p.publication_status = 'PUBLISHED';
END;
$do$;

COMMIT;
