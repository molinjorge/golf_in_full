-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 319
-- BEST BALL F5 — MARCADORES TEAM
-- ============================================================================
-- OBJETIVO
--   1) Reutilizar tournament_scorecard_marker_assignments para Best Ball.
--   2) Generalizar el validador TEAM existente:
--        - team_stroke -> snapshot TEAM A-Go-Go existente
--        - best_ball   -> snapshot normalizado Best Ball 316
--   3) Crear asignación circular entre tarjetas TEAM del mismo grupo.
--   4) Si un equipo juega solo en el grupo, permitir self_team.
--   5) Integrar marcadores a la emisión atómica Best Ball.
--
-- NO HACE
--   - No habilita captura SCORE/PICKUP.
--   - No modifica las filas PENDING de tournament_best_ball_hole_scores.
--   - No cambia la lógica interna de marcadores A-Go-Go.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1. GENERALIZAR EL VALIDADOR TEAM EXISTENTE SIN CAMBIAR SU TRIGGER
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._validar_asignacion_marcador_team_243()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_target record;
    v_marker record;
    v_team_cards_in_group integer;
    v_member_match boolean:=false;
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

    -- Se preserva exactamente el comportamiento histórico para tarjetas
    -- que no sean TEAM de motores soportados.
    IF v_target.unit_type IS DISTINCT FROM 'team'
       OR v_target.participation_type IS DISTINCT FROM 'equipo'
       OR v_target.scoring_engine NOT IN ('team_stroke','best_ball')
    THEN
        IF NEW.marker_score_card_id=NEW.score_card_id THEN
            RAISE EXCEPTION
                'Una tarjeta individual no puede marcarse a sí misma.'
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
        sc.status,
        v.participation_type,
        v.scoring_engine
    INTO v_marker
    FROM public.tournament_score_cards sc
    JOIN public.tournament_round_start_validations v
      ON v.id=sc.validation_id
    WHERE sc.id=NEW.marker_score_card_id;

    IF v_marker.id IS NULL
       OR v_marker.status IS DISTINCT FROM 'issued'
       OR v_marker.unit_type IS DISTINCT FROM 'team'
       OR v_marker.participation_type IS DISTINCT FROM 'equipo'
    THEN
        RAISE EXCEPTION
            'La tarjeta del equipo marcador no es una tarjeta TEAM emitida.'
            USING ERRCODE='23514';
    END IF;

    IF v_marker.tournament_round_id IS DISTINCT FROM v_target.tournament_round_id
       OR v_marker.validation_id IS DISTINCT FROM v_target.validation_id
       OR v_marker.scoring_engine IS DISTINCT FROM v_target.scoring_engine
    THEN
        RAISE EXCEPTION
            'El equipo marcador debe pertenecer a la misma ronda, validación y motor.'
            USING ERRCODE='23514';
    END IF;

    IF v_marker.validation_group_id IS DISTINCT FROM v_target.validation_group_id THEN
        RAISE EXCEPTION
            'El equipo marcador debe pertenecer al mismo grupo de salida.'
            USING ERRCODE='23514';
    END IF;

    IF v_marker.id=v_target.id THEN
        SELECT count(*)
          INTO v_team_cards_in_group
          FROM public.tournament_score_cards sc
          JOIN public.tournament_round_start_validations v
            ON v.id=sc.validation_id
         WHERE sc.validation_group_id=v_target.validation_group_id
           AND sc.status='issued'
           AND sc.unit_type='team'
           AND v.participation_type='equipo'
           AND v.scoring_engine=v_target.scoring_engine;

        IF v_team_cards_in_group<>1 THEN
            RAISE EXCEPTION
                'El automarcado TEAM sólo está permitido cuando el equipo juega solo en su grupo.'
                USING ERRCODE='23514',
                      DETAIL=format(
                        'engine=%s; team_cards_in_group=%s',
                        v_target.scoring_engine,
                        v_team_cards_in_group
                      );
        END IF;
    ELSE
        IF v_marker.tournament_team_id IS NOT DISTINCT FROM v_target.tournament_team_id THEN
            RAISE EXCEPTION
                'El marcador normal debe pertenecer a otro equipo.'
                USING ERRCODE='23514';
        END IF;
    END IF;

    -- La pertenencia se exige únicamente a asignaciones activas.
    IF NEW.status='active' THEN
        IF v_target.scoring_engine='team_stroke' THEN
            SELECT EXISTS(
                SELECT 1
                FROM public.tournament_team_scorecard_snapshots ts
                CROSS JOIN LATERAL jsonb_array_elements(ts.members_snapshot) m
                WHERE ts.score_card_id=v_marker.id
                  AND NULLIF(m->>'playerId','')::uuid=NEW.marker_player_id
                  AND NULLIF(m->>'registrationId','')::uuid=NEW.marker_registration_id
            )
            INTO v_member_match;

        ELSIF v_target.scoring_engine='best_ball' THEN
            SELECT EXISTS(
                SELECT 1
                FROM public.tournament_best_ball_scorecard_snapshots ss
                JOIN public.tournament_best_ball_scorecard_members bm
                  ON bm.best_ball_scorecard_snapshot_id=ss.id
                WHERE ss.score_card_id=v_marker.id
                  AND bm.player_id=NEW.marker_player_id
                  AND bm.tournament_registration_id=NEW.marker_registration_id
            )
            INTO v_member_match;
        END IF;

        IF NOT COALESCE(v_member_match,false) THEN
            RAISE EXCEPTION
                'El jugador/inscripción indicado no pertenece a la tarjeta TEAM marcadora.'
                USING ERRCODE='23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

