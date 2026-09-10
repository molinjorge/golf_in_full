-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 283
-- Corrige la consulta de grupos vacíos dentro de la RPC 281
-- tournament_round_shifts no tiene tournament_id:
-- la relación correcta es turno -> ronda -> torneo.
-- ============================================================

DO $migration$
DECLARE
    v_oid oid;
    v_def text;
    v_old text := $old$
        FROM public.tournament_groups g
        JOIN public.tournament_round_shifts rs
          ON rs.id=g.tournament_round_shift_id
         AND rs.activo=true
        WHERE rs.tournament_id=v_t.id
          AND g.activo=true
$old$;
    v_new text := $new$
        FROM public.tournament_groups g
        JOIN public.tournament_round_shifts rs
          ON rs.id=g.tournament_round_shift_id
         AND rs.activo=true
        JOIN public.tournament_rounds r
          ON r.id=rs.tournament_round_id
         AND r.activo=true
        WHERE r.tournament_id=v_t.id
          AND g.activo=true
$new$;
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
            'No existe public.incorporar_suelto_como_excepcion_a_gogo_281(uuid,uuid,text). Aplique primero las migraciones previas.';
    END IF;

    v_def := pg_get_functiondef(v_oid);

    IF position('WHERE rs.tournament_id=v_t.id' in v_def) = 0 THEN
        RAISE EXCEPTION
            'La RPC 281 ya no contiene el predicado defectuoso rs.tournament_id=v_t.id. Revise antes de aplicar la Migración 283.';
    END IF;

    IF position(v_old in v_def) = 0 THEN
        RAISE EXCEPTION
            'La definición desplegada de la RPC 281 no coincide con el bloque esperado. No se aplicó ningún cambio.';
    END IF;

    v_def := replace(v_def, v_old, v_new);

    EXECUTE v_def;
END;
$migration$;

COMMENT ON FUNCTION public.incorporar_suelto_como_excepcion_a_gogo_281(uuid, uuid, text)
IS 'A-Go-Go 281/282/283: incorpora un único jugador suelto a un equipo normal completo como única excepción +1 pre-emisión. La 282 habilita temporalmente la válvula del trigger de cupo; la 283 corrige la relación grupos -> turnos -> rondas -> torneo al retirar grupos lógicamente vacíos.';
