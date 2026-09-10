-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 284
-- Retiro competitivo de equipo incompleto A-Go-Go
-- Post-Freeze / Pre-START_TOURNAMENT / Pre-emisión
-- ============================================================

CREATE OR REPLACE FUNCTION public.retirar_equipo_incompleto_competencia_a_gogo_284(
    p_team_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_team public.tournament_teams%ROWTYPE;
    v_t public.tournaments%ROWTYPE;
    v_reg public.tournament_registrations%ROWTYPE;
    v_admin_id uuid;
    v_freeze_id uuid;
    v_format record;
    v_detector_before jsonb;
    v_detector_after jsonb;
    v_active_members integer;
    v_cards_issued boolean;
    v_validated_rounds uuid[] := ARRAY[]::uuid[];
    v_round_id uuid;
    v_preview jsonb;
    v_change_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF length(btrim(COALESCE(p_reason,''))) < 5 THEN
        RAISE EXCEPTION
            'El motivo del retiro debe contener al menos 5 caracteres.'
            USING ERRCODE='22023';
    END IF;

    SELECT *
      INTO v_team
      FROM public.tournament_teams
     WHERE id=p_team_id
     FOR UPDATE;

    IF v_team.id IS NULL OR NOT v_team.activo THEN
        RAISE EXCEPTION
            'El equipo no existe o ya no está activo.'
            USING ERRCODE='22023';
    END IF;

    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id=v_team.tournament_id
       AND activo=true
     FOR UPDATE;

    IF v_t.id IS NULL THEN
        RAISE EXCEPTION 'El torneo no existe o está inactivo.';
    END IF;

    IF v_t.estatus::text IN ('en_curso','finalizado','cancelado') THEN
        RAISE EXCEPTION
            'El torneo ya inició o terminó. La composición competitiva ya no puede modificarse.'
            USING ERRCODE='55000';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_t.id) THEN
        RAISE EXCEPTION
            'No tienes permiso para retirar equipos de competencia en este torneo.'
            USING ERRCODE='42501';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id=auth.uid()
       AND au.activo=true
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE='42501';
    END IF;

    SELECT tf.code,
           tf.tipo_participacion::text AS participation_type,
           tf.scoring_engine::text AS scoring_engine
      INTO v_format
      FROM public.tournament_formats tf
     WHERE tf.id=v_t.tournament_format_id
       AND tf.activo=true;

    IF v_format.code IS DISTINCT FROM 'A_GOGO'
       OR v_format.participation_type IS DISTINCT FROM 'equipo'
       OR v_format.scoring_engine IS DISTINCT FROM 'team_stroke'
    THEN
        RAISE EXCEPTION
            'Este procedimiento sólo aplica a A-Go-Go/team_stroke.'
            USING ERRCODE='22023';
    END IF;

    SELECT f.id
      INTO v_freeze_id
      FROM public.tournament_condition_freezes f
     WHERE f.tournament_id=v_t.id
     ORDER BY f.frozen_at DESC
     LIMIT 1;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION
            'El torneo todavía no está congelado; utiliza el flujo normal de composición.'
            USING ERRCODE='55000';
    END IF;

    v_cards_issued := EXISTS (
        SELECT 1
          FROM public.tournament_score_card_emissions e
         WHERE e.tournament_id=v_t.id
           AND e.status='issued'
    );

    IF v_cards_issued THEN
        RAISE EXCEPTION
            'No es posible retirar competitivamente el equipo con tarjetas oficiales ya emitidas. Esta operación sólo está habilitada antes de la emisión.'
            USING ERRCODE='55000';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(v_team.id::text,284));

    SELECT count(*)::integer
      INTO v_active_members
      FROM public.tournament_registrations tr
     WHERE tr.tournament_id=v_t.id
       AND tr.tournament_team_id=v_team.id
       AND tr.activo=true;

    IF v_active_members <> 1 THEN
        RAISE EXCEPTION
            'El equipo debe tener exactamente un integrante activo para usar este retiro competitivo. Integrantes activos: %.',
            v_active_members
            USING ERRCODE='23514';
    END IF;

    v_detector_before :=
        public.obtener_estado_equipos_incompletos_a_gogo_274(v_t.id);

    IF NOT EXISTS (
        SELECT 1
          FROM jsonb_array_elements(
              COALESCE(v_detector_before->'incompleteTeams','[]'::jsonb)
          ) x
         WHERE NULLIF(x->>'teamId','')::uuid=v_team.id
           AND COALESCE((x->>'activeMemberCount')::integer,0)=1
    ) THEN
        RAISE EXCEPTION
            'El detector de composición no reconoce al equipo como INCOMPLETO 1/N.'
            USING ERRCODE='23514';
    END IF;

    SELECT *
      INTO v_reg
      FROM public.tournament_registrations tr
     WHERE tr.tournament_id=v_t.id
       AND tr.tournament_team_id=v_team.id
       AND tr.activo=true
     ORDER BY tr.created_at,tr.id
     LIMIT 1
     FOR UPDATE;

    SELECT COALESCE(array_agg(DISTINCT v.tournament_round_id),ARRAY[]::uuid[])
      INTO v_validated_rounds
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_id=v_t.id
       AND v.status='validated'
       AND v.start_format='shotgun'
       AND v.participation_type='equipo'
       AND v.scoring_engine='team_stroke';

    -- Reabrir sólo las validaciones lógicas afectadas. No se mueven
    -- físicamente los demás equipos.
    UPDATE public.tournament_round_start_validations
       SET status='superseded'
     WHERE tournament_id=v_t.id
       AND status='validated'
       AND start_format='shotgun'
       AND participation_type='equipo'
       AND scoring_engine='team_stroke';

    -- El jugador restante deja de ser competidor oficial, pero su
    -- inscripción permanece históricamente registrada.
    UPDATE public.tournament_registrations
       SET activo=false,
           fecha_baja=now(),
           dado_de_baja_por=v_admin_id,
           motivo_baja='Retirado de competencia: ' || btrim(p_reason)
     WHERE id=v_reg.id;

    UPDATE public.tournament_team_roster_slots
       SET status='cancelled',
           cancelled_at=COALESCE(cancelled_at,now()),
           updated_at=now()
     WHERE tournament_registration_id=v_reg.id
       AND status<>'cancelled';

    -- El equipo se conserva históricamente, pero deja de ser unidad
    -- competitiva oficial.
    UPDATE public.tournament_teams
       SET activo=false,
           fecha_baja=now(),
           dado_de_baja_por=v_admin_id,
           motivo_baja='Retirado de competencia: ' || btrim(p_reason),
           updated_at=now()
     WHERE id=v_team.id;

    -- Retiro lógico de sus asignaciones de salida.
    UPDATE public.tournament_group_teams gt
       SET activo=false,
           fecha_baja=now(),
           dado_de_baja_por=v_admin_id,
           motivo_baja='Equipo retirado de competencia: ' || btrim(p_reason),
           updated_at=now()
     WHERE gt.tournament_team_id=v_team.id
       AND gt.activo=true;

    -- Si al retirar el equipo algún grupo queda vacío, también deja de
    -- formar parte de la salida competitiva.
    WITH empty_groups AS (
        SELECT g.id
          FROM public.tournament_groups g
          JOIN public.tournament_round_shifts rs
            ON rs.id=g.tournament_round_shift_id
           AND rs.activo=true
          JOIN public.tournament_rounds r
            ON r.id=rs.tournament_round_id
           AND r.activo=true
         WHERE r.tournament_id=v_t.id
           AND g.activo=true
           AND NOT EXISTS (
               SELECT 1
                 FROM public.tournament_group_teams gt
                WHERE gt.tournament_group_id=g.id
                  AND gt.activo=true
           )
    )
    UPDATE public.tournament_groups g
       SET activo=false,
           fecha_baja=now(),
           dado_de_baja_por=v_admin_id,
           motivo_baja='Grupo vacío por retiro competitivo de equipo',
           updated_at=now()
      FROM empty_groups eg
     WHERE g.id=eg.id;

    -- El HCP histórico se conserva. Sólo deja de considerarse CURRENT
    -- para competencia al quedar el equipo inactivo.
    UPDATE public.tournament_round_team_handicap_versions
       SET status=CASE WHEN status='active' THEN 'superseded' ELSE status END,
           is_stale=true,
           stale_reason='TEAM_RETIRED_FROM_COMPETITION_284',
           stale_at=COALESCE(stale_at,now()),
           superseded_at=CASE
               WHEN status='active' THEN COALESCE(superseded_at,now())
               ELSE superseded_at
           END
     WHERE tournament_id=v_t.id
       AND tournament_team_id=v_team.id
       AND status='active';

    INSERT INTO public.tournament_team_composition_changes(
        tournament_id,
        tournament_registration_id,
        player_id,
        replacement_player_id,
        change_type,
        old_team_id,
        new_team_id,
        reason,
        changed_by_admin_id,
        freeze_id,
        metadata
    )
    VALUES (
        v_t.id,
        v_reg.id,
        v_reg.player_id,
        NULL,
        'team_competitive_withdrawal',
        v_team.id,
        NULL,
        btrim(p_reason),
        v_admin_id,
        v_freeze_id,
        jsonb_build_object(
            'phase','284_RETIRE_INCOMPLETE_TEAM_PRE_EMISSION',
            'postFreeze',true,
            'preStartTournament',true,
            'preScorecardEmission',true,
            'teamId',v_team.id,
            'teamName',v_team.nombre_equipo,
            'remainingPlayerRegistrationId',v_reg.id,
            'remainingPlayerId',v_reg.player_id,
            'remainingPlayerRetiredFromCompetition',true,
            'teamPreservedHistorically',true,
            'registrationsPreservedHistorically',true,
            'hcpHistoryPreserved',true,
            'competitiveAssignmentsRemoved',true,
            'validatedRoundsToRefresh',
                COALESCE(to_jsonb(v_validated_rounds),'[]'::jsonb)
        )
    )
    RETURNING id INTO v_change_id;

    -- Revalidar las rondas que estaban validadas antes del retiro.
    FOREACH v_round_id IN ARRAY v_validated_rounds
    LOOP
        v_preview :=
            public._previsualizar_validacion_salidas_shotgun_team_v1(v_round_id);

        IF NOT COALESCE((v_preview->>'ready')::boolean,false) THEN
            RAISE EXCEPTION
                'El retiro dejó una ronda sin condiciones para revalidar salidas.'
                USING ERRCODE='23514',
                      DETAIL=COALESCE((v_preview->'errors')::text,'[]');
        END IF;

        PERFORM public.validar_salidas_ronda(v_round_id);
    END LOOP;

    v_detector_after :=
        public.obtener_estado_equipos_incompletos_a_gogo_274(v_t.id);

    IF EXISTS (
        SELECT 1
          FROM jsonb_array_elements(
              COALESCE(v_detector_after->'teams','[]'::jsonb)
          ) x
         WHERE NULLIF(x->>'teamId','')::uuid=v_team.id
    ) THEN
        RAISE EXCEPTION
            'El equipo retirado continúa apareciendo como unidad competitiva activa.'
            USING ERRCODE='23514';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM jsonb_array_elements(
              COALESCE(v_detector_after->'loosePlayers','[]'::jsonb)
          ) x
         WHERE NULLIF(x->>'registrationId','')::uuid=v_reg.id
    )
    OR EXISTS (
        SELECT 1
          FROM jsonb_array_elements(
              COALESCE(v_detector_after->'unassignedActivePlayers','[]'::jsonb)
          ) x
         WHERE NULLIF(x->>'registrationId','')::uuid=v_reg.id
    ) THEN
        RAISE EXCEPTION
            'El jugador retirado continúa apareciendo como participante competitivo pendiente.'
            USING ERRCODE='23514';
    END IF;

    RETURN jsonb_build_object(
        'status','completed',
        'tournamentId',v_t.id,
        'teamId',v_team.id,
        'teamName',v_team.nombre_equipo,
        'changeId',v_change_id,
        'retiredRegistrationId',v_reg.id,
        'retiredPlayerId',v_reg.player_id,
        'teamActive',false,
        'playerCompetitiveActive',false,
        'historyPreserved',true,
        'cardsIssued',false,
        'validatedRoundsRefreshed',
            COALESCE(to_jsonb(v_validated_rounds),'[]'::jsonb),
        'composition',v_detector_after
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.retirar_equipo_incompleto_competencia_a_gogo_284(uuid,text)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.retirar_equipo_incompleto_competencia_a_gogo_284(uuid,text)
TO authenticated;

COMMENT ON FUNCTION public.retirar_equipo_incompleto_competencia_a_gogo_284(uuid,text)
IS 'A-Go-Go 284: retira de competencia un equipo post-Freeze que quedó con exactamente un integrante activo, antes de START_TOURNAMENT y antes de emitir tarjetas. Conserva equipo, inscripción y HCP como historial; retira unidad, jugador restante y asignaciones de la competencia; audita la decisión y revalida salidas previamente validadas.';
