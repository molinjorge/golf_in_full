-- ============================================================================
-- 180_bloquear_validacion_salidas_con_inscripciones_abiertas.sql
-- TEE CENTRAL
--
-- OBJETIVO
-- Corregir una regla puntual de previsualizar_validacion_salidas_ronda():
--
-- ANTES:
--   estatus distinto de inscripcion_cerrada / en_curso => WARNING
--
-- DESPUES:
--   estatus distinto de inscripcion_cerrada / en_curso => ERROR BLOQUEANTE
--
-- Como ready = (errors = 0), esto impide VALIDAR Y CERRAR SALIDAS
-- mientras las inscripciones sigan abiertas.
--
-- IMPORTANTE
-- - REVISAR SALIDAS sigue permitido.
-- - No congela nada.
-- - No modifica grupos, turnos, snapshots ni tarjetas.
-- - No cambia ninguna otra regla del validador.
-- ============================================================================

BEGIN;

DO $migration$
DECLARE
    v_oid regprocedure;
    v_def text;
    v_old text;
    v_new text;
    v_hits integer;
BEGIN
    v_oid := to_regprocedure(
        'public.previsualizar_validacion_salidas_ronda(uuid)'
    );

    IF v_oid IS NULL THEN
        RAISE EXCEPTION
            'No existe public.previsualizar_validacion_salidas_ronda(uuid).';
    END IF;

    v_def := pg_get_functiondef(v_oid);

    v_old := $old$
    IF v_ctx.tournament_status NOT IN ('inscripcion_cerrada', 'en_curso') THEN
        v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
            'code', 'estatus_torneo_no_operativo',
            'message', format(
                'El torneo tiene estatus %s; normalmente las salidas se validan con inscripciones cerradas.',
                v_ctx.tournament_status
            )
        ));
    END IF;
$old$;

    v_new := $new$
    IF v_ctx.tournament_status NOT IN ('inscripcion_cerrada', 'en_curso') THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'estatus_torneo_no_operativo',
            'message', format(
                'El torneo tiene estatus %s. Debes cerrar las inscripciones antes de validar y cerrar las salidas.',
                v_ctx.tournament_status
            )
        ));
    END IF;
$new$;

    v_hits :=
        (length(v_def) - length(replace(v_def, v_old, '')))
        / NULLIF(length(v_old), 0);

    IF v_hits <> 1 THEN
        RAISE EXCEPTION
            'Migracion 180 detenida: se esperaba encontrar exactamente 1 bloque estatus_torneo_no_operativo y se encontraron %.',
            v_hits
            USING HINT =
                'No se modifico la funcion. Diagnostica primero su definicion actual.';
    END IF;

    v_def := replace(v_def, v_old, v_new);

    EXECUTE v_def;
END;
$migration$;

COMMIT;
