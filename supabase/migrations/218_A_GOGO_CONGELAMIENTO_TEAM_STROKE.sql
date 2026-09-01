-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 218 — A-GO-GO: CONGELAMIENTO COMPATIBLE CON TEAM_STROKE
-- ============================================================================
-- Objetivo:
--   Adaptar el congelamiento común para que una ronda A-Go-Go
--   (participation_type='equipo', scoring_engine='team_stroke') NO requiera
--   Handicap Allowance individual ni genere Playing Handicap individual por
--   jugador/ronda.
--
-- Principios preservados:
--   * Stroke Play / Stableford individual conservan su comportamiento actual.
--   * Se sigue congelando la evidencia base de Handicap Index por jugador.
--   * El HCP competitivo A-Go-Go sigue siendo autoridad en
--     tournament_round_team_handicap_versions.
--   * NO se fabrica un allowance 100%/0% para TEAM.
--   * NO se relaja el resto de validaciones del congelamiento.
--
-- Esta migración NO ejecuta el congelamiento de ningún torneo.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. El snapshot de condiciones debe poder expresar "allowance no aplica".
--    Para rondas individuales seguirá siendo obligatorio por validación RPC.
-- ----------------------------------------------------------------------------
ALTER TABLE public.tournament_round_condition_snapshots
    ALTER COLUMN handicap_allowance_pct DROP NOT NULL;

COMMENT ON COLUMN public.tournament_round_condition_snapshots.handicap_allowance_pct IS
'Handicap Allowance congelado de la ronda. NULL significa que no aplica al motor competitivo de la ronda (por ejemplo A-Go-Go equipo/team_stroke).';

