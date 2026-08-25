-- ============================================================================
-- MIGRACION 185 FASE 1E
-- FAIL-CLOSED DE MATERIALIZACION + DESCARTE SEGURO DE CONFORMACION TEE TIMES
-- TEE CENTRAL
--
-- REGLA FUNCIONAL
-- CONFIGURAR Tee Times puede hacerse antes del cierre.
-- MATERIALIZAR / CONFIRMAR SALIDAS sólo puede hacerse cuando:
--   1) las inscripciones están cerradas / torneo operativo;
--   2) existe congelamiento del torneo;
--   3) la ronda forma parte del congelamiento;
--   4) existen snapshots de handicap de ronda;
--   5) la ronda aún no está validada;
--   6) no existen tarjetas oficiales emitidas.
--
-- También se crea una RPC administrativa para descartar una conformación
-- Tee Times NO validada y SIN tarjetas. Esto permite limpiar conformaciones
-- prematuras y volver a prepararlas después del congelamiento.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 01. PRESERVAR MATERIALIZADOR VIGENTE COMO CORE
-- ---------------------------------------------------------------------------
DO $do$
BEGIN
    IF to_regprocedure(
        'public.materializar_conformacion_tee_times_core_1851e(uuid,jsonb)'
    ) IS NULL THEN
        ALTER FUNCTION public.materializar_conformacion_tee_times(uuid,jsonb)
        RENAME TO materializar_conformacion_tee_times_core_1851e;
    END IF;
END
$do$;

-- ---------------------------------------------------------------------------
-- 02. WRAPPER FAIL-CLOSED
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.materializar_conformacion_tee_times(
    p_shift_config_id uuid,
    p_grupos jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_round_id uuid;
    v_tournament_id uuid;
    v_status text;
    v_freeze_id uuid;
    v_round_condition_snapshot_id uuid;
    v_round_snapshot_count integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        rs.tournament_round_id,
        tr.tournament_id,
        t.estatus::text
      INTO
        v_round_id,
        v_tournament_id,
        v_status
      FROM public.tournament_tee_time_shift_configs cfg
      JOIN public.tournament_round_shifts rs
        ON rs.id = cfg.tournament_round_shift_id
       AND rs.activo
      JOIN public.tournament_rounds tr
        ON tr.id = rs.tournament_round_id
       AND tr.activo
      JOIN public.tournaments t
        ON t.id = tr.tournament_id
     WHERE cfg.id = p_shift_config_id
       AND cfg.activo
       AND tr.formato_salida =
           'tee_times'::public.formato_salida_ronda;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No existe una configuración Tee Times activa y válida para este turno.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para materializar esta conformación Tee Times.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(v_round_id);

    -- Inscripciones abiertas: jamás materializar.
    IF v_status NOT IN ('inscripcion_cerrada', 'en_curso') THEN
        RAISE EXCEPTION
            'Debes cerrar las inscripciones antes de preparar y confirmar las salidas Tee Times.'
            USING ERRCODE = '55000',
                  HINT = 'Configurar Tee Times sí está permitido; materializar grupos requiere inscripciones cerradas y condiciones congeladas.';
    END IF;

    SELECT f.id
      INTO v_freeze_id
      FROM public.tournament_condition_freezes f
     WHERE f.tournament_id = v_tournament_id
     ORDER BY f.frozen_at DESC
     LIMIT 1;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION
            'Debes congelar las condiciones y hándicaps del torneo antes de confirmar las salidas Tee Times.'
            USING ERRCODE = '55000';
    END IF;

    SELECT rcs.id
      INTO v_round_condition_snapshot_id
      FROM public.tournament_round_condition_snapshots rcs
     WHERE rcs.freeze_id = v_freeze_id
       AND rcs.tournament_round_id = v_round_id
     LIMIT 1;

    IF v_round_condition_snapshot_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda no forma parte de las condiciones congeladas del torneo.'
            USING ERRCODE = '55000';
    END IF;

    SELECT count(*)
      INTO v_round_snapshot_count
      FROM public.tournament_round_handicap_snapshots rhs
     WHERE rhs.tournament_round_id = v_round_id
       AND rhs.freeze_id = v_freeze_id;

    IF v_round_snapshot_count = 0 THEN
        RAISE EXCEPTION
            'La ronda no tiene snapshots de hándicap congelados; no se pueden confirmar las salidas Tee Times.'
            USING ERRCODE = '55000';
    END IF;

    IF public._salida_ronda_esta_validada(v_round_id) THEN
        RAISE EXCEPTION
            'Las salidas de la ronda ya están validadas y no pueden volver a materializarse.'
            USING ERRCODE = '55000';
    END IF;

    IF public._ronda_tiene_tarjetas_emitidas(v_round_id) THEN
        RAISE EXCEPTION
            'La ronda ya tiene tarjetas oficiales emitidas y no puede volver a materializarse.'
            USING ERRCODE = '55000';
    END IF;

    RETURN public.materializar_conformacion_tee_times_core_1851e(
        p_shift_config_id,
        p_grupos
    );
END;
$function$;

REVOKE ALL
ON FUNCTION public.materializar_conformacion_tee_times_core_1851e(uuid,jsonb)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.materializar_conformacion_tee_times_core_1851e(uuid,jsonb)
TO service_role;

REVOKE ALL
ON FUNCTION public.materializar_conformacion_tee_times(uuid,jsonb)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.materializar_conformacion_tee_times(uuid,jsonb)
TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 03. DESCARTE SEGURO DE CONFORMACION NO VALIDADA
-- ---------------------------------------------------------------------------
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
            'groupsDeleted', 0,
            'playersDeleted', 0,
            'metadataDeleted', 0,
            'message', 'El turno no tiene conformación Tee Times persistida.'
        );
    END IF;

    DELETE FROM public.tournament_group_players gp
     WHERE gp.tournament_group_id = ANY(v_group_ids);
    GET DIAGNOSTICS v_players = ROW_COUNT;

    DELETE FROM public.tournament_tee_time_groups ttg
     WHERE ttg.tournament_group_id = ANY(v_group_ids);
    GET DIAGNOSTICS v_metadata = ROW_COUNT;

    DELETE FROM public.tournament_groups g
     WHERE g.id = ANY(v_group_ids);
    GET DIAGNOSTICS v_groups = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'discarded', true,
        'roundId', v_round_id,
        'shiftConfigId', p_shift_config_id,
        'reason', btrim(p_reason),
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
