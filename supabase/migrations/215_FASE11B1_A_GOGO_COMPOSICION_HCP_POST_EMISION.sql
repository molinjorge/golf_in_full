-- ============================================================================
-- MIGRACIÓN 215 FASE 11B1
-- A-Go-Go — composición/HCP post-emisión con misma tarjeta TEAM
-- Proyecto: Tee Central / GOLF IN FULL
--
-- PRINCIPIOS
-- - conserva score_card_id, card_folio y qr_token;
-- - conserva una sola emisión activa por ronda;
-- - genera nueva validación formal de salidas;
-- - recalcula HCP TEAM afectado;
-- - mueve los punteros de la emisión/tarjetas a la nueva validación de forma
--   exclusivamente transaccional y auditada;
-- - actualiza el snapshot TEAM vigente y guarda su versión anterior;
-- - refresca automáticamente al jugador-marker si dejó de pertenecer al TEAM;
-- - NO permite cambios si la ronda/categoría ya fue cerrada competitivamente.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Corregir contrato real de assignment_source para A-Go-Go
-- ============================================================================

ALTER TABLE public.tournament_scorecard_marker_assignments
DROP CONSTRAINT IF EXISTS tournament_scorecard_marker_assignments_assignment_source_check;

ALTER TABLE public.tournament_scorecard_marker_assignments
ADD CONSTRAINT tournament_scorecard_marker_assignments_assignment_source_check
CHECK (
    assignment_source IN (
        'circular',
        'admin',
        'circular_team',
        'admin_team',
        'composition_refresh_team'
    )
);

-- ============================================================================
-- 2. Historial inmutable de revisiones de tarjeta TEAM
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tournament_team_scorecard_revisions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,
    score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id) ON DELETE RESTRICT,
    tournament_team_id uuid NOT NULL
        REFERENCES public.tournament_teams(id) ON DELETE RESTRICT,

    revision_number integer NOT NULL CHECK (revision_number > 0),
    source_type text NOT NULL CHECK (
        source_type IN (
            'team_reassignment',
            'player_substitution',
            'team_handicap_refresh'
        )
    ),
    source_id uuid,

    old_validation_id uuid NOT NULL
        REFERENCES public.tournament_round_start_validations(id) ON DELETE RESTRICT,
    old_validation_version integer NOT NULL CHECK (old_validation_version > 0),
    new_validation_id uuid NOT NULL
        REFERENCES public.tournament_round_start_validations(id) ON DELETE RESTRICT,
    new_validation_version integer NOT NULL CHECK (new_validation_version > 0),

    old_team_handicap_version_id uuid NOT NULL
        REFERENCES public.tournament_round_team_handicap_versions(id) ON DELETE RESTRICT,
    new_team_handicap_version_id uuid NOT NULL
        REFERENCES public.tournament_round_team_handicap_versions(id) ON DELETE RESTRICT,

    before_snapshot jsonb NOT NULL,
    after_snapshot jsonb NOT NULL,

    reason text NOT NULL CHECK (length(btrim(reason)) >= 5),
    changed_by_admin_id uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),

    UNIQUE(score_card_id,revision_number)
);

CREATE INDEX IF NOT EXISTS idx_team_scorecard_revisions_round_card
ON public.tournament_team_scorecard_revisions(
    tournament_round_id,score_card_id,revision_number
);

ALTER TABLE public.tournament_team_scorecard_revisions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tournament_team_scorecard_revisions_admin_select
ON public.tournament_team_scorecard_revisions;

CREATE POLICY tournament_team_scorecard_revisions_admin_select
ON public.tournament_team_scorecard_revisions
FOR SELECT TO authenticated
USING (
    public.puede_administrar_congelamiento_torneo(tournament_id)
);

REVOKE INSERT,UPDATE,DELETE
ON public.tournament_team_scorecard_revisions
FROM PUBLIC,anon,authenticated;

GRANT SELECT
ON public.tournament_team_scorecard_revisions
TO authenticated,service_role;

-- ============================================================================
-- 3. Excepción transaccional estrecha: reabrir validación con tarjeta emitida
-- ============================================================================

