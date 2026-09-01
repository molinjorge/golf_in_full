-- ============================================================================
-- MIGRACIÓN 209 FASE 6
-- A-Go-Go — captura digital, física y conciliación por equipo
-- Proyecto: Tee Central / GOLF IN FULL
--
-- PRINCIPIOS
-- - Una tarjeta = un equipo; un resultado por equipo/hoyo.
-- - Reutiliza sesiones, hole_scores, eventos, captura física y conciliación.
-- - A-Go-Go admite exclusivamente SCORE; PICKUP queda prohibido.
-- - Digital es opcional; tarjeta física continúa siendo obligatoria.
-- - Un integrante del equipo contrario actúa como marcador digital.
-- - Cualquier integrante vigente del equipo puede confirmar/disputar el score.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Helpers de identidad TEAM desde el snapshot oficial de Fase 5
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._jugador_es_integrante_tarjeta_equipo_209(
    p_score_card_id uuid,
    p_player_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
    SELECT EXISTS(
        SELECT 1
        FROM public.tournament_team_scorecard_snapshots ss
        CROSS JOIN LATERAL jsonb_array_elements(ss.members_snapshot) m
        WHERE ss.score_card_id=p_score_card_id
          AND NULLIF(m->>'playerId','')::uuid=p_player_id
    );
$$;

REVOKE ALL ON FUNCTION public._jugador_es_integrante_tarjeta_equipo_209(uuid,uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public._jugador_es_integrante_tarjeta_equipo_209(uuid,uuid)
TO service_role;

-- ----------------------------------------------------------------------------
-- 2. Inicialización TEAM: mismas tablas comunes, marcador circular por equipo.
--    Se elige un integrante del equipo marcador desde el snapshot oficial.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._inicializar_captura_scores_equipo_a_gogo_209(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
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
    ) INTO v_card_count,v_bad_cards
    FROM public.tournament_score_cards sc
    WHERE sc.emission_id=v_emission_id AND sc.status='issued';

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
        score_card_id,tournament_id,tournament_round_id,validation_id,status,holes_expected
    )
    SELECT sc.id,sc.tournament_id,sc.tournament_round_id,sc.validation_id,'ready',v_hole_count
    FROM public.tournament_score_cards sc
    WHERE sc.emission_id=v_emission_id AND sc.status='issued'
    ON CONFLICT(score_card_id) DO NOTHING;

    SELECT count(*) INTO v_session_count
    FROM public.tournament_scorecard_capture_sessions cs
    JOIN public.tournament_score_cards sc ON sc.id=cs.score_card_id
    WHERE sc.emission_id=v_emission_id AND sc.status='issued';

    INSERT INTO public.tournament_scorecard_hole_scores(
        capture_session_id,score_card_id,tournament_round_id,
        round_hole_snapshot_id,hole_number,play_sequence,result_type,status
    )
    SELECT cs.id,sc.id,sc.tournament_round_id,h.id,h.hole_number,
           row_number() OVER(
             PARTITION BY sc.id
             ORDER BY CASE WHEN h.hole_number>=g.hole_number THEN 0 ELSE 1 END,h.hole_number
           )::integer,
           'PENDING','pending'
    FROM public.tournament_score_cards sc
    JOIN public.tournament_scorecard_capture_sessions cs ON cs.score_card_id=sc.id
    JOIN public.tournament_round_start_validation_groups g
      ON g.id=sc.validation_group_id AND g.validation_id=sc.validation_id
    JOIN public.tournament_round_hole_snapshots h
      ON h.round_condition_snapshot_id=v_round_condition_snapshot_id
    WHERE sc.emission_id=v_emission_id AND sc.status='issued'
    ON CONFLICT(score_card_id,round_hole_snapshot_id) DO NOTHING;

    SELECT count(*) INTO v_hole_row_count
    FROM public.tournament_scorecard_hole_scores hs
    JOIN public.tournament_score_cards sc ON sc.id=hs.score_card_id
    WHERE sc.emission_id=v_emission_id AND sc.status='issued';

    IF v_hole_row_count<>v_card_count*v_hole_count THEN
        RAISE EXCEPTION 'La inicialización de hoyos TEAM quedó incompleta.';
    END IF;

    -- Marcador circular por TARJETA/EQUIPO dentro del grupo.
    -- Del equipo marcador se toma un integrante real del snapshot oficial.
    WITH group_cards AS (
        SELECT sc.validation_group_id,
               array_agg(sc.id ORDER BY u.order_in_group,sc.id) card_ids
        FROM public.tournament_score_cards sc
        JOIN public.tournament_round_start_validation_units u
          ON u.id=sc.validation_unit_id AND u.validation_id=sc.validation_id
        WHERE sc.emission_id=v_emission_id AND sc.status='issued'
        GROUP BY sc.validation_group_id
    ), proposed AS (
        SELECT gc.validation_group_id,
               gc.card_ids[i] target_card_id,
               gc.card_ids[CASE WHEN i=1 THEN array_length(gc.card_ids,1) ELSE i-1 END] marker_card_id,
               array_length(gc.card_ids,1) group_size
        FROM group_cards gc
        CROSS JOIN LATERAL generate_subscripts(gc.card_ids,1) s(i)
    ), marker_member AS (
        SELECT p.*,
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
            ORDER BY COALESCE((m->>'whsRank')::integer,2147483647),m->>'name'
            LIMIT 1
        ) mm ON true
    )
    INSERT INTO public.tournament_scorecard_marker_assignments(
        tournament_round_id,validation_group_id,score_card_id,marker_score_card_id,
        marker_player_id,marker_registration_id,assignment_source,
        valid_from_sequence,status,assigned_by
    )
    SELECT p_tournament_round_id,mm.validation_group_id,mm.target_card_id,mm.marker_card_id,
           mm.marker_player_id,mm.marker_registration_id,'circular_team',1,'active',v_admin_id
    FROM marker_member mm
    WHERE mm.group_size>=2
      AND mm.target_card_id<>mm.marker_card_id
      AND mm.marker_player_id IS NOT NULL
      AND mm.marker_registration_id IS NOT NULL
      AND NOT EXISTS(
          SELECT 1 FROM public.tournament_scorecard_marker_assignments ma
          WHERE ma.score_card_id=mm.target_card_id AND ma.status='active'
      );

    SELECT count(*) INTO v_assignment_count
    FROM public.tournament_scorecard_marker_assignments ma
    JOIN public.tournament_score_cards sc ON sc.id=ma.score_card_id
    WHERE sc.emission_id=v_emission_id AND ma.status='active';

    SELECT count(*) INTO v_pending_marker_count
    FROM public.tournament_score_cards sc
    WHERE sc.emission_id=v_emission_id AND sc.status='issued'
      AND NOT EXISTS(
        SELECT 1 FROM public.tournament_scorecard_marker_assignments ma
        WHERE ma.score_card_id=sc.id AND ma.status='active'
      );

    RETURN jsonb_build_object(
      'tournamentRoundId',p_tournament_round_id,'engine','team_stroke',
      'initialized',true,'cardCount',v_card_count,'sessionCount',v_session_count,
      'holesPerCard',v_hole_count,'holeScoreRows',v_hole_row_count,
      'activeMarkerAssignments',v_assignment_count,
      'cardsWithoutMarker',v_pending_marker_count
    );
