-- ============================================================================
-- MIGRACION 185 FASE 1A
-- CORRECCION DE ZONA HORARIA EN HORA DE SALIDA TEE TIMES
-- TEE CENTRAL
--
-- DIAGNOSTICO CONFIRMADO
-- materializar_conformacion_tee_times(uuid,jsonb)
--   -> hora_salida_tee_time(uuid,integer)
--   -> COALESCE(c.timezone, 'America/Mexico_City')
--
-- El alias c representa public.clubs, pero clubs no tiene columna timezone.
--
-- FUENTE AUTORITATIVA
-- Se adopta el mismo patrón ya utilizado por hora_salida_shotgun():
--   tournament_rounds.campo_golf_id
--     -> campos_golf.timezone_id
--     -> timezones.iana_id
--
-- OBJETIVO
-- Corregir exclusivamente hora_salida_tee_time(uuid,integer).
--
-- NO CAMBIA
-- - intervalos;
-- - offsets;
-- - sequence_number;
-- - grupos;
-- - preferred_start_lane;
-- - materializador;
-- - Shotgun;
-- - datos existentes.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.hora_salida_tee_time(
    p_start_hole_id uuid,
    p_sequence_number integer
)
RETURNS timestamp with time zone
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_fecha date;
    v_hora time without time zone;
    v_intervalo integer;
    v_offset integer;
    v_timezone text;
BEGIN
    IF p_sequence_number IS NULL OR p_sequence_number < 1 THEN
        RAISE EXCEPTION
            'La secuencia Tee Times debe ser mayor o igual a 1.'
            USING ERRCODE = '22023';
    END IF;

    SELECT
        tr.fecha,
        rs.hora_salida,
        cfg.intervalo_grupos_minutos,
        sh.offset_inicio_minutos,
        cg.timezone_id
      INTO
        v_fecha,
        v_hora,
        v_intervalo,
        v_offset,
        v_timezone
      FROM public.tournament_tee_time_shift_start_holes sh
      JOIN public.tournament_tee_time_shift_configs cfg
        ON cfg.id = sh.tournament_tee_time_shift_config_id
       AND cfg.activo = true
      JOIN public.tournament_round_shifts rs
        ON rs.id = cfg.tournament_round_shift_id
       AND rs.activo = true
      JOIN public.tournament_rounds tr
        ON tr.id = rs.tournament_round_id
       AND tr.activo = true
      JOIN public.campos_golf cg
        ON cg.id = tr.campo_golf_id
       AND cg.activo = true
      JOIN public.timezones tz
        ON tz.iana_id = cg.timezone_id
       AND tz.activo = true
     WHERE sh.id = p_start_hole_id
       AND sh.activo = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No se pudo resolver la fecha, hora o zona horaria del Tee Time.'
            USING ERRCODE = '22023',
                  HINT = 'Verifica que el punto de salida, turno, ronda, campo de golf y zona horaria estén activos y relacionados.';
    END IF;

    RETURN (
        (
            v_fecha::timestamp
            + v_hora
            + make_interval(
                mins => v_offset
                    + ((p_sequence_number - 1) * v_intervalo)
            )
        ) AT TIME ZONE v_timezone
    );
END;
$function$;

REVOKE ALL
ON FUNCTION public.hora_salida_tee_time(uuid, integer)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.hora_salida_tee_time(uuid, integer)
TO service_role;

COMMIT;