-- ----------------------------------------------------------------------------
-- 2. Core de preview 218.
--    Reutiliza íntegramente el validador histórico y elimina ÚNICAMENTE
--    round_without_allowance cuando la ronda efectiva es equipo/team_stroke.
--    Todos los demás errores/advertencias permanecen sin cambios.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._previsualizar_congelamiento_torneo_core_218(
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
    v_errors jsonb;
    v_error_count integer;
BEGIN
    v_base := public._previsualizar_congelamiento_torneo_core_1861a(
        p_tournament_id
    );

    SELECT COALESCE(jsonb_agg(e.item ORDER BY e.ord), '[]'::jsonb),
           count(*)::integer
      INTO v_errors, v_error_count
      FROM jsonb_array_elements(COALESCE(v_base->'errors','[]'::jsonb))
           WITH ORDINALITY AS e(item, ord)
     WHERE NOT (
         e.item->>'code' = 'round_without_allowance'
         AND EXISTS (
             SELECT 1
             FROM public.tournament_rounds tr
             JOIN public.tournaments t
               ON t.id = tr.tournament_id
             JOIN public.tournament_formats tf
               ON tf.id = COALESCE(
                    tr.tournament_format_id,
                    t.tournament_format_id
               )
             WHERE tr.id = NULLIF(e.item->>'roundId','')::uuid
               AND tr.tournament_id = p_tournament_id
               AND tr.activo = true
               AND tf.tipo_participacion::text = 'equipo'
               AND tf.scoring_engine::text = 'team_stroke'
         )
     );

    RETURN v_base
        || jsonb_build_object(
            'ready', v_error_count = 0,
            'errors', v_errors,
            'counts',
                COALESCE(v_base->'counts','{}'::jsonb)
                || jsonb_build_object('errors', v_error_count)
        );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 3. RPC pública de preview.
--    Conserva la validación adicional de clasificación Gross/Net existente;
--    sólo cambia el core base a la versión 218.
-- ----------------------------------------------------------------------------
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
BEGIN
    v_base :=
        public._previsualizar_congelamiento_torneo_core_218(
            p_tournament_id
        );

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

    RETURN
        v_base
        || jsonb_build_object(
            'ready',
                COALESCE((v_base->>'ready')::boolean, false)
                AND v_extra_count = 0,
            'errors',
                COALESCE(v_base->'errors', '[]'::jsonb)
                || v_extra_errors,
            'counts',
                COALESCE(v_base->'counts', '{}'::jsonb)
                || jsonb_build_object(
                    'errors',
                        COALESCE(
                            (v_base #>> '{counts,errors}')::integer,
                            0
                        ) + v_extra_count
                )
        );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. Core de congelamiento 218.
--    Cambios respecto del core histórico:
--      a) snapshot de ronda TEAM guarda allowance NULL;
--      b) NO crea tournament_round_handicap_snapshots para TEAM/team_stroke;
--      c) la integridad espera snapshots de Playing Handicap únicamente para
--         rondas que no sean TEAM/team_stroke.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._congelar_condiciones_y_handicaps_torneo_core_218(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_preview jsonb;
    v_freeze_id uuid;
    v_admin_id uuid;
    v_conditions jsonb;
    v_round_count integer;
    v_participant_count integer;
    v_round_snapshot_count integer;
    v_hole_snapshot_count integer;
    v_round_handicap_count integer;
    v_player_hcp_round_count integer;
    v_expected_round_handicap_count integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para congelar este torneo.' USING ERRCODE = '42501';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(p_tournament_id::text, 136));

    PERFORM 1 FROM public.tournaments
     WHERE id = p_tournament_id FOR UPDATE;
    PERFORM 1 FROM public.tournament_rounds
     WHERE tournament_id = p_tournament_id AND activo = true FOR SHARE;
    PERFORM 1 FROM public.tournament_registrations
     WHERE tournament_id = p_tournament_id AND activo = true FOR SHARE;
    PERFORM 1 FROM public.players p
     WHERE EXISTS (
        SELECT 1 FROM public.tournament_registrations r
        WHERE r.tournament_id = p_tournament_id
          AND r.activo = true
          AND r.player_id = p.id
     ) FOR SHARE;
    PERFORM 1 FROM public.marcas_salida ms
     WHERE EXISTS (
        SELECT 1 FROM public.tournament_registrations r
        WHERE r.tournament_id = p_tournament_id
          AND r.activo = true
          AND r.marca_salida_id = ms.id
     ) OR EXISTS (
        SELECT 1 FROM public.tournament_round_registration_tees rrt
        WHERE rrt.tournament_id = p_tournament_id
          AND rrt.tee_id = ms.id
     ) FOR SHARE;
    PERFORM 1 FROM public.tournament_round_registration_tees
     WHERE tournament_id = p_tournament_id FOR SHARE;
    PERFORM 1 FROM public.hoyos h
     WHERE EXISTS (
        SELECT 1 FROM public.tournament_rounds r
        WHERE r.tournament_id = p_tournament_id
          AND r.activo = true
          AND r.campo_golf_id = h.campo_golf_id
     ) FOR SHARE;
    PERFORM 1 FROM public.tournament_tee_overrides
     WHERE tournament_id = p_tournament_id FOR SHARE;
    PERFORM 1 FROM public.tournament_categories
     WHERE tournament_id = p_tournament_id FOR SHARE;
    PERFORM 1 FROM public.tournament_franjas_handicap
     WHERE tournament_id = p_tournament_id FOR SHARE;
    PERFORM 1 FROM public.tournament_tiebreak_rules
     WHERE tournament_id = p_tournament_id FOR SHARE;

    v_preview := public.previsualizar_congelamiento_torneo(p_tournament_id);

    IF COALESCE((v_preview #>> '{counts,errors}')::integer, 0) > 0 THEN
        RAISE EXCEPTION 'El torneo no está listo para congelarse.'
            USING ERRCODE = '22023', DETAIL = v_preview::text;
    END IF;

    SELECT count(*)
      INTO v_round_count
      FROM public.tournament_rounds
     WHERE tournament_id = p_tournament_id
       AND activo = true;

    SELECT count(*)
      INTO v_participant_count
      FROM public.tournament_registrations
     WHERE tournament_id = p_tournament_id
       AND activo = true;

    -- Sólo estas rondas requieren Course/Playing Handicap individual congelado.
    SELECT count(*)
      INTO v_player_hcp_round_count
      FROM public.tournament_rounds tr
      JOIN public.tournaments t
        ON t.id = tr.tournament_id
      JOIN public.tournament_formats tf
        ON tf.id = COALESCE(tr.tournament_format_id, t.tournament_format_id)
     WHERE tr.tournament_id = p_tournament_id
       AND tr.activo = true
       AND NOT (
            tf.tipo_participacion::text = 'equipo'
            AND tf.scoring_engine::text = 'team_stroke'
       );

    v_expected_round_handicap_count :=
        v_player_hcp_round_count * v_participant_count;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo = true
     ORDER BY au.id
     LIMIT 1;

    SELECT jsonb_build_object(
        'schemaVersion', 1,
        'formulaVersion', 'WHS-2024',
        'cutRulesIncluded', false,
        'cutRulesNote', 'Los cortes se deciden y aplican después de cada ronda; no se congelan aquí.',
        'tournament', to_jsonb(t),
        'categories', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'tournamentCategory', to_jsonb(tc),
                    'category', to_jsonb(c)
                ) ORDER BY c.display_order NULLS LAST, c.nombre, tc.id
            )
            FROM public.tournament_categories tc
            JOIN public.categories c ON c.id = tc.category_id
            WHERE tc.tournament_id = t.id
        ), '[]'::jsonb),
        'teeOverrides', COALESCE((
            SELECT jsonb_agg(to_jsonb(tto) ORDER BY tto.marca_salida_id)
            FROM public.tournament_tee_overrides tto
            WHERE tto.tournament_id = t.id
        ), '[]'::jsonb),
        'roundRegistrationTees', COALESCE((
            SELECT jsonb_agg(to_jsonb(rrt)
                             ORDER BY rrt.tournament_round_id, rrt.tournament_registration_id)
            FROM public.tournament_round_registration_tees rrt
            WHERE rrt.tournament_id = t.id
        ), '[]'::jsonb),
        'handicapBands', COALESCE((
            SELECT jsonb_agg(to_jsonb(fh) ORDER BY fh.id)
            FROM public.tournament_franjas_handicap fh
            WHERE fh.tournament_id = t.id
        ), '[]'::jsonb),
        'tiebreakRules', COALESCE((
            SELECT jsonb_agg(to_jsonb(tb) ORDER BY tb.id)
            FROM public.tournament_tiebreak_rules tb
            WHERE tb.tournament_id = t.id
        ), '[]'::jsonb)
    )
    INTO v_conditions
    FROM public.tournaments t
    WHERE t.id = p_tournament_id;

    INSERT INTO public.tournament_condition_freezes (
        tournament_id,
        frozen_by,
        tournament_updated_at_source,
        round_count,
        participant_count,
        conditions_snapshot,
        warnings_snapshot
    )
    SELECT t.id,
           v_admin_id,
           t.updated_at,
           v_round_count,
           v_participant_count,
           v_conditions,
           COALESCE(v_preview->'warnings', '[]'::jsonb)
    FROM public.tournaments t
    WHERE t.id = p_tournament_id
    RETURNING id INTO v_freeze_id;

    INSERT INTO public.tournament_round_condition_snapshots (
        freeze_id, tournament_id, tournament_round_id,
        round_number, round_date, course_id, course_name, course_timezone,
        tournament_format_id, format_code, format_name,
        participation_type, scoring_engine, format_source,
        handicap_allowance_pct, course_par
    )
    SELECT v_freeze_id,
           t.id,
           tr.id,
           tr.numero_ronda,
           tr.fecha,
           tr.campo_golf_id,
           cg.nombre_oficial,
           cg.timezone_id,
           tf.id,
           tf.code,
           tf.name,
           tf.tipo_participacion::text,
           tf.scoring_engine::text,
           CASE WHEN tr.tournament_format_id IS NULL THEN 'tournament' ELSE 'round' END,
           CASE
             WHEN tf.tipo_participacion::text = 'equipo'
              AND tf.scoring_engine::text = 'team_stroke'
             THEN NULL
             ELSE COALESCE(
                    tr.handicap_allowance_pct,
                    tf.handicap_allowance_default
                  )
           END,
           hp.course_par
    FROM public.tournament_rounds tr
    JOIN public.tournaments t ON t.id = tr.tournament_id
    JOIN public.tournament_formats tf
      ON tf.id = COALESCE(tr.tournament_format_id, t.tournament_format_id)
    JOIN public.campos_golf cg ON cg.id = tr.campo_golf_id
    CROSS JOIN LATERAL (
        SELECT sum(h.par)::integer AS course_par
        FROM public.hoyos h
        WHERE h.campo_golf_id = tr.campo_golf_id
    ) hp
    WHERE tr.tournament_id = p_tournament_id
      AND tr.activo = true;

    GET DIAGNOSTICS v_round_snapshot_count = ROW_COUNT;

    INSERT INTO public.tournament_round_hole_snapshots (
        freeze_id, tournament_id, round_condition_snapshot_id,
        tournament_round_id, source_hole_id,
        hole_number, par, stroke_index, tee_distances_yards
    )
    SELECT v_freeze_id,
           p_tournament_id,
           rcs.id,
           rcs.tournament_round_id,
           h.id,
           h.numero_hoyo,
           h.par,
           h.handicap_hoyo,
           COALESCE((
               SELECT jsonb_object_agg(ut.tee_id::text, dh.distancia_yardas)
               FROM (
                   SELECT DISTINCT COALESCE(rrt.tee_id, reg.marca_salida_id) AS tee_id
                   FROM public.tournament_registrations reg
                   LEFT JOIN public.tournament_round_registration_tees rrt
                     ON rrt.tournament_id = p_tournament_id
                    AND rrt.tournament_round_id = rcs.tournament_round_id
                    AND rrt.tournament_registration_id = reg.id
                   WHERE reg.tournament_id = p_tournament_id
                     AND reg.activo = true
                     AND COALESCE(rrt.tee_id, reg.marca_salida_id) IS NOT NULL
               ) ut
               LEFT JOIN public.distancias_hoyo dh
                 ON dh.hoyo_id = h.id
                AND dh.marca_salida_id = ut.tee_id
           ), '{}'::jsonb)
    FROM public.tournament_round_condition_snapshots rcs
    JOIN public.hoyos h ON h.campo_golf_id = rcs.course_id
    WHERE rcs.freeze_id = v_freeze_id;

    GET DIAGNOSTICS v_hole_snapshot_count = ROW_COUNT;

    -- Evidencia base de Handicap Index: se conserva para TODOS los jugadores,
    -- incluido A-Go-Go. Lo que deja de fabricarse para TEAM es el Playing HCP
    -- individual por ronda.
    INSERT INTO public.tournament_handicap_snapshots (
        freeze_id, tournament_id, tournament_registration_id,
        player_id, tournament_category_id, tee_id,
        registration_folio, player_name, category_name, tee_name, player_sex,
        handicap_index, handicap_source, handicap_source_date, handicap_status,
        player_updated_at_source, registration_updated_at_source
    )
    SELECT v_freeze_id,
           p_tournament_id,
           reg.id,
           p.id,
           reg.tournament_category_id,
           reg.marca_salida_id,
           reg.folio,
           trim(concat_ws(' ', p.nombres, p.apellidos)),
           c.nombre,
           ms.nombre,
           p.sexo::text,
           COALESCE(p.handicap_verificado, p.handicap_declarado),
           CASE WHEN p.handicap_verificado IS NOT NULL THEN 'verified' ELSE 'declared' END,
           CASE WHEN p.handicap_verificado IS NOT NULL
                THEN p.handicap_verificado_fecha
                ELSE p.handicap_declarado_fecha END,
           p.handicap_estatus::text,
           p.updated_at,
           reg.updated_at
    FROM public.tournament_registrations reg
    JOIN public.players p ON p.id = reg.player_id
    LEFT JOIN public.marcas_salida ms ON ms.id = reg.marca_salida_id
    LEFT JOIN public.tournament_categories tc ON tc.id = reg.tournament_category_id
    LEFT JOIN public.categories c ON c.id = tc.category_id
    WHERE reg.tournament_id = p_tournament_id
      AND reg.activo = true;

    -- Sólo rondas cuyo motor competitivo usa Playing Handicap individual.
    INSERT INTO public.tournament_round_handicap_snapshots (
        freeze_id, tournament_id, round_condition_snapshot_id,
        handicap_snapshot_id, tournament_round_id,
        tournament_registration_id, player_id, tee_id,
        course_rating, slope_rating, rating_source,
        course_par, handicap_allowance_pct,
        course_handicap_unrounded, course_handicap, playing_handicap
    )
    SELECT v_freeze_id,
           p_tournament_id,
           rcs.id,
           hs.id,
           rcs.tournament_round_id,
           hs.tournament_registration_id,
           hs.player_id,
           effective_tee.tee_id,
           calc.course_rating,
           calc.slope_rating,
           CASE
             WHEN (hs.player_sex = 'F' AND (tto.rating_damas IS NOT NULL OR tto.slope_damas IS NOT NULL))
               OR (hs.player_sex = 'M' AND (tto.rating_caballeros IS NOT NULL OR tto.slope_caballeros IS NOT NULL))
             THEN 'tournament_override'
             ELSE 'tee'
           END,
           rcs.course_par,
           rcs.handicap_allowance_pct,
           ch.value,
           public.redondear_handicap_whs(ch.value),
           public.calcular_playing_handicap(ch.value, rcs.handicap_allowance_pct)
    FROM public.tournament_round_condition_snapshots rcs
    JOIN public.tournament_handicap_snapshots hs
      ON hs.freeze_id = rcs.freeze_id
    LEFT JOIN public.tournament_round_registration_tees rrt
      ON rrt.tournament_id = p_tournament_id
     AND rrt.tournament_round_id = rcs.tournament_round_id
     AND rrt.tournament_registration_id = hs.tournament_registration_id
    CROSS JOIN LATERAL (
        SELECT COALESCE(rrt.tee_id, hs.tee_id) AS tee_id
    ) effective_tee
    JOIN public.marcas_salida ms ON ms.id = effective_tee.tee_id
    LEFT JOIN public.tournament_tee_overrides tto
      ON tto.tournament_id = p_tournament_id
     AND tto.marca_salida_id = effective_tee.tee_id
    CROSS JOIN LATERAL (
        SELECT CASE hs.player_sex
                 WHEN 'F' THEN COALESCE(tto.rating_damas, ms.rating_damas)
                 ELSE COALESCE(tto.rating_caballeros, ms.rating_caballeros)
               END::numeric AS course_rating,
               CASE hs.player_sex
                 WHEN 'F' THEN COALESCE(tto.slope_damas, ms.slope_damas)
                 ELSE COALESCE(tto.slope_caballeros, ms.slope_caballeros)
               END::integer AS slope_rating
    ) calc
    CROSS JOIN LATERAL (
        SELECT public.calcular_course_handicap_sin_redondear(
            hs.handicap_index,
            calc.slope_rating,
            calc.course_rating,
            rcs.course_par
        ) AS value
    ) ch
    WHERE rcs.freeze_id = v_freeze_id
      AND NOT (
          rcs.participation_type = 'equipo'
          AND rcs.scoring_engine = 'team_stroke'
      );

    GET DIAGNOSTICS v_round_handicap_count = ROW_COUNT;

    IF v_round_snapshot_count <> v_round_count
       OR v_hole_snapshot_count <> v_round_count * 18
       OR v_round_handicap_count <> v_expected_round_handicap_count THEN
        RAISE EXCEPTION 'El congelamiento quedó incompleto y fue revertido automáticamente.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'rondas=%s/%s, hoyos=%s/%s, handicaps_ronda_individuales=%s/%s',
                      v_round_snapshot_count, v_round_count,
                      v_hole_snapshot_count, v_round_count * 18,
                      v_round_handicap_count, v_expected_round_handicap_count
                  );
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'freezeId', v_freeze_id,
        'tournamentId', p_tournament_id,
        'frozenAt', now(),
        'counts', jsonb_build_object(
            'rounds', v_round_snapshot_count,
            'participants', v_participant_count,
            'holes', v_hole_snapshot_count,
            'roundsRequiringIndividualPlayingHandicap', v_player_hcp_round_count,
            'roundPlayerHandicaps', v_round_handicap_count
        ),
        'warnings', COALESCE(v_preview->'warnings', '[]'::jsonb)
    );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. RPC pública de congelamiento.