CREATE OR REPLACE FUNCTION public._impedir_reapertura_con_tarjetas_emitidas()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
BEGIN
    IF OLD.status='validated'
       AND NEW.status='reopened'
       AND public._ronda_tiene_tarjetas_emitidas(
            OLD.tournament_round_id
       )
       AND current_setting(
            'app.revisar_tarjeta_team_post_emision',true
       ) IS DISTINCT FROM 'true'
    THEN
        RAISE EXCEPTION
            'Las tarjetas oficiales de esta ronda ya fueron emitidas y las salidas no pueden reabrirse.'
            USING ERRCODE='55000',
                  HINT='Use exclusivamente el flujo auditado A-Go-Go post-emisión.';
    END IF;

    RETURN NEW;
END;
$$;

-- ============================================================================
-- 4. Excepción transaccional estrecha: mover punteros históricos vigentes
-- ============================================================================

CREATE OR REPLACE FUNCTION public._impedir_mutacion_emision_tarjeta_score()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
BEGIN
    IF TG_OP='UPDATE'
       AND current_setting(
            'app.revisar_tarjeta_team_post_emision',true
       )='true'
    THEN
        IF TG_TABLE_NAME='tournament_score_card_emissions' THEN
            IF (
                to_jsonb(NEW)
                - ARRAY['validation_id','validation_version']
            ) IS NOT DISTINCT FROM (
                to_jsonb(OLD)
                - ARRAY['validation_id','validation_version']
            )
            THEN
                RETURN NEW;
            END IF;
        END IF;

        IF TG_TABLE_NAME='tournament_score_cards'
           AND OLD.unit_type='team'
           AND NEW.unit_type='team'
        THEN
            IF (
                to_jsonb(NEW)
                - ARRAY[
                    'validation_id',
                    'validation_version',
                    'validation_group_id',
                    'validation_unit_id'
                ]
            ) IS NOT DISTINCT FROM (
                to_jsonb(OLD)
                - ARRAY[
                    'validation_id',
                    'validation_version',
                    'validation_group_id',
                    'validation_unit_id'
                ]
            )
            THEN
                RETURN NEW;
            END IF;
        END IF;
    END IF;

    RAISE EXCEPTION
        'Las emisiones y tarjetas oficiales son históricas y no pueden modificarse directamente.'
        USING ERRCODE='55000',
              HINT='Use una operación administrativa auditada.';
END;
$$;

-- ============================================================================
-- 5. Revisar TODAS las tarjetas TEAM de una ronda hacia la nueva validación
-- ============================================================================

