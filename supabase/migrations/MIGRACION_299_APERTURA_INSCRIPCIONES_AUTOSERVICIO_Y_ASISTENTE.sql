-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 299
-- Apertura de inscripciones en autoservicio + congruencia del Asistente Operativo
--
-- Objetivo:
-- 1) Los torneos creados por contratación de plataforma PAGADA no requieren
--    una confirmación manual de configuración antes de abrir inscripciones.
-- 2) En autoservicio, ABRIR INSCRIPCIONES valida directamente la configuración
--    real del torneo y los desempates en ese momento.
-- 3) El flujo histórico/provisionado conserva la exigencia de
--    configuracion_finalizada_at/configuracion_finalizada_por.
-- 4) El Asistente Operativo elimina el paso CONFIRMAR CONFIGURACIÓN sólo para
--    autoservicio y ajusta sus mensajes/avance/nextAction.
--
-- IMPORTANTE: ejecutar manualmente en Supabase.

BEGIN;

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
    v_franjas jsonb;
    v_autoservicio boolean := false;
    v_config_listo boolean := false;
    v_config_errores jsonb := '[]'::jsonb;
    v_tiebreak jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(), p_tournament_id)
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden abrir inscripciones.'
            USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE='22023';
    END IF;

    IF v_t.estatus='inscripciones_abiertas'::public.estatus_torneo THEN
        RETURN jsonb_build_object(
            'ok', true,
            'tournamentId', p_tournament_id,
            'alreadyOpen', true,
            'estatus', v_t.estatus::text
        );
    END IF;

    IF v_t.estatus<>'planificado'::public.estatus_torneo THEN
        RAISE EXCEPTION
            'Las inscripciones sólo pueden abrirse desde EN PLANIFICACIÓN. Estado actual: %.',
            v_t.estatus
            USING ERRCODE='23514';
    END IF;

    -- Un torneo es autoservicio únicamente si existe una contratación de
    -- plataforma PAGADA enlazada al torneo. No se infiere por estado_servicio.
    SELECT EXISTS (
        SELECT 1
          FROM public.platform_tournament_contracts c
         WHERE c.tournament_id = p_tournament_id
           AND c.contract_status::text = 'PAGADO'
    )
      INTO v_autoservicio;

    IF v_autoservicio THEN
        -- En autoservicio ya no existe el hito manual "Confirmar configuración".
        -- Se valida la configuración real justo al abrir inscripciones.
        SELECT v.listo, v.errores
          INTO v_config_listo, v_config_errores
          FROM public.validar_configuracion_minima_torneo(p_tournament_id) v;

        IF NOT COALESCE(v_config_listo, false) THEN
            RAISE EXCEPTION
                'No se pueden abrir inscripciones: la configuración del torneo todavía no está completa. %',
                COALESCE(v_config_errores, '[]'::jsonb)::text
                USING ERRCODE='23514';
        END IF;

        v_tiebreak := public.obtener_estado_configuracion_desempates_261(
            p_tournament_id
        );

        IF NOT COALESCE((v_tiebreak->>'complete')::boolean, false) THEN
            RAISE EXCEPTION
                'No se pueden abrir inscripciones: faltan o son inconsistentes las reglas de desempate. %',
                v_tiebreak::text
                USING ERRCODE='23514';
        END IF;
    ELSE
        -- Flujo histórico: se conserva el contrato operativo anterior.
        IF v_t.configuracion_finalizada_at IS NULL
           OR v_t.configuracion_finalizada_por IS NULL
        THEN
            RAISE EXCEPTION
                'No se pueden abrir inscripciones: la configuración del torneo aún no está finalizada.'
                USING ERRCODE='23514';
        END IF;
    END IF;

    -- Se conserva la validación explícita de franjas para ambos flujos.
    v_franjas := public.validar_franjas_handicap_torneo(p_tournament_id);

    IF NOT COALESCE((v_franjas->>'valid')::boolean, false) THEN
        RAISE EXCEPTION
            'No se pueden abrir inscripciones: las franjas de hándicap faltan o son inválidas. %',
            COALESCE((v_franjas->'errors')::text, '[]')
            USING ERRCODE='23514';
    END IF;

    IF v_t.estado_servicio<>'activo'::public.estado_servicio_torneo
       OR v_t.activo IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION
            'No se pueden abrir inscripciones: el torneo todavía no está activo en TEE CENTRAL.'
            USING ERRCODE='23514',
                  DETAIL=format(
                      'estado_servicio=%s; activo=%s',
                      v_t.estado_servicio,
                      v_t.activo
                  );
    END IF;

    PERFORM set_config('app.permitir_cambio_estatus_torneo', '1', true);

    UPDATE public.tournaments
       SET estatus='inscripciones_abiertas'::public.estatus_torneo
     WHERE id=p_tournament_id;

    RETURN jsonb_build_object(
        'ok', true,
        'tournamentId', p_tournament_id,
        'alreadyOpen', false,
        'selfService', v_autoservicio,
        'estatusAnterior', 'planificado',
        'estatus', 'inscripciones_abiertas'
    );
