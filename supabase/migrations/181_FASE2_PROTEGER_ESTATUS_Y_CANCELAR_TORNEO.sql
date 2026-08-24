-- ============================================================================
-- 181_FASE2_PROTEGER_ESTATUS_Y_CANCELAR_TORNEO.sql
-- TEE CENTRAL
--
-- OBJETIVOS
-- 1) Proteger public.tournaments.estatus contra cambios directos.
-- 2) Hacer que las RPCs de ciclo de vida de 181 Fase 1 sean las únicas vías
--    normales para abrir/cerrar/reabrir/iniciar.
-- 3) Formalizar CANCELAR TORNEO mediante RPC controlada.
--
-- NO IMPLEMENTA:
-- - finalizar_torneo()
-- - reapertura de un torneo cancelado
-- - cambios automáticos por fecha
-- - cambios de estado_servicio (eje comercial independiente)
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. GUARD DE ESTATUS DEPORTIVO
-- ============================================================================
CREATE OR REPLACE FUNCTION public.proteger_cambio_estatus_torneo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.estatus IS NOT DISTINCT FROM OLD.estatus THEN
        RETURN NEW;
    END IF;

    IF current_setting(
        'app.permitir_cambio_estatus_torneo',
        true
    ) IS DISTINCT FROM '1' THEN
        RAISE EXCEPTION
            'El estatus deportivo del torneo no puede modificarse directamente.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'tournament_id=%s; estatus_anterior=%s; estatus_nuevo=%s',
                      OLD.id,
                      OLD.estatus,
                      NEW.estatus
                  ),
                  HINT =
                      'Utiliza la operación autorizada de ciclo de vida: abrir, cerrar o reabrir inscripciones, iniciar, cancelar o finalizar el torneo.';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_proteger_cambio_estatus_torneo
    ON public.tournaments;

CREATE TRIGGER trg_proteger_cambio_estatus_torneo
BEFORE UPDATE OF estatus
ON public.tournaments
FOR EACH ROW
EXECUTE FUNCTION public.proteger_cambio_estatus_torneo();


-- ============================================================================
-- 02. PARCHE DEFENSIVO A LAS CUATRO RPCs DE 181 FASE 1
--     Inserta set_config() inmediatamente antes del UPDATE de estatus.
-- ============================================================================
DO $migration$
DECLARE
    v_names text[] := ARRAY[
        'abrir_inscripciones_torneo',
        'cerrar_inscripciones_torneo',
        'reabrir_inscripciones_torneo',
        'iniciar_torneo'
    ];
    v_name text;
    v_oid regprocedure;
    v_def text;
    v_old text;
    v_new text;
    v_hits integer;
BEGIN
    FOREACH v_name IN ARRAY v_names LOOP

        v_oid := to_regprocedure(
            format('public.%I(uuid)', v_name)
        );

        IF v_oid IS NULL THEN
            RAISE EXCEPTION
                'Migración 181 Fase 2 detenida: no existe public.%(uuid).',
                v_name;
        END IF;

        v_def := pg_get_functiondef(v_oid);

        -- Idempotencia: si ya contiene el permiso, no vuelve a insertarlo.
        IF v_def ILIKE '%app.permitir_cambio_estatus_torneo%' THEN
            CONTINUE;
        END IF;

        CASE v_name
            WHEN 'abrir_inscripciones_torneo' THEN
                v_old := $old$
    UPDATE public.tournaments
       SET estatus = 'inscripciones_abiertas'::public.estatus_torneo
     WHERE id = p_tournament_id;
$old$;

                v_new := $new$
    PERFORM set_config(
        'app.permitir_cambio_estatus_torneo',
        '1',
        true
    );

    UPDATE public.tournaments
       SET estatus = 'inscripciones_abiertas'::public.estatus_torneo
     WHERE id = p_tournament_id;
$new$;

            WHEN 'cerrar_inscripciones_torneo' THEN
                v_old := $old$
    UPDATE public.tournaments
       SET estatus = 'inscripcion_cerrada'::public.estatus_torneo
     WHERE id = p_tournament_id;
$old$;

                v_new := $new$
    PERFORM set_config(
        'app.permitir_cambio_estatus_torneo',
        '1',
        true
    );

    UPDATE public.tournaments
       SET estatus = 'inscripcion_cerrada'::public.estatus_torneo
     WHERE id = p_tournament_id;
