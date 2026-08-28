-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 198 Fase 2
-- Consumo de clasificación competitiva congelada en Stroke Play
-- ============================================================================
-- Objetivo
--   Hacer que Stroke Play respete, por categoría y ronda, únicamente las
--   clasificaciones competitivas congeladas (gross / neto) sin dejar de
--   conservar la métrica no competitiva como dato informativo.
--
-- Alcance
--   - Leaderboard Stroke: sólo genera posición/empate competitivo para los
--     tipos de resultado habilitados en el snapshot de clasificación.
--   - Desempates Stroke: sólo expone grupos de desempate competitivos.
--   - Resolución manual Stroke: impide resolver un tipo no competitivo.
--   - Cierre por categoría y publicación heredan esta política a través de
--     los contratos comunes existentes (192–195).
--   - Stableford no se modifica: su motor ya consume grossEnabled/netEnabled
--     desde tournament_category_classification_snapshots.
--
-- Compatibilidad histórica
--   Para freezes antiguos que no tienen snapshots de clasificación se aplica
--   fallback LEGACY_BOTH únicamente para no romper torneos históricos de
--   prueba. Los freezes nuevos deben tener al menos una clasificación por
--   categoría por la validación introducida en 198 Fase 1.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Resolver la política competitiva congelada por ronda/categoría.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._clasificaciones_competitivas_ronda_categoria(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_freeze_id uuid;
    v_count integer;
    v_gross boolean;
    v_net boolean;
BEGIN
    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    SELECT s.freeze_id
      INTO v_freeze_id
      FROM public.tournament_round_condition_snapshots s
     WHERE s.tournament_round_id=p_tournament_round_id
     ORDER BY s.created_at DESC, s.id DESC
     LIMIT 1;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION 'La ronda no tiene snapshot congelado de condiciones.'
            USING ERRCODE='55000';
    END IF;

    SELECT
        count(*)::integer,
        bool_or(s.tipo_resultado='gross'::public.tipo_resultado_desempate),
        bool_or(s.tipo_resultado='neto'::public.tipo_resultado_desempate)
      INTO v_count, v_gross, v_net
      FROM public.tournament_category_classification_snapshots s
     WHERE s.freeze_id=v_freeze_id
       AND s.tournament_category_id IS NOT DISTINCT FROM p_tournament_category_id;

    -- Compatibilidad con freezes históricos previos a snapshots de clasificación.
    IF COALESCE(v_count,0)=0 THEN
        RETURN jsonb_build_object(
            'freezeId',v_freeze_id,
            'configuredResultTypes',jsonb_build_array('gross','neto'),
            'grossEnabled',true,
            'netEnabled',true,
            'source','LEGACY_BOTH'
        );
    END IF;

    RETURN jsonb_build_object(
        'freezeId',v_freeze_id,
        'configuredResultTypes',(
            SELECT COALESCE(
                jsonb_agg(s.tipo_resultado::text ORDER BY s.tipo_resultado::text),
                '[]'::jsonb
            )
              FROM public.tournament_category_classification_snapshots s
             WHERE s.freeze_id=v_freeze_id
               AND s.tournament_category_id IS NOT DISTINCT FROM p_tournament_category_id
        ),
        'grossEnabled',COALESCE(v_gross,false),
        'netEnabled',COALESCE(v_net,false),
        'source','FROZEN_SNAPSHOT'
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public._tipo_resultado_competitivo_ronda(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid,
    p_tipo_resultado public.tipo_resultado_desempate
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
    SELECT CASE p_tipo_resultado
        WHEN 'gross'::public.tipo_resultado_desempate
            THEN COALESCE((public._clasificaciones_competitivas_ronda_categoria(
                    p_tournament_round_id,p_tournament_category_id
                 )->>'grossEnabled')::boolean,false)
        WHEN 'neto'::public.tipo_resultado_desempate
            THEN COALESCE((public._clasificaciones_competitivas_ronda_categoria(
                    p_tournament_round_id,p_tournament_category_id
                 )->>'netEnabled')::boolean,false)
        ELSE false
    END;
$function$;

-- ---------------------------------------------------------------------------
-- 2. Filtro competitivo de leaderboard Stroke.
--    Mantiene total/valor de la métrica, pero elimina rango/empate competitivo
--    cuando el tipo de resultado no fue configurado para la categoría.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._aplicar_clasificacion_competitiva_leaderboard_stroke(
    p_tournament_round_id uuid,
    p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_out jsonb := COALESCE(p_payload,'{}'::jsonb);
    v_categories jsonb := '[]'::jsonb;
    v_cat jsonb;
    v_cat_out jsonb;
    v_players jsonb;
    v_players_out jsonb;
    v_player jsonb;
    v_player_out jsonb;
    v_cls jsonb;
    v_cat_id uuid;
    v_gross boolean;
    v_net boolean;
    v_any_gross_ties boolean := false;
    v_any_net_ties boolean := false;
    v_cat_gross_ties boolean;
    v_cat_net_ties boolean;
    v_unresolved integer;
    v_status text;
BEGIN
    FOR v_cat IN
        SELECT value FROM jsonb_array_elements(COALESCE(v_out->'categories','[]'::jsonb))
    LOOP
        v_cat_id := NULLIF(v_cat->>'tournamentCategoryId','')::uuid;
        v_cls := public._clasificaciones_competitivas_ronda_categoria(
            p_tournament_round_id,
            v_cat_id
        );
        v_gross := COALESCE((v_cls->>'grossEnabled')::boolean,false);
        v_net := COALESCE((v_cls->>'netEnabled')::boolean,false);

        v_players_out := '[]'::jsonb;
        FOR v_player IN
            SELECT value FROM jsonb_array_elements(COALESCE(v_cat->'players','[]'::jsonb))
        LOOP
            v_player_out := v_player;

            IF v_player_out ? 'gross' THEN
                v_player_out := jsonb_set(
                    v_player_out,
                    '{gross,enabled}',
                    to_jsonb(v_gross),
                    true
                );
                IF NOT v_gross THEN
                    v_player_out := jsonb_set(v_player_out,'{gross,rank}','null'::jsonb,true);
                    v_player_out := jsonb_set(v_player_out,'{gross,tieSize}','null'::jsonb,true);
                    v_player_out := jsonb_set(v_player_out,'{gross,tiebreakPending}','false'::jsonb,true);
                END IF;
            END IF;

            IF v_player_out ? 'net' THEN
                v_player_out := jsonb_set(
                    v_player_out,
                    '{net,enabled}',
                    to_jsonb(v_net),
                    true
                );
                IF NOT v_net THEN
                    v_player_out := jsonb_set(v_player_out,'{net,rank}','null'::jsonb,true);
                    v_player_out := jsonb_set(v_player_out,'{net,tieSize}','null'::jsonb,true);
                    v_player_out := jsonb_set(v_player_out,'{net,tiebreakPending}','false'::jsonb,true);
                END IF;
            END IF;

            v_players_out := v_players_out || jsonb_build_array(v_player_out);
        END LOOP;

        v_cat_out := jsonb_set(v_cat,'{players}',v_players_out,true);
        v_cat_out := jsonb_set(v_cat_out,'{classification}',v_cls,true);

        v_cat_gross_ties := CASE
            WHEN v_gross THEN COALESCE((v_cat#>>'{summary,hasGrossTies}')::boolean,false)
            ELSE false
        END;
        v_cat_net_ties := CASE
            WHEN v_net THEN COALESCE((v_cat#>>'{summary,hasNetTies}')::boolean,false)
            ELSE false
        END;

        v_cat_out := jsonb_set(v_cat_out,'{summary,hasGrossTies}',to_jsonb(v_cat_gross_ties),true);
        v_cat_out := jsonb_set(v_cat_out,'{summary,hasNetTies}',to_jsonb(v_cat_net_ties),true);

        v_any_gross_ties := v_any_gross_ties OR v_cat_gross_ties;
        v_any_net_ties := v_any_net_ties OR v_cat_net_ties;

        v_categories := v_categories || jsonb_build_array(v_cat_out);
    END LOOP;

    v_out := jsonb_set(v_out,'{categories}',v_categories,true);
    v_out := jsonb_set(v_out,'{summary,hasGrossTies}',to_jsonb(v_any_gross_ties),true);
    v_out := jsonb_set(v_out,'{summary,hasNetTies}',to_jsonb(v_any_net_ties),true);
    v_out := jsonb_set(v_out,'{status,hasAnyTies}',to_jsonb(v_any_gross_ties OR v_any_net_ties),true);

    v_unresolved := COALESCE(NULLIF(v_out#>>'{summary,unresolvedPlayers}','')::integer,0);
    v_status := CASE
        WHEN v_unresolved>0 THEN 'PROVISIONAL'
        WHEN v_any_gross_ties OR v_any_net_ties THEN 'READY_FOR_TIEBREAK'
        ELSE 'READY_FOR_PUBLICATION'
    END;
    v_out := jsonb_set(v_out,'{status,leaderboardStatus}',to_jsonb(v_status),true);

    v_out := jsonb_set(
        v_out,
        '{classificationPolicy}',
        jsonb_build_object(
            'mode','FROZEN_CATEGORY_CLASSIFICATIONS',
            'nonCompetitiveMetricsRemainInformational',true
        ),
        true
    );

    RETURN v_out;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. Filtro competitivo de grupos de desempate Stroke.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._aplicar_clasificacion_competitiva_desempates_stroke(
    p_tournament_round_id uuid,
    p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_out jsonb := COALESCE(p_payload,'{}'::jsonb);
    v_groups jsonb := '[]'::jsonb;
    v_group jsonb;
    v_cat_id uuid;
    v_type public.tipo_resultado_desempate;
    v_tie_groups integer := 0;
    v_auto integer := 0;
    v_manual integer := 0;
    v_missing integer := 0;
    v_persist integer := 0;
    v_round_resolved boolean;
    v_engine_status text;
BEGIN
    FOR v_group IN
        SELECT value FROM jsonb_array_elements(COALESCE(v_out->'tieGroups','[]'::jsonb))
    LOOP
        v_cat_id := NULLIF(v_group->>'tournamentCategoryId','')::uuid;
        v_type := NULLIF(v_group->>'resultType','')::public.tipo_resultado_desempate;

        IF v_type IS NOT NULL
           AND public._tipo_resultado_competitivo_ronda(
                p_tournament_round_id,
                v_cat_id,
                v_type
           )
        THEN
            v_groups := v_groups || jsonb_build_array(v_group);
            v_tie_groups := v_tie_groups + 1;

            CASE v_group->>'status'
                WHEN 'RESOLVED_AUTOMATIC' THEN v_auto := v_auto + 1;
                WHEN 'MANUAL_PENDING' THEN v_manual := v_manual + 1;
                WHEN 'CONFIG_MISSING' THEN v_missing := v_missing + 1;
                WHEN 'TIE_PERSISTS_AFTER_RULES' THEN v_persist := v_persist + 1;
                ELSE NULL;
            END CASE;
        END IF;
    END LOOP;

    v_round_resolved := COALESCE((v_out#>>'{round,roundResolved}')::boolean,true);

    v_engine_status := CASE
        WHEN v_tie_groups=0 THEN 'NO_TIES'
        WHEN v_missing>0 THEN
            CASE WHEN v_round_resolved
                THEN 'CONFIGURATION_REQUIRED'
                ELSE 'PROVISIONAL_CONFIGURATION_REQUIRED'
            END
        WHEN v_manual>0 OR v_persist>0 THEN
            CASE WHEN v_round_resolved
                THEN 'ACTION_REQUIRED'
                ELSE 'PROVISIONAL_ACTION_REQUIRED'
            END
        WHEN v_round_resolved THEN 'RESOLVED'
        ELSE 'PROVISIONAL_RESOLVED'
    END;

    v_out := jsonb_set(v_out,'{tieGroups}',v_groups,true);
    v_out := jsonb_set(
        v_out,
        '{summary}',
        jsonb_build_object(
            'tieGroups',v_tie_groups,
            'automaticResolved',v_auto,
            'manualPending',v_manual,
            'configMissing',v_missing,
            'persistsAfterRules',v_persist,
            'engineStatus',v_engine_status
        ),
        true
    );
    v_out := jsonb_set(
        v_out,
        '{classificationPolicy}',
        jsonb_build_object('mode','FROZEN_CATEGORY_CLASSIFICATIONS'),
        true
    );

    RETURN v_out;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Preservar las implementaciones Stroke existentes como bases internas.
-- ---------------------------------------------------------------------------
DO $do$
BEGIN
    IF to_regprocedure('public._obtener_leaderboard_ronda_base_198_f2(uuid)') IS NULL
       AND to_regprocedure('public.obtener_leaderboard_ronda(uuid)') IS NOT NULL
    THEN
        ALTER FUNCTION public.obtener_leaderboard_ronda(uuid)
            RENAME TO _obtener_leaderboard_ronda_base_198_f2;
    END IF;

    IF to_regprocedure('public._obtener_desempates_ronda_base_198_f2(uuid)') IS NULL
       AND to_regprocedure('public.obtener_desempates_ronda(uuid)') IS NOT NULL
    THEN
        ALTER FUNCTION public.obtener_desempates_ronda(uuid)
            RENAME TO _obtener_desempates_ronda_base_198_f2;
    END IF;

    IF to_regprocedure('public._resolver_desempate_manual_ronda_base_198_f2(uuid,uuid,public.tipo_resultado_desempate,integer,integer,uuid[],text)') IS NULL
       AND to_regprocedure('public.resolver_desempate_manual_ronda(uuid,uuid,public.tipo_resultado_desempate,integer,integer,uuid[],text)') IS NOT NULL
    THEN
        ALTER FUNCTION public.resolver_desempate_manual_ronda(
            uuid,uuid,public.tipo_resultado_desempate,integer,integer,uuid[],text
        ) RENAME TO _resolver_desempate_manual_ronda_base_198_f2;
    END IF;
END;
$do$;

-- ---------------------------------------------------------------------------
-- 5. Contratos públicos Stroke con política competitiva congelada.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_leaderboard_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_base jsonb;
BEGIN
    v_base := public._obtener_leaderboard_ronda_base_198_f2(
        p_tournament_round_id
    );

    RETURN public._aplicar_clasificacion_competitiva_leaderboard_stroke(
        p_tournament_round_id,
        v_base
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.obtener_desempates_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_base jsonb;
BEGIN
    v_base := public._obtener_desempates_ronda_base_198_f2(
        p_tournament_round_id
    );

    RETURN public._aplicar_clasificacion_competitiva_desempates_stroke(
        p_tournament_round_id,
        v_base
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolver_desempate_manual_ronda(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid,
    p_tipo_resultado public.tipo_resultado_desempate,
    p_base_rank integer,
    p_tied_total integer,
    p_score_card_order uuid[],
    p_notes text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
    IF NOT public._tipo_resultado_competitivo_ronda(
        p_tournament_round_id,
        p_tournament_category_id,
        p_tipo_resultado
    ) THEN
        RAISE EXCEPTION
            'El tipo de resultado % no es clasificación competitiva de esta categoría.',
            p_tipo_resultado::text
            USING ERRCODE='22023';
    END IF;

    RETURN public._resolver_desempate_manual_ronda_base_198_f2(
        p_tournament_round_id,
        p_tournament_category_id,
        p_tipo_resultado,
        p_base_rank,
        p_tied_total,
        p_score_card_order,
        p_notes
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6. Privilegios.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public._clasificaciones_competitivas_ronda_categoria(uuid,uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._tipo_resultado_competitivo_ronda(uuid,uuid,public.tipo_resultado_desempate) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._aplicar_clasificacion_competitiva_leaderboard_stroke(uuid,jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._aplicar_clasificacion_competitiva_desempates_stroke(uuid,jsonb) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public._clasificaciones_competitivas_ronda_categoria(uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public._tipo_resultado_competitivo_ronda(uuid,uuid,public.tipo_resultado_desempate) TO service_role;
GRANT EXECUTE ON FUNCTION public._aplicar_clasificacion_competitiva_leaderboard_stroke(uuid,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public._aplicar_clasificacion_competitiva_desempates_stroke(uuid,jsonb) TO service_role;

REVOKE ALL ON FUNCTION public.obtener_leaderboard_ronda(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.obtener_desempates_ronda(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resolver_desempate_manual_ronda(uuid,uuid,public.tipo_resultado_desempate,integer,integer,uuid[],text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.obtener_leaderboard_ronda(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.obtener_desempates_ronda(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.resolver_desempate_manual_ronda(uuid,uuid,public.tipo_resultado_desempate,integer,integer,uuid[],text) TO authenticated, service_role;

COMMIT;
