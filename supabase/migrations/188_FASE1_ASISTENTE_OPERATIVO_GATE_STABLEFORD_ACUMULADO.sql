-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 188 FASE 1
-- ASISTENTE OPERATIVO — GATE ACUMULADO STABLEFORD
--
-- OBJETIVO
-- Alinear obtener_asistente_operativo_torneo(uuid) con la autoridad formal
-- previsualizar_finalizacion_torneo(uuid).
--
-- STABLEFORD MULTIRRONDA
--   PROVISIONAL           -> revisar acumulado
--   READY_FOR_TIEBREAK    -> resolver desempates acumulados
--   READY_FOR_PUBLICATION -> puede recomendar finalizar
--
-- Stroke Play conserva su comportamiento previo.
-- No modifica scores, puntos, cierres, snapshots ni resultados.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Preservar la implementación 187 Fase 1A-1 como core interno.
--    Es idempotente ante una ejecución parcial/reintento.
-- ---------------------------------------------------------------------------

DO $migration$
BEGIN
    IF to_regprocedure(
        'public._obtener_asistente_operativo_torneo_core_188(uuid)'
    ) IS NULL THEN

        IF to_regprocedure(
            'public.obtener_asistente_operativo_torneo(uuid)'
        ) IS NULL THEN
            RAISE EXCEPTION
                'No existe obtener_asistente_operativo_torneo(uuid).'
                USING ERRCODE = '55000';
        END IF;

        ALTER FUNCTION public.obtener_asistente_operativo_torneo(uuid)
            RENAME TO _obtener_asistente_operativo_torneo_core_188;
    END IF;
END;
$migration$;

