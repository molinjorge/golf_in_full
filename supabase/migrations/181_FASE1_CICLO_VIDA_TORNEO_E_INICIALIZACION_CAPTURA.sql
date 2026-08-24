-- ============================================================================
-- 181_FASE1_CICLO_VIDA_TORNEO_E_INICIALIZACION_CAPTURA.sql
-- TEE CENTRAL
--
-- OBJETIVOS
-- 1) Formalizar transiciones manuales controladas:
--      planificado -> inscripciones_abiertas
--      inscripciones_abiertas -> inscripcion_cerrada
--      inscripcion_cerrada -> inscripciones_abiertas (solo antes del freeze)
--      inscripcion_cerrada -> en_curso
--
-- 2) Hacer atómica la operación:
--      emitir tarjetas oficiales -> inicializar captura digital
--
-- IMPORTANTE
-- - "planificado" sigue siendo el enum; la UI debe mostrar "EN PLANIFICACIÓN".
-- - NO se implementa todavía FINALIZAR TORNEO.
-- - NO se bloquean todavía UPDATE directos de tournaments.estatus.
--   Ese endurecimiento se hará después de cablear la UI a estas RPCs.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. ABRIR INSCRIPCIONES
-- ============================================================================
CREATE OR REPLACE FUNCTION public.abrir_inscripciones_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(), p_tournament_id)
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden abrir inscripciones.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF v_t.estatus = 'inscripciones_abiertas'::public.estatus_torneo THEN
        RETURN jsonb_build_object(
            'ok', true,
            'tournamentId', p_tournament_id,
            'alreadyOpen', true,
            'estatus', v_t.estatus::text
        );
    END IF;

    IF v_t.estatus <> 'planificado'::public.estatus_torneo THEN
        RAISE EXCEPTION
            'Las inscripciones sólo pueden abrirse desde EN PLANIFICACIÓN. Estado actual: %.',
            v_t.estatus
            USING ERRCODE = '23514';
    END IF;

    IF v_t.configuracion_finalizada_at IS NULL
       OR v_t.configuracion_finalizada_por IS NULL
    THEN
        RAISE EXCEPTION
            'No se pueden abrir inscripciones: la configuración del torneo aún no está finalizada.'
            USING ERRCODE = '23514';
    END IF;

    IF v_t.estado_servicio <> 'activo'::public.estado_servicio_torneo
       OR v_t.activo IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION
            'No se pueden abrir inscripciones: el torneo todavía no está liberado/activo en TEE CENTRAL.'
            USING ERRCODE = '23514',
                  DETAIL = format(
                      'estado_servicio=%s; activo=%s',
                      v_t.estado_servicio,
                      v_t.activo
                  );
    END IF;

    UPDATE public.tournaments
       SET estatus = 'inscripciones_abiertas'::public.estatus_torneo
     WHERE id = p_tournament_id;

    RETURN jsonb_build_object(
        'ok', true,
        'tournamentId', p_tournament_id,
        'alreadyOpen', false,
        'estatusAnterior', 'planificado',
        'estatus', 'inscripciones_abiertas'
    );
END;
$function$;


-- ============================================================================
-- 02. CERRAR INSCRIPCIONES
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cerrar_inscripciones_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(), p_tournament_id)
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden cerrar inscripciones.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF v_t.estatus = 'inscripcion_cerrada'::public.estatus_torneo THEN
        RETURN jsonb_build_object(
            'ok', true,
            'tournamentId', p_tournament_id,
            'alreadyClosed', true,
            'estatus', v_t.estatus::text
        );
    END IF;

    IF v_t.estatus <> 'inscripciones_abiertas'::public.estatus_torneo THEN
        RAISE EXCEPTION
            'Las inscripciones sólo pueden cerrarse cuando están abiertas. Estado actual: %.',
            v_t.estatus
            USING ERRCODE = '23514';
    END IF;

    UPDATE public.tournaments
       SET estatus = 'inscripcion_cerrada'::public.estatus_torneo
     WHERE id = p_tournament_id;

    RETURN jsonb_build_object(
        'ok', true,
        'tournamentId', p_tournament_id,
        'alreadyClosed', false,
        'estatusAnterior', 'inscripciones_abiertas',
        'estatus', 'inscripcion_cerrada'
    );
END;
$function$;


