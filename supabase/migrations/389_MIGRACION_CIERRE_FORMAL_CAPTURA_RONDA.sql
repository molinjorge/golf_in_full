-- MIGRACION 389
-- TEE CENTRAL / GOLF IN FULL
-- CIERRE FORMAL Y AUDITABLE DE CAPTURA POR RONDA
--
-- OBJETIVO
-- 1) Crear un hito formal CAPTURA ABIERTA / CAPTURA CERRADA por ronda.
-- 2) Exponer un resumen numérico de captura física, conciliación y outcomes.
-- 3) Permitir cerrar captura sólo cuando no existan unidades pendientes.
-- 4) Permitir reapertura explícita y auditable.
-- 5) Impedir cerrar competitivamente una categoría mientras la captura siga abierta.
--
-- IMPORTANTE
-- - NO mezcla pagos con el flujo deportivo.
-- - NO cierra categorías ni rondas automáticamente.
-- - NO modifica resultados, desempates ni publicaciones existentes.
-- - Historial append-only: CLOSED / REOPENED.
-- - Ejecutar manualmente en Supabase PROD.

BEGIN;

CREATE TABLE IF NOT EXISTS public.tournament_round_capture_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL REFERENCES public.tournaments(id),
    tournament_round_id uuid NOT NULL REFERENCES public.tournament_rounds(id),
    action text NOT NULL CHECK (action IN ('CLOSED','REOPENED')),
    notes text NULL,
    summary_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
    performed_by_admin_user_id uuid NOT NULL REFERENCES public.admin_users(id),
    performed_by_auth_user_id uuid NOT NULL,
    occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_round_capture_events_round_time
    ON public.tournament_round_capture_events
       (tournament_round_id, occurred_at DESC, id DESC);

ALTER TABLE public.tournament_round_capture_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_round_capture_events FROM anon;
REVOKE ALL ON TABLE public.tournament_round_capture_events FROM authenticated;

COMMENT ON TABLE public.tournament_round_capture_events IS
'Historial append-only del cierre/reapertura formal de captura de una ronda. Migración 389.';

