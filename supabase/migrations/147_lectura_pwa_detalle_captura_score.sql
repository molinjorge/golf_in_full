-- ============================================================================
-- 147_lectura_pwa_detalle_captura_score.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 147 — LECTURA PWA DE DETALLE DE CAPTURA
--
-- OBJETIVO
-- Completar el backend de SOLO LECTURA requerido por la PWA antes de habilitar
-- captura GROSS:
--
-- 1. Agregar RPC segura:
--      obtener_detalle_captura_tarjeta_score(uuid)
--
--    La RPC abre una tarjeta por score_card_id y devuelve:
--    - identidad humana de tarjeta/jugador;
--    - marcador vigente;
--    - salida/grupo/turno;
--    - estado de captura;
--    - hoyos en play_sequence;
--    - PAR / Stroke Index;
--    - gross/status ya capturados;
--    - permisos derivados canCapture/canConfirm/canDispute.
--
-- 2. Ampliar:
--      obtener_mi_panel_scores_ronda(uuid)
--
--    para que myCard incluya markerDisplayName.
--
-- SEGURIDAD
-- - Requiere auth.uid().
-- - No acepta player_id ni registration_id desde cliente.
-- - La tarjeta sólo se puede abrir si el usuario autenticado es:
--     a) dueño de la tarjeta;
--     b) marcador vigente;
--     c) administrador autorizado del torneo.
-- - No expone qr_token.
-- - No usa tournament_registrations.qr_token.
-- - No permite escritura.
--
-- NO INCLUYE
-- - captura GROSS;
-- - confirmación/disputa nuevas;
-- - notificaciones;
-- - UI;
-- - NETO;
-- - leaderboard;
-- - cortes;
-- - reconciliación física.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 0. GUARDAS
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('public.tournament_score_cards') IS NULL
       OR to_regclass('public.tournament_scorecard_capture_sessions') IS NULL
       OR to_regclass('public.tournament_scorecard_marker_assignments') IS NULL
       OR to_regclass('public.tournament_scorecard_hole_scores') IS NULL
       OR to_regclass('public.tournament_round_hole_snapshots') IS NULL
    THEN
        RAISE EXCEPTION
            'Migración 147 requiere la Migración 146 y las estructuras oficiales de tarjetas/snapshots.';
    END IF;

    IF to_regprocedure('public.puede_ver_score_card_captura(uuid)') IS NULL THEN
        RAISE EXCEPTION
            'Migración 147 requiere public.puede_ver_score_card_captura(uuid).';
    END IF;

    IF to_regprocedure('public._scorecard_current_player_id()') IS NULL THEN
        RAISE EXCEPTION
            'Migración 147 requiere public._scorecard_current_player_id().';
    END IF;
END;
$$;

