-- ============================================================================
-- MIGRACION 185 FASE 1C
-- SOPORTE DE tournament_tee_time_groups EN EL GUARD GENERICO DE SALIDAS
-- TEE CENTRAL
--
-- DIAGNOSTICO CONFIRMADO
-- Al materializar Tee Times:
--   materializar_conformacion_tee_times(...)
--     -> INSERT tournament_tee_time_groups
--     -> trigger trg_proteger_cierre_salidas_tee_times
--     -> _proteger_objeto_salida_ronda_validada()
--     -> _resolver_ronda_fila_salida(TG_TABLE_NAME, NEW)
--
-- _resolver_ronda_fila_salida() no reconocía:
--   tournament_tee_time_groups
--
-- y levantaba:
--   "Tabla de salida no soportada: tournament_tee_time_groups."
--
-- OBJETIVO
-- Agregar únicamente la resolución de ronda para tournament_tee_time_groups,
-- reutilizando su tournament_group_id -> tournament_groups
-- -> tournament_round_shifts -> tournament_round_id.
--
-- NO CAMBIA
-- - materialización;
-- - validación Tee Times;
-- - Shotgun;
-- - datos;
-- - RLS;
-- - estructura de tablas.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._resolver_ronda_fila_salida(
    p_table_name text,
    p_row jsonb
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id uuid;
BEGIN
    IF p_row IS NULL THEN
        RETURN NULL;
    END IF;

    CASE p_table_name
        WHEN 'tournament_round_shifts' THEN
            RETURN nullif(p_row->>'tournament_round_id', '')::uuid;

        WHEN 'tournament_round_shift_categories' THEN
            SELECT rs.tournament_round_id
              INTO v_id
              FROM public.tournament_round_shifts rs
             WHERE rs.id = nullif(
                 p_row->>'tournament_round_shift_id', ''
             )::uuid;
            RETURN v_id;

        WHEN 'tournament_shotgun_category_configs' THEN
            SELECT rs.tournament_round_id
              INTO v_id
              FROM public.tournament_round_shift_categories sc
              JOIN public.tournament_round_shifts rs
                ON rs.id = sc.tournament_round_shift_id
             WHERE sc.id = nullif(
                 p_row->>'tournament_round_shift_category_id', ''
             )::uuid;
            RETURN v_id;

        WHEN 'tournament_shotgun_category_holes' THEN
            SELECT rs.tournament_round_id
              INTO v_id
              FROM public.tournament_shotgun_category_configs cfg
              JOIN public.tournament_round_shift_categories sc
                ON sc.id = cfg.tournament_round_shift_category_id
              JOIN public.tournament_round_shifts rs
                ON rs.id = sc.tournament_round_shift_id
             WHERE cfg.id = nullif(
                 p_row->>'tournament_shotgun_category_config_id', ''
             )::uuid;
            RETURN v_id;

        WHEN 'tournament_groups' THEN
            SELECT rs.tournament_round_id
              INTO v_id
              FROM public.tournament_round_shifts rs
             WHERE rs.id = nullif(
                 p_row->>'tournament_round_shift_id', ''
             )::uuid;
            RETURN v_id;

        WHEN 'tournament_group_players' THEN
            SELECT rs.tournament_round_id
              INTO v_id
              FROM public.tournament_groups g
              JOIN public.tournament_round_shifts rs
                ON rs.id = g.tournament_round_shift_id
             WHERE g.id = nullif(
                 p_row->>'tournament_group_id', ''
             )::uuid;
            RETURN v_id;

        WHEN 'tournament_group_teams' THEN
            SELECT rs.tournament_round_id
              INTO v_id
              FROM public.tournament_groups g
              JOIN public.tournament_round_shifts rs
                ON rs.id = g.tournament_round_shift_id
             WHERE g.id = nullif(
                 p_row->>'tournament_group_id', ''
             )::uuid;
            RETURN v_id;

        WHEN 'tournament_tee_time_groups' THEN
            SELECT rs.tournament_round_id
              INTO v_id
              FROM public.tournament_groups g
              JOIN public.tournament_round_shifts rs
                ON rs.id = g.tournament_round_shift_id
             WHERE g.id = nullif(
                 p_row->>'tournament_group_id', ''
             )::uuid;
            RETURN v_id;

        ELSE
            RAISE EXCEPTION
                'Tabla de salida no soportada: %.',
                p_table_name
                USING ERRCODE = '22023';
    END CASE;
END;
$function$;

REVOKE ALL
ON FUNCTION public._resolver_ronda_fila_salida(text, jsonb)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._resolver_ronda_fila_salida(text, jsonb)
TO service_role;

COMMIT;
