-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 256
-- INICIO FORMAL DEL TORNEO COMO FRONTERA COMPETITIVA
-- ============================================================================
-- OBJETIVOS
-- 1) Mantener iniciar_torneo() como transición formal a EN CURSO.
-- 2) Permitir preparación previa: congelar, armar grupos, validar salidas,
--    emitir tarjetas e inicializar captura.
-- 3) Bloquear escrituras competitivas antes de EN CURSO:
--      - SCORE/PICKUP digital;
--      - recepción/captura física;
--      - conciliación.
-- 4) Incorporar INICIAR TORNEO como paso explícito del Asistente.
--
-- Ejecutar manualmente en Supabase.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Estado de preparación para INICIAR TORNEO.
--    Replica las precondiciones operativas de iniciar_torneo() sin escribir.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_estado_inicio_torneo_256(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
    v_round_id uuid;
    v_round_number integer;
    v_frozen boolean := false;
    v_starts_validated boolean := false;
    v_cards_issued boolean := false;
    v_cards integer := 0;
    v_sessions integer := 0;
    v_capture_ready boolean := false;
    v_errors jsonb := '[]'::jsonb;
    v_ready boolean := false;
BEGIN
    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF v_t.estatus IN (
        'en_curso'::public.estatus_torneo,
        'finalizado'::public.estatus_torneo
    ) THEN
        RETURN jsonb_build_object(
            'tournamentId', p_tournament_id,
            'status', v_t.estatus::text,
            'alreadyStarted', true,
            'readyToStart', false,
            'errors', '[]'::jsonb
        );
    END IF;

    v_frozen := EXISTS (
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = p_tournament_id
    );

    SELECT tr.id, tr.numero_ronda
      INTO v_round_id, v_round_number
      FROM public.tournament_rounds tr
     WHERE tr.tournament_id = p_tournament_id
       AND tr.activo = true
     ORDER BY tr.numero_ronda ASC, tr.fecha ASC, tr.id ASC
     LIMIT 1;

    IF v_round_id IS NOT NULL THEN
        v_starts_validated := public._salida_ronda_esta_validada(v_round_id);
        v_cards_issued := public._ronda_tiene_tarjetas_emitidas(v_round_id);

        SELECT count(*)
          INTO v_cards
          FROM public.tournament_score_cards sc
         WHERE sc.tournament_round_id = v_round_id
           AND sc.status = 'issued';

        SELECT count(*)
          INTO v_sessions
          FROM public.tournament_scorecard_capture_sessions cs
          JOIN public.tournament_score_cards sc
            ON sc.id = cs.score_card_id
         WHERE sc.tournament_round_id = v_round_id
           AND sc.status = 'issued';

        v_capture_ready := (v_cards > 0 AND v_sessions = v_cards);
    END IF;

    IF v_t.estatus <> 'inscripcion_cerrada'::public.estatus_torneo THEN
        v_errors := v_errors || jsonb_build_array(
            format(
                'El torneo sólo puede iniciarse desde INSCRIPCIÓN CERRADA. Estado actual: %s.',
                v_t.estatus
            )
        );
    END IF;

    IF NOT v_frozen THEN
        v_errors := v_errors || jsonb_build_array(
            'Primero deben congelarse las condiciones y hándicaps.'
        );
    END IF;

    IF v_round_id IS NULL THEN
        v_errors := v_errors || jsonb_build_array(
            'No existe una primera ronda activa.'
        );
    ELSE
        IF NOT v_starts_validated THEN
            v_errors := v_errors || jsonb_build_array(
                'Las salidas de la primera ronda aún no están validadas.'
            );
        END IF;

        IF NOT v_cards_issued THEN
            v_errors := v_errors || jsonb_build_array(
                'La primera ronda no tiene tarjetas oficiales emitidas.'
            );
        END IF;

        IF NOT v_capture_ready THEN
            v_errors := v_errors || jsonb_build_array(
                'La captura digital de la primera ronda no está completamente inicializada.'
            );
        END IF;
    END IF;

    v_ready := jsonb_array_length(v_errors) = 0;

    RETURN jsonb_build_object(
        'tournamentId', p_tournament_id,
        'status', v_t.estatus::text,
        'alreadyStarted', false,
        'readyToStart', v_ready,
        'firstRoundId', v_round_id,
        'firstRoundNumber', v_round_number,
        'conditionsFrozen', v_frozen,
        'startsValidated', v_starts_validated,
        'cardsIssued', v_cards_issued,
        'issuedCards', v_cards,
        'captureSessions', v_sessions,
        'captureReady', v_capture_ready,
        'errors', v_errors
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_estado_inicio_torneo_256(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.obtener_estado_inicio_torneo_256(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_estado_inicio_torneo_256(uuid)
TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 2. Helper común: exige que la tarjeta pertenezca a un torneo EN CURSO.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exigir_torneo_en_curso_scorecard_256(
    p_score_card_id uuid,
    p_contexto text DEFAULT 'operación competitiva'
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_status public.estatus_torneo;
BEGIN
    SELECT sc.tournament_id, t.estatus
      INTO v_tournament_id, v_status
      FROM public.tournament_score_cards sc
      JOIN public.tournaments t
        ON t.id = sc.tournament_id
     WHERE sc.id = p_score_card_id
     LIMIT 1;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF v_status <> 'en_curso'::public.estatus_torneo THEN
        RAISE EXCEPTION
            'No se puede realizar % antes de INICIAR TORNEO. Estado actual: %.',
            COALESCE(NULLIF(btrim(p_contexto), ''), 'esta operación competitiva'),
            v_status
            USING ERRCODE = '23514',
                  HINT = 'Completa la preparación de la primera ronda y ejecuta INICIAR TORNEO.';
    END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public._exigir_torneo_en_curso_scorecard_256(uuid,text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exigir_torneo_en_curso_scorecard_256(uuid,text)
TO service_role;


-- ----------------------------------------------------------------------------
-- 3. Barrera digital común.
--
-- Se permiten filas PENDING antes del inicio porque forman parte de la
-- inicialización. Cuando una fila contiene ya SCORE/PICKUP, es competencia.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._bloquear_score_competitivo_antes_inicio_256()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF COALESCE(NEW.result_type, 'PENDING') <> 'PENDING' THEN
            PERFORM public._exigir_torneo_en_curso_scorecard_256(
                NEW.score_card_id,
                'captura digital de score'
            );
        END IF;
        RETURN NEW;
    END IF;

    -- UPDATE:
    -- mientras siga PENDING se permite la preparación técnica de la fila.
    -- Cualquier SCORE/PICKUP nuevo o modificado exige torneo EN CURSO.
    IF COALESCE(NEW.result_type, 'PENDING') <> 'PENDING' THEN
        IF OLD.result_type IS DISTINCT FROM NEW.result_type
           OR OLD.gross_score IS DISTINCT FROM NEW.gross_score
        THEN
            PERFORM public._exigir_torneo_en_curso_scorecard_256(
                NEW.score_card_id,
                'captura digital de score'
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_inicio_torneo_score_competitivo_256
ON public.tournament_scorecard_hole_scores;

CREATE TRIGGER trg_inicio_torneo_score_competitivo_256
BEFORE INSERT OR UPDATE OF result_type, gross_score
ON public.tournament_scorecard_hole_scores
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_score_competitivo_antes_inicio_256();


-- ----------------------------------------------------------------------------
-- 4. Barrera física.
--    Toda recepción/captura física pertenece a la fase competitiva/post-juego
--    y exige que el torneo ya esté EN CURSO.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._bloquear_fisico_antes_inicio_256()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_score_card_id uuid;
BEGIN
    v_score_card_id := CASE
        WHEN TG_OP = 'DELETE' THEN OLD.score_card_id
        ELSE NEW.score_card_id
    END;

    -- DELETE no forma parte de captura normal; otras protecciones existentes
    -- siguen gobernando anulaciones/cierres. Este gate se concentra en altas
    -- y ediciones competitivas.
    IF TG_OP <> 'DELETE' THEN
        PERFORM public._exigir_torneo_en_curso_scorecard_256(
            v_score_card_id,
            'recepción o captura física'
        );
    END IF;

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;

DROP TRIGGER IF EXISTS trg_inicio_torneo_fisico_recepcion_256
ON public.tournament_scorecard_physical_receptions;

CREATE TRIGGER trg_inicio_torneo_fisico_recepcion_256
BEFORE INSERT OR UPDATE
ON public.tournament_scorecard_physical_receptions
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_fisico_antes_inicio_256();

DROP TRIGGER IF EXISTS trg_inicio_torneo_fisico_hoyo_256
ON public.tournament_scorecard_physical_hole_scores;

CREATE TRIGGER trg_inicio_torneo_fisico_hoyo_256
BEFORE INSERT OR UPDATE
ON public.tournament_scorecard_physical_hole_scores
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_fisico_antes_inicio_256();


-- ----------------------------------------------------------------------------
-- 5. Barrera de conciliación.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._bloquear_conciliacion_antes_inicio_256()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_score_card_id uuid;
BEGIN
    v_score_card_id := CASE
        WHEN TG_OP = 'DELETE' THEN OLD.score_card_id
        ELSE NEW.score_card_id
    END;

    IF TG_OP <> 'DELETE' THEN
        PERFORM public._exigir_torneo_en_curso_scorecard_256(
            v_score_card_id,
            'conciliación de tarjeta'
        );
    END IF;

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;

DROP TRIGGER IF EXISTS trg_inicio_torneo_conciliacion_256
ON public.tournament_scorecard_reconciliations;

CREATE TRIGGER trg_inicio_torneo_conciliacion_256
BEFORE INSERT OR UPDATE
ON public.tournament_scorecard_reconciliations
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_conciliacion_antes_inicio_256();


-- ----------------------------------------------------------------------------
-- 6. Asistente v12_256.
--    Agrega INICIAR TORNEO como paso explícito.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._obtener_asistente_operativo_torneo_v12_256(
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
    v_steps jsonb;
    v_state jsonb;
    v_status text;
    v_ready boolean;
    v_started boolean;
    v_step jsonb;
    v_final_steps jsonb;
    v_blockers jsonb;
    v_next_action jsonb;
    v_total integer;
    v_completed integer;
BEGIN
    v_result := public._obtener_asistente_operativo_torneo_v11_254(
        p_tournament_id
    );

    v_steps := COALESCE(v_result->'steps', '[]'::jsonb);
    v_state := public.obtener_estado_inicio_torneo_256(p_tournament_id);

    v_status := v_state->>'status';
    v_ready := COALESCE((v_state->>'readyToStart')::boolean, false);
    v_started := COALESCE((v_state->>'alreadyStarted')::boolean, false);

    v_step := jsonb_build_object(
        'code', 'START_TOURNAMENT',
        'scope', 'TOURNAMENT',
        'title', 'Iniciar torneo',
        'status',
            CASE
                WHEN v_started THEN 'COMPLETE'
                WHEN v_ready THEN 'PENDING'
                ELSE 'BLOCKED'
            END,
        'message',
            CASE
                WHEN v_started THEN 'El torneo ya fue iniciado formalmente.'
                WHEN v_ready THEN 'La primera ronda está preparada. Ya puedes iniciar formalmente el torneo.'
                ELSE 'El torneo todavía no reúne las condiciones para iniciar.'
            END,
        'recommendation',
            CASE
                WHEN v_started OR v_ready THEN NULL
                ELSE 'Completa congelado, validación de salidas, emisión de tarjetas e inicialización de captura de la primera ronda.'
            END,
        'details', v_state,
        'action',
            CASE
                WHEN v_ready THEN jsonb_build_object(
                    'label', 'Iniciar torneo',
                    'target', 'lifecycle',
                    'action', 'start-tournament'
                )
                ELSE NULL
            END,
        'requiredRole', 'TOURNAMENT_OPERATOR',
        'availability', jsonb_build_object(
            'actionable', v_ready
        )
    );

    -- No dependemos de nombres internos de pasos anteriores:
    -- insertamos START_TOURNAMENT antes del primer paso claramente competitivo
    -- si existe; de lo contrario lo agregamos al final del flujo operativo.
    WITH expanded AS (
        SELECT elem, ord
        FROM jsonb_array_elements(v_steps)
             WITH ORDINALITY AS s(elem, ord)
    ),
    pivot AS (
        SELECT min(ord) AS competitive_ord
        FROM expanded
        WHERE elem->>'code' IN (
            'ROUND_RESULTS',
            'CATEGORY_CLOSURE',
            'ROUND_CLOSURE',
            'RESULTS_PUBLICATION',
            'TOURNAMENT_FINALIZATION'
        )
    ),
    combined AS (
        SELECT
            e.elem,
            CASE
                WHEN p.competitive_ord IS NULL THEN e.ord
                WHEN e.ord < p.competitive_ord THEN e.ord
                ELSE e.ord + 1
            END AS sort_key
        FROM expanded e
        CROSS JOIN pivot p

        UNION ALL

        SELECT
            v_step,
            CASE
                WHEN p.competitive_ord IS NULL
                    THEN COALESCE((SELECT max(ord) FROM expanded), 0) + 1
                ELSE p.competitive_ord
            END AS sort_key
        FROM pivot p
    )
    SELECT COALESCE(jsonb_agg(elem ORDER BY sort_key), '[]'::jsonb)
      INTO v_final_steps
      FROM combined;

    SELECT COALESCE(jsonb_agg(s.elem ORDER BY s.ord), '[]'::jsonb)
      INTO v_blockers
      FROM jsonb_array_elements(v_final_steps)
           WITH ORDINALITY AS s(elem, ord)
     WHERE s.elem->>'status' = 'BLOCKED'
       AND COALESCE(
           (s.elem #>> '{availability,actionable}')::boolean,
           true
       );

    SELECT s.elem->'action'
      INTO v_next_action
      FROM jsonb_array_elements(v_final_steps)
           WITH ORDINALITY AS s(elem, ord)
     WHERE s.elem->>'status' IN ('BLOCKED', 'PENDING')
       AND s.elem->'action' IS NOT NULL
       AND s.elem->'action' <> 'null'::jsonb
       AND COALESCE(
           (s.elem #>> '{availability,actionable}')::boolean,
           true
       )
     ORDER BY s.ord
     LIMIT 1;

    SELECT
        count(*)::integer,
        count(*) FILTER (WHERE elem->>'status' = 'COMPLETE')::integer
      INTO v_total, v_completed
      FROM jsonb_array_elements(v_final_steps) elem;

    v_result := jsonb_set(v_result, '{steps}', v_final_steps, true);
    v_result := jsonb_set(v_result, '{blockers}', v_blockers, true);
    v_result := jsonb_set(
        v_result,
        '{summary,blockingIssues}',
        to_jsonb(jsonb_array_length(v_blockers)),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{progress,completed}',
        to_jsonb(v_completed),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{progress,total}',
        to_jsonb(v_total),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{progress,percent}',
        to_jsonb(
            CASE
                WHEN v_total = 0 THEN 0
                ELSE round(100.0 * v_completed / v_total, 0)
            END
        ),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{nextAction}',
        COALESCE(v_next_action, 'null'::jsonb),
        true
    );

    RETURN v_result || jsonb_build_object('schemaVersion', 12);
END;
$function$;

REVOKE ALL ON FUNCTION public._obtener_asistente_operativo_torneo_v12_256(uuid)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._obtener_asistente_operativo_torneo_v12_256(uuid)
TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 7. Punto público del Asistente pasa a v12_256.
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
    RETURN public._obtener_asistente_operativo_torneo_v12_256(
        p_tournament_id
    );
END;
$function$;

COMMIT;