END;
$function$;


-- Nueva capa del Asistente Operativo.
-- Se apoya en v20_268 para no alterar el contrato histórico acumulado y sólo
-- adapta el flujo inicial cuando el torneo proviene de una contratación PAGADA.
CREATE OR REPLACE FUNCTION public._obtener_asistente_operativo_torneo_v21_299(
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
    v_elem jsonb;

    v_autoservicio boolean := false;
    v_estatus text;

    v_blockers jsonb := '[]'::jsonb;
    v_next_action jsonb := NULL;
    v_total integer := 0;
    v_completed integer := 0;
BEGIN
    v_result := public._obtener_asistente_operativo_torneo_v20_268(
        p_tournament_id
    );

    SELECT t.estatus::text,
           EXISTS (
               SELECT 1
                 FROM public.platform_tournament_contracts c
                WHERE c.tournament_id = t.id
                  AND c.contract_status::text = 'PAGADO'
           )
      INTO v_estatus, v_autoservicio
      FROM public.tournaments t
     WHERE t.id = p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE='22023';
    END IF;

    -- Los torneos históricos conservan exactamente el comportamiento heredado.
    IF NOT v_autoservicio THEN
        RETURN v_result || jsonb_build_object(
            'schemaVersion', 21,
            'commercialFlow', 'HISTORICAL',
            'configurationConfirmationRequired', true
        );
    END IF;

    v_source_steps := COALESCE(v_result->'steps', '[]'::jsonb);

    FOR v_elem IN
        SELECT elem
          FROM jsonb_array_elements(v_source_steps) x(elem)
    LOOP
        -- En autoservicio no existe el hito manual de confirmar configuración.
        IF v_elem->>'code' = 'CONFIGURATION_CONFIRMATION' THEN
            CONTINUE;
        END IF;

        -- El requisito de desempates se conserva, pero deja de referirse al
        -- paso eliminado de confirmación.
        IF v_elem->>'code' = 'TIEBREAK_CONFIGURATION'
           AND v_elem->>'status' <> 'COMPLETE'
        THEN
            v_elem := jsonb_set(
                v_elem,
                '{recommendation}',
                to_jsonb(
                    'Completa la configuración de desempates antes de abrir inscripciones.'::text
                ),
                true
            );
        END IF;

        -- Mensaje congruente con autoservicio: no hay liberación posterior por
        -- Superadmin ni confirmación manual previa.
        IF v_elem->>'code' = 'REGISTRATIONS'
           AND v_estatus = 'planificado'
        THEN
            v_elem := jsonb_set(
                v_elem,
                '{recommendation}',
                to_jsonb(
                    'Completa la configuración requerida y abre las inscripciones.'::text
                ),
                true
            );
        END IF;

        v_final_steps := v_final_steps || jsonb_build_array(v_elem);
    END LOOP;

    -- Recalcular bloqueos, siguiente acción y progreso sin el paso eliminado.
    SELECT COALESCE(
        jsonb_agg(s.elem ORDER BY s.ord),
        '[]'::jsonb
    )
      INTO v_blockers
      FROM jsonb_array_elements(v_final_steps)
           WITH ORDINALITY AS s(elem,ord)
     WHERE s.elem->>'status'='BLOCKED'
       AND COALESCE(
           (s.elem #>> '{availability,actionable}')::boolean,
           true
       );

    SELECT s.elem->'action'
      INTO v_next_action
      FROM jsonb_array_elements(v_final_steps)
           WITH ORDINALITY AS s(elem,ord)
     WHERE s.elem->>'status' IN('BLOCKED','PENDING')
       AND s.elem->'action' IS NOT NULL
       AND s.elem->'action'<>'null'::jsonb
       AND COALESCE(
           (s.elem #>> '{availability,actionable}')::boolean,
           true
       )
     ORDER BY s.ord
     LIMIT 1;

    SELECT
        count(*)::integer,
        count(*) FILTER(
            WHERE elem->>'status'='COMPLETE'
        )::integer
      INTO v_total, v_completed
      FROM jsonb_array_elements(v_final_steps) x(elem);

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
                WHEN v_total=0 THEN 0
                ELSE round(100.0*v_completed/v_total, 0)
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

    -- No falseamos configuracion_finalizada_at. En su lugar se expone de forma
    -- explícita que este flujo no requiere confirmación manual.
    v_result := jsonb_set(
        v_result,
        '{status,configurationConfirmationRequired}',
        'false'::jsonb,
        true
    );

    RETURN v_result || jsonb_build_object(
        'schemaVersion', 21,
        'commercialFlow', 'SELF_SERVICE',
        'configurationConfirmationRequired', false
    );
END;
$function$;


CREATE OR REPLACE FUNCTION public.obtener_asistente_operativo_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT public._obtener_asistente_operativo_torneo_v21_299(
        p_tournament_id
    );
$function$;

COMMIT;
