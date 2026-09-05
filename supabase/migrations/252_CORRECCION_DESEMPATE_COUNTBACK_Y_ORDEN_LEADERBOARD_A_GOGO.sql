-- ============================================================================
-- MIGRACIÓN 252
-- A-Go-Go: corrige countback por hoyos reglamentarios y orden final del leaderboard
-- ============================================================================
-- Objetivos:
-- 1) TARJETA_ULTIMOS_9/6/3/1 se calcula por holeNumber, no por playSequence.
--    En Shotgun, playSequence es el orden de recorrido y no define los hoyos
--    reglamentarios de countback.
-- 2) El leaderboard A-Go-Go vuelve a ordenar las filas después de aplicar
--    finalRank de desempates automáticos/manuales.
--
-- No modifica scores, cierres, publicaciones ni resoluciones almacenadas.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1. Helper común de clave de desempate
--    Corrección semántica: los métodos TARJETA_* usan holeNumber.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calcular_clave_metodo_desempate(
    p_method_code text,
    p_tipo_resultado public.tipo_resultado_desempate,
    p_holes jsonb
)
RETURNS integer[]
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $function$
DECLARE
    v_code text := upper(btrim(COALESCE(p_method_code,'')));
    v_key integer[];
    v_max_hole integer;
    v_take integer;
    v_start_hole integer;
    v_expected_count integer;
    v_actual_count integer;
BEGIN
    IF p_holes IS NULL
       OR jsonb_typeof(p_holes) <> 'array'
       OR jsonb_array_length(p_holes) = 0
    THEN
        RETURN NULL;
    END IF;

    SELECT max((h->>'holeNumber')::integer)
      INTO v_max_hole
      FROM jsonb_array_elements(p_holes) h
     WHERE NULLIF(h->>'holeNumber','') IS NOT NULL;

    IF v_max_hole IS NULL OR v_max_hole <= 0 THEN
        RETURN NULL;
    END IF;

    IF v_code IN (
        'TARJETA_ULTIMOS_9',
        'TARJETA_ULTIMOS_6',
        'TARJETA_ULTIMOS_3',
        'TARJETA_ULTIMO_HOYO'
    ) THEN

        v_take := CASE v_code
            WHEN 'TARJETA_ULTIMOS_9' THEN 9
            WHEN 'TARJETA_ULTIMOS_6' THEN 6
            WHEN 'TARJETA_ULTIMOS_3' THEN 3
            ELSE 1
        END;

        v_take := LEAST(v_take, v_max_hole);
        v_start_hole := v_max_hole - v_take + 1;
        v_expected_count := v_take;

        SELECT
            count(*)::integer,
            ARRAY[
                sum(
                    CASE
                        WHEN p_tipo_resultado='gross'::public.tipo_resultado_desempate
                            THEN (h->>'officialGrossScore')::integer
                        ELSE (h->>'officialNetScore')::integer
                    END
                )::integer
            ]
          INTO v_actual_count, v_key
          FROM jsonb_array_elements(p_holes) h
         WHERE (h->>'holeNumber')::integer
               BETWEEN v_start_hole AND v_max_hole
           AND (
                CASE
                    WHEN p_tipo_resultado='gross'::public.tipo_resultado_desempate
                        THEN h->>'officialGrossScore'
                    ELSE h->>'officialNetScore'
                END
               ) IS NOT NULL;

        IF v_actual_count <> v_expected_count
           OR v_key IS NULL
           OR v_key[1] IS NULL
        THEN
            RETURN NULL;
        END IF;

        RETURN v_key;
    END IF;

    IF v_code='TARJETA_18' THEN
        SELECT
            count(*)::integer,
            ARRAY[
                sum(
                    CASE
                        WHEN p_tipo_resultado='gross'::public.tipo_resultado_desempate
                            THEN (h->>'officialGrossScore')::integer
                        ELSE (h->>'officialNetScore')::integer
                    END
                )::integer
            ]
          INTO v_actual_count, v_key
          FROM jsonb_array_elements(p_holes) h
         WHERE (
                CASE
                    WHEN p_tipo_resultado='gross'::public.tipo_resultado_desempate
                        THEN h->>'officialGrossScore'
                    ELSE h->>'officialNetScore'
                END
               ) IS NOT NULL;

        IF v_actual_count <> jsonb_array_length(p_holes)
           OR v_key IS NULL
           OR v_key[1] IS NULL
        THEN
            RETURN NULL;
        END IF;

        RETURN v_key;
    END IF;

    IF v_code='HOYO_POR_HOYO_HANDICAP' THEN
        SELECT
            count(*)::integer,
            array_agg(
                CASE
                    WHEN p_tipo_resultado='gross'::public.tipo_resultado_desempate
                        THEN (h->>'officialGrossScore')::integer
                    ELSE (h->>'officialNetScore')::integer
                END
                ORDER BY (h->>'strokeIndex')::integer
            )
          INTO v_actual_count, v_key
          FROM jsonb_array_elements(p_holes) h
         WHERE (h->>'strokeIndex') IS NOT NULL
           AND (
                CASE
                    WHEN p_tipo_resultado='gross'::public.tipo_resultado_desempate
                        THEN h->>'officialGrossScore'
                    ELSE h->>'officialNetScore'
                END
               ) IS NOT NULL;

        IF v_actual_count <> jsonb_array_length(p_holes)
           OR v_key IS NULL
        THEN
            RETURN NULL;
        END IF;

        RETURN v_key;
    END IF;

    -- MUERTE_SUBITA, SORTEO y códigos desconocidos requieren intervención.
    RETURN NULL;