--    Conserva exactamente las extensiones actuales de clasificación y
--    Stableford; sólo cambia el core base a 218.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.congelar_condiciones_y_handicaps_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_result jsonb;
    v_freeze_id uuid;
    v_category_count integer;
    v_snapshot_category_count integer;
    v_category_snapshot_rows integer;
    v_special_rule_snapshot_rows integer;
    v_engine_snapshot_rows integer;
BEGIN
    v_result :=
        public._congelar_condiciones_y_handicaps_torneo_core_218(
            p_tournament_id
        );

    v_freeze_id := NULLIF(v_result->>'freezeId','')::uuid;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION 'El congelamiento base no devolvió freezeId.'
            USING ERRCODE='55000';
    END IF;

    SELECT count(*)
      INTO v_category_count
      FROM public.tournament_categories
     WHERE tournament_id=p_tournament_id;

    INSERT INTO public.tournament_category_classification_snapshots(
        freeze_id,tournament_id,source_classification_id,
        tournament_category_id,category_id,category_code,
        category_name,category_display_order,tipo_resultado
    )
    SELECT
        v_freeze_id,tc.tournament_id,cc.id,tc.id,c.id,c.codigo,
        c.nombre,c.display_order,cc.tipo_resultado
    FROM public.tournament_categories tc
    JOIN public.categories c
      ON c.id=tc.category_id
    JOIN public.tournament_category_classifications cc
      ON cc.tournament_category_id=tc.id
     AND cc.tournament_id=tc.tournament_id
    WHERE tc.tournament_id=p_tournament_id
    ON CONFLICT (freeze_id,tournament_category_id,tipo_resultado)
    DO NOTHING;

    GET DIAGNOSTICS v_category_snapshot_rows=ROW_COUNT;

    SELECT count(DISTINCT tournament_category_id)
      INTO v_snapshot_category_count
      FROM public.tournament_category_classification_snapshots
     WHERE freeze_id=v_freeze_id;

    IF v_snapshot_category_count <> v_category_count THEN
        RAISE EXCEPTION
            'El snapshot de clasificaciones por categoría quedó incompleto y el congelamiento fue revertido.'
            USING ERRCODE='55000',
                  DETAIL=format(
                      'categorias_snapshot=%s/%s',
                      v_snapshot_category_count,
                      v_category_count
                  );
    END IF;

    INSERT INTO public.tournament_stableford_special_rule_snapshots(
        freeze_id,tournament_id,source_rule_id,
        rule_code,enabled,points,behavior
    )
    SELECT
        v_freeze_id,r.tournament_id,r.id,
        r.rule_code,r.enabled,r.points,r.behavior
    FROM public.tournament_stableford_special_rules r
    WHERE r.tournament_id=p_tournament_id
    ON CONFLICT (freeze_id,rule_code)
    DO NOTHING;

    GET DIAGNOSTICS v_special_rule_snapshot_rows=ROW_COUNT;

    INSERT INTO public.tournament_stableford_engine_snapshots(
        freeze_id,
        tournament_id,
        tournament_round_id,
        round_condition_snapshot_id,
        engine_version,
        points_table_version,
        target_score_basis,
        minimum_points,
        maximum_points,
        pickup_points
    )
    SELECT
        v_freeze_id,
        rcs.tournament_id,
        rcs.tournament_round_id,
        rcs.id,
        'stableford_individual_v1',
        'R21.1_STANDARD_V1',
        'PAR',
        0,
        6,
        0
    FROM public.tournament_round_condition_snapshots rcs
    WHERE rcs.freeze_id=v_freeze_id
      AND rcs.scoring_engine='stableford'
      AND rcs.participation_type='individual'
    ON CONFLICT (freeze_id,tournament_round_id)
    DO NOTHING;

    GET DIAGNOSTICS v_engine_snapshot_rows=ROW_COUNT;

    RETURN v_result || jsonb_build_object(
        'categoryClassificationSnapshots',
            v_category_snapshot_rows,
        'stablefordSpecialRuleSnapshots',
            v_special_rule_snapshot_rows,
        'stablefordEngineSnapshots',
            v_engine_snapshot_rows
    );
END;
$function$;

COMMIT;
