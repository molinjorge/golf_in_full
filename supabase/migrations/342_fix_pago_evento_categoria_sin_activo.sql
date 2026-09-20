-- MIGRACIÓN 342
-- Corrección puntual de inscribir_pago_dia_evento_339:
-- tournament_categories no tiene columna activo.
-- No modifica tablas, elegibilidad, Freeze, workflow ni motores deportivos.
BEGIN;

CREATE OR REPLACE FUNCTION public.inscribir_pago_dia_evento_339(
    p_tournament_id uuid,
    p_tournament_category_id uuid
)
RETURNS public.tournament_registrations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_player_id uuid;
    v_t public.tournaments%ROWTYPE;
    v_reg public.tournament_registrations;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    v_player_id := public._current_player_id_199();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión como jugador.' USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id
     FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='22023';
    END IF;

    IF v_t.activo IS DISTINCT FROM true
       OR v_t.estado_servicio::text <> 'activo'
    THEN
        RAISE EXCEPTION 'El torneo no está activo para inscripciones.'
            USING ERRCODE='23514';
    END IF;

    IF v_t.estatus::text <> 'inscripciones_abiertas' THEN
        RAISE EXCEPTION 'Las inscripciones no están abiertas para este torneo.'
            USING ERRCODE='23514';
    END IF;

    IF v_t.permitir_pago_dia_evento IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Este torneo no permite pago el día del evento.'
            USING ERRCODE='23514';
    END IF;

    -- tournament_categories no implementa estado activo/inactivo.
    -- La existencia de la asociación (id + tournament_id) es la condición
    -- estructural correcta. Las demás reglas siguen en los triggers existentes
    -- de tournament_registrations.
    IF NOT EXISTS (
        SELECT 1
          FROM public.tournament_categories tc
         WHERE tc.id = p_tournament_category_id
           AND tc.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION 'La categoría indicada no pertenece al torneo.'
            USING ERRCODE='23514';
    END IF;

    INSERT INTO public.tournament_registrations (
        tournament_id,
        player_id,
        tournament_category_id,
        monto_pagado,
        fecha_pago,
        medio_pago,
        referencia_pago,
        estado_pago
    )
    VALUES (
        p_tournament_id,
        v_player_id,
        p_tournament_category_id,
        NULL,
        NULL,
        NULL,
        NULL,
        'PENDIENTE'
    )
    RETURNING * INTO v_reg;

    RETURN v_reg;
END;
$function$;

COMMIT;
