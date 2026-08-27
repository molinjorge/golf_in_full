-- ============================================================================
-- MIGRACIÓN 187 FASE 1A-1
-- AJUSTE SEMÁNTICO DEL ASISTENTE OPERATIVO DEL TORNEO
--
-- CORRIGE:
-- 1) Diferenciar "competitivamente resuelta" de "cierre formal persistido".
-- 2) No sugerir finalizar torneo sin cierre formal de todas las rondas.
-- 3) Stage más fiel cuando ya existen tarjetas/captura.
--
-- NO modifica reglas deportivas ni datos.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_asistente_operativo_torneo(
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
    v_config record;

    v_is_superadmin boolean := false;
    v_is_organizer boolean := false;
    v_can_manage boolean := false;

    v_total_categories integer := 0;
    v_category_capacity bigint := 0;
    v_registration_count integer := 0;
    v_pre_reservation_count integer := 0;
    v_phone_reservation_count integer := 0;

    v_frozen boolean := false;
    v_freeze jsonb := NULL;

    v_rounds jsonb := '[]'::jsonb;
    v_round record;

    v_steps jsonb := '[]'::jsonb;
    v_blockers jsonb := '[]'::jsonb;
    v_warnings jsonb := '[]'::jsonb;

    v_step jsonb;
    v_status text;
    v_message text;
    v_recommendation text;

    v_validation_state jsonb;
    v_emission_state jsonb;
    v_reconciliation_state jsonb;
    v_competitive_state jsonb;
    v_formal_close_state jsonb;

    v_round_validated boolean;
    v_cards_issued boolean;
    v_competitively_resolved boolean;
    v_formally_closed boolean;

    v_capture_pending integer;
    v_reconciliation_pending integer;

    v_completed integer := 0;
    v_total_steps integer := 0;
    v_blocked integer := 0;
    v_warning_count integer := 0;

    v_stage text := 'CONFIGURATION';
    v_next_action jsonb := NULL;

    v_any_cards_issued boolean := false;
    v_any_scoring_pending boolean := false;
    v_all_rounds_formally_closed boolean := true;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    v_is_superadmin := public.is_superadmin(auth.uid());
    v_is_organizer := public.is_tournament_organizer(
        auth.uid(),
        p_tournament_id
    );
    v_can_manage := public.puede_administrar_congelamiento_torneo(
        p_tournament_id
    );

    IF NOT (
        v_is_superadmin
        OR v_is_organizer
        OR v_can_manage
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar el asistente operativo de este torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_config
      FROM public.validar_configuracion_minima_torneo(p_tournament_id);

    SELECT
        count(*)::integer,
        COALESCE(sum(tc.cupo_maximo), 0)
      INTO
        v_total_categories,
        v_category_capacity
      FROM public.tournament_categories tc
     WHERE tc.tournament_id = p_tournament_id;

    SELECT count(*)::integer
      INTO v_registration_count
      FROM public.tournament_registrations tr
     WHERE tr.tournament_id = p_tournament_id
       AND tr.activo = true;

    SELECT count(*)::integer
      INTO v_pre_reservation_count
      FROM public.tournament_pre_reservations pr
     WHERE pr.tournament_id = p_tournament_id
       AND pr.activo = true
       AND pr.tournament_registration_id IS NULL;

    SELECT count(*)::integer
      INTO v_phone_reservation_count
      FROM public.phone_reservations ph
     WHERE ph.tournament_id = p_tournament_id
       AND ph.activo = true;

    SELECT jsonb_build_object(
        'frozen', f.id IS NOT NULL,
        'freezeId', f.id,
        'frozenAt', f.frozen_at,
        'rounds', COALESCE(f.round_count, 0),
        'participants', COALESCE(f.participant_count, 0),
        'warnings', COALESCE(f.warnings_snapshot, '[]'::jsonb)
    )
      INTO v_freeze
      FROM (SELECT 1) seed
      LEFT JOIN public.tournament_condition_freezes f
        ON f.tournament_id = p_tournament_id;

    v_frozen := COALESCE((v_freeze->>'frozen')::boolean, false);

    ---------------------------------------------------------------------------
    -- Configuración mínima
    ---------------------------------------------------------------------------
    v_total_steps := v_total_steps + 1;

    IF COALESCE(v_config.listo, false) THEN
        v_status := 'COMPLETE';
        v_completed := v_completed + 1;
        v_message := 'La configuración mínima del torneo está completa.';
        v_recommendation := NULL;
    ELSE
        v_status := 'BLOCKED';
        v_blocked := v_blocked + 1;
        v_message := 'La configuración mínima todavía tiene datos pendientes.';
        v_recommendation :=
            'Corrige los datos indicados antes de confirmar la configuración.';
    END IF;

    v_step := jsonb_build_object(
        'code', 'TOURNAMENT_CONFIGURATION',
        'scope', 'TOURNAMENT',
        'title', 'Configuración del torneo',
        'status', v_status,
        'message', v_message,
        'recommendation', v_recommendation,
        'details', jsonb_build_object(
            'ready', COALESCE(v_config.listo, false),
            'errors', COALESCE(v_config.errores, '[]'::jsonb),
            'tournamentCapacity', v_t.cupo_maximo,
            'categoryCapacityTotal', v_category_capacity,
            'categories', v_total_categories
        ),
        'action', jsonb_build_object(
            'label', 'Revisar configuración',
            'target', 'configuracion'
        ),
        'requiredRole', 'TOURNAMENT_OPERATOR'
    );

    v_steps := v_steps || jsonb_build_array(v_step);

    IF v_status = 'BLOCKED' THEN
        v_blockers := v_blockers || jsonb_build_array(v_step);
    END IF;

    ---------------------------------------------------------------------------
    -- Configuración finalizada
    ---------------------------------------------------------------------------
    v_total_steps := v_total_steps + 1;

    IF v_t.configuracion_finalizada_at IS NOT NULL THEN
        v_status := 'COMPLETE';
        v_completed := v_completed + 1;
        v_message := 'La configuración fue confirmada.';
        v_recommendation := NULL;
    ELSIF COALESCE(v_config.listo, false) THEN
        v_status := 'PENDING';
        v_message := 'La configuración ya puede confirmarse.';
        v_recommendation := 'Confirma la configuración para continuar.';
    ELSE
        v_status := 'PENDING';
        v_message := 'La configuración todavía no puede confirmarse.';
        v_recommendation := 'Resuelve primero los pendientes de configuración.';
    END IF;

    v_step := jsonb_build_object(
        'code', 'CONFIGURATION_CONFIRMATION',
        'scope', 'TOURNAMENT',
        'title', 'Confirmar configuración',
        'status', v_status,
        'message', v_message,
        'recommendation', v_recommendation,
        'details', jsonb_build_object(
            'finalizedAt', v_t.configuracion_finalizada_at
        ),
        'action', jsonb_build_object(
            'label', 'Confirmar configuración',
            'target', 'configuracion'
        ),
        'requiredRole', 'TOURNAMENT_OPERATOR'
    );

    v_steps := v_steps || jsonb_build_array(v_step);

    ---------------------------------------------------------------------------
    -- Inscripciones
    ---------------------------------------------------------------------------
    v_total_steps := v_total_steps + 1;

    IF v_t.estatus IN (
        'inscripcion_cerrada'::public.estatus_torneo,
        'en_curso'::public.estatus_torneo,
        'finalizado'::public.estatus_torneo
    ) THEN
        v_status := 'COMPLETE';
        v_completed := v_completed + 1;
        v_message := format(
            'Las inscripciones están cerradas con %s jugador(es) inscritos.',
            v_registration_count
        );
        v_recommendation := NULL;
    ELSIF v_t.estatus = 'inscripciones_abiertas'::public.estatus_torneo THEN
        v_status := 'PENDING';
        v_message := format(
            'Las inscripciones están abiertas. Hay %s jugador(es) inscritos.',
            v_registration_count
        );
        v_recommendation :=
            'Cuando el roster esté listo, cierra las inscripciones.';
    ELSE
        v_status := 'PENDING';
        v_message := 'Las inscripciones todavía no están abiertas.';
        v_recommendation :=
            'Completa y libera el torneo antes de abrir inscripciones.';
    END IF;

    v_step := jsonb_build_object(
        'code', 'REGISTRATIONS',
        'scope', 'TOURNAMENT',
        'title', 'Inscripciones',
        'status', v_status,
        'message', v_message,
        'recommendation', v_recommendation,
        'details', jsonb_build_object(
            'status', v_t.estatus::text,
            'registrations', v_registration_count,
            'preReservations', v_pre_reservation_count,
            'phoneReservations', v_phone_reservation_count
        ),
        'action', jsonb_build_object(
            'label', 'Ir a inscripciones',
            'target', 'inscripciones'
        ),
        'requiredRole', 'TOURNAMENT_OPERATOR'
    );

    v_steps := v_steps || jsonb_build_array(v_step);

    ---------------------------------------------------------------------------
    -- Freeze
    ---------------------------------------------------------------------------
    v_total_steps := v_total_steps + 1;

    IF v_frozen THEN
        v_status := 'COMPLETE';
        v_completed := v_completed + 1;
        v_message := 'Las condiciones y hándicaps están congelados.';
        v_recommendation := NULL;
    ELSIF v_t.estatus = 'inscripcion_cerrada'::public.estatus_torneo THEN
        v_status := 'PENDING';
        v_message := 'Las inscripciones están cerradas y el torneo puede congelarse.';
        v_recommendation :=
            'Revisa y congela las condiciones y hándicaps antes de preparar salidas.';
    ELSIF v_t.estatus = 'inscripciones_abiertas'::public.estatus_torneo THEN
        v_status := 'BLOCKED';
        v_blocked := v_blocked + 1;
        v_message :=
            'No se pueden congelar condiciones mientras las inscripciones estén abiertas.';
        v_recommendation := 'Cierra primero las inscripciones.';
    ELSE
        v_status := 'PENDING';
        v_message := 'El congelamiento todavía no corresponde.';
        v_recommendation := NULL;
    END IF;

    v_step := jsonb_build_object(
        'code', 'FREEZE',
        'scope', 'TOURNAMENT',
        'title', 'Congelar condiciones y hándicaps',
        'status', v_status,
        'message', v_message,
        'recommendation', v_recommendation,
        'details', v_freeze,
        'action', jsonb_build_object(
            'label', 'Revisar congelamiento',
            'target', 'condiciones-handicaps'
        ),
        'requiredRole', 'TOURNAMENT_OPERATOR'
    );

    v_steps := v_steps || jsonb_build_array(v_step);

    IF v_status = 'BLOCKED' THEN
        v_blockers := v_blockers || jsonb_build_array(v_step);
    END IF;

    ---------------------------------------------------------------------------
    -- Rondas
    ---------------------------------------------------------------------------
    FOR v_round IN
        SELECT
            tr.id,
            tr.numero_ronda,
            tr.fecha,
            tr.formato_salida::text AS start_format
        FROM public.tournament_rounds tr
        WHERE tr.tournament_id = p_tournament_id
          AND tr.activo = true
        ORDER BY tr.numero_ronda, tr.fecha, tr.id
    LOOP
        v_validation_state :=
            public.obtener_estado_validacion_salidas_ronda(v_round.id);

        v_round_validated :=
            COALESCE((v_validation_state->>'validated')::boolean, false);

        -----------------------------------------------------------------------
        -- Salidas
        -----------------------------------------------------------------------
        v_total_steps := v_total_steps + 1;

        IF v_round_validated THEN
            v_status := 'COMPLETE';
            v_completed := v_completed + 1;
            v_message := format(
                'Las salidas de la ronda %s están validadas y cerradas.',
                v_round.numero_ronda
            );
            v_recommendation := NULL;
        ELSIF NOT v_frozen THEN
            v_status := 'BLOCKED';
            v_blocked := v_blocked + 1;
            v_message := format(
                'La ronda %s no puede preparar/validar salidas porque el torneo no está congelado.',
                v_round.numero_ronda
            );
            v_recommendation :=
                'Congela primero las condiciones y hándicaps.';
        ELSIF v_t.estatus = 'inscripciones_abiertas'::public.estatus_torneo THEN
            v_status := 'BLOCKED';
            v_blocked := v_blocked + 1;
            v_message := format(
                'La ronda %s no puede cerrar salidas mientras las inscripciones estén abiertas.',
                v_round.numero_ronda
            );
            v_recommendation := 'Cierra primero las inscripciones.';
        ELSE
            v_status := 'PENDING';
            v_message := format(
                'Las salidas de la ronda %s todavía no están validadas.',
                v_round.numero_ronda
            );
            v_recommendation :=
                'Prepara, revisa y valida las salidas de la ronda.';
        END IF;

        v_step := jsonb_build_object(
            'code', 'ROUND_STARTS',
            'scope', 'ROUND',
            'roundId', v_round.id,
            'roundNumber', v_round.numero_ronda,
            'title', format('Ronda %s · Salidas', v_round.numero_ronda),
            'status', v_status,
            'message', v_message,
            'recommendation', v_recommendation,
            'details', jsonb_build_object(
                'startFormat', v_round.start_format,
                'validation', v_validation_state
            ),
            'action', jsonb_build_object(
                'label', 'Revisar salidas',
                'target', 'salidas',
                'roundId', v_round.id
            ),
            'requiredRole', 'TOURNAMENT_OPERATOR'
        );

        v_steps := v_steps || jsonb_build_array(v_step);

        IF v_status = 'BLOCKED' THEN
            v_blockers := v_blockers || jsonb_build_array(v_step);
        END IF;

        -----------------------------------------------------------------------
        -- Tarjetas
        -----------------------------------------------------------------------
        v_emission_state :=
            public.obtener_estado_emision_tarjetas_ronda(v_round.id);

        v_cards_issued :=
            COALESCE((v_emission_state->>'issued')::boolean, false);

        v_any_cards_issued := v_any_cards_issued OR v_cards_issued;

        v_total_steps := v_total_steps + 1;

        IF v_cards_issued THEN
            v_status := 'COMPLETE';
            v_completed := v_completed + 1;
            v_message := format(
                'Las tarjetas oficiales de la ronda %s ya fueron emitidas.',
                v_round.numero_ronda
            );
            v_recommendation := NULL;
        ELSIF v_round_validated THEN
            v_status := 'PENDING';
            v_message := format(
                'La ronda %s está lista para previsualizar y emitir tarjetas.',
                v_round.numero_ronda
            );
            v_recommendation :=
                'Previsualiza las tarjetas antes de emitirlas oficialmente.';
        ELSE
            v_status := 'BLOCKED';
            v_blocked := v_blocked + 1;
            v_message := format(
                'No se pueden emitir tarjetas de la ronda %s porque las salidas no están validadas.',
                v_round.numero_ronda
            );
            v_recommendation := 'Valida y cierra primero las salidas.';
        END IF;

        v_step := jsonb_build_object(
            'code', 'SCORECARD_EMISSION',
            'scope', 'ROUND',
            'roundId', v_round.id,
            'roundNumber', v_round.numero_ronda,
            'title', format('Ronda %s · Tarjetas', v_round.numero_ronda),
            'status', v_status,
            'message', v_message,
            'recommendation', v_recommendation,
            'details', v_emission_state,
            'action', jsonb_build_object(
                'label', 'Revisar tarjetas',
                'target', 'tarjetas',
                'roundId', v_round.id
            ),
            'requiredRole', 'TOURNAMENT_OPERATOR'
        );

        v_steps := v_steps || jsonb_build_array(v_step);

        IF v_status = 'BLOCKED' THEN
            v_blockers := v_blockers || jsonb_build_array(v_step);
        END IF;

        -----------------------------------------------------------------------
        -- Captura / conciliación
        -----------------------------------------------------------------------
        v_total_steps := v_total_steps + 1;

        IF NOT v_cards_issued THEN
            v_status := 'PENDING';
            v_message := format(
                'La captura de resultados de la ronda %s todavía no inicia.',
                v_round.numero_ronda
            );
            v_recommendation := NULL;

            v_reconciliation_state := jsonb_build_object(
                'summary',
                jsonb_build_object(
                    'totalCards', 0,
                    'nrq', 0,
                    'conciliadas', 0,
                    'pendientesConciliar', 0,
                    'noAplicaAun', 0
                )
            );
        ELSE
            v_reconciliation_state :=
                public.obtener_estados_conciliacion_ronda(v_round.id);

            v_capture_pending :=
                COALESCE(
                    (
                        v_reconciliation_state
                        #>> '{summary,noAplicaAun}'
                    )::integer,
                    0
                );

            v_reconciliation_pending :=
                COALESCE(
                    (
                        v_reconciliation_state
                        #>> '{summary,pendientesConciliar}'
                    )::integer,
                    0
                );

            IF v_capture_pending = 0
               AND v_reconciliation_pending = 0
            THEN
                v_status := 'COMPLETE';
                v_completed := v_completed + 1;
                v_message := format(
                    'Las tarjetas de la ronda %s ya están procesadas y sin conciliaciones pendientes.',
                    v_round.numero_ronda
                );
                v_recommendation := NULL;
            ELSE
                v_status := 'PENDING';
                v_any_scoring_pending := true;
                v_message := format(
                    'La ronda %s aún tiene captura física o conciliaciones pendientes.',
                    v_round.numero_ronda
                );
                v_recommendation :=
                    'Completa la captura física y resuelve únicamente las conciliaciones que lo requieran.';
            END IF;
        END IF;

        v_step := jsonb_build_object(
            'code', 'ROUND_SCORING',
            'scope', 'ROUND',
            'roundId', v_round.id,
            'roundNumber', v_round.numero_ronda,
            'title', format(
                'Ronda %s · Captura y conciliación',
                v_round.numero_ronda
            ),
            'status', v_status,
            'message', v_message,
            'recommendation', v_recommendation,
            'details', v_reconciliation_state,
            'action', jsonb_build_object(
                'label', 'Revisar captura',
                'target', 'captura-resultados',
                'roundId', v_round.id
            ),
            'requiredRole', 'TOURNAMENT_OPERATOR'
        );

        v_steps := v_steps || jsonb_build_array(v_step);

        -----------------------------------------------------------------------
        -- Estado competitivo + cierre formal
        -----------------------------------------------------------------------
        v_total_steps := v_total_steps + 1;

        v_competitive_state := NULL;
        v_competitively_resolved := false;

        IF v_frozen THEN
            BEGIN
                v_competitive_state :=
                    public.obtener_estado_cierre_competitivo_ronda(v_round.id);

                v_competitively_resolved :=
                    COALESCE(
                        (
                            v_competitive_state
                            #>> '{status,competitivelyClosed}'
                        )::boolean,
                        false
                    );

            EXCEPTION
                WHEN SQLSTATE '55000' OR SQLSTATE '0A000' THEN
                    v_competitive_state := NULL;
                    v_competitively_resolved := false;
            END;
        END IF;

        v_formal_close_state :=
            public.obtener_cierre_formal_ronda(v_round.id);

        v_formally_closed :=
            COALESCE(
                (v_formal_close_state->>'closed')::boolean,
                false
            );

        v_all_rounds_formally_closed :=
            v_all_rounds_formally_closed AND v_formally_closed;

        IF v_formally_closed THEN
            v_status := 'COMPLETE';
            v_completed := v_completed + 1;
            v_message := format(
                'La ronda %s tiene cierre competitivo formal.',
                v_round.numero_ronda
            );
            v_recommendation := NULL;

        ELSIF v_competitively_resolved THEN
            v_status := 'PENDING';
            v_message := format(
                'La ronda %s ya está competitivamente resuelta, pero todavía no tiene cierre formal.',
                v_round.numero_ronda
            );
            v_recommendation :=
                'Confirma el cierre formal de la ronda para sellar sus resultados.';

        ELSIF NOT v_frozen THEN
            v_status := 'PENDING';
            v_message := format(
                'El cierre competitivo de la ronda %s todavía no corresponde.',
                v_round.numero_ronda
            );
            v_recommendation := NULL;

        ELSE
            v_status := 'PENDING';
            v_message := format(
                'La ronda %s todavía no está competitivamente resuelta.',
                v_round.numero_ronda
            );

            IF COALESCE(
                (
                    v_competitive_state
                    #>> '{tiebreakSummary,configMissing}'
                )::integer,
                0
            ) > 0 THEN
                v_recommendation :=
                    'Faltan reglas de desempate para uno o más empates.';
            ELSIF COALESCE(
                (
                    v_competitive_state
                    #>> '{tiebreakSummary,manualPending}'
                )::integer,
                0
            ) > 0 THEN
                v_recommendation :=
                    'Hay desempates que requieren resolución manual.';
            ELSE
                v_recommendation :=
                    'Completa resultados pendientes y resuelve los desempates que correspondan.';
            END IF;
        END IF;

        v_step := jsonb_build_object(
            'code', 'ROUND_COMPETITIVE_CLOSE',
            'scope', 'ROUND',
            'roundId', v_round.id,
            'roundNumber', v_round.numero_ronda,
            'title', format(
                'Ronda %s · Cierre competitivo',
                v_round.numero_ronda
            ),
            'status', v_status,
            'message', v_message,
            'recommendation', v_recommendation,
            'details', jsonb_build_object(
                'competitiveState', v_competitive_state,
                'competitivelyResolved', v_competitively_resolved,
                'formalClose', v_formal_close_state,
                'formallyClosed', v_formally_closed
            ),
            'action', jsonb_build_object(
                'label',
                    CASE
                        WHEN v_competitively_resolved
                         AND NOT v_formally_closed
                            THEN 'Cerrar ronda'
                        ELSE 'Revisar resultados'
                    END,
                'target', 'resultados',
                'roundId', v_round.id
            ),
            'requiredRole', 'TOURNAMENT_OPERATOR'
        );

        v_steps := v_steps || jsonb_build_array(v_step);

        v_rounds := v_rounds || jsonb_build_array(
            jsonb_build_object(
                'roundId', v_round.id,
                'roundNumber', v_round.numero_ronda,
                'roundDate', v_round.fecha,
                'startFormat', v_round.start_format,
                'startsValidated', v_round_validated,
                'scorecardsIssued', v_cards_issued,
                'competitivelyResolved', v_competitively_resolved,
                'formallyClosed', v_formally_closed
            )
        );
    END LOOP;

    ---------------------------------------------------------------------------
    -- Finalización del torneo
    ---------------------------------------------------------------------------
    v_total_steps := v_total_steps + 1;

    IF v_t.estatus = 'finalizado'::public.estatus_torneo THEN
        v_status := 'COMPLETE';
        v_completed := v_completed + 1;
        v_message := 'El torneo está finalizado.';
        v_recommendation := NULL;

    ELSIF v_t.estatus = 'en_curso'::public.estatus_torneo
          AND jsonb_array_length(v_rounds) > 0
          AND v_all_rounds_formally_closed
    THEN
        v_status := 'PENDING';
        v_message := 'Todas las rondas tienen cierre formal.';
        v_recommendation :=
            'El torneo puede pasar a su finalización formal.';

    ELSE
        v_status := 'PENDING';
        v_message := 'El torneo todavía no puede finalizarse.';
        v_recommendation :=
            'Completa primero el cierre formal de todas las rondas.';
    END IF;

    v_step := jsonb_build_object(
        'code', 'TOURNAMENT_FINALIZATION',
        'scope', 'TOURNAMENT',
        'title', 'Finalizar torneo',
        'status', v_status,
        'message', v_message,
        'recommendation', v_recommendation,
        'details', jsonb_build_object(
            'tournamentStatus', v_t.estatus::text,
            'allRoundsFormallyClosed', v_all_rounds_formally_closed
        ),
        'action', jsonb_build_object(
            'label', 'Revisar finalización',
            'target', 'resultados'
        ),
        'requiredRole', 'TOURNAMENT_OPERATOR'
    );

    v_steps := v_steps || jsonb_build_array(v_step);

    ---------------------------------------------------------------------------
    -- Stage general
    ---------------------------------------------------------------------------
    IF v_t.estatus = 'finalizado'::public.estatus_torneo THEN
        v_stage := 'FINALIZED';

    ELSIF v_any_scoring_pending THEN
        v_stage := 'SCORING';

    ELSIF v_any_cards_issued THEN
        v_stage := 'RESULTS';

    ELSIF v_frozen THEN
        v_stage := 'ROUND_PREPARATION';

    ELSIF v_t.estatus = 'inscripcion_cerrada'::public.estatus_torneo THEN
        v_stage := 'PRE_FREEZE';

    ELSIF v_t.estatus = 'inscripciones_abiertas'::public.estatus_torneo THEN
        v_stage := 'REGISTRATIONS';

    ELSE
        v_stage := 'CONFIGURATION';
    END IF;

    ---------------------------------------------------------------------------
    -- Warnings del freeze
    ---------------------------------------------------------------------------
    IF jsonb_array_length(
        COALESCE(v_freeze->'warnings', '[]'::jsonb)
    ) > 0 THEN
        v_warning_count := v_warning_count + 1;

        v_warnings := v_warnings || jsonb_build_array(
            jsonb_build_object(
                'code', 'FREEZE_WARNINGS',
                'scope', 'TOURNAMENT',
                'title', 'Advertencias del congelamiento',
                'status', 'WARNING',
                'message',
                    'El congelamiento se realizó con advertencias.',
                'recommendation',
                    'Revísalas; pueden ser informativas y no necesariamente bloqueantes.',
                'details', v_freeze->'warnings',
                'action', jsonb_build_object(
                    'label', 'Revisar congelamiento',
                    'target', 'condiciones-handicaps'
                )
            )
        );
    END IF;

    ---------------------------------------------------------------------------
    -- Primera acción pendiente/bloqueante
    ---------------------------------------------------------------------------
    SELECT elem->'action'
      INTO v_next_action
      FROM jsonb_array_elements(v_steps) elem
     WHERE elem->>'status' IN ('BLOCKED', 'PENDING')
     ORDER BY
        CASE elem->>'status'
            WHEN 'BLOCKED' THEN 0
            ELSE 1
        END
     LIMIT 1;

    RETURN jsonb_build_object(
        'schemaVersion', 2,
        'tournamentId', p_tournament_id,
        'tournamentName', v_t.nombre,
        'stage', v_stage,
        'status', jsonb_build_object(
            'tournamentStatus', v_t.estatus::text,
            'serviceStatus', v_t.estado_servicio::text,
            'active', v_t.activo,
            'configurationFinalized',
                v_t.configuracion_finalizada_at IS NOT NULL,
            'frozen', v_frozen
        ),
        'actor', jsonb_build_object(
            'isSuperadmin', v_is_superadmin,
            'isTournamentOrganizer', v_is_organizer,
            'canManageTournament', v_can_manage
        ),
        'progress', jsonb_build_object(
            'completed', v_completed,
            'total', v_total_steps,
            'percent',
                CASE
                    WHEN v_total_steps = 0 THEN 0
                    ELSE round(
                        100.0 * v_completed / v_total_steps,
                        0
                    )
                END
        ),
        'summary', jsonb_build_object(
            'blockingIssues', v_blocked,
            'warnings', v_warning_count,
            'registrations', v_registration_count,
            'activeRounds', jsonb_array_length(v_rounds)
        ),
        'nextAction', v_next_action,
        'blockers', v_blockers,
        'warnings', v_warnings,
        'steps', v_steps,
        'rounds', v_rounds
    );
END;
$function$;

REVOKE ALL
ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
TO authenticated;

COMMENT ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
IS
'Contrato de solo lectura para el Asistente Operativo del Torneo. '
'SchemaVersion 2 distingue resolución competitiva de cierre formal persistido '
'y usa stages operativos CONFIGURATION/REGISTRATIONS/PRE_FREEZE/ROUND_PREPARATION/SCORING/RESULTS/FINALIZED.';

COMMIT;
