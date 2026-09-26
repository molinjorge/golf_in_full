-- 407-MIGRACION_CATEGORIAS_COMPLETAS_Y_CUPOS_APERTURA.sql
-- TEE CENTRAL
--
-- OBJETIVOS
-- 1) Considerar completa la fase HANDICAP_RANGES sólo cuando:
--    - las franjas HCP sean válidas; y
--    - TODAS las categorías tengan clasificación competitiva GROSS/NET/BOTH.
-- 2) Alinear la validación de apertura con la regla vigente:
--    suma de cupos de categorías <= cupo máximo del torneo.
--
-- NO cambia motores deportivos, Freeze, métodos de desempate ni autorizaciones.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_estado_categorias_configuradas_407(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_hcp jsonb;
    v_total integer := 0;
    v_configured integer := 0;
    v_unconfigured jsonb := '[]'::jsonb;
    v_complete boolean := false;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.tournaments WHERE id=p_tournament_id) THEN
        RAISE EXCEPTION 'Torneo no encontrado.' USING ERRCODE='P0002';
    END IF;

    v_hcp := public.validar_franjas_handicap_torneo(p_tournament_id);

    SELECT count(*)::integer
      INTO v_total
      FROM public.tournament_categories tc
     WHERE tc.tournament_id=p_tournament_id;

    SELECT count(*)::integer
      INTO v_configured
      FROM public.tournament_categories tc
     WHERE tc.tournament_id=p_tournament_id
       AND EXISTS (
           SELECT 1
             FROM public.tournament_category_classifications cc
            WHERE cc.tournament_id=p_tournament_id
              AND cc.tournament_category_id=tc.id
              AND cc.tipo_resultado IN (
                  'gross'::public.tipo_resultado_desempate,
                  'neto'::public.tipo_resultado_desempate
              )
       );

    SELECT COALESCE(
        jsonb_agg(jsonb_build_object(
            'tournamentCategoryId',tc.id,
            'categoryId',c.id,
            'categoryName',c.nombre
        ) ORDER BY c.display_order NULLS LAST,c.nombre,tc.id),
        '[]'::jsonb
    )
      INTO v_unconfigured
      FROM public.tournament_categories tc
      JOIN public.categories c ON c.id=tc.category_id
     WHERE tc.tournament_id=p_tournament_id
       AND NOT EXISTS (
           SELECT 1
             FROM public.tournament_category_classifications cc
            WHERE cc.tournament_id=p_tournament_id
              AND cc.tournament_category_id=tc.id
              AND cc.tipo_resultado IN (
                  'gross'::public.tipo_resultado_desempate,
                  'neto'::public.tipo_resultado_desempate
              )
       );

    v_complete :=
        COALESCE((v_hcp->>'valid')::boolean,false)
        AND v_total>0
        AND v_configured=v_total;

    RETURN jsonb_build_object(
        'complete',v_complete,
        'handicapRangesReady',COALESCE((v_hcp->>'valid')::boolean,false),
        'handicapRanges',v_hcp,
        'totalCategories',v_total,
        'configuredClassifications',v_configured,
        'unconfiguredClassifications',v_unconfigured,
        'allClassificationsConfigured',(v_total>0 AND v_configured=v_total),
        'descriptiveOnly',true
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_estado_categorias_configuradas_407(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_estado_categorias_configuradas_407(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_estado_categorias_configuradas_407(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_estado_categorias_configuradas_407(uuid) TO service_role;

-- Alinear la validación mínima con la regla de cupos vigente.
CREATE OR REPLACE FUNCTION public.validar_configuracion_minima_torneo(p_tournament_id uuid)
RETURNS TABLE(listo boolean, errores jsonb)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
    vr int; vra int; vc int; vsc int; suma bigint;
    e jsonb := '[]'::jsonb;
    f jsonb;
    v_club_del_campo uuid;
BEGIN
    SELECT * INTO v_t FROM public.tournaments WHERE id=p_tournament_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='22023';
    END IF;

    SELECT count(*),count(*) FILTER(WHERE activo=true)
      INTO vr,vra
      FROM public.tournament_rounds
     WHERE tournament_id=p_tournament_id;

    SELECT count(*),
           count(*) FILTER(WHERE cupo_maximo IS NULL OR cupo_maximo<=0),
           COALESCE(sum(cupo_maximo),0)
      INTO vc,vsc,suma
      FROM public.tournament_categories
     WHERE tournament_id=p_tournament_id;

    IF v_t.campo_golf_id IS NULL THEN
        e:=e||jsonb_build_array('Falta asignar campo de golf.');
    ELSE
        SELECT cg.club_id INTO v_club_del_campo
          FROM public.campos_golf cg WHERE cg.id=v_t.campo_golf_id;
        IF v_club_del_campo IS NULL THEN
            e:=e||jsonb_build_array('El campo de golf seleccionado no tiene un club asociado.');
        ELSIF v_t.club_id IS DISTINCT FROM v_club_del_campo THEN
            e:=e||jsonb_build_array('El club del torneo no corresponde al club del campo de golf seleccionado.');
        END IF;
    END IF;

    IF v_t.tournament_format_id IS NULL THEN
        e:=e||jsonb_build_array('Falta asignar modalidad/formato del torneo.');
    END IF;
    IF v_t.cupo_maximo IS NULL OR v_t.cupo_maximo<=0 THEN
        e:=e||jsonb_build_array('El cupo máximo debe ser mayor que cero.');
    END IF;
    IF v_t.numero_rondas IS NULL OR v_t.numero_rondas<=0 THEN
        e:=e||jsonb_build_array('El número de rondas debe ser mayor que cero.');
    END IF;
    IF vra<>v_t.numero_rondas THEN
        e:=e||jsonb_build_array(format(
            'Debe haber %s ronda(s) activa(s) configurada(s); actualmente hay %s.',
            v_t.numero_rondas,vra));
    END IF;

    IF vc<=0 THEN
        e:=e||jsonb_build_array('El torneo no tiene categorías configuradas.');
    ELSE
        IF vsc>0 THEN
            e:=e||jsonb_build_array(format(
              'Todas las categorías deben tener un cupo máximo mayor que cero. Hay %s categoría(s) sin cupo válido.',vsc));
        END IF;

        -- 407: sólo es inválido si las categorías EXCEDEN el cupo total.
        IF v_t.cupo_maximo IS NOT NULL
           AND v_t.cupo_maximo>0
           AND suma>v_t.cupo_maximo
        THEN
            e:=e||jsonb_build_array(format(
              'La suma de los cupos de las categorías (%s) no puede exceder el cupo máximo del torneo (%s).',
              suma,v_t.cupo_maximo));
        END IF;
    END IF;

    f:=public.validar_franjas_handicap_torneo(p_tournament_id);
    IF NOT COALESCE((f->>'valid')::boolean,false) THEN
        e:=e||COALESCE(f->'errors','[]'::jsonb);
    END IF;

    RETURN QUERY SELECT jsonb_array_length(e)=0,e;
END;
$function$;

-- Alinear baseConfigurationReady de la apertura con suma <= cupo.
-- Se conserva íntegramente la lógica restante de la función 379.
DO $do$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(p.oid)
      INTO v_def
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public'
       AND p.proname='_estado_apertura_inscripciones_379';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No existe _estado_apertura_inscripciones_379.';
    END IF;

    IF position('v_category_capacity=v_t.cupo_maximo' in v_def)=0 THEN
        RAISE EXCEPTION 'No se encontró la comparación de cupos esperada. No se aplicó el cambio.';
    END IF;

    v_def:=replace(
        v_def,
        'v_category_capacity=v_t.cupo_maximo',
        'v_category_capacity<=v_t.cupo_maximo'
    );
    EXECUTE v_def;
END
$do$;

-- El nodo HANDICAP_RANGES del evaluador exige ahora franjas + clasificación
-- competitiva de todas las categorías.
DO $do$
DECLARE
    v_def text;
    v_old text :=
      'v_complete := COALESCE((v_open->>''handicapRangesReady'')::boolean,false);' ||
      E'\r\n        v_evidence := jsonb_build_object(''handicapRangesReady'',v_complete);';
    v_new text :=
      'v_evidence := public.obtener_estado_categorias_configuradas_407(p_tournament_id);' ||
      E'\r\n        v_complete := COALESCE((v_evidence->>''complete'')::boolean,false);';
BEGIN
    SELECT pg_get_functiondef(p.oid)
      INTO v_def
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public'
       AND p.proname='obtener_workflow_evaluado_395';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No existe obtener_workflow_evaluado_395.';
    END IF;
    IF position(v_old in v_def)=0 THEN
        RAISE EXCEPTION 'No se encontró el bloque HANDICAP_RANGES esperado. No se aplicó el cambio.';
    END IF;

    v_def:=replace(v_def,v_old,v_new);
    EXECUTE v_def;
END
$do$;

COMMIT;