END;
$function$;


-- --------------------------------------------------------------------------
-- 2. Preservar la implementación actual del leaderboard A-Go-Go una sola vez.
-- --------------------------------------------------------------------------
DO $$
BEGIN
    IF to_regprocedure('public._obtener_leaderboard_a_gogo_ronda_pre252(uuid)') IS NULL THEN
        ALTER FUNCTION public.obtener_leaderboard_a_gogo_ronda(uuid)
            RENAME TO _obtener_leaderboard_a_gogo_ronda_pre252;
    END IF;
END
$$;

REVOKE ALL ON FUNCTION public._obtener_leaderboard_a_gogo_ronda_pre252(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._obtener_leaderboard_a_gogo_ronda_pre252(uuid)
TO service_role;


-- --------------------------------------------------------------------------
-- 3. Wrapper v252:
--    obtiene el leaderboard ya enriquecido con finalRank y reordena players.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_leaderboard_a_gogo_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base jsonb;
    v_categories jsonb;
BEGIN
    v_base := public._obtener_leaderboard_a_gogo_ronda_pre252(
        p_tournament_round_id
    );

    SELECT COALESCE(
        jsonb_agg(
            jsonb_set(
                c.category_json,
                '{players}',
                COALESCE((
                    SELECT jsonb_agg(p.player_json ORDER BY
                        CASE
                            WHEN p.player_json->>'competitionStatus'='OFFICIAL' THEN 0
                            WHEN p.player_json->>'competitionStatus' IN
                                 ('WD','DNF','DQ','DNS','NO_CARD') THEN 1
                            ELSE 2
                        END,
                        COALESCE(
                            NULLIF(p.player_json#>>'{net,finalRank}','')::integer,
                            NULLIF(p.player_json#>>'{net,rank}','')::integer,
                            NULLIF(p.player_json#>>'{gross,finalRank}','')::integer,
                            NULLIF(p.player_json#>>'{gross,rank}','')::integer
                        ) NULLS LAST,
                        NULLIF(p.player_json->>'cardFolio',''),
                        NULLIF(p.player_json->>'teamName','')
                    )
                    FROM jsonb_array_elements(
                        COALESCE(c.category_json->'players','[]'::jsonb)
                    ) p(player_json)
                ), '[]'::jsonb),
                true
            )
            ORDER BY c.ord
        ),
        '[]'::jsonb
    )
      INTO v_categories
      FROM jsonb_array_elements(
          COALESCE(v_base->'categories','[]'::jsonb)
      ) WITH ORDINALITY c(category_json, ord);

    RETURN jsonb_set(v_base, '{categories}', v_categories, true);
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_leaderboard_a_gogo_ronda(uuid)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_leaderboard_a_gogo_ronda(uuid)
TO authenticated, service_role;

COMMIT;
