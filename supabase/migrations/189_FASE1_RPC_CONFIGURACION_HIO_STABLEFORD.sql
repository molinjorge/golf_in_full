-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 189 Fase 1
-- RPCs seguras para configurar la regla especial Stableford Hole in One
--
-- ALCANCE
--   - Expone lectura administrativa de HOLE_IN_ONE_OVERRIDE.
--   - Expone escritura administrativa controlada por RPC SECURITY DEFINER.
--   - Mantiene la tabla base cerrada por RLS; NO agrega políticas directas.
--   - Respeta el freeze existente y el trigger de inmutabilidad.
--   - No modifica snapshots ni cálculo Stableford.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1. Lectura administrativa de la regla especial Stableford del torneo.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_reglas_especiales_stableford_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_exists boolean;
    v_is_stableford boolean;
    v_frozen boolean;
    v_rule public.tournament_stableford_special_rules%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(), p_tournament_id)
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden consultar las reglas especiales Stableford del torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT EXISTS(
        SELECT 1
        FROM public.tournaments t
        WHERE t.id = p_tournament_id
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    SELECT EXISTS(
        SELECT 1
        FROM public.tournaments t
        LEFT JOIN public.tournament_formats tf_default
          ON tf_default.id = t.tournament_format_id
        WHERE t.id = p_tournament_id
          AND (
              tf_default.scoring_engine::text = 'stableford'
              OR EXISTS (
                  SELECT 1
                  FROM public.tournament_rounds tr
                  JOIN public.tournament_formats tf_round
                    ON tf_round.id = COALESCE(tr.tournament_format_id, t.tournament_format_id)
                  WHERE tr.tournament_id = t.id
                    AND tf_round.scoring_engine::text = 'stableford'
              )
          )
    )
    INTO v_is_stableford;

    SELECT EXISTS(
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = p_tournament_id
    )
    INTO v_frozen;

    SELECT r.*
      INTO v_rule
      FROM public.tournament_stableford_special_rules r
     WHERE r.tournament_id = p_tournament_id
       AND r.rule_code = 'HOLE_IN_ONE_OVERRIDE';

    RETURN jsonb_build_object(
        'schemaVersion', 1,
        'tournamentId', p_tournament_id,
        'scoringEngine', CASE WHEN v_is_stableford THEN 'stableford' ELSE NULL END,
        'stablefordApplicable', v_is_stableford,
        'frozen', v_frozen,
        'editable', (v_is_stableford AND NOT v_frozen),
        'holeInOneOverride', jsonb_build_object(
            'ruleCode', 'HOLE_IN_ONE_OVERRIDE',
            'configured', FOUND,
            'enabled', COALESCE(v_rule.enabled, false),
            'points', CASE WHEN FOUND THEN v_rule.points ELSE NULL END,
            'behavior', COALESCE(v_rule.behavior, 'OVERRIDE'),
            'limits', jsonb_build_object(
                'minimumPoints', 0,
                'maximumPoints', NULL
            )
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_reglas_especiales_stableford_torneo(uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_reglas_especiales_stableford_torneo(uuid)
TO authenticated, service_role;

-- --------------------------------------------------------------------------
-- 2. Escritura administrativa de HOLE_IN_ONE_OVERRIDE.
--
-- Reglas:
--   - Sólo Stableford.
--   - Organizador asignado o Superadmin.
--   - No editable después del freeze.
--   - Al habilitar, points es obligatorio y >= 0.
--   - Al deshabilitar una regla existente, conserva points si no se envía uno.
--   - Deshabilitar sin fila previa es un no-op seguro.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.configurar_regla_hole_in_one_torneo(
    p_tournament_id uuid,
    p_enabled boolean,
    p_points integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_admin_id uuid;
    v_exists boolean;
    v_is_stableford boolean;
    v_frozen boolean;
    v_current public.tournament_stableford_special_rules%ROWTYPE;
    v_saved public.tournament_stableford_special_rules%ROWTYPE;
    v_effective_points integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF p_enabled IS NULL THEN
        RAISE EXCEPTION 'Debes indicar si la regla Hole in One está habilitada.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(), p_tournament_id)
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden configurar la regla Hole in One del torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT EXISTS(
        SELECT 1
        FROM public.tournaments t
        WHERE t.id = p_tournament_id
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    SELECT EXISTS(
        SELECT 1
        FROM public.tournaments t
        LEFT JOIN public.tournament_formats tf_default
          ON tf_default.id = t.tournament_format_id
        WHERE t.id = p_tournament_id
          AND (
              tf_default.scoring_engine::text = 'stableford'
              OR EXISTS (
                  SELECT 1
                  FROM public.tournament_rounds tr
                  JOIN public.tournament_formats tf_round
                    ON tf_round.id = COALESCE(tr.tournament_format_id, t.tournament_format_id)
                  WHERE tr.tournament_id = t.id
                    AND tf_round.scoring_engine::text = 'stableford'
              )
          )
    )
    INTO v_is_stableford;

    IF NOT v_is_stableford THEN
        RAISE EXCEPTION
            'La regla Hole in One sólo puede configurarse para torneos que usan Stableford.'
            USING ERRCODE = '23514';
    END IF;

    SELECT EXISTS(
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = p_tournament_id
    )
    INTO v_frozen;

    IF v_frozen THEN
        RAISE EXCEPTION
            'No se puede modificar la regla Hole in One porque las condiciones del torneo ya fueron congeladas.'
            USING ERRCODE = '55000';
    END IF;

    IF p_points IS NOT NULL AND p_points < 0 THEN
        RAISE EXCEPTION 'Los puntos de Hole in One no pueden ser negativos.'
            USING ERRCODE = '23514';
    END IF;

    SELECT r.*
      INTO v_current
      FROM public.tournament_stableford_special_rules r
     WHERE r.tournament_id = p_tournament_id
       AND r.rule_code = 'HOLE_IN_ONE_OVERRIDE'
     FOR UPDATE;

    IF p_enabled AND p_points IS NULL AND NOT FOUND THEN
        RAISE EXCEPTION
            'Debes indicar los puntos para habilitar la regla Hole in One.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT p_enabled AND NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok', true,
            'schemaVersion', 1,
            'tournamentId', p_tournament_id,
            'frozen', false,
            'editable', true,
            'holeInOneOverride', jsonb_build_object(
                'ruleCode', 'HOLE_IN_ONE_OVERRIDE',
                'configured', false,
                'enabled', false,
                'points', NULL,
                'behavior', 'OVERRIDE'
            )
        );
    END IF;

    IF p_points IS NOT NULL THEN
        v_effective_points := p_points;
    ELSE
        v_effective_points := v_current.points;
    END IF;

    IF p_enabled AND v_effective_points IS NULL THEN
        RAISE EXCEPTION
            'Debes indicar los puntos para habilitar la regla Hole in One.'
            USING ERRCODE = '22023';
    END IF;

    SELECT public.current_admin_id()
      INTO v_admin_id;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No se encontró el usuario administrativo autenticado.'
            USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.tournament_stableford_special_rules(
        tournament_id,
        rule_code,
        enabled,
        points,
        behavior,
        created_by
    )
    VALUES (
        p_tournament_id,
        'HOLE_IN_ONE_OVERRIDE',
        p_enabled,
        v_effective_points,
        'OVERRIDE',
        v_admin_id
    )
    ON CONFLICT (tournament_id, rule_code)
    DO UPDATE SET
        enabled = EXCLUDED.enabled,
        points = EXCLUDED.points,
        behavior = 'OVERRIDE'
    RETURNING * INTO v_saved;

    RETURN jsonb_build_object(
        'ok', true,
        'schemaVersion', 1,
        'tournamentId', p_tournament_id,
        'frozen', false,
        'editable', true,
        'holeInOneOverride', jsonb_build_object(
            'ruleCode', v_saved.rule_code,
            'configured', true,
            'enabled', v_saved.enabled,
            'points', v_saved.points,
            'behavior', v_saved.behavior
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.configurar_regla_hole_in_one_torneo(uuid,boolean,integer)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.configurar_regla_hole_in_one_torneo(uuid,boolean,integer)
TO authenticated, service_role;

COMMENT ON FUNCTION public.obtener_reglas_especiales_stableford_torneo(uuid)
IS 'Lee de forma administrativa la configuración Stableford especial del torneo. No expone la tabla por RLS y reporta frozen/editable.';

COMMENT ON FUNCTION public.configurar_regla_hole_in_one_torneo(uuid,boolean,integer)
IS 'Configura HOLE_IN_ONE_OVERRIDE antes del freeze. Organizador asignado o Superadmin. No escribe snapshots.';

COMMIT;
