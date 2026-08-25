-- ============================================================================
-- MIGRACION 184 FASE 1
-- NRQ (NO REQUIERE CONCILIACION) + AUTOCIERRE AL FINALIZAR CAPTURA FISICA
-- TEE CENTRAL
--
-- OBJETIVO
-- 1) Distinguir explícitamente tarjetas que NO requieren conciliación porque
--    nunca tuvieron captura digital real.
-- 2) Cuando la captura física termina y no hubo captura digital real, marcar
--    automáticamente la conciliación técnica como COMPLETED en la misma
--    transacción.
-- 3) Persistir la razón NOT_REQUIRED para que UI pueda mostrar NRQ sin confundir
--    ese caso con una conciliación digital/física completada.
-- 4) Impedir que posteriormente se capturen scores digitales sobre una tarjeta
--    ya cerrada como NRQ.
-- 5) Exponer una RPC de lectura por ronda con estados operativos:
--       NRQ
--       CONCILIADA
--       PENDIENTE_CONCILIAR
--
-- REGLA DE NEGOCIO
-- - Tarjeta física: obligatoria.
-- - Tarjeta digital: opcional.
-- - "Digital real" NO significa que exista sesión/filas inicializadas.
--   Existe captura digital real cuando:
--      a) capture_session.started_at IS NOT NULL, o
--      b) capture_session.status IN ('in_progress','captured'), o
--      c) existe al menos un gross_score digital no nulo.
-- - Si al finalizar la captura física NO existe captura digital real:
--      requirement = NOT_REQUIRED
--      reconciliation.status = COMPLETED
--      estado operativo = NRQ
-- - Si sí hubo digital:
--      el flujo normal de conciliación se conserva intacto.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. PERSISTIR SI LA CONCILIACION ERA REQUERIDA
-- ============================================================================
ALTER TABLE public.tournament_scorecard_reconciliations
    ADD COLUMN IF NOT EXISTS reconciliation_requirement text;

UPDATE public.tournament_scorecard_reconciliations
SET reconciliation_requirement = 'REQUIRED'
WHERE reconciliation_requirement IS NULL;

ALTER TABLE public.tournament_scorecard_reconciliations
    ALTER COLUMN reconciliation_requirement SET DEFAULT 'REQUIRED';

ALTER TABLE public.tournament_scorecard_reconciliations
    ALTER COLUMN reconciliation_requirement SET NOT NULL;

ALTER TABLE public.tournament_scorecard_reconciliations
    DROP CONSTRAINT IF EXISTS tournament_scorecard_reconciliations_requirement_check;

ALTER TABLE public.tournament_scorecard_reconciliations
    ADD CONSTRAINT tournament_scorecard_reconciliations_requirement_check
    CHECK (reconciliation_requirement IN ('REQUIRED','NOT_REQUIRED'));

COMMENT ON COLUMN public.tournament_scorecard_reconciliations.reconciliation_requirement IS
'REQUIRED = hubo captura digital real y existe algo que conciliar; NOT_REQUIRED = tarjeta física-only, UI debe mostrar NRQ aunque el status técnico sea COMPLETED.';

-- ============================================================================
-- 02. EVENTO AUDITABLE NRQ
-- ============================================================================
ALTER TABLE public.tournament_scorecard_reconciliation_events
    DROP CONSTRAINT IF EXISTS tournament_scorecard_reconciliation_events_event_type_check;

ALTER TABLE public.tournament_scorecard_reconciliation_events
    ADD CONSTRAINT tournament_scorecard_reconciliation_events_event_type_check
    CHECK (event_type IN (
        'reconciliation_started',
        'hole_resolved',
        'hole_resolution_changed',
        'reconciliation_completed',
        'reconciliation_voided',
        'reconciliation_not_required'
    ));

