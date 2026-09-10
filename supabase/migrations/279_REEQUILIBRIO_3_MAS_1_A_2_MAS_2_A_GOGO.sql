-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 279
-- Reequilibrio A-Go-Go 3+1 -> 2+2 post-Freeze / pre-START
--
-- Regla:
--   - torneo A-Go-Go TEAM con jugadores_por_equipo = 2
--   - existe un equipo excepción con 3 activos
--   - existe un equipo incompleto con 1 activo
--   - el administrador elige UN integrante del equipo excepción
--   - ese integrante pasa al equipo incompleto
--   - ambos equipos quedan con 2 activos
--
-- Principio operativo:
--   - NO cambia hoyo, posición ni grupo físico de salida
--   - conserva ambos equipos existentes
--   - recalcula HCP TEAM de ambos equipos
--   - si había validación, genera nuevo snapshot lógico
--   - si había tarjetas emitidas, revisa evidencia TEAM/markers
--   - devuelve únicamente las tarjetas de ambos equipos como
--     candidatas a reimpresión material
--   - todo ocurre antes de START_TOURNAMENT
-- ============================================================

CREATE OR REPLACE FUNCTION public.reequilibrar_excepcion_incompleto_a_gogo_279(
    p_registration_id uuid,
    p_incomplete_team_id uuid,
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

    v_source_count_before integer;
    v_target_count_before integer;
    v_source_count_after integer;
    v_target_count_after integer;

    v_detector_before jsonb;
    v_detector_after jsonb;

    v_old_validation_ids uuid[] := ARRAY[]::uuid[];
    v_old_validation record;
    v_has_issued_cards boolean := false;

    v_change_id uuid;
    v_hcp_source jsonb;
    v_hcp_target jsonb;
    v_hcp_results jsonb := '[]'::jsonb;
    v_revalidation jsonb;
    v_preview jsonb;
    v_validation_result jsonb;
    v_revision_result jsonb;
    v_round_results jsonb := '[]'::jsonb;
    v_round record;

    v_score_cards_to_reprint uuid[] := ARRAY[]::uuid[];
BEGIN
    -- --------------------------------------------------------
    -- Seguridad / entrada
    -- --------------------------------------------------------
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF p_registration_id IS NULL OR p_incomplete_team_id IS NULL THEN
        RAISE EXCEPTION
            'Debes indicar la inscripción a mover y el equipo incompleto destino.'
            USING ERRCODE = '22023';
    END IF;

    IF length(btrim(COALESCE(p_reason,''))) < 5 THEN
        RAISE EXCEPTION
            'El motivo debe contener al menos 5 caracteres.'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
      INTO v_reg
      FROM public.tournament_registrations
     WHERE id = p_registration_id
     FOR UPDATE;

    IF v_reg.id IS NULL OR NOT v_reg.activo THEN
        RAISE EXCEPTION
            'La inscripción seleccionada no existe o está inactiva.'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_reg.tournament_team_id IS NULL THEN
        RAISE EXCEPTION
            'La inscripción seleccionada no pertenece a un equipo.'
            USING ERRCODE = '23514';
    END IF;

    IF v_reg.tournament_team_id = p_incomplete_team_id THEN
        RAISE EXCEPTION
            'El jugador ya pertenece al equipo incompleto indicado.'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = v_reg.tournament_id
       AND activo = true
     FOR UPDATE;

    IF v_t.id IS NULL THEN
        RAISE EXCEPTION 'El torneo no existe o está inactivo.'
            USING ERRCODE = 'P0002';
    END IF;

    -- START_TOURNAMENT es frontera definitiva.
    IF v_t.estatus::text IN ('en_curso','finalizado','cancelado') THEN
        RAISE EXCEPTION
            'El torneo ya inició o terminó. La composición competitiva ya no puede modificarse.'
            USING ERRCODE = '55000';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_t.id) THEN
        RAISE EXCEPTION
            'No tienes permiso para reequilibrar equipos de este torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo = true
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tf.code,
           tf.tipo_participacion::text AS participation_type,
           tf.scoring_engine::text AS scoring_engine
      INTO v_format
      FROM public.tournament_formats tf
     WHERE tf.id = v_t.tournament_format_id
       AND tf.activo = true;

    IF v_format.code IS DISTINCT FROM 'A_GOGO'
       OR v_format.participation_type IS DISTINCT FROM 'equipo'
       OR v_format.scoring_engine IS DISTINCT FROM 'team_stroke'
    THEN
        RAISE EXCEPTION
            'Este procedimiento sólo aplica a A-Go-Go TEAM (A_GOGO/equipo/team_stroke).'
            USING ERRCODE = '22023';
    END IF;

    -- Esta fase implementa exactamente la regla aprobada 3+1 -> 2+2.
    IF v_t.jugadores_por_equipo IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION
            'La operación 279 sólo aplica a torneos configurados con 2 jugadores por equipo (3+1 -> 2+2).'
            USING ERRCODE = '23514';
    END IF;

    SELECT f.id
      INTO v_freeze_id
      FROM public.tournament_condition_freezes f
     WHERE f.tournament_id = v_t.id
     ORDER BY f.frozen_at DESC
     LIMIT 1;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION
            'El torneo todavía no está congelado; utiliza el flujo normal de composición.'
            USING ERRCODE = '55000';
    END IF;

    -- Serializar ambos equipos de forma estable.
    PERFORM pg_advisory_xact_lock(
        LEAST(
            hashtextextended(v_reg.tournament_team_id::text,279),
            hashtextextended(p_incomplete_team_id::text,279)
        )
    );
    PERFORM pg_advisory_xact_lock(
        GREATEST(
            hashtextextended(v_reg.tournament_team_id::text,279),
            hashtextextended(p_incomplete_team_id::text,279)
        )
    );

    SELECT *
      INTO v_source_team
      FROM public.tournament_teams tt
     WHERE tt.id = v_reg.tournament_team_id
       AND tt.tournament_id = v_t.id
       AND tt.activo = true
     FOR UPDATE;

    SELECT *
      INTO v_target_team
      FROM public.tournament_teams tt
     WHERE tt.id = p_incomplete_team_id
       AND tt.tournament_id = v_t.id
       AND tt.activo = true
     FOR UPDATE;

    IF v_source_team.id IS NULL THEN
        RAISE EXCEPTION
            'El equipo excepción origen no existe o está inactivo.'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_target_team.id IS NULL THEN
        RAISE EXCEPTION
            'El equipo incompleto destino no existe, está inactivo o pertenece a otro torneo.'
            USING ERRCODE = 'P0002';
    END IF;

    -- No cambiar categoría congelada implícitamente.
    IF v_source_team.tournament_category_id
       IS DISTINCT FROM v_target_team.tournament_category_id
    THEN
        RAISE EXCEPTION
            'Los dos equipos pertenecen a categorías distintas. La 279 no cambia categorías congeladas.'
            USING ERRCODE = '23514';
    END IF;

    SELECT count(*)::integer
      INTO v_source_count_before
      FROM public.tournament_registrations r
     WHERE r.tournament_id = v_t.id
       AND r.tournament_team_id = v_source_team.id
       AND r.activo = true;

    SELECT count(*)::integer
      INTO v_target_count_before
      FROM public.tournament_registrations r
     WHERE r.tournament_id = v_t.id
       AND r.tournament_team_id = v_target_team.id
       AND r.activo = true;

    IF v_source_count_before <> 3 THEN
        RAISE EXCEPTION
            'El equipo origen debe ser exactamente la excepción de 3 jugadores; actualmente tiene % activos.',
            v_source_count_before
            USING ERRCODE = '23514';
    END IF;

    IF v_target_count_before <> 1 THEN
        RAISE EXCEPTION
            'El equipo destino debe estar incompleto con exactamente 1 jugador activo; actualmente tiene %.',
            v_target_count_before
            USING ERRCODE = '23514';
    END IF;

    -- Confirmar que el detector global 278 reconoce la anomalía.
    v_detector_before :=
        public.obtener_estado_equipos_incompletos_a_gogo_274(v_t.id);

    IF COALESCE((v_detector_before->>'exceptionTeamCount')::integer,0) <> 1 THEN
        RAISE EXCEPTION
            'La 279 requiere exactamente un equipo excepción global antes del reequilibrio.'
            USING ERRCODE = '23514';
    END IF;

    IF NOT COALESCE(
        (v_detector_before->>'requiresExceptionReconfiguration')::boolean,
        false
    ) THEN
        RAISE EXCEPTION
            'El detector 278 no reporta una excepción pendiente de reconfiguración.'
            USING ERRCODE = '23514';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(
            COALESCE(v_detector_before->'exceptionTeams','[]'::jsonb)
        ) e
        WHERE NULLIF(e->>'teamId','')::uuid = v_source_team.id
    ) THEN
        RAISE EXCEPTION
            'El equipo origen no es el equipo excepción reconocido por el detector 278.'
            USING ERRCODE = '23514';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(
            COALESCE(v_detector_before->'incompleteTeams','[]'::jsonb)
        ) e
        WHERE NULLIF(e->>'teamId','')::uuid = v_target_team.id
    ) THEN
        RAISE EXCEPTION
            'El equipo destino no es un equipo incompleto reconocido por el detector 278.'
            USING ERRCODE = '23514';
    END IF;

    -- --------------------------------------------------------
    -- Estado operativo antes de mutar.
    -- --------------------------------------------------------
    SELECT COALESCE(
               array_agg(v.id ORDER BY v.tournament_round_id),
               ARRAY[]::uuid[]
           )
      INTO v_old_validation_ids
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_id = v_t.id
       AND v.status = 'validated'
       AND v.start_format = 'shotgun'
       AND v.participation_type = 'equipo'
       AND v.scoring_engine = 'team_stroke';

    IF EXISTS (
        SELECT 1
        FROM public.tournament_round_start_validations v
        WHERE v.tournament_id = v_t.id
          AND v.status = 'validated'
          AND (
              v.start_format IS DISTINCT FROM 'shotgun'
              OR v.participation_type IS DISTINCT FROM 'equipo'
              OR v.scoring_engine IS DISTINCT FROM 'team_stroke'
          )
    ) THEN
        RAISE EXCEPTION
            'Existe una validación activa fuera del motor A-Go-Go Shotgun. El reequilibrio fue bloqueado.'
            USING ERRCODE = '55000';
    END IF;

    v_has_issued_cards := EXISTS (
        SELECT 1
        FROM public.tournament_score_card_emissions e
        WHERE e.tournament_id = v_t.id
          AND e.status = 'issued'
    );

    IF v_has_issued_cards
       AND cardinality(v_old_validation_ids) = 0
    THEN
        RAISE EXCEPTION
            'Existen tarjetas emitidas pero no una validación A-Go-Go activa. El reequilibrio fue bloqueado.'
            USING ERRCODE = '55000';
    END IF;

    -- Reabrir sólo el snapshot lógico de validación.
    -- NO se modifican las asignaciones físicas de salida.
    IF v_has_issued_cards THEN
        PERFORM set_config(
            'app.revisar_tarjeta_team_post_emision',
            'true',
            true
        );
    END IF;

    IF cardinality(v_old_validation_ids) > 0 THEN
        PERFORM set_config(
            'app.reabrir_validacion_salida_ronda',
            'true',
            true
        );

        UPDATE public.tournament_round_start_validations
           SET status = 'reopened',
               reopened_at = now(),
               reopened_by = v_admin_id,
               reopen_reason =
                   'Reequilibrio A-Go-Go 279 3+1->2+2: ' || btrim(p_reason)
         WHERE id = ANY(v_old_validation_ids);
    END IF;

    -- --------------------------------------------------------
    -- Movimiento único: origen 3 -> 2; destino 1 -> 2.
    -- --------------------------------------------------------
    PERFORM set_config(
        'app.a_gogo_composition_override',
        'true',
        true
    );

    UPDATE public.tournament_registrations
       SET tournament_team_id = v_target_team.id
     WHERE id = v_reg.id;

    -- Mantener coherente el roster convertido si existe.
    UPDATE public.tournament_team_roster_slots
       SET tournament_team_id = v_target_team.id,
           updated_at = now()
     WHERE tournament_registration_id = v_reg.id
       AND status = 'converted';

    SELECT count(*)::integer
      INTO v_source_count_after
      FROM public.tournament_registrations r
     WHERE r.tournament_id = v_t.id
       AND r.tournament_team_id = v_source_team.id
       AND r.activo = true;

    SELECT count(*)::integer
      INTO v_target_count_after
      FROM public.tournament_registrations r
     WHERE r.tournament_id = v_t.id
       AND r.tournament_team_id = v_target_team.id
       AND r.activo = true;

    IF v_source_count_after <> 2 OR v_target_count_after <> 2 THEN
        RAISE EXCEPTION
            'El reequilibrio no produjo 2+2 y fue revertido (origen %, destino %).',
            v_source_count_after, v_target_count_after
            USING ERRCODE = '23514';
    END IF;

    INSERT INTO public.tournament_team_composition_changes(
        tournament_id,
        tournament_registration_id,
        player_id,
        change_type,
        old_team_id,
        new_team_id,
        reason,
        changed_by_admin_id,
        freeze_id,
        metadata
    )
    VALUES(
        v_t.id,
        v_reg.id,
        v_reg.player_id,
        'team_reassignment',
        v_source_team.id,
        v_target_team.id,
        btrim(p_reason),
        v_admin_id,
        v_freeze_id,
        jsonb_build_object(
            'phase','279_REBALANCE_3_PLUS_1_TO_2_PLUS_2',
            'postFreeze',true,
            'preStartTournament',true,
            'physicalStartsPreserved',true,
            'sourceTeamCountBefore',v_source_count_before,
            'targetTeamCountBefore',v_target_count_before,
            'sourceTeamCountAfter',v_source_count_after,
            'targetTeamCountAfter',v_target_count_after,
            'detectorBefore',v_detector_before
        )
    )
    RETURNING id INTO v_change_id;

    -- --------------------------------------------------------
    -- Rondas SIN validación activa: recalcular HCP de ambos.
    -- --------------------------------------------------------
    FOR v_round IN
        SELECT r.id
        FROM public.tournament_rounds r
        WHERE r.tournament_id = v_t.id
          AND r.activo = true
          AND NOT EXISTS (
              SELECT 1
              FROM public.tournament_round_start_validations ov
              WHERE ov.id = ANY(v_old_validation_ids)
                AND ov.tournament_round_id = r.id
          )
        ORDER BY r.numero_ronda,r.fecha,r.id
    LOOP
        v_hcp_source :=
            public.recalcular_handicap_equipo_a_gogo(
                v_round.id,
                v_source_team.id
            );

        v_hcp_target :=
            public.recalcular_handicap_equipo_a_gogo(
                v_round.id,
                v_target_team.id
            );

        v_hcp_results :=
            v_hcp_results || jsonb_build_array(
                jsonb_build_object(
                    'tournamentRoundId',v_round.id,
                    'sourceTeamHandicap',v_hcp_source,
                    'targetTeamHandicap',v_hcp_target
                )
            );
    END LOOP;

    -- --------------------------------------------------------
    -- Rondas previamente validadas.
    -- --------------------------------------------------------
    IF cardinality(v_old_validation_ids) > 0 THEN

        IF NOT v_has_issued_cards THEN
            -- 207 conserva las asignaciones físicas: recalcula HCP,
            -- vuelve a previsualizar y crea nueva versión lógica.
            v_revalidation :=
                public._revalidar_rondas_a_gogo_composicion_207(
                    v_t.id,
                    v_old_validation_ids,
                    ARRAY[v_source_team.id,v_target_team.id]::uuid[],
                    v_admin_id,
                    p_reason,
                    'team_reassignment',
                    v_change_id
                );

            v_round_results :=
                COALESCE(v_revalidation->'rounds','[]'::jsonb);

        ELSE
            -- Post-emisión: misma lógica probada por 271/215.
            -- No se reconstruyen salidas; se renueva evidencia competitiva.
            FOR v_old_validation IN
                SELECT *
                FROM public.tournament_round_start_validations v
                WHERE v.id = ANY(v_old_validation_ids)
                ORDER BY v.tournament_round_id
            LOOP
                v_hcp_source :=
                    public.recalcular_handicap_equipo_a_gogo(
                        v_old_validation.tournament_round_id,
                        v_source_team.id
                    );

                v_hcp_target :=
                    public.recalcular_handicap_equipo_a_gogo(
                        v_old_validation.tournament_round_id,
                        v_target_team.id
                    );

                v_preview :=
                    public.previsualizar_validacion_salidas_ronda(
                        v_old_validation.tournament_round_id
                    );

                IF NOT COALESCE((v_preview->>'ready')::boolean,false) THEN
                    RAISE EXCEPTION
                        'El reequilibrio dejaría la ronda no validable y fue revertido.'
                        USING ERRCODE = '23514',
                              DETAIL = (v_preview->'errors')::text;
                END IF;

                v_validation_result :=
                    public.validar_salidas_ronda(
                        v_old_validation.tournament_round_id
                    );

                v_revision_result :=
                    public._revisar_tarjetas_team_ronda_post_emision_215(
                        v_old_validation.tournament_round_id,
                        v_admin_id,
                        'team_reassignment',
                        v_change_id,
                        p_reason
                    );

                v_round_results :=
                    v_round_results || jsonb_build_array(
                        jsonb_build_object(
                            'tournamentRoundId',
                                v_old_validation.tournament_round_id,
                            'oldValidationId',
                                v_old_validation.id,
                            'oldValidationVersion',
                                v_old_validation.version,
                            'sourceTeamHandicap',
                                v_hcp_source,
                            'targetTeamHandicap',
                                v_hcp_target,
                            'validation',
                                v_validation_result,
                            'cardRevision',
                                v_revision_result
                        )
                    );
            END LOOP;
        END IF;
    END IF;

    -- --------------------------------------------------------
    -- Detector global DESPUÉS.
    -- No exigimos compositionReady=true global porque podría existir
    -- otra anomalía independiente; START seguirá bloqueado por 278/275.
    -- Sí exigimos que ESTA excepción y ESTE incompleto desaparecieron.
    -- --------------------------------------------------------
    v_detector_after :=
        public.obtener_estado_equipos_incompletos_a_gogo_274(v_t.id);

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(
            COALESCE(v_detector_after->'exceptionTeams','[]'::jsonb)
        ) e
        WHERE NULLIF(e->>'teamId','')::uuid = v_source_team.id
    ) THEN
        RAISE EXCEPTION
            'El equipo origen continúa marcado como excepción después del reequilibrio.'
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(
            COALESCE(v_detector_after->'incompleteTeams','[]'::jsonb)
        ) e
        WHERE NULLIF(e->>'teamId','')::uuid = v_target_team.id
    ) THEN
        RAISE EXCEPTION
            'El equipo destino continúa incompleto después del reequilibrio.'
            USING ERRCODE = '23514';
    END IF;

    -- Reimpresión MATERIAL: sólo tarjetas de los dos TEAM modificados.
    -- El helper 215 puede renovar referencias lógicas de la emisión completa,
    -- pero el operador sólo necesita reimprimir estas tarjetas.
    IF v_has_issued_cards THEN
        SELECT COALESCE(
                   array_agg(sc.id ORDER BY sc.id),
                   ARRAY[]::uuid[]
               )
          INTO v_score_cards_to_reprint
          FROM public.tournament_score_cards sc
          JOIN public.tournament_score_card_emissions e
            ON e.id = sc.emission_id
         WHERE sc.tournament_id = v_t.id
           AND sc.tournament_team_id IN (
               v_source_team.id,
               v_target_team.id
           )
           AND sc.unit_type = 'team'
           AND sc.status = 'issued'
           AND e.status = 'issued';
    END IF;

    UPDATE public.tournament_team_composition_changes
       SET metadata =
           COALESCE(metadata,'{}'::jsonb) ||
           jsonb_build_object(
               'validatedRoundsAffected',
                   cardinality(v_old_validation_ids),
               'cardsWereIssued',
                   v_has_issued_cards,
               'roundRevisions',
                   v_round_results,
               'nonValidatedRoundHandicaps',
                   v_hcp_results,
               'scoreCardsToReprint',
                   to_jsonb(v_score_cards_to_reprint),
               'detectorAfter',
                   v_detector_after,
               'compositionReadyAfter',
                   COALESCE(
                       (v_detector_after->>'compositionReady')::boolean,
                       false
                   )
           )
     WHERE id = v_change_id;

    RETURN jsonb_build_object(
        'status','completed',
        'operation','REBAlANCE_3_PLUS_1_TO_2_PLUS_2',
        'tournamentId',v_t.id,
        'changeId',v_change_id,
        'registrationId',v_reg.id,
        'playerId',v_reg.player_id,
        'sourceTeamId',v_source_team.id,
        'targetTeamId',v_target_team.id,
        'sourceTeamCountBefore',v_source_count_before,
        'targetTeamCountBefore',v_target_count_before,
        'sourceTeamCountAfter',v_source_count_after,
        'targetTeamCountAfter',v_target_count_after,
        'physicalStartsPreserved',true,
        'validatedRoundsAffected',cardinality(v_old_validation_ids),
        'cardsWereIssued',v_has_issued_cards,
        'roundRevisions',v_round_results,
        'nonValidatedRoundHandicaps',v_hcp_results,
        'scoreCardsToReprint',to_jsonb(v_score_cards_to_reprint),
        'compositionState',v_detector_after,
        'compositionReady',
            COALESCE(
                (v_detector_after->>'compositionReady')::boolean,
                false
            )
    );
END;
$function$;

COMMENT ON FUNCTION public.reequilibrar_excepcion_incompleto_a_gogo_279(uuid,uuid,text)
IS '279: reequilibra A-Go-Go 3+1 a 2+2 antes de START_TOURNAMENT. Mueve un integrante elegido del único equipo excepción al equipo incompleto, conserva ambos equipos y sus salidas físicas, recalcula HCP TEAM y actualiza evidencia/tarjetas/markers cuando corresponde.';

REVOKE ALL ON FUNCTION public.reequilibrar_excepcion_incompleto_a_gogo_279(uuid,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reequilibrar_excepcion_incompleto_a_gogo_279(uuid,uuid,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.reequilibrar_excepcion_incompleto_a_gogo_279(uuid,uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reequilibrar_excepcion_incompleto_a_gogo_279(uuid,uuid,text) TO service_role;
