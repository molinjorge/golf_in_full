-- ============================================================================
-- MIGRACION 229
-- Corrección resolver_categoria_unica_equipo(): evitar min(uuid)
--
-- Hallazgo E2E:
-- Al crear un equipo desde inscripción grupal, el trigger
-- trg_resolver_categoria_unica_equipo ejecutaba min(tc.id) sobre UUID y
-- PostgreSQL respondía:
--
--   function min(uuid) does not exist
--
-- Alcance:
-- - Corrige únicamente resolver_categoria_unica_equipo().
-- - Conserva la semántica existente:
--     0 categorías  -> deja NULL.
--     1 categoría   -> asigna esa categoría al equipo.
--     >1 categorías -> exige selección explícita.
-- - No modifica tablas, datos, permisos, RPCs ni otros triggers.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.resolver_categoria_unica_equipo()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_num_categorias integer;
    v_categoria_id uuid;
BEGIN
    -- Si la categoría ya viene explícita, no modificarla.
    -- El trigger existente de pertenencia al torneo sigue validándola.
    IF NEW.tournament_category_id IS NOT NULL THEN
        RETURN NEW;
    END IF;

    -- Contar categorías sin aplicar agregados sobre UUID.
    SELECT count(*)
      INTO v_num_categorias
      FROM public.tournament_categories tc
     WHERE tc.tournament_id = NEW.tournament_id;

    -- Torneo legítimamente sin categorías.
    IF v_num_categorias = 0 THEN
        RETURN NEW;
    END IF;

    -- Categoría única: obtener directamente su UUID.
    IF v_num_categorias = 1 THEN
        SELECT tc.id
          INTO v_categoria_id
          FROM public.tournament_categories tc
         WHERE tc.tournament_id = NEW.tournament_id
         LIMIT 1;

        NEW.tournament_category_id := v_categoria_id;
        RETURN NEW;
    END IF;

    -- Multicategoría: nunca adivinar.
    RAISE EXCEPTION
        'El torneo tiene múltiples categorías. Debes seleccionar la categoría del equipo.';
END;
$function$;

COMMIT;
