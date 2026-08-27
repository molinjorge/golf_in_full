-- TEE CENTRAL / GOLF IN FULL
-- Migración 190 Fase 1
-- Asistente Operativo: exponer modalidad actualmente configurada sin alterar
-- la modalidad competitiva congelada usada por finalización.
--
-- Objetivo:
-- - Antes del freeze, el operador debe poder ver la modalidad ya configurada.
-- - La lógica crítica de competencia/finalización sigue usando snapshots.
-- - No se modifica previsualizar_finalizacion_torneo().
--
-- Estrategia segura:
-- 1) Renombrar la implementación v3 actual a un core interno.
-- 2) Recrear obtener_asistente_operativo_torneo(uuid) como wrapper v4.
-- 3) El wrapper llama al core v3 y agrega configuredCompetition.
--
-- configuredCompetition se deriva de la configuración ACTUAL de las rondas activas:
-- COALESCE(tournament_rounds.tournament_format_id, tournaments.tournament_format_id).
-- Esto es informativo y NO autoritativo para finalización.

BEGIN;

DO $$
BEGIN
    IF to_regprocedure('public._obtener_asistente_operativo_torneo_v3_190(uuid)') IS NULL THEN
        IF to_regprocedure('public.obtener_asistente_operativo_torneo(uuid)') IS NULL THEN
            RAISE EXCEPTION 'No existe public.obtener_asistente_operativo_torneo(uuid).';
        END IF;

        ALTER FUNCTION public.obtener_asistente_operativo_torneo(uuid)
            RENAME TO _obtener_asistente_operativo_torneo_v3_190;
    END IF;
END;
$$;

-- El core renombrado queda como implementación interna.
REVOKE ALL ON FUNCTION public._obtener_asistente_operativo_torneo_v3_190(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._obtener_asistente_operativo_torneo_v3_190(uuid) FROM anon;
REVOKE ALL ON FUNCTION public._obtener_asistente_operativo_torneo_v3_190(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public._obtener_asistente_operativo_torneo_v3_190(uuid) TO service_role;

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

    v_active_rounds integer := 0;
    v_configured_rounds integer := 0;
    v_stableford_individual integer := 0;
    v_stableford_other integer := 0;
    v_non_stableford integer := 0;
    v_distinct_effective_formats integer := 0;

    v_configured_mode text := 'UNCONFIGURED';
    v_format_name text := NULL;
    v_scoring_engine text := NULL;
    v_participation_type text := NULL;
BEGIN
    -- Conserva íntegramente permisos, workflow y gates del contrato v3.
    v_result := public._obtener_asistente_operativo_torneo_v3_190(
        p_tournament_id
    );

    -- Sólo después de que el core autorizó al usuario, consultamos la
    -- configuración editable actual para fines informativos.
    WITH effective_round_formats AS (
        SELECT
            tr.id AS tournament_round_id,
            COALESCE(tr.tournament_format_id, t.tournament_format_id) AS effective_format_id,
            tf.name AS format_name,
            tf.scoring_engine,
            tf.tipo_participacion
        FROM public.tournament_rounds tr
        JOIN public.tournaments t
          ON t.id = tr.tournament_id
        LEFT JOIN public.tournament_formats tf
          ON tf.id = COALESCE(tr.tournament_format_id, t.tournament_format_id)
        WHERE tr.tournament_id = p_tournament_id
          AND tr.activo = true
    )
    SELECT
        count(*)::integer,
        count(*) FILTER (WHERE effective_format_id IS NOT NULL)::integer,
        count(*) FILTER (
            WHERE scoring_engine = 'stableford'
              AND tipo_participacion = 'individual'
        )::integer,
        count(*) FILTER (
            WHERE scoring_engine = 'stableford'
              AND tipo_participacion IS DISTINCT FROM 'individual'
        )::integer,
        count(*) FILTER (
            WHERE scoring_engine IS NOT NULL
              AND scoring_engine <> 'stableford'
        )::integer,
        count(DISTINCT effective_format_id) FILTER (
            WHERE effective_format_id IS NOT NULL
        )::integer,
        CASE WHEN count(DISTINCT effective_format_id) FILTER (
                   WHERE effective_format_id IS NOT NULL
             ) = 1
             THEN max(format_name)
             ELSE NULL
        END,
        CASE WHEN count(DISTINCT scoring_engine) FILTER (
                   WHERE scoring_engine IS NOT NULL
             ) = 1
             THEN max(scoring_engine)
             ELSE NULL
        END,
        CASE WHEN count(DISTINCT tipo_participacion) FILTER (
                   WHERE tipo_participacion IS NOT NULL
             ) = 1
             THEN max(tipo_participacion)
             ELSE NULL
        END
    INTO
        v_active_rounds,
        v_configured_rounds,
        v_stableford_individual,
        v_stableford_other,
        v_non_stableford,
        v_distinct_effective_formats,
        v_format_name,
        v_scoring_engine,
        v_participation_type
    FROM effective_round_formats;

    IF v_active_rounds = 0 THEN
        v_configured_mode := 'NO_ACTIVE_ROUNDS';

    ELSIF v_configured_rounds < v_active_rounds THEN
        v_configured_mode := 'UNCONFIGURED';

    ELSIF v_stableford_individual = v_active_rounds THEN
        v_configured_mode := 'STABLEFORD_INDIVIDUAL';

    ELSIF v_stableford_other > 0
       OR (v_stableford_individual > 0 AND v_non_stableford > 0)
    THEN
        v_configured_mode := 'MIXED_OR_UNSUPPORTED';

    ELSE
        v_configured_mode := 'LEGACY_OR_NON_STABLEFORD';
    END IF;

    RETURN
        v_result
        || jsonb_build_object(
            'schemaVersion', 4,
            'configuredCompetition',
                jsonb_build_object(
                    'source', 'CURRENT_CONFIGURATION',
                    'authoritativeForFinalization', false,
                    'mode', v_configured_mode,
                    'formatName', v_format_name,
                    'scoringEngine', v_scoring_engine,
                    'participationType', v_participation_type,
                    'activeRounds', v_active_rounds,
                    'configuredRounds', v_configured_rounds,
                    'distinctEffectiveFormats', v_distinct_effective_formats,
                    'stablefordIndividualRounds', v_stableford_individual,
                    'stablefordOtherRounds', v_stableford_other,
                    'nonStablefordRounds', v_non_stableford,
                    'frozen', COALESCE((v_result #>> '{status,frozen}')::boolean, false)
                )
        );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_asistente_operativo_torneo(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_asistente_operativo_torneo(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_asistente_operativo_torneo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_asistente_operativo_torneo(uuid) TO service_role;

COMMENT ON FUNCTION public.obtener_asistente_operativo_torneo(uuid) IS
'Asistente Operativo v4. Conserva íntegramente el workflow/gates v3 y agrega configuredCompetition derivado de la configuración editable actual. configuredCompetition es informativo y nunca autoritativo para finalización; tournamentCompetition continúa proveniendo del preview competitivo basado en snapshots.';

COMMIT;
