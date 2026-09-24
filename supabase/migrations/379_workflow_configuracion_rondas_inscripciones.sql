BEGIN;

-- TEE CENTRAL / GOLF IN FULL
-- Migración 379
-- Corrige el flujo moderno de apertura de inscripciones y el orden del Asistente:
-- CONFIGURACIÓN -> FRANJAS HCP -> DESEMPATES -> RONDAS -> INSCRIPCIONES -> FREEZE.
-- No elimina el hito legacy configuracion_finalizada_at; simplemente deja de ser
-- requisito para abrir inscripciones en el flujo operativo vigente.

CREATE OR REPLACE FUNCTION public._estado_apertura_inscripciones_379(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
    v_min_ready boolean := false;
    v_min_errors jsonb := '[]'::jsonb;
    v_hcp jsonb := '{}'::jsonb;
    v_tiebreak jsonb := '{}'::jsonb;
    v_declared integer := 0;
    v_active integer := 0;
    v_missing integer[] := ARRAY[]::integer[];
    v_rounds_ready boolean := false;
    v_base_ready boolean := false;
    v_categories integer := 0;
    v_bad_category_caps integer := 0;
    v_category_capacity bigint := 0;
    v_course_club uuid;
BEGIN
    SELECT * INTO v_t
      FROM public.tournaments
     WHERE id=p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='22023';
    END IF;

    SELECT count(*)::integer,
           count(*) FILTER (WHERE cupo_maximo IS NULL OR cupo_maximo<=0)::integer,
           COALESCE(sum(cupo_maximo),0)
      INTO v_categories,v_bad_category_caps,v_category_capacity
      FROM public.tournament_categories
     WHERE tournament_id=p_tournament_id;

    IF v_t.campo_golf_id IS NOT NULL THEN
        SELECT club_id INTO v_course_club
          FROM public.campos_golf
         WHERE id=v_t.campo_golf_id;
    END IF;

    -- CONFIGURATION representa sólo la configuración general del torneo.
    -- Franjas, desempates y estructura de rondas tienen nodos propios.
    v_base_ready :=
        v_t.campo_golf_id IS NOT NULL
        AND v_course_club IS NOT NULL
        AND v_t.club_id IS NOT DISTINCT FROM v_course_club
        AND v_t.tournament_format_id IS NOT NULL
        AND v_t.cupo_maximo IS NOT NULL AND v_t.cupo_maximo>0
        AND v_t.numero_rondas IS NOT NULL AND v_t.numero_rondas>0
        AND v_categories>0
        AND v_bad_category_caps=0
        AND v_category_capacity=v_t.cupo_maximo;

    v_hcp := public.validar_franjas_handicap_torneo(p_tournament_id);
    v_tiebreak := public.obtener_estado_configuracion_desempates_261(p_tournament_id);

    v_declared := COALESCE(v_t.numero_rondas,0);

    SELECT count(*)::integer
      INTO v_active
      FROM public.tournament_rounds r
     WHERE r.tournament_id=p_tournament_id
       AND r.activo=true
       AND r.numero_ronda BETWEEN 1 AND v_declared;

    IF v_declared>0 THEN
        SELECT COALESCE(array_agg(gs ORDER BY gs),ARRAY[]::integer[])
          INTO v_missing
          FROM generate_series(1,v_declared) gs
         WHERE NOT EXISTS (
             SELECT 1
               FROM public.tournament_rounds r
              WHERE r.tournament_id=p_tournament_id
                AND r.numero_ronda=gs
                AND r.activo=true
         );
    END IF;

    v_rounds_ready := v_declared>0 AND cardinality(v_missing)=0 AND v_active=v_declared;

    -- Conservamos validar_configuracion_minima_torneo como última autoridad de
    -- integridad para la apertura. Así no debilitamos validaciones históricas.
    SELECT v.listo,v.errores
      INTO v_min_ready,v_min_errors
      FROM public.validar_configuracion_minima_torneo(p_tournament_id) v;

    RETURN jsonb_build_object(
        'baseConfigurationReady',v_base_ready,
        'handicapRangesReady',COALESCE((v_hcp->>'valid')::boolean,false),
        'handicapRanges',v_hcp,
        'tiebreakReady',COALESCE((v_tiebreak->>'complete')::boolean,false),
        'tiebreak',v_tiebreak,
        'roundStructureReady',v_rounds_ready,
        'declaredRounds',v_declared,
        'activeRounds',v_active,
        'missingRounds',to_jsonb(v_missing),
        'minimumConfigurationReady',COALESCE(v_min_ready,false),
        'minimumConfigurationErrors',COALESCE(v_min_errors,'[]'::jsonb),
        'readyToOpen',
            v_base_ready
            AND COALESCE((v_hcp->>'valid')::boolean,false)
            AND COALESCE((v_tiebreak->>'complete')::boolean,false)
            AND v_rounds_ready
            AND COALESCE(v_min_ready,false)
    );
END;
$function$;

REVOKE ALL ON FUNCTION public._estado_apertura_inscripciones_379(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._estado_apertura_inscripciones_379(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.abrir_inscripciones_torneo(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
    v_ready jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(),p_tournament_id)
    ) THEN
        RAISE EXCEPTION 'Sólo el organizador asignado o el Superadmin pueden abrir inscripciones.'
            USING ERRCODE='42501';
    END IF;

    SELECT * INTO v_t
      FROM public.tournaments
     WHERE id=p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='22023';
    END IF;

    IF v_t.estatus='inscripciones_abiertas'::public.estatus_torneo THEN
        RETURN jsonb_build_object('ok',true,'tournamentId',p_tournament_id,
                                  'alreadyOpen',true,'estatus',v_t.estatus::text);
    END IF;

    IF v_t.estatus<>'planificado'::public.estatus_torneo THEN
        RAISE EXCEPTION 'Las inscripciones sólo pueden abrirse desde EN PLANIFICACIÓN. Estado actual: %.',v_t.estatus
            USING ERRCODE='23514';
    END IF;

    IF v_t.estado_servicio<>'activo'::public.estado_servicio_torneo
       OR v_t.activo IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'No se pueden abrir inscripciones: el torneo todavía no está activo en TEE CENTRAL.'
            USING ERRCODE='23514',
                  DETAIL=format('estado_servicio=%s; activo=%s',v_t.estado_servicio,v_t.activo);
    END IF;

    v_ready := public._estado_apertura_inscripciones_379(p_tournament_id);

    IF NOT COALESCE((v_ready->>'baseConfigurationReady')::boolean,false) THEN
        RAISE EXCEPTION 'No se pueden abrir inscripciones: la configuración general del torneo todavía no está completa. %',v_ready::text
            USING ERRCODE='23514';
    END IF;

    IF NOT COALESCE((v_ready->>'handicapRangesReady')::boolean,false) THEN
        RAISE EXCEPTION 'No se pueden abrir inscripciones: las franjas de hándicap faltan o son inválidas. %',
            COALESCE((v_ready->'handicapRanges'->'errors')::text,'[]') USING ERRCODE='23514';
    END IF;

    IF NOT COALESCE((v_ready->>'tiebreakReady')::boolean,false) THEN
        RAISE EXCEPTION 'No se pueden abrir inscripciones: faltan o son inconsistentes las reglas de desempate. %',
            COALESCE((v_ready->'tiebreak')::text,'{}') USING ERRCODE='23514';
    END IF;

    IF NOT COALESCE((v_ready->>'roundStructureReady')::boolean,false) THEN
        RAISE EXCEPTION 'No se pueden abrir inscripciones: primero deben existir y estar activas todas las rondas declaradas. %',
            jsonb_build_object('declaredRounds',v_ready->'declaredRounds','activeRounds',v_ready->'activeRounds','missingRounds',v_ready->'missingRounds')::text
            USING ERRCODE='23514';
    END IF;

    IF NOT COALESCE((v_ready->>'minimumConfigurationReady')::boolean,false) THEN
        RAISE EXCEPTION 'No se pueden abrir inscripciones: la configuración del torneo todavía no está completa. %',
            COALESCE((v_ready->'minimumConfigurationErrors')::text,'[]') USING ERRCODE='23514';
    END IF;

    PERFORM set_config('app.permitir_cambio_estatus_torneo','1',true);

    UPDATE public.tournaments
       SET estatus='inscripciones_abiertas'::public.estatus_torneo
     WHERE id=p_tournament_id;

    RETURN jsonb_build_object(
        'ok',true,
        'tournamentId',p_tournament_id,
        'alreadyOpen',false,
        'configurationValidation','REAL_STATE_379',
        'estatusAnterior','planificado',
        'estatus','inscripciones_abiertas'
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.abrir_inscripciones_torneo(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.abrir_inscripciones_torneo(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.reconstruir_workflow_extendido_341(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base jsonb;
    v_ready jsonb;
    v_t public.tournaments%ROWTYPE;
    v_has_freeze boolean;
    v_reg_status text;
    v_round_status text;
    v_nodes integer;
BEGIN
    -- Conserva todo el workflow deportivo/operativo ya existente.
    v_base := public.reconstruir_workflow_extendido_337(p_tournament_id);

    SELECT * INTO v_t
      FROM public.tournaments
     WHERE id=p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='22023';
    END IF;

    v_ready := public._estado_apertura_inscripciones_379(p_tournament_id);

    SELECT EXISTS(
        SELECT 1 FROM public.tournament_condition_freezes f
        WHERE f.tournament_id=p_tournament_id
    ) INTO v_has_freeze;

    -- 10 CONFIGURATION: configuración general, sin absorber HCP/desempates/rondas.
    PERFORM public._upsert_workflow_node_332(
        p_tournament_id,NULL,'TOURNAMENT','CONFIGURATION',10,
        CASE WHEN COALESCE((v_ready->>'baseConfigurationReady')::boolean,false)
             THEN 'COMPLETE' ELSE 'AVAILABLE' END,
        NULL,'HANDICAP_RANGES',NULL,
        jsonb_build_object(
            'source','REAL_STATE_379',
            'configuration_ready',COALESCE((v_ready->>'baseConfigurationReady')::boolean,false),
            'configuracion_finalizada_at',v_t.configuracion_finalizada_at,
            'legacy_confirmation_required',false,
            'tournament_status',v_t.estatus::text
        ),
        CASE WHEN COALESCE((v_ready->>'baseConfigurationReady')::boolean,false)
             THEN 'Configuración general completa.'
             ELSE 'Configuración general pendiente.' END,
        CASE WHEN COALESCE((v_ready->>'baseConfigurationReady')::boolean,false) THEN now() ELSE NULL END
    );

    -- Cadena explícita: CONFIGURATION -> HCP -> TIEBREAK -> ROUND_STRUCTURE -> REGISTRATIONS -> FREEZE.
    UPDATE public.tournament_workflow_nodes
       SET sequence_no=12, previous_code='CONFIGURATION', next_code='TIEBREAK_CONFIGURATION', updated_at=now()
     WHERE tournament_id=p_tournament_id AND scope='TOURNAMENT'
       AND tournament_round_id IS NULL AND code='HANDICAP_RANGES';

    UPDATE public.tournament_workflow_nodes
       SET sequence_no=14, previous_code='HANDICAP_RANGES', next_code='ROUND_STRUCTURE', updated_at=now()
     WHERE tournament_id=p_tournament_id AND scope='TOURNAMENT'
       AND tournament_round_id IS NULL AND code='TIEBREAK_CONFIGURATION';

    v_round_status := CASE
        WHEN COALESCE((v_ready->>'roundStructureReady')::boolean,false) THEN 'COMPLETE'
        WHEN v_has_freeze THEN 'BLOCKED'
        WHEN NOT COALESCE((v_ready->>'baseConfigurationReady')::boolean,false) THEN 'BLOCKED'
        WHEN NOT COALESCE((v_ready->>'handicapRangesReady')::boolean,false) THEN 'BLOCKED'
        WHEN NOT COALESCE((v_ready->>'tiebreakReady')::boolean,false) THEN 'BLOCKED'
        ELSE 'AVAILABLE'
    END;

    PERFORM public._upsert_workflow_node_332(
        p_tournament_id,NULL,'TOURNAMENT','ROUND_STRUCTURE',16,v_round_status,
        'TIEBREAK_CONFIGURATION','REGISTRATIONS',
        CASE
            WHEN v_has_freeze AND v_round_status<>'COMPLETE' THEN 'FREEZE'
            WHEN NOT COALESCE((v_ready->>'baseConfigurationReady')::boolean,false) THEN 'CONFIGURATION'
            WHEN NOT COALESCE((v_ready->>'handicapRangesReady')::boolean,false) THEN 'HANDICAP_RANGES'
            WHEN NOT COALESCE((v_ready->>'tiebreakReady')::boolean,false) THEN 'TIEBREAK_CONFIGURATION'
            ELSE NULL
        END,
        jsonb_build_object(
            'source','ROUND_STRUCTURE_379',
            'declaredRounds',v_ready->'declaredRounds',
            'activeRounds',v_ready->'activeRounds',
            'missingRounds',v_ready->'missingRounds',
            'hasFreeze',v_has_freeze,
            'requiredBeforeRegistrations',true
        ),
        CASE
            WHEN COALESCE((v_ready->>'roundStructureReady')::boolean,false)
                THEN format('Las %s ronda(s) declaradas están creadas y activas.',v_ready->>'declaredRounds')
            WHEN v_has_freeze THEN 'El torneo ya está congelado y la estructura de rondas requiere revisión administrativa.'
            WHEN jsonb_array_length(COALESCE(v_ready->'missingRounds','[]'::jsonb))>0
                THEN format('Antes de abrir inscripciones deben existir las %s ronda(s) declaradas. Faltan: %s.',
                            v_ready->>'declaredRounds',v_ready->'missingRounds')
            ELSE 'Define y crea la estructura de rondas antes de abrir inscripciones.'
        END,
        CASE WHEN COALESCE((v_ready->>'roundStructureReady')::boolean,false) THEN now() ELSE NULL END
    );

    v_reg_status := CASE
        WHEN v_t.estatus::text IN ('inscripcion_cerrada','en_curso','finalizado','cancelado') THEN 'COMPLETE'
        WHEN v_t.estatus::text='inscripciones_abiertas' THEN 'AVAILABLE'
        WHEN NOT COALESCE((v_ready->>'baseConfigurationReady')::boolean,false) THEN 'BLOCKED'
        WHEN NOT COALESCE((v_ready->>'handicapRangesReady')::boolean,false) THEN 'BLOCKED'
        WHEN NOT COALESCE((v_ready->>'tiebreakReady')::boolean,false) THEN 'BLOCKED'
        WHEN NOT COALESCE((v_ready->>'roundStructureReady')::boolean,false) THEN 'BLOCKED'
        WHEN NOT COALESCE((v_ready->>'minimumConfigurationReady')::boolean,false) THEN 'BLOCKED'
        ELSE 'AVAILABLE'
    END;

    PERFORM public._upsert_workflow_node_332(
        p_tournament_id,NULL,'TOURNAMENT','REGISTRATIONS',20,v_reg_status,
        'ROUND_STRUCTURE','FREEZE',
        CASE
            WHEN v_reg_status<>'BLOCKED' THEN NULL
            WHEN NOT COALESCE((v_ready->>'baseConfigurationReady')::boolean,false) THEN 'CONFIGURATION'
            WHEN NOT COALESCE((v_ready->>'handicapRangesReady')::boolean,false) THEN 'HANDICAP_RANGES'
            WHEN NOT COALESCE((v_ready->>'tiebreakReady')::boolean,false) THEN 'TIEBREAK_CONFIGURATION'
            WHEN NOT COALESCE((v_ready->>'roundStructureReady')::boolean,false) THEN 'ROUND_STRUCTURE'
            ELSE 'CONFIGURATION'
        END,
        jsonb_build_object(
            'source','REAL_STATE_379',
            'registration_count',(SELECT count(*) FROM public.tournament_registrations WHERE tournament_id=p_tournament_id AND activo=true),
            'tournament_status',v_t.estatus::text,
            'configuration_ready',COALESCE((v_ready->>'readyToOpen')::boolean,false),
            'legacy_confirmation_required',false
        ),
        CASE
            WHEN v_reg_status='COMPLETE' THEN 'Inscripciones cerradas o ciclo ya avanzado.'
            WHEN v_reg_status='AVAILABLE' AND v_t.estatus::text='inscripciones_abiertas' THEN 'Inscripciones abiertas.'
            WHEN v_reg_status='AVAILABLE' THEN 'Inscripciones disponibles para abrir.'
            WHEN NOT COALESCE((v_ready->>'roundStructureReady')::boolean,false)
                THEN 'Requiere completar la estructura de rondas antes de abrir inscripciones.'
            ELSE 'Requiere completar la configuración necesaria para abrir inscripciones.'
        END,
        NULL
    );

    UPDATE public.tournament_workflow_nodes
       SET sequence_no=30, previous_code='REGISTRATIONS', updated_at=now()
     WHERE tournament_id=p_tournament_id AND scope='TOURNAMENT'
       AND tournament_round_id IS NULL AND code='FREEZE';

    SELECT count(*)::integer INTO v_nodes
      FROM public.tournament_workflow_nodes
     WHERE tournament_id=p_tournament_id;

    RETURN jsonb_build_object(
        'ok',true,
        'tournament_id',p_tournament_id,
        'node_count',v_nodes,
        'base',v_base,
        'extended_version',379,
        'workflow_order','CONFIGURATION>HANDICAP_RANGES>TIEBREAK_CONFIGURATION>ROUND_STRUCTURE>REGISTRATIONS>FREEZE',
        'opening_state',v_ready,
        'reconciled_at',now()
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.reconstruir_workflow_extendido_341(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reconstruir_workflow_extendido_341(uuid) TO authenticated, service_role;

COMMIT;
