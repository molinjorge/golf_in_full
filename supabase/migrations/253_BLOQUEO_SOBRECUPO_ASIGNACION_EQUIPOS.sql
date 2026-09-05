-- ============================================================================
-- MIGRACIÓN 253
-- Torneos por equipos: impedir sobrecupo al asignar/reasignar jugadores
-- ============================================================================
-- Problema corregido:
-- El trigger trg_validar_cupo_equipo protegía únicamente INSERT sobre
-- tournament_registrations. El armado administrativo de equipos usa UPDATE
-- de tournament_team_id, por lo que era posible mover jugadores a un equipo
-- ya completo y superar tournaments.jugadores_por_equipo.
--
-- Alcance:
-- - Protege INSERT y UPDATE relevantes de tournament_registrations.
-- - Solo valida cuando la operación incorpora una inscripción activa a un
--   equipo destino o reactiva una inscripción dentro de un equipo.
-- - Mover un jugador FUERA de un equipo completo sigue permitido.
-- - No altera scores, HCP TEAM, salidas, tarjetas, conciliación ni resultados.
-- - No corrige datos históricos automáticamente.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.validar_cupo_equipo()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_jugadores_por_equipo integer;
    v_ocupacion_actual integer;
    v_slots_mismo_jugador integer := 0;
    v_debe_validar boolean := false;
BEGIN
    -- Compatibilidad con flujos internos existentes que convierten una plaza
    -- ya reservada/roster en inscripción sin crear una plaza adicional.
    IF current_setting('app.saltar_validacion_cupo_equipo', true) = 'true' THEN
        RETURN NEW;
    END IF;

    -- Solo interesa una inscripción activa que termina perteneciendo a equipo.
    IF NEW.activo IS DISTINCT FROM true
       OR NEW.tournament_team_id IS NULL
    THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        v_debe_validar := true;
    ELSIF TG_OP = 'UPDATE' THEN
        -- Validar únicamente cuando la operación AUMENTA la ocupación del
        -- equipo destino:
        -- 1) entra desde otro equipo o desde SIN EQUIPO;
        -- 2) se reactiva dentro de un equipo.
        v_debe_validar :=
            OLD.activo IS DISTINCT FROM true
            OR OLD.tournament_team_id IS DISTINCT FROM NEW.tournament_team_id;
    END IF;

    IF NOT v_debe_validar THEN
        RETURN NEW;
    END IF;

    -- Serializa incorporaciones concurrentes al mismo equipo.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            NEW.tournament_team_id::text || ':team-capacity',
            253
        )
    );

    SELECT t.jugadores_por_equipo
      INTO v_jugadores_por_equipo
      FROM public.tournaments t
      JOIN public.tournament_teams tt
        ON tt.tournament_id=t.id
     WHERE tt.id=NEW.tournament_team_id
       AND tt.tournament_id=NEW.tournament_id
       AND tt.activo=true
       AND t.activo=true;

    IF v_jugadores_por_equipo IS NULL
       OR v_jugadores_por_equipo <= 0
    THEN
        RAISE EXCEPTION
            'El torneo no tiene configurado un tamaño válido de equipo.'
            USING ERRCODE='23514';
    END IF;

    v_ocupacion_actual :=
        public.ocupacion_actual_equipo(NEW.tournament_team_id);

    -- Si el jugador ya tiene un slot provisional/confirmado en el equipo
    -- destino, ese slot representa la MISMA plaza que ahora se convierte en
    -- inscripción. No debe contarse dos veces para esta validación.
    IF NEW.player_id IS NOT NULL THEN
        SELECT count(*)::integer
          INTO v_slots_mismo_jugador
          FROM public.tournament_team_roster_slots rs
         WHERE rs.tournament_team_id=NEW.tournament_team_id
           AND rs.tournament_id=NEW.tournament_id
           AND rs.player_id=NEW.player_id
           AND rs.status IN ('pending_confirmation','confirmed')
           AND rs.tournament_registration_id IS NULL;

        v_ocupacion_actual :=
            GREATEST(v_ocupacion_actual - v_slots_mismo_jugador, 0);
    END IF;

    IF v_ocupacion_actual >= v_jugadores_por_equipo THEN
        RAISE EXCEPTION
            'El equipo destino ya está completo (% de % lugares). No es posible asignar otro jugador.',
            v_ocupacion_actual,
            v_jugadores_por_equipo
            USING
                ERRCODE='23514',
                DETAIL='TEAM_CAPACITY_EXCEEDED';
    END IF;

    RETURN NEW;
END;
$function$;


DROP TRIGGER IF EXISTS trg_validar_cupo_equipo
ON public.tournament_registrations;

CREATE TRIGGER trg_validar_cupo_equipo
BEFORE INSERT OR UPDATE OF tournament_team_id, activo
ON public.tournament_registrations
FOR EACH ROW
EXECUTE FUNCTION public.validar_cupo_equipo();

COMMIT;
