-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 186 Fase 1A
-- Clasificaciones competitivas por categoría + snapshot de freeze
--
-- OBJETIVO
--   1) Representar qué clasificaciones oficiales publica cada categoría:
--      GROSS, NETO o ambas.
--   2) Preservar el comportamiento histórico actual: todas las categorías
--      existentes y nuevas nacen con GROSS + NETO.
--   3) Impedir cambios después del congelamiento del torneo.
--   4) Congelar la configuración por categoría para reproducibilidad histórica.
--
-- NO HACE
--   - No calcula Stableford.
--   - No modifica tarjetas, captura, conciliación, resultados ni leaderboard.
--   - No habilita todavía Stableford en tournament_start_engine_registry.
--   - No modifica reglas de desempate.
--
-- EJECUCIÓN
--   Ejecutar manualmente en SQL Editor del proyecto GOLFING_FULL.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Configuración viva de clasificaciones oficiales por categoría.
--
-- Reutilizamos public.tipo_resultado_desempate ('gross','neto') porque el
-- dominio semántico coincide con los dos ejes competitivos que ya usa el motor
-- de desempates. La tabla es extensible: una categoría tiene una fila por tipo.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_category_classifications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    tournament_category_id uuid NOT NULL
        REFERENCES public.tournament_categories(id) ON DELETE CASCADE,
    tipo_resultado public.tipo_resultado_desempate NOT NULL,
    created_by uuid NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_category_classifications_uk
        UNIQUE (tournament_category_id, tipo_resultado)
);

COMMENT ON TABLE public.tournament_category_classifications IS
'Clasificaciones competitivas oficiales habilitadas por categoría de torneo. V1: gross y/o neto.';

COMMENT ON COLUMN public.tournament_category_classifications.tipo_resultado IS
'Clasificación oficial habilitada para la categoría: gross o neto.';

-- ----------------------------------------------------------------------------
-- 2. Integridad tournament_id <-> tournament_category_id.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.validar_clasificacion_categoria_torneo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
BEGIN
    SELECT tc.tournament_id
      INTO v_tournament_id
      FROM public.tournament_categories tc
     WHERE tc.id = NEW.tournament_category_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION
            'La categoría de torneo indicada no existe.'
            USING ERRCODE = '23503';
    END IF;

    IF NEW.tournament_id IS DISTINCT FROM v_tournament_id THEN
        RAISE EXCEPTION
            'La clasificación debe pertenecer al mismo torneo que la categoría.'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_validar_clasificacion_categoria_torneo
    ON public.tournament_category_classifications;

CREATE TRIGGER trg_validar_clasificacion_categoria_torneo
BEFORE INSERT OR UPDATE
ON public.tournament_category_classifications
FOR EACH ROW
EXECUTE FUNCTION public.validar_clasificacion_categoria_torneo();

-- ----------------------------------------------------------------------------
-- 3. updated_at + protección por freeze.
-- ----------------------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_tournament_category_classifications_updated_at
    ON public.tournament_category_classifications;

CREATE TRIGGER trg_tournament_category_classifications_updated_at
BEFORE UPDATE
ON public.tournament_category_classifications
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_proteger_category_classifications_congelado
    ON public.tournament_category_classifications;

CREATE TRIGGER trg_proteger_category_classifications_congelado
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_category_classifications
FOR EACH ROW
EXECUTE FUNCTION public.proteger_configuracion_especifica_torneo_congelado();

-- ----------------------------------------------------------------------------
-- 4. RLS: misma frontera administrativa de tournament_categories.
-- ----------------------------------------------------------------------------

ALTER TABLE public.tournament_category_classifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tournament_category_classifications_select
    ON public.tournament_category_classifications;

CREATE POLICY tournament_category_classifications_select
ON public.tournament_category_classifications
FOR SELECT
TO public
USING (true);

DROP POLICY IF EXISTS tournament_category_classifications_write
    ON public.tournament_category_classifications;

CREATE POLICY tournament_category_classifications_write
ON public.tournament_category_classifications
FOR ALL
TO authenticated
USING (
    public.is_superadmin(auth.uid())
    OR public.is_tournament_organizer(auth.uid(), tournament_id)
    OR EXISTS (
        SELECT 1
        FROM public.tournaments t
        WHERE t.id = tournament_id
          AND public.is_club_admin(auth.uid(), t.club_id)
    )
)
WITH CHECK (
    public.is_superadmin(auth.uid())
    OR public.is_tournament_organizer(auth.uid(), tournament_id)
    OR EXISTS (
        SELECT 1
        FROM public.tournaments t
        WHERE t.id = tournament_id
          AND public.is_club_admin(auth.uid(), t.club_id)
    )
);

