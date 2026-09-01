-- ============================================================================
-- MIGRACIÓN 214 FASE 11A
-- A-Go-Go — experiencia digital TEAM
-- Proyecto: Tee Central / GOLF IN FULL
--
-- OBJETIVO
-- Completar el recorrido digital de un integrante TEAM sin crear un sistema
-- paralelo:
--   - puede ver su tarjeta de equipo,
--   - puede abrirla por QR,
--   - puede verla en su panel/rondas,
--   - cualquier integrante del TEAM puede confirmar/disputar,
--   - el marker vigente puede capturar,
--   - el Comité puede cambiar marker entre equipos durante la ronda.
--
-- NOTA:
-- La revisión de composición/HCP/salida DESPUÉS de emitir tarjeta pertenece a
-- Fase 11B. Esta fase consume el snapshot TEAM vigente de la tarjeta.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Visibilidad común: incorporar integrantes TEAM
-- ============================================================================

ALTER FUNCTION public.puede_ver_score_card_captura(uuid)
RENAME TO _puede_ver_score_card_captura_pre214;

CREATE OR REPLACE FUNCTION public.puede_ver_score_card_captura(
    p_score_card_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
    SELECT
        auth.uid() IS NOT NULL
        AND EXISTS (
            SELECT 1
            FROM public.tournament_score_cards sc
            WHERE sc.id=p_score_card_id
              AND sc.status='issued'
              AND (
                    public.puede_administrar_congelamiento_torneo(
                        sc.tournament_id
                    )

                    OR (
                        sc.unit_type='registration'
                        AND sc.player_id=
                            public._scorecard_current_player_id()
                    )

                    OR (
                        sc.unit_type='team'
                        AND public._jugador_es_integrante_tarjeta_equipo_209(
                            sc.id,
                            public._scorecard_current_player_id()
                        )
                    )

                    OR EXISTS (
                        SELECT 1
                        FROM public.tournament_scorecard_marker_assignments ma
                        WHERE ma.score_card_id=sc.id
                          AND ma.status='active'
                          AND ma.marker_player_id=
                              public._scorecard_current_player_id()
                    )
              )
        );
$$;

REVOKE ALL ON FUNCTION public.puede_ver_score_card_captura(uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.puede_ver_score_card_captura(uuid)
TO authenticated,service_role;


-- ============================================================================
-- 2. Abrir por QR: dispatcher individual / TEAM
-- ============================================================================

ALTER FUNCTION public.abrir_captura_tarjeta_score(text)
RENAME TO _abrir_captura_tarjeta_score_pre214;

CREATE OR REPLACE FUNCTION public.abrir_captura_tarjeta_score(
    p_qr_token text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_card record;
    v_player_id uuid;
    v_is_member boolean:=false;
    v_is_marker boolean:=false;
    v_is_admin boolean:=false;
    v_session record;
    v_active_marker record;
BEGIN
    SELECT
        sc.id,
        sc.unit_type,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.validation_id,
        sc.validation_group_id,
        sc.validation_unit_id,
        sc.tournament_team_id,
        sc.card_folio,
        sc.status
      INTO v_card
      FROM public.tournament_score_cards sc
     WHERE sc.qr_token=p_qr_token
       AND sc.status='issued'
     LIMIT 1;

    IF v_card.id IS NULL THEN
        -- Mantener exactamente el comportamiento previo para QR inválido.
        RETURN public._abrir_captura_tarjeta_score_pre214(
            p_qr_token
        );
    END IF;

    IF v_card.unit_type<>'team' THEN
        RETURN public._abrir_captura_tarjeta_score_pre214(
            p_qr_token
        );
    END IF;

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_session
      FROM public.tournament_scorecard_capture_sessions cs
     WHERE cs.score_card_id=v_card.id;

    IF v_session.id IS NULL THEN
        RAISE EXCEPTION
            'La captura de scores de esta ronda todavía no está inicializada.'
            USING ERRCODE='55000';
    END IF;

    v_player_id:=public._scorecard_current_player_id();

    v_is_member:=
        v_player_id IS NOT NULL
        AND public._jugador_es_integrante_tarjeta_equipo_209(
            v_card.id,
            v_player_id
        );

    SELECT
        ma.id,
        ma.marker_player_id,
        ma.marker_score_card_id,
        ma.valid_from_sequence,
        ss.team_name AS marker_team_name,
        COALESCE(
            (
                SELECT m->>'name'
                FROM public.tournament_team_scorecard_snapshots ms
                CROSS JOIN LATERAL
                    jsonb_array_elements(ms.members_snapshot) m
                WHERE ms.score_card_id=ma.marker_score_card_id
                  AND NULLIF(m->>'playerId','')::uuid=
                      ma.marker_player_id
                LIMIT 1
            ),
            'Marcador'
        ) AS marker_name
      INTO v_active_marker
      FROM public.tournament_scorecard_marker_assignments ma
      LEFT JOIN public.tournament_team_scorecard_snapshots ss
        ON ss.score_card_id=ma.marker_score_card_id
     WHERE ma.score_card_id=v_card.id
       AND ma.status='active'
     ORDER BY ma.assigned_at DESC,ma.id DESC
     LIMIT 1;

    v_is_marker:=
        v_player_id IS NOT NULL
        AND v_active_marker.marker_player_id=v_player_id;

    v_is_admin:=
        public.puede_administrar_congelamiento_torneo(
            v_card.tournament_id
        );

    IF NOT (v_is_member OR v_is_marker OR v_is_admin) THEN
        RAISE EXCEPTION
            'No tienes permiso para abrir esta tarjeta de score.'
            USING ERRCODE='42501';
    END IF;

    RETURN (
        SELECT jsonb_build_object(
            'scoreCard',
                jsonb_build_object(
                    'id',sc.id,
                    'folio',sc.card_folio,
                    'competitiveUnit','TEAM',
                    'teamId',sc.tournament_team_id,
                    'teamName',ts.team_name,
                    'members',ts.members_snapshot,
                    'teamPlayingHandicap',
                        ts.team_playing_handicap,
                    'tournamentRoundId',
                        sc.tournament_round_id,
                    'groupLabel',
                        g.group_label,
                    'startHoleNumber',
                        g.hole_number,
                    'startPosition',
                        g.start_position,
                    'shiftNumber',
                        g.shift_number,
                    'startAt',
                        g.start_at
                ),

            'access',
                jsonb_build_object(
                    'isOwner',false,
                    'isTeamMember',v_is_member,
                    'isMarker',v_is_marker,
                    'isAdmin',v_is_admin,
                    'canCapture',v_is_marker,
                    'canConfirmOrDispute',v_is_member
                ),

            'marker',
                CASE
                    WHEN v_active_marker.id IS NULL
                        THEN NULL
                    ELSE jsonb_build_object(
                        'playerId',
                            v_active_marker.marker_player_id,
                        'displayName',
                            v_active_marker.marker_name,
                        'teamName',
                            v_active_marker.marker_team_name,
                        'validFromSequence',
                            v_active_marker.valid_from_sequence
                    )
                END,

            'capture',
                jsonb_build_object(
                    'status',v_session.status,
                    'holesExpected',v_session.holes_expected,
                    'startedAt',v_session.started_at,
                    'capturedAt',v_session.captured_at
                ),

            'holes',
                COALESCE((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'holeScoreId',hs.id,
                            'roundHoleSnapshotId',
                                hs.round_hole_snapshot_id,
                            'holeNumber',hs.hole_number,
                            'playSequence',hs.play_sequence,
                            'par',rh.par,
                            'strokeIndex',rh.stroke_index,
                            'resultType',hs.result_type,
                            'grossScore',hs.gross_score,
                            'status',hs.status,

                            'playerClaimedGrossScore',
                                CASE
                                    WHEN v_is_member
                                      OR v_is_marker
                                      OR v_is_admin
                                    THEN hs.player_claimed_gross_score
                                    ELSE NULL
                                END,

                            'disputeNote',
                                CASE
                                    WHEN v_is_member
                                      OR v_is_marker
                                      OR v_is_admin
                                    THEN hs.dispute_note
                                    ELSE NULL
                                END,

                            'canCapture',
                                v_is_marker
                                AND hs.status IN (
                                    'pending',
                                    'entered',
                                    'disputed'
                                ),

                            'canConfirm',
                                v_is_member
                                AND hs.status='entered',

                            'canDispute',
                                v_is_member
                                AND hs.status='entered'
                        )
                        ORDER BY hs.play_sequence
                    )
                    FROM public.tournament_scorecard_hole_scores hs
                    JOIN public.tournament_round_hole_snapshots rh
                      ON rh.id=hs.round_hole_snapshot_id
                    WHERE hs.score_card_id=sc.id
                ),'[]'::jsonb)
        )
        FROM public.tournament_score_cards sc
        JOIN public.tournament_team_scorecard_snapshots ts
          ON ts.score_card_id=sc.id
        JOIN public.tournament_round_start_validation_groups g
          ON g.id=sc.validation_group_id
         AND g.validation_id=sc.validation_id
        WHERE sc.id=v_card.id
    );
END;
$$;

REVOKE ALL ON FUNCTION public.abrir_captura_tarjeta_score(text)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.abrir_captura_tarjeta_score(text)
TO authenticated,service_role;


-- ============================================================================
-- 3. Detalle por score_card_id: TEAM
-- ============================================================================

ALTER FUNCTION public.obtener_detalle_captura_tarjeta_score(uuid)
RENAME TO _obtener_detalle_captura_tarjeta_score_pre214;

CREATE OR REPLACE FUNCTION public.obtener_detalle_captura_tarjeta_score(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_card record;
BEGIN
    SELECT id,unit_type,qr_token
      INTO v_card
      FROM public.tournament_score_cards
     WHERE id=p_score_card_id
       AND status='issued';

    IF v_card.id IS NULL OR v_card.unit_type<>'team' THEN
        RETURN public._obtener_detalle_captura_tarjeta_score_pre214(
            p_score_card_id
        );
    END IF;

    -- Para TEAM reutilizar exactamente el contrato enriquecido del QR.
    RETURN public.abrir_captura_tarjeta_score(
        v_card.qr_token
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_detalle_captura_tarjeta_score(uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.obtener_detalle_captura_tarjeta_score(uuid)
TO authenticated,service_role;


-- ============================================================================
-- 4. Panel del jugador: incorporar su TEAM
-- ============================================================================

ALTER FUNCTION public.obtener_mi_panel_scores_ronda(uuid)
RENAME TO _obtener_mi_panel_scores_ronda_pre214;

CREATE OR REPLACE FUNCTION public.obtener_mi_panel_scores_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_player_id uuid;
    v_individual jsonb;
    v_team_card jsonb;
    v_cards_i_mark jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    v_player_id:=public._scorecard_current_player_id();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no está vinculado a un jugador activo.'
            USING ERRCODE='42501';
    END IF;

    -- Si existe tarjeta individual, preservar contrato histórico.
    v_individual:=
        public._obtener_mi_panel_scores_ronda_pre214(
            p_tournament_round_id
        );

    SELECT jsonb_build_object(
        'competitiveUnit','TEAM',
        'scoreCardId',sc.id,
        'folio',sc.card_folio,
        'teamId',sc.tournament_team_id,
        'teamName',ts.team_name,
        'members',ts.members_snapshot,
        'teamPlayingHandicap',
            ts.team_playing_handicap,
        'markerDisplayName',
            (
                SELECT COALESCE(
                    (
                        SELECT m->>'name'
                        FROM public.tournament_team_scorecard_snapshots ms
                        CROSS JOIN LATERAL
                            jsonb_array_elements(ms.members_snapshot) m
                        WHERE ms.score_card_id=
                              ma.marker_score_card_id
                          AND NULLIF(m->>'playerId','')::uuid=
                              ma.marker_player_id
                        LIMIT 1
                    ),
                    'Marcador'
                )
                FROM public.tournament_scorecard_marker_assignments ma
                WHERE ma.score_card_id=sc.id
                  AND ma.status='active'
                ORDER BY ma.assigned_at DESC,ma.id DESC
                LIMIT 1
            ),
        'captureStatus',cs.status,
        'holesExpected',cs.holes_expected,
        'holesEntered',(
            SELECT count(*)
            FROM public.tournament_scorecard_hole_scores hs
            WHERE hs.score_card_id=sc.id
              AND hs.result_type='SCORE'
        ),
        'holesConfirmed',(
            SELECT count(*)
            FROM public.tournament_scorecard_hole_scores hs
            WHERE hs.score_card_id=sc.id
              AND hs.status='confirmed'
        ),
        'holesDisputed',(
            SELECT count(*)
            FROM public.tournament_scorecard_hole_scores hs
            WHERE hs.score_card_id=sc.id
              AND hs.status='disputed'
        )
    )
    INTO v_team_card
    FROM public.tournament_score_cards sc
    JOIN public.tournament_team_scorecard_snapshots ts
      ON ts.score_card_id=sc.id
    LEFT JOIN public.tournament_scorecard_capture_sessions cs
      ON cs.score_card_id=sc.id
    WHERE sc.tournament_round_id=p_tournament_round_id
      AND sc.unit_type='team'
      AND sc.status='issued'
      AND EXISTS(
          SELECT 1
          FROM jsonb_array_elements(ts.members_snapshot) m
          WHERE NULLIF(m->>'playerId','')::uuid=v_player_id
      )
    ORDER BY sc.card_number
    LIMIT 1;

    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'competitiveUnit',sc.unit_type,
                'scoreCardId',sc.id,
                'folio',sc.card_folio,
                'displayName',
                    CASE
                        WHEN sc.unit_type='team'
                            THEN ts.team_name
                        ELSE u.unit_name
                    END,
                'validFromSequence',ma.valid_from_sequence,
                'captureStatus',cs.status,
                'holesExpected',cs.holes_expected,
                'holesEntered',(
                    SELECT count(*)
                    FROM public.tournament_scorecard_hole_scores hs
                    WHERE hs.score_card_id=sc.id
                      AND hs.result_type IN ('SCORE','PICKUP')
                )
            )
            ORDER BY sc.card_number
        ),
        '[]'::jsonb
    )
    INTO v_cards_i_mark
    FROM public.tournament_scorecard_marker_assignments ma
    JOIN public.tournament_score_cards sc
      ON sc.id=ma.score_card_id
     AND sc.status='issued'
    JOIN public.tournament_round_start_validation_units u
      ON u.id=sc.validation_unit_id
     AND u.validation_id=sc.validation_id
    LEFT JOIN public.tournament_team_scorecard_snapshots ts
      ON ts.score_card_id=sc.id
    LEFT JOIN public.tournament_scorecard_capture_sessions cs
      ON cs.score_card_id=sc.id
    WHERE ma.tournament_round_id=p_tournament_round_id
      AND ma.marker_player_id=v_player_id
      AND ma.status='active';

    RETURN jsonb_build_object(
        'tournamentRoundId',
            p_tournament_round_id,

        'myCard',
            COALESCE(
                v_team_card,
                v_individual->'myCard'
            ),

        'cardsIMark',
            v_cards_i_mark
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_mi_panel_scores_ronda(uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.obtener_mi_panel_scores_ronda(uuid)
TO authenticated,service_role;


-- ============================================================================
-- 5. Mis rondas: incorporar membership TEAM
-- ============================================================================

ALTER FUNCTION public.obtener_mis_rondas_score()
RENAME TO _obtener_mis_rondas_score_pre214;

CREATE OR REPLACE FUNCTION public.obtener_mis_rondas_score()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_player_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    v_player_id:=public._scorecard_current_player_id();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no está vinculado a un jugador activo.'
            USING ERRCODE='42501';
    END IF;

    RETURN COALESCE((
        WITH relevant_rounds AS (
            -- Tarjeta individual propia.
            SELECT
                sc.tournament_round_id,
                true AS has_own_card,
                false AS has_team_card,
                false AS marks_cards
            FROM public.tournament_score_cards sc
            WHERE sc.player_id=v_player_id
              AND sc.status='issued'

            UNION ALL

            -- Tarjeta TEAM a la que pertenece.
            SELECT
                sc.tournament_round_id,
                false,
                true,
                false
            FROM public.tournament_score_cards sc
            JOIN public.tournament_team_scorecard_snapshots ts
              ON ts.score_card_id=sc.id
            WHERE sc.unit_type='team'
              AND sc.status='issued'
              AND EXISTS(
                  SELECT 1
                  FROM jsonb_array_elements(ts.members_snapshot) m
                  WHERE NULLIF(m->>'playerId','')::uuid=v_player_id
              )

            UNION ALL

            -- Tarjetas que marca.
            SELECT
                ma.tournament_round_id,
                false,
                false,
                true
            FROM public.tournament_scorecard_marker_assignments ma
            JOIN public.tournament_score_cards sc
              ON sc.id=ma.score_card_id
             AND sc.status='issued'
            WHERE ma.marker_player_id=v_player_id
              AND ma.status='active'
        ),

        grouped AS (
            SELECT
                tournament_round_id,
                bool_or(has_own_card) AS has_own_card,
                bool_or(has_team_card) AS has_team_card,
                bool_or(marks_cards) AS marks_cards
            FROM relevant_rounds
            GROUP BY tournament_round_id
        )

        SELECT jsonb_agg(
            jsonb_build_object(
                'tournamentRoundId',tr.id,
                'tournamentId',t.id,
                'tournamentName',t.nombre,
                'roundNumber',tr.numero_ronda,
                'roundDate',tr.fecha,
                'hasOwnCard',g.has_own_card,
                'hasTeamCard',g.has_team_card,
                'marksCards',g.marks_cards,
                'cardsIMarkCount',(
                    SELECT count(*)
                    FROM public.tournament_scorecard_marker_assignments ma
                    JOIN public.tournament_score_cards sc
                      ON sc.id=ma.score_card_id
                     AND sc.status='issued'
                    WHERE ma.tournament_round_id=tr.id
                      AND ma.marker_player_id=v_player_id
                      AND ma.status='active'
                ),
                'captureInitialized',
                    EXISTS(
                        SELECT 1
                        FROM public.tournament_score_cards sc
                        JOIN public.tournament_scorecard_capture_sessions cs
                          ON cs.score_card_id=sc.id
                        LEFT JOIN public.tournament_team_scorecard_snapshots ts
                          ON ts.score_card_id=sc.id
                        WHERE sc.tournament_round_id=tr.id
                          AND sc.status='issued'
                          AND (
                              sc.player_id=v_player_id
                              OR (
                                  sc.unit_type='team'
                                  AND EXISTS(
                                      SELECT 1
                                      FROM jsonb_array_elements(
                                          ts.members_snapshot
                                      ) m
                                      WHERE NULLIF(
                                          m->>'playerId',''
                                      )::uuid=v_player_id
                                  )
                              )
                              OR EXISTS(
                                  SELECT 1
                                  FROM public.tournament_scorecard_marker_assignments ma
                                  WHERE ma.score_card_id=sc.id
                                    AND ma.marker_player_id=v_player_id
                                    AND ma.status='active'
                              )
                          )
                    )
            )
            ORDER BY
                tr.fecha DESC,
                tr.numero_ronda DESC,
                t.nombre,
                tr.id
        )
        FROM grouped g
        JOIN public.tournament_rounds tr
          ON tr.id=g.tournament_round_id
        JOIN public.tournaments t
          ON t.id=tr.tournament_id
        WHERE tr.activo=true
          AND t.activo=true
    ),'[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_mis_rondas_score()
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.obtener_mis_rondas_score()
TO authenticated,service_role;


-- ============================================================================
-- 6. Cambio administrativo de marker TEAM
-- ============================================================================

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
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_target record;
    v_marker record;
    v_admin_id uuid;
    v_marker_registration_id uuid;
    v_old_assignment record;
    v_new_assignment_id uuid;
    v_holes_expected integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_from_sequence IS NULL
       OR p_from_sequence<=0
    THEN
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
        sc.validation_group_id,
        sc.tournament_team_id,
        sc.unit_type,
        sc.status
      INTO v_target
      FROM public.tournament_score_cards sc
     WHERE sc.id=p_score_card_id;

    IF v_target.id IS NULL
       OR v_target.status<>'issued'
       OR v_target.unit_type<>'team'
    THEN
        RAISE EXCEPTION
            'La tarjeta objetivo no es una tarjeta TEAM emitida.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_target.tournament_id
    ) THEN
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

    IF v_marker.id=v_target.id
       OR v_marker.tournament_team_id=v_target.tournament_team_id
    THEN
        RAISE EXCEPTION
            'El marcador debe pertenecer a otro equipo.'
            USING ERRCODE='23514';
    END IF;

    IF v_marker.tournament_round_id<>v_target.tournament_round_id THEN
        RAISE EXCEPTION
            'El equipo marcador debe pertenecer a la misma ronda.'
            USING ERRCODE='23514';
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
                       WHEN p_from_sequence>
                            v_old_assignment.valid_from_sequence
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
        'admin_team',
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
        'status','active'
    );
END;
$$;

REVOKE ALL ON FUNCTION public.asignar_marcador_tarjeta_equipo_a_gogo(
    uuid,uuid,uuid,integer,text
) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.asignar_marcador_tarjeta_equipo_a_gogo(
    uuid,uuid,uuid,integer,text
) TO authenticated,service_role;

COMMIT;
