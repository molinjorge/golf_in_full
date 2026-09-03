-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 234 — A-GO-GO: EXIGIR HCP TEAM CURRENT ANTES DEL FREEZE
--
-- Objetivo:
-- Reforzar el gate de congelamiento para torneos TEAM/team_stroke con
-- clasificación Neto. Además de exigir una configuración HCP TEAM válida
-- (Migración 231), cada equipo activo con integrantes debe tener una versión
-- HCP TEAM CURRENT para cada ronda activa TEAM/team_stroke antes del freeze.
--
-- Principios:
-- 1) Reutiliza tournament_round_team_handicap_versions y su semántica
--    MISSING / STALE / CURRENT de Migración 204.
-- 2) NO recalcula automáticamente; sólo bloquea y orienta.
-- 3) NO congela para siempre el valor HCP TEAM. Después del freeze siguen
--    vigentes los flujos auditados de cambio de composición y recálculo.
-- 4) Gross-only permanece sin requerir HCP TEAM.
-- 5) Stroke Play y Stableford no cambian.
-- 6) El RPC real de congelamiento ya consume previsualizar_congelamiento_torneo,
--    por lo que no se modifica el RPC de congelar.

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
    v_team_hcp_state_errors jsonb := '[]'::jsonb;
    v_team_hcp_state_count integer := 0;
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

    -- HCP TEAM sólo es requisito competitivo cuando:
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

        -- Contrato de configuración de Migración 231.
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

        -- Migración 234:
        -- Si la configuración es válida, cada equipo activo que realmente
        -- tiene integrantes debe tener HCP TEAM vigente por cada ronda
        -- TEAM/team_stroke. Se reutiliza la semántica de vigencia de M204:
        -- ausencia = MISSING; is_stale=true = STALE; de lo contrario CURRENT.
        IF v_team_hcp_count = 0 THEN
            WITH team_rounds AS (
                SELECT
                    tr.id AS round_id,
                    tr.numero_ronda
                FROM public.tournament_rounds tr
                JOIN public.tournaments t
                  ON t.id = tr.tournament_id
                JOIN public.tournament_formats tf
                  ON tf.id = COALESCE(
                        tr.tournament_format_id,
                        t.tournament_format_id
                     )
                WHERE tr.tournament_id = p_tournament_id
                  AND tr.activo = true
                  AND tf.tipo_participacion::text = 'equipo'
                  AND tf.scoring_engine::text = 'team_stroke'
            ),
            active_teams AS (
                SELECT
                    tt.id AS team_id,
                    tt.nombre_equipo
                FROM public.tournament_teams tt
                WHERE tt.tournament_id = p_tournament_id
                  AND tt.activo = true
                  AND EXISTS (
                      SELECT 1
                      FROM public.tournament_registrations reg
                      WHERE reg.tournament_id = p_tournament_id
                        AND reg.tournament_team_id = tt.id
                        AND reg.activo = true
                  )
            ),
            team_round_state AS (
                SELECT
                    r.round_id,
                    r.numero_ronda,
                    t.team_id,
                    t.nombre_equipo,
                    v.id AS version_id,
                    v.config_id,
                    v.is_stale
                FROM team_rounds r
                CROSS JOIN active_teams t
                LEFT JOIN LATERAL (
                    SELECT hv.*
                    FROM public.tournament_round_team_handicap_versions hv
                    WHERE hv.tournament_round_id = r.round_id
                      AND hv.tournament_team_id = t.team_id
                      AND hv.status = 'active'
                    ORDER BY hv.version DESC, hv.created_at DESC, hv.id
                    LIMIT 1
                ) v ON true
            ),
            invalid_states AS (
                SELECT
                    s.*,
                    CASE
                        WHEN s.version_id IS NULL THEN 'MISSING'
                        ELSE 'STALE'
                    END AS hcp_state
                FROM team_round_state s
                WHERE s.version_id IS NULL
                   OR COALESCE(s.is_stale, false) = true
                   OR s.config_id IS DISTINCT FROM v_config.id
            )
            SELECT
                COALESCE(
                    jsonb_agg(
                        jsonb_build_object(
                            'code',
                                CASE
                                    WHEN i.hcp_state = 'MISSING'
                                    THEN 'team_hcp_missing_before_freeze'
                                    ELSE 'team_hcp_stale_before_freeze'
                                END,
                            'message',
                                CASE
                                    WHEN i.hcp_state = 'MISSING'
                                    THEN format(
                                        'El equipo %s no tiene HCP TEAM calculado para la ronda %s. Recalcula los HCP TEAM pendientes antes de congelar.',
                                        i.nombre_equipo,
                                        i.numero_ronda
                                    )
                                    ELSE format(
                                        'El HCP TEAM del equipo %s está pendiente de recalcular para la ronda %s. Recalcula los HCP TEAM pendientes antes de congelar.',
                                        i.nombre_equipo,
                                        i.numero_ronda
                                    )
                                END,
                            'roundId', i.round_id,
                            'teamId', i.team_id,
                            'teamName', i.nombre_equipo,
                            'state', i.hcp_state
                        )
                        ORDER BY i.numero_ronda, i.nombre_equipo, i.team_id
                    ),
                    '[]'::jsonb
                ),
                count(*)::integer
              INTO v_team_hcp_state_errors, v_team_hcp_state_count
              FROM invalid_states i;
        END IF;
    END IF;

    RETURN
        v_base
        || jsonb_build_object(
            'ready',
                COALESCE((v_base->>'ready')::boolean, false)
                AND v_extra_count = 0
                AND v_team_hcp_count = 0
                AND v_team_hcp_state_count = 0,
            'errors',
                COALESCE(v_base->'errors', '[]'::jsonb)
                || v_extra_errors
                || v_team_hcp_errors
                || v_team_hcp_state_errors,
            'counts',
                COALESCE(v_base->'counts', '{}'::jsonb)
                || jsonb_build_object(
                    'errors',
                        COALESCE(
                            (v_base #>> '{counts,errors}')::integer,
                            0
                        )
                        + v_extra_count
                        + v_team_hcp_count
                        + v_team_hcp_state_count
                )
        );
END;
$function$;

COMMENT ON FUNCTION public.previsualizar_congelamiento_torneo(uuid) IS
'Previsualiza el congelamiento. Para A-Go-Go/team_stroke con Neto exige configuración HCP TEAM válida y una versión HCP TEAM CURRENT por equipo activo y ronda antes del freeze.';

COMMIT;
