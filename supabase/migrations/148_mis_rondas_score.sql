-- ============================================================================
-- 148_mis_rondas_score.sql
-- GOLF IN FULL / Tee Central
-- MIGRACIÓN 148 — RONDAS DE SCORE DEL JUGADOR AUTENTICADO
-- ============================================================================
BEGIN;

DO $$
BEGIN
    IF to_regclass('public.tournament_score_cards') IS NULL
       OR to_regclass('public.tournament_scorecard_marker_assignments') IS NULL
       OR to_regclass('public.tournament_scorecard_capture_sessions') IS NULL
       OR to_regclass('public.tournament_rounds') IS NULL
       OR to_regclass('public.tournaments') IS NULL
    THEN
        RAISE EXCEPTION 'Migración 148 requiere tarjetas oficiales y núcleo de captura (Migraciones 143 y 146).';
    END IF;

    IF to_regprocedure('public._scorecard_current_player_id()') IS NULL THEN
        RAISE EXCEPTION 'Migración 148 requiere public._scorecard_current_player_id().';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.obtener_mis_rondas_score()
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
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    v_player_id := public._scorecard_current_player_id();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION 'El usuario autenticado no está vinculado a un jugador activo.' USING ERRCODE = '42501';
    END IF;

    RETURN COALESCE((
        WITH relevant_rounds AS (
            SELECT sc.tournament_round_id, true AS has_own_card, false AS marks_cards
            FROM public.tournament_score_cards sc
            WHERE sc.player_id = v_player_id
              AND sc.status = 'issued'

            UNION ALL

            SELECT ma.tournament_round_id, false AS has_own_card, true AS marks_cards
            FROM public.tournament_scorecard_marker_assignments ma
            JOIN public.tournament_score_cards sc
              ON sc.id = ma.score_card_id
             AND sc.status = 'issued'
            WHERE ma.marker_player_id = v_player_id
              AND ma.status = 'active'
        ),
        grouped AS (
            SELECT tournament_round_id,
                   bool_or(has_own_card) AS has_own_card,
                   bool_or(marks_cards) AS marks_cards
            FROM relevant_rounds
            GROUP BY tournament_round_id
        )
        SELECT jsonb_agg(
            jsonb_build_object(
                'tournamentRoundId', tr.id,
                'tournamentId', t.id,
                'tournamentName', t.nombre,
                'roundNumber', tr.numero_ronda,
                'roundDate', tr.fecha,
                'hasOwnCard', g.has_own_card,
                'marksCards', g.marks_cards,
                'cardsIMarkCount', (
                    SELECT count(*)
                    FROM public.tournament_scorecard_marker_assignments ma
                    JOIN public.tournament_score_cards sc
                      ON sc.id = ma.score_card_id
                     AND sc.status = 'issued'
                    WHERE ma.tournament_round_id = tr.id
                      AND ma.marker_player_id = v_player_id
                      AND ma.status = 'active'
                ),
                'captureInitialized', EXISTS (
                    SELECT 1
                    FROM public.tournament_score_cards sc
                    JOIN public.tournament_scorecard_capture_sessions cs
                      ON cs.score_card_id = sc.id
                    WHERE sc.tournament_round_id = tr.id
                      AND sc.status = 'issued'
                      AND (
                          sc.player_id = v_player_id
                          OR EXISTS (
                              SELECT 1
                              FROM public.tournament_scorecard_marker_assignments ma
                              WHERE ma.score_card_id = sc.id
                                AND ma.marker_player_id = v_player_id
                                AND ma.status = 'active'
                          )
                      )
                )
            )
            ORDER BY tr.fecha DESC, tr.numero_ronda DESC, t.nombre, tr.id
        )
        FROM grouped g
        JOIN public.tournament_rounds tr ON tr.id = g.tournament_round_id
        JOIN public.tournaments t ON t.id = tr.tournament_id
        WHERE tr.activo = true
          AND t.activo = true
    ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_mis_rondas_score() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_mis_rondas_score() TO authenticated;

COMMIT;
