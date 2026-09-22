BEGIN;

-- ============================================================
-- MIGRACIÓN 352
-- Total a pagar congelado por inscripción + control de cobranza
-- ============================================================

-- 1) Obligación económica de la inscripción.
--    En esta fase se admite un solo pago liquidatorio; la futura
--    cuenta corriente podrá evolucionar sobre este total sin cambiar
--    el significado de monto_pagado.
ALTER TABLE public.tournament_registrations
  ADD COLUMN IF NOT EXISTS total_a_pagar numeric(12,2);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint
     WHERE conname = 'tournament_registrations_total_a_pagar_352_chk'
       AND conrelid = 'public.tournament_registrations'::regclass
  ) THEN
    ALTER TABLE public.tournament_registrations
      ADD CONSTRAINT tournament_registrations_total_a_pagar_352_chk
      CHECK (total_a_pagar IS NULL OR total_a_pagar >= 0);
  END IF;
END $$;

COMMENT ON COLUMN public.tournament_registrations.total_a_pagar IS
  'Importe total congelado a pagar por esta inscripción. En la fase 352 se liquida con un solo pago; reservado para futura evolución a cargos/abonos/saldo.';

-- 2) Backfill controlado del torneo operativo POLLA SEPTIEMBRE, 24.
--    Se valida la configuración conocida antes de tocar datos.
DO $$
DECLARE
  v_tournament_id uuid;
  v_count integer;
  v_tarifa numeric;
  v_equipo numeric;
  v_early numeric;
BEGIN
  SELECT count(*)
    INTO v_count
    FROM public.tournaments
   WHERE nombre = 'POLLA SEPTIEMBRE, 24';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Migración 352: se esperaba exactamente un torneo llamado POLLA SEPTIEMBRE, 24; encontrados: %', v_count;
  END IF;

  SELECT id, tarifa_individual, tarifa_equipo_completo, tarifa_early_bird
    INTO v_tournament_id, v_tarifa, v_equipo, v_early
    FROM public.tournaments
   WHERE nombre = 'POLLA SEPTIEMBRE, 24';

  IF v_tarifa IS DISTINCT FROM 1000.00::numeric
     OR v_equipo IS NOT NULL
     OR v_early IS NOT NULL THEN
    RAISE EXCEPTION 'Migración 352: configuración económica inesperada para POLLA SEPTIEMBRE, 24. Tarifa individual=%, equipo=%, early bird=%',
      v_tarifa, v_equipo, v_early;
  END IF;

  UPDATE public.tournament_registrations
     SET total_a_pagar = 1000.00
   WHERE tournament_id = v_tournament_id
     AND activo IS TRUE
     AND estado_pago = 'PENDIENTE'
     AND total_a_pagar IS NULL;
END $$;

