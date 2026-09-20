-- TEE CENTRAL / GOLF IN FULL
-- Migración 345
-- Objetivo: permitir cerrar una ronda sin capturar notas de cierre.
-- Ejecución manual en Supabase.

BEGIN;

CREATE OR REPLACE FUNCTION public.cerrar_ronda_competitiva(
    p_tournament_round_id uuid,
    p_notas text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_round public.tournament_rounds%ROWTYPE;
    v_lifecycle public.tournament_round_lifecycle%ROWTYPE;
    v_result jsonb;
    v_admin_id uuid;
BEGIN
    SELECT *
      INTO v_round
      FROM public.tournament_rounds
     WHERE id = p_tournament_round_id
       AND activo = true;

    IF v_round.id IS NULL THEN
        RAISE EXCEPTION
            'La ronda indicada no existe o no está activa.'
            USING ERRCODE='22023';
    END IF;

    INSERT INTO public.tournament_round_lifecycle(
        tournament_id,
        tournament_round_id
    )
    VALUES (
        v_round.tournament_id,
        v_round.id
    )
    ON CONFLICT (tournament_round_id) DO NOTHING;

    SELECT *
      INTO v_lifecycle
      FROM public.tournament_round_lifecycle
     WHERE tournament_round_id = v_round.id
     FOR UPDATE;

    IF v_lifecycle.started_at IS NULL THEN
        RAISE EXCEPTION
            'La ronda debe estar EN JUEGO antes de poder finalizarse.'
            USING ERRCODE='23514',
                  HINT='Ejecuta primero INICIAR RONDA.';
    END IF;

    v_result :=
        public._cerrar_ronda_competitiva_pre314(
            p_tournament_round_id,
            p_notas
        );

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo = true
     ORDER BY au.id
     LIMIT 1;

    UPDATE public.tournament_round_lifecycle
       SET completed_at = COALESCE(completed_at, now()),
           completed_by_admin_user_id =
               COALESCE(completed_by_admin_user_id, v_admin_id),
           completion_source =
               COALESCE(completion_source, 'FORMAL_CLOSE'),
           updated_at = now()
     WHERE tournament_round_id = v_round.id;

    RETURN v_result;
END;
$function$;

COMMIT;
