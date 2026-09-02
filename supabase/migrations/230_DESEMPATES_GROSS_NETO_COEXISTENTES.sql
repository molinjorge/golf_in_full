-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 230 — DESEMPATES GROSS + NETO COEXISTENTES
--
-- Objetivo:
-- 1) Permitir reglas activas de desempate Gross y Neto simultáneamente
--    para el mismo torneo/categoría/alcance/orden.
-- 2) Evitar que aplicar una secuencia Neto desactive Gross, o viceversa.
-- 3) Mantener el enum tipo_resultado_desempate con sólo 'gross' y 'neto'.
-- 4) Cerrar ejecución anónima de la RPC y exigir permiso administrativo.
--
-- IMPORTANTE:
-- - No crea un valor 'gross_y_neto'.
-- - No cambia motores Stroke Play, Stableford ni A-Go-Go.
-- - No modifica resultados ni resoluciones históricas.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Unicidad activa por clasificación competitiva
-- -----------------------------------------------------------------------------
-- Antes, tipo_resultado no formaba parte de la llave y Gross/Neto chocaban.

DROP INDEX IF EXISTS public.tournament_tiebreak_rules_unico_activo;

CREATE UNIQUE INDEX tournament_tiebreak_rules_unico_activo
    ON public.tournament_tiebreak_rules (
        tournament_id,
        COALESCE(
            tournament_category_id,
            '00000000-0000-0000-0000-000000000000'::uuid
        ),
        alcance,
        tipo_resultado,
        orden
    )
    WHERE activo = true;

-- -----------------------------------------------------------------------------
-- 2. Aplicación de secuencia aislada por Gross/Neto
-- -----------------------------------------------------------------------------
-- La RPC conserva su firma pública. Ahora sólo sustituye reglas del mismo
-- tipo_resultado y valida autorización administrativa del torneo.

CREATE OR REPLACE FUNCTION public.aplicar_secuencia_desempate(
    p_tournament_id uuid,
    p_alcance public.alcance_desempate,
    p_secuencia_id uuid,
    p_tournament_category_id uuid DEFAULT NULL::uuid,
    p_tipo_resultado public.tipo_resultado_desempate DEFAULT 'neto'::public.tipo_resultado_desempate
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para configurar desempates de este torneo.'
            USING ERRCODE = '42501';
    END IF;

    UPDATE public.tournament_tiebreak_rules
       SET activo = false,
           fecha_baja = now(),
           motivo_baja = 'Reemplazada al aplicar una nueva plantilla de secuencia'
     WHERE tournament_id = p_tournament_id
       AND alcance = p_alcance
       AND COALESCE(
               tournament_category_id,
               '00000000-0000-0000-0000-000000000000'::uuid
           ) = COALESCE(
               p_tournament_category_id,
               '00000000-0000-0000-0000-000000000000'::uuid
           )
       AND tipo_resultado = p_tipo_resultado
       AND activo = true;

    INSERT INTO public.tournament_tiebreak_rules (
        tournament_id,
        alcance,
        orden,
        tiebreak_method_id,
        tournament_category_id,
        tipo_resultado
    )
    SELECT
        p_tournament_id,
        p_alcance,
        sp.orden,
        sp.tiebreak_method_id,
        p_tournament_category_id,
        p_tipo_resultado
    FROM public.secuencia_desempate_pasos sp
    WHERE sp.secuencia_id = p_secuencia_id
    ORDER BY sp.orden;
END;
$function$;

-- -----------------------------------------------------------------------------
-- 3. Seguridad de ejecución
-- -----------------------------------------------------------------------------
-- La función es SECURITY DEFINER: no debe quedar ejecutable por PUBLIC/anon.

REVOKE EXECUTE ON FUNCTION public.aplicar_secuencia_desempate(
    uuid,
    public.alcance_desempate,
    uuid,
    uuid,
    public.tipo_resultado_desempate
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.aplicar_secuencia_desempate(
    uuid,
    public.alcance_desempate,
    uuid,
    uuid,
    public.tipo_resultado_desempate
) FROM anon;

GRANT EXECUTE ON FUNCTION public.aplicar_secuencia_desempate(
    uuid,
    public.alcance_desempate,
    uuid,
    uuid,
    public.tipo_resultado_desempate
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.aplicar_secuencia_desempate(
    uuid,
    public.alcance_desempate,
    uuid,
    uuid,
    public.tipo_resultado_desempate
) TO service_role;

COMMIT;