-- ============================================================================
-- 03. HELPER: EXISTE CAPTURA DIGITAL REAL
-- ============================================================================
CREATE OR REPLACE FUNCTION public._tarjeta_tiene_captura_digital_real(
    p_score_card_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT
        EXISTS (
            SELECT 1
            FROM public.tournament_scorecard_capture_sessions cs
            WHERE cs.score_card_id = p_score_card_id
              AND (
                    cs.started_at IS NOT NULL
                 OR cs.status IN ('in_progress','captured')
              )
        )
        OR EXISTS (
            SELECT 1
            FROM public.tournament_scorecard_hole_scores hs
            WHERE hs.score_card_id = p_score_card_id
              AND hs.gross_score IS NOT NULL
        );
$function$;

REVOKE ALL ON FUNCTION public._tarjeta_tiene_captura_digital_real(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._tarjeta_tiene_captura_digital_real(uuid)
TO service_role;

-- ============================================================================
-- 04. BACKFILL HISTORICO SEGURO
--
-- También normaliza tarjetas físicas YA CAPTURED anteriores a esta migración.
-- Si objetivamente nunca hubo captura digital real, deben quedar NRQ ahora,
-- sin esperar a que el trigger futuro vuelva a dispararse.
--
-- El actor histórico se deriva del administrador que finalizó/recibió la
-- tarjeta física. No se alteran scores ni resultados oficiales.
-- ============================================================================

-- 04.1 Crear conciliación técnica para physical-only CAPTURED que nunca tuvo
--      fila de conciliación.
INSERT INTO public.tournament_scorecard_reconciliations (
    score_card_id,
    tournament_id,
    tournament_round_id,
    status,
    reconciliation_requirement,
    started_at,
    started_by_admin_user_id,
    completed_at,
    completed_by_admin_user_id,
    notes
)
SELECT
    pr.score_card_id,
    sc.tournament_id,
    sc.tournament_round_id,
    'COMPLETED',
    'NOT_REQUIRED',
    COALESCE(pr.capture_completed_at, pr.received_at, now()),
    COALESCE(au_done.id, au_received.id),
    COALESCE(pr.capture_completed_at, pr.received_at, now()),
    COALESCE(au_done.id, au_received.id),
    'NRQ histórico: tarjeta física finalizada sin captura digital real.'
FROM public.tournament_scorecard_physical_receptions pr
JOIN public.tournament_score_cards sc
  ON sc.id = pr.score_card_id
 AND sc.status = 'issued'
LEFT JOIN public.admin_users au_done
  ON au_done.auth_user_id = pr.capture_completed_by_auth_user_id
 AND au_done.activo
LEFT JOIN public.admin_users au_received
  ON au_received.auth_user_id = pr.received_by_auth_user_id
 AND au_received.activo
WHERE pr.status = 'CAPTURED'
  AND NOT public._tarjeta_tiene_captura_digital_real(pr.score_card_id)
  AND COALESCE(au_done.id, au_received.id) IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM public.tournament_scorecard_reconciliations r
      WHERE r.score_card_id = pr.score_card_id
  );

-- 04.2 Reconciliaciones existentes no anuladas: si son physical-only y la
--      física ya terminó, completar técnicamente y marcar NOT_REQUIRED.
UPDATE public.tournament_scorecard_reconciliations r
SET status = 'COMPLETED',
    reconciliation_requirement = 'NOT_REQUIRED',
    started_at = COALESCE(
        r.started_at,
        pr.capture_completed_at,
        pr.received_at,
        now()
    ),
    started_by_admin_user_id = COALESCE(
        r.started_by_admin_user_id,
        au_done.id,
        au_received.id
    ),
    completed_at = COALESCE(
        r.completed_at,
        pr.capture_completed_at,
        pr.received_at,
        now()
    ),
    completed_by_admin_user_id = COALESCE(
        r.completed_by_admin_user_id,
        au_done.id,
        au_received.id
    ),
    notes = COALESCE(
        NULLIF(btrim(r.notes), ''),
        'NRQ histórico: tarjeta física finalizada sin captura digital real.'
    ),
    updated_at = now()
FROM public.tournament_scorecard_physical_receptions pr
LEFT JOIN public.admin_users au_done
  ON au_done.auth_user_id = pr.capture_completed_by_auth_user_id
 AND au_done.activo
LEFT JOIN public.admin_users au_received
  ON au_received.auth_user_id = pr.received_by_auth_user_id
 AND au_received.activo
WHERE r.score_card_id = pr.score_card_id
  AND pr.status = 'CAPTURED'
  AND r.status <> 'VOIDED'
  AND COALESCE(au_done.id, au_received.id) IS NOT NULL
  AND NOT public._tarjeta_tiene_captura_digital_real(r.score_card_id);

-- 04.3 Auditoría histórica NRQ, sin duplicar eventos.
INSERT INTO public.tournament_scorecard_reconciliation_events (
    reconciliation_id,
    score_card_id,
    event_type,
    actor_admin_user_id,
    reason
)
SELECT
    r.id,
    r.score_card_id,
    'reconciliation_not_required',
    r.completed_by_admin_user_id,
    'NRQ: no existió captura digital real al finalizar la tarjeta física.'
FROM public.tournament_scorecard_reconciliations r
WHERE r.status = 'COMPLETED'
  AND r.reconciliation_requirement = 'NOT_REQUIRED'
  AND r.completed_by_admin_user_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM public.tournament_scorecard_reconciliation_events e
      WHERE e.reconciliation_id = r.id
        AND e.event_type = 'reconciliation_not_required'
  );

