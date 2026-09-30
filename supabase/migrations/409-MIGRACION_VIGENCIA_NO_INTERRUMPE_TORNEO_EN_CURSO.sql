-- TEE CENTRAL
-- MIGRACIÓN 409 — VIGENCIA COMERCIAL NO INTERRUMPE TORNEO EN CURSO
-- IMPORTANTE: ejecutar manualmente en Supabase PROD.

BEGIN;

CREATE OR REPLACE FUNCTION public.torneo_esta_vencido_295(p_tournament_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT EXISTS (
        SELECT 1
          FROM public.platform_tournament_access a
          JOIN public.tournaments t
            ON t.id = a.tournament_id
          LEFT JOIN public.campos_golf c
            ON c.id = t.campo_golf_id
         WHERE a.tournament_id = p_tournament_id
           -- Un torneo formalmente EN CURSO nunca se interrumpe por vigencia comercial.
           AND t.estatus IS DISTINCT FROM 'en_curso'
           -- El último día de vigencia termina según la zona horaria del campo.
           AND (clock_timestamp() AT TIME ZONE COALESCE(NULLIF(BTRIM(c.timezone_id), ''), 'UTC'))::date
                 > a.valid_through_date
    );
$function$;

CREATE OR REPLACE FUNCTION public.obtener_estado_vigencia_torneo_294(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_exists boolean;
    v_access public.platform_tournament_access%rowtype;
    v_tournament_status text;
    v_timezone text;
    v_local_date date;
    v_status text;
    v_write_allowed boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1
          FROM public.tournaments t
         WHERE t.id = p_tournament_id
    )
    INTO v_tournament_exists;

    IF NOT v_tournament_exists THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING errcode = '22023';
    END IF;

    SELECT a.*
      INTO v_access
      FROM public.platform_tournament_access a
     WHERE a.tournament_id = p_tournament_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'tournamentId', p_tournament_id,
            'status', 'LEGACY',
            'writeAllowed', true,
            'readOnly', false,
            'validFromDate', null,
            'validThroughDate', null
        );
    END IF;

    SELECT t.estatus,
           COALESCE(NULLIF(BTRIM(c.timezone_id), ''), 'UTC')
      INTO v_tournament_status, v_timezone
      FROM public.tournaments t
      LEFT JOIN public.campos_golf c
        ON c.id = t.campo_golf_id
     WHERE t.id = p_tournament_id;

    v_local_date := (clock_timestamp() AT TIME ZONE v_timezone)::date;

    -- La vigencia comercial controla el acceso antes de iniciar,
    -- pero nunca interrumpe un torneo formalmente EN CURSO.
    IF v_tournament_status = 'en_curso' THEN
        v_status := 'VIGENTE';
        v_write_allowed := true;
    ELSIF v_local_date < v_access.valid_from_date THEN
        v_status := 'NO_INICIADO';
        v_write_allowed := false;
    ELSIF v_local_date <= v_access.valid_through_date THEN
        v_status := 'VIGENTE';
        v_write_allowed := true;
    ELSE
        v_status := 'VENCIDO';
        v_write_allowed := false;
    END IF;

    RETURN jsonb_build_object(
        'tournamentId', p_tournament_id,
        'status', v_status,
        'writeAllowed', v_write_allowed,
        'readOnly', NOT v_write_allowed,
        'validFromDate', v_access.valid_from_date,
        'validThroughDate', v_access.valid_through_date
    );
END;
$function$;

COMMIT;