-- ============================================================================
-- 03. REABRIR INSCRIPCIONES
-- Sólo antes de congelar condiciones.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.reabrir_inscripciones_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(), p_tournament_id)
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden reabrir inscripciones.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF v_t.estatus = 'inscripciones_abiertas'::public.estatus_torneo THEN
        RETURN jsonb_build_object(
            'ok', true,
            'tournamentId', p_tournament_id,
            'alreadyOpen', true,
            'estatus', v_t.estatus::text
        );
    END IF;

    IF v_t.estatus <> 'inscripcion_cerrada'::public.estatus_torneo THEN
        RAISE EXCEPTION
            'Las inscripciones sólo pueden reabrirse desde INSCRIPCIÓN CERRADA. Estado actual: %.',
            v_t.estatus
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No se pueden reabrir las inscripciones porque las condiciones y hándicaps del torneo ya fueron congelados.'
            USING ERRCODE = '55000',
                  HINT = 'El freeze fotografía participantes, tees y hándicaps. La reapertura normal sólo está permitida antes del congelamiento.';
    END IF;

    -- Defensa adicional: estos estados no deberían existir sin freeze,
    -- pero si existieran por datos históricos, tampoco permitimos reapertura.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_round_start_validations v
        JOIN public.tournament_rounds tr
          ON tr.id = v.tournament_round_id
        WHERE tr.tournament_id = p_tournament_id
          AND v.status = 'validated'
    ) THEN
        RAISE EXCEPTION
            'No se pueden reabrir las inscripciones porque ya existen salidas validadas.'
            USING ERRCODE = '55000';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_score_card_emissions e
        WHERE e.tournament_id = p_tournament_id
          AND e.status = 'issued'
    ) THEN
        RAISE EXCEPTION
            'No se pueden reabrir las inscripciones porque ya existen tarjetas oficiales emitidas.'
            USING ERRCODE = '55000';
    END IF;

    UPDATE public.tournaments
       SET estatus = 'inscripciones_abiertas'::public.estatus_torneo
     WHERE id = p_tournament_id;

    RETURN jsonb_build_object(
        'ok', true,
        'tournamentId', p_tournament_id,
        'alreadyOpen', false,
        'estatusAnterior', 'inscripcion_cerrada',
        'estatus', 'inscripciones_abiertas'
    );
END;
$function$;


-- ============================================================================
-- 04. INICIAR TORNEO
--
-- Acción manual.
-- Requiere que la PRIMERA ronda activa esté completamente preparada:
-- freeze + salidas validadas + tarjetas emitidas + captura digital inicializada.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.iniciar_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
    v_round_id uuid;
    v_round_number integer;
    v_cards integer := 0;
    v_sessions integer := 0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(), p_tournament_id)
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden iniciar el torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF v_t.estatus = 'en_curso'::public.estatus_torneo THEN
        RETURN jsonb_build_object(
            'ok', true,
            'tournamentId', p_tournament_id,
            'alreadyStarted', true,
            'estatus', 'en_curso'
        );
    END IF;

    IF v_t.estatus <> 'inscripcion_cerrada'::public.estatus_torneo THEN
        RAISE EXCEPTION
            'El torneo sólo puede iniciarse desde INSCRIPCIÓN CERRADA. Estado actual: %.',
            v_t.estatus
            USING ERRCODE = '23514';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No se puede iniciar el torneo: primero deben congelarse las condiciones y hándicaps.'
            USING ERRCODE = '23514';
    END IF;

    SELECT tr.id, tr.numero_ronda
      INTO v_round_id, v_round_number
      FROM public.tournament_rounds tr
     WHERE tr.tournament_id = p_tournament_id
       AND tr.activo = true
     ORDER BY tr.numero_ronda ASC, tr.fecha ASC, tr.id ASC
     LIMIT 1;

    IF v_round_id IS NULL THEN
        RAISE EXCEPTION
            'No se puede iniciar el torneo: no existe una ronda activa.'
            USING ERRCODE = '23514';
    END IF;

    IF NOT public._salida_ronda_esta_validada(v_round_id) THEN
        RAISE EXCEPTION
            'No se puede iniciar el torneo: las salidas de la primera ronda aún no están validadas.'
            USING ERRCODE = '23514',
                  DETAIL = format('round_id=%s; numero_ronda=%s', v_round_id, v_round_number);
    END IF;

    IF NOT public._ronda_tiene_tarjetas_emitidas(v_round_id) THEN
        RAISE EXCEPTION
            'No se puede iniciar el torneo: la primera ronda no tiene tarjetas oficiales emitidas.'
            USING ERRCODE = '23514',
                  DETAIL = format('round_id=%s; numero_ronda=%s', v_round_id, v_round_number);
    END IF;

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

    IF v_cards <= 0 OR v_sessions <> v_cards THEN
        RAISE EXCEPTION
            'No se puede iniciar el torneo: la captura digital de la primera ronda no está completamente inicializada.'
            USING ERRCODE = '23514',
                  DETAIL = format(
                      'round_id=%s; tarjetas_emitidas=%s; sesiones_captura=%s',
                      v_round_id,
                      v_cards,
                      v_sessions
                  ),
                  HINT = 'Emite nuevamente/consulta la emisión oficial para completar la inicialización de captura.';
    END IF;

    UPDATE public.tournaments
       SET estatus = 'en_curso'::public.estatus_torneo
     WHERE id = p_tournament_id;

    RETURN jsonb_build_object(
        'ok', true,
        'tournamentId', p_tournament_id,
        'alreadyStarted', false,
        'estatusAnterior', 'inscripcion_cerrada',
        'estatus', 'en_curso',
        'firstRoundId', v_round_id,
        'firstRoundNumber', v_round_number,
        'issuedCards', v_cards,
        'captureSessions', v_sessions
    );