REVOKE ALL
ON FUNCTION public._obtener_asistente_operativo_torneo_core_188(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._obtener_asistente_operativo_torneo_core_188(uuid)
TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Contrato público v3.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_asistente_operativo_torneo(
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
    v_preview jsonb := NULL;

    v_steps jsonb;
    v_new_steps jsonb := '[]'::jsonb;
    v_blockers jsonb := '[]'::jsonb;
    v_next_action jsonb := NULL;

    v_original_finalization_step jsonb;
    v_finalization_step jsonb;

    v_can_finalize boolean := false;
    v_all_rounds_formally_closed boolean := false;

    v_tournament_status text;
    v_competition_mode text := NULL;

    v_aggregate_required boolean := false;
    v_aggregate_ready boolean := true;
    v_aggregate_status text := 'NOT_REQUIRED';

    v_ready_to_finalize boolean := false;
    v_blocking_count integer := 0;
BEGIN
    v_result :=
        public._obtener_asistente_operativo_torneo_core_188(
            p_tournament_id
        );

    v_steps :=
        COALESCE(
            v_result->'steps',
            '[]'::jsonb
        );

    v_tournament_status :=
        v_result #>> '{status,tournamentStatus}';

    v_can_finalize :=
        COALESCE(
            (v_result #>> '{actor,isSuperadmin}')::boolean,
            false
        )
        OR
        COALESCE(
            (v_result #>> '{actor,isTournamentOrganizer}')::boolean,
            false
        );

    v_all_rounds_formally_closed :=
        jsonb_array_length(
            COALESCE(
                v_result->'rounds',
                '[]'::jsonb
            )
        ) > 0
        AND
        COALESCE(
            (
                SELECT bool_and(
                    COALESCE(
                        (r->>'formallyClosed')::boolean,
                        false
                    )
                )
                FROM jsonb_array_elements(
                    COALESCE(
                        v_result->'rounds',
                        '[]'::jsonb
                    )
                ) r
            ),
            false
        );

    -- Sólo los mismos roles autorizados para finalizar_torneo()
    -- consultan el preview formal.
    IF v_can_finalize THEN
        BEGIN
            v_preview :=
                public.previsualizar_finalizacion_torneo(
                    p_tournament_id
                );

        EXCEPTION
            WHEN SQLSTATE '55000'
              OR SQLSTATE '0A000'
              OR SQLSTATE '42501'
            THEN
                v_preview := NULL;
        END;
    END IF;

    IF v_preview IS NOT NULL THEN
        v_competition_mode :=
            v_preview #>> '{competition,mode}';

        v_aggregate_required :=
            COALESCE(
                (
                    v_preview
                    #>> '{aggregateCompetition,required}'
                )::boolean,
                false
            );

        v_aggregate_ready :=
            COALESCE(
                (
                    v_preview
                    #>> '{aggregateCompetition,ready}'
                )::boolean,
                true
            );

        v_aggregate_status :=
            COALESCE(
                v_preview
                #>> '{aggregateCompetition,leaderboardStatus}',
                'NOT_REQUIRED'
            );

        v_ready_to_finalize :=
            COALESCE(
                (v_preview->>'readyToFinalize')::boolean,
                false
            );
    END IF;

    SELECT elem
      INTO v_original_finalization_step
      FROM jsonb_array_elements(v_steps) elem
     WHERE elem->>'code' = 'TOURNAMENT_FINALIZATION'
     LIMIT 1;

    v_finalization_step :=
        v_original_finalization_step;

    -- -----------------------------------------------------------------------
    -- 3. Corregir exclusivamente el paso TOURNAMENT_FINALIZATION.
    -- -----------------------------------------------------------------------

    IF v_original_finalization_step IS NOT NULL THEN

        IF v_tournament_status = 'finalizado' THEN
            v_finalization_step :=
                v_original_finalization_step;

        ELSIF NOT v_all_rounds_formally_closed THEN
            v_finalization_step :=
                jsonb_set(
                    v_original_finalization_step,
                    '{details}',
                    COALESCE(
                        v_original_finalization_step->'details',
                        '{}'::jsonb
                    )
                    || jsonb_build_object(
                        'canFinalizeByRole',
                            v_can_finalize,
                        'finalizationPreviewAvailable',
                            v_preview IS NOT NULL
                    ),
                    true
                );

        ELSIF NOT v_can_finalize THEN
            v_finalization_step :=
                v_original_finalization_step
                || jsonb_build_object(
                    'status',
                        'PENDING',
                    'message',
                        'Todas las rondas tienen cierre formal.',
                    'recommendation',
                        'La finalización del torneo debe ejecutarla el Organizador asignado o el Superadmin.',
                    'action',
                        NULL,
                    'requiredRole',
                        'TOURNAMENT_ORGANIZER_OR_SUPERADMIN'
                );

            v_finalization_step :=
                jsonb_set(
                    v_finalization_step,
                    '{details}',
                    COALESCE(
                        v_finalization_step->'details',
                        '{}'::jsonb
                    )
                    || jsonb_build_object(
                        'canFinalizeByRole',
                            false,
                        'finalizationPreviewAvailable',
                            false
                    ),
                    true
                );

        ELSIF v_ready_to_finalize THEN
            v_finalization_step :=
                v_original_finalization_step
                || jsonb_build_object(
                    'status',
                        'PENDING',
                    'message',
                        CASE
                            WHEN v_competition_mode =
                                 'STABLEFORD_INDIVIDUAL'
                            THEN
                                'Todas las rondas tienen cierre formal y el resultado acumulado Stableford está listo para publicación.'
                            ELSE
                                'Todas las rondas tienen cierre formal.'
                        END,
                    'recommendation',
                        'El torneo puede pasar a su finalización formal.',
                    'action',
                        jsonb_build_object(
                            'label',
                                'Finalizar torneo',
                            'target',
                                'resultados'
                        ),
                    'requiredRole',
                        'TOURNAMENT_ORGANIZER_OR_SUPERADMIN'
                );

            v_finalization_step :=
                jsonb_set(
                    v_finalization_step,
                    '{details}',
                    COALESCE(
                        v_finalization_step->'details',
                        '{}'::jsonb
                    )
                    || jsonb_build_object(
                        'canFinalizeByRole',
                            true,
                        'finalizationPreviewAvailable',
                            true,
                        'competitionMode',
                            v_competition_mode,
                        'aggregateRequired',
                            v_aggregate_required,
                        'aggregateReady',
                            v_aggregate_ready,
                        'aggregateLeaderboardStatus',
                            v_aggregate_status,
                        'readyToFinalize',
                            true
                    ),
                    true
                );

        ELSIF v_competition_mode = 'STABLEFORD_INDIVIDUAL'
          AND v_aggregate_status = 'PROVISIONAL'
        THEN
            v_finalization_step :=
                v_original_finalization_step
                || jsonb_build_object(
                    'status',
                        'PENDING',
                    'message',
                        'Las rondas ya están cerradas, pero el resultado acumulado Stableford todavía es provisional.',
                    'recommendation',
                        'Completa o resuelve las participaciones pendientes del acumulado antes de finalizar.',
                    'action',
                        jsonb_build_object(
                            'label',
                                'Revisar acumulado Stableford',
                            'target',
                                'resultados'
                        ),
                    'requiredRole',
                        'TOURNAMENT_OPERATOR'
                );

            v_finalization_step :=
                jsonb_set(
                    v_finalization_step,
                    '{details}',
                    COALESCE(
                        v_finalization_step->'details',
                        '{}'::jsonb
                    )
                    || jsonb_build_object(
                        'canFinalizeByRole',
                            true,
                        'finalizationPreviewAvailable',
                            true,
                        'competitionMode',
                            v_competition_mode,
                        'aggregateRequired',
                            true,
                        'aggregateReady',
                            false,
                        'aggregateLeaderboardStatus',
                            v_aggregate_status,
                        'readyToFinalize',
                            false
                    ),
                    true
                );

        ELSIF v_competition_mode = 'STABLEFORD_INDIVIDUAL'
          AND v_aggregate_status = 'READY_FOR_TIEBREAK'
        THEN
            v_finalization_step :=
                v_original_finalization_step
                || jsonb_build_object(
                    'status',
                        'PENDING',
                    'message',
                        'Las rondas ya están cerradas, pero existen desempates acumulados Stableford pendientes.',
                    'recommendation',
                        'Resuelve los desempates acumulados antes de finalizar el torneo.',
                    'action',
                        jsonb_build_object(
                            'label',
                                'Resolver desempates acumulados',
                            'target',
                                'resultados'
                        ),
                    'requiredRole',
                        'TOURNAMENT_OPERATOR'
                );

            v_finalization_step :=
                jsonb_set(
                    v_finalization_step,
                    '{details}',
                    COALESCE(
                        v_finalization_step->'details',
                        '{}'::jsonb
                    )
                    || jsonb_build_object(
                        'canFinalizeByRole',
                            true,
                        'finalizationPreviewAvailable',
                            true,
                        'competitionMode',
                            v_competition_mode,
                        'aggregateRequired',
                            true,
                        'aggregateReady',
                            false,
                        'aggregateLeaderboardStatus',
                            v_aggregate_status,
                        'readyToFinalize',
                            false
                    ),
                    true
                );

        ELSIF v_competition_mode = 'MIXED_OR_UNSUPPORTED'
           OR v_aggregate_status =
              'UNSUPPORTED_TOURNAMENT_COMPOSITION'
        THEN
            v_finalization_step :=
                v_original_finalization_step
                || jsonb_build_object(
                    'status',
                        'BLOCKED',
                    'message',
                        'La composición competitiva del torneo todavía no tiene una regla global de finalización soportada.',
                    'recommendation',
                        'Revisa la combinación de modalidades y rondas antes de intentar finalizar.',
                    'action',
                        jsonb_build_object(
                            'label',
                                'Revisar resultados',
                            'target',
                                'resultados'
                        ),
                    'requiredRole',
                        'TOURNAMENT_OPERATOR'
                );

            v_finalization_step :=
                jsonb_set(
                    v_finalization_step,
                    '{details}',
                    COALESCE(
                        v_finalization_step->'details',
                        '{}'::jsonb
                    )
                    || jsonb_build_object(
                        'canFinalizeByRole',
                            true,
                        'finalizationPreviewAvailable',
                            true,
                        'competitionMode',
                            v_competition_mode,
                        'aggregateRequired',
                            v_aggregate_required,
                        'aggregateReady',
                            false,
                        'aggregateLeaderboardStatus',
                            v_aggregate_status,
                        'readyToFinalize',
                            false
                    ),
                    true
                );

        ELSE
            -- Stroke Play / no Stableford:
            -- no se introduce ningún gate artificial.
            v_finalization_step :=
                jsonb_set(
                    v_original_finalization_step,
                    '{details}',
                    COALESCE(
                        v_original_finalization_step->'details',
                        '{}'::jsonb
                    )
                    || jsonb_build_object(
                        'canFinalizeByRole',
                            true,
                        'finalizationPreviewAvailable',
                            v_preview IS NOT NULL,
                        'competitionMode',
                            v_competition_mode,
                        'aggregateRequired',
                            v_aggregate_required,
                        'aggregateReady',
                            v_aggregate_ready,
                        'aggregateLeaderboardStatus',
                            v_aggregate_status,
                        'readyToFinalize',
                            v_ready_to_finalize
                    ),
                    true
                );
        END IF;
    END IF;

    -- -----------------------------------------------------------------------
    -- 4. Reconstruir steps conservando orden.
    -- -----------------------------------------------------------------------

    SELECT COALESCE(
        jsonb_agg(
            CASE
                WHEN s.elem->>'code' =
                     'TOURNAMENT_FINALIZATION'
                THEN v_finalization_step
                ELSE s.elem
            END
            ORDER BY s.ord
        ),
        '[]'::jsonb
    )
      INTO v_new_steps
      FROM jsonb_array_elements(v_steps)
           WITH ORDINALITY AS s(elem, ord);

    SELECT COALESCE(
        jsonb_agg(s.elem ORDER BY s.ord),
        '[]'::jsonb
    )
      INTO v_blockers
      FROM jsonb_array_elements(v_new_steps)
           WITH ORDINALITY AS s(elem, ord)
     WHERE s.elem->>'status' = 'BLOCKED';

    v_blocking_count :=
        jsonb_array_length(v_blockers);

    SELECT s.elem->'action'
      INTO v_next_action
      FROM jsonb_array_elements(v_new_steps)
           WITH ORDINALITY AS s(elem, ord)
     WHERE s.elem->>'status' IN ('BLOCKED', 'PENDING')
       AND s.elem->'action' IS NOT NULL
       AND s.elem->'action' <> 'null'::jsonb
     ORDER BY
        CASE s.elem->>'status'
            WHEN 'BLOCKED' THEN 0
            ELSE 1
        END,
        s.ord
     LIMIT 1;

    -- -----------------------------------------------------------------------
    -- 5. Contrato final v3.
    -- -----------------------------------------------------------------------

    v_result :=
        jsonb_set(
            v_result,
            '{steps}',
            v_new_steps,
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
            to_jsonb(v_blocking_count),
            true
        );

    v_result :=
        jsonb_set(
            v_result,
            '{nextAction}',
            COALESCE(
                v_next_action,
                'null'::jsonb
            ),
            true
        );

    RETURN
        v_result
        || jsonb_build_object(
            'schemaVersion',
                3,
            'tournamentCompetition',
                CASE
                    WHEN v_preview IS NULL
                    THEN jsonb_build_object(
                        'finalizationPreviewAvailable',
                            false,
                        'canFinalizeByRole',
                            v_can_finalize
                    )
                    ELSE jsonb_build_object(
                        'finalizationPreviewAvailable',
                            true,
                        'canFinalizeByRole',
                            v_can_finalize,
                        'competitionMode',
                            v_competition_mode,
                        'aggregateRequired',
                            v_aggregate_required,
                        'aggregateReady',
                            v_aggregate_ready,
                        'aggregateLeaderboardStatus',
                            v_aggregate_status,
                        'readyToFinalize',
                            v_ready_to_finalize
                    )
                END
        );
END;
$function$;

REVOKE ALL
ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
TO authenticated, service_role;

COMMENT ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
IS
'Asistente Operativo v3. Conserva el core 187 y alinea la recomendación de finalización con previsualizar_finalizacion_torneo(), incluyendo el gate acumulado Stableford multirronda. Sólo lectura.';

COMMIT;

-- ============================================================================
-- FIN MIGRACIÓN 188 FASE 1
-- ============================================================================
