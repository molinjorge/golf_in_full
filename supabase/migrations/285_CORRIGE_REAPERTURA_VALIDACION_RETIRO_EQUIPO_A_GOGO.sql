-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 285
-- Corrige reapertura de validacion de salidas en retiro competitivo
-- A-Go-Go post-Freeze / pre-START / pre-emision.
-- ============================================================

DO $migration$
DECLARE
    v_oid regprocedure;
    v_def text;
    v_old text;
    v_new text;
BEGIN
    v_oid := to_regprocedure('public.retirar_equipo_incompleto_competencia_a_gogo_284(uuid,text)');
    IF v_oid IS NULL THEN
        RAISE EXCEPTION 'Migracion 285: no existe la RPC 284 esperada.';
    END IF;

    SELECT pg_get_functiondef(v_oid) INTO v_def;

    v_old := $old$
    -- Reabrir sólo las validaciones lógicas afectadas. No se mueven
    -- físicamente los demás equipos.
    UPDATE public.tournament_round_start_validations
       SET status='superseded'
     WHERE tournament_id=v_t.id
       AND status='validated'
       AND start_format='shotgun'
       AND participation_type='equipo'
       AND scoring_engine='team_stroke';
$old$;

    v_new := $new$
    -- Reabrir sólo las validaciones lógicas afectadas mediante el contrato
    -- autorizado. La fotografía histórica validada permanece inmutable;
    -- únicamente cambia validated -> reopened con su auditoría.
    IF cardinality(v_validated_rounds) > 0 THEN
        PERFORM set_config('app.reabrir_validacion_salida_ronda','true',true);

        UPDATE public.tournament_round_start_validations
           SET status='reopened',
               reopened_at=now(),
               reopened_by=v_admin_id,
               reopen_reason='Retiro competitivo A-Go-Go 284: ' || btrim(p_reason)
         WHERE tournament_id=v_t.id
           AND status='validated'
           AND start_format='shotgun'
           AND participation_type='equipo'
           AND scoring_engine='team_stroke';

        PERFORM set_config('app.reabrir_validacion_salida_ronda','false',true);
    END IF;
$new$;

    IF position(v_old in v_def) = 0 THEN
        RAISE EXCEPTION 'Migracion 285 abortada: la RPC 284 desplegada no coincide con el bloque esperado.';
    END IF;

    IF position('app.reabrir_validacion_salida_ronda' in v_def) > 0 THEN
        RAISE EXCEPTION 'Migracion 285 abortada: la RPC 284 ya contiene reapertura autorizada.';
    END IF;

    v_def := replace(v_def, v_old, v_new);

    IF position(v_old in v_def) > 0
       OR position('app.reabrir_validacion_salida_ronda' in v_def) = 0
       OR position('status=''reopened''' in v_def) = 0
       OR position('reopened_at=now()' in v_def) = 0
       OR position('reopened_by=v_admin_id' in v_def) = 0
       OR position('reopen_reason=' in v_def) = 0
    THEN
        RAISE EXCEPTION 'Migracion 285 abortada: el parche no produjo la definicion esperada.';
    END IF;

    EXECUTE v_def;
END
$migration$;

COMMENT ON FUNCTION public.retirar_equipo_incompleto_competencia_a_gogo_284(uuid,text)
IS 'A-Go-Go: retira un equipo incompleto post-Freeze/pre-START/pre-emision preservando historia. Migracion 285 corrige la reapertura de validaciones mediante validated -> reopened autorizado.';
