-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 282
-- Corrige RPC 281 para permitir la excepción +1 controlada
-- frente al trigger general de cupo de equipo (Migración 253)
-- ============================================================

DO $migration$
DECLARE
    v_oid oid;
    v_def text;
    v_marker_override text :=
        'PERFORM set_config(''app.a_gogo_composition_override'',''true'',true);';
    v_marker_move_end text :=
        'WHERE id=v_reg.id;';
BEGIN
    SELECT p.oid
      INTO v_oid
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = 'incorporar_suelto_como_excepcion_a_gogo_281'
       AND pg_get_function_identity_arguments(p.oid)
           = 'p_registration_id uuid, p_target_team_id uuid, p_reason text';

    IF v_oid IS NULL THEN
        RAISE EXCEPTION
            'No existe public.incorporar_suelto_como_excepcion_a_gogo_281(uuid,uuid,text). Aplique primero la Migración 281.';
    END IF;

    v_def := pg_get_functiondef(v_oid);

    IF position('app.saltar_validacion_cupo_equipo' in v_def) > 0 THEN
        RAISE EXCEPTION
            'La RPC 281 ya contiene la señal app.saltar_validacion_cupo_equipo; revise antes de aplicar la Migración 282.';
    END IF;

    IF position(v_marker_override in v_def) = 0 THEN
        RAISE EXCEPTION
            'No se encontró el punto esperado de override de composición en la RPC 281. No se aplicó ningún cambio.';
    END IF;

    IF position(v_marker_move_end in v_def) = 0 THEN
        RAISE EXCEPTION
            'No se encontró el UPDATE esperado de la inscripción en la RPC 281. No se aplicó ningún cambio.';
    END IF;

    -- Abrir la válvula oficial del trigger 253 únicamente dentro de la
    -- operación excepcional ya validada por la RPC 281.
    v_def := replace(
        v_def,
        v_marker_override,
        v_marker_override || E'\n\n    -- Migración 282: excepción controlada de cupo sólo para este movimiento.\n    PERFORM set_config(''app.saltar_validacion_cupo_equipo'',''true'',true);'
    );

    -- Cerrar de inmediato la válvula después del movimiento de la inscripción.
    v_def := replace(
        v_def,
        v_marker_move_end,
        v_marker_move_end || E'\n\n    PERFORM set_config(''app.saltar_validacion_cupo_equipo'',''false'',true);'
    );

    EXECUTE v_def;
END;
$migration$;

COMMENT ON FUNCTION public.incorporar_suelto_como_excepcion_a_gogo_281(uuid, uuid, text)
IS 'A-Go-Go 281/282: incorpora un único jugador suelto a un equipo normal completo como única excepción +1 pre-emisión. La 282 habilita de forma local y temporal la válvula del trigger general de cupo únicamente durante el UPDATE controlado de la inscripción.';