CREATE OR REPLACE FUNCTION public._revisar_tarjetas_team_ronda_post_emision_215(
    p_tournament_round_id uuid,
    p_admin_id uuid,
    p_source_type text,
    p_source_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_validation public.tournament_round_start_validations%ROWTYPE;
    v_emission public.tournament_score_card_emissions%ROWTYPE;
    v_card record;
    v_snapshot public.tournament_team_scorecard_snapshots%ROWTYPE;
    v_unit record;
    v_hcp public.tournament_round_team_handicap_versions%ROWTYPE;
    v_members jsonb;
    v_before jsonb;
    v_after jsonb;
    v_revision integer;
    v_count integer:=0;
    v_new_marker record;
    v_assignment record;
    v_from_sequence integer;
    v_holes_expected integer;
BEGIN
    IF p_source_type NOT IN (
        'team_reassignment',
        'player_substitution',
        'team_handicap_refresh'
    ) THEN
        RAISE EXCEPTION 'source_type no soportado.';
    END IF;

    IF length(btrim(COALESCE(p_reason,'')))<5 THEN
        RAISE EXCEPTION 'El motivo debe contener al menos 5 caracteres.';
    END IF;

    SELECT *
      INTO v_validation
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_round_id=p_tournament_round_id
       AND v.status='validated'
       AND v.start_format='shotgun'
       AND v.participation_type='equipo'
       AND v.scoring_engine='team_stroke'
     ORDER BY v.version DESC
     LIMIT 1;

    IF v_validation.id IS NULL THEN
        RAISE EXCEPTION
            'No existe nueva validación A-Go-Go activa para revisar las tarjetas.';
    END IF;

    SELECT *
      INTO v_emission
      FROM public.tournament_score_card_emissions e
     WHERE e.tournament_round_id=p_tournament_round_id
       AND e.status='issued'
     FOR UPDATE;

    IF v_emission.id IS NULL THEN
        RETURN jsonb_build_object(
            'revisedCards',0,
            'emissionRepointed',false
        );
    END IF;

    IF public._ronda_esta_cerrada_competitivamente(
        p_tournament_round_id
    ) THEN
        RAISE EXCEPTION
            'La ronda ya está cerrada competitivamente y no admite revisión de tarjetas.'
            USING ERRCODE='55000';
    END IF;

    PERFORM set_config(
        'app.revisar_tarjeta_team_post_emision',
        'true',
        true
    );

    FOR v_card IN
        SELECT sc.*
        FROM public.tournament_score_cards sc
        WHERE sc.emission_id=v_emission.id
          AND sc.status='issued'
          AND sc.unit_type='team'
        ORDER BY sc.card_number,sc.id
        FOR UPDATE
    LOOP
        SELECT
            u.id AS validation_unit_id,
            u.validation_group_id,
            u.tournament_category_id
          INTO v_unit
          FROM public.tournament_round_start_validation_units u
         WHERE u.validation_id=v_validation.id
           AND u.unit_type='team'
           AND u.tournament_team_id=v_card.tournament_team_id
         LIMIT 1;

        IF v_unit.validation_unit_id IS NULL THEN
            RAISE EXCEPTION
                'El equipo % no existe en la nueva validación.',
                v_card.tournament_team_id;
        END IF;

        SELECT *
          INTO v_hcp
          FROM public.tournament_round_team_handicap_versions hv
         WHERE hv.id=public._team_hcp_version_from_validation_208(
             v_validation.id,
             v_card.tournament_team_id
         );

        IF v_hcp.id IS NULL
           OR v_hcp.status<>'active'
           OR v_hcp.is_stale
        THEN
            RAISE EXCEPTION
                'El HCP vigente del equipo % no es válido para revisar la tarjeta.',
                v_card.tournament_team_id;
        END IF;

        SELECT *
          INTO v_snapshot
          FROM public.tournament_team_scorecard_snapshots ss
         WHERE ss.score_card_id=v_card.id
         FOR UPDATE;

        IF v_snapshot.id IS NULL THEN
            RAISE EXCEPTION
                'La tarjeta % no tiene snapshot TEAM.',v_card.id;
        END IF;

        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'registrationId',m.tournament_registration_id,
                    'playerId',m.player_id,
                    'name',m.player_name,
                    'handicapIndex',m.handicap_index,
                    'handicapSource',m.handicap_source,
                    'handicapStatus',m.handicap_status,
                    'teeId',m.tee_id,
                    'courseRating',m.course_rating,
                    'slopeRating',m.slope_rating,
                    'courseHandicapUnrounded',m.course_handicap_unrounded,
                    'whsRank',m.whs_rank,
                    'whsWeightPct',m.whs_weight_pct
                )
                ORDER BY
                    COALESCE(m.whs_rank,2147483647),
                    m.player_name,
                    m.player_id
            ),
            '[]'::jsonb
        )
          INTO v_members
          FROM public.tournament_round_team_handicap_members m
         WHERE m.team_handicap_version_id=v_hcp.id;

        IF jsonb_array_length(v_members)=0 THEN
            RAISE EXCEPTION
                'La nueva versión HCP del equipo % no tiene integrantes.',
                v_card.tournament_team_id;
        END IF;

        v_before:=jsonb_build_object(
            'scoreCard',to_jsonb(v_card),
            'teamSnapshot',to_jsonb(v_snapshot)
        );

        SELECT COALESCE(max(r.revision_number),0)+1
          INTO v_revision
          FROM public.tournament_team_scorecard_revisions r
         WHERE r.score_card_id=v_card.id;

        UPDATE public.tournament_score_cards
           SET validation_id=v_validation.id,
               validation_version=v_validation.version,
               validation_group_id=v_unit.validation_group_id,
               validation_unit_id=v_unit.validation_unit_id
         WHERE id=v_card.id;

        UPDATE public.tournament_team_scorecard_snapshots
           SET team_handicap_version_id=v_hcp.id,
               team_name=(
                   SELECT tt.nombre_equipo
                   FROM public.tournament_teams tt
                   WHERE tt.id=v_card.tournament_team_id
               ),
               team_handicap_method=v_hcp.method,
               team_handicap_unrounded=v_hcp.team_handicap_unrounded,
               team_playing_handicap=v_hcp.team_playing_handicap,
               member_count=v_hcp.member_count,
               members_snapshot=v_members
         WHERE score_card_id=v_card.id;

        -- El grupo lógico sigue siendo el mismo en 11B1, pero el id del
        -- snapshot validado cambió. Mantener consistente el marker activo.
        UPDATE public.tournament_scorecard_marker_assignments
           SET validation_group_id=v_unit.validation_group_id
         WHERE score_card_id=v_card.id
           AND status='active';

        SELECT jsonb_build_object(
            'scoreCard',to_jsonb(sc),
            'teamSnapshot',to_jsonb(ss)
        )
          INTO v_after
          FROM public.tournament_score_cards sc
          JOIN public.tournament_team_scorecard_snapshots ss
            ON ss.score_card_id=sc.id
         WHERE sc.id=v_card.id;

        INSERT INTO public.tournament_team_scorecard_revisions(
            tournament_id,
            tournament_round_id,
            score_card_id,
            tournament_team_id,
            revision_number,
            source_type,
            source_id,
            old_validation_id,
            old_validation_version,
            new_validation_id,
            new_validation_version,
            old_team_handicap_version_id,
            new_team_handicap_version_id,
            before_snapshot,
            after_snapshot,
            reason,
            changed_by_admin_id
        )
        VALUES(
            v_card.tournament_id,
            p_tournament_round_id,
            v_card.id,
            v_card.tournament_team_id,
            v_revision,
            p_source_type,
            p_source_id,
            v_card.validation_id,
            v_card.validation_version,
            v_validation.id,
            v_validation.version,
            v_snapshot.team_handicap_version_id,
            v_hcp.id,
            v_before,
            v_after,
            btrim(p_reason),
            p_admin_id
        );

        v_count:=v_count+1;
    END LOOP;

    -- La emisión sigue siendo la MISMA, sólo apunta al snapshot validado actual.
    UPDATE public.tournament_score_card_emissions
       SET validation_id=v_validation.id,
           validation_version=v_validation.version
     WHERE id=v_emission.id;

    -- Si un marker activo pertenecía a un TEAM cuya composición cambió y ya
    -- no forma parte del snapshot vigente, sustituirlo desde el siguiente hoyo
    -- no capturado. No reescribir jamás hoyos históricos.
    FOR v_assignment IN
        SELECT ma.*
        FROM public.tournament_scorecard_marker_assignments ma
        JOIN public.tournament_score_cards marker_sc
          ON marker_sc.id=ma.marker_score_card_id
         AND marker_sc.unit_type='team'
        JOIN public.tournament_team_scorecard_snapshots marker_ss
          ON marker_ss.score_card_id=marker_sc.id
        WHERE ma.tournament_round_id=p_tournament_round_id
          AND ma.status='active'
          AND NOT EXISTS(
              SELECT 1
              FROM jsonb_array_elements(marker_ss.members_snapshot) m
              WHERE NULLIF(m->>'playerId','')::uuid=ma.marker_player_id
          )
        FOR UPDATE OF ma
    LOOP
        SELECT
            NULLIF(m->>'playerId','')::uuid AS player_id,
            NULLIF(m->>'registrationId','')::uuid AS registration_id
          INTO v_new_marker
          FROM public.tournament_team_scorecard_snapshots ss
          CROSS JOIN LATERAL jsonb_array_elements(ss.members_snapshot) m
         WHERE ss.score_card_id=v_assignment.marker_score_card_id
           AND NULLIF(m->>'playerId','') IS NOT NULL
           AND NULLIF(m->>'registrationId','') IS NOT NULL
         ORDER BY
            COALESCE(NULLIF(m->>'whsRank','')::integer,2147483647),
            m->>'name'
         LIMIT 1;

        IF v_new_marker.player_id IS NULL THEN
            RAISE EXCEPTION
                'El TEAM marcador no tiene integrante vigente para sustituir al marker.';
        END IF;

        SELECT cs.holes_expected
          INTO v_holes_expected
          FROM public.tournament_scorecard_capture_sessions cs
         WHERE cs.score_card_id=v_assignment.score_card_id;

        SELECT COALESCE(max(hs.play_sequence),0)+1
          INTO v_from_sequence
          FROM public.tournament_scorecard_hole_scores hs
         WHERE hs.score_card_id=v_assignment.score_card_id
           AND hs.result_type='SCORE';

        IF v_from_sequence<=COALESCE(v_holes_expected,0) THEN
            UPDATE public.tournament_scorecard_marker_assignments
               SET status='ended',
                   valid_to_sequence=CASE
                       WHEN v_from_sequence>valid_from_sequence
                           THEN v_from_sequence-1
                       ELSE NULL
                   END,
                   ended_at=now(),
                   change_reason=btrim(p_reason)
             WHERE id=v_assignment.id;

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
            SELECT
                p_tournament_round_id,
                target_sc.validation_group_id,
                v_assignment.score_card_id,
                v_assignment.marker_score_card_id,
                v_new_marker.player_id,
                v_new_marker.registration_id,
                'composition_refresh_team',
                v_from_sequence,
                'active',
                p_admin_id,
                btrim(p_reason)
            FROM public.tournament_score_cards target_sc
            WHERE target_sc.id=v_assignment.score_card_id;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'revisedCards',v_count,
        'emissionId',v_emission.id,
        'emissionRepointed',true,
        'validationId',v_validation.id,
        'validationVersion',v_validation.version
    );
