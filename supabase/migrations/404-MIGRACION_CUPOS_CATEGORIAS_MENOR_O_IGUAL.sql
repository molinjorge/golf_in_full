-- 404-MIGRACION_CUPOS_CATEGORIAS_MENOR_O_IGUAL.sql
-- TEE CENTRAL
--
-- Nueva regla:
--   SUM(cupos de categorías) <= cupo total del torneo.
--
-- Es válido dejar lugares todavía sin distribuir entre categorías.
-- Sólo se bloquea cuando las categorías asignan MÁS lugares que el cupo total.
--
-- Ajusta exclusivamente las validaciones introducidas por 402 y 403.
-- No modifica motores deportivos, Freeze, inscripción ni reglas competitivas.

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
    IF NEW.cupo_maximo IS NOT DISTINCT FROM OLD.cupo_maximo THEN
        RETURN NEW;
    END IF;

    SELECT
        count(*)::integer,
        count(*) FILTER (WHERE tc.cupo_maximo IS NULL OR tc.cupo_maximo <= 0)::integer,
        COALESCE(sum(tc.cupo_maximo),0)::integer
      INTO v_categorias, v_invalidas, v_suma
      FROM public.tournament_categories tc
     WHERE tc.tournament_id = OLD.id;

    IF v_categorias = 0 THEN
        RETURN NEW;
    END IF;

    IF v_invalidas > 0 THEN
        RAISE EXCEPTION
            'No se puede cambiar el cupo total porque existen categorías sin un cupo válido.'
            USING ERRCODE='23514', DETAIL='CATEGORY_CAPACITY_INVALID';
    END IF;

    IF NEW.cupo_maximo IS NULL OR NEW.cupo_maximo <= 0 THEN
        RAISE EXCEPTION 'El cupo total del torneo debe ser mayor a cero.'
            USING ERRCODE='23514', DETAIL='TOURNAMENT_CAPACITY_INVALID';
    END IF;

    -- 404: sólo es inválido comprometer más lugares que el cupo total.
    IF v_suma > NEW.cupo_maximo THEN
        RAISE EXCEPTION
            'No se puede guardar el cupo total en % porque las categorías suman %. Hay % lugares asignados de más entre las categorías.',
            NEW.cupo_maximo, v_suma, v_suma - NEW.cupo_maximo
            USING ERRCODE='23514',
                  DETAIL='CATEGORY_CAPACITY_TOTAL_EXCEEDED',
                  HINT='Reduce primero los cupos de categorías o guarda la configuración conjunta mediante guardar_configuracion_cupos_categorias_402.';
    END IF;

    RETURN NEW;
END;
$function$;


