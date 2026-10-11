-- 443-MIGRACION_ALINEAR_DESEMPATES_ASISTENTE.sql
-- TEE CENTRAL / GOLF IN FULL
-- Ejecución manual por el usuario.
BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_estado_configuracion_desempates_406(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_canonical jsonb;
    v_gross integer := 0;
    v_neto integer := 0;
    v_total integer := 0;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.tournaments t WHERE t.id=p_tournament_id) THEN
        RAISE EXCEPTION 'Torneo no encontrado.' USING ERRCODE='P0002';
    END IF;

    -- 261 es la autoridad canónica: deriva los tipos requeridos de las
    -- clasificaciones reales y valida secuencia R&A, faltantes y conflictos.
    v_canonical := public.obtener_estado_configuracion_desempates_261(p_tournament_id);

    SELECT
        count(*) FILTER (WHERE r.tipo_resultado='gross')::integer,
        count(*) FILTER (WHERE r.tipo_resultado='neto')::integer,
        count(*)::integer
      INTO v_gross,v_neto,v_total
      FROM public.tournament_tiebreak_rules r
     WHERE r.tournament_id=p_tournament_id AND r.activo=true;

    RETURN jsonb_build_object(
        'complete',COALESCE((v_canonical->>'complete')::boolean,false),
        'activeRules',v_total,
        'grossActiveRules',v_gross,
        'netActiveRules',v_neto,
        'source','obtener_estado_configuracion_desempates_261',
        'descriptiveOnly',true,
        'canonicalStatus',v_canonical->'status',
        'requiredResultTypes',COALESCE(v_canonical->'requiredResultTypes','[]'::jsonb),
        'configuredResultTypes',COALESCE(v_canonical->'configuredResultTypes','[]'::jsonb),
        'missingResultTypes',COALESCE(v_canonical->'missingResultTypes','[]'::jsonb),
        'invalidResultTypes',COALESCE(v_canonical->'invalidResultTypes','[]'::jsonb),
        'conflictingResultTypes',COALESCE(v_canonical->'conflictingResultTypes','[]'::jsonb)
    );
END;
$function$;

COMMENT ON FUNCTION public.obtener_estado_configuracion_desempates_406(uuid)
IS 'Evidencia descriptiva de desempates para workflow. Desde 443 delega la validez competitiva al validador canónico 261 y conserva contadores GROSS/NETO para diagnóstico.';

COMMIT;