-- --------------------------------------------------------------------------
-- 2. INICIALIZADOR DE MARCADORES BEST BALL
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._inicializar_marcadores_best_ball_319(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_emission_id uuid;
    v_validation_id uuid;
    v_admin_id uuid;

    v_card_count integer:=0;
    v_assignment_count integer:=0;
    v_pending_count integer:=0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    SELECT tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds
     WHERE id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para inicializar marcadores Best Ball.'
            USING ERRCODE='42501';
    END IF;

    v_admin_id:=public._scorecard_current_admin_id();

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No existe administrador activo asociado.'
            USING ERRCODE='42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(p_tournament_round_id);

    SELECT e.id,e.validation_id
      INTO v_emission_id,v_validation_id
      FROM public.tournament_score_card_emissions e
      JOIN public.tournament_round_start_validations v
        ON v.id=e.validation_id
       AND v.tournament_round_id=e.tournament_round_id
     WHERE e.tournament_round_id=p_tournament_round_id
       AND e.status='issued'
       AND v.start_format='shotgun'
       AND v.participation_type='equipo'
       AND v.scoring_engine='best_ball'
       AND v.validator_engine='best_ball_team_shotgun_v1'
     LIMIT 1;

    IF v_emission_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda no tiene emisión oficial Best Ball TEAM.'
            USING ERRCODE='23514';
    END IF;

    SELECT count(*)
      INTO v_card_count
      FROM public.tournament_score_cards sc
     WHERE sc.emission_id=v_emission_id
       AND sc.status='issued'
       AND sc.unit_type='team';

    IF v_card_count=0 THEN
        RAISE EXCEPTION
            'La emisión Best Ball no contiene tarjetas TEAM.'
            USING ERRCODE='55000';
    END IF;

    -- F5 exige que F4 ya haya inicializado la sesión de cada tarjeta.
    IF (
        SELECT count(*)
        FROM public.tournament_scorecard_capture_sessions cs
        JOIN public.tournament_score_cards sc
          ON sc.id=cs.score_card_id
        WHERE sc.emission_id=v_emission_id
          AND sc.status='issued'
    )<>v_card_count THEN
        RAISE EXCEPTION
            'La captura Best Ball debe estar inicializada antes de asignar marcadores.'
            USING ERRCODE='55000';
    END IF;

    -- Construcción circular:
    --   tarjetas A,B,C => A<-C, B<-A, C<-B
    --   una sola TEAM => self_team
    -- El jugador marcador es member_order=1 de la tarjeta marcadora.
    WITH group_cards AS (
        SELECT
            sc.validation_group_id,
            array_agg(
                sc.id
                ORDER BY u.order_in_group,sc.id
            ) AS card_ids
        FROM public.tournament_score_cards sc
        JOIN public.tournament_round_start_validation_units u
          ON u.id=sc.validation_unit_id
         AND u.validation_id=sc.validation_id
        WHERE sc.emission_id=v_emission_id
          AND sc.status='issued'
          AND sc.unit_type='team'
        GROUP BY sc.validation_group_id
    ),
    proposed AS (
        SELECT
            gc.validation_group_id,
            gc.card_ids[i] AS target_card_id,
            CASE
                WHEN array_length(gc.card_ids,1)=1
                    THEN gc.card_ids[i]
                ELSE gc.card_ids[
                    CASE
                        WHEN i=1 THEN array_length(gc.card_ids,1)
                        ELSE i-1
                    END
                ]
            END AS marker_card_id,
            array_length(gc.card_ids,1) AS group_size
        FROM group_cards gc
        CROSS JOIN LATERAL generate_subscripts(gc.card_ids,1) s(i)
    ),
    marker_member AS (
        SELECT
            p.validation_group_id,
            p.target_card_id,
            p.marker_card_id,
            p.group_size,
            bm.player_id AS marker_player_id,
            bm.tournament_registration_id AS marker_registration_id
        FROM proposed p
        JOIN public.tournament_best_ball_scorecard_snapshots ss
          ON ss.score_card_id=p.marker_card_id
        JOIN public.tournament_best_ball_scorecard_members bm
          ON bm.best_ball_scorecard_snapshot_id=ss.id
         AND bm.member_order=1
    )
    INSERT INTO public.tournament_scorecard_marker_assignments(
        tournament_round_id,
        validation_group_id,
        score_card_id,
        marker_score_card_id,
        marker_player_id,
        marker_registration_id,
        assignment_source,
        valid_from_sequence,
        status,
        assigned_by
    )
    SELECT
        p_tournament_round_id,
        mm.validation_group_id,
        mm.target_card_id,
        mm.marker_card_id,
        mm.marker_player_id,
        mm.marker_registration_id,
        CASE
            WHEN mm.group_size=1 THEN 'self_team'
            ELSE 'circular_team'
        END,
        1,
        'active',
        v_admin_id
    FROM marker_member mm
    WHERE NOT EXISTS(
        SELECT 1
        FROM public.tournament_scorecard_marker_assignments ma
        WHERE ma.score_card_id=mm.target_card_id
          AND ma.status='active'
    );

    SELECT count(*)
      INTO v_assignment_count
      FROM public.tournament_scorecard_marker_assignments ma
      JOIN public.tournament_score_cards sc
        ON sc.id=ma.score_card_id
     WHERE sc.emission_id=v_emission_id
       AND sc.status='issued'
       AND ma.status='active';

    SELECT count(*)
      INTO v_pending_count
      FROM public.tournament_score_cards sc
     WHERE sc.emission_id=v_emission_id
       AND sc.status='issued'
       AND sc.unit_type='team'
       AND NOT EXISTS(
           SELECT 1
           FROM public.tournament_scorecard_marker_assignments ma
           WHERE ma.score_card_id=sc.id
             AND ma.status='active'
       );

    IF v_assignment_count<>v_card_count OR v_pending_count<>0 THEN
        RAISE EXCEPTION
            'La asignación de marcadores Best Ball quedó incompleta.'
            USING ERRCODE='55000',
                  DETAIL=format(
                    'tarjetas=%s; marcadores_activos=%s; pendientes=%s',
                    v_card_count,
                    v_assignment_count,
                    v_pending_count
                  );
    END IF;

    RETURN jsonb_build_object(
        'tournamentRoundId',p_tournament_round_id,
        'engine','best_ball',
        'initialized',true,
        'cardCount',v_card_count,
        'activeMarkerAssignments',v_assignment_count,
        'cardsWithoutMarker',v_pending_count
    );
END;
$function$;

-- --------------------------------------------------------------------------
-- 3. EMISION + CAPTURA PENDING + MARCADORES, TODO ATOMICO
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._emitir_tarjetas_best_ball_ronda_319(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_base jsonb;
    v_markers jsonb;
BEGIN
    v_base:=public._emitir_tarjetas_best_ball_ronda_318(
        p_tournament_round_id
    );

    v_markers:=public._inicializar_marcadores_best_ball_319(
        p_tournament_round_id
    );

    IF NOT COALESCE((v_markers->>'initialized')::boolean,false)
       OR v_markers->>'engine' IS DISTINCT FROM 'best_ball'
       OR COALESCE((v_markers->>'cardsWithoutMarker')::integer,-1)<>0
    THEN
        RAISE EXCEPTION
            'La emisión Best Ball no pudo completar la asignación de marcadores.'
            USING ERRCODE='55000',
                  DETAIL=COALESCE(v_markers::text,'NULL');
    END IF;

    RETURN v_base || jsonb_build_object(
        'markerInitialization',v_markers
    );
END;
$function$;

-- --------------------------------------------------------------------------
-- 4. DISPATCHER OFICIAL DE EMISION
--    Único cambio: Best Ball usa wrapper 319.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.emitir_tarjetas_score_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_capability jsonb;
    v_emission_engine text;
BEGIN
    v_capability:=public._resolver_capacidad_emision_tarjetas_ronda(
        p_tournament_round_id
    );

    IF NOT COALESCE((v_capability->>'supported')::boolean,false) THEN
        RETURN public._emitir_tarjetas_score_ronda_individual_208(
            p_tournament_round_id
        );
    END IF;

    v_emission_engine:=v_capability->>'scorecardEmissionEngine';

    IF v_emission_engine='official_scorecard_best_ball_team_v1' THEN
        RETURN public._emitir_tarjetas_best_ball_ronda_319(
            p_tournament_round_id
        );
    END IF;

    IF v_emission_engine='official_scorecard_team_v1'
       AND v_capability->>'unitType'='team'
    THEN
        RETURN public._emitir_tarjetas_equipo_a_gogo_ronda_246(
            p_tournament_round_id
        );
    END IF;

    RETURN public._emitir_tarjetas_score_ronda_individual_208(
        p_tournament_round_id
    );
END;
$function$;

COMMIT;
