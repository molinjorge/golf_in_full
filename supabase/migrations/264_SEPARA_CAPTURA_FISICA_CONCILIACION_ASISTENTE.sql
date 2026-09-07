-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 264
-- Separar CAPTURA FÍSICA y CONCILIACIÓN en el Asistente Operativo
-- ============================================================
--
-- DIAGNÓSTICO
-- El backend ya distingue claramente:
--   1) recepción/captura física de tarjeta;
--   2) conciliación DIGITAL vs FÍSICO.
--
-- Sin embargo, el Asistente todavía heredaba un único ROUND_SCORING
-- titulado "Captura y conciliación".
--
-- Esto podía dar instrucciones ambiguas:
-- - no distingue si faltan tarjetas físicas;
-- - no distingue si ya terminó la captura física pero quedan diferencias;
-- - no distingue si la conciliación no aplica (NRQ);
-- - no ofrece una etapa propia de conciliación.
--
-- OBJETIVO
-- Reemplazar únicamente la presentación operativa de ROUND_SCORING por:
--
--   ROUND_PHYSICAL_CAPTURE
--   ROUND_RECONCILIATION
--
-- SIN cambiar:
-- - captura digital;
-- - captura física;
-- - reglas NRQ;
-- - conciliaciones;
-- - resultados;
-- - cierres;
-- - Stroke Play / Stableford / A-Go-Go.
--
-- El gate START_TOURNAMENT de 260 se preserva.
-- ============================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- A. Estado agregado y explícito de Captura Física + Conciliación
-- ---------------------------------------------------------------------------

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

    v_total integer := 0;

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
        RAISE EXCEPTION
            'tournament_round_id es obligatorio.'
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
        RAISE EXCEPTION
            'La ronda indicada no existe o no está activa.'
            USING ERRCODE='22023';
    END IF;

    -- Esta función es sólo un agregado operacional. Las RPC individuales
    -- conservan toda la autorización real de escritura.
    WITH cards AS (
        SELECT
            sc.id AS score_card_id,

            COALESCE(
                pr.status::text,
                'NOT_RECEIVED'
            ) AS physical_status,

            public._tarjeta_tiene_captura_digital_real(sc.id)
                AS digital_used,

            rec.status::text AS reconciliation_status,

            COALESCE(
                rec.reconciliation_requirement::text,
                'REQUIRED'
            ) AS reconciliation_requirement,

            CASE
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

        LEFT JOIN public.tournament_scorecard_physical_receptions pr
          ON pr.score_card_id=sc.id

        LEFT JOIN public.tournament_scorecard_reconciliations rec
          ON rec.score_card_id=sc.id

        WHERE sc.tournament_round_id=p_tournament_round_id
          AND sc.status='issued'
    )
    SELECT
        count(*)::integer,

        count(*) FILTER(
            WHERE physical_status='NOT_RECEIVED'
        )::integer,

        count(*) FILTER(
            WHERE physical_status='RECEIVED'
        )::integer,

        count(*) FILTER(
            WHERE physical_status='IN_CAPTURE'
        )::integer,

        count(*) FILTER(
            WHERE physical_status='CAPTURED'
        )::integer,

        count(*) FILTER(
            WHERE digital_used
        )::integer,

        count(*) FILTER(
            WHERE operational_reconciliation_status='NRQ'
        )::integer,

        count(*) FILTER(
            WHERE operational_reconciliation_status='CONCILIADA'
        )::integer,

        count(*) FILTER(
            WHERE operational_reconciliation_status='PENDIENTE_CONCILIAR'
        )::integer,

        count(*) FILTER(
            WHERE operational_reconciliation_status='NO_APLICA_AUN'
        )::integer

      INTO
        v_total,
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
        v_total>0
        AND v_physical_captured=v_total;

    v_reconciliation_complete :=
        v_total>0
        AND v_physical_complete
        AND v_pending_reconciliation=0
        AND v_not_applicable_yet=0
        AND (v_nrq+v_reconciled)=v_total;

    v_physical_status :=
        CASE
            WHEN v_total=0
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
            WHEN v_total=0
                THEN 'WAITING_CARDS'
            WHEN NOT v_physical_complete
                THEN 'WAITING_PHYSICAL'
            WHEN v_reconciliation_complete
                THEN 'COMPLETE'
            WHEN v_pending_reconciliation>0
                THEN 'PENDING'
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
            'totalCards',v_total,
            'notReceived',v_not_received,
            'received',v_received,
            'inCapture',v_in_capture,
            'captured',v_physical_captured
        ),

        'reconciliation',jsonb_build_object(
            'status',v_reconciliation_status,
            'complete',v_reconciliation_complete,
            'digitalUsed',v_digital_used,
            'nrq',v_nrq,
            'reconciled',v_reconciled,
            'pendingReconciliation',v_pending_reconciliation,
            'notApplicableYet',v_not_applicable_yet
        )
    );
