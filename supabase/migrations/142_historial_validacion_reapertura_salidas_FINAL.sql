-- ============================================================================
-- MIGRACIÓN 142
-- HISTORIAL AUDITABLE DE VALIDACIÓN / REAPERTURA DE SALIDAS POR RONDA
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_historial_validacion_salidas_ronda(
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
    v_history jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tr.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds tr
     WHERE tr.id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar el historial de validación de salidas de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', v.id,
                'version', v.version,
                'status', v.status,
                'validatedAt', v.validated_at,
                'validatedBy',
                    CASE
                        WHEN v.validated_by IS NULL THEN NULL
                        ELSE jsonb_build_object(
                            'adminUserId', v.validated_by,
                            'displayName', COALESCE(
                                NULLIF(
                                    concat_ws(
                                        ' ',
                                        NULLIF(to_jsonb(validator)->>'nombres', ''),
                                        NULLIF(to_jsonb(validator)->>'apellidos', '')
                                    ),
                                    ''
                                ),
                                NULLIF(to_jsonb(validator)->>'nombre', ''),
                                NULLIF(to_jsonb(validator)->>'name', ''),
                                NULLIF(to_jsonb(validator)->>'email', ''),
                                v.validated_by::text
                            )
                        )
                    END,
                'reopenedAt', v.reopened_at,
                'reopenedBy',
                    CASE
                        WHEN v.reopened_by IS NULL THEN NULL
                        ELSE jsonb_build_object(
                            'adminUserId', v.reopened_by,
                            'displayName', COALESCE(
                                NULLIF(
                                    concat_ws(
                                        ' ',
                                        NULLIF(to_jsonb(reopener)->>'nombres', ''),
                                        NULLIF(to_jsonb(reopener)->>'apellidos', '')
                                    ),
                                    ''
                                ),
                                NULLIF(to_jsonb(reopener)->>'nombre', ''),
                                NULLIF(to_jsonb(reopener)->>'name', ''),
                                NULLIF(to_jsonb(reopener)->>'email', ''),
                                v.reopened_by::text
                            )
                        )
                    END,
                'reopenReason', v.reopen_reason,
                'validatorEngine', v.validator_engine,
                'startFormat', v.start_format,
                'participationType', v.participation_type,
                'scoringEngine', v.scoring_engine,
                'contentHash', v.content_hash,
                'counts', jsonb_build_object(
                    'configs', v.config_count,
                    'groups', v.group_count,
                    'units', v.unit_count
                )
            )
            ORDER BY v.version DESC, v.validated_at DESC, v.id DESC
        ),
        '[]'::jsonb
    )
      INTO v_history
      FROM public.tournament_round_start_validations v
      LEFT JOIN public.admin_users validator
        ON validator.id = v.validated_by
      LEFT JOIN public.admin_users reopener
        ON reopener.id = v.reopened_by
     WHERE v.tournament_round_id = p_tournament_round_id;

    RETURN jsonb_build_object(
        'tournamentRoundId', p_tournament_round_id,
        'latestVersion', COALESCE(
            (
                SELECT max(v.version)
                FROM public.tournament_round_start_validations v
                WHERE v.tournament_round_id = p_tournament_round_id
            ),
            0
        ),
        'historyCount', jsonb_array_length(v_history),
        'history', v_history
    );
END;
$function$;

COMMENT ON FUNCTION public.obtener_historial_validacion_salidas_ronda(uuid)
IS 'Devuelve el historial auditable y versionado de validaciones/reaperturas de salidas de una ronda. Solo lectura.';

REVOKE ALL
ON FUNCTION public.obtener_historial_validacion_salidas_ronda(uuid)
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.obtener_historial_validacion_salidas_ronda(uuid)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.obtener_historial_validacion_salidas_ronda(uuid)
TO authenticated;

COMMIT;
