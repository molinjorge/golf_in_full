-- MIGRACION 391
-- TEE CENTRAL
-- Blindaje de reapertura de captura cuando la ronda ya fue cerrada competitivamente.
-- El usuario ejecuta esta migración manualmente en Supabase PROD.

BEGIN;

CREATE OR REPLACE FUNCTION public.reabrir_captura_ronda_389(
    p_tournament_round_id uuid,
    p_motivo text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_auth uuid := auth.uid();
    v_admin_id uuid;
    v_tournament_id uuid;
    v_state jsonb;
BEGIN
    IF v_auth IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF NULLIF(btrim(p_motivo),'') IS NULL THEN
        RAISE EXCEPTION 'El motivo de reapertura es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    SELECT r.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds r
     WHERE r.id = p_tournament_round_id
       AND r.activo = true
     FOR UPDATE;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'Ronda activa no encontrada.' USING ERRCODE='22023';
    END IF;

    IF NOT (
        public.is_superadmin(v_auth)
        OR public.is_tournament_organizer(v_auth, v_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No autorizado para reabrir captura.'
            USING ERRCODE='42501';
    END IF;

    -- 391: el cierre competitivo de ronda es punto de no retorno para captura.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_round_competitive_closures rc
         WHERE rc.tournament_round_id = p_tournament_round_id
           AND rc.competitive_status = 'FINAL'
    ) THEN
        RAISE EXCEPTION
            'No se puede reabrir captura: la ronda ya fue cerrada competitivamente.'
            USING ERRCODE='55000';
    END IF;

    -- Regla existente desde 389: tampoco se reabre si ya existe
    -- al menos una categoría cerrada formalmente.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_round_category_competitive_closures c
         WHERE c.tournament_round_id = p_tournament_round_id
           AND c.competitive_status = 'FINAL'
    ) THEN
        RAISE EXCEPTION
            'No se puede reabrir captura: ya existe al menos una categoría cerrada formalmente.'
            USING ERRCODE='55000';
    END IF;

    v_state := public.obtener_estado_cierre_captura_ronda_389(
        p_tournament_round_id
    );

    IF NOT COALESCE((v_state->>'captureClosed')::boolean, false) THEN
        RETURN v_state;
    END IF;

    v_admin_id := public.current_admin_id();

    INSERT INTO public.tournament_round_capture_events (
        tournament_id,
        tournament_round_id,
        action,
        notes,
        summary_snapshot,
        performed_by_admin_user_id,
        performed_by_auth_user_id
    )
    VALUES (
        v_tournament_id,
        p_tournament_round_id,
        'REOPENED',
        btrim(p_motivo),
        v_state->'summary',
        v_admin_id,
        v_auth
    );

    RETURN public.obtener_estado_cierre_captura_ronda_389(
        p_tournament_round_id
    );
END;
$function$;

COMMIT;
