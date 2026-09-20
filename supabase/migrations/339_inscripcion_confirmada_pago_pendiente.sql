-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 339
-- Inscripción confirmada con pago pendiente / pago el día del evento
-- ============================================================================
-- PRINCIPIOS
-- 1) El pago pendiente NO es una pre-reserva: existe tournament_registration.
-- 2) Los motores deportivos siguen trabajando con la inscripción activa normal.
-- 3) La opción queda DESACTIVADA por defecto por torneo.
-- 4) No se inventan pagos: mientras esté PENDIENTE, los datos reales de pago son NULL.
-- 5) Al registrar el cobro se completan monto/fecha/medio/referencia y pasa a PAGADO.
-- ============================================================================

BEGIN;

-- 1. Configuración opt-in del torneo.
ALTER TABLE public.tournaments
    ADD COLUMN IF NOT EXISTS permitir_pago_dia_evento boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.tournaments.permitir_pago_dia_evento IS
'Permite que el jugador quede formalmente inscrito con pago pendiente y liquide en el check-in/día del evento. Desactivado por defecto.';

-- 2. Estado económico explícito de la inscripción.
-- IMPORTANTE: se crea con DEFAULT + NOT NULL en el propio DDL.
-- PostgreSQL materializa lógicamente PAGADO para las filas históricas sin ejecutar
-- UPDATE sobre tournament_registrations. Así no se disparan los guards operativos
-- de torneos CANCELADOS ni VENCIDOS.
ALTER TABLE public.tournament_registrations
    ADD COLUMN IF NOT EXISTS estado_pago text NOT NULL DEFAULT 'PAGADO';

ALTER TABLE public.tournament_registrations
    DROP CONSTRAINT IF EXISTS tournament_registrations_estado_pago_339_chk;

ALTER TABLE public.tournament_registrations
    ADD CONSTRAINT tournament_registrations_estado_pago_339_chk
    CHECK (estado_pago IN ('PENDIENTE','PAGADO'));

-- 3. Los datos económicos pueden ser NULL solamente para PENDIENTE.
ALTER TABLE public.tournament_registrations
    ALTER COLUMN monto_pagado DROP NOT NULL,
    ALTER COLUMN fecha_pago DROP NOT NULL,
    ALTER COLUMN medio_pago DROP NOT NULL,
    ALTER COLUMN referencia_pago DROP NOT NULL;

ALTER TABLE public.tournament_registrations
    DROP CONSTRAINT IF EXISTS tournament_registrations_integridad_pago_339_chk;

ALTER TABLE public.tournament_registrations
    ADD CONSTRAINT tournament_registrations_integridad_pago_339_chk
    CHECK (
        (
            estado_pago = 'PENDIENTE'
            AND monto_pagado IS NULL
            AND fecha_pago IS NULL
            AND medio_pago IS NULL
            AND referencia_pago IS NULL
        )
        OR
        (
            estado_pago = 'PAGADO'
            AND monto_pagado IS NOT NULL
            AND fecha_pago IS NOT NULL
            AND medio_pago IS NOT NULL
            AND referencia_pago IS NOT NULL
        )
    );

COMMENT ON COLUMN public.tournament_registrations.estado_pago IS
'Estado económico de la inscripción: PENDIENTE para pago el día del evento; PAGADO para inscripción económicamente liquidada.';

-- 4. RPC del jugador: crea inscripción REAL con pago pendiente.
CREATE OR REPLACE FUNCTION public.inscribir_pago_dia_evento_339(
    p_tournament_id uuid,
    p_tournament_category_id uuid
)
RETURNS public.tournament_registrations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
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

    -- La categoría debe pertenecer al torneo. Las reglas deportivas de elegibilidad,
    -- cupo, duplicados, perfil, marca y freeze siguen siendo autoridad en los
    -- triggers existentes de tournament_registrations.
    IF NOT EXISTS (
        SELECT 1
          FROM public.tournament_categories tc
         WHERE tc.id = p_tournament_category_id
           AND tc.tournament_id = p_tournament_id
           AND tc.activo = true
    ) THEN
        RAISE EXCEPTION 'La categoría indicada no pertenece al torneo o no está activa.'
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

COMMENT ON FUNCTION public.inscribir_pago_dia_evento_339(uuid,uuid) IS
'Crea una inscripción formal activa con estado_pago=PENDIENTE cuando el torneo habilita pago el día del evento. No crea pre-reserva ni simula un pago.';

REVOKE ALL ON FUNCTION public.inscribir_pago_dia_evento_339(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inscribir_pago_dia_evento_339(uuid,uuid) TO authenticated;

-- 5. RPC administrativa: registrar el cobro real, incluso después del Freeze.
-- El trigger deportivo de Freeze permite UPDATE de campos económicos porque
-- protege jugador/categoría/marca/equipo/activo, no los datos de pago.
CREATE OR REPLACE FUNCTION public.registrar_pago_inscripcion_339(
    p_registration_id uuid,
    p_monto_pagado numeric,
    p_medio_pago public.medio_pago_torneo,
    p_referencia_pago text
)
RETURNS public.tournament_registrations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_reg public.tournament_registrations;
    v_result public.tournament_registrations;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_reg
      FROM public.tournament_registrations
     WHERE id = p_registration_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La inscripción indicada no existe.' USING ERRCODE='22023';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(), v_reg.tournament_id)
        OR EXISTS (
            SELECT 1
              FROM public.tournaments t
             WHERE t.id = v_reg.tournament_id
               AND public.is_club_admin(auth.uid(), t.club_id)
        )
    ) THEN
        RAISE EXCEPTION 'No tienes permiso para registrar el pago de esta inscripción.'
            USING ERRCODE='42501';
    END IF;

    IF v_reg.activo IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'No se puede registrar pago sobre una inscripción inactiva.'
            USING ERRCODE='23514';
    END IF;

    IF v_reg.estado_pago <> 'PENDIENTE' THEN
        RAISE EXCEPTION 'Esta inscripción no está pendiente de pago.'
            USING ERRCODE='23514';
    END IF;

    IF p_monto_pagado IS NULL OR p_monto_pagado < 0 THEN
        RAISE EXCEPTION 'El monto pagado debe ser válido.'
            USING ERRCODE='23514';
    END IF;

    IF p_medio_pago IS NULL THEN
        RAISE EXCEPTION 'Debe indicar el medio de pago real.'
            USING ERRCODE='23514';
    END IF;

    IF NULLIF(btrim(p_referencia_pago), '') IS NULL THEN
        RAISE EXCEPTION 'Debe registrar una referencia o nota del pago.'
            USING ERRCODE='23514';
    END IF;

    UPDATE public.tournament_registrations
       SET monto_pagado = p_monto_pagado,
           fecha_pago = now(),
           medio_pago = p_medio_pago,
           referencia_pago = btrim(p_referencia_pago),
           estado_pago = 'PAGADO'
     WHERE id = p_registration_id
     RETURNING * INTO v_result;

    RETURN v_result;
END;
$function$;

COMMENT ON FUNCTION public.registrar_pago_inscripcion_339(uuid,numeric,public.medio_pago_torneo,text) IS
'Confirma administrativamente el cobro real de una inscripción PENDIENTE y la convierte a PAGADO sin alterar su identidad competitiva.';

REVOKE ALL ON FUNCTION public.registrar_pago_inscripcion_339(uuid,numeric,public.medio_pago_torneo,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.registrar_pago_inscripcion_339(uuid,numeric,public.medio_pago_torneo,text) TO authenticated;

COMMIT;
