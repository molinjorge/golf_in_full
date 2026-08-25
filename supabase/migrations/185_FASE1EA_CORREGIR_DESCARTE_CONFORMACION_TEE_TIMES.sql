-- ============================================================================
-- MIGRACION 185 FASE 1E-A
-- CORRECCION DEL DESCARTE SEGURO DE CONFORMACION TEE TIMES
-- TEE CENTRAL
--
-- PROBLEMA
-- descartar_conformacion_tee_times(uuid,text) eliminaba:
--   1) tournament_group_players
--   2) tournament_tee_time_groups
--   3) tournament_groups
--
-- pero tournament_groups tiene el trigger:
--   trg_validar_borrado_grupo_vacio
-- que exige:
--   - grupo activo = false
--   - sin jugadores
--
-- Por tanto, antes del DELETE final hay que desactivar formalmente el grupo.
--
-- Esta migración NO cambia las precondiciones de seguridad del descarte.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.descartar_conformacion_tee_times(
    p_shift_config_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_round_id uuid;
    v_tournament_id uuid;
    v_admin_id uuid;
    v_group_ids uuid[];
    v_groups integer := 0;
    v_players integer := 0;
    v_metadata integer := 0;
    v_deactivated integer := 0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF length(btrim(COALESCE(p_reason, ''))) < 5 THEN
        RAISE EXCEPTION
            'El motivo de descarte debe contener al menos 5 caracteres.'
            USING ERRCODE = '22023';
    END IF;

    SELECT
        rs.tournament_round_id,
        tr.tournament_id
      INTO
        v_round_id,
        v_tournament_id
      FROM public.tournament_tee_time_shift_configs cfg
      JOIN public.tournament_round_shifts rs
        ON rs.id = cfg.tournament_round_shift_id
      JOIN public.tournament_rounds tr
        ON tr.id = rs.tournament_round_id
     WHERE cfg.id = p_shift_config_id
       AND cfg.activo
       AND tr.formato_salida =
           'tee_times'::public.formato_salida_ronda;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La configuración Tee Times indicada no existe o no está activa.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para descartar esta conformación Tee Times.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(v_round_id);

    IF public._salida_ronda_esta_validada(v_round_id) THEN
        RAISE EXCEPTION
            'Las salidas de la ronda están validadas y la conformación no puede descartarse.'
            USING ERRCODE = '55000',
                  HINT = 'Reabre formalmente la validación antes de cualquier cambio.';
    END IF;

    IF public._ronda_tiene_tarjetas_emitidas(v_round_id) THEN
        RAISE EXCEPTION
            'La ronda ya tiene tarjetas oficiales emitidas y la conformación no puede descartarse.'
            USING ERRCODE = '55000';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT array_agg(DISTINCT g.id)
      INTO v_group_ids
      FROM public.tournament_tee_time_groups ttg
      JOIN public.tournament_tee_time_shift_start_holes sh
        ON sh.id = ttg.tournament_tee_time_start_hole_id
      JOIN public.tournament_groups g
        ON g.id = ttg.tournament_group_id
     WHERE sh.tournament_tee_time_shift_config_id = p_shift_config_id;

    IF v_group_ids IS NULL OR cardinality(v_group_ids) = 0 THEN
        RETURN jsonb_build_object(
            'success', true,
            'discarded', false,
            'groupsDeactivated', 0,
            'groupsDeleted', 0,
            'playersDeleted', 0,
            'metadataDeleted', 0,
            'message', 'El turno no tiene conformación Tee Times persistida.'
        );
    END IF;

    -- 1. Primero quitar jugadores.
    DELETE FROM public.tournament_group_players gp
     WHERE gp.tournament_group_id = ANY(v_group_ids);
    GET DIAGNOSTICS v_players = ROW_COUNT;

    -- 2. Quitar metadata Tee Times.
    DELETE FROM public.tournament_tee_time_groups ttg
     WHERE ttg.tournament_group_id = ANY(v_group_ids);
    GET DIAGNOSTICS v_metadata = ROW_COUNT;

    -- 3. El trigger de borrado de tournament_groups exige inactivo.
    UPDATE public.tournament_groups g
       SET activo = false,
           fecha_baja = now(),
           dado_de_baja_por = v_admin_id,
           motivo_baja = btrim(p_reason)
     WHERE g.id = ANY(v_group_ids)
       AND g.activo = true;
    GET DIAGNOSTICS v_deactivated = ROW_COUNT;

    -- 4. Ya inactivos y sin jugadores: ahora sí pueden eliminarse.
    DELETE FROM public.tournament_groups g
     WHERE g.id = ANY(v_group_ids);
    GET DIAGNOSTICS v_groups = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'discarded', true,
        'roundId', v_round_id,
        'shiftConfigId', p_shift_config_id,
        'reason', btrim(p_reason),
        'groupsDeactivated', v_deactivated,
        'groupsDeleted', v_groups,
        'playersDeleted', v_players,
        'metadataDeleted', v_metadata
    );
END;
$function$;

REVOKE ALL
ON FUNCTION public.descartar_conformacion_tee_times(uuid,text)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.descartar_conformacion_tee_times(uuid,text)
TO authenticated, service_role;

COMMIT;
