-- TEE CENTRAL / GOLF IN FULL
-- Migración 248
-- Blindaje de estados de revisión A-Go-Go TEAM:
-- 1) un hoyo DISPUTED no puede ser sobrescrito por el marcador;
-- 2) SELF_TEAM no admite confirmación ni disputa jugador-marcador.
--
-- Alcance deliberadamente limitado a A-Go-Go TEAM/team_stroke.
-- No modifica PLAYER, Stroke Play ni Stableford.

BEGIN;

CREATE OR REPLACE FUNCTION public.registrar_resultado_hoyo_equipo_a_gogo(
    p_score_card_id uuid,
    p_round_hole_snapshot_id uuid,
    p_gross_score integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_player_id uuid;
    v_card record;
    v_hole record;
    v_assignment record;
    v_old_type text;
    v_old_gross integer;
    v_event text;
    v_remaining integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_gross_score IS NULL OR p_gross_score<=0 THEN
        RAISE EXCEPTION 'A-Go-Go requiere SCORE gross mayor que cero.';
    END IF;

    v_player_id:=public._scorecard_current_player_id();
    IF v_player_id IS NULL THEN
        RAISE EXCEPTION 'Usuario sin jugador activo.' USING ERRCODE='42501';
    END IF;

    SELECT sc.*,v.scoring_engine,v.participation_type
      INTO v_card
      FROM public.tournament_score_cards sc
      JOIN public.tournament_round_start_validations v
        ON v.id=sc.validation_id
     WHERE sc.id=p_score_card_id
       AND sc.status='issued';

    IF v_card.id IS NULL
       OR v_card.unit_type<>'team'
       OR v_card.scoring_engine<>'team_stroke'
       OR v_card.participation_type<>'equipo'
    THEN
        RAISE EXCEPTION 'La tarjeta no corresponde a A-Go-Go TEAM.';
    END IF;

    SELECT *
      INTO v_hole
      FROM public.tournament_scorecard_hole_scores
     WHERE score_card_id=p_score_card_id
       AND round_hole_snapshot_id=p_round_hole_snapshot_id
     FOR UPDATE;

    IF v_hole.id IS NULL THEN
        RAISE EXCEPTION 'Hoyo no inicializado para esta tarjeta.';
    END IF;

    SELECT *
      INTO v_assignment
      FROM public.tournament_scorecard_marker_assignments ma
     WHERE ma.score_card_id=p_score_card_id
       AND ma.marker_player_id=v_player_id
       AND ma.status='active'
       AND ma.valid_from_sequence<=v_hole.play_sequence
       AND (ma.valid_to_sequence IS NULL OR ma.valid_to_sequence>=v_hole.play_sequence)
     ORDER BY ma.assigned_at DESC,ma.id DESC
     LIMIT 1;

    IF v_assignment.id IS NULL THEN
        RAISE EXCEPTION 'No eres el marcador vigente de este equipo para este hoyo.'
            USING ERRCODE='42501';
    END IF;

    IF v_hole.status='confirmed' THEN
        RAISE EXCEPTION 'El equipo ya confirmó este hoyo; requiere flujo del Comité.'
            USING ERRCODE='55000';
    END IF;

    -- Migración 248: una disputa activa ya no puede ser borrada por una
    -- nueva captura del marcador. Debe resolverse por el flujo de Comité/
    -- conciliación correspondiente.
    IF v_hole.status='disputed' THEN
        RAISE EXCEPTION 'Este hoyo está en disputa; no puede ser sobrescrito por el marcador y requiere resolución del Comité.'
            USING ERRCODE='55000';
    END IF;

    v_old_type:=v_hole.result_type;
    v_old_gross:=v_hole.gross_score;
    v_event:=CASE
        WHEN v_hole.result_type='PENDING' THEN 'score_entered'
        ELSE 'score_corrected'
    END;

    UPDATE public.tournament_scorecard_hole_scores
       SET result_type='SCORE',
           gross_score=p_gross_score,
           status='entered',
           marker_assignment_id=v_assignment.id,
           entered_by_player_id=v_player_id,
           entered_at=now(),
           confirmed_by_player_id=NULL,
           confirmed_at=NULL,
           player_claimed_result_type=NULL,
           player_claimed_gross_score=NULL,
           dispute_note=NULL,
           disputed_at=NULL
     WHERE id=v_hole.id;

    INSERT INTO public.tournament_scorecard_events(
        score_card_id,
        hole_score_id,
        marker_assignment_id,
        event_type,
        actor_player_id,
        old_result_type,
        new_result_type,
        old_gross_score,
        new_gross_score
    )
    VALUES(
        p_score_card_id,
        v_hole.id,
        v_assignment.id,
        v_event,
        v_player_id,
        v_old_type,
        'SCORE',
        v_old_gross,
        p_gross_score
    );

    UPDATE public.tournament_scorecard_capture_sessions
       SET status=CASE WHEN status='ready' THEN 'in_progress' ELSE status END,
           started_at=COALESCE(started_at,now())
     WHERE score_card_id=p_score_card_id;

    SELECT count(*)
      INTO v_remaining
      FROM public.tournament_scorecard_hole_scores
     WHERE score_card_id=p_score_card_id
       AND result_type='PENDING';

    IF v_remaining=0 THEN
        UPDATE public.tournament_scorecard_capture_sessions
           SET status='captured',
               started_at=COALESCE(started_at,now()),
               captured_at=COALESCE(captured_at,now())
         WHERE score_card_id=p_score_card_id;
    END IF;

    RETURN jsonb_build_object(
        'holeScoreId',v_hole.id,
        'scoreCardId',p_score_card_id,
        'holeNumber',v_hole.hole_number,
        'playSequence',v_hole.play_sequence,
        'resultType','SCORE',
        'grossScore',p_gross_score,
        'status','entered'
    );
END;
$function$;


CREATE OR REPLACE FUNCTION public.confirmar_score_hoyo_equipo_a_gogo(
    p_hole_score_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_player_id uuid;
    v_hole record;
    v_assignment_source text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    v_player_id:=public._scorecard_current_player_id();

    SELECT hs.*,sc.unit_type,v.scoring_engine
      INTO v_hole
      FROM public.tournament_scorecard_hole_scores hs
      JOIN public.tournament_score_cards sc
        ON sc.id=hs.score_card_id
       AND sc.status='issued'
      JOIN public.tournament_round_start_validations v
        ON v.id=sc.validation_id
     WHERE hs.id=p_hole_score_id
     FOR UPDATE OF hs;

    IF v_hole.id IS NULL
       OR v_hole.unit_type<>'team'
       OR v_hole.scoring_engine<>'team_stroke'
    THEN
        RAISE EXCEPTION 'Hoyo A-Go-Go no encontrado.';
    END IF;

    IF NOT public._jugador_es_integrante_tarjeta_equipo_209(
        v_hole.score_card_id,
        v_player_id
    ) THEN
        RAISE EXCEPTION 'Sólo un integrante del equipo puede confirmar.'
            USING ERRCODE='42501';
    END IF;

    SELECT ma.assignment_source
      INTO v_assignment_source
      FROM public.tournament_scorecard_marker_assignments ma
     WHERE ma.id=v_hole.marker_assignment_id
     LIMIT 1;

    -- Migración 248: SELF_TEAM es autocaptura. No existe una segunda parte
    -- independiente que deba confirmar la captura.
    IF v_assignment_source='self_team' THEN
        RAISE EXCEPTION 'La autocaptura TEAM no requiere confirmación.'
            USING ERRCODE='55000';
    END IF;

    IF v_hole.status<>'entered' OR v_hole.result_type<>'SCORE' THEN
        RAISE EXCEPTION 'Hoyo no disponible para confirmación.';
    END IF;

    UPDATE public.tournament_scorecard_hole_scores
       SET status='confirmed',
           confirmed_by_player_id=v_player_id,
           confirmed_at=now()
     WHERE id=p_hole_score_id;

    INSERT INTO public.tournament_scorecard_events(
        score_card_id,
        hole_score_id,
        marker_assignment_id,
        event_type,
        actor_player_id,
        old_result_type,
        new_result_type,
        old_gross_score,
        new_gross_score
    )
    VALUES(
        v_hole.score_card_id,
        v_hole.id,
        v_hole.marker_assignment_id,
        'player_confirmed',
        v_player_id,
        'SCORE',
        'SCORE',
        v_hole.gross_score,
        v_hole.gross_score
    );

    RETURN jsonb_build_object(
        'holeScoreId',v_hole.id,
        'scoreCardId',v_hole.score_card_id,
        'holeNumber',v_hole.hole_number,
        'resultType','SCORE',
        'grossScore',v_hole.gross_score,
        'status','confirmed'
    );
END;
$function$;


CREATE OR REPLACE FUNCTION public.disputar_score_hoyo_equipo_a_gogo(
    p_hole_score_id uuid,
    p_claimed_gross_score integer,
    p_reason text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_player_id uuid;
    v_hole record;
    v_assignment_source text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_claimed_gross_score IS NULL OR p_claimed_gross_score<=0 THEN
        RAISE EXCEPTION 'El score reclamado debe ser mayor que cero.';
    END IF;

    v_player_id:=public._scorecard_current_player_id();

    SELECT hs.*,sc.unit_type,v.scoring_engine
      INTO v_hole
      FROM public.tournament_scorecard_hole_scores hs
      JOIN public.tournament_score_cards sc
        ON sc.id=hs.score_card_id
       AND sc.status='issued'
      JOIN public.tournament_round_start_validations v
        ON v.id=sc.validation_id
     WHERE hs.id=p_hole_score_id
     FOR UPDATE OF hs;

    IF v_hole.id IS NULL
       OR v_hole.unit_type<>'team'
       OR v_hole.scoring_engine<>'team_stroke'
    THEN
        RAISE EXCEPTION 'Hoyo A-Go-Go no encontrado.';
    END IF;

    IF NOT public._jugador_es_integrante_tarjeta_equipo_209(
        v_hole.score_card_id,
        v_player_id
    ) THEN
        RAISE EXCEPTION 'Sólo un integrante del equipo puede disputar.'
            USING ERRCODE='42501';
    END IF;

    SELECT ma.assignment_source
      INTO v_assignment_source
      FROM public.tournament_scorecard_marker_assignments ma
     WHERE ma.id=v_hole.marker_assignment_id
     LIMIT 1;

    -- Migración 248: en SELF_TEAM marcador y equipo son la misma unidad.
    -- Una corrección posterior corresponde al Comité/conciliación, no a una
    -- disputa entre partes inexistentes.
    IF v_assignment_source='self_team' THEN
        RAISE EXCEPTION 'La autocaptura TEAM no admite disputa jugador-marcador; una corrección requiere el flujo del Comité.'
            USING ERRCODE='55000';
    END IF;

    IF v_hole.status<>'entered' OR v_hole.result_type<>'SCORE' THEN
        RAISE EXCEPTION 'Hoyo no disponible para disputa.';
    END IF;

    IF p_claimed_gross_score=v_hole.gross_score THEN
        RAISE EXCEPTION 'El score reclamado coincide con el capturado.';
    END IF;

    UPDATE public.tournament_scorecard_hole_scores
       SET status='disputed',
           player_claimed_result_type='SCORE',
           player_claimed_gross_score=p_claimed_gross_score,
           dispute_note=NULLIF(btrim(COALESCE(p_reason,'')),''),
           disputed_at=now(),
           confirmed_by_player_id=NULL,
           confirmed_at=NULL
     WHERE id=p_hole_score_id;

    INSERT INTO public.tournament_scorecard_events(
        score_card_id,
        hole_score_id,
        marker_assignment_id,
        event_type,
        actor_player_id,
        old_result_type,
        new_result_type,
        old_gross_score,
        new_gross_score,
        claimed_result_type,
        claimed_gross_score,
        reason
    )
    VALUES(
        v_hole.score_card_id,
        v_hole.id,
        v_hole.marker_assignment_id,
        'player_disputed',
        v_player_id,
        'SCORE',
        'SCORE',
        v_hole.gross_score,
        v_hole.gross_score,
        'SCORE',
        p_claimed_gross_score,
        NULLIF(btrim(COALESCE(p_reason,'')),'')
    );

    RETURN jsonb_build_object(
        'holeScoreId',v_hole.id,
        'scoreCardId',v_hole.score_card_id,
        'holeNumber',v_hole.hole_number,
        'resultType','SCORE',
        'grossScore',v_hole.gross_score,
        'teamClaimedGrossScore',p_claimed_gross_score,
        'status','disputed'
    );
END;
$function$;

-- Mantener el mismo perímetro de ejecución de los RPC públicos.
REVOKE ALL ON FUNCTION public.registrar_resultado_hoyo_equipo_a_gogo(uuid,uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.registrar_resultado_hoyo_equipo_a_gogo(uuid,uuid,integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.registrar_resultado_hoyo_equipo_a_gogo(uuid,uuid,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_resultado_hoyo_equipo_a_gogo(uuid,uuid,integer) TO service_role;

REVOKE ALL ON FUNCTION public.confirmar_score_hoyo_equipo_a_gogo(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.confirmar_score_hoyo_equipo_a_gogo(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.confirmar_score_hoyo_equipo_a_gogo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirmar_score_hoyo_equipo_a_gogo(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.disputar_score_hoyo_equipo_a_gogo(uuid,integer,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.disputar_score_hoyo_equipo_a_gogo(uuid,integer,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.disputar_score_hoyo_equipo_a_gogo(uuid,integer,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.disputar_score_hoyo_equipo_a_gogo(uuid,integer,text) TO service_role;

COMMIT;