-- ============================================================================
-- 1. DETALLE SEGURO DE CAPTURA POR score_card_id
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_detalle_captura_tarjeta_score(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_card record;
    v_session record;
    v_player_id uuid;
    v_is_owner boolean := false;
    v_is_marker boolean := false;
    v_is_admin boolean := false;
    v_active_marker record;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF p_score_card_id IS NULL THEN
        RAISE EXCEPTION 'score_card_id es obligatorio.'
            USING ERRCODE = '22023';
    END IF;

    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.validation_id,
        sc.validation_group_id,
        sc.validation_unit_id,
        sc.player_id,
        sc.tournament_registration_id,
        sc.card_folio,
        sc.card_number,
        sc.status,
        u.unit_name AS player_name,
        u.order_in_group,
        g.group_label,
        g.hole_number AS start_hole_number,
        g.start_position,
        g.shift_number,
        g.start_at,
        g.shift_time
      INTO v_card
      FROM public.tournament_score_cards sc
      JOIN public.tournament_round_start_validation_units u
        ON u.id = sc.validation_unit_id
       AND u.validation_id = sc.validation_id
      JOIN public.tournament_round_start_validation_groups g
        ON g.id = sc.validation_group_id
       AND g.validation_id = sc.validation_id
     WHERE sc.id = p_score_card_id
       AND sc.status = 'issued'
     LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION
            'La tarjeta oficial indicada no existe o no está emitida.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_ver_score_card_captura(v_card.id) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar esta tarjeta de score.'
            USING ERRCODE = '42501';
    END IF;

    SELECT cs.*
      INTO v_session
      FROM public.tournament_scorecard_capture_sessions cs
     WHERE cs.score_card_id = v_card.id
     LIMIT 1;

    IF v_session.id IS NULL THEN
        RAISE EXCEPTION
            'La captura de scores de esta tarjeta todavía no está inicializada.'
            USING ERRCODE = '55000';
    END IF;

    v_player_id := public._scorecard_current_player_id();
    v_is_owner := v_player_id IS NOT NULL
                  AND v_player_id = v_card.player_id;

    SELECT
        ma.id,
        ma.marker_player_id,
        ma.marker_score_card_id,
        ma.valid_from_sequence,
        mu.unit_name AS marker_name
      INTO v_active_marker
      FROM public.tournament_scorecard_marker_assignments ma
      JOIN public.tournament_score_cards msc
        ON msc.id = ma.marker_score_card_id
       AND msc.status = 'issued'
      JOIN public.tournament_round_start_validation_units mu
        ON mu.id = msc.validation_unit_id
       AND mu.validation_id = msc.validation_id
     WHERE ma.score_card_id = v_card.id
       AND ma.status = 'active'
     ORDER BY ma.assigned_at DESC, ma.id DESC
     LIMIT 1;

    v_is_marker := v_player_id IS NOT NULL
                   AND v_active_marker.marker_player_id = v_player_id;

    v_is_admin :=
        public.puede_administrar_congelamiento_torneo(v_card.tournament_id);

    RETURN jsonb_build_object(
        'scoreCard',
        jsonb_build_object(
            'id', v_card.id,
            'folio', v_card.card_folio,
            'cardNumber', v_card.card_number,
            'playerName', v_card.player_name,
            'tournamentRoundId', v_card.tournament_round_id,
            'groupLabel', v_card.group_label,
            'orderInGroup', v_card.order_in_group,
            'startHoleNumber', v_card.start_hole_number,
            'startPosition', v_card.start_position,
            'shiftNumber', v_card.shift_number,
            'startAt', v_card.start_at,
            'shiftTime', v_card.shift_time
        ),

        'marker',
        CASE
            WHEN v_active_marker.id IS NULL THEN NULL
            ELSE jsonb_build_object(
                'displayName', v_active_marker.marker_name,
                'validFromSequence', v_active_marker.valid_from_sequence
            )
        END,

        'access',
        jsonb_build_object(
            'isOwner', v_is_owner,
            'isMarker', v_is_marker,
            'isAdmin', v_is_admin
        ),

        'capture',
        jsonb_build_object(
            'status', v_session.status,
            'holesExpected', v_session.holes_expected,
            'startedAt', v_session.started_at,
            'capturedAt', v_session.captured_at,
            'holesEntered', (
                SELECT count(*)
                FROM public.tournament_scorecard_hole_scores hs
                WHERE hs.score_card_id = v_card.id
                  AND hs.gross_score IS NOT NULL
            ),
            'holesConfirmed', (
                SELECT count(*)
                FROM public.tournament_scorecard_hole_scores hs
                WHERE hs.score_card_id = v_card.id
                  AND hs.status = 'confirmed'
            ),
            'holesDisputed', (
                SELECT count(*)
                FROM public.tournament_scorecard_hole_scores hs
                WHERE hs.score_card_id = v_card.id
                  AND hs.status = 'disputed'
            )
        ),

        'holes',
        COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'holeScoreId', hs.id,
                    'roundHoleSnapshotId', hs.round_hole_snapshot_id,
                    'holeNumber', hs.hole_number,
                    'playSequence', hs.play_sequence,
                    'par', rh.par,
                    'strokeIndex', rh.stroke_index,
                    'grossScore', hs.gross_score,
                    'status', hs.status,
                    'playerClaimedGrossScore',
                        CASE
                            WHEN v_is_owner OR v_is_marker OR v_is_admin
                            THEN hs.player_claimed_gross_score
                            ELSE NULL
                        END,
                    'disputeNote',
                        CASE
                            WHEN v_is_owner OR v_is_marker OR v_is_admin
                            THEN hs.dispute_note
                            ELSE NULL
                        END,
                    'canCapture',
                        (
                            v_is_marker
                            AND hs.status IN ('pending', 'entered', 'disputed')
                        ),
                    'canConfirm',
                        (
                            v_is_owner
                            AND hs.status = 'entered'
                        ),
                    'canDispute',
                        (
                            v_is_owner
                            AND hs.status = 'entered'
                        )
                )
                ORDER BY hs.play_sequence
            )
            FROM public.tournament_scorecard_hole_scores hs
            JOIN public.tournament_round_hole_snapshots rh
              ON rh.id = hs.round_hole_snapshot_id
            WHERE hs.score_card_id = v_card.id
        ), '[]'::jsonb)
    );
