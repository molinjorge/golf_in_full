-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 231 — VALIDAR HCP TEAM ANTES DE CONGELAR A-GO-GO NETO
--
-- Objetivo:
-- 1) Impedir congelar un torneo/ronda TEAM + team_stroke cuando exista
--    clasificación Neto y no haya configuración activa de HCP TEAM.
-- 2) Impedir congelar Neto con método GROSS_ONLY.
-- 3) Para ASSIGNED_TABLE_SUM_HI, exigir que exista al menos un rango.
-- 4) Reutilizar el gate común previsualizar_congelamiento_torneo(), sin
--    alterar el motor de congelamiento 218 ni los recálculos versionados.
--
-- NO hace:
-- - No cambia Stroke Play ni Stableford.
-- - No cambia composición de equipos ni HCP TEAM versionado.
-- - No modifica torneos ya congelados.
-- - No bloquea aquí la edición post-freeze: el frontend ya la controla;
--   esta migración corrige exclusivamente el hueco que permitía congelar
--   Neto sin método HCP TEAM previamente configurado.

BEGIN;

CREATE OR REPLACE FUNCTION public.previsualizar_congelamiento_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base jsonb;
    v_extra_errors jsonb;
    v_extra_count integer;
    v_team_hcp_errors jsonb := '[]'::jsonb;
    v_team_hcp_count integer := 0;
    v_is_team_stroke boolean := false;
    v_has_neto boolean := false;
    v_config public.tournament_team_handicap_configs%ROWTYPE;
    v_range_count integer := 0;
BEGIN
    v_base :=
        public._previsualizar_congelamiento_torneo_core_218(
            p_tournament_id
        );

    -- Validación común ya existente: toda categoría debe tener clasificación.
    SELECT
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'code', 'category_classification_missing',
                    'message',
                        format(
                            'La categoría %s no tiene clasificación competitiva definida (Gross, Neto o ambas).',
                            c.nombre
                        ),
                    'tournamentCategoryId', tc.id
                )
                ORDER BY c.display_order NULLS LAST, c.nombre, tc.id
            ),
            '[]'::jsonb
        ),
        count(*)::integer
      INTO v_extra_errors, v_extra_count
      FROM public.tournament_categories tc
      JOIN public.categories c
        ON c.id = tc.category_id
     WHERE tc.tournament_id = p_tournament_id
       AND NOT EXISTS (
            SELECT 1
            FROM public.tournament_category_classifications cc
            WHERE cc.tournament_category_id = tc.id
              AND cc.tournament_id = tc.tournament_id
       );

    -- La configuración HCP TEAM sólo es requisito competitivo cuando:
    -- a) existe al menos una ronda activa TEAM/team_stroke, y
    -- b) al menos una categoría del torneo clasifica Neto.
    SELECT EXISTS (
        SELECT 1
        FROM public.tournament_rounds tr
        JOIN public.tournaments t
          ON t.id = tr.tournament_id
        JOIN public.tournament_formats tf
          ON tf.id = COALESCE(tr.tournament_format_id, t.tournament_format_id)
        WHERE tr.tournament_id = p_tournament_id
          AND tr.activo = true
          AND tf.tipo_participacion::text = 'equipo'
          AND tf.scoring_engine::text = 'team_stroke'
    ) INTO v_is_team_stroke;

    SELECT EXISTS (
        SELECT 1
        FROM public.tournament_category_classifications cc
        WHERE cc.tournament_id = p_tournament_id
          AND cc.tipo_resultado::text = 'neto'
    ) INTO v_has_neto;

    IF v_is_team_stroke AND v_has_neto THEN
        SELECT *
          INTO v_config
          FROM public.tournament_team_handicap_configs c
         WHERE c.tournament_id = p_tournament_id
           AND c.active = true
         LIMIT 1;

        IF v_config.id IS NULL THEN
            v_team_hcp_errors := v_team_hcp_errors || jsonb_build_array(
                jsonb_build_object(
                    'code', 'team_hcp_config_missing',
                    'message', 'El torneo A-Go-Go incluye clasificación Neto y debe configurar el método de HCP TEAM antes de congelar.'
                )
            );
            v_team_hcp_count := v_team_hcp_count + 1;

        ELSIF v_config.method = 'GROSS_ONLY' THEN
            v_team_hcp_errors := v_team_hcp_errors || jsonb_build_array(
                jsonb_build_object(
                    'code', 'team_hcp_gross_only_incompatible',
                    'message', 'El torneo A-Go-Go incluye clasificación Neto; el método HCP TEAM no puede ser GROSS_ONLY.'
                )
            );
            v_team_hcp_count := v_team_hcp_count + 1;

        ELSIF v_config.method = 'AVERAGE_HI_PCT'
              AND (v_config.average_pct IS NULL
                   OR v_config.average_pct < 0
                   OR v_config.average_pct > 100) THEN
            v_team_hcp_errors := v_team_hcp_errors || jsonb_build_array(
                jsonb_build_object(
                    'code', 'team_hcp_average_pct_invalid',
                    'message', 'El método AVERAGE_HI_PCT requiere un porcentaje válido entre 0 y 100 antes de congelar.'
                )
            );
            v_team_hcp_count := v_team_hcp_count + 1;

        ELSIF v_config.method = 'ASSIGNED_TABLE_SUM_HI' THEN
            SELECT count(*)::integer
              INTO v_range_count
              FROM public.tournament_team_handicap_ranges r
             WHERE r.config_id = v_config.id;

            IF v_range_count = 0 THEN
                v_team_hcp_errors := v_team_hcp_errors || jsonb_build_array(
                    jsonb_build_object(
                        'code', 'team_hcp_ranges_missing',
                        'message', 'El método ASSIGNED_TABLE_SUM_HI requiere al menos un rango de HCP TEAM antes de congelar.',
                        'configId', v_config.id
                    )
                );
                v_team_hcp_count := v_team_hcp_count + 1;
            END IF;
        END IF;
    END IF;

    RETURN
        v_base
        || jsonb_build_object(
            'ready',
                COALESCE((v_base->>'ready')::boolean, false)
                AND v_extra_count = 0
                AND v_team_hcp_count = 0,
            'errors',
                COALESCE(v_base->'errors', '[]'::jsonb)
                || v_extra_errors
                || v_team_hcp_errors,
            'counts',
                COALESCE(v_base->'counts', '{}'::jsonb)
                || jsonb_build_object(
                    'errors',
                        COALESCE(
                            (v_base #>> '{counts,errors}')::integer,
                            0
                        ) + v_extra_count + v_team_hcp_count
                )
        );
END;
$function$;

COMMENT ON FUNCTION public.previsualizar_congelamiento_torneo(uuid) IS
'Previsualiza el congelamiento común. Desde migración 231, A-Go-Go/team_stroke con clasificación Neto exige configuración válida de HCP TEAM antes de congelar.';

COMMIT;
