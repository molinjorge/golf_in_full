-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 329
-- BEST BALL F15 — REVISION POST-EMISION / PRE-INICIO
-- ============================================================================
-- REGLA:
--   Se permite reconstruir la composición congelada Best Ball después de
--   emitir tarjetas, SOLAMENTE mientras la ronda permanezca PENDIENTE.
--
--   Una vez EN_JUEGO o FINALIZADA, la composición deportiva queda cerrada.
--
-- ALCANCE:
--   - conserva score_card_id;
--   - sincroniza snapshot TEAM con tournament_registrations actuales;
--   - exige 2..5 integrantes por equipo emitido;
--   - exige RHS individual congelado válido para cada integrante;
--   - reconstruye únicamente filas PENDING Best Ball;
--   - finaliza marcadores activos y los vuelve a generar;
--   - registra auditoría antes/después;
--   - NO usa HCP TEAM;
--   - NO modifica Stroke, Stableford ni A-Go-Go.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.tournament_best_ball_scorecard_revisions (
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
    reason text NOT NULL CHECK (length(btrim(reason)) >= 10),
    before_snapshot jsonb NOT NULL,
    after_snapshot jsonb NOT NULL,
    revised_by_admin_id uuid NOT NULL,
    revised_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_best_ball_scorecard_revisions_card_revision_uk
        UNIQUE(score_card_id, revision_number)
);

CREATE INDEX IF NOT EXISTS tournament_best_ball_scorecard_revisions_round_idx
    ON public.tournament_best_ball_scorecard_revisions
       (tournament_round_id, revised_at, score_card_id);

