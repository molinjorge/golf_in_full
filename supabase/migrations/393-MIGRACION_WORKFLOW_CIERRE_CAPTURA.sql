-- TEE CENTRAL
-- MIGRACION 393 - WORKFLOW FORMAL DE CIERRE DE CAPTURA
-- Ejecutar manualmente en Supabase PROD.
-- Objetivo: materializar ROUND_CAPTURE_CLOSE sin impedir la consulta de resultados provisionales.

BEGIN;

-- 1) Preservar la reconstruccion vigente.
DO $$
BEGIN
  IF to_regprocedure('public._reconstruir_workflow_extendido_pre393(uuid)') IS NULL THEN
    ALTER FUNCTION public.reconstruir_workflow_extendido_387(uuid)
      RENAME TO _reconstruir_workflow_extendido_pre393;
  END IF;
END $$;

-- 2) Nueva reconstruccion 393.
CREATE OR REPLACE FUNCTION public.reconstruir_workflow_extendido_387(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_base jsonb;
  v_r record;
  v_capture_action text;
  v_capture_at timestamptz;
  v_reconciliation_status text;
  v_results_status text;
  v_capture_status text;
  v_capture_blocked_by text;
  v_capture_detail text;
  v_category_closed boolean;
  v_category_status text;
  v_category_blocked_by text;
  v_category_detail text;
  v_nodes integer;
BEGIN
  IF p_tournament_id IS NULL THEN
    RAISE EXCEPTION 'tournament_id es obligatorio.' USING ERRCODE='22023';
  END IF;

  -- Conserva integra la reconstruccion vigente hasta 392/387.
  v_base := public._reconstruir_workflow_extendido_pre393(p_tournament_id);

  FOR v_r IN
    SELECT r.id, r.numero_ronda
      FROM public.tournament_rounds r
     WHERE r.tournament_id=p_tournament_id
       AND r.activo=true
     ORDER BY r.numero_ronda,r.id
  LOOP
    SELECT n.status INTO v_reconciliation_status
      FROM public.tournament_workflow_nodes n
     WHERE n.tournament_id=p_tournament_id
       AND n.tournament_round_id=v_r.id
       AND n.scope='ROUND'
       AND n.code='ROUND_RECONCILIATION'
     LIMIT 1;

    SELECT n.status INTO v_results_status
      FROM public.tournament_workflow_nodes n
     WHERE n.tournament_id=p_tournament_id
       AND n.tournament_round_id=v_r.id
       AND n.scope='ROUND'
       AND n.code='ROUND_RESULTS'
     LIMIT 1;

    SELECT e.action,e.occurred_at
      INTO v_capture_action,v_capture_at
      FROM public.tournament_round_capture_events e
     WHERE e.tournament_round_id=v_r.id
     ORDER BY e.occurred_at DESC,e.id DESC
     LIMIT 1;

    IF v_capture_action='CLOSED' THEN
      v_capture_status := 'COMPLETE';
      v_capture_blocked_by := NULL;
      v_capture_detail := 'Captura de la ronda cerrada formalmente.';
    ELSIF v_reconciliation_status='COMPLETE' THEN
      v_capture_status := 'AVAILABLE';
      v_capture_blocked_by := NULL;
      v_capture_detail := 'Captura y conciliacion resueltas. Corresponde cerrar formalmente la captura.';
    ELSE
      v_capture_status := 'BLOCKED';
      v_capture_blocked_by := 'ROUND_RECONCILIATION';
      v_capture_detail := 'Requiere completar captura y conciliacion antes del cierre formal de captura.';
    END IF;

    -- Nodo formal nuevo. No se encadena como previous_code de ROUND_RESULTS:
    -- los resultados provisionales pueden seguir consultandose con captura abierta.
    UPDATE public.tournament_workflow_nodes
       SET sequence_no=255,
           status=v_capture_status,
           previous_code='ROUND_RECONCILIATION',
           next_code='ROUND_CATEGORY_CLOSURE',
           blocked_by_code=v_capture_blocked_by,
           detail=v_capture_detail,
           completed_at=CASE WHEN v_capture_status='COMPLETE' THEN v_capture_at ELSE NULL END,
           reconciled_at=now(),
           evidence=COALESCE(evidence,'{}'::jsonb) || jsonb_build_object(
             'workflow_guard_version',393,
             'capture_action',v_capture_action,
             'capture_closed',(v_capture_action='CLOSED'),
             'capture_closed_at',v_capture_at,
             'results_parallel',true
           ),
           updated_at=now()
     WHERE tournament_id=p_tournament_id
       AND tournament_round_id=v_r.id
       AND scope='ROUND'
       AND code='ROUND_CAPTURE_CLOSE';

    IF NOT FOUND THEN
      INSERT INTO public.tournament_workflow_nodes(
        tournament_id,tournament_round_id,scope,code,sequence_no,status,
        previous_code,next_code,blocked_by_code,evidence,detail,completed_at,
        reconciled_at,created_at,updated_at
      ) VALUES (
        p_tournament_id,v_r.id,'ROUND','ROUND_CAPTURE_CLOSE',255,v_capture_status,
        'ROUND_RECONCILIATION','ROUND_CATEGORY_CLOSURE',v_capture_blocked_by,
        jsonb_build_object(
          'workflow_guard_version',393,
          'capture_action',v_capture_action,
          'capture_closed',(v_capture_action='CLOSED'),
          'capture_closed_at',v_capture_at,
          'results_parallel',true
        ),
        v_capture_detail,
        CASE WHEN v_capture_status='COMPLETE' THEN v_capture_at ELSE NULL END,
        now(),now(),now()
      );
    END IF;

    -- Mantener ROUND_RESULTS independiente para permitir resultados provisionales.
    UPDATE public.tournament_workflow_nodes
       SET next_code='ROUND_CATEGORY_CLOSURE',
           evidence=COALESCE(evidence,'{}'::jsonb) || jsonb_build_object(
             'workflow_guard_version',393,
             'capture_close_required_for_category_close',true
           ),
           updated_at=now()
     WHERE tournament_id=p_tournament_id
       AND tournament_round_id=v_r.id
       AND scope='ROUND'
       AND code='ROUND_RESULTS';

    SELECT EXISTS(
      SELECT 1
        FROM public.tournament_round_category_competitive_closures c
       WHERE c.tournament_round_id=v_r.id
         AND c.competitive_status='FINAL'
    ) INTO v_category_closed;

    IF v_category_closed THEN
      v_category_status := 'COMPLETE';
      v_category_blocked_by := NULL;
      v_category_detail := 'Cierre competitivo de categorias registrado.';
    ELSIF v_capture_status <> 'COMPLETE' THEN
      v_category_status := 'BLOCKED';
      v_category_blocked_by := 'ROUND_CAPTURE_CLOSE';
      v_category_detail := 'Requiere cerrar formalmente la captura antes del cierre de categorias.';
    ELSIF v_results_status='COMPLETE' THEN
      v_category_status := 'AVAILABLE';
      v_category_blocked_by := NULL;
      v_category_detail := 'Captura cerrada y resultados disponibles. Cierre sujeto a validaciones deportivas de cada categoria.';
    ELSE
      v_category_status := 'BLOCKED';
      v_category_blocked_by := 'ROUND_RESULTS';
      v_category_detail := 'Requiere completar resultados antes del cierre de categorias.';
    END IF;

    UPDATE public.tournament_workflow_nodes
       SET status=v_category_status,
           previous_code='ROUND_RESULTS',
           blocked_by_code=v_category_blocked_by,
           detail=v_category_detail,
           evidence=COALESCE(evidence,'{}'::jsonb) || jsonb_build_object(
             'workflow_guard_version',393,
             'capture_close_status',v_capture_status,
             'capture_close_required',true,
             'results_status',v_results_status
           ),
           reconciled_at=now(),
           updated_at=now()
     WHERE tournament_id=p_tournament_id
       AND tournament_round_id=v_r.id
       AND scope='ROUND'
       AND code='ROUND_CATEGORY_CLOSURE';
  END LOOP;

  SELECT count(*)::integer INTO v_nodes
    FROM public.tournament_workflow_nodes
   WHERE tournament_id=p_tournament_id;

  RETURN jsonb_build_object(
    'ok',true,
    'tournament_id',p_tournament_id,
    'node_count',v_nodes,
    'base',v_base,
    'extended_version',393,
    'capture_close_node','ROUND_CAPTURE_CLOSE',
    'results_parallel',true,
    'category_close_requires_capture_close',true,
    'reconciled_at',now()
  );
END;
$function$;

-- Mantener permisos del punto de entrada de reconstruccion.
REVOKE ALL ON FUNCTION public.reconstruir_workflow_extendido_387(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reconstruir_workflow_extendido_387(uuid) TO authenticated, service_role;

COMMIT;
