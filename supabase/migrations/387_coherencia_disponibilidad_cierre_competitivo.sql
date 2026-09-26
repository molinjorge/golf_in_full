-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 387
-- COHERENCIA DE DISPONIBILIDAD DEL CIERRE COMPETITIVO
-- ============================================================================
-- EJECUCIÓN: MANUAL por el usuario en Supabase SQL Editor.
--
-- OBJETIVO:
--   Impedir que ROUND_COMPETITIVE_CLOSE quede AVAILABLE antes de que la etapa
--   inmediatamente anterior del workflow de la ronda esté COMPLETE.
--
-- DIAGNÓSTICO:
--   La reconstrucción base 332 marca ROUND_COMPETITIVE_CLOSE AVAILABLE desde
--   que la ronda tiene started_at. Las extensiones posteriores cambian su
--   previous_code a ROUND_RESULTS_PUBLICATION (o ROUND_RESULTS cuando no hay
--   formalización por categoría), pero no recalculan status/blocked_by_code.
--
-- REGLA 387:
--   - cierre FINAL persistido                         -> COMPLETE
--   - etapa anterior COMPLETE y sin cierre FINAL    -> AVAILABLE
--   - etapa anterior todavía no COMPLETE            -> BLOCKED por previous_code
--
-- NO ejecuta el cierre competitivo ni modifica resultados deportivos.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.reconstruir_workflow_extendido_387(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base jsonb;
    v_nodes integer;
BEGIN
    IF p_tournament_id IS NULL THEN
        RAISE EXCEPTION 'tournament_id es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    -- Conserva toda la reconstrucción vigente hasta 385.
    v_base := public.reconstruir_workflow_extendido_385(p_tournament_id);

    -- Corrige exclusivamente el nodo de cierre competitivo.
    -- previous_code ya fue materializado por 337/341 según aplique:
    -- ROUND_RESULTS_PUBLICATION o ROUND_RESULTS.
    UPDATE public.tournament_workflow_nodes c
       SET status = CASE
               WHEN EXISTS (
                   SELECT 1
                     FROM public.tournament_round_competitive_closures rc
                    WHERE rc.tournament_round_id=c.tournament_round_id
                      AND rc.competitive_status='FINAL'
               ) THEN 'COMPLETE'
               WHEN prev.status='COMPLETE' THEN 'AVAILABLE'
               ELSE 'BLOCKED'
           END,
           blocked_by_code = CASE
               WHEN EXISTS (
                   SELECT 1
                     FROM public.tournament_round_competitive_closures rc
                    WHERE rc.tournament_round_id=c.tournament_round_id
                      AND rc.competitive_status='FINAL'
               ) THEN NULL
               WHEN prev.status='COMPLETE' THEN NULL
               ELSE c.previous_code
           END,
           detail = CASE
               WHEN EXISTS (
                   SELECT 1
                     FROM public.tournament_round_competitive_closures rc
                    WHERE rc.tournament_round_id=c.tournament_round_id
                      AND rc.competitive_status='FINAL'
               ) THEN 'Cierre competitivo registrado.'
               WHEN prev.status='COMPLETE'
                   THEN 'Cierre sujeto a validaciones deportivas existentes.'
               ELSE 'Requiere completar la etapa anterior antes del cierre competitivo.'
           END,
           completed_at = CASE
               WHEN EXISTS (
                   SELECT 1
                     FROM public.tournament_round_competitive_closures rc
                    WHERE rc.tournament_round_id=c.tournament_round_id
                      AND rc.competitive_status='FINAL'
               )
               THEN (
                   SELECT max(rc.closed_at)
                     FROM public.tournament_round_competitive_closures rc
                    WHERE rc.tournament_round_id=c.tournament_round_id
                      AND rc.competitive_status='FINAL'
               )
               ELSE NULL
           END,
           evidence = COALESCE(c.evidence,'{}'::jsonb) || jsonb_build_object(
               'workflow_guard_version',387,
               'previous_code',c.previous_code,
               'previous_status',prev.status,
               'closed_at',(
                   SELECT max(rc.closed_at)
                     FROM public.tournament_round_competitive_closures rc
                    WHERE rc.tournament_round_id=c.tournament_round_id
                      AND rc.competitive_status='FINAL'
               )
           ),
           updated_at=now()
      FROM public.tournament_workflow_nodes prev
     WHERE c.tournament_id=p_tournament_id
       AND c.scope='ROUND'
       AND c.code='ROUND_COMPETITIVE_CLOSE'
       AND c.previous_code IS NOT NULL
       AND prev.tournament_id=c.tournament_id
       AND prev.tournament_round_id=c.tournament_round_id
       AND prev.scope='ROUND'
       AND prev.code=c.previous_code;

    SELECT count(*)::integer
      INTO v_nodes
      FROM public.tournament_workflow_nodes
     WHERE tournament_id=p_tournament_id;

    RETURN jsonb_build_object(
        'ok',true,
        'tournament_id',p_tournament_id,
        'node_count',v_nodes,
        'base',v_base,
        'extended_version',387,
        'competitive_close_guard','PREVIOUS_STAGE_COMPLETE',
        'reconciled_at',now()
    );
END;
$function$;

-- Mantiene el punto público de reconciliación apuntando a la versión vigente.
CREATE OR REPLACE FUNCTION public.reconciliar_workflow_torneo_332(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RETURN public.reconstruir_workflow_extendido_387(p_tournament_id);
END;
$function$;

-- Re-materializa torneos con rondas activas para corregir inmediatamente
-- los nodos derivados. No ejecuta cierres ni altera datos deportivos.
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT DISTINCT tr.tournament_id
          FROM public.tournament_rounds tr
         WHERE tr.activo=true
    LOOP
        PERFORM public.reconstruir_workflow_extendido_387(r.tournament_id);
    END LOOP;
END;
$$;

COMMIT;