END;
$$;

REVOKE ALL ON FUNCTION public._inicializar_captura_scores_equipo_a_gogo_209(uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public._inicializar_captura_scores_equipo_a_gogo_209(uuid)
TO authenticated,service_role;

-- Conservar inicializador individual y despachar por unidad.
ALTER FUNCTION public.inicializar_captura_scores_ronda(uuid)
RENAME TO _inicializar_captura_scores_ronda_individual_209;

CREATE OR REPLACE FUNCTION public.inicializar_captura_scores_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_unit_type text; v_engine text;
BEGIN
    SELECT sc.unit_type,v.scoring_engine
      INTO v_unit_type,v_engine
      FROM public.tournament_score_card_emissions e
      JOIN public.tournament_score_cards sc ON sc.emission_id=e.id AND sc.status='issued'
      JOIN public.tournament_round_start_validations v ON v.id=e.validation_id
     WHERE e.tournament_round_id=p_tournament_round_id AND e.status='issued'
     LIMIT 1;

    IF v_unit_type='team' AND v_engine='team_stroke' THEN
        RETURN public._inicializar_captura_scores_equipo_a_gogo_209(p_tournament_round_id);
    END IF;
    RETURN public._inicializar_captura_scores_ronda_individual_209(p_tournament_round_id);
END;
$$;

-- ----------------------------------------------------------------------------
-- 3. Digital TEAM: marcador contrario captura SCORE; integrante confirma/disputa.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_resultado_hoyo_equipo_a_gogo(
    p_score_card_id uuid,
    p_round_hole_snapshot_id uuid,
    p_gross_score integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_player_id uuid; v_card record; v_hole record; v_assignment record;
        v_old_type text; v_old_gross integer; v_event text; v_remaining integer;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501'; END IF;
    IF p_gross_score IS NULL OR p_gross_score<=0 THEN
        RAISE EXCEPTION 'A-Go-Go requiere SCORE gross mayor que cero.';
    END IF;
    v_player_id:=public._scorecard_current_player_id();
    IF v_player_id IS NULL THEN RAISE EXCEPTION 'Usuario sin jugador activo.' USING ERRCODE='42501'; END IF;

    SELECT sc.*,v.scoring_engine,v.participation_type INTO v_card
    FROM public.tournament_score_cards sc
    JOIN public.tournament_round_start_validations v ON v.id=sc.validation_id
    WHERE sc.id=p_score_card_id AND sc.status='issued';

    IF v_card.id IS NULL OR v_card.unit_type<>'team'
       OR v_card.scoring_engine<>'team_stroke' OR v_card.participation_type<>'equipo' THEN
        RAISE EXCEPTION 'La tarjeta no corresponde a A-Go-Go TEAM.';
    END IF;

    SELECT * INTO v_hole FROM public.tournament_scorecard_hole_scores
    WHERE score_card_id=p_score_card_id AND round_hole_snapshot_id=p_round_hole_snapshot_id
    FOR UPDATE;
    IF v_hole.id IS NULL THEN RAISE EXCEPTION 'Hoyo no inicializado para esta tarjeta.'; END IF;

    SELECT * INTO v_assignment
    FROM public.tournament_scorecard_marker_assignments ma
    WHERE ma.score_card_id=p_score_card_id AND ma.marker_player_id=v_player_id
      AND ma.status='active' AND ma.valid_from_sequence<=v_hole.play_sequence
      AND (ma.valid_to_sequence IS NULL OR ma.valid_to_sequence>=v_hole.play_sequence)
    ORDER BY ma.assigned_at DESC,ma.id DESC LIMIT 1;
    IF v_assignment.id IS NULL THEN
        RAISE EXCEPTION 'No eres el marcador vigente de este equipo para este hoyo.' USING ERRCODE='42501';
    END IF;
    IF v_hole.status='confirmed' THEN
        RAISE EXCEPTION 'El equipo ya confirmó este hoyo; requiere flujo del Comité.';
    END IF;

    v_old_type:=v_hole.result_type; v_old_gross:=v_hole.gross_score;
    v_event:=CASE WHEN v_hole.result_type='PENDING' THEN 'score_entered' ELSE 'score_corrected' END;

    UPDATE public.tournament_scorecard_hole_scores
       SET result_type='SCORE',gross_score=p_gross_score,status='entered',
           marker_assignment_id=v_assignment.id,entered_by_player_id=v_player_id,entered_at=now(),
           confirmed_by_player_id=NULL,confirmed_at=NULL,
           player_claimed_result_type=NULL,player_claimed_gross_score=NULL,
           dispute_note=NULL,disputed_at=NULL
     WHERE id=v_hole.id;

    INSERT INTO public.tournament_scorecard_events(
      score_card_id,hole_score_id,marker_assignment_id,event_type,actor_player_id,
      old_result_type,new_result_type,old_gross_score,new_gross_score
    ) VALUES(p_score_card_id,v_hole.id,v_assignment.id,v_event,v_player_id,
             v_old_type,'SCORE',v_old_gross,p_gross_score);

    UPDATE public.tournament_scorecard_capture_sessions
       SET status=CASE WHEN status='ready' THEN 'in_progress' ELSE status END,
           started_at=COALESCE(started_at,now())
     WHERE score_card_id=p_score_card_id;

    SELECT count(*) INTO v_remaining FROM public.tournament_scorecard_hole_scores
    WHERE score_card_id=p_score_card_id AND result_type='PENDING';
    IF v_remaining=0 THEN
      UPDATE public.tournament_scorecard_capture_sessions
      SET status='captured',started_at=COALESCE(started_at,now()),captured_at=COALESCE(captured_at,now())
      WHERE score_card_id=p_score_card_id;
    END IF;

    RETURN jsonb_build_object('holeScoreId',v_hole.id,'scoreCardId',p_score_card_id,
      'holeNumber',v_hole.hole_number,'playSequence',v_hole.play_sequence,
      'resultType','SCORE','grossScore',p_gross_score,'status','entered');
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_resultado_hoyo_equipo_a_gogo(uuid,uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.registrar_resultado_hoyo_equipo_a_gogo(uuid,uuid,integer) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.confirmar_score_hoyo_equipo_a_gogo(p_hole_score_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE v_player_id uuid; v_hole record;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501'; END IF;
 v_player_id:=public._scorecard_current_player_id();
 SELECT hs.*,sc.unit_type,v.scoring_engine INTO v_hole
 FROM public.tournament_scorecard_hole_scores hs
 JOIN public.tournament_score_cards sc ON sc.id=hs.score_card_id AND sc.status='issued'
 JOIN public.tournament_round_start_validations v ON v.id=sc.validation_id
 WHERE hs.id=p_hole_score_id FOR UPDATE OF hs;
 IF v_hole.id IS NULL OR v_hole.unit_type<>'team' OR v_hole.scoring_engine<>'team_stroke' THEN RAISE EXCEPTION 'Hoyo A-Go-Go no encontrado.'; END IF;
 IF NOT public._jugador_es_integrante_tarjeta_equipo_209(v_hole.score_card_id,v_player_id) THEN RAISE EXCEPTION 'Sólo un integrante del equipo puede confirmar.' USING ERRCODE='42501'; END IF;
 IF v_hole.status<>'entered' OR v_hole.result_type<>'SCORE' THEN RAISE EXCEPTION 'Hoyo no disponible para confirmación.'; END IF;
 UPDATE public.tournament_scorecard_hole_scores SET status='confirmed',confirmed_by_player_id=v_player_id,confirmed_at=now() WHERE id=p_hole_score_id;
 INSERT INTO public.tournament_scorecard_events(score_card_id,hole_score_id,marker_assignment_id,event_type,actor_player_id,old_result_type,new_result_type,old_gross_score,new_gross_score)
 VALUES(v_hole.score_card_id,v_hole.id,v_hole.marker_assignment_id,'player_confirmed',v_player_id,'SCORE','SCORE',v_hole.gross_score,v_hole.gross_score);
 RETURN jsonb_build_object('holeScoreId',v_hole.id,'scoreCardId',v_hole.score_card_id,'holeNumber',v_hole.hole_number,'resultType','SCORE','grossScore',v_hole.gross_score,'status','confirmed');
END; $$;

REVOKE ALL ON FUNCTION public.confirmar_score_hoyo_equipo_a_gogo(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.confirmar_score_hoyo_equipo_a_gogo(uuid) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.disputar_score_hoyo_equipo_a_gogo(
 p_hole_score_id uuid,p_claimed_gross_score integer,p_reason text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE v_player_id uuid; v_hole record;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501'; END IF;
 IF p_claimed_gross_score IS NULL OR p_claimed_gross_score<=0 THEN RAISE EXCEPTION 'El score reclamado debe ser mayor que cero.'; END IF;
 v_player_id:=public._scorecard_current_player_id();
 SELECT hs.*,sc.unit_type,v.scoring_engine INTO v_hole
 FROM public.tournament_scorecard_hole_scores hs
 JOIN public.tournament_score_cards sc ON sc.id=hs.score_card_id AND sc.status='issued'
 JOIN public.tournament_round_start_validations v ON v.id=sc.validation_id
 WHERE hs.id=p_hole_score_id FOR UPDATE OF hs;
 IF v_hole.id IS NULL OR v_hole.unit_type<>'team' OR v_hole.scoring_engine<>'team_stroke' THEN RAISE EXCEPTION 'Hoyo A-Go-Go no encontrado.'; END IF;
 IF NOT public._jugador_es_integrante_tarjeta_equipo_209(v_hole.score_card_id,v_player_id) THEN RAISE EXCEPTION 'Sólo un integrante del equipo puede disputar.' USING ERRCODE='42501'; END IF;
 IF v_hole.status<>'entered' OR v_hole.result_type<>'SCORE' THEN RAISE EXCEPTION 'Hoyo no disponible para disputa.'; END IF;
 IF p_claimed_gross_score=v_hole.gross_score THEN RAISE EXCEPTION 'El score reclamado coincide con el capturado.'; END IF;
 UPDATE public.tournament_scorecard_hole_scores SET status='disputed',player_claimed_result_type='SCORE',player_claimed_gross_score=p_claimed_gross_score,dispute_note=NULLIF(btrim(COALESCE(p_reason,'')),''),disputed_at=now(),confirmed_by_player_id=NULL,confirmed_at=NULL WHERE id=p_hole_score_id;
 INSERT INTO public.tournament_scorecard_events(score_card_id,hole_score_id,marker_assignment_id,event_type,actor_player_id,old_result_type,new_result_type,old_gross_score,new_gross_score,claimed_result_type,claimed_gross_score,reason)
 VALUES(v_hole.score_card_id,v_hole.id,v_hole.marker_assignment_id,'player_disputed',v_player_id,'SCORE','SCORE',v_hole.gross_score,v_hole.gross_score,'SCORE',p_claimed_gross_score,NULLIF(btrim(COALESCE(p_reason,'')),''));
 RETURN jsonb_build_object('holeScoreId',v_hole.id,'scoreCardId',v_hole.score_card_id,'holeNumber',v_hole.hole_number,'resultType','SCORE','grossScore',v_hole.gross_score,'teamClaimedGrossScore',p_claimed_gross_score,'status','disputed');
END; $$;

REVOKE ALL ON FUNCTION public.disputar_score_hoyo_equipo_a_gogo(uuid,integer,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.disputar_score_hoyo_equipo_a_gogo(uuid,integer,text) TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 4. Física TEAM: reutiliza recepción/finalización común y prohíbe PICKUP.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guardar_resultado_fisico_hoyo_equipo_a_gogo(
 p_score_card_id uuid,p_round_hole_snapshot_id uuid,p_gross_score integer
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE v_card record;
BEGIN
 IF p_gross_score IS NULL OR p_gross_score<=0 THEN RAISE EXCEPTION 'A-Go-Go físico requiere gross mayor que cero.'; END IF;
 SELECT sc.id,sc.unit_type,v.scoring_engine INTO v_card
 FROM public.tournament_score_cards sc JOIN public.tournament_round_start_validations v ON v.id=sc.validation_id
 WHERE sc.id=p_score_card_id AND sc.status='issued';
 IF v_card.id IS NULL OR v_card.unit_type<>'team' OR v_card.scoring_engine<>'team_stroke' THEN RAISE EXCEPTION 'Tarjeta A-Go-Go TEAM no encontrada.'; END IF;
 RETURN public.guardar_resultado_fisico_hoyo(p_score_card_id,p_round_hole_snapshot_id,'SCORE',p_gross_score);
END; $$;

REVOKE ALL ON FUNCTION public.guardar_resultado_fisico_hoyo_equipo_a_gogo(uuid,uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.guardar_resultado_fisico_hoyo_equipo_a_gogo(uuid,uuid,integer) TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 5. Conciliación TEAM: motor común, pero resolución siempre SCORE.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolver_hoyo_conciliacion_a_gogo(
 p_score_card_id uuid,p_round_hole_snapshot_id uuid,p_resolution_source text,
 p_manual_gross_score integer DEFAULT NULL,p_reason text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE v_card record; v_result jsonb;
BEGIN
 SELECT sc.id,sc.unit_type,v.scoring_engine INTO v_card
 FROM public.tournament_score_cards sc JOIN public.tournament_round_start_validations v ON v.id=sc.validation_id
 WHERE sc.id=p_score_card_id AND sc.status='issued';
 IF v_card.id IS NULL OR v_card.unit_type<>'team' OR v_card.scoring_engine<>'team_stroke' THEN RAISE EXCEPTION 'Tarjeta A-Go-Go TEAM no encontrada.'; END IF;
 v_result:=public.resolver_hoyo_conciliacion_resultado(
   p_score_card_id,p_round_hole_snapshot_id,p_resolution_source,
   CASE WHEN upper(btrim(COALESCE(p_resolution_source,'')))='MANUAL' THEN 'SCORE' ELSE NULL END,
   p_manual_gross_score,p_reason
 );
 IF v_result->>'resolvedResultType'<>'SCORE' THEN
   RAISE EXCEPTION 'A-Go-Go sólo admite resolución SCORE; PICKUP está prohibido.' USING ERRCODE='0A000';
 END IF;
 RETURN v_result;
END; $$;

REVOKE ALL ON FUNCTION public.resolver_hoyo_conciliacion_a_gogo(uuid,uuid,text,integer,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.resolver_hoyo_conciliacion_a_gogo(uuid,uuid,text,integer,text) TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 6. Blindaje adicional: incluso si alguien llama las RPC genéricas,
--    PICKUP nunca puede persistirse para una tarjeta team_stroke.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._bloquear_pickup_a_gogo_209()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $$
DECLARE v_engine text;
BEGIN
 IF (TG_TABLE_NAME='tournament_scorecard_hole_scores' AND NEW.result_type='PICKUP')
    OR (TG_TABLE_NAME='tournament_scorecard_physical_hole_scores' AND NEW.physical_result_type='PICKUP') THEN
   SELECT v.scoring_engine INTO v_engine
   FROM public.tournament_score_cards sc JOIN public.tournament_round_start_validations v ON v.id=sc.validation_id
   WHERE sc.id=NEW.score_card_id;
   IF v_engine='team_stroke' THEN
     RAISE EXCEPTION 'PICKUP no está permitido en A-Go-Go.' USING ERRCODE='0A000';
   END IF;
 END IF;
 RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_bloquear_pickup_a_gogo_digital ON public.tournament_scorecard_hole_scores;
CREATE TRIGGER trg_bloquear_pickup_a_gogo_digital
BEFORE INSERT OR UPDATE OF result_type ON public.tournament_scorecard_hole_scores
FOR EACH ROW EXECUTE FUNCTION public._bloquear_pickup_a_gogo_209();

DROP TRIGGER IF EXISTS trg_bloquear_pickup_a_gogo_fisico ON public.tournament_scorecard_physical_hole_scores;
CREATE TRIGGER trg_bloquear_pickup_a_gogo_fisico
BEFORE INSERT OR UPDATE OF physical_result_type ON public.tournament_scorecard_physical_hole_scores
FOR EACH ROW EXECUTE FUNCTION public._bloquear_pickup_a_gogo_209();

COMMIT;
