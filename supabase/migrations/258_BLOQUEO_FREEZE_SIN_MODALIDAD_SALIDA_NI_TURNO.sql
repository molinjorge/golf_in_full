-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 258
-- Bloqueo de congelamiento sin modalidad de salida ni turno
--
-- OBJETIVO
-- Ninguna ronda activa puede permitir congelar el torneo si:
--   1) tournament_rounds.formato_salida IS NULL, o
--   2) no existe al menos un turno activo en tournament_round_shifts.
--
-- IMPORTANTE
-- - No modifica datos existentes.
-- - No descongela torneos.
-- - No cambia la lógica de HCP TEAM.
-- - No cambia Stroke Play / Stableford / A-Go-Go.
-- - Extiende la PREVISUALIZACIÓN; el RPC de congelamiento ya depende
--   obligatoriamente de dicha previsualización.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1. Conservar la implementación vigente de la previsualización
--    como helper pre-258.
--
--    El rename conserva el OID, definición y ACL existentes del
--    objeto original. El nuevo wrapper público creado más abajo
--    conservará el contrato público.
-- ------------------------------------------------------------

DO $$
BEGIN
    IF to_regprocedure(
        'public._previsualizar_congelamiento_torneo_pre258(uuid)'
    ) IS NULL THEN

        IF to_regprocedure(
            'public.previsualizar_congelamiento_torneo(uuid)'
        ) IS NULL THEN
            RAISE EXCEPTION
                'No existe public.previsualizar_congelamiento_torneo(uuid).';
        END IF;

        ALTER FUNCTION public.previsualizar_congelamiento_torneo(uuid)
            RENAME TO _previsualizar_congelamiento_torneo_pre258;
    END IF;
END;
$$;


-- ------------------------------------------------------------
-- 2. Helper específico 258.
--
--    Devuelve únicamente errores de preparación de salida.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._validar_salida_antes_congelar_258(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH active_rounds AS (
        SELECT
            tr.id,
            tr.numero_ronda,
            tr.formato_salida
        FROM public.tournament_rounds tr
        WHERE tr.tournament_id = p_tournament_id
          AND tr.activo = true
    ),
    problems AS (
        -- Modalidad de salida obligatoria.
        SELECT
            r.numero_ronda,
            1 AS problem_order,
            jsonb_build_object(
                'code', 'round_start_format_missing_before_freeze',
                'message', format(
                    'La ronda %s no tiene definida la modalidad de salida. Define Tee Times o Shotgun antes de congelar.',
                    r.numero_ronda
                ),
                'roundId', r.id,
                'roundNumber', r.numero_ronda
            ) AS item
        FROM active_rounds r
        WHERE r.formato_salida IS NULL

        UNION ALL

        -- Al menos un turno activo por ronda.
        SELECT
            r.numero_ronda,
            2 AS problem_order,
            jsonb_build_object(
                'code', 'round_shift_missing_before_freeze',
                'message', format(
                    'La ronda %s no tiene ningún turno activo. Configura al menos un turno con su hora de salida antes de congelar.',
                    r.numero_ronda
                ),
                'roundId', r.id,
                'roundNumber', r.numero_ronda
            ) AS item
        FROM active_rounds r
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.tournament_round_shifts s
            WHERE s.tournament_round_id = r.id
              AND s.activo = true
        )
    )
    SELECT jsonb_build_object(
        'valid', count(*) = 0,
        'errors', COALESCE(
            jsonb_agg(item ORDER BY numero_ronda, problem_order),
            '[]'::jsonb
        ),
        'errorCount', count(*)::integer
    )
    FROM problems;
$function$;

COMMENT ON FUNCTION public._validar_salida_antes_congelar_258(uuid)
IS 'M258: valida que cada ronda activa tenga formato_salida y al menos un turno activo antes del congelamiento.';


-- ------------------------------------------------------------
-- 3. Reponer el contrato público de previsualización como wrapper.
--
--    La lógica histórica queda intacta en:
--      _previsualizar_congelamiento_torneo_pre258(uuid)
--
--    Este wrapper sólo agrega los errores de salida de M258.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.previsualizar_congelamiento_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base jsonb;
    v_start jsonb;
    v_extra_errors jsonb;
    v_extra_count integer;
    v_base_error_count integer;
BEGIN
    v_base :=
        public._previsualizar_congelamiento_torneo_pre258(
            p_tournament_id
        );

    v_start :=
        public._validar_salida_antes_congelar_258(
            p_tournament_id
        );

    v_extra_errors :=
        COALESCE(v_start->'errors', '[]'::jsonb);

    v_extra_count :=
        COALESCE((v_start->>'errorCount')::integer, 0);

    v_base_error_count :=
        COALESCE((v_base #>> '{counts,errors}')::integer, 0);

    RETURN
        v_base
        || jsonb_build_object(
            'ready',
                COALESCE((v_base->>'ready')::boolean, false)
                AND v_extra_count = 0,
            'errors',
                COALESCE(v_base->'errors', '[]'::jsonb)
                || v_extra_errors,
            'counts',
                COALESCE(v_base->'counts', '{}'::jsonb)
                || jsonb_build_object(
                    'errors',
                    v_base_error_count + v_extra_count
                )
        );
END;
$function$;

COMMENT ON FUNCTION public.previsualizar_congelamiento_torneo(uuid)
IS 'M258: previsualización de congelamiento con bloqueo adicional por modalidad de salida y turnos faltantes.';


-- ------------------------------------------------------------
-- 4. ACL del contrato público.
--
--    Se conserva el acceso que tenía la función antes de M258:
--      postgres, anon, authenticated, service_role.
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION public.previsualizar_congelamiento_torneo(uuid)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION public.previsualizar_congelamiento_torneo(uuid)
TO postgres, anon, authenticated, service_role;


-- El helper nuevo no forma parte del API de cliente.
REVOKE ALL
ON FUNCTION public._validar_salida_antes_congelar_258(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._validar_salida_antes_congelar_258(uuid)
TO postgres, service_role;


COMMIT;
