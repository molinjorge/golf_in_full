-- 406-MIGRACION_EVIDENCIA_CONFIGURACION_DESEMPATES.sql
-- TEE CENTRAL
--
-- OBJETIVO
-- Hacer que el nodo descriptivo TIEBREAK_CONFIGURATION reconozca la
-- configuración de desempates realmente guardada en tournament_tiebreak_rules.
--
-- NO modifica el motor de desempates, sus reglas, autorizaciones ni bloqueos.
-- Sólo cambia la evidencia descriptiva usada por el evaluador 395.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_estado_configuracion_desempates_406(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_gross integer := 0;
    v_neto integer := 0;
    v_total integer := 0;
    v_complete boolean := false;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.tournaments t WHERE t.id=p_tournament_id
    ) THEN
        RAISE EXCEPTION 'Torneo no encontrado.'
            USING ERRCODE='P0002';
    END IF;

    SELECT
        count(*) FILTER (WHERE r.tipo_resultado='gross')::integer,
        count(*) FILTER (WHERE r.tipo_resultado='neto')::integer,
        count(*)::integer
      INTO v_gross,v_neto,v_total
      FROM public.tournament_tiebreak_rules r
     WHERE r.tournament_id=p_tournament_id
       AND r.activo=true;

    -- Evidencia descriptiva: existe una configuración activa para los
    -- dos tipos de resultado utilizados por la configuración global actual.
    v_complete := v_gross>0 AND v_neto>0;

    RETURN jsonb_build_object(
        'complete',v_complete,
        'activeRules',v_total,
        'grossActiveRules',v_gross,
        'netActiveRules',v_neto,
        'source','tournament_tiebreak_rules',
        'descriptiveOnly',true
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_estado_configuracion_desempates_406(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_estado_configuracion_desempates_406(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_estado_configuracion_desempates_406(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_estado_configuracion_desempates_406(uuid) TO service_role;

DO $do$
DECLARE
    v_def text;
    v_old text :=
        'v_complete := COALESCE((v_open->>''tiebreakReady'')::boolean,false);' ||
        E'\r\n        v_evidence := jsonb_build_object(''tiebreakReady'',v_complete);';
    v_new text :=
        'v_evidence := public.obtener_estado_configuracion_desempates_406(p_tournament_id);' ||
        E'\r\n        v_complete := COALESCE((v_evidence->>''complete'')::boolean,false);';
BEGIN
    SELECT pg_get_functiondef(p.oid)
      INTO v_def
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public'
       AND p.proname='obtener_workflow_evaluado_395'
       AND p.prokind='f';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No existe obtener_workflow_evaluado_395.';
    END IF;

    IF position(v_old in v_def)=0 THEN
        RAISE EXCEPTION
          'La definición actual del evaluador no contiene el bloque esperado de tiebreakReady. No se aplicó ningún cambio.';
    END IF;

    v_def := replace(v_def,v_old,v_new);

    IF position('obtener_estado_configuracion_desempates_406' in v_def)=0 THEN
        RAISE EXCEPTION 'No fue posible construir la nueva definición del evaluador.';
    END IF;

    EXECUTE v_def;
END
$do$;

COMMENT ON FUNCTION public.obtener_estado_configuracion_desempates_406(uuid)
IS '406: evidencia descriptiva del nodo Configurar desempates basada en reglas activas realmente guardadas; no modifica el motor.';

COMMIT;
