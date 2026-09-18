-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 333
-- Workflow materializado: CONFIGURATION alineado con autoservicio
--
-- Requisito previo: Migración 332 ya ejecutada.
--
-- OBJETIVO
-- - No reescribir la 332.
-- - En autoservicio PAGADO, eliminar del workflow el requisito histórico
--   configuracion_finalizada_at/configuracion_finalizada_por.
-- - Mientras el torneo autoservicio siga PLANIFICADO, CONFIGURATION refleja
--   las mismas validaciones reales que abrir_inscripciones_torneo():
--     * validar_configuracion_minima_torneo()
--     * obtener_estado_configuracion_desempates_261()
-- - Si el autoservicio ya avanzó más allá de PLANIFICADO, CONFIGURATION es
--   COMPLETE porque el backend ya permitió cruzar la apertura de inscripciones.
-- - En torneos legacy se conserva configuracion_finalizada_at como evidencia.
-- - No cambia motores deportivos, lifecycle, Freeze, salidas, tarjetas,
--   captura, cierres ni las RPC históricas de configuración.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.reconstruir_workflow_torneo_332(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    t public.tournaments%ROWTYPE;
    r public.tournament_rounds%ROWTYPE;
    v_prev_complete boolean;
    v_status text;
    v_block text;
    v_freeze_count integer;
    v_reg_count integer;
    v_group_count integer;
    v_validation_count integer;
    v_emission_count integer;
    v_capture_count integer;
    v_cut_rule_count integer;
    v_cut_status_count integer;
    v_lifecycle_started timestamptz;
    v_lifecycle_completed timestamptz;
    v_round_close timestamptz;
    v_finalized_at timestamptz;
    v_nodes integer;

    -- 333
    v_autoservicio boolean := false;
    v_config_listo boolean := false;
    v_config_errores jsonb := '[]'::jsonb;
    v_tiebreak jsonb := '{}'::jsonb;
    v_tiebreak_complete boolean := false;
    v_configuration_complete boolean := false;
BEGIN
    SELECT * INTO t
    FROM public.tournaments
    WHERE id=p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Torneo no encontrado';
    END IF;

    DELETE FROM public.tournament_workflow_nodes n
    WHERE n.tournament_id=p_tournament_id
      AND n.scope='ROUND'
      AND NOT EXISTS (
          SELECT 1
          FROM public.tournament_rounds rr
          WHERE rr.id=n.tournament_round_id
            AND rr.tournament_id=p_tournament_id
            AND rr.activo=true
      );

    SELECT count(*) INTO v_reg_count
    FROM public.tournament_registrations
    WHERE tournament_id=p_tournament_id;

    SELECT count(*) INTO v_freeze_count
    FROM public.tournament_condition_freezes
    WHERE tournament_id=p_tournament_id;

    SELECT max(finalized_at) INTO v_finalized_at
    FROM public.tournament_competitive_finalizations
    WHERE tournament_id=p_tournament_id
      AND status='FINALIZED';

    -- ------------------------------------------------------------------------
    -- 333: Determinar si el torneo pertenece al flujo autoservicio vigente.
    -- La misma evidencia usada por abrir_inscripciones_torneo():
    -- contrato de plataforma PAGADO enlazado al torneo.
    -- ------------------------------------------------------------------------
    SELECT EXISTS (
        SELECT 1
        FROM public.platform_tournament_contracts c
        WHERE c.tournament_id=p_tournament_id
          AND c.contract_status::text='PAGADO'
    )
    INTO v_autoservicio;

    IF v_autoservicio THEN
        IF t.estatus::text IN (
            'inscripciones_abiertas',
            'inscripcion_cerrada',
            'en_curso',
            'finalizado',
            'cancelado'
        ) THEN
            -- El torneo ya cruzó la frontera que exige validación real.
            v_configuration_complete := true;
            v_config_listo := true;
            v_tiebreak_complete := true;
        ELSE
            SELECT v.listo, v.errores
            INTO v_config_listo, v_config_errores
            FROM public.validar_configuracion_minima_torneo(p_tournament_id) v;

            v_tiebreak :=
                public.obtener_estado_configuracion_desempates_261(
                    p_tournament_id
                );

            v_tiebreak_complete :=
                COALESCE((v_tiebreak->>'complete')::boolean,false);

            v_configuration_complete :=
                COALESCE(v_config_listo,false)
                AND v_tiebreak_complete;
        END IF;
    ELSE
        -- Compatibilidad legacy: conserva el hito histórico.
        v_configuration_complete :=
            t.configuracion_finalizada_at IS NOT NULL;
    END IF;

    -- 10 CONFIGURATION
    v_status :=
        CASE
            WHEN v_configuration_complete THEN 'COMPLETE'
            ELSE 'AVAILABLE'
        END;

    PERFORM public._upsert_workflow_node_332(
        p_tournament_id,
        NULL,
        'TOURNAMENT',
        'CONFIGURATION',
        10,
        v_status,
        NULL,
        'REGISTRATIONS',
        NULL,
        jsonb_build_object(
            'self_service',v_autoservicio,
            'configuration_ready',v_configuration_complete,
            'minimum_configuration_ready',v_config_listo,
            'minimum_configuration_errors',v_config_errores,
            'tiebreak_configuration_ready',v_tiebreak_complete,
            'configuracion_finalizada_at',t.configuracion_finalizada_at,
            'tournament_status',t.estatus::text
        ),
        CASE
            WHEN v_configuration_complete AND v_autoservicio
                THEN 'Configuración operativamente lista para autoservicio.'
            WHEN v_configuration_complete
                THEN 'Configuración finalizada.'
            WHEN v_autoservicio
                THEN 'Configuración incompleta para abrir inscripciones.'
            ELSE 'Configuración pendiente.'
        END,
        CASE
            WHEN NOT v_autoservicio THEN t.configuracion_finalizada_at
            ELSE NULL
        END
    );

    -- 20 REGISTRATIONS
    -- En autoservicio se bloquea sólo si la configuración REAL aún no permite
    -- abrir inscripciones. En legacy conserva el hito manual.
    v_status :=
        CASE
            WHEN t.estatus::text IN (
                'inscripcion_cerrada','en_curso','finalizado','cancelado'
            ) THEN 'COMPLETE'
            WHEN t.estatus::text='inscripciones_abiertas' THEN 'AVAILABLE'
            WHEN NOT v_configuration_complete THEN 'BLOCKED'
            ELSE 'AVAILABLE'
        END;

    v_block :=
        CASE
            WHEN NOT v_configuration_complete THEN 'CONFIGURATION'
            ELSE NULL
        END;

    PERFORM public._upsert_workflow_node_332(
        p_tournament_id,NULL,'TOURNAMENT','REGISTRATIONS',20,
        v_status,'CONFIGURATION','FREEZE',v_block,
        jsonb_build_object(
            'registration_count',v_reg_count,
            'tournament_status',t.estatus::text,
            'self_service',v_autoservicio,
            'configuration_ready',v_configuration_complete
        ),
        CASE
            WHEN v_status='COMPLETE'
                THEN 'Inscripciones cerradas o ciclo ya avanzado.'
            WHEN v_status='BLOCKED'
                THEN 'Requiere completar la configuración necesaria para abrir inscripciones.'
            ELSE 'Inscripciones disponibles.'
        END,
        NULL
    );

    -- 30 FREEZE
    v_status := CASE
      WHEN v_freeze_count>0 THEN 'COMPLETE'
      WHEN t.estatus::text NOT IN ('inscripcion_cerrada','en_curso','finalizado','cancelado') THEN 'BLOCKED'
      ELSE 'AVAILABLE' END;
    v_block := CASE
      WHEN v_freeze_count=0
       AND t.estatus::text NOT IN ('inscripcion_cerrada','en_curso','finalizado','cancelado')
      THEN 'REGISTRATIONS' END;

    PERFORM public._upsert_workflow_node_332(
      p_tournament_id,NULL,'TOURNAMENT','FREEZE',30,v_status,
      'REGISTRATIONS','START_TOURNAMENT',v_block,
      jsonb_build_object('freeze_count',v_freeze_count),
      CASE
        WHEN v_freeze_count>0 THEN 'Condiciones congeladas.'
        WHEN v_status='BLOCKED' THEN 'Requiere cierre de inscripciones.'
        ELSE 'Freeze disponible.'
      END,
      (SELECT max(frozen_at)
       FROM public.tournament_condition_freezes
       WHERE tournament_id=p_tournament_id)
    );

    -- 40 START_TOURNAMENT
    v_status := CASE
      WHEN t.estatus::text IN ('en_curso','finalizado') THEN 'COMPLETE'
      WHEN v_freeze_count=0 THEN 'BLOCKED'
      ELSE 'AVAILABLE' END;
    v_block := CASE WHEN v_freeze_count=0 THEN 'FREEZE' END;

    PERFORM public._upsert_workflow_node_332(
      p_tournament_id,NULL,'TOURNAMENT','START_TOURNAMENT',40,v_status,
      'FREEZE','TOURNAMENT_FINALIZATION',v_block,
      jsonb_build_object('tournament_status',t.estatus::text),
      CASE
        WHEN v_status='COMPLETE' THEN 'Torneo iniciado.'
        WHEN v_status='BLOCKED' THEN 'Requiere Freeze.'
        ELSE 'Inicio sujeto a validaciones operativas existentes.'
      END,NULL
    );

    -- RONDAS ACTIVAS: se conserva literalmente la proyección de 332.
    v_prev_complete := true;

    FOR r IN
        SELECT *
        FROM public.tournament_rounds
        WHERE tournament_id=p_tournament_id
          AND activo=true
        ORDER BY numero_ronda,id
    LOOP
        SELECT count(*) INTO v_group_count
        FROM public.tournament_groups g
        JOIN public.tournament_round_shifts s
          ON s.id=g.tournament_round_shift_id
        WHERE s.tournament_round_id=r.id
          AND g.activo=true;

        SELECT count(*) INTO v_validation_count
        FROM public.tournament_round_start_validations
        WHERE tournament_round_id=r.id
          AND status='validated'
          AND reopened_at IS NULL;

        SELECT count(*) INTO v_emission_count
        FROM public.tournament_score_card_emissions
        WHERE tournament_round_id=r.id
          AND status='issued'
          AND voided_at IS NULL;

        SELECT count(*) INTO v_capture_count
        FROM public.tournament_scorecard_capture_sessions
        WHERE tournament_round_id=r.id
          AND status IN ('ready','in_progress','captured');

        SELECT started_at,completed_at
        INTO v_lifecycle_started,v_lifecycle_completed
        FROM public.tournament_round_lifecycle
        WHERE tournament_round_id=r.id
        LIMIT 1;

        SELECT max(closed_at) INTO v_round_close
        FROM public.tournament_round_competitive_closures
        WHERE tournament_round_id=r.id
          AND competitive_status='FINAL';

        SELECT count(*) INTO v_cut_rule_count
        FROM public.tournament_cut_rules
        WHERE despues_de_ronda_id=r.id
          AND activo=true;

        SELECT count(*) INTO v_cut_status_count
        FROM public.tournament_cut_player_statuses
        WHERE cut_after_round_id=r.id;

        v_status := CASE
          WHEN r.campo_golf_id IS NOT NULL AND r.formato_salida IS NOT NULL
            THEN 'COMPLETE'
          ELSE 'AVAILABLE' END;

        PERFORM public._upsert_workflow_node_332(
          p_tournament_id,r.id,'ROUND','ROUND_CONFIGURATION',
          100+r.numero_ronda*100,v_status,NULL,'ROUND_GROUPS',NULL,
          jsonb_build_object(
            'round_number',r.numero_ronda,'date',r.fecha,
            'start_format',r.formato_salida::text,'course_id',r.campo_golf_id
          ),
          CASE WHEN v_status='COMPLETE'
            THEN 'Ronda configurada.'
            ELSE 'Configuración de ronda pendiente.' END,NULL
        );

        v_status := CASE
          WHEN v_group_count>0 THEN 'COMPLETE'
          WHEN v_freeze_count=0 THEN 'BLOCKED'
          ELSE 'AVAILABLE' END;
        v_block := CASE
          WHEN v_group_count=0 AND v_freeze_count=0 THEN 'FREEZE' END;

        PERFORM public._upsert_workflow_node_332(
          p_tournament_id,r.id,'ROUND','ROUND_GROUPS',
          110+r.numero_ronda*100,v_status,
          'ROUND_CONFIGURATION','ROUND_STARTS',v_block,
          jsonb_build_object(
            'group_count',v_group_count,'start_format',r.formato_salida::text
          ),
          CASE
            WHEN v_group_count>0 THEN 'Grupos materializados.'
            WHEN v_status='BLOCKED' THEN 'Requiere Freeze.'
            ELSE 'Armado de grupos disponible.'
          END,NULL
        );

        v_status := CASE
          WHEN v_validation_count>0 THEN 'COMPLETE'
          WHEN v_group_count=0 THEN 'BLOCKED'
          ELSE 'AVAILABLE' END;
        v_block := CASE
          WHEN v_validation_count=0 AND v_group_count=0 THEN 'ROUND_GROUPS' END;

        PERFORM public._upsert_workflow_node_332(
          p_tournament_id,r.id,'ROUND','ROUND_STARTS',
          120+r.numero_ronda*100,v_status,
          'ROUND_GROUPS','SCORECARD_EMISSION',v_block,
          jsonb_build_object('active_validations',v_validation_count),
          CASE
            WHEN v_validation_count>0 THEN 'Salidas validadas.'
            WHEN v_status='BLOCKED' THEN 'Requiere grupos.'
            ELSE 'Validación de salidas disponible.'
          END,NULL
        );

        v_status := CASE
          WHEN v_emission_count>0 THEN 'COMPLETE'
          WHEN v_validation_count=0 THEN 'BLOCKED'
          ELSE 'AVAILABLE' END;
        v_block := CASE
          WHEN v_emission_count=0 AND v_validation_count=0 THEN 'ROUND_STARTS' END;

        PERFORM public._upsert_workflow_node_332(
          p_tournament_id,r.id,'ROUND','SCORECARD_EMISSION',
          130+r.numero_ronda*100,v_status,
          'ROUND_STARTS','ROUND_SCORING_INIT',v_block,
          jsonb_build_object('active_emissions',v_emission_count),
          CASE
            WHEN v_emission_count>0 THEN 'Tarjetas emitidas.'
            WHEN v_status='BLOCKED' THEN 'Requiere salidas validadas.'
            ELSE 'Emisión disponible.'
          END,NULL
        );

        v_status := CASE
          WHEN v_capture_count>0 THEN 'COMPLETE'
          WHEN v_emission_count=0 THEN 'BLOCKED'
          ELSE 'AVAILABLE' END;
        v_block := CASE
          WHEN v_capture_count=0 AND v_emission_count=0
          THEN 'SCORECARD_EMISSION' END;

        PERFORM public._upsert_workflow_node_332(
          p_tournament_id,r.id,'ROUND','ROUND_SCORING_INIT',
          140+r.numero_ronda*100,v_status,
          'SCORECARD_EMISSION','ROUND_PLAY',v_block,
          jsonb_build_object('capture_sessions',v_capture_count),
          CASE
            WHEN v_capture_count>0 THEN 'Captura inicializada.'
            WHEN v_status='BLOCKED' THEN 'Requiere tarjetas emitidas.'
            ELSE 'Inicialización de captura disponible.'
          END,NULL
        );

        v_status := CASE
          WHEN v_lifecycle_completed IS NOT NULL THEN 'COMPLETE'
          WHEN v_lifecycle_started IS NOT NULL THEN 'IN_PROGRESS'
          WHEN NOT v_prev_complete THEN 'BLOCKED'
          WHEN v_capture_count=0 THEN 'BLOCKED'
          ELSE 'AVAILABLE' END;
        v_block := CASE
          WHEN v_lifecycle_started IS NULL AND NOT v_prev_complete
            THEN 'PREVIOUS_ROUND_CLOSE'
          WHEN v_lifecycle_started IS NULL AND v_capture_count=0
            THEN 'ROUND_SCORING_INIT' END;

        PERFORM public._upsert_workflow_node_332(
          p_tournament_id,r.id,'ROUND','ROUND_PLAY',
          150+r.numero_ronda*100,v_status,
          'ROUND_SCORING_INIT','ROUND_COMPETITIVE_CLOSE',v_block,
          jsonb_build_object(
            'started_at',v_lifecycle_started,
            'completed_at',v_lifecycle_completed,
            'previous_round_complete',v_prev_complete
          ),
          CASE
            WHEN v_lifecycle_completed IS NOT NULL THEN 'Ronda finalizada.'
            WHEN v_lifecycle_started IS NOT NULL THEN 'Ronda en juego.'
            WHEN v_status='BLOCKED' THEN 'Ronda bloqueada por antecedente operativo.'
            ELSE 'Ronda disponible para iniciar.'
          END,v_lifecycle_completed
        );

        v_status := CASE
          WHEN v_round_close IS NOT NULL THEN 'COMPLETE'
          WHEN v_lifecycle_started IS NULL THEN 'BLOCKED'
          ELSE 'AVAILABLE' END;
        v_block := CASE
          WHEN v_round_close IS NULL AND v_lifecycle_started IS NULL
          THEN 'ROUND_PLAY' END;

        PERFORM public._upsert_workflow_node_332(
          p_tournament_id,r.id,'ROUND','ROUND_COMPETITIVE_CLOSE',
          160+r.numero_ronda*100,v_status,
          'ROUND_PLAY',
          CASE WHEN v_cut_rule_count>0 THEN 'ROUND_CUT' ELSE NULL END,
          v_block,
          jsonb_build_object('closed_at',v_round_close),
          CASE
            WHEN v_round_close IS NOT NULL THEN 'Cierre competitivo registrado.'
            WHEN v_status='BLOCKED' THEN 'Requiere ronda iniciada y requisitos de cierre.'
            ELSE 'Cierre sujeto a validaciones deportivas existentes.'
          END,v_round_close
        );

        IF v_cut_rule_count>0 THEN
            v_status := CASE
              WHEN v_cut_status_count>0 THEN 'COMPLETE'
              WHEN v_round_close IS NULL THEN 'BLOCKED'
              ELSE 'AVAILABLE' END;
            v_block := CASE
              WHEN v_cut_status_count=0 AND v_round_close IS NULL
              THEN 'ROUND_COMPETITIVE_CLOSE' END;

            PERFORM public._upsert_workflow_node_332(
              p_tournament_id,r.id,'ROUND','ROUND_CUT',
              170+r.numero_ronda*100,v_status,
              'ROUND_COMPETITIVE_CLOSE',NULL,v_block,
              jsonb_build_object(
                'active_cut_rules',v_cut_rule_count,
                'cut_status_rows',v_cut_status_count
              ),
              CASE
                WHEN v_cut_status_count>0 THEN 'Corte materializado.'
                WHEN v_status='BLOCKED' THEN 'Requiere cierre de ronda.'
                ELSE 'Corte configurado y pendiente de aplicación.'
              END,NULL
            );
        ELSE
            DELETE FROM public.tournament_workflow_nodes
            WHERE tournament_id=p_tournament_id
              AND tournament_round_id=r.id
              AND code='ROUND_CUT';
        END IF;

        v_prev_complete := (v_round_close IS NOT NULL);
    END LOOP;

    -- 900 TOURNAMENT_FINALIZATION
    v_status := CASE
      WHEN v_finalized_at IS NOT NULL OR t.estatus::text='finalizado'
        THEN 'COMPLETE'
      WHEN EXISTS (
          SELECT 1 FROM public.tournament_rounds rr
          WHERE rr.tournament_id=p_tournament_id AND rr.activo=true
      )
       AND NOT EXISTS (
          SELECT 1
          FROM public.tournament_rounds rr
          WHERE rr.tournament_id=p_tournament_id
            AND rr.activo=true
            AND NOT EXISTS (
                SELECT 1
                FROM public.tournament_round_competitive_closures c
                WHERE c.tournament_round_id=rr.id
                  AND c.competitive_status='FINAL'
            )
       ) THEN 'AVAILABLE'
      ELSE 'BLOCKED' END;

    v_block := CASE
      WHEN v_status='BLOCKED' THEN 'ROUND_COMPETITIVE_CLOSE' END;

    PERFORM public._upsert_workflow_node_332(
      p_tournament_id,NULL,'TOURNAMENT','TOURNAMENT_FINALIZATION',
      900,v_status,'START_TOURNAMENT',NULL,v_block,
      jsonb_build_object(
        'finalized_at',v_finalized_at,'tournament_status',t.estatus::text
      ),
      CASE
        WHEN v_status='COMPLETE' THEN 'Torneo finalizado.'
        WHEN v_status='AVAILABLE'
          THEN 'Todas las rondas tienen cierre competitivo; finalización sujeta a validaciones existentes.'
        ELSE 'Existen rondas pendientes de cierre.'
      END,v_finalized_at
    );

    SELECT count(*) INTO v_nodes
    FROM public.tournament_workflow_nodes
    WHERE tournament_id=p_tournament_id;

    RETURN jsonb_build_object(
        'ok',true,
        'tournament_id',p_tournament_id,
        'node_count',v_nodes,
        'reconciled_at',now()
    );
END;
$function$;

-- Reconstruir la proyección de todos los torneos no cancelados.
DO $$
DECLARE
    x record;
BEGIN
    FOR x IN
        SELECT id
        FROM public.tournaments
        WHERE estatus::text <> 'cancelado'
        ORDER BY created_at,id
    LOOP
        PERFORM public.reconstruir_workflow_torneo_332(x.id);
    END LOOP;
END $$;

COMMIT;
