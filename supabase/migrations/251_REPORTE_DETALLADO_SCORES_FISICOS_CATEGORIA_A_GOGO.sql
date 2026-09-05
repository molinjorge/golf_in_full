-- TEE CENTRAL / GOLF IN FULL
-- Migración 251
-- Reporte detallado de scores físicos por categoría para A-Go-Go TEAM.
--
-- Objetivo:
-- - Fuente de golpes: exclusivamente tournament_scorecard_physical_hole_scores.
-- - Filtro obligatorio por categoría, esté o no cerrada/publicada.
-- - Una fila lógica por equipo con todos los hoyos en orden natural.
-- - Orden competitivo por GROSS o NETO usando finalRank/rank del leaderboard
--   cuando exista; fallback al total físico cuando todavía no exista ranking.
-- - No modifica captura, conciliación, resultados, desempates ni cierres.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_reporte_scores_fisicos_categoria_a_gogo_ronda(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid,
    p_criterio text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_round record;
    v_category record;
    v_leaderboard jsonb;
    v_category_payload jsonb;
    v_gross_enabled boolean := false;
    v_net_enabled boolean := false;
    v_criterio text;
    v_holes_expected integer := 0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL
       OR p_tournament_category_id IS NULL
    THEN
        RAISE EXCEPTION
            'tournament_round_id y tournament_category_id son obligatorios.'
            USING ERRCODE='22023';
    END IF;

    SELECT
        tr.id,
        tr.tournament_id,
        tr.numero_ronda,
        tr.fecha,
        t.nombre AS tournament_name
      INTO v_round
      FROM public.tournament_rounds tr
      JOIN public.tournaments t
        ON t.id=tr.tournament_id
     WHERE tr.id=p_tournament_round_id
     LIMIT 1;

    IF v_round.id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_round.tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar este reporte.'
            USING ERRCODE='42501';
    END IF;

    SELECT
        tc.id,
        tc.tournament_id,
        c.codigo AS category_code,
        c.nombre AS category_name,
        c.display_order AS category_display_order
      INTO v_category
      FROM public.tournament_categories tc
      JOIN public.categories c
        ON c.id=tc.category_id
     WHERE tc.id=p_tournament_category_id
       AND tc.tournament_id=v_round.tournament_id
     LIMIT 1;

    IF v_category.id IS NULL THEN
        RAISE EXCEPTION
            'La categoría indicada no pertenece al torneo de la ronda.'
            USING ERRCODE='22023';
    END IF;

    -- El leaderboard A-Go-Go aporta exclusivamente el orden competitivo,
    -- clasificación habilitada y metadatos TEAM. Los golpes del reporte NO
    -- se toman de aquí, sino de la captura física.
    v_leaderboard := public.obtener_leaderboard_a_gogo_ronda(
        p_tournament_round_id
    );

    SELECT c
      INTO v_category_payload
      FROM jsonb_array_elements(
          COALESCE(v_leaderboard->'categories','[]'::jsonb)
      ) c
     WHERE NULLIF(c->>'tournamentCategoryId','')::uuid
           = p_tournament_category_id
     LIMIT 1;

    IF v_category_payload IS NULL THEN
        RAISE EXCEPTION
            'La categoría no está presente en el leaderboard A-Go-Go de la ronda.'
            USING ERRCODE='23514';
    END IF;

    v_gross_enabled := COALESCE(
        (v_category_payload#>>'{classification,grossEnabled}')::boolean,
        false
    );

    v_net_enabled := COALESCE(
        (v_category_payload#>>'{classification,netEnabled}')::boolean,
        false
    );

    v_criterio := upper(btrim(COALESCE(p_criterio,'')));

    IF v_criterio IN ('NET','NETO') THEN
        v_criterio := 'NETO';
    ELSIF v_criterio='GROSS' THEN
        v_criterio := 'GROSS';
    ELSIF v_criterio='' THEN
        IF v_gross_enabled AND NOT v_net_enabled THEN
            v_criterio := 'GROSS';
        ELSIF v_net_enabled AND NOT v_gross_enabled THEN
            v_criterio := 'NETO';
        ELSIF v_gross_enabled AND v_net_enabled THEN
            RAISE EXCEPTION
                'La categoría clasifica GROSS y NETO; debes indicar p_criterio=GROSS o NETO.'
                USING ERRCODE='22023';
        ELSE
            RAISE EXCEPTION
                'La categoría no tiene una clasificación competitiva GROSS/NETO habilitada.'
                USING ERRCODE='23514';
        END IF;
    ELSE
        RAISE EXCEPTION
            'Criterio inválido. Usa GROSS o NETO.'
            USING ERRCODE='22023';
    END IF;

    IF v_criterio='GROSS' AND NOT v_gross_enabled THEN
        RAISE EXCEPTION
            'La categoría no tiene clasificación GROSS habilitada.'
            USING ERRCODE='23514';
    END IF;

    IF v_criterio='NETO' AND NOT v_net_enabled THEN
        RAISE EXCEPTION
            'La categoría no tiene clasificación NETO habilitada.'
            USING ERRCODE='23514';
    END IF;

    SELECT count(*)::integer
      INTO v_holes_expected
      FROM public.tournament_round_hole_snapshots rhs
     WHERE rhs.tournament_round_id=p_tournament_round_id;

    RETURN (
        WITH leaderboard_teams AS (
            SELECT
                p AS payload,
                NULLIF(p->>'scoreCardId','')::uuid AS score_card_id,
                NULLIF(p->>'teamId','')::uuid AS team_id,
                COALESCE(
                    NULLIF(p->>'teamName',''),
                    NULLIF(p->>'playerName',''),
                    'Equipo'
                ) AS team_name,
                NULLIF(p->>'cardFolio','') AS card_folio,
                NULLIF(p->>'teamPlayingHandicap','')::integer
                    AS team_playing_handicap,

                CASE
                    WHEN v_criterio='GROSS' THEN
                        COALESCE(
                            NULLIF(p#>>'{gross,finalRank}','')::integer,
                            NULLIF(p#>>'{gross,rank}','')::integer
                        )
                    ELSE
                        COALESCE(
                            NULLIF(p#>>'{net,finalRank}','')::integer,
                            NULLIF(p#>>'{net,rank}','')::integer
                        )
                END AS leaderboard_position,

                CASE
                    WHEN v_criterio='GROSS' THEN
                        NULLIF(p#>>'{gross,rank}','')::integer
                    ELSE
                        NULLIF(p#>>'{net,rank}','')::integer
                END AS base_rank,

                CASE
                    WHEN v_criterio='GROSS' THEN
                        NULLIF(p#>>'{gross,finalRank}','')::integer
                    ELSE
                        NULLIF(p#>>'{net,finalRank}','')::integer
                END AS final_rank,

                CASE
                    WHEN v_criterio='GROSS' THEN
                        NULLIF(p#>>'{gross,total}','')::integer
                    ELSE
                        NULLIF(p#>>'{net,total}','')::integer
                END AS leaderboard_total,

                CASE
                    WHEN v_criterio='GROSS' THEN
                        NULLIF(p#>>'{gross,tieSize}','')::integer
                    ELSE
                        NULLIF(p#>>'{net,tieSize}','')::integer
                END AS tie_size,

                CASE
                    WHEN v_criterio='GROSS' THEN
                        COALESCE(
                            NULLIF(p#>>'{gross,tiebreakStatus}',''),
                            CASE
                                WHEN COALESCE(
                                    (p#>>'{gross,tiebreakPending}')::boolean,
                                    false
                                ) THEN 'PENDING'
                                ELSE NULL
                            END
                        )
                    ELSE
                        COALESCE(
                            NULLIF(p#>>'{net,tiebreakStatus}',''),
                            CASE
                                WHEN COALESCE(
                                    (p#>>'{net,tiebreakPending}')::boolean,
                                    false
                                ) THEN 'PENDING'
                                ELSE NULL
                            END
                        )
                END AS tiebreak_status,

                p->>'competitionStatus' AS competition_status

            FROM jsonb_array_elements(
                COALESCE(v_category_payload->'players','[]'::jsonb)
            ) p
        ),

        physical AS (
            SELECT
                lt.*,
                sc.card_number,
                pr.status AS physical_status,
                pr.capture_completed_at,

                count(phs.id)::integer AS physical_holes_captured,
                sum(phs.physical_gross_score)::integer AS physical_gross_total,

                CASE
                    WHEN count(phs.id)=v_holes_expected
                     AND count(*) FILTER (
                         WHERE phs.physical_gross_score IS NULL
                     )=0
                    THEN true
                    ELSE false
                END AS physical_complete,

                COALESCE(
                    jsonb_agg(
                        jsonb_build_object(
                            'holeNumber', rhs.hole_number,
                            'score', phs.physical_gross_score
                        )
                        ORDER BY rhs.hole_number
                    ) FILTER (WHERE rhs.id IS NOT NULL),
                    '[]'::jsonb
                ) AS holes

            FROM leaderboard_teams lt

            JOIN public.tournament_score_cards sc
              ON sc.id=lt.score_card_id
             AND sc.tournament_round_id=p_tournament_round_id
             AND sc.tournament_category_id=p_tournament_category_id
             AND sc.status='issued'
             AND sc.unit_type='team'

            LEFT JOIN public.tournament_scorecard_physical_receptions pr
              ON pr.score_card_id=sc.id

            CROSS JOIN public.tournament_round_hole_snapshots rhs

            LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
              ON phs.score_card_id=sc.id
             AND phs.round_hole_snapshot_id=rhs.id

            WHERE rhs.tournament_round_id=p_tournament_round_id

            GROUP BY
                lt.payload,
                lt.score_card_id,
                lt.team_id,
                lt.team_name,
                lt.card_folio,
                lt.team_playing_handicap,
                lt.leaderboard_position,
                lt.base_rank,
                lt.final_rank,
                lt.leaderboard_total,
                lt.tie_size,
                lt.tiebreak_status,
                lt.competition_status,
                sc.card_number,
                pr.status,
                pr.capture_completed_at
        ),

        ranked AS (
            SELECT
                p.*,
                CASE
                    WHEN p.physical_gross_total IS NULL THEN NULL
                    WHEN v_criterio='GROSS' THEN p.physical_gross_total
                    ELSE
                        p.physical_gross_total
                        - COALESCE(p.team_playing_handicap,0)
                END AS physical_metric_total,

                row_number() OVER (
                    ORDER BY
                        CASE WHEN p.leaderboard_position IS NULL THEN 1 ELSE 0 END,
                        p.leaderboard_position NULLS LAST,
                        CASE
                            WHEN p.leaderboard_position IS NULL THEN
                                CASE
                                    WHEN v_criterio='GROSS'
                                        THEN p.physical_gross_total
                                    ELSE
                                        p.physical_gross_total
                                        - COALESCE(p.team_playing_handicap,0)
                                END
                            ELSE NULL
                        END NULLS LAST,
                        p.card_number NULLS LAST,
                        p.team_name
                )::integer AS display_order
            FROM physical p
        )

        SELECT jsonb_build_object(
            'schemaVersion', 1,
            'reportType', 'A_GOGO_PHYSICAL_SCORES_BY_CATEGORY',
            'source', 'PHYSICAL_CAPTURE',

            'round', jsonb_build_object(
                'tournamentId', v_round.tournament_id,
                'tournamentName', v_round.tournament_name,
                'tournamentRoundId', v_round.id,
                'roundNumber', v_round.numero_ronda,
                'roundDate', v_round.fecha,
                'scoringEngine', 'team_stroke',
                'participationType', 'equipo'
            ),

            'category', jsonb_build_object(
                'tournamentCategoryId', v_category.id,
                'categoryCode', v_category.category_code,
                'categoryName', v_category.category_name,
                'grossEnabled', v_gross_enabled,
                'netEnabled', v_net_enabled
            ),

            'orderCriterion', v_criterio,
            'holesExpected', v_holes_expected,
            'holeNumbers', COALESCE((
                SELECT jsonb_agg(rhs.hole_number ORDER BY rhs.hole_number)
                FROM public.tournament_round_hole_snapshots rhs
                WHERE rhs.tournament_round_id=p_tournament_round_id
            ), '[]'::jsonb),

            'teams', COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'displayOrder', r.display_order,
                        'leaderboardPosition', r.leaderboard_position,
                        'baseRank', r.base_rank,
                        'finalRank', r.final_rank,
                        'leaderboardTotal', r.leaderboard_total,
                        'tieSize', r.tie_size,
                        'tiebreakStatus', r.tiebreak_status,
                        'competitionStatus', r.competition_status,

                        'scoreCardId', r.score_card_id,
                        'cardFolio', r.card_folio,
                        'teamId', r.team_id,
                        'teamName', r.team_name,
                        'teamPlayingHandicap', r.team_playing_handicap,

                        'physicalStatus', COALESCE(r.physical_status,'NOT_RECEIVED'),
                        'physicalComplete', r.physical_complete,
                        'physicalHolesCaptured', r.physical_holes_captured,
                        'captureCompletedAt', r.capture_completed_at,
                        'physicalGrossTotal', r.physical_gross_total,
                        'physicalNetTotal', CASE
                            WHEN r.physical_gross_total IS NULL THEN NULL
                            ELSE r.physical_gross_total
                                 - COALESCE(r.team_playing_handicap,0)
                        END,
                        'physicalMetricTotal', r.physical_metric_total,
                        'holes', r.holes
                    )
                    ORDER BY r.display_order
                )
                FROM ranked r
            ), '[]'::jsonb)
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_reporte_scores_fisicos_categoria_a_gogo_ronda(uuid,uuid,text)
    FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.obtener_reporte_scores_fisicos_categoria_a_gogo_ronda(uuid,uuid,text)
    TO authenticated, service_role;

COMMIT;