-- ============================================================================
-- 05. TRIGGER: AL FINALIZAR FISICA, AUTOCOMPLETAR NRQ
-- ============================================================================
CREATE OR REPLACE FUNCTION public._autocompletar_conciliacion_nrq_al_finalizar_fisica()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_admin_id uuid;
    v_card record;
    v_rec public.tournament_scorecard_reconciliations;
BEGIN
    IF NEW.status <> 'CAPTURED'
       OR OLD.status IS NOT DISTINCT FROM 'CAPTURED'
    THEN
        RETURN NEW;
    END IF;

    -- Serializa la decisión NRQ vs inicio/captura digital de la misma tarjeta.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(NEW.score_card_id::text, 18401)
    );

    IF public._tarjeta_tiene_captura_digital_real(NEW.score_card_id) THEN
        RETURN NEW;
    END IF;

    SELECT sc.id, sc.tournament_id, sc.tournament_round_id
      INTO v_card
      FROM public.tournament_score_cards sc
     WHERE sc.id = NEW.score_card_id
       AND sc.status = 'issued'
     LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION
            'No se puede cerrar NRQ: la tarjeta oficial no existe o no está emitida.'
            USING ERRCODE = '55000';
    END IF;

    v_admin_id := public._scorecard_current_admin_id();

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No se puede cerrar NRQ: el usuario no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_rec
      FROM public.tournament_scorecard_reconciliations r
     WHERE r.score_card_id = NEW.score_card_id
     FOR UPDATE;

    -- Una conciliación anulada no se revive silenciosamente.
    IF v_rec.id IS NOT NULL AND v_rec.status = 'VOIDED' THEN
        RETURN NEW;
    END IF;

    IF v_rec.id IS NULL THEN
        INSERT INTO public.tournament_scorecard_reconciliations (
            score_card_id,
            tournament_id,
            tournament_round_id,
            status,
            reconciliation_requirement,
            started_at,
            started_by_admin_user_id,
            completed_at,
            completed_by_admin_user_id,
            notes
        )
        VALUES (
            NEW.score_card_id,
            v_card.tournament_id,
            v_card.tournament_round_id,
            'COMPLETED',
            'NOT_REQUIRED',
            now(),
            v_admin_id,
            now(),
            v_admin_id,
            'NRQ: tarjeta física finalizada sin captura digital real.'
        )
        RETURNING * INTO v_rec;
    ELSE
        UPDATE public.tournament_scorecard_reconciliations
           SET status = 'COMPLETED',
               reconciliation_requirement = 'NOT_REQUIRED',
               started_at = COALESCE(started_at, now()),
               started_by_admin_user_id = COALESCE(started_by_admin_user_id, v_admin_id),
               completed_at = COALESCE(completed_at, now()),
               completed_by_admin_user_id = COALESCE(completed_by_admin_user_id, v_admin_id),
               notes = COALESCE(
                   NULLIF(btrim(notes), ''),
                   'NRQ: tarjeta física finalizada sin captura digital real.'
               ),
               updated_at = now()
         WHERE id = v_rec.id
         RETURNING * INTO v_rec;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.tournament_scorecard_reconciliation_events e
        WHERE e.reconciliation_id = v_rec.id
          AND e.event_type = 'reconciliation_not_required'
    ) THEN
        INSERT INTO public.tournament_scorecard_reconciliation_events (
            reconciliation_id,
            score_card_id,
            event_type,
            actor_admin_user_id,
            reason
        )
        VALUES (
            v_rec.id,
            NEW.score_card_id,
            'reconciliation_not_required',
            v_admin_id,
            'NRQ: no existió captura digital real al finalizar la tarjeta física.'
        );
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_autocompletar_conciliacion_nrq_al_finalizar_fisica
ON public.tournament_scorecard_physical_receptions;

CREATE TRIGGER trg_autocompletar_conciliacion_nrq_al_finalizar_fisica
AFTER UPDATE OF status
ON public.tournament_scorecard_physical_receptions
FOR EACH ROW
WHEN (NEW.status = 'CAPTURED' AND OLD.status IS DISTINCT FROM 'CAPTURED')
EXECUTE FUNCTION public._autocompletar_conciliacion_nrq_al_finalizar_fisica();

-- ============================================================================
-- 06. GUARD: UNA TARJETA NRQ YA NO PUEDE RECIBIR CAPTURA DIGITAL
-- ============================================================================
CREATE OR REPLACE FUNCTION public._proteger_captura_digital_despues_nrq()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_score_card_id uuid;
BEGIN
    v_score_card_id := NEW.score_card_id;

    IF NEW.gross_score IS NULL THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE'
       AND OLD.gross_score IS NOT DISTINCT FROM NEW.gross_score
    THEN
        RETURN NEW;
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(v_score_card_id::text, 18401)
    );

    IF EXISTS (
        SELECT 1
        FROM public.tournament_scorecard_reconciliations r
        WHERE r.score_card_id = v_score_card_id
          AND r.status = 'COMPLETED'
          AND r.reconciliation_requirement = 'NOT_REQUIRED'
    ) THEN
        RAISE EXCEPTION
            'Esta tarjeta fue cerrada como NRQ (No requiere conciliación) y ya no admite captura digital.'
            USING ERRCODE = '55000',
                  HINT = 'La tarjeta física ya fue finalizada sin evidencia digital.';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_proteger_captura_digital_despues_nrq
