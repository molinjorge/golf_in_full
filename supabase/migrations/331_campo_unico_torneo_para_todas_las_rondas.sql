-- MIGRACIÓN 331
-- TEE CENTRAL / GOLF IN FULL
-- Campo único por torneo: todas las rondas heredan obligatoriamente
-- tournaments.campo_golf_id.
--
-- PREMISA FUNCIONAL:
--   Todo el torneo se juega en el campo seleccionado en el torneo.
--   El campo no es una configuración independiente de la ronda.
--
-- Esta migración:
--   1) protege INSERT/UPDATE de tournament_rounds para exigir el campo del torneo;
--   2) conserva la firma existente de crear_o_reactivar_siguiente_ronda(...);
--   3) ignora p_campo_golf_id como fuente de verdad y usa el campo del torneo;
--   4) no modifica históricos cancelados;
--   5) no altera fechas, formatos, allowance, Freeze, lifecycle ni motores.
--
-- EJECUCIÓN MANUAL EN SUPABASE.

BEGIN;

CREATE OR REPLACE FUNCTION public._forzar_campo_torneo_en_ronda_331()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_campo_torneo uuid;
BEGIN
    SELECT t.campo_golf_id
      INTO v_campo_torneo
      FROM public.tournaments t
     WHERE t.id = NEW.tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo de la ronda no existe.'
            USING ERRCODE = '23503';
    END IF;

    IF v_campo_torneo IS NULL THEN
        RAISE EXCEPTION
            'El torneo debe tener un campo de golf definido antes de crear o modificar sus rondas.'
            USING ERRCODE = '23514';
    END IF;

    -- El campo de la ronda no es independiente: siempre hereda el del torneo.
    NEW.campo_golf_id := v_campo_torneo;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_forzar_campo_torneo_en_ronda_331
ON public.tournament_rounds;

CREATE TRIGGER trg_forzar_campo_torneo_en_ronda_331
BEFORE INSERT OR UPDATE OF campo_golf_id, tournament_id
ON public.tournament_rounds
FOR EACH ROW
EXECUTE FUNCTION public._forzar_campo_torneo_en_ronda_331();

CREATE OR REPLACE FUNCTION public.crear_o_reactivar_siguiente_ronda(
    p_tournament_id uuid,
    p_fecha date,
    p_campo_golf_id uuid,
    p_tournament_format_id uuid DEFAULT NULL::uuid,
    p_handicap_allowance_pct numeric DEFAULT NULL::numeric,
    p_formato_salida public.formato_salida_ronda DEFAULT NULL::public.formato_salida_ronda
)
RETURNS public.tournament_rounds
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_declared_rounds integer;
    v_next_round integer;
    v_existing public.tournament_rounds%ROWTYPE;
    v_result public.tournament_rounds%ROWTYPE;
    v_admin_id uuid;
    v_has_dependencies boolean;
    v_campo_torneo uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para administrar las rondas de este torneo.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(p_tournament_id::text, 138));

    SELECT t.numero_rondas, t.campo_golf_id
      INTO v_declared_rounds, v_campo_torneo
      FROM public.tournaments t
     WHERE t.id = p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo no existe.' USING ERRCODE = '22023';
    END IF;

    IF v_declared_rounds IS NULL THEN
        RAISE EXCEPTION 'El torneo no tiene definido su número de rondas.'
            USING ERRCODE = '22023';
    END IF;

    IF v_campo_torneo IS NULL THEN
        RAISE EXCEPTION
            'El torneo debe tener un campo de golf definido antes de crear o reactivar rondas.'
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No se pueden crear ni reactivar rondas después de congelar el torneo.'
            USING ERRCODE = '55000';
    END IF;

    IF p_handicap_allowance_pct IS NOT NULL
       AND (p_handicap_allowance_pct < 0 OR p_handicap_allowance_pct > 100) THEN
        RAISE EXCEPTION 'Handicap Allowance fuera del rango 0..100.'
            USING ERRCODE = '22023';
    END IF;

    SELECT gs
      INTO v_next_round
      FROM generate_series(1, v_declared_rounds) AS gs
     WHERE NOT EXISTS (
         SELECT 1
         FROM public.tournament_rounds tr
         WHERE tr.tournament_id = p_tournament_id
           AND tr.numero_ronda = gs
           AND tr.activo = true
     )
     ORDER BY gs
     LIMIT 1;

    IF v_next_round IS NULL THEN
        RAISE EXCEPTION
            'Todas las % ronda(s) declaradas ya están activas.',
            v_declared_rounds
            USING ERRCODE = '23514';
    END IF;

    SELECT *
      INTO v_existing
      FROM public.tournament_rounds tr
     WHERE tr.tournament_id = p_tournament_id
       AND tr.numero_ronda = v_next_round
     FOR UPDATE;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo = true
     ORDER BY au.id
     LIMIT 1;

    IF v_existing.id IS NOT NULL THEN
        SELECT EXISTS (
            SELECT 1
            FROM public.tournament_round_shifts rs
            WHERE rs.tournament_round_id = v_existing.id
        )
        INTO v_has_dependencies;

        IF v_has_dependencies
           AND (
                p_fecha IS DISTINCT FROM v_existing.fecha
                OR v_campo_torneo IS DISTINCT FROM v_existing.campo_golf_id
                OR p_formato_salida IS DISTINCT FROM v_existing.formato_salida
           ) THEN
            RAISE EXCEPTION
                'La ronda % tiene turnos o salidas relacionados; debe reactivarse conservando fecha, campo y formato de salida.',
                v_next_round
                USING ERRCODE = '23514',
                      HINT = 'Abre los datos existentes de la ronda inactiva y no cambies sus condiciones físicas.';
        END IF;

        UPDATE public.tournament_rounds
           SET fecha = p_fecha,
               campo_golf_id = v_campo_torneo,
               tournament_format_id = p_tournament_format_id,
               handicap_allowance_pct = p_handicap_allowance_pct,
               formato_salida = p_formato_salida,
               activo = true,
               fecha_baja = NULL,
               dado_de_baja_por = NULL,
               motivo_baja = NULL
         WHERE id = v_existing.id
         RETURNING * INTO v_result;
    ELSE
        INSERT INTO public.tournament_rounds (
            tournament_id,
            numero_ronda,
            fecha,
            tournament_format_id,
            campo_golf_id,
            handicap_allowance_pct,
            formato_salida,
            activo,
            created_by
        )
        VALUES (
            p_tournament_id,
            v_next_round,
            p_fecha,
            p_tournament_format_id,
            v_campo_torneo,
            p_handicap_allowance_pct,
            p_formato_salida,
            true,
            v_admin_id
        )
        RETURNING * INTO v_result;
    END IF;

    RETURN v_result;
END;
$function$;

-- Se conserva la política de permisos existente de la RPC.
REVOKE ALL ON FUNCTION public._forzar_campo_torneo_en_ronda_331() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._forzar_campo_torneo_en_ronda_331() FROM anon;
REVOKE ALL ON FUNCTION public._forzar_campo_torneo_en_ronda_331() FROM authenticated;

COMMIT;
