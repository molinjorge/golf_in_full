-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 385
-- Coherencia temporal del workflow de ronda antes de ROUND_PLAY
--
-- IMPORTANTE:
--   - No modifica motores deportivos.
--   - No modifica captura física, conciliación, resultados ni cierres.
--   - Corrige exclusivamente la PROYECCIÓN/MATERIALIZACIÓN del workflow.
--   - Si una ronda no ha iniciado (started_at IS NULL), ninguna fase posterior
--     puede aparecer AVAILABLE / IN_PROGRESS / COMPLETE.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Wrapper 385 sobre el workflow vigente 341.
--
-- 341 conserva toda la construcción existente (incluido 337). Después de esa
-- reconstrucción, 385 aplica una invariancia temporal:
--
--   ROUND_PLAY no iniciado
--       -> ROUND_PHYSICAL_CAPTURE BLOCKED por ROUND_PLAY
--       -> ROUND_RECONCILIATION BLOCKED por ROUND_PHYSICAL_CAPTURE
--       -> ROUND_RESULTS BLOCKED por ROUND_RECONCILIATION
--       -> ROUND_CATEGORY_CLOSURE BLOCKED por ROUND_RESULTS
--       -> ROUND_RESULTS_PUBLICATION BLOCKED por ROUND_CATEGORY_CLOSURE
--       -> ROUND_COMPETITIVE_CLOSE BLOCKED por su predecesor real
--
-- No se altera ROUND_PLAY ni se inventa el estado de inicio: la autoridad es
-- tournament_round_lifecycle.started_at, igual que en el workflow existente.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reconstruir_workflow_extendido_385(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base jsonb;
    r record;
    v_close_blocker text;
    v_corrected_rounds integer := 0;
BEGIN
    -- Conserva íntegramente la reconstrucción vigente.
    v_base := public.reconstruir_workflow_extendido_341(p_tournament_id);

    FOR r IN
        SELECT tr.id AS round_id,
               tr.numero_ronda,
               EXISTS (
                   SELECT 1
                     FROM public.tournament_round_lifecycle l
                    WHERE l.tournament_round_id = tr.id
                      AND l.started_at IS NOT NULL
               ) AS round_started
          FROM public.tournament_rounds tr
         WHERE tr.tournament_id = p_tournament_id
           AND tr.activo = true
         ORDER BY tr.numero_ronda, tr.id
    LOOP
        IF NOT r.round_started THEN
            v_corrected_rounds := v_corrected_rounds + 1;

            UPDATE public.tournament_workflow_nodes
               SET status = 'BLOCKED',
                   blocked_by_code = 'ROUND_PLAY',
                   detail = 'Requiere iniciar la ronda.',
                   completed_at = NULL,
                   updated_at = now()
             WHERE tournament_id = p_tournament_id
               AND tournament_round_id = r.round_id
               AND scope = 'ROUND'
               AND code = 'ROUND_PHYSICAL_CAPTURE';

            UPDATE public.tournament_workflow_nodes
               SET status = 'BLOCKED',
                   blocked_by_code = 'ROUND_PHYSICAL_CAPTURE',
                   detail = 'Requiere iniciar la ronda y completar la captura física.',
                   completed_at = NULL,
                   updated_at = now()
             WHERE tournament_id = p_tournament_id
               AND tournament_round_id = r.round_id
               AND scope = 'ROUND'
               AND code = 'ROUND_RECONCILIATION';

            UPDATE public.tournament_workflow_nodes
               SET status = 'BLOCKED',
                   blocked_by_code = 'ROUND_RECONCILIATION',
                   detail = 'Resultados diferidos hasta iniciar la ronda y completar conciliación.',
                   completed_at = NULL,
                   updated_at = now()
             WHERE tournament_id = p_tournament_id
               AND tournament_round_id = r.round_id
               AND scope = 'ROUND'
               AND code = 'ROUND_RESULTS';

            UPDATE public.tournament_workflow_nodes
               SET status = 'BLOCKED',
                   blocked_by_code = 'ROUND_RESULTS',
                   detail = 'Requiere iniciar la ronda y completar resultados.',
                   completed_at = NULL,
                   updated_at = now()
             WHERE tournament_id = p_tournament_id
               AND tournament_round_id = r.round_id
               AND scope = 'ROUND'
               AND code = 'ROUND_CATEGORY_CLOSURE';

            UPDATE public.tournament_workflow_nodes
               SET status = 'BLOCKED',
                   blocked_by_code = 'ROUND_CATEGORY_CLOSURE',
                   detail = 'Requiere iniciar la ronda y completar el cierre de categorías.',
                   completed_at = NULL,
                   updated_at = now()
             WHERE tournament_id = p_tournament_id
               AND tournament_round_id = r.round_id
               AND scope = 'ROUND'
               AND code = 'ROUND_RESULTS_PUBLICATION';

            -- Respeta la cadena materializada real:
            -- con categorías normalmente previous_code=ROUND_RESULTS_PUBLICATION;
            -- sin categorías previous_code=ROUND_RESULTS.
            SELECT COALESCE(previous_code, 'ROUND_RESULTS')
              INTO v_close_blocker
              FROM public.tournament_workflow_nodes
             WHERE tournament_id = p_tournament_id
               AND tournament_round_id = r.round_id
               AND scope = 'ROUND'
               AND code = 'ROUND_COMPETITIVE_CLOSE'
             LIMIT 1;

            UPDATE public.tournament_workflow_nodes
               SET status = 'BLOCKED',
                   blocked_by_code = COALESCE(v_close_blocker, 'ROUND_RESULTS'),
                   detail = 'Requiere ronda iniciada y completar las fases previas de resultados y cierre.',
                   completed_at = NULL,
                   updated_at = now()
             WHERE tournament_id = p_tournament_id
               AND tournament_round_id = r.round_id
               AND scope = 'ROUND'
               AND code = 'ROUND_COMPETITIVE_CLOSE';
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'ok', true,
        'tournament_id', p_tournament_id,
        'extended_version', 385,
        'temporal_guard', 'ROUND_PLAY_STARTED_BEFORE_POST_PLAY_STAGES',
        'corrected_unstarted_rounds', v_corrected_rounds,
        'base', COALESCE(v_base, '{}'::jsonb),
        'reconciled_at', now()
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.reconstruir_workflow_extendido_385(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reconstruir_workflow_extendido_385(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.reconstruir_workflow_extendido_385(uuid) TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. Mantener la RPC pública de reconciliación con el mismo nombre/firma.
--    Solo cambia su implementación interna para utilizar 385.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reconciliar_workflow_torneo_332(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(),p_tournament_id)
        OR public.puede_administrar_congelamiento_torneo(p_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No tienes permiso para reconciliar el workflow de este torneo.'
            USING ERRCODE='42501';
    END IF;

    RETURN public.reconstruir_workflow_extendido_385(p_tournament_id);
END;
$function$;

-- Conserva el modelo de permisos existente de la RPC.
REVOKE ALL ON FUNCTION public.reconciliar_workflow_torneo_332(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reconciliar_workflow_torneo_332(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.reconciliar_workflow_torneo_332(uuid) TO authenticated;

COMMIT;
