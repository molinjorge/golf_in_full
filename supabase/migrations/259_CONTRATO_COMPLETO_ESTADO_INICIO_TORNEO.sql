-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 259
-- Contrato completo del estado de inicio después de iniciar/finalizar
-- ============================================================

BEGIN;

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
    v_already_started boolean := false;
BEGIN
    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    v_already_started :=
        v_t.estatus IN (
            'en_curso'::public.estatus_torneo,
            'finalizado'::public.estatus_torneo
        );

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
        v_starts_validated :=
            public._salida_ronda_esta_validada(v_round_id);

        v_cards_issued :=
            public._ronda_tiene_tarjetas_emitidas(v_round_id);

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

    IF v_already_started THEN
        RETURN jsonb_build_object(
            'tournamentId', p_tournament_id,
            'status', v_t.estatus::text,
            'alreadyStarted', true,
            'readyToStart', false,
            'firstRoundId', v_round_id,
            'firstRoundNumber', v_round_number,
            'conditionsFrozen', v_frozen,
            'startsValidated', v_starts_validated,
            'cardsIssued', v_cards_issued,
            'issuedCards', v_cards,
            'captureSessions', v_sessions,
            'captureReady', v_capture_ready,
            'errors', '[]'::jsonb
        );
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

COMMENT ON FUNCTION public.obtener_estado_inicio_torneo_256(uuid)
IS 'M259: estado de inicio con contrato completo también para torneos en_curso/finalizado; preserva firstRoundId y todos los indicadores de preparación.';

REVOKE ALL
ON FUNCTION public.obtener_estado_inicio_torneo_256(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.obtener_estado_inicio_torneo_256(uuid)
TO postgres, authenticated, service_role;

COMMIT;
