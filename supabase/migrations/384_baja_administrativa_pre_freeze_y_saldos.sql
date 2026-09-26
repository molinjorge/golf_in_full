BEGIN;

-- 384: Baja administrativa pre-Freeze y saldo financiero de una baja pagada.
-- La inscripción se conserva como histórico. Si tenía un pago vigente > 0,
-- se crea un saldo PENDIENTE que posteriormente podrá aplicarse o devolverse.

CREATE TABLE IF NOT EXISTS public.tournament_deregistrations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    tournament_registration_id uuid NOT NULL REFERENCES public.tournament_registrations(id) ON DELETE RESTRICT,
    player_id uuid NOT NULL REFERENCES public.players(id) ON DELETE RESTRICT,
    deregistration_folio text NOT NULL,
    deregistration_reason text NOT NULL,
    deregistered_at timestamptz NOT NULL DEFAULT now(),
    deregistered_by_admin_id uuid NOT NULL REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    original_registration_folio text,
    payment_status_at_deregistration text NOT NULL,
    amount_due_at_deregistration numeric,
    amount_paid_at_deregistration numeric,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_deregistrations_folio_uq UNIQUE (tournament_id, deregistration_folio),
    CONSTRAINT tournament_deregistrations_registration_uq UNIQUE (tournament_registration_id),
    CONSTRAINT tournament_deregistrations_payment_status_chk CHECK (
        payment_status_at_deregistration = ANY (ARRAY['PENDIENTE'::text, 'PAGADO'::text])
    ),
    CONSTRAINT tournament_deregistrations_amounts_chk CHECK (
        (amount_due_at_deregistration IS NULL OR amount_due_at_deregistration >= 0)
        AND (amount_paid_at_deregistration IS NULL OR amount_paid_at_deregistration >= 0)
    )
);

CREATE INDEX IF NOT EXISTS idx_tournament_deregistrations_tournament_date
    ON public.tournament_deregistrations(tournament_id, deregistered_at DESC);