END;
$$;

-- ============================================================================
-- 2. PANEL DE RONDA — AGREGA markerDisplayName A myCard
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_mi_panel_scores_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_player_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    v_player_id := public._scorecard_current_player_id();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no está vinculado a un jugador activo.'
            USING ERRCODE = '42501';
    END IF;

    RETURN jsonb_build_object(
        'tournamentRoundId', p_tournament_round_id,

        'myCard', (
            SELECT jsonb_build_object(
                'scoreCardId', sc.id,
                'folio', sc.card_folio,
                'playerName', u.unit_name,
                'markerDisplayName', (
                    SELECT mu.unit_name
                    FROM public.tournament_scorecard_marker_assignments ma
                    JOIN public.tournament_score_cards msc
                      ON msc.id = ma.marker_score_card_id
                     AND msc.status = 'issued'
                    JOIN public.tournament_round_start_validation_units mu
                      ON mu.id = msc.validation_unit_id
                     AND mu.validation_id = msc.validation_id
                    WHERE ma.score_card_id = sc.id
                      AND ma.status = 'active'
                    ORDER BY ma.assigned_at DESC, ma.id DESC
                    LIMIT 1
                ),
                'captureStatus', cs.status,
                'holesExpected', cs.holes_expected,
                'holesEntered', (
                    SELECT count(*)
                    FROM public.tournament_scorecard_hole_scores hs
                    WHERE hs.score_card_id = sc.id
                      AND hs.gross_score IS NOT NULL
                ),
                'holesConfirmed', (
                    SELECT count(*)
                    FROM public.tournament_scorecard_hole_scores hs
                    WHERE hs.score_card_id = sc.id
                      AND hs.status = 'confirmed'
                ),
                'holesDisputed', (
                    SELECT count(*)
                    FROM public.tournament_scorecard_hole_scores hs
                    WHERE hs.score_card_id = sc.id
                      AND hs.status = 'disputed'
                )
            )
            FROM public.tournament_score_cards sc
            JOIN public.tournament_round_start_validation_units u
              ON u.id = sc.validation_unit_id
             AND u.validation_id = sc.validation_id
            LEFT JOIN public.tournament_scorecard_capture_sessions cs
              ON cs.score_card_id = sc.id
            WHERE sc.tournament_round_id = p_tournament_round_id
              AND sc.player_id = v_player_id
              AND sc.status = 'issued'
            ORDER BY sc.card_number
            LIMIT 1
        ),

        'cardsIMark', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'scoreCardId', sc.id,
                    'folio', sc.card_folio,
                    'playerName', u.unit_name,
                    'validFromSequence', ma.valid_from_sequence,
                    'captureStatus', cs.status,
                    'holesExpected', cs.holes_expected,
                    'holesEntered', (
                        SELECT count(*)
                        FROM public.tournament_scorecard_hole_scores hs
                        WHERE hs.score_card_id = sc.id
                          AND hs.gross_score IS NOT NULL
                    )
                )
                ORDER BY sc.card_number
            )
            FROM public.tournament_scorecard_marker_assignments ma
            JOIN public.tournament_score_cards sc
              ON sc.id = ma.score_card_id
            JOIN public.tournament_round_start_validation_units u
              ON u.id = sc.validation_unit_id
             AND u.validation_id = sc.validation_id
            LEFT JOIN public.tournament_scorecard_capture_sessions cs
              ON cs.score_card_id = sc.id
            WHERE ma.tournament_round_id = p_tournament_round_id
              AND ma.marker_player_id = v_player_id
              AND ma.status = 'active'
              AND sc.status = 'issued'
        ), '[]'::jsonb)
    );
END;
$$;

-- ============================================================================
-- 3. PRIVILEGIOS
-- ============================================================================

REVOKE ALL ON FUNCTION public.obtener_detalle_captura_tarjeta_score(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_detalle_captura_tarjeta_score(uuid)
    TO authenticated;

REVOKE ALL ON FUNCTION public.obtener_mi_panel_scores_ronda(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_mi_panel_scores_ronda(uuid)
    TO authenticated;

COMMIT;
