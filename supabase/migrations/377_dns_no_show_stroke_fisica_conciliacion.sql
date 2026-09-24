-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 377
-- DNS / NO SE PRESENTÓ — STROKE PLAY INDIVIDUAL
-- Exclusión operativa de captura física y conciliación
--
-- IMPORTANTE:
--   * Ejecutar manualmente en Supabase PROD.
--   * No modifica salidas, grupos ni marcadores.
--   * No borra ni anula la tarjeta oficial.
--   * No da de baja la inscripción del torneo.
--   * Conserva la tarjeta emitida y registra outcome DNS auditable.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. RPC ADMINISTRATIVA ESPECÍFICA PARA MARCAR DNS
-- ============================================================================

CREATE OR REPLACE FUNCTION public.marcar_no_show_tarjeta_stroke_377(
    p_score_card_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_card record;
    v_scoring_engine text;
    v_participation_type text;
    v_reason text;
    v_existing_outcome text;
    v_physical_reception_id uuid;
    v_physical_scores integer := 0;
    v_reconciliation_id uuid;
    v_result jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_score_card_id IS NULL THEN
        RAISE EXCEPTION 'score_card_id es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    v_reason := btrim(COALESCE(p_reason,''));

    IF length(v_reason) < 5 THEN
        RAISE EXCEPTION 'El motivo debe tener al menos 5 caracteres.'
            USING ERRCODE='22023';
    END IF;

    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.status
      INTO v_card
      FROM public.tournament_score_cards sc
     WHERE sc.id=p_score_card_id
     FOR UPDATE;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF v_card.status <> 'issued' THEN
        RAISE EXCEPTION 'Sólo puede marcarse NO SHOW sobre una tarjeta oficial emitida.'
            USING ERRCODE='55000';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_card.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para modificar esta tarjeta.'
            USING ERRCODE='42501';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM public.tournament_round_competitive_closures c
         WHERE c.tournament_round_id=v_card.tournament_round_id
    ) THEN
        RAISE EXCEPTION 'La ronda ya tiene cierre competitivo formal y no admite NO SHOW.'
            USING ERRCODE='55000';
    END IF;

    SELECT
        s.scoring_engine,
        s.participation_type
      INTO
        v_scoring_engine,
        v_participation_type
      FROM public.tournament_round_condition_snapshots s
     WHERE s.tournament_round_id=v_card.tournament_round_id
     ORDER BY s.created_at DESC,s.id DESC
     LIMIT 1;

    IF NOT (
        v_scoring_engine IN ('stroke','stroke_play')
        AND v_participation_type='individual'
    ) THEN
        RAISE EXCEPTION
            'NO SHOW 377 sólo está habilitado para Stroke Play individual. Motor=% / participación=%.',
            COALESCE(v_scoring_engine,'NULL'),
            COALESCE(v_participation_type,'NULL')
            USING ERRCODE='0A000';
    END IF;

    SELECT o.outcome_code
      INTO v_existing_outcome
      FROM public.tournament_scorecard_round_outcomes o
     WHERE o.score_card_id=v_card.id;

    IF v_existing_outcome='DNS' THEN
        RETURN jsonb_build_object(
            'scoreCardId',v_card.id,
            'tournamentRoundId',v_card.tournament_round_id,
            'outcomeCode','DNS',
            'changed',false,
            'alreadyNoShow',true
        );
    END IF;

    IF v_existing_outcome IS NOT NULL THEN
        RAISE EXCEPTION
            'La tarjeta ya tiene outcome competitivo %; no puede sustituirse por DNS mediante esta operación.',
            v_existing_outcome
            USING ERRCODE='55000';
    END IF;

    -- DNS significa que el jugador no inició la ronda.
    -- Por eso se bloquea si existe evidencia real de captura digital.
    IF public._tarjeta_tiene_captura_digital_real(v_card.id) THEN
        RAISE EXCEPTION
            'No puede marcarse NO SHOW: la tarjeta ya tiene captura digital real.'
            USING ERRCODE='55000';
    END IF;

    SELECT pr.id
      INTO v_physical_reception_id
      FROM public.tournament_scorecard_physical_receptions pr
     WHERE pr.score_card_id=v_card.id
     LIMIT 1;

    IF v_physical_reception_id IS NOT NULL THEN
        RAISE EXCEPTION
            'No puede marcarse NO SHOW: la tarjeta física ya fue recibida.'
            USING ERRCODE='55000';
    END IF;

    SELECT count(*)::integer
      INTO v_physical_scores
      FROM public.tournament_scorecard_physical_hole_scores phs
     WHERE phs.score_card_id=v_card.id;

    IF v_physical_scores>0 THEN
        RAISE EXCEPTION
            'No puede marcarse NO SHOW: existen resultados de captura física.'
            USING ERRCODE='55000';
    END IF;

    SELECT r.id
      INTO v_reconciliation_id
      FROM public.tournament_scorecard_reconciliations r
     WHERE r.score_card_id=v_card.id
     LIMIT 1;

    IF v_reconciliation_id IS NOT NULL THEN
        RAISE EXCEPTION
            'No puede marcarse NO SHOW: la conciliación de la tarjeta ya fue iniciada.'
            USING ERRCODE='55000';
    END IF;

    -- La RPC existente es la autoridad para persistir el outcome y su auditoría.
    v_result := public.establecer_outcome_competitivo_tarjeta(
        v_card.id,
        'DNS',
        v_reason
    );

    RETURN v_result || jsonb_build_object(
        'operationalPhysicalCaptureRequired',false,
        'operationalReconciliationRequired',false,
        'startAssignmentChanged',false,
        'markerAssignmentsChanged',false
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.marcar_no_show_tarjeta_stroke_377(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marcar_no_show_tarjeta_stroke_377(uuid,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.marcar_no_show_tarjeta_stroke_377(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.marcar_no_show_tarjeta_stroke_377(uuid,text) TO service_role;


-- ============================================================================
-- 2. ESTADO AGREGADO DE CAPTURA / CONCILIACIÓN
--
-- DNS sigue contando como tarjeta oficial emitida, pero deja de formar parte
-- de las tarjetas requeridas para captura física y conciliación.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_estado_captura_conciliacion_ronda_264(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_round record;

    v_total_issued integer := 0;
    v_required integer := 0;
    v_dns integer := 0;

    v_not_received integer := 0;
    v_received integer := 0;
    v_in_capture integer := 0;
    v_physical_captured integer := 0;

    v_digital_used integer := 0;

    v_nrq integer := 0;
    v_reconciled integer := 0;
    v_pending_reconciliation integer := 0;
    v_not_applicable_yet integer := 0;

    v_physical_complete boolean := false;
    v_reconciliation_complete boolean := false;

    v_physical_status text;
    v_reconciliation_status text;
BEGIN
    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    SELECT
        tr.id,
        tr.tournament_id,
        tr.numero_ronda,
        tr.fecha,
        t.estatus::text AS tournament_status
      INTO v_round
      FROM public.tournament_rounds tr
      JOIN public.tournaments t
        ON t.id=tr.tournament_id
     WHERE tr.id=p_tournament_round_id
       AND tr.activo=true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La ronda indicada no existe o no está activa.'
            USING ERRCODE='22023';
    END IF;

    WITH cards AS (
        SELECT
            sc.id AS score_card_id,
            (o.outcome_code='DNS') AS is_dns,

            COALESCE(pr.status::text,'NOT_RECEIVED') AS physical_status,

            public._tarjeta_tiene_captura_digital_real(sc.id) AS digital_used,

            rec.status::text AS reconciliation_status,

            COALESCE(
                rec.reconciliation_requirement::text,
                'REQUIRED'
            ) AS reconciliation_requirement,

            CASE
                WHEN o.outcome_code='DNS'
                    THEN 'DNS'

                WHEN COALESCE(
                    rec.reconciliation_requirement::text,
                    'REQUIRED'
                )='NOT_REQUIRED'
                    THEN 'NRQ'

                WHEN public._tarjeta_tiene_captura_digital_real(sc.id)
                     AND rec.status::text='COMPLETED'
                    THEN 'CONCILIADA'

                WHEN public._tarjeta_tiene_captura_digital_real(sc.id)
                    THEN 'PENDIENTE_CONCILIAR'

                WHEN pr.status::text='CAPTURED'
                    THEN 'NRQ'

                ELSE 'NO_APLICA_AUN'
            END AS operational_reconciliation_status

        FROM public.tournament_score_cards sc

        LEFT JOIN public.tournament_scorecard_round_outcomes o
          ON o.score_card_id=sc.id

        LEFT JOIN public.tournament_scorecard_physical_receptions pr
          ON pr.score_card_id=sc.id

        LEFT JOIN public.tournament_scorecard_reconciliations rec
          ON rec.score_card_id=sc.id

        WHERE sc.tournament_round_id=p_tournament_round_id
          AND sc.status='issued'
    )
    SELECT
        count(*)::integer,
        count(*) FILTER (WHERE is_dns)::integer,
        count(*) FILTER (WHERE NOT is_dns)::integer,

        count(*) FILTER (
            WHERE NOT is_dns AND physical_status='NOT_RECEIVED'
        )::integer,

        count(*) FILTER (
            WHERE NOT is_dns AND physical_status='RECEIVED'
        )::integer,

        count(*) FILTER (
            WHERE NOT is_dns AND physical_status='IN_CAPTURE'
        )::integer,

        count(*) FILTER (
            WHERE NOT is_dns AND physical_status='CAPTURED'
        )::integer,

        count(*) FILTER (
            WHERE NOT is_dns AND digital_used
        )::integer,

        count(*) FILTER (
            WHERE NOT is_dns
              AND operational_reconciliation_status='NRQ'
        )::integer,

        count(*) FILTER (
            WHERE NOT is_dns
              AND operational_reconciliation_status='CONCILIADA'
        )::integer,

        count(*) FILTER (
            WHERE NOT is_dns
              AND operational_reconciliation_status='PENDIENTE_CONCILIAR'
        )::integer,

        count(*) FILTER (
            WHERE NOT is_dns
              AND operational_reconciliation_status='NO_APLICA_AUN'
        )::integer

      INTO
        v_total_issued,
        v_dns,
        v_required,
        v_not_received,
        v_received,
        v_in_capture,
        v_physical_captured,
        v_digital_used,
        v_nrq,
        v_reconciled,
        v_pending_reconciliation,
        v_not_applicable_yet
      FROM cards;

    -- Si existen tarjetas emitidas y todas son DNS, operacionalmente no queda
    -- ninguna tarjeta física por capturar: el paso está completo.
    v_physical_complete :=
        v_total_issued>0
        AND v_physical_captured=v_required;

    v_reconciliation_complete :=
        v_total_issued>0
        AND v_physical_complete
        AND v_pending_reconciliation=0
        AND v_not_applicable_yet=0
        AND (v_nrq+v_reconciled)=v_required;

    v_physical_status :=
        CASE
            WHEN v_total_issued=0
                THEN 'WAITING_CARDS'
            WHEN v_physical_complete
                THEN 'COMPLETE'
            WHEN v_physical_captured>0
              OR v_received>0
              OR v_in_capture>0
                THEN 'IN_PROGRESS'
            ELSE 'PENDING'
        END;

    v_reconciliation_status :=
        CASE
            WHEN v_total_issued=0
                THEN 'WAITING_CARDS'
            WHEN NOT v_physical_complete
                THEN 'WAITING_PHYSICAL'
            WHEN v_reconciliation_complete
                THEN 'COMPLETE'
            ELSE 'PENDING'
        END;

    RETURN jsonb_build_object(
        'tournamentId',v_round.tournament_id,
        'tournamentRoundId',p_tournament_round_id,
        'roundNumber',v_round.numero_ronda,
        'roundDate',v_round.fecha,
        'tournamentStatus',v_round.tournament_status,

        'physicalCapture',jsonb_build_object(
            'status',v_physical_status,
            'complete',v_physical_complete,
            'totalCards',v_total_issued,
            'requiredCards',v_required,
            'dns',v_dns,
            'notReceived',v_not_received,
            'received',v_received,
            'inCapture',v_in_capture,
            'captured',v_physical_captured
        ),

        'reconciliation',jsonb_build_object(
            'status',v_reconciliation_status,
            'complete',v_reconciliation_complete,
            'totalCards',v_total_issued,
            'requiredCards',v_required,
            'dns',v_dns,
            'digitalUsed',v_digital_used,
            'nrq',v_nrq,
            'reconciled',v_reconciled,
            'pendingReconciliation',v_pending_reconciliation,
            'notApplicableYet',v_not_applicable_yet
        )
    );
END;
$function$;


-- ============================================================================
-- 3. DETALLE OPERATIVO DE CONCILIACIÓN
--
-- DNS se devuelve explícitamente como estado operativo propio y nunca como
-- PENDIENTE_CONCILIAR / NO_APLICA_AUN.
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
            USING ERRCODE='42501';
    END IF;

    SELECT tr.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar la conciliación de esta ronda.'
            USING ERRCODE='42501';
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
                COALESCE(pr.status,'NOT_RECEIVED') AS physical_status,
                rec.status AS technical_reconciliation_status,
                COALESCE(rec.reconciliation_requirement,'REQUIRED') AS reconciliation_requirement,
                public._tarjeta_tiene_captura_digital_real(sc.id) AS digital_used,
                o.outcome_code,
                o.reason AS outcome_reason
            FROM public.tournament_score_cards sc
            JOIN public.tournament_round_start_validation_units u
              ON u.id=sc.validation_unit_id
             AND u.validation_id=sc.validation_id
            LEFT JOIN public.tournament_categories tc
              ON tc.id=u.tournament_category_id
            LEFT JOIN public.categories c
              ON c.id=tc.category_id
            LEFT JOIN public.tournament_scorecard_physical_receptions pr
              ON pr.score_card_id=sc.id
            LEFT JOIN public.tournament_scorecard_reconciliations rec
              ON rec.score_card_id=sc.id
            LEFT JOIN public.tournament_scorecard_round_outcomes o
              ON o.score_card_id=sc.id
            WHERE sc.tournament_round_id=p_tournament_round_id
              AND sc.status='issued'
        ),
        classified AS (
            SELECT
                b.*,
                CASE
                    WHEN b.outcome_code='DNS'
                        THEN 'DNS'
                    WHEN b.reconciliation_requirement='NOT_REQUIRED'
                        THEN 'NRQ'
                    WHEN b.digital_used
                         AND b.technical_reconciliation_status='COMPLETED'
                        THEN 'CONCILIADA'
                    WHEN b.digital_used
                        THEN 'PENDIENTE_CONCILIAR'
                    WHEN b.physical_status='CAPTURED'
                        THEN 'NRQ'
                    ELSE 'NO_APLICA_AUN'
                END AS operational_status
            FROM base b
        )
        SELECT jsonb_build_object(
            'tournamentId',v_tournament_id,
            'tournamentRoundId',p_tournament_round_id,
            'summary',jsonb_build_object(
                'totalCards',count(*),
                'requiredCards',count(*) FILTER (WHERE outcome_code IS DISTINCT FROM 'DNS'),
                'dns',count(*) FILTER (WHERE outcome_code='DNS'),
                'nrq',count(*) FILTER (WHERE operational_status='NRQ'),
                'conciliadas',count(*) FILTER (WHERE operational_status='CONCILIADA'),
                'pendientesConciliar',count(*) FILTER (WHERE operational_status='PENDIENTE_CONCILIAR'),
                'noAplicaAun',count(*) FILTER (WHERE operational_status='NO_APLICA_AUN')
            ),
            'cards',COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'scoreCardId',score_card_id,
                        'cardNumber',card_number,
                        'cardFolio',card_folio,
                        'playerId',player_id,
                        'playerName',player_name,
                        'tournamentCategoryId',tournament_category_id,
                        'categoryCode',category_code,
                        'categoryName',category_name,
                        'categoryDisplayOrder',category_display_order,
                        'physicalStatus',physical_status,
                        'digitalUsed',digital_used,
                        'reconciliationRequirement',reconciliation_requirement,
                        'technicalReconciliationStatus',technical_reconciliation_status,
                        'operationalStatus',operational_status,
                        'outcomeCode',outcome_code,
                        'outcomeReason',outcome_reason,
                        'requiresPhysicalCapture',(outcome_code IS DISTINCT FROM 'DNS'),
                        'requiresReconciliation',(outcome_code IS DISTINCT FROM 'DNS')
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


-- ============================================================================
-- 4. PERMISOS
-- Reafirmar permisos después de CREATE OR REPLACE.
-- ============================================================================

REVOKE ALL ON FUNCTION public.obtener_estado_captura_conciliacion_ronda_264(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_estado_captura_conciliacion_ronda_264(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_estado_captura_conciliacion_ronda_264(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_estado_captura_conciliacion_ronda_264(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.obtener_estados_conciliacion_ronda(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_estados_conciliacion_ronda(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_estados_conciliacion_ronda(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_estados_conciliacion_ronda(uuid) TO service_role;

COMMIT;
