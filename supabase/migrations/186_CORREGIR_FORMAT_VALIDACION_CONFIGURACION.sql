BEGIN;

CREATE OR REPLACE FUNCTION public.validar_configuracion_minima_torneo(
    p_tournament_id uuid
)
RETURNS TABLE(listo boolean, errores jsonb)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
    v_total_rondas integer;
    v_total_rondas_activas integer;
    v_total_categorias integer;
    v_categorias_sin_cupo integer;
    v_suma_cupos bigint;
    v_errores jsonb := '[]'::jsonb;
BEGIN
    SELECT * INTO v_t
    FROM public.tournaments
    WHERE id = p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*), count(*) FILTER (WHERE activo = true)
    INTO v_total_rondas, v_total_rondas_activas
    FROM public.tournament_rounds
    WHERE tournament_id = p_tournament_id;

    SELECT
        count(*),
        count(*) FILTER (WHERE cupo_maximo IS NULL OR cupo_maximo <= 0),
        COALESCE(sum(cupo_maximo), 0)
    INTO v_total_categorias, v_categorias_sin_cupo, v_suma_cupos
    FROM public.tournament_categories
    WHERE tournament_id = p_tournament_id;

    IF v_t.club_id IS NULL THEN
        v_errores := v_errores || jsonb_build_array('Falta asignar club.');
    END IF;

    IF v_t.campo_golf_id IS NULL THEN
        v_errores := v_errores || jsonb_build_array('Falta asignar campo de golf.');
    END IF;

    IF v_t.tournament_format_id IS NULL THEN
        v_errores := v_errores || jsonb_build_array('Falta asignar modalidad/formato del torneo.');
    END IF;

    IF v_t.cupo_maximo IS NULL OR v_t.cupo_maximo <= 0 THEN
        v_errores := v_errores || jsonb_build_array('El cupo máximo debe ser mayor que cero.');
    END IF;

    IF v_t.numero_rondas IS NULL OR v_t.numero_rondas <= 0 THEN
        v_errores := v_errores || jsonb_build_array('El número de rondas debe ser mayor que cero.');
    END IF;

    IF v_total_rondas_activas <> v_t.numero_rondas THEN
        v_errores := v_errores || jsonb_build_array(
            format(
                'Debe haber %s ronda(s) activa(s) configurada(s); actualmente hay %s.',
                v_t.numero_rondas,
                v_total_rondas_activas
            )
        );
    END IF;

    IF v_total_categorias <= 0 THEN
        v_errores := v_errores || jsonb_build_array('El torneo no tiene categorías configuradas.');
    ELSE
        IF v_categorias_sin_cupo > 0 THEN
            v_errores := v_errores || jsonb_build_array(
                format(
                    'Todas las categorías deben tener un cupo máximo mayor que cero. Hay %s categoría(s) sin cupo válido.',
                    v_categorias_sin_cupo
                )
            );
        END IF;

        IF v_t.cupo_maximo IS NOT NULL
           AND v_t.cupo_maximo > 0
           AND v_suma_cupos <> v_t.cupo_maximo
        THEN
            v_errores := v_errores || jsonb_build_array(
                format(
                    'La suma de los cupos de las categorías (%s) debe ser igual al cupo máximo del torneo (%s).',
                    v_suma_cupos,
                    v_t.cupo_maximo
                )
            );
        END IF;
    END IF;

    RETURN QUERY
    SELECT jsonb_array_length(v_errores) = 0, v_errores;
END;
$function$;

COMMIT;
