-- 403-MIGRACION_BLINDAJE_CUPO_TOTAL_CATEGORIAS.sql
-- TEE CENTRAL
--
-- Objetivo:
--   Impedir que un UPDATE directo a tournaments.cupo_maximo deje descuadrado
--   el cupo total respecto de las categorías ya configuradas.
--
-- Regla:
--   Si el torneo ya tiene categorías, un cambio AISLADO de cupo_maximo sólo
--   se acepta cuando el nuevo cupo coincide con SUM(tournament_categories.cupo_maximo).
--   Para cambiar cupo total + distribución simultáneamente debe usarse la RPC 402.
--
-- Importante:
--   NO corrige datos existentes.
--   NO modifica motores deportivos, congelamiento, inscripción ni reglas competitivas.
--   NO sustituye la RPC 402.

BEGIN;

CREATE OR REPLACE FUNCTION public._proteger_cupo_total_categorias_403()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_categorias integer;
    v_invalidas integer;
    v_suma integer;
BEGIN
    -- Sólo interesa un cambio real del cupo total.
    IF NEW.cupo_maximo IS NOT DISTINCT FROM OLD.cupo_maximo THEN
        RETURN NEW;
    END IF;

    SELECT
        count(*)::integer,
        count(*) FILTER (
            WHERE tc.cupo_maximo IS NULL OR tc.cupo_maximo <= 0
        )::integer,
        COALESCE(sum(tc.cupo_maximo),0)::integer
      INTO v_categorias, v_invalidas, v_suma
      FROM public.tournament_categories tc
     WHERE tc.tournament_id = OLD.id;

    -- Si todavía no existen categorías, no inventamos una restricción nueva.
    -- La configuración completa será validada al guardarse por la RPC 402.
    IF v_categorias = 0 THEN
        RETURN NEW;
    END IF;

    IF v_invalidas > 0 THEN
        RAISE EXCEPTION
            'No se puede cambiar el cupo total porque existen categorías sin un cupo válido. Corrige y guarda la configuración completa de categorías.'
            USING ERRCODE = '23514',
                  DETAIL = 'CATEGORY_CAPACITY_INVALID',
                  HINT = 'Utiliza guardar_configuracion_cupos_categorias_402 para guardar cupo total y categorías en una sola operación.';
    END IF;

    IF NEW.cupo_maximo IS NULL OR NEW.cupo_maximo <= 0 THEN
        RAISE EXCEPTION
            'El cupo total del torneo debe ser mayor a cero.'
            USING ERRCODE = '23514',
                  DETAIL = 'TOURNAMENT_CAPACITY_INVALID';
    END IF;

    IF NEW.cupo_maximo <> v_suma THEN
        IF NEW.cupo_maximo > v_suma THEN
            RAISE EXCEPTION
                'No se puede guardar el cupo total en % porque las categorías suman %. Faltan asignar % lugares entre las categorías.',
                NEW.cupo_maximo, v_suma, NEW.cupo_maximo - v_suma
                USING ERRCODE = '23514',
                      DETAIL = 'CATEGORY_CAPACITY_TOTAL_MISMATCH',
                      HINT = 'Modifica el cupo total y la distribución de categorías mediante guardar_configuracion_cupos_categorias_402.';
        ELSE
            RAISE EXCEPTION
                'No se puede guardar el cupo total en % porque las categorías suman %. Hay % lugares asignados de más entre las categorías.',
                NEW.cupo_maximo, v_suma, v_suma - NEW.cupo_maximo
                USING ERRCODE = '23514',
                      DETAIL = 'CATEGORY_CAPACITY_TOTAL_MISMATCH',
                      HINT = 'Modifica el cupo total y la distribución de categorías mediante guardar_configuracion_cupos_categorias_402.';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_proteger_cupo_total_categorias_403
ON public.tournaments;

CREATE TRIGGER trg_proteger_cupo_total_categorias_403
BEFORE UPDATE OF cupo_maximo
ON public.tournaments
FOR EACH ROW
EXECUTE FUNCTION public._proteger_cupo_total_categorias_403();

COMMENT ON FUNCTION public._proteger_cupo_total_categorias_403()
IS '403: impide cambios aislados de tournaments.cupo_maximo que descuadren categorías; los cambios conjuntos deben pasar por RPC 402.';

COMMIT;