CREATE OR REPLACE FUNCTION public.guardar_configuracion_cupos_categorias_402(
    p_tournament_id uuid,
    p_categorias jsonb,
    p_cupo_total integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_cupo_actual integer;
    v_cupo_objetivo integer;
    v_suma_cupos integer;
    v_sin_asignar integer;
    v_cantidad integer;
    v_distintas integer;
    v_invalidas integer;
    v_hcp_invalidos integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para administrar la configuración de este torneo.'
            USING ERRCODE='42501';
    END IF;

    SELECT t.cupo_maximo
      INTO v_cupo_actual
      FROM public.tournaments t
     WHERE t.id=p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='P0002';
    END IF;

    IF p_categorias IS NULL
       OR jsonb_typeof(p_categorias) <> 'array'
       OR jsonb_array_length(p_categorias)=0 THEN
        RAISE EXCEPTION 'Debes configurar al menos una categoría.'
            USING ERRCODE='23514', DETAIL='CATEGORY_CONFIGURATION_EMPTY';
    END IF;

    v_cupo_objetivo := COALESCE(p_cupo_total,v_cupo_actual);

    IF v_cupo_objetivo IS NULL OR v_cupo_objetivo <= 0 THEN
        RAISE EXCEPTION 'El cupo total del torneo debe ser mayor a cero.'
            USING ERRCODE='23514', DETAIL='TOURNAMENT_CAPACITY_INVALID';
    END IF;

    WITH x AS (
        SELECT
            NULLIF(e->>'category_id','')::uuid AS category_id,
            CASE WHEN (e ? 'cupo_maximo') AND jsonb_typeof(e->'cupo_maximo')='number'
                 THEN (e->>'cupo_maximo')::numeric ELSE NULL END AS cupo_num,
            CASE WHEN NULLIF(e->>'handicap_minimo','') IS NULL
                 THEN NULL ELSE (e->>'handicap_minimo')::numeric END AS hmin,
            CASE WHEN NULLIF(e->>'handicap_maximo','') IS NULL
                 THEN NULL ELSE (e->>'handicap_maximo')::numeric END AS hmax
        FROM jsonb_array_elements(p_categorias) e
    )
    SELECT
        count(*)::integer,
        count(DISTINCT category_id)::integer,
        count(*) FILTER (
            WHERE category_id IS NULL OR cupo_num IS NULL OR cupo_num <= 0
               OR cupo_num <> trunc(cupo_num) OR cupo_num > 2147483647
        )::integer,
        count(*) FILTER (WHERE hmin IS NOT NULL AND hmax IS NOT NULL AND hmin > hmax)::integer,
        COALESCE(sum(cupo_num) FILTER (
            WHERE cupo_num IS NOT NULL AND cupo_num > 0
              AND cupo_num=trunc(cupo_num) AND cupo_num <= 2147483647
        ),0)::integer
      INTO v_cantidad,v_distintas,v_invalidas,v_hcp_invalidos,v_suma_cupos
      FROM x;

    IF v_distintas <> v_cantidad THEN
        RAISE EXCEPTION 'No puede repetirse una categoría en la configuración.'
            USING ERRCODE='23514', DETAIL='DUPLICATE_CATEGORY';
    END IF;

    IF v_invalidas > 0 THEN
        RAISE EXCEPTION 'Todas las categorías deben tener un cupo entero mayor a cero.'
            USING ERRCODE='23514', DETAIL='CATEGORY_CAPACITY_INVALID';
    END IF;

    IF v_hcp_invalidos > 0 THEN
        RAISE EXCEPTION 'El hándicap mínimo no puede ser mayor que el máximo.'
            USING ERRCODE='23514', DETAIL='HANDICAP_RANGE_INVALID';
    END IF;

    -- 404: puede haber lugares sin asignar. Sólo se rechaza el excedente.
    IF v_suma_cupos > v_cupo_objetivo THEN
        RAISE EXCEPTION
            'Los cupos de las categorías suman % jugadores y el cupo del torneo es %. Hay % lugares excedentes.',
            v_suma_cupos,v_cupo_objetivo,v_suma_cupos-v_cupo_objetivo
            USING ERRCODE='23514', DETAIL='CATEGORY_CAPACITY_TOTAL_EXCEEDED';
    END IF;

    v_sin_asignar := v_cupo_objetivo-v_suma_cupos;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_categorias) e
        LEFT JOIN public.categories c ON c.id=(e->>'category_id')::uuid
        WHERE c.id IS NULL
    ) THEN
        RAISE EXCEPTION 'Una o más categorías indicadas no existen.'
            USING ERRCODE='23503', DETAIL='CATEGORY_NOT_FOUND';
    END IF;

    -- IMPORTANTE: para cambios conjuntos, primero ajustamos categorías y después
    -- el cupo total. Así el trigger 403 ve ya la distribución objetivo.
    DELETE FROM public.tournament_categories tc
     WHERE tc.tournament_id=p_tournament_id
       AND NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(p_categorias) e
           WHERE (e->>'category_id')::uuid=tc.category_id
       );

    UPDATE public.tournament_categories tc
       SET cupo_maximo=x.cupo_maximo,
           handicap_minimo=x.handicap_minimo,
           handicap_maximo=x.handicap_maximo
      FROM (
        SELECT
          (e->>'category_id')::uuid category_id,
          (e->>'cupo_maximo')::integer cupo_maximo,
          CASE WHEN NULLIF(e->>'handicap_minimo','') IS NULL THEN NULL
               ELSE (e->>'handicap_minimo')::numeric END handicap_minimo,
          CASE WHEN NULLIF(e->>'handicap_maximo','') IS NULL THEN NULL
               ELSE (e->>'handicap_maximo')::numeric END handicap_maximo
        FROM jsonb_array_elements(p_categorias) e
      ) x
     WHERE tc.tournament_id=p_tournament_id
       AND tc.category_id=x.category_id
       AND (
          tc.cupo_maximo IS DISTINCT FROM x.cupo_maximo OR
          tc.handicap_minimo IS DISTINCT FROM x.handicap_minimo OR
          tc.handicap_maximo IS DISTINCT FROM x.handicap_maximo
       );

    INSERT INTO public.tournament_categories(
        tournament_id,category_id,cupo_maximo,handicap_minimo,handicap_maximo
    )
    SELECT p_tournament_id,x.category_id,x.cupo_maximo,x.handicap_minimo,x.handicap_maximo
    FROM (
        SELECT
          (e->>'category_id')::uuid category_id,
          (e->>'cupo_maximo')::integer cupo_maximo,
          CASE WHEN NULLIF(e->>'handicap_minimo','') IS NULL THEN NULL
               ELSE (e->>'handicap_minimo')::numeric END handicap_minimo,
          CASE WHEN NULLIF(e->>'handicap_maximo','') IS NULL THEN NULL
               ELSE (e->>'handicap_maximo')::numeric END handicap_maximo
        FROM jsonb_array_elements(p_categorias) e
    ) x
    WHERE NOT EXISTS (
        SELECT 1 FROM public.tournament_categories tc
        WHERE tc.tournament_id=p_tournament_id AND tc.category_id=x.category_id
    );

    IF v_cupo_actual IS DISTINCT FROM v_cupo_objetivo THEN
        UPDATE public.tournaments
           SET cupo_maximo=v_cupo_objetivo
         WHERE id=p_tournament_id;
    END IF;

    RETURN jsonb_build_object(
        'ok',true,
        'tournamentId',p_tournament_id,
        'cupoTotal',v_cupo_objetivo,
        'categorias',v_cantidad,
        'sumaCupos',v_suma_cupos,
        'sinAsignar',v_sin_asignar,
        'cuadraExacto',v_sin_asignar=0,
        'atomic',true
    );
END;
$function$;

-- Mantener privilegios restrictivos de 402.
REVOKE ALL ON FUNCTION public.guardar_configuracion_cupos_categorias_402(uuid,jsonb,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.guardar_configuracion_cupos_categorias_402(uuid,jsonb,integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.guardar_configuracion_cupos_categorias_402(uuid,jsonb,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.guardar_configuracion_cupos_categorias_402(uuid,jsonb,integer) TO service_role;

COMMENT ON FUNCTION public.guardar_configuracion_cupos_categorias_402(uuid,jsonb,integer)
IS '404 sobre RPC 402: guardado atómico; suma de cupos de categorías puede ser menor o igual al cupo total; sólo bloquea excedentes.';

COMMENT ON FUNCTION public._proteger_cupo_total_categorias_403()
IS '404 sobre guard 403: permite cupo total mayor o igual a la suma de categorías; bloquea únicamente si el total queda por debajo de los cupos asignados.';

COMMIT;
