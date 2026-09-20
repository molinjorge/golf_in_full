-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 340
-- Warning no bloqueante del Asistente por pagos pendientes
-- ============================================================================
-- Requiere: 339 aplicada.
-- No modifica workflow, motores deportivos, inscripciones ni pagos.
-- El warning es informativo y desaparece automáticamente cuando no quedan
-- inscripciones activas con estado_pago='PENDIENTE'.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._adaptar_asistente_pagos_pendientes_340(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_result jsonb;
    v_pending integer := 0;
    v_warning jsonb;
    v_warnings jsonb;
BEGIN
    -- Conserva íntegramente el contrato y comportamiento del Asistente 338.
    -- 338 mantiene sus controles de autenticación/autorización y reconciliación.
    v_result := public._adaptar_asistente_workflow_338(p_tournament_id);

    SELECT count(*)::integer
      INTO v_pending
      FROM public.tournament_registrations tr
     WHERE tr.tournament_id = p_tournament_id
       AND tr.activo = true
       AND tr.estado_pago = 'PENDIENTE';

    v_warnings := COALESCE(v_result->'warnings', '[]'::jsonb);

    IF v_pending > 0 THEN
        v_warning := jsonb_build_object(
            'code', 'PENDING_PAYMENTS',
            'severity', 'WARNING',
            'blocking', false,
            'title', 'Pagos pendientes',
            'message', CASE
                WHEN v_pending = 1
                    THEN 'Hay 1 jugador inscrito con pago pendiente.'
                ELSE format('Hay %s jugadores inscritos con pago pendiente.', v_pending)
            END,
            'recommendation', 'Registra el pago durante el check-in cuando corresponda.',
            'count', v_pending,
            'target', 'inscripciones'
        );

        v_warnings := v_warnings || jsonb_build_array(v_warning);
    END IF;

    -- Sólo se actualizan los campos informativos de warnings.
    -- blockers, nextAction, steps, workflow y estados deportivos quedan intactos.
    v_result := jsonb_set(v_result, '{warnings}', v_warnings, true);
    v_result := jsonb_set(
        v_result,
        '{summary,warnings}',
        to_jsonb(jsonb_array_length(v_warnings)),
        true
    );

    -- Identifica el contrato extendido sin alterar la fuente materializada.
    v_result := jsonb_set(v_result, '{schemaVersion}', '340'::jsonb, true);

    RETURN v_result;
END;
$function$;

COMMENT ON FUNCTION public._adaptar_asistente_pagos_pendientes_340(uuid) IS
'Extiende el Asistente 338 con warning informativo, no bloqueante, mientras existan inscripciones activas con estado_pago=PENDIENTE.';

REVOKE ALL ON FUNCTION public._adaptar_asistente_pagos_pendientes_340(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.obtener_asistente_operativo_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
    SELECT public._adaptar_asistente_pagos_pendientes_340(p_tournament_id);
$function$;

COMMIT;
