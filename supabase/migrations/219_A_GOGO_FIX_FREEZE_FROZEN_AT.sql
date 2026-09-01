-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 219
-- A-Go-Go L4C1B — Corrección de referencia al congelamiento vigente
--
-- Objetivo:
-- Corregir referencias heredadas a tournament_condition_freezes.created_at,
-- columna que no existe. La columna temporal real es frozen_at.
--
-- Alcance:
--   1) reasignar_inscripcion_equipo_a_gogo_post_freeze(...)
--   2) solicitar_sustitucion_integrante_a_gogo_post_freeze(...)
--   3) confirmar_sustitucion_integrante_a_gogo(...)
--
-- No cambia firmas, permisos, reglas funcionales ni contratos de retorno.
-- No modifica Stroke Play, Stableford, tarjetas, scoring, HCP TEAM ni salidas.
-- ============================================================================

DO $migration_219$
DECLARE
    r record;
    v_def text;
    v_new_def text;
    v_count integer := 0;
BEGIN
    FOR r IN
        SELECT p.oid,
               p.proname,
               pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.prokind = 'f'
          AND (
                (p.proname = 'reasignar_inscripcion_equipo_a_gogo_post_freeze'
                 AND pg_get_function_identity_arguments(p.oid) =
                     'p_tournament_registration_id uuid, p_new_team_id uuid, p_reason text')
             OR (p.proname = 'solicitar_sustitucion_integrante_a_gogo_post_freeze'
                 AND pg_get_function_identity_arguments(p.oid) =
                     'p_outgoing_registration_id uuid, p_incoming_name text, p_incoming_email citext, p_reason text')
             OR (p.proname = 'confirmar_sustitucion_integrante_a_gogo'
                 AND pg_get_function_identity_arguments(p.oid) =
                     'p_request_id uuid')
          )
    LOOP
        v_def := pg_get_functiondef(r.oid);

        IF v_def NOT ILIKE '%ORDER BY f.created_at DESC%' THEN
            RAISE EXCEPTION
                'Migración 219: la función public.%(%) no contiene la referencia esperada a f.created_at; se aborta para evitar una modificación no controlada.',
                r.proname, r.args;
        END IF;

        v_new_def := replace(
            v_def,
            'ORDER BY f.created_at DESC',
            'ORDER BY f.frozen_at DESC'
        );

        EXECUTE v_new_def;
        v_count := v_count + 1;
    END LOOP;

    IF v_count <> 3 THEN
        RAISE EXCEPTION
            'Migración 219: se esperaban exactamente 3 funciones corregidas y se encontraron %.',
            v_count;
    END IF;
END
$migration_219$;

-- La migración es deliberadamente quirúrgica:
-- no se crean objetos, no se cambian firmas y no se otorgan permisos.