ALTER TABLE public.tournament_deregistrations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.tournament_deregistrations FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.tournament_deregistration_balances (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    deregistration_id uuid NOT NULL REFERENCES public.tournament_deregistrations(id) ON DELETE RESTRICT,
    tournament_registration_id uuid NOT NULL REFERENCES public.tournament_registrations(id) ON DELETE RESTRICT,
    player_id uuid NOT NULL REFERENCES public.players(id) ON DELETE RESTRICT,
    original_amount numeric NOT NULL,
    available_amount numeric NOT NULL,
    status text NOT NULL DEFAULT 'PENDIENTE',
    original_payment_method public.medio_pago_torneo,
    original_payment_reference text,
    original_payment_at timestamptz,
    applied_to_registration_id uuid REFERENCES public.tournament_registrations(id) ON DELETE RESTRICT,
    applied_to_player_id uuid REFERENCES public.players(id) ON DELETE RESTRICT,
    applied_by_admin_id uuid REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    applied_at timestamptz,
    refunded_by_admin_id uuid REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    refunded_at timestamptz,
    resolution_note text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_deregistration_balances_deregistration_uq UNIQUE (deregistration_id),
    CONSTRAINT tournament_deregistration_balances_registration_uq UNIQUE (tournament_registration_id),
    CONSTRAINT tournament_deregistration_balances_amount_chk CHECK (
        original_amount > 0 AND available_amount >= 0 AND available_amount <= original_amount
    ),
    CONSTRAINT tournament_deregistration_balances_status_chk CHECK (
        status = ANY (ARRAY['PENDIENTE'::text, 'APLICADO'::text, 'DEVUELTO'::text])
    ),
    CONSTRAINT tournament_deregistration_balances_resolution_chk CHECK (
        (status = 'PENDIENTE'
            AND available_amount = original_amount
            AND applied_to_registration_id IS NULL
            AND applied_to_player_id IS NULL
            AND applied_by_admin_id IS NULL
            AND applied_at IS NULL
            AND refunded_by_admin_id IS NULL
            AND refunded_at IS NULL)
        OR
        (status = 'APLICADO'
            AND available_amount = 0
            AND applied_to_registration_id IS NOT NULL
            AND applied_to_player_id IS NOT NULL
            AND applied_by_admin_id IS NOT NULL
            AND applied_at IS NOT NULL
            AND refunded_by_admin_id IS NULL
            AND refunded_at IS NULL)
        OR
        (status = 'DEVUELTO'
            AND available_amount = 0
            AND applied_to_registration_id IS NULL
            AND applied_to_player_id IS NULL
            AND applied_by_admin_id IS NULL
            AND applied_at IS NULL
            AND refunded_by_admin_id IS NOT NULL
            AND refunded_at IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_tournament_deregistration_balances_tournament_status
    ON public.tournament_deregistration_balances(tournament_id, status, created_at DESC);

ALTER TABLE public.tournament_deregistration_balances ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.tournament_deregistration_balances FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.dar_de_baja_inscripcion_pre_freeze_384(
    p_registration_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_reg public.tournament_registrations;
    v_admin_id uuid;
    v_reason text := btrim(COALESCE(p_reason, ''));
    v_deregistration_folio text;
    v_consecutivo integer;
    v_deregistration_id uuid;
    v_balance_id uuid;
    v_balance_amount numeric;
    v_groups_removed integer := 0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    IF p_registration_id IS NULL THEN
        RAISE EXCEPTION 'Debe indicar la inscripción que desea dar de baja.' USING ERRCODE = '22023';
    END IF;

    IF length(v_reason) < 5 THEN
        RAISE EXCEPTION 'Debe indicar un motivo de baja de al menos 5 caracteres.' USING ERRCODE = '23514';
    END IF;

    SELECT *
      INTO v_reg
      FROM public.tournament_registrations
     WHERE id = p_registration_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La inscripción indicada no existe.' USING ERRCODE = '22023';
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
        RAISE EXCEPTION 'No tienes permiso para dar de baja esta inscripción.' USING ERRCODE = '42501';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo = true;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No existe un usuario administrativo activo para registrar la baja.' USING ERRCODE = '42501';
    END IF;

    IF v_reg.activo IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'La inscripción ya se encuentra inactiva.' USING ERRCODE = '23514';
    END IF;

    -- La baja administrativa general de 384 es exclusivamente pre-Freeze.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_condition_freezes f
         WHERE f.tournament_id = v_reg.tournament_id
    ) THEN
        RAISE EXCEPTION 'No se puede dar de baja administrativamente una inscripción después del Freeze.'
            USING ERRCODE = '23514',
                  HINT = 'Después del Freeze deben utilizarse únicamente los procedimientos competitivos específicos de la modalidad.';
    END IF;

    -- Los flujos TEAM tienen composición/cobertura económica propia. 384 no los altera.
    IF v_reg.tournament_team_id IS NOT NULL THEN
        RAISE EXCEPTION 'Esta inscripción pertenece a un equipo y debe gestionarse desde el flujo de administración del equipo.'
            USING ERRCODE = '23514';
    END IF;

    -- Serializa el folio BAJ dentro del torneo.
    PERFORM 1
      FROM public.tournaments
     WHERE id = v_reg.tournament_id
     FOR UPDATE;

    SELECT COALESCE(MAX(substring(d.deregistration_folio FROM '^BAJ-([0-9]+)$')::integer), 0) + 1
      INTO v_consecutivo
      FROM public.tournament_deregistrations d
     WHERE d.tournament_id = v_reg.tournament_id
       AND d.deregistration_folio ~ '^BAJ-[0-9]+$';

    v_deregistration_folio := 'BAJ-' || lpad(v_consecutivo::text, 4, '0');

    -- Retira al jugador de grupos pre-Freeze. La inscripción histórica no se elimina.
    DELETE FROM public.tournament_group_players gp
     WHERE gp.tournament_registration_id = v_reg.id;
    GET DIAGNOSTICS v_groups_removed = ROW_COUNT;

    UPDATE public.tournament_registrations
       SET activo = false,
           motivo_baja = v_reason
     WHERE id = v_reg.id;

    INSERT INTO public.tournament_deregistrations (
        tournament_id, tournament_registration_id, player_id, deregistration_folio,
        deregistration_reason, deregistered_at, deregistered_by_admin_id,
        original_registration_folio, payment_status_at_deregistration,
        amount_due_at_deregistration, amount_paid_at_deregistration
    ) VALUES (
        v_reg.tournament_id, v_reg.id, v_reg.player_id, v_deregistration_folio,
        v_reason, now(), v_admin_id, v_reg.folio, v_reg.estado_pago,
        v_reg.total_a_pagar, v_reg.monto_pagado
    ) RETURNING id INTO v_deregistration_id;

    -- Si había dinero efectivamente recibido, crea un saldo financiero vivo.
    IF v_reg.estado_pago = 'PAGADO'
       AND v_reg.monto_pagado IS NOT NULL
       AND v_reg.monto_pagado > 0 THEN

        v_balance_amount := v_reg.monto_pagado;

        INSERT INTO public.tournament_deregistration_balances (
            tournament_id,
            deregistration_id,
            tournament_registration_id,
            player_id,
            original_amount,
            available_amount,
            status,
            original_payment_method,
            original_payment_reference,
            original_payment_at
        ) VALUES (
            v_reg.tournament_id,
            v_deregistration_id,
            v_reg.id,
            v_reg.player_id,
            v_balance_amount,
            v_balance_amount,
            'PENDIENTE',
            v_reg.medio_pago,
            v_reg.referencia_pago,
            v_reg.fecha_pago
        )
        RETURNING id INTO v_balance_id;
    END IF;

    RETURN jsonb_build_object(
        'changed', true,
        'registrationId', v_reg.id,
        'tournamentId', v_reg.tournament_id,
        'playerId', v_reg.player_id,
        'registrationFolio', v_reg.folio,
        'deregistrationId', v_deregistration_id,
        'deregistrationFolio', v_deregistration_folio,
        'reason', v_reason,
        'paymentStatus', v_reg.estado_pago,
        'paidAmount', v_reg.monto_pagado,
        'balanceCreated', v_balance_id IS NOT NULL,
        'balanceId', v_balance_id,
        'balanceAmount', v_balance_amount,
        'balanceStatus', CASE WHEN v_balance_id IS NOT NULL THEN 'PENDIENTE' ELSE NULL END,
        'groupsRemoved', v_groups_removed
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.dar_de_baja_inscripcion_pre_freeze_384(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dar_de_baja_inscripcion_pre_freeze_384(uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.obtener_saldos_bajas_384(p_tournament_id uuid)
RETURNS TABLE (
    balance_id uuid,
    tournament_id uuid,
    deregistration_folio text,
    registration_id uuid,
    registration_folio text,
    player_id uuid,
    player_name text,
    deregistration_reason text,
    deregistered_at timestamptz,
    original_amount numeric,
    available_amount numeric,
    status text,
    applied_to_registration_id uuid,
    applied_to_player_id uuid,
    applied_to_player_name text,
    applied_by_admin_id uuid,
    applied_by_admin_name text,
    applied_at timestamptz,
    refunded_by_admin_id uuid,
    refunded_by_admin_name text,
    refunded_at timestamptz,
    resolution_note text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    IF p_tournament_id IS NULL THEN
        RAISE EXCEPTION 'Debe indicar el torneo.' USING ERRCODE = '22023';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(), p_tournament_id)
        OR EXISTS (
            SELECT 1
              FROM public.tournaments t
             WHERE t.id = p_tournament_id
               AND public.is_club_admin(auth.uid(), t.club_id)
        )
    ) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar los saldos por bajas de este torneo.' USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT b.id,
           b.tournament_id,
           d.deregistration_folio,
           b.tournament_registration_id,
           d.original_registration_folio,
           b.player_id,
           concat_ws(' ', p.nombres, p.apellidos),
           d.deregistration_reason,
           d.deregistered_at,
           b.original_amount,
           b.available_amount,
           b.status,
           b.applied_to_registration_id,
           b.applied_to_player_id,
           concat_ws(' ', p2.nombres, p2.apellidos),
           b.applied_by_admin_id,
           CASE WHEN aa.id IS NULL THEN NULL ELSE concat_ws(' ', aa.nombres, aa.apellidos) END,
           b.applied_at,
           b.refunded_by_admin_id,
           CASE WHEN ar.id IS NULL THEN NULL ELSE concat_ws(' ', ar.nombres, ar.apellidos) END,
           b.refunded_at,
           b.resolution_note
      FROM public.tournament_deregistration_balances b
      JOIN public.tournament_deregistrations d ON d.id = b.deregistration_id
      JOIN public.players p ON p.id = b.player_id
 LEFT JOIN public.players p2 ON p2.id = b.applied_to_player_id
 LEFT JOIN public.admin_users aa ON aa.id = b.applied_by_admin_id
 LEFT JOIN public.admin_users ar ON ar.id = b.refunded_by_admin_id
     WHERE b.tournament_id = p_tournament_id
     ORDER BY CASE b.status WHEN 'PENDIENTE' THEN 0 WHEN 'APLICADO' THEN 1 ELSE 2 END,
              d.deregistered_at DESC,
              d.deregistration_folio DESC;
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_saldos_bajas_384(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_saldos_bajas_384(uuid) TO authenticated, service_role;

COMMENT ON TABLE public.tournament_deregistrations IS
'384: registro histórico de toda baja administrativa pre-Freeze, pagada o pendiente, con folio BAJ por torneo.';

COMMENT ON TABLE public.tournament_deregistration_balances IS
'384: saldos financieros originados por bajas administrativas pre-Freeze de inscripciones pagadas. La inscripción queda histórica/inactiva y el dinero permanece pendiente hasta aplicación o devolución.';

COMMENT ON FUNCTION public.dar_de_baja_inscripcion_pre_freeze_384(uuid, text) IS
'384: baja administrativa pre-Freeze para inscripción individual. Conserva histórico/pago, retira de grupos y crea saldo PENDIENTE si había monto pagado > 0.';

COMMENT ON FUNCTION public.obtener_saldos_bajas_384(uuid) IS
'384: consulta administrativa de saldos originados por bajas, preparada para posterior aplicación/devolución.';

COMMIT;