END;
$function$;

COMMENT ON FUNCTION
public.obtener_estado_captura_conciliacion_ronda_264(uuid)
IS
'M264: estado agregado separado de Captura Física y Conciliación por ronda, sin modificar lógica competitiva.';

REVOKE ALL
ON FUNCTION public.obtener_estado_captura_conciliacion_ronda_264(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.obtener_estado_captura_conciliacion_ronda_264(uuid)
TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- B. Asistente v17
-- Reemplaza ROUND_SCORING por dos pasos explícitos.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._obtener_asistente_operativo_torneo_v17_264(
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
    v_state jsonb;

    v_round_id uuid;
    v_round_number integer;

    v_physical jsonb;
    v_reconciliation jsonb;

    v_original_actionable boolean;
    v_original_waiting_for text;

    v_physical_complete boolean;
    v_reconciliation_complete boolean;

    v_physical_step jsonb;
    v_reconciliation_step jsonb;

    v_blockers jsonb := '[]'::jsonb;
    v_next_action jsonb := NULL;
    v_total integer := 0;
    v_completed integer := 0;
BEGIN
    v_result :=
        public._obtener_asistente_operativo_torneo_v16_263(
            p_tournament_id
        );

    v_source_steps :=
        COALESCE(v_result->'steps','[]'::jsonb);

    FOR v_elem IN
        SELECT elem
        FROM jsonb_array_elements(v_source_steps) x(elem)
    LOOP
        IF v_elem->>'code'<>'ROUND_SCORING' THEN
            v_final_steps :=
                v_final_steps || jsonb_build_array(v_elem);
            CONTINUE;
        END IF;

        v_round_id :=
            NULLIF(v_elem->>'roundId','')::uuid;

        v_round_number :=
            NULLIF(v_elem->>'roundNumber','')::integer;

        v_state :=
            public.obtener_estado_captura_conciliacion_ronda_264(
                v_round_id
            );

        v_physical := v_state->'physicalCapture';
        v_reconciliation := v_state->'reconciliation';

        v_physical_complete :=
            COALESCE(
                (v_physical->>'complete')::boolean,
                false
            );

        v_reconciliation_complete :=
            COALESCE(
                (v_reconciliation->>'complete')::boolean,
                false
            );

        -- Hereda el gate real que ya traía ROUND_SCORING.
        -- Es especialmente importante para START_TOURNAMENT y para
        -- cualquier dependencia previa ya establecida por versiones anteriores.
        v_original_actionable :=
            COALESCE(
                (v_elem #>> '{availability,actionable}')::boolean,
                true
            );

        v_original_waiting_for :=
            NULLIF(
                v_elem #>> '{availability,waitingFor}',
                ''
            );

        -- ---------------------------------------------------------------
        -- CAPTURA FÍSICA
        -- ---------------------------------------------------------------
        v_physical_step :=
            jsonb_build_object(
                'code','ROUND_PHYSICAL_CAPTURE',
                'scope','ROUND',
                'roundId',v_round_id,
                'roundNumber',v_round_number,
                'title',
                    format(
                        'Ronda %s · Captura física',
                        v_round_number
                    ),
                'status',
                    CASE
                        WHEN v_physical_complete
                            THEN 'COMPLETE'
                        WHEN NOT v_original_actionable
                            THEN 'PENDING'
                        ELSE 'PENDING'
                    END,
                'message',
                    CASE
                        WHEN v_physical_complete THEN
                            format(
                                'La captura física de la ronda %s está completa: %s de %s tarjeta(s).',
                                v_round_number,
                                COALESCE((v_physical->>'captured')::integer,0),
                                COALESCE((v_physical->>'totalCards')::integer,0)
                            )
                        WHEN COALESCE((v_physical->>'totalCards')::integer,0)=0 THEN
                            format(
                                'La captura física de la ronda %s todavía no puede comenzar porque no hay tarjetas oficiales activas.',
                                v_round_number
                            )
                        ELSE
                            format(
                                'La ronda %s tiene %s de %s tarjeta(s) físicas completadas.',
                                v_round_number,
                                COALESCE((v_physical->>'captured')::integer,0),
                                COALESCE((v_physical->>'totalCards')::integer,0)
                            )
                    END,
                'recommendation',
                    CASE
                        WHEN v_physical_complete THEN NULL
                        WHEN NOT v_original_actionable THEN
                            'Completa primero el requisito operativo anterior.'
                        ELSE
                            'Recibe y captura las tarjetas físicas de la ronda.'
                    END,
                'details',v_physical,
                'action',
                    CASE
                        WHEN v_physical_complete
                          OR NOT v_original_actionable
                            THEN NULL
                        ELSE jsonb_build_object(
                            'label','Ir a captura física',
                            'target','tarjetas-fisicas',
                            'roundId',v_round_id
                        )
                    END,
                'requiredRole','TOURNAMENT_OPERATOR',
                'availability',
                    CASE
                        WHEN v_physical_complete THEN
                            jsonb_build_object(
                                'actionable',false,
                                'state','COMPLETE',
                                'waitingFor',NULL
                            )
                        WHEN NOT v_original_actionable THEN
                            jsonb_build_object(
                                'actionable',false,
                                'state','WAITING',
                                'waitingFor',
                                    COALESCE(
                                        v_original_waiting_for,
                                        'PREVIOUS_REQUIREMENT'
                                    )
                            )
                        ELSE
                            jsonb_build_object(
                                'actionable',true,
                                'state','AVAILABLE',
                                'waitingFor',NULL
                            )
                    END
            );

        -- ---------------------------------------------------------------
        -- CONCILIACIÓN
        -- ---------------------------------------------------------------
        v_reconciliation_step :=
            jsonb_build_object(
                'code','ROUND_RECONCILIATION',
                'scope','ROUND',
                'roundId',v_round_id,
                'roundNumber',v_round_number,
                'title',
                    format(
                        'Ronda %s · Conciliación',
                        v_round_number
                    ),
                'status',
                    CASE
                        WHEN v_reconciliation_complete
                            THEN 'COMPLETE'
                        ELSE 'PENDING'
                    END,
                'message',
                    CASE
                        WHEN v_reconciliation_complete
                             AND COALESCE(
                                 (v_reconciliation->>'digitalUsed')::integer,
                                 0
                             )=0 THEN
                            format(
                                'La ronda %s no requirió conciliación DIGITAL vs FÍSICO: todas las tarjetas quedaron NRQ.',
                                v_round_number
                            )

                        WHEN v_reconciliation_complete THEN
                            format(
                                'La conciliación de la ronda %s está completa: %s conciliada(s) y %s NRQ.',
                                v_round_number,
                                COALESCE(
                                    (v_reconciliation->>'reconciled')::integer,
                                    0
                                ),
                                COALESCE(
                                    (v_reconciliation->>'nrq')::integer,
                                    0
                                )
                            )

                        WHEN NOT v_physical_complete THEN
                            format(
                                'La conciliación de la ronda %s espera a que termine la captura física.',
                                v_round_number
                            )

                        ELSE
                            format(
                                'La ronda %s tiene %s tarjeta(s) pendientes de conciliación.',
                                v_round_number,
                                COALESCE(
                                    (v_reconciliation->>'pendingReconciliation')::integer,
                                    0
                                )
                            )
                    END,
                'recommendation',
                    CASE
                        WHEN v_reconciliation_complete THEN NULL
                        WHEN NOT v_physical_complete THEN
                            'Completa primero la captura física.'
                        ELSE
                            'Revisa las tarjetas que sí requieren conciliación DIGITAL vs FÍSICO.'
                    END,
                'details',v_reconciliation,
                'action',
                    CASE
                        WHEN v_reconciliation_complete
                          OR NOT v_physical_complete
                            THEN NULL
                        ELSE jsonb_build_object(
                            'label','Ir a conciliación',
                            'target','conciliacion',
                            'roundId',v_round_id
                        )
                    END,
                'requiredRole','TOURNAMENT_OPERATOR',
                'availability',
                    CASE
                        WHEN v_reconciliation_complete THEN
                            jsonb_build_object(
                                'actionable',false,
                                'state','COMPLETE',
                                'waitingFor',NULL
                            )
                        WHEN NOT v_physical_complete THEN
                            jsonb_build_object(
                                'actionable',false,
                                'state','WAITING',
                                'waitingFor','ROUND_PHYSICAL_CAPTURE'
                            )
                        ELSE
                            jsonb_build_object(
                                'actionable',true,
                                'state','AVAILABLE',
                                'waitingFor',NULL
                            )
                    END
            );

        v_final_steps :=
            v_final_steps
            || jsonb_build_array(v_physical_step)
            || jsonb_build_array(v_reconciliation_step);
    END LOOP;

    -- -------------------------------------------------------------------
    -- Recalcular blockers, nextAction y progreso por orden real.
    -- -------------------------------------------------------------------

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
      INTO v_total,v_completed
      FROM jsonb_array_elements(v_final_steps) x(elem);

    v_result :=
        jsonb_set(
            v_result,
            '{steps}',
            v_final_steps,
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{blockers}',
            v_blockers,
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{summary,blockingIssues}',
            to_jsonb(jsonb_array_length(v_blockers)),
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{progress,completed}',
            to_jsonb(v_completed),
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{progress,total}',
            to_jsonb(v_total),
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{progress,percent}',
            to_jsonb(
                CASE
                    WHEN v_total=0 THEN 0
                    ELSE round(
                        100.0*v_completed/v_total,
                        0
                    )
                END
            ),
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{nextAction}',
            COALESCE(v_next_action,'null'::jsonb),
            true
        );

    RETURN
        v_result
        || jsonb_build_object(
            'schemaVersion',17
        );
END;
$function$;

COMMENT ON FUNCTION
public._obtener_asistente_operativo_torneo_v17_264(uuid)
IS
'M264: separa ROUND_SCORING en Captura Física y Conciliación, preservando gates previos y lógica competitiva.';

REVOKE ALL
ON FUNCTION public._obtener_asistente_operativo_torneo_v17_264(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._obtener_asistente_operativo_torneo_v17_264(uuid)
TO postgres, service_role;

CREATE OR REPLACE FUNCTION public.obtener_asistente_operativo_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RETURN
        public._obtener_asistente_operativo_torneo_v17_264(
            p_tournament_id
        );
END;
$function$;

COMMENT ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
IS
'M264: Asistente schemaVersion 17; Captura Física y Conciliación son etapas operativas separadas.';

COMMIT;