END;
$$;

-- ============================================================================
-- 6. Reasignación de integrante entre equipos DESPUÉS de emisión
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reasignar_inscripcion_equipo_a_gogo_post_emision(
    p_tournament_registration_id uuid,
    p_new_team_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_reg public.tournament_registrations%ROWTYPE;
    v_old_team_id uuid;
    v_tournament_id uuid;
    v_admin_id uuid;
    v_old_validation record;
    v_base_result jsonb;
    v_change_id uuid;
    v_hcp jsonb;
    v_preview jsonb;
    v_validation_result jsonb;
    v_revision_result jsonb;
    v_rounds jsonb:='[]'::jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF length(btrim(COALESCE(p_reason,'')))<5 THEN
        RAISE EXCEPTION 'El motivo debe contener al menos 5 caracteres.';
    END IF;

    SELECT * INTO v_reg
    FROM public.tournament_registrations
    WHERE id=p_tournament_registration_id
      AND activo
    FOR UPDATE;

    IF v_reg.id IS NULL OR v_reg.tournament_team_id IS NULL THEN
        RAISE EXCEPTION 'La inscripción activa no pertenece a un equipo.';
    END IF;

    v_tournament_id:=v_reg.tournament_id;
    v_old_team_id:=v_reg.tournament_team_id;

    IF v_old_team_id=p_new_team_id THEN
        RAISE EXCEPTION 'La inscripción ya pertenece al equipo destino.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para modificar equipos.' USING ERRCODE='42501';
    END IF;

    SELECT au.id INTO v_admin_id
    FROM public.admin_users au
    WHERE au.auth_user_id=auth.uid() AND au.activo
    ORDER BY au.id LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No existe administrador activo asociado.';
    END IF;

    IF NOT EXISTS(
        SELECT 1
        FROM public.tournament_score_card_emissions e
        WHERE e.tournament_id=v_tournament_id
          AND e.status='issued'
    ) THEN
        RAISE EXCEPTION
            'No existen tarjetas emitidas. Utiliza el flujo post-validación normal.';
    END IF;

    PERFORM set_config('app.revisar_tarjeta_team_post_emision','true',true);
    PERFORM set_config('app.reabrir_validacion_salida_ronda','true',true);

    CREATE TEMP TABLE pg_temp.tmp_old_validations_215
    ON COMMIT DROP
    AS
    SELECT v.*
    FROM public.tournament_round_start_validations v
    WHERE v.tournament_id=v_tournament_id
      AND v.status='validated'
      AND v.start_format='shotgun'
      AND v.participation_type='equipo'
      AND v.scoring_engine='team_stroke';

    UPDATE public.tournament_round_start_validations v
       SET status='reopened',
           reopened_at=now(),
           reopened_by=v_admin_id,
           reopen_reason='Cambio composición A-Go-Go post-emisión: '||btrim(p_reason)
     WHERE v.id IN (SELECT id FROM pg_temp.tmp_old_validations_215);

    v_base_result:=public.reasignar_inscripcion_equipo_a_gogo_post_freeze(
        p_tournament_registration_id,
        p_new_team_id,
        p_reason
    );

    v_change_id:=NULLIF(v_base_result->>'changeId','')::uuid;
    IF v_change_id IS NULL THEN
        RAISE EXCEPTION 'La reasignación no devolvió changeId.';
    END IF;

    -- Una tarjeta TEAM emitida no puede quedar sin integrantes.
    IF NOT EXISTS(
        SELECT 1 FROM public.tournament_registrations r
        WHERE r.tournament_id=v_tournament_id
          AND r.tournament_team_id=v_old_team_id
          AND r.activo
    ) THEN
        RAISE EXCEPTION
            'El cambio dejaría al equipo origen sin integrantes y fue revertido.';
    END IF;

    FOR v_old_validation IN
        SELECT * FROM pg_temp.tmp_old_validations_215
        ORDER BY tournament_round_id
    LOOP
        v_hcp:=public.recalcular_handicap_equipo_a_gogo(
            v_old_validation.tournament_round_id,
            v_old_team_id
        );

        v_hcp:=public.recalcular_handicap_equipo_a_gogo(
            v_old_validation.tournament_round_id,
            p_new_team_id
        );

        v_preview:=public.previsualizar_validacion_salidas_ronda(
            v_old_validation.tournament_round_id
        );

        IF NOT COALESCE((v_preview->>'ready')::boolean,false) THEN
            RAISE EXCEPTION
                'El cambio dejaría la ronda no validable y fue revertido.'
                USING ERRCODE='23514',DETAIL=(v_preview->'errors')::text;
        END IF;

        v_validation_result:=public.validar_salidas_ronda(
            v_old_validation.tournament_round_id
        );

        v_revision_result:=public._revisar_tarjetas_team_ronda_post_emision_215(
            v_old_validation.tournament_round_id,
            v_admin_id,
            'team_reassignment',
            v_change_id,
            p_reason
        );

        v_rounds:=v_rounds||jsonb_build_array(
            jsonb_build_object(
                'tournamentRoundId',v_old_validation.tournament_round_id,
                'oldValidationId',v_old_validation.id,
                'oldValidationVersion',v_old_validation.version,
                'validation',v_validation_result,
                'cardRevision',v_revision_result
            )
        );
    END LOOP;

    UPDATE public.tournament_team_composition_changes
       SET metadata=COALESCE(metadata,'{}'::jsonb)||jsonb_build_object(
           'phase','215_FASE11B1',
           'postEmission',true,
           'sameScoreCardId',true,
           'roundRevisions',v_rounds
       )
     WHERE id=v_change_id;

    RETURN v_base_result||jsonb_build_object(
        'postEmission',true,
        'sameScoreCardId',true,
        'roundRevisions',v_rounds
    );
END;
$$;

-- ============================================================================
-- 7. Sustitución de integrante DESPUÉS de emisión
-- ============================================================================

CREATE OR REPLACE FUNCTION public.confirmar_sustitucion_integrante_a_gogo_post_emision(
    p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_request public.tournament_team_substitution_requests%ROWTYPE;
    v_admin_id uuid;
    v_old_validation record;
    v_base_result jsonb;
    v_change_id uuid;
    v_preview jsonb;
    v_validation_result jsonb;
    v_revision_result jsonb;
    v_rounds jsonb:='[]'::jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT * INTO v_request
    FROM public.tournament_team_substitution_requests
    WHERE id=p_request_id
    FOR UPDATE;

    IF v_request.id IS NULL
       OR v_request.status<>'pending_confirmation'
    THEN
        RAISE EXCEPTION 'La sustitución no existe o ya no está pendiente.';
    END IF;

    v_admin_id:=v_request.requested_by_admin_id;

    IF NOT EXISTS(
        SELECT 1 FROM public.tournament_score_card_emissions e
        WHERE e.tournament_id=v_request.tournament_id
          AND e.status='issued'
    ) THEN
        RAISE EXCEPTION
            'No existen tarjetas emitidas. Utiliza el flujo post-validación normal.';
    END IF;

    PERFORM set_config('app.revisar_tarjeta_team_post_emision','true',true);
    PERFORM set_config('app.reabrir_validacion_salida_ronda','true',true);

    CREATE TEMP TABLE pg_temp.tmp_old_validations_215
    ON COMMIT DROP
    AS
    SELECT v.*
    FROM public.tournament_round_start_validations v
    WHERE v.tournament_id=v_request.tournament_id
      AND v.status='validated'
      AND v.start_format='shotgun'
      AND v.participation_type='equipo'
      AND v.scoring_engine='team_stroke';

    UPDATE public.tournament_round_start_validations v
       SET status='reopened',
           reopened_at=now(),
           reopened_by=v_admin_id,
           reopen_reason='Sustitución A-Go-Go post-emisión: '||btrim(v_request.reason)
     WHERE v.id IN (SELECT id FROM pg_temp.tmp_old_validations_215);

    -- Reutiliza toda la validación de identidad/roster/pago de Fase 202.
    v_base_result:=public.confirmar_sustitucion_integrante_a_gogo(
        p_request_id
    );

    v_change_id:=NULLIF(v_base_result->>'changeId','')::uuid;
    IF v_change_id IS NULL THEN
        RAISE EXCEPTION 'La sustitución no devolvió changeId.';
    END IF;

    FOR v_old_validation IN
        SELECT * FROM pg_temp.tmp_old_validations_215
        ORDER BY tournament_round_id
    LOOP
        PERFORM public.recalcular_handicap_equipo_a_gogo(
            v_old_validation.tournament_round_id,
            v_request.tournament_team_id
        );

        v_preview:=public.previsualizar_validacion_salidas_ronda(
            v_old_validation.tournament_round_id
        );

        IF NOT COALESCE((v_preview->>'ready')::boolean,false) THEN
            RAISE EXCEPTION
                'La sustitución dejaría la ronda no validable y fue revertida.'
                USING ERRCODE='23514',DETAIL=(v_preview->'errors')::text;
        END IF;

        v_validation_result:=public.validar_salidas_ronda(
            v_old_validation.tournament_round_id
        );

        v_revision_result:=public._revisar_tarjetas_team_ronda_post_emision_215(
            v_old_validation.tournament_round_id,
            v_admin_id,
            'player_substitution',
            v_change_id,
            v_request.reason
        );

        v_rounds:=v_rounds||jsonb_build_array(
            jsonb_build_object(
                'tournamentRoundId',v_old_validation.tournament_round_id,
                'oldValidationId',v_old_validation.id,
                'oldValidationVersion',v_old_validation.version,
                'validation',v_validation_result,
                'cardRevision',v_revision_result
            )
        );
    END LOOP;

    UPDATE public.tournament_team_composition_changes
       SET metadata=COALESCE(metadata,'{}'::jsonb)||jsonb_build_object(
           'phase','215_FASE11B1',
           'postEmission',true,
           'sameScoreCardId',true,
           'roundRevisions',v_rounds
       )
     WHERE id=v_change_id;

    RETURN v_base_result||jsonb_build_object(
        'postEmission',true,
        'sameScoreCardId',true,
        'roundRevisions',v_rounds
    );
END;
$$;

-- ============================================================================
-- 8. Consulta de historial de revisiones TEAM
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_revisiones_tarjeta_equipo_a_gogo(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_tournament_id uuid;
BEGIN
    SELECT tournament_id INTO v_tournament_id
    FROM public.tournament_score_cards
    WHERE id=p_score_card_id
      AND unit_type='team';

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta TEAM no existe.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar el historial.'
            USING ERRCODE='42501';
    END IF;

    RETURN jsonb_build_object(
        'scoreCardId',p_score_card_id,
        'revisions',COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'revisionId',r.id,
                    'revisionNumber',r.revision_number,
                    'sourceType',r.source_type,
                    'sourceId',r.source_id,
                    'oldValidationId',r.old_validation_id,
                    'oldValidationVersion',r.old_validation_version,
                    'newValidationId',r.new_validation_id,
                    'newValidationVersion',r.new_validation_version,
                    'oldTeamHandicapVersionId',r.old_team_handicap_version_id,
                    'newTeamHandicapVersionId',r.new_team_handicap_version_id,
                    'reason',r.reason,
                    'changedByAdminId',r.changed_by_admin_id,
                    'createdAt',r.created_at,
                    'before',r.before_snapshot,
                    'after',r.after_snapshot
                )
                ORDER BY r.revision_number
            )
            FROM public.tournament_team_scorecard_revisions r
            WHERE r.score_card_id=p_score_card_id
        ),'[]'::jsonb)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.reasignar_inscripcion_equipo_a_gogo_post_emision(uuid,uuid,text)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.reasignar_inscripcion_equipo_a_gogo_post_emision(uuid,uuid,text)
TO authenticated,service_role;

REVOKE ALL ON FUNCTION public.confirmar_sustitucion_integrante_a_gogo_post_emision(uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.confirmar_sustitucion_integrante_a_gogo_post_emision(uuid)
TO authenticated,service_role;

REVOKE ALL ON FUNCTION public.obtener_revisiones_tarjeta_equipo_a_gogo(uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.obtener_revisiones_tarjeta_equipo_a_gogo(uuid)
TO authenticated,service_role;

COMMIT;
