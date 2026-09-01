-- ============================================================================
-- MIGRACIÓN 216 FASE 11B2
-- A-Go-Go — reacomodo de salida post-emisión conservando score_card_id
-- Proyecto: Tee Central / GOLF IN FULL
--
-- ALCANCE
-- - permite mover un TEAM entre grupos/hoyos Shotgun después de emitir tarjetas;
-- - sólo antes del primer SCORE digital en los grupos afectados;
-- - conserva score_card_id, card_folio y la misma emisión;
-- - crea nueva validación formal de salidas;
-- - repunta tarjetas y sesiones de captura a la nueva validación;
-- - recalcula play_sequence únicamente para la tarjeta movida;
-- - reconstruye markers sólo en grupos origen/destino;
-- - registra historial de revisión y reacomodo;
-- - no permite operar con categoría/ronda competitivamente cerrada.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Historial 215: admitir revisión por reacomodo de salida
-- ============================================================================

ALTER TABLE public.tournament_team_scorecard_revisions
DROP CONSTRAINT IF EXISTS tournament_team_scorecard_revisions_source_type_check;

ALTER TABLE public.tournament_team_scorecard_revisions
ADD CONSTRAINT tournament_team_scorecard_revisions_source_type_check
CHECK (
    source_type IN (
        'team_reassignment',
        'player_substitution',
        'team_handicap_refresh',
        'start_rearrangement'
    )
);

-- ============================================================================
-- 2. Consistencia automática tarjeta ↔ sesión de captura
--    Corrige también futuras revisiones hechas por la Fase 215.
-- ============================================================================

CREATE OR REPLACE FUNCTION public._sincronizar_validacion_sesion_captura_team_216()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
BEGIN
    IF TG_OP='UPDATE'
       AND NEW.unit_type='team'
       AND NEW.validation_id IS DISTINCT FROM OLD.validation_id
       AND current_setting(
            'app.revisar_tarjeta_team_post_emision',true
       )='true'
    THEN
        UPDATE public.tournament_scorecard_capture_sessions
           SET validation_id=NEW.validation_id
         WHERE score_card_id=NEW.id;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_validacion_sesion_team_216
ON public.tournament_score_cards;

CREATE TRIGGER trg_sync_validacion_sesion_team_216
AFTER UPDATE ON public.tournament_score_cards
FOR EACH ROW
EXECUTE FUNCTION public._sincronizar_validacion_sesion_captura_team_216();

-- ============================================================================
-- 3. Helper: repuntar todas las tarjetas a la nueva validación,
--    registrando revisión sólo para el TEAM movido.
-- ============================================================================

