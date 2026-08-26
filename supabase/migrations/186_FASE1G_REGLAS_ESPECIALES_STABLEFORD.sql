-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 186 Fase 1G
-- Reglas especiales Stableford configurables + snapshot inmutable
--
-- ALCANCE
--   - Configuración por torneo de reglas especiales Stableford.
--   - Primera regla soportada: HOLE_IN_ONE_OVERRIDE.
--   - Semántica: sustituye los puntos Stableford normales por el valor configurado.
--   - Snapshot inmutable durante el freeze.
--   - NO calcula todavía puntos Stableford (eso queda para 1H).
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.tournament_stableford_special_rules (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    rule_code text NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    points integer NOT NULL,
    behavior text NOT NULL DEFAULT 'OVERRIDE',
    created_by uuid NULL REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_stableford_special_rules_code_ck
        CHECK (rule_code IN ('HOLE_IN_ONE_OVERRIDE')),
    CONSTRAINT tournament_stableford_special_rules_points_ck
        CHECK (points >= 0),
    CONSTRAINT tournament_stableford_special_rules_behavior_ck
        CHECK (behavior = 'OVERRIDE'),
    CONSTRAINT tournament_stableford_special_rules_uk
        UNIQUE (tournament_id, rule_code)
);

CREATE INDEX IF NOT EXISTS idx_tournament_stableford_special_rules_tournament
ON public.tournament_stableford_special_rules(tournament_id);

DROP TRIGGER IF EXISTS trg_tournament_stableford_special_rules_updated_at
ON public.tournament_stableford_special_rules;

CREATE TRIGGER trg_tournament_stableford_special_rules_updated_at
BEFORE UPDATE ON public.tournament_stableford_special_rules
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_proteger_stableford_special_rules_congelado
ON public.tournament_stableford_special_rules;

CREATE TRIGGER trg_proteger_stableford_special_rules_congelado
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_stableford_special_rules
FOR EACH ROW
EXECUTE FUNCTION public.proteger_configuracion_especifica_torneo_congelado();

CREATE TABLE IF NOT EXISTS public.tournament_stableford_special_rule_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    freeze_id uuid NOT NULL
        REFERENCES public.tournament_condition_freezes(id) ON DELETE RESTRICT,
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    source_rule_id uuid NOT NULL
        REFERENCES public.tournament_stableford_special_rules(id) ON DELETE RESTRICT,
    rule_code text NOT NULL,
    enabled boolean NOT NULL,
    points integer NOT NULL,
    behavior text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_stableford_special_rule_snapshots_code_ck
        CHECK (rule_code IN ('HOLE_IN_ONE_OVERRIDE')),
    CONSTRAINT tournament_stableford_special_rule_snapshots_points_ck
        CHECK (points >= 0),
    CONSTRAINT tournament_stableford_special_rule_snapshots_behavior_ck
        CHECK (behavior = 'OVERRIDE'),
    CONSTRAINT tournament_stableford_special_rule_snapshots_uk
        UNIQUE (freeze_id, rule_code)
);

DROP TRIGGER IF EXISTS trg_no_mutar_stableford_special_rule_snapshots
ON public.tournament_stableford_special_rule_snapshots;

CREATE TRIGGER trg_no_mutar_stableford_special_rule_snapshots
BEFORE UPDATE OR DELETE
ON public.tournament_stableford_special_rule_snapshots
FOR EACH ROW
EXECUTE FUNCTION public.impedir_mutacion_snapshot_torneo();

-- Congelamiento: reutiliza 1F y agrega reglas especiales sin mutar el freeze principal.
CREATE OR REPLACE FUNCTION public.congelar_condiciones_y_handicaps_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_result jsonb;
    v_freeze_id uuid;
    v_category_count integer;
    v_snapshot_category_count integer;
    v_category_snapshot_rows integer;
    v_special_rule_snapshot_rows integer;
BEGIN
    v_result :=
        public._congelar_condiciones_y_handicaps_torneo_core_1861a(
            p_tournament_id
        );

    v_freeze_id := NULLIF(v_result->>'freezeId','')::uuid;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION 'El congelamiento base no devolvió freezeId.'
            USING ERRCODE='55000';
    END IF;

    SELECT count(*)
      INTO v_category_count
      FROM public.tournament_categories
     WHERE tournament_id=p_tournament_id;

    INSERT INTO public.tournament_category_classification_snapshots(
        freeze_id,tournament_id,source_classification_id,
        tournament_category_id,category_id,category_code,
        category_name,category_display_order,tipo_resultado
    )
    SELECT
        v_freeze_id,tc.tournament_id,cc.id,tc.id,c.id,c.codigo,
        c.nombre,c.display_order,cc.tipo_resultado
    FROM public.tournament_categories tc
    JOIN public.categories c ON c.id=tc.category_id
    JOIN public.tournament_category_classifications cc
      ON cc.tournament_category_id=tc.id
     AND cc.tournament_id=tc.tournament_id
    WHERE tc.tournament_id=p_tournament_id
    ON CONFLICT (freeze_id,tournament_category_id,tipo_resultado) DO NOTHING;

    GET DIAGNOSTICS v_category_snapshot_rows=ROW_COUNT;

    SELECT count(DISTINCT tournament_category_id)
      INTO v_snapshot_category_count
      FROM public.tournament_category_classification_snapshots
     WHERE freeze_id=v_freeze_id;

    IF v_snapshot_category_count <> v_category_count THEN
        RAISE EXCEPTION
            'El snapshot de clasificaciones por categoría quedó incompleto y el congelamiento fue revertido.'
            USING ERRCODE='55000',
                  DETAIL=format('categorias_snapshot=%s/%s',
                                v_snapshot_category_count,v_category_count);
    END IF;

    INSERT INTO public.tournament_stableford_special_rule_snapshots(
        freeze_id,tournament_id,source_rule_id,
        rule_code,enabled,points,behavior
    )
    SELECT
        v_freeze_id,r.tournament_id,r.id,
        r.rule_code,r.enabled,r.points,r.behavior
    FROM public.tournament_stableford_special_rules r
    WHERE r.tournament_id=p_tournament_id
    ON CONFLICT (freeze_id,rule_code) DO NOTHING;

    GET DIAGNOSTICS v_special_rule_snapshot_rows=ROW_COUNT;

    RETURN v_result || jsonb_build_object(
        'categoryClassificationSnapshots',v_category_snapshot_rows,
        'stablefordSpecialRuleSnapshots',v_special_rule_snapshot_rows
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.congelar_condiciones_y_handicaps_torneo(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.congelar_condiciones_y_handicaps_torneo(uuid)
TO anon,authenticated,service_role;

COMMIT;
