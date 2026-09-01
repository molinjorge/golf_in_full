-- ============================================================================
-- MIGRACIÓN 217 — L2 A-GOGO
-- Contrato completo de configuración HCP TEAM
-- Proyecto: Tee Central / GOLF IN FULL
--
-- OBJETIVO
-- 1) Permitir releer de forma segura la configuración HCP TEAM y sus rangos.
-- 2) Permitir reemplazar atómicamente la tabla completa de rangos.
-- 3) Limpiar rangos obsoletos cuando el método deja de ser ASSIGNED_TABLE_SUM_HI.
--
-- PRINCIPIOS
-- - No se abre SELECT directo a authenticated sobre tablas internas.
-- - Se reutiliza puede_administrar_congelamiento_torneo().
-- - Se preservan las RPC existentes.
-- - Los triggers de Migración 204 continúan invalidando HCP TEAM cuando cambia
--   configuración o rangos.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LECTURA SEGURA DE CONFIGURACIÓN HCP TEAM
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_configuracion_handicap_equipo_a_gogo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_config public.tournament_team_handicap_configs%ROWTYPE;
    v_participation text;
    v_engine text;
    v_ranges jsonb := '[]'::jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar la configuración de este torneo.'
            USING ERRCODE='42501';
    END IF;

    SELECT tf.tipo_participacion::text, tf.scoring_engine::text
      INTO v_participation, v_engine
      FROM public.tournaments t
      JOIN public.tournament_formats tf
        ON tf.id=t.tournament_format_id
     WHERE t.id=p_tournament_id
       AND t.activo=true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo no existe o no está activo.';
    END IF;

    IF v_participation IS DISTINCT FROM 'equipo'
       OR v_engine IS DISTINCT FROM 'team_stroke' THEN
        RAISE EXCEPTION
            'La configuración de HCP de equipo solo aplica a A-Go-Go/team_stroke.';
    END IF;

    SELECT *
      INTO v_config
      FROM public.tournament_team_handicap_configs
     WHERE tournament_id=p_tournament_id
       AND active=true;

    IF v_config.id IS NULL THEN
        RETURN jsonb_build_object(
            'configured', false,
            'tournamentId', p_tournament_id,
            'config', NULL,
            'ranges', '[]'::jsonb
        );
    END IF;

    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', r.id,
                'from', r.handicap_sum_from,
                'to', r.handicap_sum_to,
                'assignedTeamHandicap', r.assigned_team_handicap,
                'displayOrder', r.display_order
            )
            ORDER BY r.display_order, r.handicap_sum_from, r.id
        ),
        '[]'::jsonb
    )
      INTO v_ranges
      FROM public.tournament_team_handicap_ranges r
     WHERE r.config_id=v_config.id;

    RETURN jsonb_build_object(
        'configured', true,
        'tournamentId', p_tournament_id,
        'config', jsonb_build_object(
            'configId', v_config.id,
            'method', v_config.method,
            'averagePct', v_config.average_pct,
            'roundingMode', v_config.rounding_mode,
            'active', v_config.active
        ),
        'ranges', v_ranges
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_configuracion_handicap_equipo_a_gogo(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_configuracion_handicap_equipo_a_gogo(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_configuracion_handicap_equipo_a_gogo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_configuracion_handicap_equipo_a_gogo(uuid) TO service_role;


-- ----------------------------------------------------------------------------
-- 2. REEMPLAZO ATÓMICO DE RANGOS
--
-- Contrato p_ranges:
-- [
--   {
--     "from": 0,
--     "to": 40,
--     "assignedTeamHandicap": 5,
--     "displayOrder": 1
--   },
--   ...
-- ]
--
-- "to" puede ser null para último rango abierto.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reemplazar_rangos_handicap_equipo_a_gogo(
    p_config_id uuid,
    p_ranges jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_config public.tournament_team_handicap_configs%ROWTYPE;
    v_count integer := 0;
    v_ranges jsonb := COALESCE(p_ranges, '[]'::jsonb);
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_config
      FROM public.tournament_team_handicap_configs
     WHERE id=p_config_id
       AND active=true
     FOR UPDATE;

    IF v_config.id IS NULL THEN
        RAISE EXCEPTION 'La configuración no existe o no está activa.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_config.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para configurar este torneo.'
            USING ERRCODE='42501';
    END IF;

    IF v_config.method <> 'ASSIGNED_TABLE_SUM_HI' THEN
        RAISE EXCEPTION
            'Los rangos solo aplican al método ASSIGNED_TABLE_SUM_HI.';
    END IF;

    IF jsonb_typeof(v_ranges) <> 'array' THEN
        RAISE EXCEPTION 'p_ranges debe ser un arreglo JSON.';
    END IF;

    -- Validación de campos y límites.
    IF EXISTS (
        SELECT 1
          FROM jsonb_to_recordset(v_ranges)
               AS x(
                   "from" numeric,
                   "to" numeric,
                   "assignedTeamHandicap" numeric,
                   "displayOrder" integer
               )
         WHERE x."from" IS NULL
            OR x."assignedTeamHandicap" IS NULL
            OR (x."to" IS NOT NULL AND x."to" < x."from")
    ) THEN
        RAISE EXCEPTION
            'Cada rango requiere from y assignedTeamHandicap; to no puede ser menor que from.';
    END IF;

    -- No admitir traslapes dentro del conjunto nuevo.
    IF EXISTS (
        WITH input_ranges AS (
            SELECT
                row_number() OVER () AS rn,
                x."from" AS h_from,
                x."to" AS h_to
            FROM jsonb_to_recordset(v_ranges)
                 AS x(
                     "from" numeric,
                     "to" numeric,
                     "assignedTeamHandicap" numeric,
                     "displayOrder" integer
                 )
        )
        SELECT 1
          FROM input_ranges a
          JOIN input_ranges b
            ON a.rn < b.rn
           AND numrange(a.h_from, a.h_to, '[]')
               && numrange(b.h_from, b.h_to, '[]')
    ) THEN
        RAISE EXCEPTION 'Los rangos no pueden traslaparse.';
    END IF;

    -- Reemplazo total dentro de la misma transacción/RPC.
    DELETE FROM public.tournament_team_handicap_ranges
     WHERE config_id=p_config_id;

    INSERT INTO public.tournament_team_handicap_ranges(
        config_id,
        handicap_sum_from,
        handicap_sum_to,
        assigned_team_handicap,
        display_order
    )
    SELECT
        p_config_id,
        (e.obj->>'from')::numeric,
        NULLIF(e.obj->>'to','')::numeric,
        (e.obj->>'assignedTeamHandicap')::numeric,
        COALESCE(
            NULLIF(e.obj->>'displayOrder','')::integer,
            e.ordinality::integer - 1
        )
    FROM jsonb_array_elements(v_ranges) WITH ORDINALITY
         AS e(obj, ordinality);

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RETURN jsonb_build_object(
        'configId', p_config_id,
        'tournamentId', v_config.tournament_id,
        'replaced', true,
        'rangeCount', v_count,
        'ranges', (
            SELECT COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'id', r.id,
                        'from', r.handicap_sum_from,
                        'to', r.handicap_sum_to,
                        'assignedTeamHandicap', r.assigned_team_handicap,
                        'displayOrder', r.display_order
                    )
                    ORDER BY r.display_order, r.handicap_sum_from, r.id
                ),
                '[]'::jsonb
            )
            FROM public.tournament_team_handicap_ranges r
            WHERE r.config_id=p_config_id
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.reemplazar_rangos_handicap_equipo_a_gogo(uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reemplazar_rangos_handicap_equipo_a_gogo(uuid,jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.reemplazar_rangos_handicap_equipo_a_gogo(uuid,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reemplazar_rangos_handicap_equipo_a_gogo(uuid,jsonb) TO service_role;


-- ----------------------------------------------------------------------------
-- 3. AJUSTE DE LA RPC EXISTENTE DE CONFIGURACIÓN
--    - conserva su contrato
--    - limpia rangos si el método deja de ser ASSIGNED_TABLE_SUM_HI
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.configurar_handicap_equipo_a_gogo(
    p_tournament_id uuid,
    p_method text,
    p_average_pct numeric DEFAULT NULL::numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_admin_id uuid;
    v_participation text;
    v_engine text;
    v_config public.tournament_team_handicap_configs%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para configurar este torneo.'
            USING ERRCODE='42501';
    END IF;

    SELECT au.id INTO v_admin_id
    FROM public.admin_users au
    WHERE au.auth_user_id=auth.uid()
      AND au.activo
    ORDER BY au.id
    LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No existe administrador activo asociado.';
    END IF;

    SELECT tf.tipo_participacion::text, tf.scoring_engine::text
      INTO v_participation, v_engine
      FROM public.tournaments t
      JOIN public.tournament_formats tf
        ON tf.id=t.tournament_format_id
     WHERE t.id=p_tournament_id
       AND t.activo=true;

    IF v_participation IS DISTINCT FROM 'equipo'
       OR v_engine IS DISTINCT FROM 'team_stroke' THEN
        RAISE EXCEPTION
            'La configuración de HCP de equipo solo aplica a A-Go-Go/team_stroke.';
    END IF;

    IF p_method NOT IN (
        'GROSS_ONLY',
        'AVERAGE_HI_PCT',
        'ASSIGNED_TABLE_SUM_HI',
        'WHS_SCRAMBLE'
    ) THEN
        RAISE EXCEPTION 'Método de HCP de equipo no reconocido.';
    END IF;

    IF p_method='AVERAGE_HI_PCT'
       AND (p_average_pct IS NULL OR p_average_pct<0 OR p_average_pct>100) THEN
        RAISE EXCEPTION
            'AVERAGE_HI_PCT requiere porcentaje entre 0 y 100.';
    END IF;

    INSERT INTO public.tournament_team_handicap_configs(
        tournament_id,
        method,
        average_pct,
        created_by,
        updated_by
    )
    VALUES(
        p_tournament_id,
        p_method,
        CASE WHEN p_method='AVERAGE_HI_PCT'
             THEN p_average_pct ELSE NULL END,
        v_admin_id,
        v_admin_id
    )
    ON CONFLICT (tournament_id)
    DO UPDATE SET
        method=EXCLUDED.method,
        average_pct=EXCLUDED.average_pct,
        active=true,
        updated_by=v_admin_id,
        updated_at=now()
    RETURNING * INTO v_config;

    -- Los rangos son configuración exclusiva de ASSIGNED_TABLE_SUM_HI.
    -- Si se cambia de método, no deben permanecer rangos históricos activos
    -- que reaparezcan accidentalmente al volver al método por tabla.
    IF p_method <> 'ASSIGNED_TABLE_SUM_HI' THEN
        DELETE FROM public.tournament_team_handicap_ranges
         WHERE config_id=v_config.id;
    END IF;

    RETURN jsonb_build_object(
        'configId',v_config.id,
        'tournamentId',v_config.tournament_id,
        'method',v_config.method,
        'averagePct',v_config.average_pct,
        'active',v_config.active
    );
END;
$function$;

-- Preservar explícitamente el contrato de permisos de la RPC existente.
REVOKE ALL ON FUNCTION public.configurar_handicap_equipo_a_gogo(uuid,text,numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.configurar_handicap_equipo_a_gogo(uuid,text,numeric) FROM anon;
GRANT EXECUTE ON FUNCTION public.configurar_handicap_equipo_a_gogo(uuid,text,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.configurar_handicap_equipo_a_gogo(uuid,text,numeric) TO service_role;

COMMIT;
