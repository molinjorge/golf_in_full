-- TEE CENTRAL
-- MIGRACION 392 - ESTADO DE CATEGORIA RESPETA CIERRE FORMAL DE CAPTURA
-- EJECUCION: MANUAL EN SUPABASE PROD
-- IMPORTANTE: este archivo NO fue ejecutado por ChatGPT.

BEGIN;

-- Conservamos el motor competitivo actual sin duplicarlo. La funcion publica
-- pasa a enriquecer su salida con el cierre formal de captura 389 y evita
-- declarar READY_TO_CLOSE mientras la captura siga abierta.
--
-- La funcion base se crea como copia del estado competitivo actual mediante
-- una funcion SQL que invoca la implementacion vigente antes de sustituirla.
-- Para evitar recursion y preservar exactamente la logica deportiva existente,
-- primero renombramos la implementacion actual.

DO $do$
BEGIN
    IF to_regprocedure('public._obtener_estado_competitivo_categorias_ronda_pre392(uuid)') IS NOT NULL THEN
        RAISE EXCEPTION 'Ya existe _obtener_estado_competitivo_categorias_ronda_pre392(uuid). Revise si la migracion 392 ya fue aplicada.';
    END IF;

    IF to_regprocedure('public.obtener_estado_competitivo_categorias_ronda(uuid)') IS NULL THEN
        RAISE EXCEPTION 'No existe obtener_estado_competitivo_categorias_ronda(uuid).';
    END IF;
END
$do$;

ALTER FUNCTION public.obtener_estado_competitivo_categorias_ronda(uuid)
RENAME TO _obtener_estado_competitivo_categorias_ronda_pre392;

-- La funcion anterior queda como implementacion interna. No debe quedar
-- invocable directamente desde la API porque permitiria saltarse el gate 392.
REVOKE ALL ON FUNCTION public._obtener_estado_competitivo_categorias_ronda_pre392(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._obtener_estado_competitivo_categorias_ronda_pre392(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public._obtener_estado_competitivo_categorias_ronda_pre392(uuid) FROM service_role;

CREATE OR REPLACE FUNCTION public.obtener_estado_competitivo_categorias_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base jsonb;
    v_capture jsonb;
    v_capture_closed boolean := false;
    v_capture_status text := 'OPEN';
    v_categories jsonb := '[]'::jsonb;
    v_category jsonb;
    v_new_category jsonb;
    v_original_status text;
    v_total integer := 0;
    v_provisional integer := 0;
    v_tiebreak_pending integer := 0;
    v_ready integer := 0;
BEGIN
    -- La implementacion pre-392 sigue siendo la unica fuente para resultados,
    -- participantes y desempates. Esta migracion solo agrega el gate CAPTURA.
    v_base := public._obtener_estado_competitivo_categorias_ronda_pre392(
        p_tournament_round_id
    );

    IF COALESCE((v_base->>'supported')::boolean, false) = false THEN
        RETURN jsonb_set(v_base, '{schemaVersion}', '392'::jsonb, true);
    END IF;

    v_capture := public.obtener_estado_cierre_captura_ronda_389(
        p_tournament_round_id
    );

    v_capture_closed := COALESCE(
        (v_capture->>'captureClosed')::boolean,
        false
    );

    v_capture_status := COALESCE(
        NULLIF(v_capture->>'captureStatus', ''),
        'OPEN'
    );

    FOR v_category IN
        SELECT value
        FROM jsonb_array_elements(COALESCE(v_base->'categories', '[]'::jsonb))
    LOOP
        v_original_status := COALESCE(v_category->>'status', 'PROVISIONAL');

        v_new_category := v_category
            || jsonb_build_object(
                'captureClosed', v_capture_closed,
                'captureStatus', v_capture_status,
                'statusBeforeCaptureGate', v_original_status
            );

        IF NOT v_capture_closed THEN
            -- CAPTURA ABIERTA tiene prioridad operativa. No altera el calculo
            -- deportivo interno; solo impide anunciar la categoria como lista
            -- para cierre formal.
            v_new_category := v_new_category
                || jsonb_build_object(
                    'status', 'PROVISIONAL',
                    'readyToClose', false,
                    'blockingReason', 'CAPTURE_OPEN'
                );
        ELSE
            v_new_category := v_new_category
                || jsonb_build_object(
                    'blockingReason',
                    CASE
                        WHEN v_original_status = 'READY_TO_CLOSE' THEN NULL
                        WHEN v_original_status = 'TIEBREAKS_PENDING' THEN 'TIEBREAKS_PENDING'
                        ELSE 'RESULTS_PENDING'
                    END
                );
        END IF;

        v_categories := v_categories || jsonb_build_array(v_new_category);
        v_total := v_total + 1;

        CASE v_new_category->>'status'
            WHEN 'READY_TO_CLOSE' THEN v_ready := v_ready + 1;
            WHEN 'TIEBREAKS_PENDING' THEN v_tiebreak_pending := v_tiebreak_pending + 1;
            ELSE v_provisional := v_provisional + 1;
        END CASE;
    END LOOP;

    RETURN v_base
        || jsonb_build_object(
            'schemaVersion', 392,
            'capture', jsonb_build_object(
                'captureClosed', v_capture_closed,
                'captureStatus', v_capture_status,
                'canCloseCapture', COALESCE((v_capture->>'canCloseCapture')::boolean, false),
                'summary', COALESCE(v_capture->'summary', '{}'::jsonb)
            ),
            'summary', jsonb_build_object(
                'totalCategories', v_total,
                'provisionalCategories', v_provisional,
                'tiebreakPendingCategories', v_tiebreak_pending,
                'readyToCloseCategories', v_ready,
                'captureClosed', v_capture_closed
            ),
            'categories', v_categories
        );
END;
$function$;

-- Mantener el mismo contrato de ejecucion que la RPC sustituida.
REVOKE ALL ON FUNCTION public.obtener_estado_competitivo_categorias_ronda(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_estado_competitivo_categorias_ronda(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_estado_competitivo_categorias_ronda(uuid) TO service_role;

COMMENT ON FUNCTION public.obtener_estado_competitivo_categorias_ronda(uuid) IS
'M392: estado competitivo por categoria enriquecido con cierre formal de captura 389. CAPTURA ABIERTA fuerza readyToClose=false y blockingReason=CAPTURE_OPEN sin alterar resultados ni desempates.';

COMMIT;