CREATE OR REPLACE FUNCTION public._revisar_salida_tarjetas_team_post_emision_216(
    p_tournament_round_id uuid,
    p_moved_team_id uuid,
    p_old_validation_id uuid,
    p_source_id uuid,
    p_admin_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_new_validation public.tournament_round_start_validations%ROWTYPE;
    v_emission public.tournament_score_card_emissions%ROWTYPE;
    v_card record;
    v_new_unit record;
    v_old_snapshot public.tournament_team_scorecard_snapshots%ROWTYPE;
    v_revision integer;
    v_before jsonb;
    v_after jsonb;
    v_moved_card_id uuid;
    v_new_start_hole integer;
    v_updated integer:=0;
BEGIN
    IF length(btrim(COALESCE(p_reason,'')))<5 THEN
        RAISE EXCEPTION 'El motivo debe contener al menos 5 caracteres.';
    END IF;

    SELECT * INTO v_new_validation
    FROM public.tournament_round_start_validations v
    WHERE v.tournament_round_id=p_tournament_round_id
      AND v.status='validated'
      AND v.start_format='shotgun'
      AND v.participation_type='equipo'
      AND v.scoring_engine='team_stroke'
    ORDER BY v.version DESC
    LIMIT 1;

    IF v_new_validation.id IS NULL
       OR v_new_validation.id=p_old_validation_id
    THEN
        RAISE EXCEPTION 'No existe una nueva validación TEAM para revisar tarjetas.';
    END IF;

    SELECT * INTO v_emission
    FROM public.tournament_score_card_emissions e
    WHERE e.tournament_round_id=p_tournament_round_id
      AND e.status='issued'
    FOR UPDATE;

    IF v_emission.id IS NULL THEN
        RAISE EXCEPTION 'La ronda no tiene emisión TEAM activa.';
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
            g.hole_number
          INTO v_new_unit
          FROM public.tournament_round_start_validation_units u
          JOIN public.tournament_round_start_validation_groups g
            ON g.id=u.validation_group_id
           AND g.validation_id=u.validation_id
         WHERE u.validation_id=v_new_validation.id
           AND u.unit_type='team'
           AND u.tournament_team_id=v_card.tournament_team_id
         LIMIT 1;

        IF v_new_unit.validation_unit_id IS NULL THEN
            RAISE EXCEPTION
                'El TEAM % no existe en la nueva validación.',
                v_card.tournament_team_id;
        END IF;

        IF v_card.tournament_team_id=p_moved_team_id THEN
            v_moved_card_id:=v_card.id;
            v_new_start_hole:=v_new_unit.hole_number;

            SELECT * INTO v_old_snapshot
            FROM public.tournament_team_scorecard_snapshots ss
            WHERE ss.score_card_id=v_card.id;

            v_before:=jsonb_build_object(
                'scoreCard',to_jsonb(v_card),
                'teamSnapshot',to_jsonb(v_old_snapshot)
            );

            SELECT COALESCE(max(r.revision_number),0)+1
              INTO v_revision
              FROM public.tournament_team_scorecard_revisions r
             WHERE r.score_card_id=v_card.id;
        END IF;

        UPDATE public.tournament_score_cards
           SET validation_id=v_new_validation.id,
               validation_version=v_new_validation.version,
               validation_group_id=v_new_unit.validation_group_id,
               validation_unit_id=v_new_unit.validation_unit_id
         WHERE id=v_card.id;

        -- La asignación activa debe seguir el grupo validado actual de su target.
        UPDATE public.tournament_scorecard_marker_assignments
           SET validation_group_id=v_new_unit.validation_group_id
         WHERE score_card_id=v_card.id
           AND status='active';

        v_updated:=v_updated+1;
    END LOOP;

    IF v_moved_card_id IS NULL THEN
        RAISE EXCEPTION 'No se encontró la tarjeta del TEAM movido.';
    END IF;

    -- Sólo la tarjeta movida cambia su hoyo de inicio y por tanto su secuencia.
    WITH seq AS (
        SELECT
            hs.id,
            row_number() OVER(
                ORDER BY
                    CASE
                        WHEN hs.hole_number>=v_new_start_hole THEN 0
                        ELSE 1
                    END,
                    hs.hole_number
            )::integer AS new_sequence
        FROM public.tournament_scorecard_hole_scores hs
        WHERE hs.score_card_id=v_moved_card_id
    )
    UPDATE public.tournament_scorecard_hole_scores hs
       SET play_sequence=seq.new_sequence
      FROM seq
     WHERE hs.id=seq.id
       AND hs.play_sequence IS DISTINCT FROM seq.new_sequence;

    UPDATE public.tournament_score_card_emissions
       SET validation_id=v_new_validation.id,
           validation_version=v_new_validation.version
     WHERE id=v_emission.id;

    SELECT jsonb_build_object(
        'scoreCard',to_jsonb(sc),
        'teamSnapshot',to_jsonb(ss)
    ) INTO v_after
    FROM public.tournament_score_cards sc
    JOIN public.tournament_team_scorecard_snapshots ss
      ON ss.score_card_id=sc.id
    WHERE sc.id=v_moved_card_id;

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
    SELECT
        sc.tournament_id,
        p_tournament_round_id,
        sc.id,
        sc.tournament_team_id,
        v_revision,
        'start_rearrangement',
        p_source_id,
        p_old_validation_id,
        (v_before#>>'{scoreCard,validation_version}')::integer,
        v_new_validation.id,
        v_new_validation.version,
        v_old_snapshot.team_handicap_version_id,
        v_old_snapshot.team_handicap_version_id,
        v_before,
        v_after,
        btrim(p_reason),
        p_admin_id
    FROM public.tournament_score_cards sc
    WHERE sc.id=v_moved_card_id;

    RETURN jsonb_build_object(
        'scoreCardId',v_moved_card_id,
        'sameScoreCardId',true,
        'updatedCards',v_updated,
        'newValidationId',v_new_validation.id,
        'newValidationVersion',v_new_validation.version,
        'newStartHole',v_new_start_hole
    );
END;
$$;

-- ============================================================================
-- 4. Helper: reconstruir markers únicamente en grupos afectados.
--    Se usa sólo antes de cualquier SCORE en esos grupos.
-- ============================================================================

CREATE OR REPLACE FUNCTION public._reconstruir_markers_grupos_team_216(
    p_tournament_round_id uuid,
    p_validation_group_ids uuid[],
    p_admin_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_assignment_count integer:=0;
BEGIN
    IF COALESCE(cardinality(p_validation_group_ids),0)=0 THEN
        RETURN jsonb_build_object('rebuiltGroups',0,'assignments',0);
    END IF;

    -- Ninguna tarjeta afectada puede tener SCORE digital capturado.
    IF EXISTS(
        SELECT 1
        FROM public.tournament_score_cards sc
        JOIN public.tournament_scorecard_hole_scores hs
          ON hs.score_card_id=sc.id
        WHERE sc.tournament_round_id=p_tournament_round_id
          AND sc.validation_group_id=ANY(p_validation_group_ids)
          AND sc.status='issued'
          AND hs.result_type='SCORE'
    ) THEN
        RAISE EXCEPTION
            'Uno de los grupos afectados ya inició captura digital y sus markers no pueden reconstruirse como salida.'
            USING ERRCODE='55000';
    END IF;

    UPDATE public.tournament_scorecard_marker_assignments ma
       SET status='ended',
           valid_to_sequence=NULL,
           ended_at=now(),
           change_reason=btrim(p_reason)
     WHERE ma.tournament_round_id=p_tournament_round_id
       AND ma.validation_group_id=ANY(p_validation_group_ids)
       AND ma.status='active';

    WITH group_cards AS (
        SELECT
            sc.validation_group_id,
            array_agg(
                sc.id ORDER BY u.order_in_group,sc.id
            ) AS card_ids
        FROM public.tournament_score_cards sc
        JOIN public.tournament_round_start_validation_units u
          ON u.id=sc.validation_unit_id
         AND u.validation_id=sc.validation_id
        WHERE sc.tournament_round_id=p_tournament_round_id
          AND sc.validation_group_id=ANY(p_validation_group_ids)
          AND sc.status='issued'
          AND sc.unit_type='team'
        GROUP BY sc.validation_group_id
    ), proposed AS (
        SELECT
            gc.validation_group_id,
            gc.card_ids[i] AS target_card_id,
            gc.card_ids[
                CASE
                    WHEN i=1 THEN array_length(gc.card_ids,1)
                    ELSE i-1
                END
            ] AS marker_card_id,
            array_length(gc.card_ids,1) AS group_size
        FROM group_cards gc
        CROSS JOIN LATERAL generate_subscripts(gc.card_ids,1) s(i)
    ), marker_member AS (
        SELECT
            p.*,
            NULLIF(m->>'playerId','')::uuid AS marker_player_id,
            NULLIF(m->>'registrationId','')::uuid AS marker_registration_id
        FROM proposed p
        LEFT JOIN LATERAL (
            SELECT m
            FROM public.tournament_team_scorecard_snapshots ss
            CROSS JOIN LATERAL jsonb_array_elements(ss.members_snapshot) m
            WHERE ss.score_card_id=p.marker_card_id
              AND NULLIF(m->>'playerId','') IS NOT NULL
              AND NULLIF(m->>'registrationId','') IS NOT NULL
            ORDER BY
                COALESCE(NULLIF(m->>'whsRank','')::integer,2147483647),
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
        assigned_by,
        change_reason
    )
    SELECT
        p_tournament_round_id,
        mm.validation_group_id,
        mm.target_card_id,
        mm.marker_card_id,
        mm.marker_player_id,
        mm.marker_registration_id,
        'circular_team',
        1,
        'active',
        p_admin_id,
        btrim(p_reason)
    FROM marker_member mm
    WHERE mm.group_size>=2
      AND mm.target_card_id<>mm.marker_card_id
      AND mm.marker_player_id IS NOT NULL
      AND mm.marker_registration_id IS NOT NULL;

    GET DIAGNOSTICS v_assignment_count=ROW_COUNT;

    RETURN jsonb_build_object(
        'rebuiltGroups',cardinality(p_validation_group_ids),
        'assignments',v_assignment_count
    );
END;
$$;

-- ============================================================================
-- 5. RPC pública administrativa: mover TEAM post-emisión
-- ============================================================================

CREATE OR REPLACE FUNCTION public.mover_equipo_shotgun_post_emision_a_gogo(
    p_config_id uuid,
    p_tournament_team_id uuid,
    p_destino_hole_id uuid,
    p_destino_posicion text,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_auth_uid uuid;
    v_admin_id uuid;
    v_tournament_id uuid;
    v_round_id uuid;
    v_category_id uuid;
    v_old_validation public.tournament_round_start_validations%ROWTYPE;
    v_new_validation public.tournament_round_start_validations%ROWTYPE;
    v_old_source_group_id uuid;
    v_dest_source_group_id uuid;
    v_new_source_group_id uuid;
    v_move jsonb;
    v_preview jsonb;
    v_validation_result jsonb;
    v_card_revision jsonb;
    v_marker_refresh jsonb;
    v_audit_id uuid;
    v_affected_new_groups uuid[];
BEGIN
    v_auth_uid:=auth.uid();

    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF length(btrim(COALESCE(p_reason,'')))<5 THEN
        RAISE EXCEPTION 'El motivo debe contener al menos 5 caracteres.';
    END IF;

    IF upper(btrim(COALESCE(p_destino_posicion,''))) NOT IN ('A','B') THEN
        RAISE EXCEPTION 'La posición destino debe ser A o B.';
    END IF;

    SELECT
        tr.tournament_id,
        tr.id,
        sc.tournament_category_id
      INTO v_tournament_id,v_round_id,v_category_id
      FROM public.tournament_shotgun_category_configs cfg
      JOIN public.tournament_round_shift_categories sc
        ON sc.id=cfg.tournament_round_shift_category_id
       AND sc.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id=sc.tournament_round_shift_id
       AND rs.activo
      JOIN public.tournament_rounds tr
        ON tr.id=rs.tournament_round_id
       AND tr.activo
      JOIN public.tournaments t
        ON t.id=tr.tournament_id
       AND t.activo
      JOIN public.tournament_formats tf
        ON tf.id=COALESCE(tr.tournament_format_id,t.tournament_format_id)
     WHERE cfg.id=p_config_id
       AND cfg.activo
       AND tr.formato_salida='shotgun'::public.formato_salida_ronda
       AND tf.tipo_participacion::text='equipo'
       AND tf.scoring_engine::text='team_stroke';

    IF v_round_id IS NULL THEN
        RAISE EXCEPTION 'La configuración no corresponde a A-Go-Go Shotgun.';
    END IF;

    IF NOT public.can_manage_tournament_shotgun_config(v_auth_uid,p_config_id)
       OR NOT public.puede_administrar_congelamiento_torneo(v_tournament_id)
    THEN
        RAISE EXCEPTION 'No tienes permisos para modificar estas salidas.'
            USING ERRCODE='42501';
    END IF;

    SELECT au.id INTO v_admin_id
    FROM public.admin_users au
    WHERE au.auth_user_id=v_auth_uid
      AND au.activo
    ORDER BY au.id LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No existe administrador activo asociado.';
    END IF;

    PERFORM public._bloquear_salida_ronda(v_round_id);

    IF NOT public._ronda_tiene_tarjetas_emitidas(v_round_id) THEN
        RAISE EXCEPTION
            'La ronda aún no tiene tarjetas emitidas. Utiliza el flujo post-validación normal.';
    END IF;

    IF public._ronda_esta_cerrada_competitivamente(v_round_id)
       OR public._categoria_ronda_esta_cerrada_competitivamente(
            v_round_id,v_category_id
       )
    THEN
        RAISE EXCEPTION
            'La ronda o categoría ya está cerrada competitivamente.'
            USING ERRCODE='55000';
    END IF;

    SELECT * INTO v_old_validation
    FROM public.tournament_round_start_validations v
    WHERE v.tournament_round_id=v_round_id
      AND v.status='validated'
      AND v.start_format='shotgun'
      AND v.participation_type='equipo'
      AND v.scoring_engine='team_stroke'
    FOR UPDATE;

    IF v_old_validation.id IS NULL THEN
        RAISE EXCEPTION 'No existe validación A-Go-Go activa.';
    END IF;

    SELECT g.id
      INTO v_old_source_group_id
      FROM public.tournament_group_teams gt
      JOIN public.tournament_groups g
        ON g.id=gt.tournament_group_id
       AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id=g.tournament_round_shift_id
       AND rs.tournament_round_id=v_round_id
     WHERE gt.tournament_team_id=p_tournament_team_id
       AND gt.activo
     LIMIT 1;

    IF v_old_source_group_id IS NULL THEN
        RAISE EXCEPTION 'El TEAM no está asignado a un grupo activo.';
    END IF;

    -- Resolver grupo destino existente sin crearlo todavía.
    SELECT g.id
      INTO v_dest_source_group_id
      FROM public.tournament_shotgun_category_holes sh
      JOIN public.tournament_groups g
        ON g.tournament_shotgun_category_hole_id=sh.id
       AND g.activo
     WHERE sh.tournament_shotgun_category_config_id=p_config_id
       AND sh.hoyo_id=p_destino_hole_id
       AND g.posicion_salida=upper(btrim(p_destino_posicion))
     LIMIT 1;

    -- Antes de tocar la validación: origen y destino no pueden haber iniciado.
    IF EXISTS(
        SELECT 1
        FROM public.tournament_score_cards sc
        JOIN public.tournament_round_start_validation_groups vg
          ON vg.id=sc.validation_group_id
         AND vg.validation_id=sc.validation_id
        JOIN public.tournament_scorecard_hole_scores hs
          ON hs.score_card_id=sc.id
        WHERE sc.tournament_round_id=v_round_id
          AND sc.status='issued'
          AND vg.source_group_id=ANY(
              array_remove(
                  ARRAY[v_old_source_group_id,v_dest_source_group_id]::uuid[],
                  NULL
              )
          )
          AND hs.result_type='SCORE'
    ) THEN
        RAISE EXCEPTION
            'El grupo origen o destino ya inició captura. El reacomodo de salida post-emisión ya no está permitido.'
            USING ERRCODE='55000';
    END IF;

    PERFORM set_config('app.revisar_tarjeta_team_post_emision','true',true);
    PERFORM set_config('app.reabrir_validacion_salida_ronda','true',true);

    UPDATE public.tournament_round_start_validations
       SET status='reopened',
           reopened_at=now(),
           reopened_by=v_admin_id,
           reopen_reason='Reacomodo A-Go-Go post-emisión: '||btrim(p_reason)
     WHERE id=v_old_validation.id;

    v_move:=public.mover_unidad_shotgun(
        p_config_id,
        p_tournament_team_id,
        'equipo',
        p_destino_hole_id,
        upper(btrim(p_destino_posicion))
    );

    v_new_source_group_id:=NULLIF(v_move#>>'{destino,groupId}','')::uuid;
    IF v_new_source_group_id IS NULL THEN
        v_new_source_group_id:=NULLIF(v_move->>'groupId','')::uuid;
    END IF;

    IF v_new_source_group_id IS NULL THEN
        RAISE EXCEPTION 'El movimiento no devolvió grupo destino.';
    END IF;

    v_preview:=public.previsualizar_validacion_salidas_ronda(v_round_id);
    IF NOT COALESCE((v_preview->>'ready')::boolean,false) THEN
        RAISE EXCEPTION
            'El movimiento dejaría las salidas no validables y fue revertido.'
            USING ERRCODE='23514',DETAIL=(v_preview->'errors')::text;
    END IF;

    v_validation_result:=public.validar_salidas_ronda(v_round_id);

    SELECT * INTO v_new_validation
    FROM public.tournament_round_start_validations v
    WHERE v.tournament_round_id=v_round_id
      AND v.status='validated'
    ORDER BY v.version DESC LIMIT 1;

    IF v_new_validation.id IS NULL
       OR v_new_validation.version<=v_old_validation.version
    THEN
        RAISE EXCEPTION 'No se creó una nueva validación formal.';
    END IF;

    INSERT INTO public.tournament_round_start_local_rearrangements(
        tournament_id,
        tournament_round_id,
        tournament_team_id,
        old_validation_id,
        new_validation_id,
        old_validation_version,
        new_validation_version,
        old_group_id,
        new_group_id,
        reason,
        changed_by_admin_id,
        movement_result,
        validation_result
    )
    VALUES(
        v_tournament_id,
        v_round_id,
        p_tournament_team_id,
        v_old_validation.id,
        v_new_validation.id,
        v_old_validation.version,
        v_new_validation.version,
        v_old_source_group_id,
        v_new_source_group_id,
        btrim(p_reason),
        v_admin_id,
        v_move,
        v_validation_result
    )
    RETURNING id INTO v_audit_id;

    v_card_revision:=public._revisar_salida_tarjetas_team_post_emision_216(
        v_round_id,
        p_tournament_team_id,
        v_old_validation.id,
        v_audit_id,
        v_admin_id,
        p_reason
    );

    -- IDs de los grupos NUEVOS equivalentes a origen/destino.
    SELECT COALESCE(array_agg(vg.id ORDER BY vg.id),ARRAY[]::uuid[])
      INTO v_affected_new_groups
      FROM public.tournament_round_start_validation_groups vg
     WHERE vg.validation_id=v_new_validation.id
       AND vg.source_group_id=ANY(
           array_remove(
               ARRAY[v_old_source_group_id,v_new_source_group_id]::uuid[],
               NULL
           )
       );

    v_marker_refresh:=public._reconstruir_markers_grupos_team_216(
        v_round_id,
        v_affected_new_groups,
        v_admin_id,
        p_reason
    );

    RETURN jsonb_build_object(
        'success',true,
        'auditId',v_audit_id,
        'tournamentRoundId',v_round_id,
        'teamId',p_tournament_team_id,
        'sameScoreCardId',true,
        'oldValidationId',v_old_validation.id,
        'oldValidationVersion',v_old_validation.version,
        'newValidationId',v_new_validation.id,
        'newValidationVersion',v_new_validation.version,
        'movement',v_move,
        'cardRevision',v_card_revision,
        'markerRefresh',v_marker_refresh
    );
END;
$$;

REVOKE ALL ON FUNCTION public.mover_equipo_shotgun_post_emision_a_gogo(
    uuid,uuid,uuid,text,text
) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.mover_equipo_shotgun_post_emision_a_gogo(
    uuid,uuid,uuid,text,text
) TO authenticated,service_role;

COMMIT;