ON public.tournament_scorecard_hole_scores;

CREATE TRIGGER trg_proteger_captura_digital_despues_nrq
BEFORE INSERT OR UPDATE OF gross_score
ON public.tournament_scorecard_hole_scores
FOR EACH ROW
EXECUTE FUNCTION public._proteger_captura_digital_despues_nrq();

-- ============================================================================
-- 07. RPC DE LECTURA: ESTADO OPERATIVO DE CONCILIACION POR RONDA
--
-- No sustituye las RPC competitivas. Es una proyección operativa para UI,
-- filtros y drill-down.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.obtener_estados_conciliacion_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tr.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds tr
     WHERE tr.id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar la conciliación de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    RETURN (
        WITH base AS (
            SELECT
                sc.id AS score_card_id,
                sc.card_number,
                sc.card_folio,
                u.player_id,
                u.unit_name AS player_name,
                u.tournament_category_id,
                c.codigo AS category_code,
                c.nombre AS category_name,
                c.display_order AS category_display_order,
                COALESCE(pr.status, 'NOT_RECEIVED') AS physical_status,
                rec.status AS technical_reconciliation_status,
                COALESCE(rec.reconciliation_requirement, 'REQUIRED') AS reconciliation_requirement,
                public._tarjeta_tiene_captura_digital_real(sc.id) AS digital_used
            FROM public.tournament_score_cards sc
            JOIN public.tournament_round_start_validation_units u
              ON u.id = sc.validation_unit_id
             AND u.validation_id = sc.validation_id
            LEFT JOIN public.tournament_categories tc
              ON tc.id = u.tournament_category_id
            LEFT JOIN public.categories c
              ON c.id = tc.category_id
            LEFT JOIN public.tournament_scorecard_physical_receptions pr
              ON pr.score_card_id = sc.id
            LEFT JOIN public.tournament_scorecard_reconciliations rec
              ON rec.score_card_id = sc.id
            WHERE sc.tournament_round_id = p_tournament_round_id
              AND sc.status = 'issued'
        ), classified AS (
            SELECT
                b.*,
                CASE
                    WHEN b.reconciliation_requirement = 'NOT_REQUIRED'
                        THEN 'NRQ'
                    WHEN b.digital_used
                         AND b.technical_reconciliation_status = 'COMPLETED'
                        THEN 'CONCILIADA'
                    WHEN b.digital_used
                        THEN 'PENDIENTE_CONCILIAR'
                    WHEN b.physical_status = 'CAPTURED'
                        THEN 'NRQ'
                    ELSE 'NO_APLICA_AUN'
                END AS operational_status
            FROM base b
        )
        SELECT jsonb_build_object(
            'tournamentId', v_tournament_id,
            'tournamentRoundId', p_tournament_round_id,
            'summary', jsonb_build_object(
                'totalCards', count(*),
                'nrq', count(*) FILTER (WHERE operational_status = 'NRQ'),
                'conciliadas', count(*) FILTER (WHERE operational_status = 'CONCILIADA'),
                'pendientesConciliar', count(*) FILTER (WHERE operational_status = 'PENDIENTE_CONCILIAR'),
                'noAplicaAun', count(*) FILTER (WHERE operational_status = 'NO_APLICA_AUN')
            ),
            'cards', COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'scoreCardId', score_card_id,
                        'cardNumber', card_number,
                        'cardFolio', card_folio,
                        'playerId', player_id,
                        'playerName', player_name,
                        'tournamentCategoryId', tournament_category_id,
                        'categoryCode', category_code,
                        'categoryName', category_name,
                        'categoryDisplayOrder', category_display_order,
                        'physicalStatus', physical_status,
                        'digitalUsed', digital_used,
                        'reconciliationRequirement', reconciliation_requirement,
                        'technicalReconciliationStatus', technical_reconciliation_status,
                        'operationalStatus', operational_status
                    )
                    ORDER BY
                        category_display_order NULLS LAST,
                        category_name NULLS LAST,
                        card_number,
                        player_name
                ),
                '[]'::jsonb
            )
        )
        FROM classified
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_estados_conciliacion_ronda(uuid)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_estados_conciliacion_ronda(uuid)
TO authenticated, service_role;

COMMIT;
