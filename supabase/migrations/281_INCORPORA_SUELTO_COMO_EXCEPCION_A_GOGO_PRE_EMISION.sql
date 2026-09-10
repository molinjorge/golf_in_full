-- TEE CENTRAL / GOLF IN FULL
-- Migración 281
-- Incorpora un jugador suelto a un equipo completo como la única excepción +1
-- A-Go-Go, post-Freeze y antes de START_TOURNAMENT.
-- Alcance deliberado de esta fase: antes de la emisión oficial de tarjetas.

BEGIN;

CREATE OR REPLACE FUNCTION public.incorporar_suelto_como_excepcion_a_gogo_281(
    p_registration_id uuid,
    p_target_team_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_reg public.tournament_registrations%ROWTYPE;
    v_t public.tournaments%ROWTYPE;
    v_source_team public.tournament_teams%ROWTYPE;
    v_target_team public.tournament_teams%ROWTYPE;
    v_admin_id uuid;
    v_freeze_id uuid;
    v_format record;
    v_detector_before jsonb;
    v_detector_after jsonb;
    v_source_count integer;
    v_target_count integer;
    v_old_validation_ids uuid[] := ARRAY[]::uuid[];
    v_old_validation record;
    v_hcp_target jsonb;
    v_preview jsonb;
    v_validation_result jsonb;
    v_round_results jsonb := '[]'::jsonb;
    v_change_id uuid;
    v_round record;
    v_groups_deactivated integer := 0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_registration_id IS NULL OR p_target_team_id IS NULL THEN
        RAISE EXCEPTION 'Debes indicar la inscripción suelta y el equipo destino.'
            USING ERRCODE='22023';
    END IF;

    IF length(btrim(COALESCE(p_reason,''))) < 5 THEN
        RAISE EXCEPTION 'El motivo debe contener al menos 5 caracteres.'
            USING ERRCODE='22023';
    END IF;

    SELECT * INTO v_reg
    FROM public.tournament_registrations
    WHERE id=p_registration_id
    FOR UPDATE;

    IF v_reg.id IS NULL OR NOT v_reg.activo OR v_reg.tournament_team_id IS NULL THEN
        RAISE EXCEPTION 'La inscripción no existe, está inactiva o no pertenece a un equipo.'
            USING ERRCODE='P0002';
    END IF;

    SELECT * INTO v_t
    FROM public.tournaments
    WHERE id=v_reg.tournament_id AND activo=true
    FOR UPDATE;

    IF v_t.id IS NULL THEN
        RAISE EXCEPTION 'El torneo no existe o está inactivo.' USING ERRCODE='P0002';
    END IF;

    IF v_t.estatus::text IN ('en_curso','finalizado','cancelado') THEN
        RAISE EXCEPTION 'El torneo ya inició o terminó. La composición competitiva ya no puede modificarse.'
            USING ERRCODE='55000';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_t.id) THEN
        RAISE EXCEPTION 'No tienes permiso para resolver la composición de este torneo.'
            USING ERRCODE='42501';
    END IF;

    SELECT au.id INTO v_admin_id
    FROM public.admin_users au
    WHERE au.auth_user_id=auth.uid() AND au.activo=true
    ORDER BY au.id LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE='42501';
    END IF;

    SELECT tf.code,
           tf.tipo_participacion::text AS participation_type,
           tf.scoring_engine::text AS scoring_engine
    INTO v_format
    FROM public.tournament_formats tf
    WHERE tf.id=v_t.tournament_format_id AND tf.activo=true;

    IF v_format.code IS DISTINCT FROM 'A_GOGO'
       OR v_format.participation_type IS DISTINCT FROM 'equipo'
       OR v_format.scoring_engine IS DISTINCT FROM 'team_stroke' THEN
        RAISE EXCEPTION 'Este procedimiento sólo aplica a A-Go-Go TEAM (A_GOGO/equipo/team_stroke).'
            USING ERRCODE='22023';
    END IF;

    IF v_t.jugadores_por_equipo IS NULL OR v_t.jugadores_por_equipo < 2 THEN
        RAISE EXCEPTION 'El torneo no tiene un tamaño normal de equipo válido.'
            USING ERRCODE='23514';
    END IF;

    IF v_t.jugadores_por_equipo + 1 > 4 THEN
        RAISE EXCEPTION 'La excepción +1 excedería el máximo absoluto de 4 jugadores.'
            USING ERRCODE='23514';
    END IF;

    SELECT f.id INTO v_freeze_id
    FROM public.tournament_condition_freezes f
    WHERE f.tournament_id=v_t.id
    ORDER BY f.frozen_at DESC LIMIT 1;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION 'El torneo todavía no está congelado; utiliza el flujo normal de composición.'
            USING ERRCODE='55000';
    END IF;

    -- Esta fase no modifica tarjetas ya emitidas. Ese caso requiere su propio
    -- contrato para retirar la tarjeta del equipo origen y resolver markers.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_score_card_emissions e
        WHERE e.tournament_id=v_t.id AND e.status='issued'
    ) THEN
        RAISE EXCEPTION 'Ya existen tarjetas oficiales emitidas. La excepción +1 post-emisión se resolverá mediante el flujo específico posterior.'
            USING ERRCODE='55000';
    END IF;

    PERFORM pg_advisory_xact_lock(
        LEAST(
            hashtextextended(v_reg.tournament_team_id::text,281),
            hashtextextended(p_target_team_id::text,281)
        )
    );
    PERFORM pg_advisory_xact_lock(
        GREATEST(
            hashtextextended(v_reg.tournament_team_id::text,281),
            hashtextextended(p_target_team_id::text,281)
        )
    );

    SELECT * INTO v_source_team
    FROM public.tournament_teams tt
    WHERE tt.id=v_reg.tournament_team_id
      AND tt.tournament_id=v_t.id
      AND tt.activo=true
    FOR UPDATE;

    SELECT * INTO v_target_team
    FROM public.tournament_teams tt
    WHERE tt.id=p_target_team_id
      AND tt.tournament_id=v_t.id
      AND tt.activo=true
    FOR UPDATE;

    IF v_source_team.id IS NULL OR v_target_team.id IS NULL THEN
        RAISE EXCEPTION 'El equipo origen o destino no existe, está inactivo o pertenece a otro torneo.'
            USING ERRCODE='P0002';
    END IF;

    IF v_source_team.id=v_target_team.id THEN
        RAISE EXCEPTION 'El equipo destino debe ser distinto del equipo incompleto origen.'
            USING ERRCODE='22023';
    END IF;

    IF v_source_team.tournament_category_id IS DISTINCT FROM v_target_team.tournament_category_id THEN
        RAISE EXCEPTION 'El equipo origen y el destino pertenecen a categorías distintas.'
            USING ERRCODE='23514';
    END IF;

    SELECT count(*)::integer INTO v_source_count
    FROM public.tournament_registrations r
    WHERE r.tournament_id=v_t.id
      AND r.tournament_team_id=v_source_team.id
      AND r.activo=true;

    SELECT count(*)::integer INTO v_target_count
    FROM public.tournament_registrations r
    WHERE r.tournament_id=v_t.id
      AND r.tournament_team_id=v_target_team.id
      AND r.activo=true;

    IF v_source_count<>1 THEN
        RAISE EXCEPTION 'El jugador debe ser el único integrante activo de su equipo; el equipo origen tiene % activos.',v_source_count
            USING ERRCODE='23514';
    END IF;

    IF v_target_count<>v_t.jugadores_por_equipo THEN
        RAISE EXCEPTION 'El equipo destino debe tener exactamente el tamaño normal configurado (%); actualmente tiene %.',v_t.jugadores_por_equipo,v_target_count
            USING ERRCODE='23514';
    END IF;

    v_detector_before:=public.obtener_estado_equipos_incompletos_a_gogo_274(v_t.id);

    IF COALESCE((v_detector_before->>'exceptionTeamCount')::integer,0)<>0 THEN
        RAISE EXCEPTION 'Ya existe un equipo con excepción +1. No puede crearse una segunda excepción.'
            USING ERRCODE='23514';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(COALESCE(v_detector_before->'loosePlayers','[]'::jsonb)) x
        WHERE NULLIF(x->>'registrationId','')::uuid=v_reg.id
          AND NULLIF(x->>'teamId','')::uuid=v_source_team.id
    ) THEN
        RAISE EXCEPTION 'La inscripción seleccionada no está reconocida por el detector como jugador suelto.'
            USING ERRCODE='23514';
    END IF;

    SELECT COALESCE(array_agg(v.id ORDER BY v.tournament_round_id),ARRAY[]::uuid[])
    INTO v_old_validation_ids
    FROM public.tournament_round_start_validations v
    WHERE v.tournament_id=v_t.id
      AND v.status='validated'
      AND v.start_format='shotgun'
      AND v.participation_type='equipo'
      AND v.scoring_engine='team_stroke';

    IF EXISTS (
        SELECT 1
        FROM public.tournament_round_start_validations v
        WHERE v.tournament_id=v_t.id
          AND v.status='validated'
          AND (
              v.start_format IS DISTINCT FROM 'shotgun'
              OR v.participation_type IS DISTINCT FROM 'equipo'
              OR v.scoring_engine IS DISTINCT FROM 'team_stroke'
          )
    ) THEN
        RAISE EXCEPTION 'Existe una validación activa fuera del motor A-Go-Go Shotgun.'
            USING ERRCODE='55000';
    END IF;

    -- Reabrir primero las validaciones para poder retirar lógicamente al
    -- equipo origen de sus asignaciones de salida.
    IF cardinality(v_old_validation_ids)>0 THEN
        PERFORM set_config('app.reabrir_validacion_salida_ronda','true',true);

        UPDATE public.tournament_round_start_validations
        SET status='reopened',
            reopened_at=now(),
            reopened_by=v_admin_id,
            reopen_reason='Excepción +1 A-Go-Go 281: '||btrim(p_reason)
        WHERE id=ANY(v_old_validation_ids);
    END IF;

    PERFORM set_config('app.a_gogo_composition_override','true',true);

    -- El jugador conserva su inscripción y pasa al equipo destino.
    UPDATE public.tournament_registrations
    SET tournament_team_id=v_target_team.id
    WHERE id=v_reg.id;

    UPDATE public.tournament_team_roster_slots
    SET tournament_team_id=v_target_team.id,
        updated_at=now()
    WHERE tournament_registration_id=v_reg.id
      AND status='converted';

    -- El equipo origen queda histórico/no competitivo, no se elimina.
    UPDATE public.tournament_teams
    SET activo=false
    WHERE id=v_source_team.id;

    -- Retirar sus asignaciones lógicas de salida. No se mueve el equipo
    -- destino de su salida actual.
    UPDATE public.tournament_group_teams gt
    SET activo=false
    WHERE gt.tournament_team_id=v_source_team.id
      AND gt.activo=true;

    -- Si una agrupación quedó sin unidades competitivas, conservarla como
    -- histórica pero inactiva para que no bloquee una nueva validación.
    WITH empty_groups AS (
        SELECT g.id
        FROM public.tournament_groups g
        JOIN public.tournament_round_shifts rs
          ON rs.id=g.tournament_round_shift_id
         AND rs.activo=true
        WHERE rs.tournament_id=v_t.id
          AND g.activo=true
          AND NOT EXISTS (
              SELECT 1 FROM public.tournament_group_teams gt
              WHERE gt.tournament_group_id=g.id AND gt.activo=true
          )
    )
    UPDATE public.tournament_groups g
    SET activo=false
    FROM empty_groups eg
    WHERE g.id=eg.id;

    GET DIAGNOSTICS v_groups_deactivated=ROW_COUNT;

    INSERT INTO public.tournament_team_composition_changes(
        tournament_id,tournament_registration_id,player_id,change_type,
        old_team_id,new_team_id,reason,changed_by_admin_id,freeze_id,metadata
    ) VALUES (
        v_t.id,v_reg.id,v_reg.player_id,'team_reassignment',
        v_source_team.id,v_target_team.id,btrim(p_reason),v_admin_id,v_freeze_id,
        jsonb_build_object(
            'phase','281_LOOSE_TO_SINGLE_PLUS_ONE_PRE_EMISSION',
            'postFreeze',true,
            'preStartTournament',true,
            'preEmission',true,
            'sourceTeamRetired',true,
            'targetCountBefore',v_target_count,
            'targetCountAfter',v_target_count+1,
            'configuredTeamSize',v_t.jugadores_por_equipo,
            'groupsDeactivated',v_groups_deactivated,
            'physicalTargetStartPreserved',true,
            'detectorBefore',v_detector_before
        )
    ) RETURNING id INTO v_change_id;

    -- Rondas que no tenían validación activa: sólo cambia el HCP del destino.
    FOR v_round IN
        SELECT r.id
        FROM public.tournament_rounds r
        WHERE r.tournament_id=v_t.id
          AND r.activo=true
          AND NOT EXISTS (
              SELECT 1
              FROM public.tournament_round_start_validations ov
              WHERE ov.id=ANY(v_old_validation_ids)
                AND ov.tournament_round_id=r.id
          )
        ORDER BY r.numero_ronda,r.fecha,r.id
    LOOP
        v_hcp_target:=public.recalcular_handicap_equipo_a_gogo(v_round.id,v_target_team.id);
        v_round_results:=v_round_results||jsonb_build_array(jsonb_build_object(
            'tournamentRoundId',v_round.id,
            'targetTeamHandicap',v_hcp_target,
            'revalidated',false
        ));
    END LOOP;

    -- Rondas que estaban validadas: recalcular sólo destino y reconstruir
    -- el snapshot lógico sin el equipo origen retirado.
    FOR v_old_validation IN
        SELECT *
        FROM public.tournament_round_start_validations v
        WHERE v.id=ANY(v_old_validation_ids)
        ORDER BY v.tournament_round_id
    LOOP
        v_hcp_target:=public.recalcular_handicap_equipo_a_gogo(
            v_old_validation.tournament_round_id,
            v_target_team.id
        );

        v_preview:=public.previsualizar_validacion_salidas_ronda(
            v_old_validation.tournament_round_id
        );

        IF NOT COALESCE((v_preview->>'ready')::boolean,false) THEN
            RAISE EXCEPTION 'La incorporación +1 dejaría la ronda no validable y fue revertida.'
                USING ERRCODE='23514',DETAIL=(v_preview->'errors')::text;
        END IF;

        v_validation_result:=public.validar_salidas_ronda(
            v_old_validation.tournament_round_id
        );

        v_round_results:=v_round_results||jsonb_build_array(jsonb_build_object(
            'tournamentRoundId',v_old_validation.tournament_round_id,
            'oldValidationId',v_old_validation.id,
            'oldValidationVersion',v_old_validation.version,
            'targetTeamHandicap',v_hcp_target,
            'validation',v_validation_result,
            'revalidated',true
        ));
    END LOOP;

    v_detector_after:=public.obtener_estado_equipos_incompletos_a_gogo_274(v_t.id);

    IF COALESCE((v_detector_after->>'exceptionTeamCount')::integer,0)<>1 THEN
        RAISE EXCEPTION 'La operación no produjo exactamente una excepción +1 y fue revertida.'
            USING ERRCODE='23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(COALESCE(v_detector_after->'exceptionTeams','[]'::jsonb)) e
        WHERE NULLIF(e->>'teamId','')::uuid=v_target_team.id
    ) IS FALSE THEN
        RAISE EXCEPTION 'El equipo destino no quedó reconocido como la excepción +1.'
            USING ERRCODE='23514';
    END IF;

    IF COALESCE((v_detector_after->>'loosePlayerCount')::integer,0)<>0
       OR COALESCE((v_detector_after->>'unassignedActivePlayerCount')::integer,0)<>0 THEN
        RAISE EXCEPTION 'Persisten jugadores sueltos o activos sin equipo; la operación fue revertida.'
            USING ERRCODE='23514';
    END IF;

    IF NOT COALESCE((v_detector_after->>'compositionReady')::boolean,false) THEN
        RAISE EXCEPTION 'La composición global no quedó lista después de crear la excepción +1.'
            USING ERRCODE='23514',DETAIL=v_detector_after::text;
    END IF;

    UPDATE public.tournament_team_composition_changes
    SET metadata=COALESCE(metadata,'{}'::jsonb)||jsonb_build_object(
        'roundRevisions',v_round_results,
        'detectorAfter',v_detector_after,
        'compositionReadyAfter',true
    )
    WHERE id=v_change_id;

    RETURN jsonb_build_object(
        'status','completed',
        'operation','LOOSE_TO_SINGLE_PLUS_ONE_PRE_EMISSION',
        'tournamentId',v_t.id,
        'changeId',v_change_id,
        'registrationId',v_reg.id,
        'playerId',v_reg.player_id,
        'sourceTeamId',v_source_team.id,
        'sourceTeamRetired',true,
        'targetTeamId',v_target_team.id,
        'targetTeamCountBefore',v_target_count,
        'targetTeamCountAfter',v_target_count+1,
        'configuredTeamSize',v_t.jugadores_por_equipo,
        'physicalTargetStartPreserved',true,
        'groupsDeactivated',v_groups_deactivated,
        'roundRevisions',v_round_results,
        'compositionState',v_detector_after,
        'compositionReady',true
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.incorporar_suelto_como_excepcion_a_gogo_281(uuid,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.incorporar_suelto_como_excepcion_a_gogo_281(uuid,uuid,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.incorporar_suelto_como_excepcion_a_gogo_281(uuid,uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.incorporar_suelto_como_excepcion_a_gogo_281(uuid,uuid,text) TO service_role;

COMMIT;
