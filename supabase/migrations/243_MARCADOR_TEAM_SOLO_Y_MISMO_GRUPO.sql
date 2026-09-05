-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 243
-- A-Go-Go TEAM: marcador del mismo equipo sólo cuando juega solo
-- + marcador contrario restringido al mismo grupo de salida
-- ============================================================================
-- OBJETIVO
-- 1) Permitir automarcado TEAM exclusivamente cuando la tarjeta es la única
--    tarjeta TEAM emitida de su grupo de salida.
-- 2) Mantener marcado cruzado/circular para grupos con 2+ equipos.
-- 3) Impedir que un marcador TEAM sea tomado de otro grupo de salida.
-- 4) Conservar reasignación localizada por play_sequence y trazabilidad.
-- 5) No modificar Stroke Play, Stableford, scoring, conciliación ni resultados.
--
-- IMPORTANTE:
-- - Esta migración no inicializa capturas ni modifica datos operativos existentes.
-- - El automarcado es una excepción controlada para grupos TEAM solitarios.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. assignment_source: agregar fuente explícita para automarcado TEAM
-- ---------------------------------------------------------------------------

ALTER TABLE public.tournament_scorecard_marker_assignments
    DROP CONSTRAINT IF EXISTS tournament_scorecard_marker_assignments_assignment_source_check;

ALTER TABLE public.tournament_scorecard_marker_assignments
    ADD CONSTRAINT tournament_scorecard_marker_assignments_assignment_source_check
    CHECK (
        assignment_source = ANY (
            ARRAY[
                'circular'::text,
                'admin'::text,
                'circular_team'::text,
                'admin_team'::text,
                'composition_refresh_team'::text,
                'self_team'::text
            ]
        )
    );

-- El CHECK histórico prohibía toda autorreferencia. Se sustituye por un guard
-- contextual que sólo la permite para TEAM/team_stroke cuando el grupo tiene
-- exactamente una tarjeta TEAM emitida.
ALTER TABLE public.tournament_scorecard_marker_assignments
    DROP CONSTRAINT IF EXISTS tournament_scorecard_marker_not_self_ck;


-- ---------------------------------------------------------------------------
-- 2. Guard estructural para asignaciones TEAM
-- ---------------------------------------------------------------------------

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

    IF v_marker.id= v_target.id THEN
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

    -- El jugador y la inscripción del marcador deben existir en el snapshot
    -- oficial de la tarjeta marcadora, incluso en automarcado.
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

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_validar_asignacion_marcador_team_243
ON public.tournament_scorecard_marker_assignments;

CREATE TRIGGER trg_validar_asignacion_marcador_team_243
BEFORE INSERT OR UPDATE OF
    score_card_id,
    marker_score_card_id,
    marker_player_id,
    marker_registration_id,
    status,
    valid_from_sequence,
    valid_to_sequence
ON public.tournament_scorecard_marker_assignments
FOR EACH ROW
EXECUTE FUNCTION public._validar_asignacion_marcador_team_243();