$new$;

            WHEN 'reabrir_inscripciones_torneo' THEN
                v_old := $old$
    UPDATE public.tournaments
       SET estatus = 'inscripciones_abiertas'::public.estatus_torneo
     WHERE id = p_tournament_id;
$old$;

                v_new := $new$
    PERFORM set_config(
        'app.permitir_cambio_estatus_torneo',
        '1',
        true
    );

    UPDATE public.tournaments
       SET estatus = 'inscripciones_abiertas'::public.estatus_torneo
     WHERE id = p_tournament_id;
$new$;

            WHEN 'iniciar_torneo' THEN
                v_old := $old$
    UPDATE public.tournaments
       SET estatus = 'en_curso'::public.estatus_torneo
     WHERE id = p_tournament_id;
$old$;

                v_new := $new$
    PERFORM set_config(
        'app.permitir_cambio_estatus_torneo',
        '1',
        true
    );

    UPDATE public.tournaments
       SET estatus = 'en_curso'::public.estatus_torneo
     WHERE id = p_tournament_id;
$new$;
        END CASE;

        v_hits :=
            (length(v_def) - length(replace(v_def, v_old, '')))
            / NULLIF(length(v_old), 0);

        IF v_hits <> 1 THEN
            RAISE EXCEPTION
                'Migración 181 Fase 2 detenida: en % se esperaba exactamente 1 UPDATE de estatus y se encontraron %.',
                v_name,
                v_hits
                USING HINT =
                    'No se modificó esa función. Diagnostica primero su definición actual.';
        END IF;

        v_def := replace(v_def, v_old, v_new);

        EXECUTE v_def;
    END LOOP;
END;
$migration$;


-- ============================================================================
-- 03. CANCELAR TORNEO
--
-- Acción manual y terminal dentro del ciclo deportivo normal.
-- Puede cancelarse desde:
--   planificado
--   inscripciones_abiertas
--   inscripcion_cerrada
--   en_curso
--
-- NO puede cancelarse un torneo ya finalizado.
-- Si ya está cancelado, es idempotente.
--
-- El motivo se exige para que la operación sea deliberada.
-- El UPDATE queda registrado además por trg_audit_tournaments.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cancelar_torneo(
    p_tournament_id uuid,
    p_motivo text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
    v_motivo text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(
            auth.uid(),
            p_tournament_id
        )
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden cancelar el torneo.'
            USING ERRCODE = '42501';
    END IF;

    v_motivo := btrim(COALESCE(p_motivo, ''));

    IF length(v_motivo) < 10 THEN
        RAISE EXCEPTION
            'El motivo de cancelación debe tener al menos 10 caracteres.'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF v_t.estatus = 'cancelado'::public.estatus_torneo THEN
        RETURN jsonb_build_object(
            'ok', true,
            'tournamentId', p_tournament_id,
            'alreadyCancelled', true,
            'estatus', 'cancelado'
        );
    END IF;

    IF v_t.estatus = 'finalizado'::public.estatus_torneo THEN
        RAISE EXCEPTION
            'Un torneo FINALIZADO no puede cambiarse a CANCELADO.'
            USING ERRCODE = '23514';
    END IF;

    IF v_t.estatus NOT IN (
        'planificado'::public.estatus_torneo,
        'inscripciones_abiertas'::public.estatus_torneo,
        'inscripcion_cerrada'::public.estatus_torneo,
        'en_curso'::public.estatus_torneo
    ) THEN
        RAISE EXCEPTION
            'El torneo no puede cancelarse desde su estado actual: %.',
            v_t.estatus
            USING ERRCODE = '23514';
    END IF;

    PERFORM set_config(
        'app.permitir_cambio_estatus_torneo',
        '1',
        true
    );

    UPDATE public.tournaments
       SET estatus = 'cancelado'::public.estatus_torneo
     WHERE id = p_tournament_id;

    RETURN jsonb_build_object(
        'ok', true,
        'tournamentId', p_tournament_id,
        'alreadyCancelled', false,
        'estatusAnterior', v_t.estatus::text,
        'estatus', 'cancelado',
        'motivo', v_motivo
    );
END;
$function$;


-- ============================================================================
-- 04. PRIVILEGIOS DE CANCELACIÓN
-- ============================================================================
REVOKE ALL
ON FUNCTION public.cancelar_torneo(uuid, text)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.cancelar_torneo(uuid, text)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.cancelar_torneo(uuid, text)
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.cancelar_torneo(uuid, text)
TO service_role;


COMMIT;
