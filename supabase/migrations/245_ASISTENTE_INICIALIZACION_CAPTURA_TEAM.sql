-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 245 — Asistente: inicialización explícita de captura A-Go-Go TEAM
-- ============================================================================
-- Objetivo:
--   1) Distinguir, en ROUND_SCORING, entre tarjetas TEAM emitidas y captura
--      realmente inicializada.
--   2) Cuando no existen sesiones, indicar explícitamente "Iniciar captura".
--   3) Si la inicialización quedó parcial/inconsistente, bloquear el paso y
--      mostrar diagnóstico en lugar de fingir que está listo.
--   4) Preservar sin cambios Stroke Play, Stableford y cualquier rama no TEAM.
--
-- IMPORTANTE:
--   - Esta migración NO inicializa capturas.
--   - NO modifica tarjetas, scores, grupos, salidas ni resultados.
--   - La inicialización real sigue siendo responsabilidad de:
--         public.inicializar_captura_scores_ronda(uuid)
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Estado canónico de inicialización de captura para una ronda TEAM.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._estado_inicializacion_captura_team_ronda_245(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_emission_id uuid;
    v_validation_id uuid;
    v_participation_type text;
    v_scoring_engine text;

    v_card_count integer := 0;
    v_session_count integer := 0;
    v_cards_without_session integer := 0;
    v_cards_bad_holes integer := 0;
    v_cards_without_marker integer := 0;
    v_hole_rows integer := 0;
    v_expected_hole_rows integer := 0;

    v_state text;
    v_status text;
    v_message text;
    v_recommendation text;
BEGIN
    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    SELECT tr.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    SELECT
        e.id,
        e.validation_id,
        v.participation_type,
        v.scoring_engine
      INTO
        v_emission_id,
        v_validation_id,
        v_participation_type,
        v_scoring_engine
      FROM public.tournament_score_card_emissions e
      JOIN public.tournament_round_start_validations v
        ON v.id=e.validation_id
       AND v.tournament_round_id=e.tournament_round_id
     WHERE e.tournament_round_id=p_tournament_round_id
       AND e.status='issued'
     ORDER BY e.issued_at DESC, e.id DESC
     LIMIT 1;

    -- Esta migración sólo interviene en A-Go-Go/team_stroke por equipo.
    IF v_emission_id IS NULL
       OR v_participation_type IS DISTINCT FROM 'equipo'
       OR v_scoring_engine IS DISTINCT FROM 'team_stroke'
    THEN
        RETURN jsonb_build_object(
            'applicable', false,
            'state', CASE WHEN v_emission_id IS NULL THEN 'NO_ACTIVE_EMISSION' ELSE 'NOT_TEAM_STROKE' END,
            'status', 'NOT_APPLICABLE',
            'tournamentRoundId', p_tournament_round_id,
            'emissionId', v_emission_id
        );
    END IF;

    SELECT count(*)::integer
      INTO v_card_count
      FROM public.tournament_score_cards sc
     WHERE sc.emission_id=v_emission_id
       AND sc.status='issued'
       AND sc.unit_type='team';

    SELECT
        count(cs.id)::integer,
        count(*) FILTER (WHERE cs.id IS NULL)::integer,
        COALESCE(sum(CASE WHEN cs.id IS NOT NULL THEN cs.holes_expected ELSE 0 END),0)::integer
      INTO
        v_session_count,
        v_cards_without_session,
        v_expected_hole_rows
      FROM public.tournament_score_cards sc
      LEFT JOIN public.tournament_scorecard_capture_sessions cs
        ON cs.score_card_id=sc.id
     WHERE sc.emission_id=v_emission_id
       AND sc.status='issued'
       AND sc.unit_type='team';

    SELECT count(*)::integer
      INTO v_hole_rows
      FROM public.tournament_scorecard_hole_scores hs
      JOIN public.tournament_score_cards sc
        ON sc.id=hs.score_card_id
     WHERE sc.emission_id=v_emission_id
       AND sc.status='issued'
       AND sc.unit_type='team';

    SELECT count(*)::integer
      INTO v_cards_bad_holes
      FROM public.tournament_score_cards sc
      JOIN public.tournament_scorecard_capture_sessions cs
        ON cs.score_card_id=sc.id
      LEFT JOIN LATERAL (
          SELECT count(*)::integer AS n
          FROM public.tournament_scorecard_hole_scores hs
          WHERE hs.score_card_id=sc.id
      ) x ON true
     WHERE sc.emission_id=v_emission_id
       AND sc.status='issued'
       AND sc.unit_type='team'
       AND (
           cs.holes_expected IS NULL
           OR cs.holes_expected<=0
           OR COALESCE(x.n,0)<>cs.holes_expected
       );

    SELECT count(*)::integer
      INTO v_cards_without_marker
      FROM public.tournament_score_cards sc
     WHERE sc.emission_id=v_emission_id
       AND sc.status='issued'
       AND sc.unit_type='team'
       AND NOT EXISTS (
           SELECT 1
           FROM public.tournament_scorecard_marker_assignments ma
           WHERE ma.score_card_id=sc.id
             AND ma.status='active'
       );

    IF v_card_count>0
       AND v_session_count=0
       AND v_hole_rows=0
       AND v_cards_without_marker=v_card_count
    THEN
        v_state := 'NOT_INITIALIZED';
        v_status := 'PENDING';
        v_message := 'Las tarjetas TEAM ya fueron emitidas, pero la captura digital todavía no está inicializada.';
        v_recommendation := 'Inicializa la captura antes de revisar scores, captura física o conciliaciones.';

    ELSIF v_card_count>0
       AND v_session_count=v_card_count
       AND v_cards_without_session=0
       AND v_cards_bad_holes=0
       AND v_hole_rows=v_expected_hole_rows
       AND v_cards_without_marker=0
    THEN
        v_state := 'READY';
        v_status := 'READY';
        v_message := 'La captura digital TEAM está inicializada.';
        v_recommendation := NULL;

    ELSE
        v_state := 'PARTIAL_OR_INCONSISTENT';
        v_status := 'BLOCKED';
        v_message := 'La inicialización de captura TEAM está parcial o inconsistente.';
        v_recommendation := 'Revisa la inicialización antes de continuar; no captures scores hasta corregir la inconsistencia.';
    END IF;

    RETURN jsonb_build_object(
        'applicable', true,
        'state', v_state,
        'status', v_status,
        'message', v_message,
        'recommendation', v_recommendation,
        'tournamentRoundId', p_tournament_round_id,
        'emissionId', v_emission_id,
        'validationId', v_validation_id,
        'cardCount', v_card_count,
        'sessionCount', v_session_count,
        'cardsWithoutSession', v_cards_without_session,
        'holeScoreRows', v_hole_rows,
        'expectedHoleScoreRows', v_expected_hole_rows,
        'cardsWithInvalidHoleCount', v_cards_bad_holes,
        'cardsWithoutMarker', v_cards_without_marker
    );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 2. Asistente v8: refina exclusivamente ROUND_SCORING para TEAM/team_stroke.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._obtener_asistente_operativo_torneo_v8_245(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_result jsonb;
    v_source_steps jsonb := '[]'::jsonb;
    v_final_steps jsonb := '[]'::jsonb;
    v_blockers jsonb := '[]'::jsonb;
    v_next_action jsonb := NULL;

    v_elem jsonb;
    v_round_id text;
    v_init jsonb;
    v_init_state text;
    v_actionable boolean;
BEGIN
    -- Conserva íntegramente HCP TEAM, grupos, salidas y demás gates de v7_244.
    v_result := public._obtener_asistente_operativo_torneo_v7_244(
        p_tournament_id
    );

    v_source_steps := COALESCE(v_result->'steps','[]'::jsonb);

    FOR v_elem IN
        SELECT elem FROM jsonb_array_elements(v_source_steps) elem
    LOOP
        IF v_elem->>'code'='ROUND_SCORING'
           AND v_elem ? 'roundId'
        THEN
            v_round_id := v_elem->>'roundId';
            v_init := public._estado_inicializacion_captura_team_ronda_245(
                v_round_id::uuid
            );

            IF COALESCE((v_init->>'applicable')::boolean,false) THEN
                v_init_state := v_init->>'state';
                v_actionable := COALESCE(
                    (v_elem #>> '{availability,actionable}')::boolean,
                    false
                );

                -- Exponer siempre el diagnóstico de inicialización dentro del
                -- mismo paso, sin perder el estado de conciliación heredado.
                v_elem := jsonb_set(
                    v_elem,
                    '{details}',
                    COALESCE(v_elem->'details','{}'::jsonb)
                    || jsonb_build_object('captureInitialization',v_init),
                    true
                );

                IF v_init_state='NOT_INITIALIZED' THEN
                    v_elem := v_elem || jsonb_build_object(
                        'status','PENDING',
                        'message',v_init->>'message',
                        'recommendation',v_init->>'recommendation',
                        'action',
                            CASE WHEN v_actionable THEN jsonb_build_object(
                                'label','Iniciar captura',
                                'target','captura-resultados',
                                'roundId',v_round_id,
                                'operation','initialize_capture',
                                'rpc','inicializar_captura_scores_ronda'
                            ) ELSE NULL END
                    );

                ELSIF v_init_state='PARTIAL_OR_INCONSISTENT' THEN
                    v_elem := v_elem || jsonb_build_object(
                        'status','BLOCKED',
                        'message',v_init->>'message',
                        'recommendation',v_init->>'recommendation',
                        'action',
                            CASE WHEN v_actionable THEN jsonb_build_object(
                                'label','Revisar inicialización',
                                'target','captura-resultados',
                                'roundId',v_round_id,
                                'operation','review_capture_initialization'
                            ) ELSE NULL END
                    );

                -- READY conserva exactamente el estado/mensaje/recomendación
                -- de captura física/conciliación calculado por el core.
                END IF;
            END IF;
        END IF;

        v_final_steps := v_final_steps || jsonb_build_array(v_elem);
    END LOOP;

    -- Recalcular blockers/nextAction porque ROUND_SCORING pudo cambiar.
    SELECT COALESCE(jsonb_agg(s.elem ORDER BY s.ord),'[]'::jsonb)
      INTO v_blockers
      FROM jsonb_array_elements(v_final_steps)
           WITH ORDINALITY AS s(elem,ord)
     WHERE s.elem->>'status'='BLOCKED'
       AND COALESCE(
           (s.elem #>> '{availability,actionable}')::boolean,
           false
       );

    SELECT s.elem->'action'
      INTO v_next_action
      FROM jsonb_array_elements(v_final_steps)
           WITH ORDINALITY AS s(elem,ord)
     WHERE s.elem->>'status' IN ('BLOCKED','PENDING')
       AND COALESCE(
           (s.elem #>> '{availability,actionable}')::boolean,
           false
       )
       AND s.elem->'action' IS NOT NULL
       AND s.elem->'action'<>'null'::jsonb
     ORDER BY s.ord
     LIMIT 1;

    v_result := jsonb_set(v_result,'{steps}',v_final_steps,true);
    v_result := jsonb_set(v_result,'{blockers}',v_blockers,true);
    v_result := jsonb_set(
        v_result,
        '{summary,blockingIssues}',
        to_jsonb(jsonb_array_length(v_blockers)),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{nextAction}',
        COALESCE(v_next_action,'null'::jsonb),
        true
    );

    RETURN v_result || jsonb_build_object('schemaVersion',8);
END;
$function$;

-- ----------------------------------------------------------------------------
-- 3. El RPC público pasa a v8_245.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_asistente_operativo_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RETURN public._obtener_asistente_operativo_torneo_v8_245(
        p_tournament_id
    );
END;
$function$;

-- Seguridad: helpers internos no se exponen a anon/authenticated.
REVOKE ALL ON FUNCTION public._estado_inicializacion_captura_team_ronda_245(uuid)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public._obtener_asistente_operativo_torneo_v8_245(uuid)
FROM PUBLIC, anon, authenticated;

-- El RPC público conserva su contrato de ejecución existente.
GRANT EXECUTE ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
TO authenticated, service_role;

COMMIT;