GRANT SELECT ON public.tournament_category_classifications TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.tournament_category_classifications TO authenticated;
GRANT ALL ON public.tournament_category_classifications TO service_role;

-- ----------------------------------------------------------------------------
-- 5. Backfill: preservar comportamiento vigente.
--    Todas las categorías existentes quedan con GROSS + NETO.
-- ----------------------------------------------------------------------------

INSERT INTO public.tournament_category_classifications (
    tournament_id,
    tournament_category_id,
    tipo_resultado,
    created_by
)
SELECT
    tc.tournament_id,
    tc.id,
    rt.tipo_resultado,
    tc.created_by
FROM public.tournament_categories tc
CROSS JOIN (
    VALUES
        ('gross'::public.tipo_resultado_desempate),
        ('neto'::public.tipo_resultado_desempate)
) AS rt(tipo_resultado)
ON CONFLICT (tournament_category_id, tipo_resultado) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 6. Default para categorías nuevas: GROSS + NETO.
--    El organizador puede quitar una antes del freeze.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.inicializar_clasificaciones_categoria_torneo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    INSERT INTO public.tournament_category_classifications (
        tournament_id,
        tournament_category_id,
        tipo_resultado,
        created_by
    )
    VALUES
        (
            NEW.tournament_id,
            NEW.id,
            'gross'::public.tipo_resultado_desempate,
            NEW.created_by
        ),
        (
            NEW.tournament_id,
            NEW.id,
            'neto'::public.tipo_resultado_desempate,
            NEW.created_by
        )
    ON CONFLICT (tournament_category_id, tipo_resultado) DO NOTHING;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_inicializar_clasificaciones_categoria_torneo
    ON public.tournament_categories;

CREATE TRIGGER trg_inicializar_clasificaciones_categoria_torneo
AFTER INSERT
ON public.tournament_categories
FOR EACH ROW
EXECUTE FUNCTION public.inicializar_clasificaciones_categoria_torneo();

-- ----------------------------------------------------------------------------
-- 7. Snapshot estructurado de clasificaciones por categoría.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_category_classification_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    freeze_id uuid NOT NULL
        REFERENCES public.tournament_condition_freezes(id) ON DELETE RESTRICT,
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    source_classification_id uuid NOT NULL
        REFERENCES public.tournament_category_classifications(id) ON DELETE RESTRICT,
    tournament_category_id uuid NOT NULL
        REFERENCES public.tournament_categories(id) ON DELETE RESTRICT,
    category_id uuid NOT NULL
        REFERENCES public.categories(id) ON DELETE RESTRICT,
    category_code text NOT NULL,
    category_name text NOT NULL,
    category_display_order integer NULL,
    tipo_resultado public.tipo_resultado_desempate NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_category_classification_snapshots_uk
        UNIQUE (freeze_id, tournament_category_id, tipo_resultado)
);

COMMENT ON TABLE public.tournament_category_classification_snapshots IS
'Fotografía inmutable de las clasificaciones oficiales por categoría al congelar el torneo.';

ALTER TABLE public.tournament_category_classification_snapshots
    ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tournament_category_classification_snapshots_select
    ON public.tournament_category_classification_snapshots;

CREATE POLICY tournament_category_classification_snapshots_select
ON public.tournament_category_classification_snapshots
FOR SELECT
TO authenticated
USING (public.puede_ver_congelamiento_torneo(tournament_id));

REVOKE ALL ON public.tournament_category_classification_snapshots FROM anon;
GRANT SELECT ON public.tournament_category_classification_snapshots TO authenticated;
GRANT ALL ON public.tournament_category_classification_snapshots TO service_role;

-- ----------------------------------------------------------------------------
-- 8. Preview de freeze:
--    preservamos la implementación actual como core y agregamos la validación
--    de que toda categoría tenga al menos una clasificación oficial.
-- ----------------------------------------------------------------------------

DO $do$
BEGIN
    IF to_regprocedure(
        'public._previsualizar_congelamiento_torneo_core_1861a(uuid)'
    ) IS NULL THEN
        ALTER FUNCTION public.previsualizar_congelamiento_torneo(uuid)
            RENAME TO _previsualizar_congelamiento_torneo_core_1861a;
    END IF;
