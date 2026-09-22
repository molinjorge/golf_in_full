-- TEE CENTRAL / GOLF IN FULL
-- Migración 348 CORREGIDA
-- Porcentaje de hándicap configurable a nivel torneo
-- EJECUCIÓN MANUAL EN SUPABASE
--
-- Corrección respecto del primer intento:
-- se conserva numeric(5,2), que es el tipo ya expuesto por
-- tournament_rounds_efectivo.handicap_allowance_efectivo.

BEGIN;

-- 1) Fuente de verdad opcional a nivel torneo.
-- NULL conserva el comportamiento histórico: usar el default de la modalidad.
ALTER TABLE public.tournaments
  ADD COLUMN IF NOT EXISTS handicap_allowance_pct numeric(5,2);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'tournaments_handicap_allowance_pct_check'
      AND conrelid = 'public.tournaments'::regclass
  ) THEN
    ALTER TABLE public.tournaments
      ADD CONSTRAINT tournaments_handicap_allowance_pct_check
      CHECK (
        handicap_allowance_pct IS NULL
        OR handicap_allowance_pct BETWEEN 0 AND 100
      );
  END IF;
END $$;

COMMENT ON COLUMN public.tournaments.handicap_allowance_pct IS
'Handicap Allowance opcional del torneo. Jerarquía efectiva: override de ronda -> torneo -> default de modalidad.';

-- 2) Vista efectiva.
-- IMPORTANTE: se preserva explícitamente numeric(5,2) para no cambiar
-- el contrato/tipo existente de handicap_allowance_efectivo.
CREATE OR REPLACE VIEW public.tournament_rounds_efectivo AS
SELECT
    tr.id,
    tr.tournament_id,
    tr.numero_ronda,
    tr.fecha,
    tr.campo_golf_id,
    COALESCE(tr.tournament_format_id, t.tournament_format_id)
        AS tournament_format_id_efectivo,
    tr.tournament_format_id IS NOT NULL AS modalidad_sobreescrita,
    COALESCE(
        tr.handicap_allowance_pct,
        t.handicap_allowance_pct,
        tf.handicap_allowance_default
    )::numeric(5,2) AS handicap_allowance_efectivo
FROM public.tournament_rounds tr
JOIN public.tournaments t
  ON t.id = tr.tournament_id
LEFT JOIN public.tournament_formats tf
  ON tf.id = COALESCE(tr.tournament_format_id, t.tournament_format_id);

-- 3) Actualizar las funciones que materializan directamente
-- la herencia de Handicap Allowance.
-- Se exige encontrar el patrón vigente; si alguna función no coincide,
-- se aborta toda la transacción.

DO $$
DECLARE
    v_name text;
    v_oid oid;
    v_def text;
    v_new text;
BEGIN
    FOREACH v_name IN ARRAY ARRAY[
        '_congelar_condiciones_y_handicaps_torneo_core_1861a',
        '_congelar_condiciones_y_handicaps_torneo_core_218',
        '_previsualizar_congelamiento_torneo_core_1861a',
        'obtener_estado_configuracion_rondas_263'
    ]
    LOOP
        v_oid := NULL;

        SELECT p.oid
          INTO v_oid
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname = v_name
           AND pg_get_function_identity_arguments(p.oid) = 'p_tournament_id uuid';

        IF v_oid IS NULL THEN
            RAISE EXCEPTION
              'Migración 348 abortada: no existe public.%(p_tournament_id uuid).',
              v_name;
        END IF;

        SELECT pg_get_functiondef(v_oid)
          INTO v_def;

        -- Variante compacta.
        v_new := replace(
            v_def,
            'COALESCE(tr.handicap_allowance_pct, tf.handicap_allowance_default)',
            'COALESCE(tr.handicap_allowance_pct, t.handicap_allowance_pct, tf.handicap_allowance_default)'
        );

        -- Variante multilínea.
        IF v_new = v_def THEN
            v_new := regexp_replace(
                v_def,
                'COALESCE\(\s*tr\.handicap_allowance_pct,\s*tf\.handicap_allowance_default\s*\)',
                'COALESCE(tr.handicap_allowance_pct, t.handicap_allowance_pct, tf.handicap_allowance_default)',
                'g'
            );
        END IF;

        IF v_new = v_def THEN
            RAISE EXCEPTION
              'Migración 348 abortada: no se encontró la fórmula esperada de Handicap Allowance en public.%.',
              v_name;
        END IF;

        EXECUTE v_new;
    END LOOP;
END $$;

COMMIT;
