-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 186 Fase 1F
-- Corrección de inmutabilidad del freeze introducida en 186 Fase 1A
--
-- PROBLEMA DETECTADO
--   186 Fase 1A extendió congelar_condiciones_y_handicaps_torneo(uuid) para
--   materializar snapshots de clasificaciones por categoría, pero después del
--   core intentaba hacer UPDATE a tournament_condition_freezes para agregar
--   JSON/schema_version. Esa tabla es inmutable y su trigger bloquea UPDATE.
--
-- SOLUCIÓN
--   1) Mantener tournament_category_classification_snapshots como autoridad
--      histórica estructurada.
--   2) No modificar nunca tournament_condition_freezes después de INSERT.
--   3) Proteger también los snapshots de clasificación contra UPDATE/DELETE.
--   4) Mantener la validación previa de que toda categoría tenga al menos una
--      clasificación.
--
-- NO CAMBIA
--   - No altera freezes históricos.
--   - No modifica clasificaciones vivas.
--   - No modifica scoring, tarjetas, conciliación ni leaderboard.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Inmutabilidad de snapshot de clasificaciones.
-- ----------------------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_no_mutar_tournament_category_classification_snapshots
    ON public.tournament_category_classification_snapshots;

CREATE TRIGGER trg_no_mutar_tournament_category_classification_snapshots
BEFORE UPDATE OR DELETE
ON public.tournament_category_classification_snapshots
FOR EACH ROW
EXECUTE FUNCTION public.impedir_mutacion_snapshot_torneo();

-- ----------------------------------------------------------------------------
-- 2. Corregir wrapper de freeze.
--    Conserva el core histórico y materializa sólo la tabla snapshot.
--    NO hace UPDATE sobre tournament_condition_freezes.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.congelar_condiciones_y_handicaps_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_result jsonb;
    v_freeze_id uuid;
    v_category_count integer;
    v_snapshot_category_count integer;
    v_snapshot_row_count integer;
BEGIN
    v_result :=
        public._congelar_condiciones_y_handicaps_torneo_core_1861a(
            p_tournament_id
        );

    v_freeze_id := NULLIF(v_result->>'freezeId', '')::uuid;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION
            'El congelamiento base no devolvió freezeId.'
            USING ERRCODE = '55000';
    END IF;

    SELECT count(*)
      INTO v_category_count
      FROM public.tournament_categories tc
     WHERE tc.tournament_id = p_tournament_id;

    INSERT INTO public.tournament_category_classification_snapshots (
        freeze_id,
        tournament_id,
        source_classification_id,
        tournament_category_id,
        category_id,
        category_code,
        category_name,
        category_display_order,
        tipo_resultado
    )
    SELECT
        v_freeze_id,
        tc.tournament_id,
        cc.id,
        tc.id,
        c.id,
        c.codigo,
        c.nombre,
        c.display_order,
        cc.tipo_resultado
    FROM public.tournament_categories tc
    JOIN public.categories c
      ON c.id = tc.category_id
    JOIN public.tournament_category_classifications cc
      ON cc.tournament_category_id = tc.id
     AND cc.tournament_id = tc.tournament_id
    WHERE tc.tournament_id = p_tournament_id
    ON CONFLICT (
        freeze_id,
        tournament_category_id,
        tipo_resultado
    ) DO NOTHING;

    GET DIAGNOSTICS v_snapshot_row_count = ROW_COUNT;

    SELECT count(DISTINCT tournament_category_id)
      INTO v_snapshot_category_count
      FROM public.tournament_category_classification_snapshots
     WHERE freeze_id = v_freeze_id;

    IF v_snapshot_category_count <> v_category_count THEN
        RAISE EXCEPTION
            'El snapshot de clasificaciones por categoría quedó incompleto y el congelamiento fue revertido.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'categorias_snapshot=%s/%s',
                      v_snapshot_category_count,
                      v_category_count
                  );
    END IF;

    RETURN
        v_result
        || jsonb_build_object(
            'categoryClassificationSnapshots',
            v_snapshot_row_count
        );
END;
$function$;

REVOKE ALL ON FUNCTION public.congelar_condiciones_y_handicaps_torneo(uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.congelar_condiciones_y_handicaps_torneo(uuid)
TO anon, authenticated, service_role;

COMMIT;

-- ============================================================================
-- FIN MIGRACIÓN 186 FASE 1F
-- ============================================================================
