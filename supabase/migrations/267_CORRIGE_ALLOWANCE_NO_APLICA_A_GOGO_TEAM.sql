-- ============================================================
-- MIGRACIÓN 267
-- CORRIGE HANDICAP ALLOWANCE EN CONFIGURACIÓN DE RONDAS A-GOGO
-- ============================================================
-- Objetivo:
--   Alinear el validador estructural de rondas (Migración 263)
--   con el contrato A-Go-Go/team_stroke establecido en la
--   Migración 218.
--
-- Regla:
--   - Stroke Play / Stableford individual:
--       Handicap Allowance efectivo sigue siendo obligatorio
--       y debe estar entre 0 y 100.
--   - A-Go-Go TEAM:
--       Handicap Allowance individual NO APLICA.
--       Puede permanecer NULL.
--       El hándicap competitivo se controla mediante HCP TEAM.
--
-- Alcance:
--   - No modifica datos.
--   - No asigna porcentajes artificiales.
--   - No cambia freeze, HCP TEAM, grupos, salidas ni scoring.
--   - Sólo corrige el estado estructural de Rondas usado por
--     el Asistente Operativo.
-- ============================================================

CREATE OR REPLACE FUNCTION public.obtener_estado_configuracion_rondas_263(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament public.tournaments%ROWTYPE;
    v_declared integer := 0;
    v_active integer := 0;
    v_frozen boolean := false;
    v_errors jsonb := '[]'::jsonb;
    v_rounds jsonb := '[]'::jsonb;
    v_error_count integer := 0;
BEGIN
    SELECT *
      INTO v_tournament
      FROM public.tournaments
     WHERE id = p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    v_declared := COALESCE(v_tournament.numero_rondas, 0);

    SELECT count(*)::integer
      INTO v_active
      FROM public.tournament_rounds tr
     WHERE tr.tournament_id = p_tournament_id
       AND tr.activo = true;

    SELECT EXISTS (
        SELECT 1
          FROM public.tournament_condition_freezes f
         WHERE f.tournament_id = p_tournament_id
    )
    INTO v_frozen;

    IF v_frozen THEN
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'roundId', tr.id,
                    'roundNumber', tr.numero_ronda,
                    'date', tr.fecha,
                    'courseId', tr.campo_golf_id,
                    'startFormat', tr.formato_salida,
                    'status', 'COMPLETE',
                    'grandfatheredByFreeze', true
                )
                ORDER BY tr.numero_ronda
            ),
            '[]'::jsonb
        )
        INTO v_rounds
        FROM public.tournament_rounds tr
        WHERE tr.tournament_id = p_tournament_id
          AND tr.activo = true;

        RETURN jsonb_build_object(
            'complete', true,
            'status', 'COMPLETE',
            'frozen', true,
            'declaredRounds', v_declared,
            'activeRounds', v_active,
            'errors', '[]'::jsonb,
            'rounds', v_rounds,
            'message',
                'La configuración estructural de rondas ya fue superada antes del congelamiento.',
            'recommendation', NULL
        );
    END IF;

    WITH round_state AS (
        SELECT
            tr.id,
            tr.numero_ronda,
            tr.fecha,
            tr.campo_golf_id,
            tr.formato_salida::text AS start_format,
            COALESCE(tr.tournament_format_id, t.tournament_format_id)
                AS effective_format_id,
            tf.code AS format_code,
            tf.name AS format_name,
            tf.activo AS format_active,
            tf.tipo_participacion::text AS participation_type,
            tf.scoring_engine::text AS scoring_engine,
            COALESCE(
                tr.handicap_allowance_pct,
                tf.handicap_allowance_default
            ) AS effective_allowance,
            (
                tf.tipo_participacion::text = 'equipo'
                AND tf.scoring_engine::text = 'team_stroke'
            ) AS allowance_not_applicable,
            cg.activo AS course_active,
            (
                SELECT count(*)::integer
                  FROM public.tournament_round_shifts s
                 WHERE s.tournament_round_id = tr.id
                   AND s.activo = true
            ) AS active_shifts,
            EXISTS (
                SELECT 1
                  FROM public.tournament_start_engine_registry r
                 WHERE r.start_format::text = COALESCE(tr.formato_salida::text, '')
                   AND r.participation_type =
                       COALESCE(tf.tipo_participacion::text, '')
                   AND r.scoring_engine =
                       COALESCE(tf.scoring_engine::text, '')
                   AND r.activo = true
            ) AS engine_supported
        FROM public.tournament_rounds tr
        JOIN public.tournaments t
          ON t.id = tr.tournament_id
        LEFT JOIN public.tournament_formats tf
          ON tf.id = COALESCE(
              tr.tournament_format_id,
              t.tournament_format_id
          )
        LEFT JOIN public.campos_golf cg
          ON cg.id = tr.campo_golf_id
        WHERE tr.tournament_id = p_tournament_id
          AND tr.activo = true
    ),
    per_round AS (
        SELECT
            rs.*,
            (
                CASE
                    WHEN rs.fecha IS NULL THEN
                        jsonb_build_array(
                            jsonb_build_object(
                                'code', 'round_date_missing',
                                'message', format(
                                    'La ronda %s no tiene fecha.',
                                    rs.numero_ronda
                                )
                            )
                        )
                    ELSE '[]'::jsonb
                END
                ||
                CASE
                    WHEN rs.campo_golf_id IS NULL
                         OR COALESCE(rs.course_active, false) = false THEN
                        jsonb_build_array(
                            jsonb_build_object(
                                'code', 'round_course_missing_or_inactive',
                                'message', format(
                                    'La ronda %s no tiene un campo activo válido.',
                                    rs.numero_ronda
                                )
                            )
                        )
                    ELSE '[]'::jsonb
                END
                ||
                CASE
                    WHEN rs.effective_format_id IS NULL
                         OR rs.format_code IS NULL
                         OR COALESCE(rs.format_active, false) = false THEN
                        jsonb_build_array(
                            jsonb_build_object(
                                'code', 'round_format_missing_or_inactive',
                                'message', format(
                                    'La ronda %s no tiene una modalidad competitiva activa válida.',
                                    rs.numero_ronda
                                )
                            )
                        )
                    ELSE '[]'::jsonb
                END
                ||
                CASE
                    WHEN NOT COALESCE(rs.allowance_not_applicable, false)
                         AND (
                             rs.effective_allowance IS NULL
                             OR rs.effective_allowance < 0
                             OR rs.effective_allowance > 100
                         ) THEN
                        jsonb_build_array(
                            jsonb_build_object(
                                'code', 'round_handicap_allowance_invalid',
                                'message', format(
                                    'La ronda %s no tiene Handicap Allowance efectivo válido entre 0 y 100.',
                                    rs.numero_ronda
                                )
                            )
                        )
                    ELSE '[]'::jsonb
                END
                ||
                CASE
                    WHEN rs.start_format IS NULL THEN
                        jsonb_build_array(
                            jsonb_build_object(
                                'code', 'round_start_format_missing',
                                'message', format(
                                    'La ronda %s no tiene modalidad de salida definida.',
                                    rs.numero_ronda
                                )
                            )
                        )
                    ELSE '[]'::jsonb
                END
                ||
                CASE
                    WHEN rs.active_shifts = 0 THEN
                        jsonb_build_array(
                            jsonb_build_object(
                                'code', 'round_shift_missing',
                                'message', format(
                                    'La ronda %s no tiene ningún turno activo.',
                                    rs.numero_ronda
                                )
                            )
                        )
                    ELSE '[]'::jsonb
                END
                ||
                CASE
                    WHEN rs.start_format IS NOT NULL
                         AND rs.effective_format_id IS NOT NULL
                         AND NOT rs.engine_supported THEN
                        jsonb_build_array(
                            jsonb_build_object(
                                'code', 'round_start_engine_unsupported',
                                'message', format(
                                    'La combinación de salida y modalidad de la ronda %s no tiene un motor operativo soportado.',
                                    rs.numero_ronda
                                ),
                                'startFormat', rs.start_format,
                                'participationType', rs.participation_type,
                                'scoringEngine', rs.scoring_engine
                            )
                        )
                    ELSE '[]'::jsonb
                END
            ) AS errors
        FROM round_state rs
    )
    SELECT
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'roundId', pr.id,
                    'roundNumber', pr.numero_ronda,
                    'date', pr.fecha,
                    'courseId', pr.campo_golf_id,
                    'formatId', pr.effective_format_id,
                    'formatCode', pr.format_code,
                    'formatName', pr.format_name,
                    'participationType', pr.participation_type,
                    'scoringEngine', pr.scoring_engine,
                    'handicapAllowancePct', pr.effective_allowance,
                    'handicapAllowanceApplicable',
                        NOT COALESCE(pr.allowance_not_applicable, false),
                    'startFormat', pr.start_format,
                    'activeShifts', pr.active_shifts,
                    'engineSupported', pr.engine_supported,
                    'status',
                        CASE
                            WHEN jsonb_array_length(pr.errors) = 0
                                THEN 'COMPLETE'
                            ELSE 'BLOCKED'
                        END,
                    'errors', pr.errors
                )
                ORDER BY pr.numero_ronda
            ),
            '[]'::jsonb
        ),
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'roundId', pr2.id,
                        'roundNumber', pr2.numero_ronda
                    ) || e.value
                    ORDER BY pr2.numero_ronda
                )
                FROM per_round pr2
                CROSS JOIN LATERAL
                    jsonb_array_elements(pr2.errors) e(value)
            ),
            '[]'::jsonb
        )
    INTO v_rounds, v_errors
    FROM per_round pr;

    IF v_declared <= 0 OR v_active <> v_declared THEN
        v_errors :=
            jsonb_build_array(
                jsonb_build_object(
                    'code', 'round_count_mismatch',
                    'message', format(
                        'El torneo declara %s ronda(s) y actualmente tiene %s ronda(s) activa(s).',
                        v_declared,
                        v_active
                    )
                )
            ) || COALESCE(v_errors, '[]'::jsonb);
    END IF;

    v_error_count :=
        jsonb_array_length(COALESCE(v_errors, '[]'::jsonb));

    RETURN jsonb_build_object(
        'complete', v_error_count = 0,
        'status',
            CASE
                WHEN v_error_count = 0 THEN 'COMPLETE'
                ELSE 'INCOMPLETE'
            END,
        'frozen', false,
        'declaredRounds', v_declared,
        'activeRounds', v_active,
        'errors', COALESCE(v_errors, '[]'::jsonb),
        'rounds', COALESCE(v_rounds, '[]'::jsonb),
        'message',
            CASE
                WHEN v_error_count = 0
                    THEN 'Todas las rondas tienen completa su configuración estructural.'
                ELSE 'Una o más rondas tienen configuración estructural pendiente.'
            END,
        'recommendation',
            CASE
                WHEN v_error_count = 0 THEN NULL
                ELSE
                    'Revisa la pestaña Rondas y completa fecha, campo, modalidad, los parámetros de hándicap que apliquen, formato de salida y al menos un turno activo.'
            END
    );
END;
$function$;

-- Mantener ACL existente del RPC público.
REVOKE ALL ON FUNCTION public.obtener_estado_configuracion_rondas_263(uuid)
FROM PUBLIC;

REVOKE ALL ON FUNCTION public.obtener_estado_configuracion_rondas_263(uuid)
FROM anon;

GRANT EXECUTE ON FUNCTION public.obtener_estado_configuracion_rondas_263(uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.obtener_estado_configuracion_rondas_263(uuid)
TO service_role;