END;
$function$;


-- ============================================================================
-- 05. EMISIÓN OFICIAL + INICIALIZACIÓN DIGITAL ATÓMICA
--
-- Modificación defensiva de la RPC existente.
-- Inserta la llamada a inicializar_captura_scores_ronda() antes de ambos
-- retornos de obtener_estado_emision_tarjetas_ronda().
--
-- Beneficio adicional:
-- si una ronda histórica ya tiene tarjetas emitidas pero no sesiones digitales,
-- volver a ejecutar emitir_tarjetas_score_ronda() completa la inicialización
-- sin duplicar tarjetas.
-- ============================================================================
DO $migration$
DECLARE
    v_oid regprocedure;
    v_def text;
    v_old_existing text;
    v_new_existing text;
    v_old_final text;
    v_new_final text;
    v_hits_existing integer;
    v_hits_final integer;
BEGIN
    v_oid := to_regprocedure(
        'public.emitir_tarjetas_score_ronda(uuid)'
    );

    IF v_oid IS NULL THEN
        RAISE EXCEPTION
            'No existe public.emitir_tarjetas_score_ronda(uuid).';
    END IF;

    IF to_regprocedure(
        'public.inicializar_captura_scores_ronda(uuid)'
    ) IS NULL THEN
        RAISE EXCEPTION
            'No existe public.inicializar_captura_scores_ronda(uuid).';
    END IF;

    v_def := pg_get_functiondef(v_oid);

    -- Si ya fue modificada previamente, no volver a insertar llamadas.
    IF v_def ILIKE '%PERFORM public.inicializar_captura_scores_ronda(p_tournament_round_id);%' THEN
        RETURN;
    END IF;

    v_old_existing := $old$
    IF public._ronda_tiene_tarjetas_emitidas(p_tournament_round_id) THEN
        RETURN public.obtener_estado_emision_tarjetas_ronda(
            p_tournament_round_id
        );
    END IF;
$old$;

    v_new_existing := $new$
    IF public._ronda_tiene_tarjetas_emitidas(p_tournament_round_id) THEN
        PERFORM public.inicializar_captura_scores_ronda(
            p_tournament_round_id
        );

        RETURN public.obtener_estado_emision_tarjetas_ronda(
            p_tournament_round_id
        );
    END IF;
$new$;

    v_old_final := $old$
    RETURN public.obtener_estado_emision_tarjetas_ronda(
        p_tournament_round_id
    );
END;
$old$;

    v_new_final := $new$
    -- La emisión y la inicialización digital quedan en la MISMA transacción.
    -- Si la inicialización falla, PostgreSQL revierte también la emisión.
    PERFORM public.inicializar_captura_scores_ronda(
        p_tournament_round_id
    );

    RETURN public.obtener_estado_emision_tarjetas_ronda(
        p_tournament_round_id
    );
END;
$new$;

    v_hits_existing :=
        (length(v_def) - length(replace(v_def, v_old_existing, '')))
        / NULLIF(length(v_old_existing), 0);

    v_hits_final :=
        (length(v_def) - length(replace(v_def, v_old_final, '')))
        / NULLIF(length(v_old_final), 0);

    IF v_hits_existing <> 1 OR v_hits_final <> 1 THEN
        RAISE EXCEPTION
            'Migración 181 detenida: no coincide la estructura esperada de emitir_tarjetas_score_ronda(). existing=% final=%',
            v_hits_existing,
            v_hits_final
            USING HINT =
                'No se modificó la función. Diagnostica primero su definición actual.';
    END IF;

    v_def := replace(v_def, v_old_existing, v_new_existing);
    v_def := replace(v_def, v_old_final, v_new_final);

    EXECUTE v_def;
END;
$migration$;


-- ============================================================================
-- 06. PRIVILEGIOS
-- ============================================================================
REVOKE ALL ON FUNCTION public.abrir_inscripciones_torneo(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cerrar_inscripciones_torneo(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reabrir_inscripciones_torneo(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.iniciar_torneo(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.abrir_inscripciones_torneo(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.cerrar_inscripciones_torneo(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.reabrir_inscripciones_torneo(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.iniciar_torneo(uuid) FROM anon;

GRANT EXECUTE ON FUNCTION public.abrir_inscripciones_torneo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cerrar_inscripciones_torneo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reabrir_inscripciones_torneo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.iniciar_torneo(uuid) TO authenticated;

GRANT EXECUTE ON FUNCTION public.abrir_inscripciones_torneo(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.cerrar_inscripciones_torneo(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.reabrir_inscripciones_torneo(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.iniciar_torneo(uuid) TO service_role;

COMMIT;
