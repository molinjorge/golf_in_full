-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 298
-- Finalización / reapertura de configuración para torneos autoservicio activos
--
-- Objetivo:
--   Mantener la confirmación explícita de configuración como requisito previo
--   a abrir inscripciones, pero permitir el mismo ciclo de confirmar/reabrir
--   en torneos de autoservicio que nacen con estado_servicio='activo'.
--
-- Alcance:
--   - NO cambia abrir_inscripciones_torneo().
--   - NO cambia validaciones deportivas mínimas ni desempates.
--   - NO cambia provisionamiento/liberación histórica.
--   - Permite finalizar/reabrir configuración en estado 'activo' únicamente
--     mientras el estatus deportivo siga siendo 'planificado'.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.finalizar_configuracion_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_admin_id uuid;
    v_listo boolean;
    v_errores jsonb;
    v_estado public.estado_servicio_torneo;
    v_estatus public.estatus_torneo;
    v_tiebreak jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(
            auth.uid(),
            p_tournament_id
        )
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden finalizar la configuración del torneo.'
            USING ERRCODE='42501';
    END IF;

    SELECT estado_servicio, estatus
      INTO v_estado, v_estatus
      FROM public.tournaments
     WHERE id=p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El torneo indicado no existe.'
            USING ERRCODE='22023';
    END IF;

    -- Flujo histórico: continúa permitido mientras está provisionado.
    -- Autoservicio: el torneo nace activo; se permite confirmar sólo antes
    -- de abrir inscripciones, es decir, mientras siga EN PLANIFICACIÓN.
    IF v_estado='provisionado'::public.estado_servicio_torneo THEN
        NULL;
    ELSIF v_estado='activo'::public.estado_servicio_torneo
          AND v_estatus='planificado'::public.estatus_torneo THEN
        NULL;
    ELSE
        RAISE EXCEPTION
            'La configuración sólo puede finalizarse mientras el torneo está provisionado o, en autoservicio, activo y EN PLANIFICACIÓN. Estado de servicio: %; estatus: %.',
            v_estado,
            v_estatus
            USING ERRCODE='23514';
    END IF;

    SELECT v.listo,v.errores
      INTO v_listo,v_errores
      FROM public.validar_configuracion_minima_torneo(
          p_tournament_id
      ) v;

    IF NOT v_listo THEN
        RAISE EXCEPTION
            'La configuración del torneo todavía no está completa: %',
            v_errores::text
            USING ERRCODE='23514';
    END IF;

    v_tiebreak :=
        public.obtener_estado_configuracion_desempates_261(
            p_tournament_id
        );

    IF NOT COALESCE(
        (v_tiebreak->>'complete')::boolean,
        false
    ) THEN
        RAISE EXCEPTION
            'La configuración del torneo todavía no puede finalizarse: faltan o son inconsistentes las reglas de desempate. %',
            v_tiebreak::text
            USING ERRCODE='23514';
    END IF;

    SELECT public.current_admin_id()
      INTO v_admin_id;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No se encontró el usuario administrativo autenticado.'
            USING ERRCODE='42501';
    END IF;

    PERFORM set_config(
        'app.permitir_finalizacion_configuracion_torneo',
        '1',
        true
    );

    UPDATE public.tournaments
       SET configuracion_finalizada_at=COALESCE(
               configuracion_finalizada_at,
               now()
           ),
           configuracion_finalizada_por=COALESCE(
               configuracion_finalizada_por,
               v_admin_id
           )
     WHERE id=p_tournament_id;

    RETURN jsonb_build_object(
        'ok',true,
        'tournamentId',p_tournament_id,
        'configuracionFinalizada',true,
        'configuracionFinalizadaAt',
            (
                SELECT configuracion_finalizada_at
                FROM public.tournaments
                WHERE id=p_tournament_id
            ),
        'estadoServicio',v_estado::text,
        'estatus',v_estatus::text,
        'activo',
            (
                SELECT activo
                FROM public.tournaments
                WHERE id=p_tournament_id
            )
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.reabrir_configuracion_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_estado public.estado_servicio_torneo;
    v_estatus public.estatus_torneo;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(
            auth.uid(),
            p_tournament_id
        )
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden reabrir la configuración del torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT estado_servicio, estatus
      INTO v_estado, v_estatus
      FROM public.tournaments
     WHERE id = p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    -- Flujo histórico: se conserva mientras el torneo esté provisionado.
    -- Autoservicio: puede reabrirse únicamente antes de abrir inscripciones.
    IF v_estado='provisionado'::public.estado_servicio_torneo THEN
        NULL;
    ELSIF v_estado='activo'::public.estado_servicio_torneo
          AND v_estatus='planificado'::public.estatus_torneo THEN
        NULL;
    ELSE
        RAISE EXCEPTION
            'La configuración sólo puede reabrirse mientras el torneo está provisionado o, en autoservicio, activo y EN PLANIFICACIÓN. Estado de servicio: %; estatus: %.',
            v_estado,
            v_estatus
            USING ERRCODE = '55000';
    END IF;

    PERFORM set_config(
        'app.permitir_finalizacion_configuracion_torneo',
        '1',
        true
    );

    UPDATE public.tournaments
       SET configuracion_finalizada_at = NULL,
           configuracion_finalizada_por = NULL
     WHERE id = p_tournament_id;

    RETURN jsonb_build_object(
        'ok', true,
        'tournamentId', p_tournament_id,
        'configuracionFinalizada', false,
        'estadoServicio', v_estado::text,
        'estatus', v_estatus::text
    );
END;
$function$;

-- Mantener explícitos los permisos existentes de ejecución.
REVOKE ALL ON FUNCTION public.finalizar_configuracion_torneo(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.finalizar_configuracion_torneo(uuid)
    TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.reabrir_configuracion_torneo(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reabrir_configuracion_torneo(uuid)
    TO authenticated, service_role;

COMMIT;
