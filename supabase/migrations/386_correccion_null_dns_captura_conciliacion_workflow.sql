-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 386
-- CORRECCIÓN NULL EN DNS PARA ESTADO DE CAPTURA / CONCILIACIÓN
-- ============================================================================
-- EJECUCIÓN: MANUAL por el usuario en Supabase SQL Editor.
-- OBJETIVO:
--   Corregir obtener_estado_captura_conciliacion_ronda_264() para que una
--   tarjeta sin outcome NO sea excluida de requiredCards.
--
-- CAUSA:
--   (o.outcome_code='DNS') devuelve NULL cuando no existe outcome.
--   Posteriormente "WHERE NOT is_dns" también resulta NULL y excluye la tarjeta.
--
-- CORRECCIÓN:
--   COALESCE(o.outcome_code='DNS', false) AS is_dns
--
-- IMPORTANTE:
--   No modifica tarjetas, scores, outcomes, recepciones ni conciliaciones.
--   Al final reconstruye el workflow únicamente de torneos que actualmente
--   tienen tarjetas emitidas, para que los nodos materializados reflejen
--   inmediatamente el estado corregido.
-- ============================================================================

BEGIN;

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

            -- 386:
            -- Sin outcome, la tarjeta NO es DNS.
            COALESCE(o.outcome_code='DNS', false) AS is_dns,

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

-- Re-materializa el workflow solamente para torneos con tarjetas emitidas.
-- No altera las tarjetas ni sus datos operativos; reconstruye nodos derivados.
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT DISTINCT tr.tournament_id
          FROM public.tournament_rounds tr
          JOIN public.tournament_score_cards sc
            ON sc.tournament_round_id=tr.id
         WHERE tr.activo=true
           AND sc.status='issued'
    LOOP
        PERFORM public.reconstruir_workflow_extendido_385(r.tournament_id);
    END LOOP;
END;
$$;

COMMIT;