CREATE OR REPLACE FUNCTION public.revisar_tarjetas_best_ball_post_emision_329(
    p_tournament_round_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_admin_id uuid;
    v_state jsonb;
    v_status text;
    v_emission_id uuid;
    v_validation_id uuid;
    v_round_condition_snapshot_id uuid;
    v_card_count integer:=0;
    v_bad integer:=0;
    v_revised integer:=0;
    v_marker_result jsonb;
    r record;
    v_snapshot_id uuid;
    v_before jsonb;
    v_after jsonb;
    v_revision_number integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_reason IS NULL OR length(btrim(p_reason))<10 THEN
        RAISE EXCEPTION 'El motivo de revisión debe tener al menos 10 caracteres.'
            USING ERRCODE='22023';
    END IF;

    SELECT tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds
     WHERE id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.' USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para revisar tarjetas Best Ball.'
            USING ERRCODE='42501';
    END IF;

    v_admin_id:=public._scorecard_current_admin_id();
    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No existe administrador activo asociado.'
            USING ERRCODE='42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(p_tournament_round_id);

    v_state:=public.obtener_estado_operativo_ronda_314(p_tournament_round_id);
    v_status:=v_state->>'status';

    IF v_status IS DISTINCT FROM 'PENDIENTE' THEN
        RAISE EXCEPTION
          'La composición Best Ball sólo puede revisarse antes de iniciar la ronda. Estado actual: %.',
          COALESCE(v_status,'DESCONOCIDO')
          USING ERRCODE='55000';
    END IF;

    SELECT e.id,e.validation_id,v.round_condition_snapshot_id
      INTO v_emission_id,v_validation_id,v_round_condition_snapshot_id
      FROM public.tournament_score_card_emissions e
      JOIN public.tournament_round_start_validations v
        ON v.id=e.validation_id
       AND v.tournament_round_id=e.tournament_round_id
     WHERE e.tournament_round_id=p_tournament_round_id
       AND e.status='issued'
       AND v.participation_type='equipo'
       AND v.scoring_engine='best_ball'
       AND v.validator_engine='best_ball_team_shotgun_v1'
     LIMIT 1;

    IF v_emission_id IS NULL THEN
        RAISE EXCEPTION 'La ronda no tiene emisión oficial Best Ball TEAM.'
            USING ERRCODE='23514';
    END IF;

    SELECT count(*) INTO v_card_count
      FROM public.tournament_score_cards sc
     WHERE sc.emission_id=v_emission_id
       AND sc.status='issued'
       AND sc.unit_type='team';

    IF v_card_count=0 THEN
        RAISE EXCEPTION 'No existen tarjetas TEAM Best Ball emitidas.'
            USING ERRCODE='55000';
    END IF;

    -- F15 no admite evidencia deportiva previa. Todo debe seguir virgen/PENDING.
    SELECT count(*) INTO v_bad
      FROM public.tournament_best_ball_hole_scores hs
      JOIN public.tournament_score_cards sc ON sc.id=hs.score_card_id
     WHERE sc.emission_id=v_emission_id
       AND (
          hs.status IS DISTINCT FROM 'pending'
          OR hs.result_type IS DISTINCT FROM 'PENDING'
          OR hs.gross_score IS NOT NULL
          OR hs.marker_assignment_id IS NOT NULL
          OR hs.entered_by_player_id IS NOT NULL
          OR hs.entered_at IS NOT NULL
       );

    IF v_bad>0 THEN
        RAISE EXCEPTION
          'No puede revisarse la composición: existen scores Best Ball ya capturados.'
          USING ERRCODE='55000';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_scorecard_physical_receptions pr
        JOIN public.tournament_score_cards sc ON sc.id=pr.score_card_id
        WHERE sc.emission_id=v_emission_id
    ) OR EXISTS (
        SELECT 1
        FROM public.tournament_scorecard_reconciliations rc
        JOIN public.tournament_score_cards sc ON sc.id=rc.score_card_id
        WHERE sc.emission_id=v_emission_id
    ) THEN
        RAISE EXCEPTION
          'No puede revisarse la composición: ya existe evidencia física o conciliación.'
          USING ERRCODE='55000';
    END IF;

    -- Cada equipo que tiene tarjeta emitida debe seguir existiendo y tener 2..5
    -- inscripciones activas. F15 no crea tarjetas para equipos nuevos.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_score_cards sc
        LEFT JOIN public.tournament_teams tt
          ON tt.id=sc.tournament_team_id
         AND tt.tournament_id=v_tournament_id
         AND tt.activo=true
        LEFT JOIN public.tournament_registrations tr
          ON tr.tournament_team_id=sc.tournament_team_id
         AND tr.tournament_id=v_tournament_id
         AND tr.activo=true
        WHERE sc.emission_id=v_emission_id
          AND sc.status='issued'
          AND sc.unit_type='team'
        GROUP BY sc.id,tt.id
        HAVING tt.id IS NULL OR count(tr.id) NOT BETWEEN 2 AND 5
    ) THEN
        RAISE EXCEPTION
          'Cada equipo Best Ball ya emitido debe conservar entre 2 y 5 inscripciones activas.'
          USING ERRCODE='55000';
    END IF;

    -- No puede aparecer un equipo activo con integrantes que no tenga tarjeta emitida:
    -- eso requiere volver a validar/emitir, fuera de F15.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_registrations tr
        JOIN public.tournament_teams tt
          ON tt.id=tr.tournament_team_id
         AND tt.tournament_id=v_tournament_id
         AND tt.activo=true
        WHERE tr.tournament_id=v_tournament_id
          AND tr.activo=true
          AND tr.tournament_team_id IS NOT NULL
        GROUP BY tr.tournament_team_id
        HAVING count(*) BETWEEN 2 AND 5
           AND NOT EXISTS (
             SELECT 1
             FROM public.tournament_score_cards sc
             WHERE sc.emission_id=v_emission_id
               AND sc.status='issued'
               AND sc.unit_type='team'
               AND sc.tournament_team_id=tr.tournament_team_id
           )
    ) THEN
        RAISE EXCEPTION
          'Existe un equipo activo sin tarjeta emitida. F15 no crea nuevas tarjetas; debe revalidarse la salida.'
          USING ERRCODE='55000';
    END IF;

    -- Todos los integrantes actuales deben tener RHS individual congelado.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_score_cards sc
        JOIN public.tournament_registrations tr
          ON tr.tournament_team_id=sc.tournament_team_id
         AND tr.tournament_id=v_tournament_id
         AND tr.activo=true
        LEFT JOIN public.tournament_round_handicap_snapshots rhs
          ON rhs.tournament_round_id=p_tournament_round_id
         AND rhs.tournament_registration_id=tr.id
         AND rhs.player_id=tr.player_id
        WHERE sc.emission_id=v_emission_id
          AND sc.status='issued'
          AND sc.unit_type='team'
          AND (rhs.id IS NULL OR rhs.playing_handicap IS NULL)
    ) THEN
        RAISE EXCEPTION
          'Uno o más integrantes actuales no tienen snapshot individual de hándicap válido para la ronda.'
          USING ERRCODE='55000';
    END IF;

    -- Cerrar marcadores vigentes. Se reconstruyen al final con F5/319.
    UPDATE public.tournament_scorecard_marker_assignments ma
       SET status='ended',
           valid_to_sequence=0,
           ended_at=now(),
           change_reason='Best Ball F15: revisión post-emisión/pre-inicio'
     WHERE ma.tournament_round_id=p_tournament_round_id
       AND ma.status='active'
       AND EXISTS (
         SELECT 1 FROM public.tournament_score_cards sc
         WHERE sc.id=ma.score_card_id
           AND sc.emission_id=v_emission_id
       );

    FOR r IN
        SELECT sc.id score_card_id,
               sc.tournament_team_id,
               tt.nombre_equipo team_name,
               tt.tournament_category_id
        FROM public.tournament_score_cards sc
        JOIN public.tournament_teams tt
          ON tt.id=sc.tournament_team_id
        WHERE sc.emission_id=v_emission_id
          AND sc.status='issued'
          AND sc.unit_type='team'
        ORDER BY sc.card_number,sc.id
    LOOP
        SELECT ss.id INTO v_snapshot_id
        FROM public.tournament_best_ball_scorecard_snapshots ss
        WHERE ss.score_card_id=r.score_card_id;

        IF v_snapshot_id IS NULL THEN
            RAISE EXCEPTION 'Tarjeta % sin snapshot Best Ball.',r.score_card_id
                USING ERRCODE='55000';
        END IF;

        SELECT jsonb_build_object(
          'teamId',r.tournament_team_id,
          'teamName',ss.team_name,
          'members',COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'memberId',m.id,
              'registrationId',m.tournament_registration_id,
              'playerId',m.player_id,
              'roundHandicapSnapshotId',m.round_handicap_snapshot_id,
              'memberOrder',m.member_order
            ) ORDER BY m.member_order,m.player_id)
            FROM public.tournament_best_ball_scorecard_members m
            WHERE m.best_ball_scorecard_snapshot_id=ss.id
          ),'[]'::jsonb)
        )
        INTO v_before
        FROM public.tournament_best_ball_scorecard_snapshots ss
        WHERE ss.id=v_snapshot_id;

        -- Sólo se eliminan filas vírgenes PENDING, ya comprobadas arriba.
        DELETE FROM public.tournament_best_ball_hole_scores
         WHERE score_card_id=r.score_card_id;

        DELETE FROM public.tournament_best_ball_scorecard_members
         WHERE best_ball_scorecard_snapshot_id=v_snapshot_id;

        UPDATE public.tournament_best_ball_scorecard_snapshots
           SET team_name=r.team_name
         WHERE id=v_snapshot_id;

        UPDATE public.tournament_score_cards
           SET tournament_category_id=r.tournament_category_id
         WHERE id=r.score_card_id;

        INSERT INTO public.tournament_best_ball_scorecard_members(
          best_ball_scorecard_snapshot_id,
          tournament_registration_id,
          player_id,
          round_handicap_snapshot_id,
          member_order
        )
        SELECT
          v_snapshot_id,
          tr.id,
          tr.player_id,
          rhs.id,
          row_number() OVER(ORDER BY tr.created_at,tr.id)::smallint
        FROM public.tournament_registrations tr
        JOIN public.tournament_round_handicap_snapshots rhs
          ON rhs.tournament_round_id=p_tournament_round_id
         AND rhs.tournament_registration_id=tr.id
         AND rhs.player_id=tr.player_id
        WHERE tr.tournament_id=v_tournament_id
          AND tr.tournament_team_id=r.tournament_team_id
          AND tr.activo=true
        ORDER BY tr.created_at,tr.id;

        -- Reconstrucción PENDING para los integrantes actuales.
        INSERT INTO public.tournament_best_ball_hole_scores(
          capture_session_id,score_card_id,best_ball_scorecard_member_id,
          player_id,tournament_round_id,round_hole_snapshot_id,
          hole_number,play_sequence,gross_score,status,result_type
        )
        SELECT
          cs.id,r.score_card_id,m.id,m.player_id,p_tournament_round_id,h.id,
          h.hole_number,
          row_number() OVER(
            PARTITION BY m.id
            ORDER BY
              CASE WHEN h.hole_number>=g.hole_number THEN 0 ELSE 1 END,
              h.hole_number
          )::integer,
          NULL,'pending','PENDING'
        FROM public.tournament_scorecard_capture_sessions cs
        JOIN public.tournament_score_cards sc
          ON sc.id=cs.score_card_id
         AND sc.id=r.score_card_id
        JOIN public.tournament_round_start_validation_groups g
          ON g.id=sc.validation_group_id
         AND g.validation_id=sc.validation_id
        JOIN public.tournament_best_ball_scorecard_members m
          ON m.best_ball_scorecard_snapshot_id=v_snapshot_id
        JOIN public.tournament_round_hole_snapshots h
          ON h.round_condition_snapshot_id=v_round_condition_snapshot_id;

        SELECT jsonb_build_object(
          'teamId',r.tournament_team_id,
          'teamName',ss.team_name,
          'members',COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'memberId',m.id,
              'registrationId',m.tournament_registration_id,
              'playerId',m.player_id,
              'roundHandicapSnapshotId',m.round_handicap_snapshot_id,
              'memberOrder',m.member_order
            ) ORDER BY m.member_order,m.player_id)
            FROM public.tournament_best_ball_scorecard_members m
            WHERE m.best_ball_scorecard_snapshot_id=ss.id
          ),'[]'::jsonb)
        )
        INTO v_after
        FROM public.tournament_best_ball_scorecard_snapshots ss
        WHERE ss.id=v_snapshot_id;

        IF v_before IS DISTINCT FROM v_after THEN
            SELECT COALESCE(max(revision_number),0)+1
              INTO v_revision_number
              FROM public.tournament_best_ball_scorecard_revisions
             WHERE score_card_id=r.score_card_id;

            INSERT INTO public.tournament_best_ball_scorecard_revisions(
              tournament_id,tournament_round_id,score_card_id,tournament_team_id,
              revision_number,reason,before_snapshot,after_snapshot,
              revised_by_admin_id
            ) VALUES (
              v_tournament_id,p_tournament_round_id,r.score_card_id,
              r.tournament_team_id,v_revision_number,btrim(p_reason),
              v_before,v_after,v_admin_id
            );

            v_revised:=v_revised+1;
        END IF;
    END LOOP;

    -- Integridad: cada miembro actual debe volver a tener exactamente 18 PENDING.
    IF EXISTS (
      SELECT 1
      FROM public.tournament_best_ball_scorecard_snapshots ss
      JOIN public.tournament_score_cards sc
        ON sc.id=ss.score_card_id
       AND sc.emission_id=v_emission_id
       AND sc.status='issued'
      JOIN public.tournament_best_ball_scorecard_members m
        ON m.best_ball_scorecard_snapshot_id=ss.id
      LEFT JOIN public.tournament_best_ball_hole_scores hs
        ON hs.best_ball_scorecard_member_id=m.id
       AND hs.score_card_id=sc.id
      GROUP BY sc.id,m.id
      HAVING count(hs.id)<>18
         OR count(hs.id) FILTER(
              WHERE hs.status='pending'
                AND hs.result_type='PENDING'
                AND hs.gross_score IS NULL
            )<>18
    ) THEN
      RAISE EXCEPTION
        'La reconstrucción Best Ball quedó incompleta; la operación debe revertirse.'
        USING ERRCODE='55000';
    END IF;

    v_marker_result:=public._inicializar_marcadores_best_ball_319(
        p_tournament_round_id
    );

    RETURN jsonb_build_object(
      'tournamentRoundId',p_tournament_round_id,
      'engine','best_ball',
      'lifecycleStatus',v_status,
      'cardsReviewed',v_card_count,
      'cardsChanged',v_revised,
      'sameScoreCardIds',true,
      'scoresRebuiltAsPending',true,
      'markersRebuilt',true,
      'markerResult',v_marker_result
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.obtener_revisiones_tarjetas_best_ball_329(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
BEGIN
    SELECT tournament_id INTO v_tournament_id
    FROM public.tournament_rounds
    WHERE id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
      RAISE EXCEPTION 'La ronda indicada no existe.' USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
      RAISE EXCEPTION 'No tienes permiso para consultar revisiones Best Ball.'
        USING ERRCODE='42501';
    END IF;

    RETURN jsonb_build_object(
      'tournamentRoundId',p_tournament_round_id,
      'engine','best_ball',
      'revisions',COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'revisionId',r.id,
          'scoreCardId',r.score_card_id,
          'teamId',r.tournament_team_id,
          'revisionNumber',r.revision_number,
          'reason',r.reason,
          'before',r.before_snapshot,
          'after',r.after_snapshot,
          'revisedByAdminId',r.revised_by_admin_id,
          'revisedAt',r.revised_at
        ) ORDER BY r.revised_at,r.score_card_id,r.revision_number)
        FROM public.tournament_best_ball_scorecard_revisions r
        WHERE r.tournament_round_id=p_tournament_round_id
      ),'[]'::jsonb)
    );
END;
$function$;

COMMIT;
