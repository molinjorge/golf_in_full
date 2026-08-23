-- ============================================================================
-- 178_FASE2_FIX_CATEGORIA_ESTANDAR_MARCA_TEXT.sql
-- TEE CENTRAL / GOLF IN FULL
--
-- CORRECCIÓN DE MIGRACIÓN 178
-- Corrige incompatibilidad: helper devuelve enum categoria_marca_salida,
-- mientras la RPC pública declara categoria_estandar_marca text.
-- ============================================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_categorias_elegibles_jugador_inscripcion(
    p_tournament_id uuid,
    p_player_id uuid
)
RETURNS TABLE (
    tournament_category_id uuid,
    category_id uuid,
    nombre text,
    codigo text,
    genero text,
    edad_minima integer,
    edad_maxima integer,
    handicap_minimo numeric,
    handicap_maximo numeric,
    display_order integer,
    tipo_elegibilidad text,
    es_categoria_natural boolean,
    categoria_estandar_marca text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión para consultar categorías de inscripción.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(), p_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar las categorías elegibles de este torneo.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.tournaments t WHERE t.id = p_tournament_id) THEN
        RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.players p WHERE p.id = p_player_id) THEN
        RAISE EXCEPTION 'El jugador indicado no existe.' USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    SELECT
        e.tournament_category_id,
        e.category_id,
        e.nombre,
        e.codigo,
        e.genero,
        e.edad_minima,
        e.edad_maxima,
        e.handicap_minimo,
        e.handicap_maximo,
        e.display_order,
        e.tipo_elegibilidad,
        e.es_categoria_natural,
        e.categoria_estandar_marca::text
    FROM public._categorias_elegibles_jugador(p_tournament_id, p_player_id) e
    ORDER BY e.display_order NULLS LAST, e.nombre;
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_categorias_elegibles_jugador_inscripcion(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_categorias_elegibles_jugador_inscripcion(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_categorias_elegibles_jugador_inscripcion(uuid, uuid) TO authenticated;

COMMIT;