END;
$do$;

-- El core preservado es implementación interna: no debe poder invocarse
-- directamente desde la API porque omitiría la validación añadida por el wrapper.
REVOKE ALL ON FUNCTION
    public._previsualizar_congelamiento_torneo_core_1861a(uuid)
    FROM PUBLIC, anon, authenticated, service_role;

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
    v_extra_errors jsonb;
    v_extra_count integer;
BEGIN
    v_base :=
        public._previsualizar_congelamiento_torneo_core_1861a(
            p_tournament_id
        );

    SELECT
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'code', 'category_classification_missing',
                    'message',
                        format(
                            'La categoría %s no tiene clasificación oficial Gross/Net definida.',
                            c.nombre
                        ),
                    'tournamentCategoryId', tc.id
                )
                ORDER BY c.display_order NULLS LAST, c.nombre, tc.id
            ),
            '[]'::jsonb
        ),
        count(*)::integer
      INTO v_extra_errors, v_extra_count
      FROM public.tournament_categories tc
      JOIN public.categories c
        ON c.id = tc.category_id
     WHERE tc.tournament_id = p_tournament_id
       AND NOT EXISTS (
            SELECT 1
            FROM public.tournament_category_classifications cc
            WHERE cc.tournament_category_id = tc.id
              AND cc.tournament_id = tc.tournament_id
       );

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
                        COALESCE(
                            (v_base #>> '{counts,errors}')::integer,
                            0
                        ) + v_extra_count
                )
        );
END;
$function$;

REVOKE ALL ON FUNCTION public.previsualizar_congelamiento_torneo(uuid)
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.previsualizar_congelamiento_torneo(uuid)
    TO anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 9. Freeze:
--    preservamos el core actual, ejecutamos el congelamiento existente y,
--    dentro de la MISMA transacción, agregamos el snapshot de clasificaciones.
--    Si el snapshot queda incompleto, se lanza excepción y todo el freeze revierte.
-- ----------------------------------------------------------------------------

DO $do$
BEGIN
    IF to_regprocedure(
        'public._congelar_condiciones_y_handicaps_torneo_core_1861a(uuid)'
    ) IS NULL THEN
        ALTER FUNCTION public.congelar_condiciones_y_handicaps_torneo(uuid)
            RENAME TO _congelar_condiciones_y_handicaps_torneo_core_1861a;
    END IF;
END;
$do$;

-- El core de freeze sólo puede ser consumido por el wrapper SECURITY DEFINER.
-- Se evita exponer una vía que congele sin snapshot de clasificaciones.
REVOKE ALL ON FUNCTION
    public._congelar_condiciones_y_handicaps_torneo_core_1861a(uuid)
    FROM PUBLIC, anon, authenticated, service_role;

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
    v_classifications_json jsonb;
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

    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'tournamentCategoryId', s.tournament_category_id,
                'categoryId', s.category_id,
                'categoryCode', s.category_code,
                'categoryName', s.category_name,
                'categoryDisplayOrder', s.category_display_order,
                'resultType', s.tipo_resultado
            )
            ORDER BY
                s.category_display_order NULLS LAST,
                s.category_name,
                s.tipo_resultado
        ),
        '[]'::jsonb
    )
      INTO v_classifications_json
      FROM public.tournament_category_classification_snapshots s
     WHERE s.freeze_id = v_freeze_id;

    UPDATE public.tournament_condition_freezes f
       SET schema_version = GREATEST(f.schema_version, 2),
           conditions_snapshot =
               jsonb_set(
                   jsonb_set(
                       f.conditions_snapshot,
                       '{schemaVersion}',
                       to_jsonb(2),
                       true
                   ),
                   '{categoryClassifications}',
                   v_classifications_json,
                   true
               )
     WHERE f.id = v_freeze_id;

    RETURN
        v_result
        || jsonb_build_object(
            'schemaVersion', 2,
            'categoryClassificationSnapshots', v_snapshot_row_count
        );
END;
$function$;

REVOKE ALL ON FUNCTION public.congelar_condiciones_y_handicaps_torneo(uuid)
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.congelar_condiciones_y_handicaps_torneo(uuid)
    TO anon, authenticated, service_role;

COMMIT;

-- ============================================================================
-- FIN MIGRACIÓN 186 FASE 1A
-- ============================================================================