-- 3) Las nuevas inscripciones con pago el día del evento congelan
--    el precio aplicable al momento de inscribirse.
--    Para esta RPC individual: early bird vigente, si existe; de lo
--    contrario tarifa individual. La tarifa por equipo no aplica aquí.
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
    v_total_a_pagar numeric(12,2);
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

    IF NOT EXISTS (
        SELECT 1
          FROM public.tournament_categories tc
         WHERE tc.id = p_tournament_category_id
           AND tc.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION 'La categoría indicada no pertenece al torneo.'
            USING ERRCODE='23514';
    END IF;

    IF v_t.tarifa_early_bird IS NOT NULL
       AND v_t.fecha_limite_early_bird IS NOT NULL
       AND CURRENT_DATE <= v_t.fecha_limite_early_bird
    THEN
        v_total_a_pagar := v_t.tarifa_early_bird;
    ELSE
        v_total_a_pagar := v_t.tarifa_individual;
    END IF;

    IF v_total_a_pagar IS NULL OR v_total_a_pagar < 0 THEN
        RAISE EXCEPTION 'El torneo no tiene una tarifa individual válida para congelar el total a pagar.'
            USING ERRCODE='23514';
    END IF;

    INSERT INTO public.tournament_registrations (
        tournament_id,
        player_id,
        tournament_category_id,
        total_a_pagar,
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
        v_total_a_pagar,
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

-- 4) Pago único liquidatorio.
--    Si la inscripción ya tiene total_a_pagar, el importe recibido debe
--    coincidir exactamente. Inscripciones históricas sin total conservan
--    el comportamiento previo para no romper flujos legacy.
CREATE OR REPLACE FUNCTION public.registrar_pago_inscripcion_339(
  p_registration_id uuid,
  p_monto_pagado numeric,
  p_medio_pago public.medio_pago_torneo,
  p_referencia_pago text
)
RETURNS public.tournament_registrations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
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

    IF v_reg.total_a_pagar IS NOT NULL
       AND round(p_monto_pagado::numeric, 2) <> round(v_reg.total_a_pagar::numeric, 2)
    THEN
        RAISE EXCEPTION 'En esta fase el pago debe liquidar el total a pagar de la inscripción: %.', v_reg.total_a_pagar
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

-- 5) Fuente única para pantalla, reporte formal y Excel de cobranza.
CREATE OR REPLACE FUNCTION public.obtener_control_cobranza_pendiente_352(
  p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_t public.tournaments%ROWTYPE;
  v_campo_nombre text;
  v_rows jsonb;
  v_count integer;
  v_total numeric(14,2);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
  END IF;

  SELECT * INTO v_t
    FROM public.tournaments
   WHERE id = p_tournament_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='22023';
  END IF;

  IF NOT (
      public.is_superadmin(auth.uid())
      OR public.is_tournament_organizer(auth.uid(), p_tournament_id)
      OR public.is_club_admin(auth.uid(), v_t.club_id)
  ) THEN
    RAISE EXCEPTION 'No tienes permiso para consultar la cobranza de este torneo.'
      USING ERRCODE='42501';
  END IF;

  SELECT cg.nombre_oficial
    INTO v_campo_nombre
    FROM public.campos_golf cg
   WHERE cg.id = v_t.campo_golf_id;

  SELECT count(*), COALESCE(sum(tr.total_a_pagar),0)::numeric(14,2)
    INTO v_count, v_total
    FROM public.tournament_registrations tr
   WHERE tr.tournament_id = p_tournament_id
     AND tr.activo IS TRUE
     AND tr.estado_pago = 'PENDIENTE';

  SELECT COALESCE(jsonb_agg(x.obj ORDER BY x.apellidos_sort, x.nombres_sort), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT p.apellidos AS apellidos_sort,
             p.nombres AS nombres_sort,
             jsonb_build_object(
               'registrationId', tr.id,
               'playerId', p.id,
               'apellidos', p.apellidos,
               'nombres', p.nombres,
               'nombreCompleto', concat_ws(', ', p.apellidos, p.nombres),
               'totalAPagar', tr.total_a_pagar,
               'estadoPago', tr.estado_pago
             ) AS obj
        FROM public.tournament_registrations tr
        JOIN public.players p ON p.id = tr.player_id
       WHERE tr.tournament_id = p_tournament_id
         AND tr.activo IS TRUE
         AND tr.estado_pago = 'PENDIENTE'
    ) x;

  RETURN jsonb_build_object(
    'tournamentId', v_t.id,
    'torneo', v_t.nombre,
    'fechaInicio', v_t.fecha_inicio,
    'fechaFin', v_t.fecha_fin,
    'campo', v_campo_nombre,
    'moneda', v_t.moneda,
    'tarifaIndividual', v_t.tarifa_individual,
    'tarifaEquipoCompleto', v_t.tarifa_equipo_completo,
    'tarifaEarlyBird', v_t.tarifa_early_bird,
    'fechaLimiteEarlyBird', v_t.fecha_limite_early_bird,
    'permitirPagoDiaEvento', v_t.permitir_pago_dia_evento,
    'cantidadPendientes', v_count,
    'totalEsperado', v_total,
    'mediosPago', jsonb_build_array('tarjeta_credito','tarjeta_debito','transferencia','efectivo'),
    'jugadores', v_rows
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_control_cobranza_pendiente_352(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_control_cobranza_pendiente_352(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_control_cobranza_pendiente_352(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_control_cobranza_pendiente_352(uuid) TO service_role;

COMMIT;
