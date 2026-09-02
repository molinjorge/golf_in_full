-- TEE CENTRAL / GOLF IN FULL
-- Migración 221
-- Corrección del trigger común que bloquea PICKUP en A-Go-Go.
--
-- Problema:
-- _bloquear_pickup_a_gogo_209() estaba referenciando NEW.result_type y
-- NEW.physical_result_type dentro de una sola expresión booleana. Al ejecutarse
-- sobre tournament_scorecard_hole_scores, PostgreSQL intentaba resolver
-- NEW.physical_result_type, columna que no existe en esa tabla, provocando:
--   [42703] record "new" has no field "physical_result_type"
--
-- Solución:
-- separar explícitamente la rama digital de la física por TG_TABLE_NAME.
-- No cambia la regla funcional: team_stroke sigue sin admitir PICKUP.
--
-- IMPORTANTE: ejecutar manualmente en Supabase.

BEGIN;

CREATE OR REPLACE FUNCTION public._bloquear_pickup_a_gogo_209()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_engine text;
    v_is_pickup boolean := false;
BEGIN
    IF TG_TABLE_NAME = 'tournament_scorecard_hole_scores' THEN
        v_is_pickup := (NEW.result_type = 'PICKUP');

    ELSIF TG_TABLE_NAME = 'tournament_scorecard_physical_hole_scores' THEN
        v_is_pickup := (NEW.physical_result_type = 'PICKUP');

    ELSE
        RAISE EXCEPTION
            '_bloquear_pickup_a_gogo_209 fue ejecutado desde una tabla no soportada: %',
            TG_TABLE_NAME
            USING ERRCODE = '0A000';
    END IF;

    IF v_is_pickup THEN
        SELECT v.scoring_engine
          INTO v_engine
          FROM public.tournament_score_cards sc
          JOIN public.tournament_round_start_validations v
            ON v.id = sc.validation_id
         WHERE sc.id = NEW.score_card_id;

        IF v_engine = 'team_stroke' THEN
            RAISE EXCEPTION
                'PICKUP no está permitido en A-Go-Go.'
                USING ERRCODE = '0A000';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

COMMIT;