CREATE OR REPLACE FUNCTION public.obtener_estado_cierre_captura_ronda_389(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_auth uuid := auth.uid();
    v_tournament_id uuid;
    v_last_action text;
    v_last_at timestamptz;
    v_last_admin uuid;

    v_total integer := 0;
    v_physical_captured integer := 0;
    v_reconciliation_completed integer := 0;
    v_reconciliation_not_required integer := 0;
    v_reconciliation_required_completed integer := 0;

    v_dns integer := 0;
    v_wd integer := 0;
    v_dnf integer := 0;
    v_dq integer := 0;
    v_no_card integer := 0;
    v_other_terminal integer := 0;

    v_resolved integer := 0;
    v_pending integer := 0;
BEGIN
    IF v_auth IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT r.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds r
     WHERE r.id = p_tournament_round_id
       AND r.activo = true;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'Ronda activa no encontrada.' USING ERRCODE='22023';
    END IF;

    IF NOT (
        public.is_superadmin(v_auth)
        OR public.is_tournament_organizer(v_auth, v_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No autorizado para consultar esta ronda.'
            USING ERRCODE='42501';
    END IF;

    SELECT e.action, e.occurred_at, e.performed_by_admin_user_id
      INTO v_last_action, v_last_at, v_last_admin
      FROM public.tournament_round_capture_events e
     WHERE e.tournament_round_id = p_tournament_round_id
     ORDER BY e.occurred_at DESC, e.id DESC
     LIMIT 1;

    SELECT count(*)
      INTO v_total
      FROM public.tournament_score_cards sc
     WHERE sc.tournament_round_id = p_tournament_round_id;

    SELECT
        count(*) FILTER (WHERE pr.status = 'CAPTURED'),
        count(*) FILTER (
            WHERE rc.status = 'COMPLETED'
        ),
        count(*) FILTER (
            WHERE rc.status = 'COMPLETED'
              AND rc.reconciliation_requirement = 'NOT_REQUIRED'
        ),
        count(*) FILTER (
            WHERE rc.status = 'COMPLETED'
              AND COALESCE(rc.reconciliation_requirement,'') <> 'NOT_REQUIRED'
        )
      INTO
        v_physical_captured,
        v_reconciliation_completed,
        v_reconciliation_not_required,
        v_reconciliation_required_completed
      FROM public.tournament_score_cards sc
      LEFT JOIN public.tournament_scorecard_physical_receptions pr
        ON pr.score_card_id = sc.id
      LEFT JOIN public.tournament_scorecard_reconciliations rc
        ON rc.score_card_id = sc.id
     WHERE sc.tournament_round_id = p_tournament_round_id;

    SELECT
        count(*) FILTER (WHERE o.outcome_code = 'DNS'),
        count(*) FILTER (WHERE o.outcome_code = 'WD'),
        count(*) FILTER (WHERE o.outcome_code = 'DNF'),
        count(*) FILTER (WHERE o.outcome_code = 'DQ'),
        count(*) FILTER (WHERE o.outcome_code = 'NO_CARD'),
        count(*) FILTER (
            WHERE o.outcome_code NOT IN ('DNS','WD','DNF','DQ','NO_CARD')
        )
      INTO
        v_dns, v_wd, v_dnf, v_dq, v_no_card, v_other_terminal
      FROM public.tournament_scorecard_round_outcomes o
     WHERE o.tournament_round_id = p_tournament_round_id;

    -- Una unidad está resuelta para CIERRE DE CAPTURA si:
    -- A) tiene outcome terminal formal, o
    -- B) su tarjeta física está CAPTURED y su conciliación está COMPLETED.
    SELECT count(*)
      INTO v_resolved
      FROM public.tournament_score_cards sc
     WHERE sc.tournament_round_id = p_tournament_round_id
       AND (
            EXISTS (
                SELECT 1
                  FROM public.tournament_scorecard_round_outcomes o
                 WHERE o.score_card_id = sc.id
                   AND o.outcome_code IN ('DNS','WD','DNF','DQ','NO_CARD')
            )
            OR (
                EXISTS (
                    SELECT 1
                      FROM public.tournament_scorecard_physical_receptions pr
                     WHERE pr.score_card_id = sc.id
                       AND pr.status = 'CAPTURED'
                )
                AND EXISTS (
                    SELECT 1
                      FROM public.tournament_scorecard_reconciliations rc
                     WHERE rc.score_card_id = sc.id
                       AND rc.status = 'COMPLETED'
                )
            )
       );

    v_pending := GREATEST(v_total - v_resolved, 0);

    RETURN jsonb_build_object(
        'schemaVersion', 389,
        'tournamentId', v_tournament_id,
        'tournamentRoundId', p_tournament_round_id,
        'captureStatus',
            CASE WHEN v_last_action = 'CLOSED'
                 THEN 'CLOSED'
                 ELSE 'OPEN'
            END,
        'captureClosed', (v_last_action = 'CLOSED'),
        'canCloseCapture', (v_total > 0 AND v_pending = 0 AND v_last_action IS DISTINCT FROM 'CLOSED'),
        'canReopenCapture', (v_last_action = 'CLOSED'),
        'lastEvent', jsonb_build_object(
            'action', v_last_action,
            'occurredAt', v_last_at,
            'adminUserId', v_last_admin
        ),
        'summary', jsonb_build_object(
            'totalUnits', v_total,
            'physicalCaptured', v_physical_captured,
            'reconciliationCompleted', v_reconciliation_completed,
            'reconciliationNotRequired', v_reconciliation_not_required,
            'reconciliationRequiredCompleted', v_reconciliation_required_completed,
            'dns', v_dns,
            'wd', v_wd,
            'dnf', v_dnf,
            'dq', v_dq,
            'noCard', v_no_card,
            'otherTerminal', v_other_terminal,
            'resolvedUnits', v_resolved,
            'pendingUnits', v_pending
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_estado_cierre_captura_ronda_389(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_estado_cierre_captura_ronda_389(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.cerrar_captura_ronda_389(
    p_tournament_round_id uuid,
    p_notas text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_auth uuid := auth.uid();
    v_admin_id uuid;
    v_tournament_id uuid;
    v_state jsonb;
    v_pending integer;
BEGIN
    IF v_auth IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT r.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds r
     WHERE r.id = p_tournament_round_id
       AND r.activo = true
     FOR UPDATE;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'Ronda activa no encontrada.' USING ERRCODE='22023';
    END IF;

    IF NOT (
        public.is_superadmin(v_auth)
        OR public.is_tournament_organizer(v_auth, v_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No autorizado para cerrar captura.'
            USING ERRCODE='42501';
    END IF;

    v_admin_id := public.current_admin_id();

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No fue posible resolver el administrador actual.'
            USING ERRCODE='42501';
    END IF;

    v_state := public.obtener_estado_cierre_captura_ronda_389(
        p_tournament_round_id
    );

    IF COALESCE((v_state->>'captureClosed')::boolean, false) THEN
        RETURN v_state;
    END IF;

    v_pending := COALESCE(
        NULLIF(v_state#>>'{summary,pendingUnits}','')::integer,
        0
    );

    IF COALESCE(
        NULLIF(v_state#>>'{summary,totalUnits}','')::integer,
        0
    ) <= 0 THEN
        RAISE EXCEPTION 'No existen tarjetas/unidades emitidas para cerrar captura.'
            USING ERRCODE='55000';
    END IF;

    IF v_pending > 0 THEN
        RAISE EXCEPTION
            'No se puede cerrar captura: quedan % unidad(es) pendiente(s).',
            v_pending
            USING ERRCODE='55000';
    END IF;

    INSERT INTO public.tournament_round_capture_events (
        tournament_id,
        tournament_round_id,
        action,
        notes,
        summary_snapshot,
        performed_by_admin_user_id,
        performed_by_auth_user_id
    )
    VALUES (
        v_tournament_id,
        p_tournament_round_id,
        'CLOSED',
        NULLIF(btrim(p_notas),''),
        v_state->'summary',
        v_admin_id,
        v_auth
    );

    RETURN public.obtener_estado_cierre_captura_ronda_389(
        p_tournament_round_id
    );
END;
$$;

REVOKE ALL ON FUNCTION public.cerrar_captura_ronda_389(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cerrar_captura_ronda_389(uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.reabrir_captura_ronda_389(
    p_tournament_round_id uuid,
    p_motivo text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_auth uuid := auth.uid();
    v_admin_id uuid;
    v_tournament_id uuid;
    v_state jsonb;
BEGIN
    IF v_auth IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF NULLIF(btrim(p_motivo),'') IS NULL THEN
        RAISE EXCEPTION 'El motivo de reapertura es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    SELECT r.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds r
     WHERE r.id = p_tournament_round_id
       AND r.activo = true
     FOR UPDATE;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'Ronda activa no encontrada.' USING ERRCODE='22023';
    END IF;

    IF NOT (
        public.is_superadmin(v_auth)
        OR public.is_tournament_organizer(v_auth, v_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No autorizado para reabrir captura.'
            USING ERRCODE='42501';
    END IF;

    -- No se permite reabrir captura si ya existe cierre formal de categoría.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_round_category_competitive_closures c
         WHERE c.tournament_round_id = p_tournament_round_id
           AND c.competitive_status = 'FINAL'
    ) THEN
        RAISE EXCEPTION
            'No se puede reabrir captura: ya existe al menos una categoría cerrada formalmente.'
            USING ERRCODE='55000';
    END IF;

    v_state := public.obtener_estado_cierre_captura_ronda_389(
        p_tournament_round_id
    );

    IF NOT COALESCE((v_state->>'captureClosed')::boolean, false) THEN
        RETURN v_state;
    END IF;

    v_admin_id := public.current_admin_id();

    INSERT INTO public.tournament_round_capture_events (
        tournament_id,
        tournament_round_id,
        action,
        notes,
        summary_snapshot,
        performed_by_admin_user_id,
        performed_by_auth_user_id
    )
    VALUES (
        v_tournament_id,
        p_tournament_round_id,
        'REOPENED',
        btrim(p_motivo),
        v_state->'summary',
        v_admin_id,
        v_auth
    );

    RETURN public.obtener_estado_cierre_captura_ronda_389(
        p_tournament_round_id
    );
END;
$$;

REVOKE ALL ON FUNCTION public.reabrir_captura_ronda_389(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reabrir_captura_ronda_389(uuid,text) TO authenticated;

-- Gate duro: ningún cierre competitivo de categoría nuevo puede insertarse
-- si la ronda no tiene CAPTURA CERRADA.
CREATE OR REPLACE FUNCTION public._exigir_captura_cerrada_categoria_389()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_last_action text;
BEGIN
    SELECT e.action
      INTO v_last_action
      FROM public.tournament_round_capture_events e
     WHERE e.tournament_round_id = NEW.tournament_round_id
     ORDER BY e.occurred_at DESC, e.id DESC
     LIMIT 1;

    IF v_last_action IS DISTINCT FROM 'CLOSED' THEN
        RAISE EXCEPTION
            'No se puede cerrar la categoría: primero debe cerrarse formalmente la captura de la ronda.'
            USING ERRCODE='55000';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_exigir_captura_cerrada_categoria_389
ON public.tournament_round_category_competitive_closures;

CREATE TRIGGER trg_exigir_captura_cerrada_categoria_389
BEFORE INSERT ON public.tournament_round_category_competitive_closures
FOR EACH ROW
EXECUTE FUNCTION public._exigir_captura_cerrada_categoria_389();

-- Compatibilidad histórica:
-- POLLA SEPTIEMBRE, 24 ya cerró categoría/ronda antes de existir este hito.
-- NO se fabrica un evento retroactivo. El trigger aplica sólo a nuevos INSERT.

COMMIT;
