-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 257
-- CAMPO DE GOLF COMO FUENTE DE VERDAD + RETIRO DE DURACION_DIAS
-- ============================================================================

BEGIN;

ALTER TABLE public.tournaments
    DROP COLUMN IF EXISTS duracion_dias;

CREATE OR REPLACE FUNCTION public.validar_campo_pertenece_al_club()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_club_del_campo uuid;
BEGIN
    IF NEW.campo_golf_id IS NULL THEN
        NEW.club_id := NULL;
        RETURN NEW;
    END IF;

    SELECT cg.club_id
      INTO v_club_del_campo
      FROM public.campos_golf cg
     WHERE cg.id = NEW.campo_golf_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El campo de golf seleccionado no existe.'
            USING ERRCODE = '23503';
    END IF;

    IF v_club_del_campo IS NULL THEN
        RAISE EXCEPTION
            'El campo de golf seleccionado no tiene un club asociado.'
            USING ERRCODE = '23514';
    END IF;

    NEW.club_id := v_club_del_campo;
    RETURN NEW;
END;
$function$;

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
    vr int;
    vra int;
    vc int;
    vsc int;
    suma bigint;
    e jsonb := '[]'::jsonb;
    f jsonb;
    v_club_del_campo uuid;
BEGIN
    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE='22023';
    END IF;

    SELECT count(*),
           count(*) FILTER(WHERE activo=true)
      INTO vr, vra
      FROM public.tournament_rounds
     WHERE tournament_id=p_tournament_id;

    SELECT count(*),
           count(*) FILTER(WHERE cupo_maximo IS NULL OR cupo_maximo<=0),
           COALESCE(sum(cupo_maximo),0)
      INTO vc, vsc, suma
      FROM public.tournament_categories
     WHERE tournament_id=p_tournament_id;

    IF v_t.campo_golf_id IS NULL THEN
        e := e || jsonb_build_array('Falta asignar campo de golf.');
    ELSE
        SELECT cg.club_id
          INTO v_club_del_campo
          FROM public.campos_golf cg
         WHERE cg.id = v_t.campo_golf_id;

        IF v_club_del_campo IS NULL THEN
            e := e || jsonb_build_array(
                'El campo de golf seleccionado no tiene un club asociado.'
            );
        ELSIF v_t.club_id IS DISTINCT FROM v_club_del_campo THEN
            e := e || jsonb_build_array(
                'El club del torneo no corresponde al club del campo de golf seleccionado.'
            );
        END IF;
    END IF;

    IF v_t.tournament_format_id IS NULL THEN
        e := e || jsonb_build_array(
            'Falta asignar modalidad/formato del torneo.'
        );
    END IF;

    IF v_t.cupo_maximo IS NULL OR v_t.cupo_maximo<=0 THEN
        e := e || jsonb_build_array(
            'El cupo máximo debe ser mayor que cero.'
        );
    END IF;

    IF v_t.numero_rondas IS NULL OR v_t.numero_rondas<=0 THEN
        e := e || jsonb_build_array(
            'El número de rondas debe ser mayor que cero.'
        );
    END IF;

    IF vra<>v_t.numero_rondas THEN
        e := e || jsonb_build_array(format(
            'Debe haber %s ronda(s) activa(s) configurada(s); actualmente hay %s.',
            v_t.numero_rondas, vra
        ));
    END IF;

    IF vc<=0 THEN
        e := e || jsonb_build_array(
            'El torneo no tiene categorías configuradas.'
        );
    ELSE
        IF vsc>0 THEN
            e := e || jsonb_build_array(format(
                'Todas las categorías deben tener un cupo máximo mayor que cero. Hay %s categoría(s) sin cupo válido.',
                vsc
            ));
        END IF;

        IF v_t.cupo_maximo IS NOT NULL
           AND v_t.cupo_maximo>0
           AND suma<>v_t.cupo_maximo
        THEN
            e := e || jsonb_build_array(format(
                'La suma de los cupos de las categorías (%s) debe ser igual al cupo máximo del torneo (%s).',
                suma, v_t.cupo_maximo
            ));
        END IF;
    END IF;

    f := public.validar_franjas_handicap_torneo(p_tournament_id);

    IF NOT COALESCE((f->>'valid')::boolean,false) THEN
        e := e || COALESCE(f->'errors','[]'::jsonb);
    END IF;

    RETURN QUERY
    SELECT jsonb_array_length(e)=0, e;
END;
$function$;

COMMENT ON COLUMN public.tournaments.campo_golf_id IS
'Campo base del torneo. Fuente de verdad para derivar automáticamente tournaments.club_id. Puede ser NULL durante el aprovisionamiento comercial.';

COMMENT ON COLUMN public.tournaments.club_id IS
'Club derivado automáticamente desde campos_golf.club_id cuando existe campo_golf_id. No debe capturarse independientemente.';

COMMIT;