-- ---------------------------------------------------------------------------
-- 3. Reasignación administrativa TEAM
--    - otro equipo: obligatorio mismo grupo
--    - misma tarjeta: sólo si el grupo tiene un único TEAM
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.asignar_marcador_tarjeta_equipo_a_gogo(
    p_score_card_id uuid,
    p_marker_score_card_id uuid,
    p_marker_player_id uuid,
    p_from_sequence integer,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_target record;
    v_marker record;
    v_admin_id uuid;
    v_marker_registration_id uuid;
    v_old_assignment record;
    v_new_assignment_id uuid;
    v_holes_expected integer;
    v_team_cards_in_group integer;
    v_is_self boolean := false;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_from_sequence IS NULL OR p_from_sequence<=0 THEN
        RAISE EXCEPTION
            'La secuencia inicial del marcador debe ser mayor que cero.'
            USING ERRCODE='22023';
    END IF;

    IF length(btrim(COALESCE(p_reason,'')))<5 THEN
        RAISE EXCEPTION
            'El motivo del cambio de marcador debe tener al menos 5 caracteres.'
            USING ERRCODE='22023';
    END IF;

    SELECT
        sc.id,
        sc.tournament_id,
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
    WHERE sc.id=p_score_card_id;

    IF v_target.id IS NULL
       OR v_target.status<>'issued'
       OR v_target.unit_type<>'team'
       OR v_target.participation_type IS DISTINCT FROM 'equipo'
       OR v_target.scoring_engine IS DISTINCT FROM 'team_stroke'
    THEN
        RAISE EXCEPTION
            'La tarjeta objetivo no es una tarjeta A-Go-Go TEAM emitida.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_target.tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para cambiar el marcador de esta tarjeta.'
            USING ERRCODE='42501';
    END IF;

    v_admin_id:=public._scorecard_current_admin_id();

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene administrador activo asociado.'
            USING ERRCODE='42501';
    END IF;

    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.validation_group_id,
        sc.tournament_team_id,
        sc.unit_type,
        sc.status
    INTO v_marker
    FROM public.tournament_score_cards sc
    WHERE sc.id=p_marker_score_card_id;

    IF v_marker.id IS NULL
       OR v_marker.status<>'issued'
       OR v_marker.unit_type<>'team'
    THEN
        RAISE EXCEPTION
            'La tarjeta del equipo marcador no es válida.'
            USING ERRCODE='22023';
    END IF;

    IF v_marker.tournament_round_id<>v_target.tournament_round_id THEN
        RAISE EXCEPTION
            'El equipo marcador debe pertenecer a la misma ronda.'
            USING ERRCODE='23514';
    END IF;

    IF v_marker.validation_group_id IS DISTINCT FROM v_target.validation_group_id THEN
        RAISE EXCEPTION
            'El equipo marcador debe pertenecer al mismo grupo de salida.'
            USING ERRCODE='23514';
    END IF;

    v_is_self := (v_marker.id=v_target.id);

    IF v_is_self THEN
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
        IF v_marker.tournament_team_id=v_target.tournament_team_id THEN
            RAISE EXCEPTION
                'El marcador normal debe pertenecer a otro equipo.'
                USING ERRCODE='23514';
        END IF;
    END IF;

    SELECT NULLIF(m->>'registrationId','')::uuid
    INTO v_marker_registration_id
    FROM public.tournament_team_scorecard_snapshots ts
    CROSS JOIN LATERAL jsonb_array_elements(ts.members_snapshot) m
    WHERE ts.score_card_id=v_marker.id
      AND NULLIF(m->>'playerId','')::uuid=p_marker_player_id
    LIMIT 1;

    IF v_marker_registration_id IS NULL THEN
        RAISE EXCEPTION
            'El jugador indicado no pertenece al equipo marcador de esa tarjeta.'
            USING ERRCODE='23514';
    END IF;

    SELECT cs.holes_expected
    INTO v_holes_expected
    FROM public.tournament_scorecard_capture_sessions cs
    WHERE cs.score_card_id=v_target.id;

    IF v_holes_expected IS NULL THEN
        RAISE EXCEPTION
            'La captura de esta ronda todavía no está inicializada.'
            USING ERRCODE='55000';
    END IF;

    IF p_from_sequence>v_holes_expected THEN
        RAISE EXCEPTION
            'La secuencia inicial excede el número de hoyos de la tarjeta.'
            USING ERRCODE='22023';
    END IF;

    IF EXISTS(
        SELECT 1
        FROM public.tournament_scorecard_hole_scores hs
        WHERE hs.score_card_id=v_target.id
          AND hs.play_sequence>=p_from_sequence
          AND hs.result_type='SCORE'
    ) THEN
        RAISE EXCEPTION
            'No puede cambiarse retroactivamente el marcador sobre hoyos ya capturados.'
            USING ERRCODE='55000',
                  HINT='Use una secuencia posterior al último hoyo ya capturado.';
    END IF;

    SELECT ma.*
    INTO v_old_assignment
    FROM public.tournament_scorecard_marker_assignments ma
    WHERE ma.score_card_id=v_target.id
      AND ma.status='active'
    FOR UPDATE;

    IF v_old_assignment.id IS NOT NULL THEN
        UPDATE public.tournament_scorecard_marker_assignments
        SET status='ended',
            valid_to_sequence=
                CASE
                    WHEN p_from_sequence>v_old_assignment.valid_from_sequence
                    THEN p_from_sequence-1
                    ELSE NULL
                END,
            ended_at=now(),
            change_reason=p_reason
        WHERE id=v_old_assignment.id;
    END IF;

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
        assigned_by,
        change_reason
    )
    VALUES(
        v_target.tournament_round_id,
        v_target.validation_group_id,
        v_target.id,
        v_marker.id,
        p_marker_player_id,
        v_marker_registration_id,
        CASE WHEN v_is_self THEN 'admin_team' ELSE 'admin_team' END,
        p_from_sequence,
        'active',
        v_admin_id,
        p_reason
    )
    RETURNING id INTO v_new_assignment_id;

    INSERT INTO public.tournament_scorecard_events(
        score_card_id,
        marker_assignment_id,
        event_type,
        actor_admin_user_id,
        reason
    )
    VALUES(
        v_target.id,
        v_new_assignment_id,
        'marker_changed',
        v_admin_id,
        p_reason
    );

    RETURN jsonb_build_object(
        'scoreCardId',v_target.id,
        'competitiveUnit','TEAM',
        'markerAssignmentId',v_new_assignment_id,
        'markerScoreCardId',v_marker.id,
        'markerPlayerId',p_marker_player_id,
        'validFromSequence',p_from_sequence,
        'selfMarker',v_is_self,
        'status','active'
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- 4. Inicializador TEAM
--    Grupo con 1 TEAM -> self_team
--    Grupo con 2+ TEAM -> circular_team (comportamiento existente)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._inicializar_captura_scores_equipo_a_gogo_209(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_validation_id uuid;
    v_round_condition_snapshot_id uuid;
    v_emission_id uuid;
    v_admin_id uuid;
    v_card_count integer:=0;
    v_hole_count integer:=0;
    v_session_count integer:=0;
    v_hole_row_count integer:=0;
    v_assignment_count integer:=0;
    v_pending_marker_count integer:=0;
    v_bad_cards integer:=0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT tournament_id INTO v_tournament_id
    FROM public.tournament_rounds
    WHERE id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para inicializar la captura.'
            USING ERRCODE='42501';
    END IF;

    v_admin_id:=public._scorecard_current_admin_id();
    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No existe administrador activo asociado.';
    END IF;

    PERFORM public._bloquear_salida_ronda(p_tournament_round_id);

    SELECT e.id,e.validation_id,v.round_condition_snapshot_id
    INTO v_emission_id,v_validation_id,v_round_condition_snapshot_id
    FROM public.tournament_score_card_emissions e
    JOIN public.tournament_round_start_validations v ON v.id=e.validation_id
    WHERE e.tournament_round_id=p_tournament_round_id
      AND e.status='issued'
      AND v.start_format='shotgun'
      AND v.participation_type='equipo'
      AND v.scoring_engine='team_stroke'
    LIMIT 1;

    IF v_emission_id IS NULL THEN
        RAISE EXCEPTION 'La ronda no tiene emisión oficial A-Go-Go TEAM.';
    END IF;

    SELECT count(*),count(*) FILTER(
        WHERE sc.unit_type<>'team'
           OR sc.tournament_team_id IS NULL
           OR sc.player_id IS NOT NULL
           OR sc.tournament_registration_id IS NOT NULL
    )
    INTO v_card_count,v_bad_cards
    FROM public.tournament_score_cards sc
    WHERE sc.emission_id=v_emission_id
      AND sc.status='issued';

    IF v_card_count=0 OR v_bad_cards>0 THEN
        RAISE EXCEPTION 'La emisión contiene tarjetas incompatibles con captura TEAM.';
    END IF;

    SELECT count(*) INTO v_hole_count
    FROM public.tournament_round_hole_snapshots h
    WHERE h.round_condition_snapshot_id=v_round_condition_snapshot_id;

    IF v_hole_count=0 THEN
        RAISE EXCEPTION 'La ronda no tiene hoyos congelados para captura.';
    END IF;

    INSERT INTO public.tournament_scorecard_capture_sessions(
        score_card_id,
        tournament_id,
        tournament_round_id,
        validation_id,
        status,
        holes_expected
    )
    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.validation_id,
        'ready',
        v_hole_count
    FROM public.tournament_score_cards sc
    WHERE sc.emission_id=v_emission_id
      AND sc.status='issued'
    ON CONFLICT(score_card_id) DO NOTHING;

    SELECT count(*) INTO v_session_count
    FROM public.tournament_scorecard_capture_sessions cs
    JOIN public.tournament_score_cards sc ON sc.id=cs.score_card_id
    WHERE sc.emission_id=v_emission_id
      AND sc.status='issued';

    INSERT INTO public.tournament_scorecard_hole_scores(
        capture_session_id,
        score_card_id,
        tournament_round_id,
        round_hole_snapshot_id,
        hole_number,
        play_sequence,
        result_type,
        status
    )
    SELECT
        cs.id,
        sc.id,
        sc.tournament_round_id,
        h.id,
        h.hole_number,
        row_number() OVER(
            PARTITION BY sc.id
            ORDER BY
                CASE WHEN h.hole_number>=g.hole_number THEN 0 ELSE 1 END,
                h.hole_number
        )::integer,
        'PENDING',
        'pending'
    FROM public.tournament_score_cards sc
    JOIN public.tournament_scorecard_capture_sessions cs
      ON cs.score_card_id=sc.id
    JOIN public.tournament_round_start_validation_groups g
      ON g.id=sc.validation_group_id
     AND g.validation_id=sc.validation_id
    JOIN public.tournament_round_hole_snapshots h
      ON h.round_condition_snapshot_id=v_round_condition_snapshot_id
    WHERE sc.emission_id=v_emission_id
      AND sc.status='issued'
    ON CONFLICT(score_card_id,round_hole_snapshot_id) DO NOTHING;

    SELECT count(*) INTO v_hole_row_count
    FROM public.tournament_scorecard_hole_scores hs
    JOIN public.tournament_score_cards sc ON sc.id=hs.score_card_id
    WHERE sc.emission_id=v_emission_id
      AND sc.status='issued';

    IF v_hole_row_count<>v_card_count*v_hole_count THEN
        RAISE EXCEPTION 'La inicialización de hoyos TEAM quedó incompleta.';
    END IF;

    -- Marcador por tarjeta/equipo dentro del mismo grupo:
    --   1 TEAM  -> un integrante del propio TEAM (self_team)
    --   2+ TEAM -> circular entre tarjetas TEAM (circular_team)
    WITH group_cards AS (
        SELECT
            sc.validation_group_id,
            array_agg(sc.id ORDER BY u.order_in_group,sc.id) card_ids
        FROM public.tournament_score_cards sc
        JOIN public.tournament_round_start_validation_units u
          ON u.id=sc.validation_unit_id
         AND u.validation_id=sc.validation_id
        WHERE sc.emission_id=v_emission_id
          AND sc.status='issued'
        GROUP BY sc.validation_group_id
    ),
    proposed AS (
        SELECT
            gc.validation_group_id,
            gc.card_ids[i] target_card_id,
            CASE
                WHEN array_length(gc.card_ids,1)=1
                    THEN gc.card_ids[i]
                ELSE gc.card_ids[
                    CASE
                        WHEN i=1 THEN array_length(gc.card_ids,1)
                        ELSE i-1
                    END
                ]
            END marker_card_id,
            array_length(gc.card_ids,1) group_size
        FROM group_cards gc
        CROSS JOIN LATERAL generate_subscripts(gc.card_ids,1) s(i)
    ),
    marker_member AS (
        SELECT
            p.*,
            NULLIF(m->>'playerId','')::uuid marker_player_id,
            NULLIF(m->>'registrationId','')::uuid marker_registration_id
        FROM proposed p
        LEFT JOIN LATERAL (
            SELECT m
            FROM public.tournament_team_scorecard_snapshots ss
            CROSS JOIN LATERAL jsonb_array_elements(ss.members_snapshot) m
            WHERE ss.score_card_id=p.marker_card_id
              AND NULLIF(m->>'playerId','') IS NOT NULL
              AND NULLIF(m->>'registrationId','') IS NOT NULL
            ORDER BY
                COALESCE((m->>'whsRank')::integer,2147483647),
                m->>'name'
            LIMIT 1
        ) mm ON true
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
        CASE WHEN mm.group_size=1 THEN 'self_team' ELSE 'circular_team' END,
        1,
        'active',
        v_admin_id
    FROM marker_member mm
    WHERE mm.marker_player_id IS NOT NULL
      AND mm.marker_registration_id IS NOT NULL
      AND NOT EXISTS(
          SELECT 1
          FROM public.tournament_scorecard_marker_assignments ma
          WHERE ma.score_card_id=mm.target_card_id
            AND ma.status='active'
      );

    SELECT count(*) INTO v_assignment_count
    FROM public.tournament_scorecard_marker_assignments ma
    JOIN public.tournament_score_cards sc ON sc.id=ma.score_card_id
    WHERE sc.emission_id=v_emission_id
      AND ma.status='active';

    SELECT count(*) INTO v_pending_marker_count
    FROM public.tournament_score_cards sc
    WHERE sc.emission_id=v_emission_id
      AND sc.status='issued'
      AND NOT EXISTS(
          SELECT 1
          FROM public.tournament_scorecard_marker_assignments ma
          WHERE ma.score_card_id=sc.id
            AND ma.status='active'
      );

    RETURN jsonb_build_object(
        'tournamentRoundId',p_tournament_round_id,
        'engine','team_stroke',
        'initialized',true,
        'cardCount',v_card_count,
        'sessionCount',v_session_count,
        'holesPerCard',v_hole_count,
        'holeScoreRows',v_hole_row_count,
        'activeMarkerAssignments',v_assignment_count,
        'cardsWithoutMarker',v_pending_marker_count
    );
END;
$function$;

COMMIT;
