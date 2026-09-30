-- TEE CENTRAL
-- MIGRACIÓN 410 — ETIQUETA CERRAR CAPTURA EN ASISTENTE
-- Objetivo: corregir únicamente la etiqueta de acción del nodo maestro
-- ROUND_CAPTURE_CLOSE para que el Asistente indique la acción real:
-- "Cerrar captura" en lugar de "Revisar cierre de captura".
--
-- NO modifica evaluador, RPC 396, navegación, guards, motores,
-- reglas deportivas, cierre de captura ni ninguna autorización.

BEGIN;

DO $$
DECLARE
    v_template_id uuid;
    v_rows integer;
BEGIN
    SELECT id
      INTO v_template_id
      FROM public.workflow_master_templates
     WHERE template_code = 'TEE_CENTRAL_STANDARD'
       AND version = 1
       AND active = true;

    IF v_template_id IS NULL THEN
        RAISE EXCEPTION
            'Migración 410: no existe la plantilla activa TEE_CENTRAL_STANDARD versión 1.';
    END IF;

    UPDATE public.workflow_master_nodes
       SET action_label = 'Cerrar captura',
           updated_at = now()
     WHERE template_id = v_template_id
       AND code = 'ROUND_CAPTURE_CLOSE'
       AND sequence_no = 180
       AND action_label = 'Revisar cierre de captura';

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows <> 1 THEN
        RAISE EXCEPTION
            'Migración 410: se esperaba actualizar exactamente 1 nodo ROUND_CAPTURE_CLOSE y se actualizaron %.',
            v_rows;
    END IF;
END;
$$;

COMMIT;
