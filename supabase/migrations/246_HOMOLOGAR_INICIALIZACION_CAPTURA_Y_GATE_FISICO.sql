-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 246 — Homologar inicialización de captura y blindar captura física
-- ============================================================================
-- Objetivo:
--   1) Homologar A-Go-Go TEAM con Stroke Play / Stableford individual:
--      emitir tarjetas => inicializar estructura digital en la misma transacción.
--   2) Mantener idempotencia: re-ejecutar emisión TEAM con tarjetas ya emitidas
--      también completa una inicialización faltante sin duplicar tarjetas.
--   3) Convertir la existencia íntegra de la estructura digital en prerrequisito
--      común para cualquier captura física.
--   4) Extender el Asistente Operativo para diagnosticar la inicialización en
--      todas las modalidades soportadas, no sólo TEAM.
--
-- IMPORTANTE:
--   - NO inicializa automáticamente rondas históricas ya emitidas al aplicar
--     la migración. La reparación/continuación de esas rondas se ejecuta luego
--     mediante el flujo normal inicializar_captura_scores_ronda(uuid).
--   - NO modifica scores, resultados, freezes, grupos ni salidas existentes.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Estado común de estructura digital por ronda.
--    Para TEAM reutiliza el diagnóstico estricto de la 245 (incluye markers).
--    Para PLAYER valida sesiones + cantidad exacta de hoyos por tarjeta.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._estado_inicializacion_captura_ronda_246(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emission_id uuid;
    v_unit_type text;
    v_scoring_engine text;
    v_team_state jsonb;
    v_card_count integer := 0;
    v_session_count integer := 0;
    v_cards_without_session integer := 0;
    v_bad_hole_count integer := 0;
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

    SELECT e.id, sc.unit_type, v.scoring_engine
      INTO v_emission_id, v_unit_type, v_scoring_engine
      FROM public.tournament_score_card_emissions e
      JOIN public.tournament_round_start_validations v
        ON v.id=e.validation_id
       AND v.tournament_round_id=e.tournament_round_id
      JOIN public.tournament_score_cards sc
        ON sc.emission_id=e.id
       AND sc.status='issued'
     WHERE e.tournament_round_id=p_tournament_round_id
       AND e.status='issued'
     ORDER BY e.issued_at DESC, e.id DESC, sc.card_number NULLS LAST, sc.id
     LIMIT 1;

    IF v_emission_id IS NULL THEN
        RETURN jsonb_build_object(
            'applicable', false,
            'state', 'NO_ACTIVE_EMISSION',
            'status', 'NOT_APPLICABLE',
            'tournamentRoundId', p_tournament_round_id
        );
    END IF;

    -- TEAM/team_stroke conserva el contrato estricto de la 245, incluyendo marker.
    IF v_unit_type='team' AND v_scoring_engine='team_stroke' THEN
        v_team_state := public._estado_inicializacion_captura_team_ronda_245(
            p_tournament_round_id
        );
        RETURN v_team_state || jsonb_build_object(
            'source', 'TEAM_245',
            'commonContract', true
        );
    END IF;

    SELECT count(*)::integer
      INTO v_card_count
      FROM public.tournament_score_cards sc
     WHERE sc.emission_id=v_emission_id
       AND sc.status='issued';

    SELECT
        count(cs.id)::integer,
        count(*) FILTER (WHERE cs.id IS NULL)::integer,
        COALESCE(sum(CASE WHEN cs.id IS NOT NULL THEN cs.holes_expected ELSE 0 END),0)::integer
      INTO v_session_count, v_cards_without_session, v_expected_hole_rows
      FROM public.tournament_score_cards sc
      LEFT JOIN public.tournament_scorecard_capture_sessions cs
        ON cs.score_card_id=sc.id
     WHERE sc.emission_id=v_emission_id
       AND sc.status='issued';

    SELECT count(*)::integer
      INTO v_hole_rows
      FROM public.tournament_scorecard_hole_scores hs
      JOIN public.tournament_score_cards sc
        ON sc.id=hs.score_card_id
     WHERE sc.emission_id=v_emission_id
       AND sc.status='issued';

    SELECT count(*)::integer
      INTO v_bad_hole_count
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
       AND (
           cs.holes_expected IS NULL
           OR cs.holes_expected<=0
           OR COALESCE(x.n,0)<>cs.holes_expected
       );

    IF v_card_count>0
       AND v_session_count=0
       AND v_hole_rows=0
    THEN
        v_state := 'NOT_INITIALIZED';
        v_status := 'PENDING';
        v_message := 'Las tarjetas oficiales ya fueron emitidas, pero la estructura digital todavía no está inicializada.';
        v_recommendation := 'Inicializa la captura antes de continuar con captura física o conciliación.';

    ELSIF v_card_count>0
       AND v_session_count=v_card_count
       AND v_cards_without_session=0
       AND v_bad_hole_count=0
       AND v_hole_rows=v_expected_hole_rows
    THEN
        v_state := 'READY';
        v_status := 'READY';
        v_message := 'La estructura digital de captura está inicializada.';
        v_recommendation := NULL;

    ELSE
        v_state := 'PARTIAL_OR_INCONSISTENT';
        v_status := 'BLOCKED';
        v_message := 'La estructura digital de captura está parcial o inconsistente.';
        v_recommendation := 'Corrige la inicialización antes de continuar con captura física o conciliación.';
    END IF;

    RETURN jsonb_build_object(
        'applicable', true,
        'commonContract', true,
        'state', v_state,
        'status', v_status,
        'message', v_message,
        'recommendation', v_recommendation,
        'tournamentRoundId', p_tournament_round_id,
        'emissionId', v_emission_id,
        'unitType', v_unit_type,
        'scoringEngine', v_scoring_engine,
        'cardCount', v_card_count,
        'sessionCount', v_session_count,
        'cardsWithoutSession', v_cards_without_session,
        'holeScoreRows', v_hole_rows,
        'expectedHoleScoreRows', v_expected_hole_rows,
        'cardsWithInvalidHoleCount', v_bad_hole_count
    );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 2. Wrapper TEAM homologado: emisión + inicialización en la misma transacción.
--    La función 208 conserva toda la lógica de emisión; esta capa sólo añade
--    el mismo post-paso que ya usa la emisión individual.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._emitir_tarjetas_equipo_a_gogo_ronda_246(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emission_state jsonb;
BEGIN
    v_emission_state := public._emitir_tarjetas_equipo_a_gogo_ronda_208(
        p_tournament_round_id
    );

    -- Si la inicialización falla, toda la transacción de emisión revierte.
    PERFORM public.inicializar_captura_scores_ronda(
        p_tournament_round_id
    );

    RETURN public.obtener_estado_emision_tarjetas_ronda(
        p_tournament_round_id
    );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 3. Dispatcher público: TEAM usa la capa 246; individual queda intacto.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.emitir_tarjetas_score_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_capability jsonb;
BEGIN
    v_capability := public._resolver_capacidad_emision_tarjetas_ronda(
        p_tournament_round_id
    );

    IF COALESCE((v_capability->>'supported')::boolean,false)
       AND v_capability->>'unitType'='team'
    THEN
        RETURN public._emitir_tarjetas_equipo_a_gogo_ronda_246(
            p_tournament_round_id
        );
    END IF;

    RETURN public._emitir_tarjetas_score_ronda_individual_208(
        p_tournament_round_id
    );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. Guard común para captura física.
--    No confunde "estructura inicializada" con "captura digital real": NRQ
--    sigue siendo posible si la sesión existe pero nunca fue usada.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exigir_estructura_captura_inicializada_246(
    p_score_card_id uuid
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_round_id uuid;
    v_state jsonb;
BEGIN
    SELECT sc.tournament_round_id
      INTO v_round_id
      FROM public.tournament_score_cards sc
     WHERE sc.id=p_score_card_id
       AND sc.status='issued'
     LIMIT 1;

    IF v_round_id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta oficial indicada no existe o no está emitida.'
            USING ERRCODE='22023';
    END IF;

    v_state := public._estado_inicializacion_captura_ronda_246(v_round_id);

    IF NOT COALESCE((v_state->>'applicable')::boolean,false)
       OR v_state->>'state' IS DISTINCT FROM 'READY'
    THEN
        RAISE EXCEPTION
            'La captura física no está disponible hasta completar la inicialización digital de la ronda.'
            USING ERRCODE='55000',
                  DETAIL=v_state::text,
                  HINT='Inicialice primero la captura digital de la ronda.';
    END IF;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. Punto común de entrada de captura física: añade el guard sin duplicarlo
--    en cada RPC de recibir/guardar/finalizar.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._obtener_score_card_para_captura_fisica(
    p_score_card_id uuid
)
RETURNS public.tournament_score_cards
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_card public.tournament_score_cards;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_score_card_id IS NULL THEN
        RAISE EXCEPTION 'score_card_id es obligatorio.' USING ERRCODE='22023';
    END IF;

    SELECT *
      INTO v_card
      FROM public.tournament_score_cards
     WHERE id=p_score_card_id
       AND status='issued'
     LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta oficial indicada no existe o no está emitida.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_card.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para capturar esta tarjeta física.'
            USING ERRCODE='42501';
    END IF;

    PERFORM public._exigir_estructura_captura_inicializada_246(v_card.id);

    RETURN v_card;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 6. Asistente v9: contrato común de inicialización para ROUND_SCORING.
--    v8 conserva HCP TEAM/grupos y la UX específica TEAM; v9 generaliza el
--    diagnóstico para cualquier modalidad soportada.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._obtener_asistente_operativo_torneo_v9_246(
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
    v_state text;
    v_actionable boolean;
BEGIN
    v_result := public._obtener_asistente_operativo_torneo_v8_245(
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
            v_init := public._estado_inicializacion_captura_ronda_246(
                v_round_id::uuid
            );

            IF COALESCE((v_init->>'applicable')::boolean,false) THEN
                v_state := v_init->>'state';
                v_actionable := COALESCE(
                    (v_elem #>> '{availability,actionable}')::boolean,
                    false
                );

                v_elem := jsonb_set(
                    v_elem,
                    '{details}',
                    COALESCE(v_elem->'details','{}'::jsonb)
                    || jsonb_build_object('captureInitializationCommon',v_init),
                    true
                );

                IF v_state='NOT_INITIALIZED' THEN
                    v_elem := v_elem || jsonb_build_object(
                        'status','PENDING',
                        'message',v_init->>'message',
                        'recommendation',v_init->>'recommendation',
                        'action', CASE WHEN v_actionable THEN jsonb_build_object(
                            'label','Iniciar captura',
                            'target','captura-resultados',
                            'roundId',v_round_id,
                            'operation','initialize_capture',
                            'rpc','inicializar_captura_scores_ronda'
                        ) ELSE NULL END
                    );

                ELSIF v_state='PARTIAL_OR_INCONSISTENT' THEN
                    v_elem := v_elem || jsonb_build_object(
                        'status','BLOCKED',
                        'message',v_init->>'message',
                        'recommendation',v_init->>'recommendation',
                        'action', CASE WHEN v_actionable THEN jsonb_build_object(
                            'label','Revisar inicialización',
                            'target','captura-resultados',
                            'roundId',v_round_id,
                            'operation','review_capture_initialization'
                        ) ELSE NULL END
                    );
                END IF;
            END IF;
        END IF;

        v_final_steps := v_final_steps || jsonb_build_array(v_elem);
    END LOOP;

    SELECT COALESCE(jsonb_agg(s.elem ORDER BY s.ord),'[]'::jsonb)
      INTO v_blockers
      FROM jsonb_array_elements(v_final_steps)
           WITH ORDINALITY AS s(elem,ord)
     WHERE s.elem->>'status'='BLOCKED'
       AND COALESCE((s.elem #>> '{availability,actionable}')::boolean,false);

    SELECT s.elem->'action'
      INTO v_next_action
      FROM jsonb_array_elements(v_final_steps)
           WITH ORDINALITY AS s(elem,ord)
     WHERE s.elem->>'status' IN ('BLOCKED','PENDING')
       AND COALESCE((s.elem #>> '{availability,actionable}')::boolean,false)
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

    RETURN v_result || jsonb_build_object('schemaVersion',9);
END;
$function$;

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
    RETURN public._obtener_asistente_operativo_torneo_v9_246(
        p_tournament_id
    );
END;
$function$;

-- Seguridad de helpers internos.
REVOKE ALL ON FUNCTION public._estado_inicializacion_captura_ronda_246(uuid)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public._emitir_tarjetas_equipo_a_gogo_ronda_246(uuid)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public._exigir_estructura_captura_inicializada_246(uuid)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public._obtener_asistente_operativo_torneo_v9_246(uuid)
FROM PUBLIC, anon, authenticated;

-- Contratos públicos existentes.
GRANT EXECUTE ON FUNCTION public.emitir_tarjetas_score_ronda(uuid)
TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
TO authenticated, service_role;

COMMIT;
