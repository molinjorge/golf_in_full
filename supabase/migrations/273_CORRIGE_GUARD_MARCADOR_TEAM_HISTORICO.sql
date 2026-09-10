-- ============================================================
-- MIGRACIÓN 273
-- Corrige guard de marcadores TEAM para cierre histórico
-- ============================================================
-- Objetivo:
--   Permitir que una asignación de marcador TEAM previamente válida
--   pueda pasar a estado 'ended' aunque el jugador/inscripción ya no
--   pertenezca al snapshot vigente de la tarjeta marcadora.
--
-- Contexto:
--   En una sustitución post-emisión, primero se actualiza el snapshot
--   TEAM con la nueva composición. Después, el helper 215 termina la
--   asignación activa del marcador saliente y crea una nueva asignación
--   con un integrante vigente.
--
-- Regla preservada:
--   - Asignaciones activas: el jugador/inscripción DEBE pertenecer al
--     snapshot vigente de la tarjeta TEAM marcadora.
--   - Asignaciones terminadas/históricas: pueden conservar al jugador
--     anterior, para no reescribir historia.
--
-- No desactiva triggers, no crea bypass genérico y no modifica datos.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._validar_asignacion_marcador_team_243()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_target record;
    v_marker record;
    v_team_cards_in_group integer;
    v_member_match boolean := false;
BEGIN
    SELECT
        sc.id,
        sc.tournament_round_id,
        sc.validation_id,
        sc.validation_group_id,
        sc.tournament_team_id,
        sc.unit_type,
        sc.status,
        v.participation_type,
        v.scoring_engine
    INTO v_target
    FROM public.tournament_score_cards sc
    JOIN public.tournament_round_start_validations v
      ON v.id=sc.validation_id
    WHERE sc.id=NEW.score_card_id;

    IF v_target.id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta objetivo de marcador no existe.'
            USING ERRCODE='23503';
    END IF;

    -- Fuera de TEAM/team_stroke sólo preservamos la prohibición histórica
    -- de automarcado. No se alteran las reglas de PLAYER.
    IF v_target.unit_type IS DISTINCT FROM 'team'
       OR v_target.participation_type IS DISTINCT FROM 'equipo'
       OR v_target.scoring_engine IS DISTINCT FROM 'team_stroke'
    THEN
        IF NEW.marker_score_card_id=NEW.score_card_id THEN
            RAISE EXCEPTION 'Una tarjeta individual no puede marcarse a sí misma.'
                USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;

    IF v_target.status IS DISTINCT FROM 'issued' THEN
        RAISE EXCEPTION 'La tarjeta TEAM objetivo debe estar emitida.'
            USING ERRCODE='23514';
    END IF;

    SELECT
        sc.id,
        sc.tournament_round_id,
        sc.validation_id,
        sc.validation_group_id,
        sc.tournament_team_id,
        sc.unit_type,
        sc.status
    INTO v_marker
    FROM public.tournament_score_cards sc
    WHERE sc.id=NEW.marker_score_card_id;

    IF v_marker.id IS NULL
       OR v_marker.status IS DISTINCT FROM 'issued'
       OR v_marker.unit_type IS DISTINCT FROM 'team'
    THEN
        RAISE EXCEPTION 'La tarjeta del equipo marcador no es una tarjeta TEAM emitida.'
            USING ERRCODE='23514';
    END IF;

    IF v_marker.tournament_round_id IS DISTINCT FROM v_target.tournament_round_id THEN
        RAISE EXCEPTION 'El equipo marcador debe pertenecer a la misma ronda.'
            USING ERRCODE='23514';
    END IF;

    -- Regla física: para TEAM el marcador debe jugar en el mismo grupo.
    IF v_marker.validation_group_id IS DISTINCT FROM v_target.validation_group_id THEN
        RAISE EXCEPTION 'El equipo marcador debe pertenecer al mismo grupo de salida.'
            USING ERRCODE='23514';
    END IF;

    IF v_marker.id = v_target.id THEN
        SELECT count(*)
        INTO v_team_cards_in_group
        FROM public.tournament_score_cards sc
        JOIN public.tournament_round_start_validations v
          ON v.id=sc.validation_id
        WHERE sc.validation_group_id=v_target.validation_group_id
          AND sc.status='issued'
          AND sc.unit_type='team'
          AND v.participation_type='equipo'
          AND v.scoring_engine='team_stroke';

        IF v_team_cards_in_group<>1 THEN
            RAISE EXCEPTION
                'El automarcado TEAM sólo está permitido cuando el equipo juega solo en su grupo.'
                USING ERRCODE='23514',
                      DETAIL=format('team_cards_in_group=%s',v_team_cards_in_group);
        END IF;
    ELSE
        IF v_marker.tournament_team_id IS NOT DISTINCT FROM v_target.tournament_team_id THEN
            RAISE EXCEPTION 'El marcador normal debe pertenecer a otro equipo.'
                USING ERRCODE='23514';
        END IF;
    END IF;

    -- 273:
    -- La pertenencia al snapshot vigente sólo se exige a una asignación
    -- que va a quedar ACTIVA. Una asignación ENDED es evidencia histórica
    -- y puede conservar al jugador/inscripción que pertenecía al snapshot
    -- anterior antes de una sustitución.
    IF NEW.status = 'active' THEN
        SELECT EXISTS(
            SELECT 1
            FROM public.tournament_team_scorecard_snapshots ts
            CROSS JOIN LATERAL jsonb_array_elements(ts.members_snapshot) m
            WHERE ts.score_card_id=v_marker.id
              AND NULLIF(m->>'playerId','')::uuid=NEW.marker_player_id
              AND NULLIF(m->>'registrationId','')::uuid=NEW.marker_registration_id
        )
        INTO v_member_match;

        IF NOT COALESCE(v_member_match,false) THEN
            RAISE EXCEPTION
                'El jugador/inscripción indicado no pertenece a la tarjeta TEAM marcadora.'
                USING ERRCODE='23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

COMMIT;
