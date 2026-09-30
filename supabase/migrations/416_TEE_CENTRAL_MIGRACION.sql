-- TEE CENTRAL
-- Migración 416
-- Corrige nombre de jugador en obtener_resultados_stableford_torneo(uuid)
-- Alcance: Stableford Individual acumulado/finalización.
-- No modifica frontend ni otros motores deportivos.

BEGIN;

DO $$
DECLARE
    v_oid oid;
    v_definition text;
    v_matches integer;
BEGIN
    SELECT p.oid
      INTO v_oid
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = 'obtener_resultados_stableford_torneo'
       AND pg_get_function_identity_arguments(p.oid) = 'p_tournament_id uuid';

    IF v_oid IS NULL THEN
        RAISE EXCEPTION
            '416 abortada: no existe public.obtener_resultados_stableford_torneo(uuid).';
    END IF;

    SELECT pg_get_functiondef(v_oid)
      INTO v_definition;

    SELECT count(*)
      INTO v_matches
      FROM regexp_matches(
          v_definition,
          'p\.nombre[[:space:]]+AS player_name',
          'g'
      );

    IF v_matches <> 1 THEN
        RAISE EXCEPTION
            '416 abortada: se esperaba exactamente 1 referencia obsoleta p.nombre AS player_name; encontradas %.',
            v_matches;
    END IF;

    v_definition := regexp_replace(
        v_definition,
        'p\.nombre[[:space:]]+AS player_name',
        'btrim(concat_ws('' '', p.nombres, p.apellidos)) AS player_name'
    );

    EXECUTE v_definition;
END
$$;

COMMIT;
