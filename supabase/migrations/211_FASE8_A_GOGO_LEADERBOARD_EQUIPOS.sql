-- ============================================================================
-- MIGRACIÓN 211 FASE 8
-- A-Go-Go — leaderboard de ronda por equipos
-- Proyecto: Tee Central / GOLF IN FULL
--
-- PRINCIPIOS
-- - Unidad competitiva = TEAM.
-- - Consume resultado oficial de Migración 210.
-- - Reutiliza clasificación congelada Gross/Neto de Migración 198.
-- - Reutiliza outcomes comunes DQ/WD/DNS/DNF/NO_CARD por score_card_id.
-- - Gross y Neto: menor cantidad de golpes es mejor.
-- - Detecta empates; NO los resuelve (Fase 9).
-- - Extiende obtener_leaderboard_operativo_ronda sin romper Stroke/Stableford.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Leaderboard A-Go-Go de una ronda
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_leaderboard_a_gogo_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_round record;
    v_validation record;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    SELECT tr.id,tr.tournament_id,tr.numero_ronda,tr.fecha
      INTO v_round
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id
       AND tr.activo=true
     LIMIT 1;

    IF v_round.id IS NULL THEN
        RAISE EXCEPTION
            'La ronda indicada no existe o no está activa.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_round.tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar este leaderboard.'
            USING ERRCODE='42501';
    END IF;

    SELECT
        v.id,
        v.freeze_id,
        v.start_format,
        v.participation_type,
        v.scoring_engine,
        v.version
      INTO v_validation
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_round_id=p_tournament_round_id
       AND v.status='validated'
     ORDER BY v.version DESC
     LIMIT 1;

    IF v_validation.id IS NULL
       OR v_validation.participation_type IS DISTINCT FROM 'equipo'
       OR v_validation.scoring_engine IS DISTINCT FROM 'team_stroke'
    THEN
        RAISE EXCEPTION
            'La ronda no corresponde a A-Go-Go/team_stroke.'
            USING ERRCODE='0A000';
    END IF;

    RETURN (
        WITH cards AS (
            SELECT
                sc.id AS score_card_id,
                sc.card_number,
                sc.card_folio,
                sc.tournament_team_id,
                ss.team_name,
                ss.team_playing_handicap,
                ss.team_handicap_version_id,
                ss.member_count,
                ss.members_snapshot,

                sc.tournament_category_id,
                c.codigo AS category_code,
                COALESCE(
                    c.nombre,
                    g.category_name
                ) AS category_name,
                c.display_order AS category_display_order,

                pr.status AS physical_status,
                pr.player_signature_present,
                pr.marker_signature_present,
                rec.status AS reconciliation_status,

                o.outcome_code,
                o.reason AS outcome_reason,

                public._clasificaciones_competitivas_ronda_categoria(
                    p_tournament_round_id,
                    sc.tournament_category_id
                ) AS classification

            FROM public.tournament_score_cards sc

            JOIN public.tournament_team_scorecard_snapshots ss
              ON ss.score_card_id=sc.id

            JOIN public.tournament_round_start_validation_groups g
              ON g.id=sc.validation_group_id
             AND g.validation_id=sc.validation_id

            LEFT JOIN public.tournament_categories tc
              ON tc.id=sc.tournament_category_id

            LEFT JOIN public.categories c
              ON c.id=tc.category_id

            LEFT JOIN public.tournament_scorecard_physical_receptions pr
              ON pr.score_card_id=sc.id

            LEFT JOIN public.tournament_scorecard_reconciliations rec
              ON rec.score_card_id=sc.id

            LEFT JOIN public.tournament_scorecard_round_outcomes o
              ON o.score_card_id=sc.id

            WHERE sc.tournament_round_id=p_tournament_round_id
              AND sc.status='issued'
              AND sc.unit_type='team'
              AND sc.tournament_team_id IS NOT NULL
        ),

        prepared AS (
            SELECT
                c.*,

                (
                    c.outcome_code IS NULL
                    AND c.physical_status='CAPTURED'
                    AND COALESCE(c.player_signature_present,false)
                    AND COALESCE(c.marker_signature_present,false)
                    AND c.reconciliation_status='COMPLETED'
                ) AS official_candidate,

                COALESCE(
                    (c.classification->>'grossEnabled')::boolean,
                    false
                ) AS gross_enabled,

                COALESCE(
                    (c.classification->>'netEnabled')::boolean,
                    false
                ) AS net_enabled

            FROM cards c
        ),

        official AS (
            SELECT
                p.*,

                CASE
                    WHEN p.official_candidate
                    THEN public.obtener_resultado_a_gogo_oficial_tarjeta(
                        p.score_card_id
                    )
                    ELSE NULL
                END AS official_result

            FROM prepared p
        ),

        raw AS (
            SELECT
                o.*,

                (
                    o.outcome_code IS NULL
                    AND o.official_result IS NOT NULL
                    AND COALESCE(
                        (o.official_result#>>'{result,ready}')::boolean,
                        false
                    )
                ) AS official_ready,

                NULLIF(
                    o.official_result#>>'{result,officialGrossTotal}',
                    ''
                )::integer AS gross_total,

                NULLIF(
                    o.official_result#>>'{result,officialNetTotal}',
                    ''
                )::integer AS net_total,

                CASE
                    WHEN o.outcome_code IS NOT NULL
                        THEN o.outcome_code
                    WHEN o.official_result IS NOT NULL
                         AND COALESCE(
                             (o.official_result#>>'{result,ready}')::boolean,
                             false
                         )
                        THEN 'OFFICIAL'
                    WHEN o.physical_status IS NULL
                        THEN 'PHYSICAL_NOT_RECEIVED'
                    WHEN o.physical_status<>'CAPTURED'
                        THEN 'PHYSICAL_NOT_CAPTURED'
                    WHEN NOT COALESCE(o.player_signature_present,false)
                      OR NOT COALESCE(o.marker_signature_present,false)
                        THEN 'SIGNATURES_MISSING'
                    WHEN o.reconciliation_status IS NULL
                        THEN 'RECONCILIATION_NOT_STARTED'
                    WHEN o.reconciliation_status<>'COMPLETED'
                        THEN 'RECONCILIATION_NOT_COMPLETED'
                    ELSE 'PENDING'
                END AS competition_status

            FROM official o
        ),

        gross_ranked AS (
            SELECT
                r.score_card_id,

                rank() OVER (
                    PARTITION BY r.tournament_category_id
                    ORDER BY r.gross_total ASC
                )::integer AS base_rank,

                count(*) OVER (
                    PARTITION BY
                        r.tournament_category_id,
                        r.gross_total
                )::integer AS tie_size

            FROM raw r
            WHERE r.official_ready
              AND r.gross_enabled
              AND r.gross_total IS NOT NULL
        ),

        net_ranked AS (
            SELECT
                r.score_card_id,

                rank() OVER (
                    PARTITION BY r.tournament_category_id
                    ORDER BY r.net_total ASC
                )::integer AS base_rank,

                count(*) OVER (
                    PARTITION BY
                        r.tournament_category_id,
                        r.net_total
                )::integer AS tie_size

            FROM raw r
            WHERE r.official_ready
              AND r.net_enabled
              AND r.net_total IS NOT NULL
        ),

        combined AS (
            SELECT
                r.*,

                gr.base_rank AS gross_rank,
                gr.tie_size AS gross_tie_size,

                nr.base_rank AS net_rank,
                nr.tie_size AS net_tie_size,

                (
                    r.gross_enabled
                    AND r.official_ready
                    AND COALESCE(gr.tie_size,0)>1
                ) AS gross_tiebreak_pending,

                (
                    r.net_enabled
                    AND r.official_ready
                    AND COALESCE(nr.tie_size,0)>1
                ) AS net_tiebreak_pending

            FROM raw r

            LEFT JOIN gross_ranked gr
              ON gr.score_card_id=r.score_card_id

            LEFT JOIN net_ranked nr
              ON nr.score_card_id=r.score_card_id
        ),

        category_summary AS (
            SELECT
                tournament_category_id,
                category_code,
                category_name,
                category_display_order,

                min(classification::text)::jsonb AS classification,

                count(*)::integer AS total_teams,

                count(*) FILTER(
                    WHERE official_ready
                )::integer AS ranked_teams,

                count(*) FILTER(
                    WHERE competition_status IN(
                        'WD','DNF','DQ','DNS','NO_CARD'
                    )
                )::integer AS terminal_exceptions,

                count(*) FILTER(
                    WHERE official_ready
                       OR competition_status IN(
                            'WD','DNF','DQ','DNS','NO_CARD'
                       )
                )::integer AS resolved_teams,

                count(*) FILTER(
                    WHERE NOT (
                        official_ready
                        OR competition_status IN(
                            'WD','DNF','DQ','DNS','NO_CARD'
                        )
                    )
                )::integer AS unresolved_teams,

                bool_or(gross_tiebreak_pending)
                    FILTER(WHERE gross_enabled)
                    AS gross_tiebreak_pending,

                bool_or(net_tiebreak_pending)
                    FILTER(WHERE net_enabled)
                    AS net_tiebreak_pending

            FROM combined

            GROUP BY
                tournament_category_id,
                category_code,
                category_name,
                category_display_order
        ),

        global_state AS (
            SELECT
                count(*)::integer AS total_teams,

                count(*) FILTER(
                    WHERE official_ready
                       OR competition_status IN(
                            'WD','DNF','DQ','DNS','NO_CARD'
                       )
                )::integer AS resolved_teams,

                count(*) FILTER(
                    WHERE NOT (
                        official_ready
                        OR competition_status IN(
                            'WD','DNF','DQ','DNS','NO_CARD'
                        )
                    )
                )::integer AS unresolved_teams,

                count(*) FILTER(
                    WHERE competition_status IN(
                        'WD','DNF','DQ','DNS','NO_CARD'
                    )
                )::integer AS terminal_exceptions,

                bool_or(gross_tiebreak_pending)
                    AS has_gross_ties,

                bool_or(net_tiebreak_pending)
                    AS has_net_ties

            FROM combined
        )

        SELECT jsonb_build_object(
            'schemaVersion',1,

            'round',jsonb_build_object(
                'tournamentId',v_round.tournament_id,
                'tournamentRoundId',v_round.id,
                'roundNumber',v_round.numero_ronda,
                'roundDate',v_round.fecha,
                'startFormat',v_validation.start_format,
                'participationType','equipo',
                'scoringEngine','team_stroke'
            ),

            'competitiveUnit',jsonb_build_object(
                'type','TEAM',
                'label','Equipo'
            ),

            'metricUnit','STROKES',

            'status',(
                SELECT jsonb_build_object(
                    'hasAnyTies',
                        COALESCE(has_gross_ties,false)
                        OR COALESCE(has_net_ties,false),

                    'leaderboardStatus',
                        CASE
                            WHEN unresolved_teams>0
                                THEN 'PROVISIONAL'
                            WHEN COALESCE(has_gross_ties,false)
                              OR COALESCE(has_net_ties,false)
                                THEN 'READY_FOR_TIEBREAK'
                            ELSE 'READY_FOR_PUBLICATION'
                        END
                )
                FROM global_state
            ),

            'summary',(
                SELECT jsonb_build_object(
                    'totalParticipants',total_teams,
                    'resolvedParticipants',resolved_teams,
                    'unresolvedParticipants',unresolved_teams,
                    'terminalExceptions',terminal_exceptions,
                    'totalTeams',total_teams,
                    'resolvedTeams',resolved_teams,
                    'unresolvedTeams',unresolved_teams
                )
                FROM global_state
            ),

            'categories',COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'tournamentCategoryId',
                            cs.tournament_category_id,
                        'categoryCode',
                            cs.category_code,
                        'categoryName',
                            cs.category_name,
                        'categoryDisplayOrder',
                            cs.category_display_order,

                        'classification',
                            cs.classification,

                        'status',
                            CASE
                                WHEN cs.unresolved_teams>0
                                    THEN 'PROVISIONAL'
                                WHEN COALESCE(
                                    cs.gross_tiebreak_pending,
                                    false
                                )
                                  OR COALESCE(
                                    cs.net_tiebreak_pending,
                                    false
                                )
                                    THEN 'READY_FOR_TIEBREAK'
                                ELSE 'READY_FOR_PUBLICATION'
                            END,

                        'summary',jsonb_build_object(
                            'totalParticipants',
                                cs.total_teams,
                            'rankedParticipants',
                                cs.ranked_teams,
                            'resolvedParticipants',
                                cs.resolved_teams,
                            'unresolvedParticipants',
                                cs.unresolved_teams,
                            'terminalExceptions',
                                cs.terminal_exceptions,
                            'grossTiebreakPending',
                                COALESCE(
                                    cs.gross_tiebreak_pending,
                                    false
                                ),
                            'netTiebreakPending',
                                COALESCE(
                                    cs.net_tiebreak_pending,
                                    false
                                ),
                            'totalTeams',
                                cs.total_teams,
                            'rankedTeams',
                                cs.ranked_teams
                        ),

                        -- Se conserva la llave "players" para compatibilidad
                        -- con la UI operativa común. Cada elemento declara
                        -- explícitamente competitiveUnit=TEAM.
                        'players',COALESCE((
                            SELECT jsonb_agg(
                                jsonb_build_object(
                                    'competitiveUnit','TEAM',

                                    'scoreCardId',
                                        p.score_card_id,
                                    'cardFolio',
                                        p.card_folio,

                                    'teamId',
                                        p.tournament_team_id,
                                    'teamName',
                                        p.team_name,

                                    -- Compatibilidad de presentación:
                                    -- playerId siempre NULL y playerName
                                    -- contiene el nombre visible del equipo.
                                    'playerId',
                                        NULL,
                                    'playerName',
                                        p.team_name,

                                    'teamPlayingHandicap',
                                        p.team_playing_handicap,
                                    'teamHandicapVersionId',
                                        p.team_handicap_version_id,
                                    'memberCount',
                                        p.member_count,
                                    'members',
                                        p.members_snapshot,

                                    'competitionStatus',
                                        p.competition_status,
                                    'outcomeReason',
                                        p.outcome_reason,

                                    'eligibleForRanking',
                                        p.official_ready,

                                    'gross',jsonb_build_object(
                                        'enabled',
                                            p.gross_enabled,
                                        'total',
                                            CASE
                                                WHEN p.official_ready
                                                THEN p.gross_total
                                                ELSE NULL
                                            END,
                                        'rank',
                                            CASE
                                                WHEN p.gross_enabled
                                                  AND p.official_ready
                                                THEN p.gross_rank
                                                ELSE NULL
                                            END,
                                        'tieSize',
                                            CASE
                                                WHEN p.gross_enabled
                                                  AND p.official_ready
                                                THEN p.gross_tie_size
                                                ELSE NULL
                                            END,
                                        'tiebreakPending',
                                            p.gross_tiebreak_pending
                                    ),

                                    'net',jsonb_build_object(
                                        'enabled',
                                            p.net_enabled,
                                        'total',
                                            CASE
                                                WHEN p.official_ready
                                                THEN p.net_total
                                                ELSE NULL
                                            END,
                                        'rank',
                                            CASE
                                                WHEN p.net_enabled
                                                  AND p.official_ready
                                                THEN p.net_rank
                                                ELSE NULL
                                            END,
                                        'tieSize',
                                            CASE
                                                WHEN p.net_enabled
                                                  AND p.official_ready
                                                THEN p.net_tie_size
                                                ELSE NULL
                                            END,
                                        'tiebreakPending',
                                            p.net_tiebreak_pending
                                    )
                                )
                                ORDER BY
                                    CASE
                                        WHEN p.official_ready THEN 0
                                        WHEN p.competition_status IN(
                                            'WD','DNF','DQ','DNS','NO_CARD'
                                        ) THEN 1
                                        ELSE 2
                                    END,
                                    COALESCE(
                                        p.net_rank,
                                        p.gross_rank
                                    ) NULLS LAST,
                                    p.card_number,
                                    p.team_name
                            )
                            FROM combined p
                            WHERE p.tournament_category_id
                                  IS NOT DISTINCT FROM
                                  cs.tournament_category_id
                        ),'[]'::jsonb)
                    )
                    ORDER BY
                        cs.category_display_order NULLS LAST,
                        cs.category_name NULLS LAST
                )
                FROM category_summary cs
            ),'[]'::jsonb)
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_leaderboard_a_gogo_ronda(uuid)
FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.obtener_leaderboard_a_gogo_ronda(uuid)
TO authenticated,service_role;


-- ----------------------------------------------------------------------------
-- 2. Extender dispatcher operativo común.
--    Se conserva íntegra la función anterior para Stroke/Stableford.
-- ----------------------------------------------------------------------------

ALTER FUNCTION public.obtener_leaderboard_operativo_ronda(uuid)
RENAME TO _obtener_leaderboard_operativo_ronda_pre211;

CREATE OR REPLACE FUNCTION public.obtener_leaderboard_operativo_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_scoring_engine text;
    v_participation_type text;
    v_team_payload jsonb;
BEGIN
    SELECT
        s.scoring_engine,
        s.participation_type
      INTO
        v_scoring_engine,
        v_participation_type
      FROM public.tournament_round_condition_snapshots s
     WHERE s.tournament_round_id=p_tournament_round_id
     ORDER BY s.created_at DESC,s.id DESC
     LIMIT 1;

    IF v_participation_type='equipo'
       AND v_scoring_engine='team_stroke'
    THEN
        v_team_payload :=
            public.obtener_leaderboard_a_gogo_ronda(
                p_tournament_round_id
            );

        -- Adaptación mínima al contrato operativo común.
        RETURN jsonb_build_object(
            'schemaVersion',1,
            'supported',true,
            'unsupportedReason',NULL,

            'round',
                v_team_payload->'round',

            'competitiveUnit',
                v_team_payload->'competitiveUnit',

            'source',jsonb_build_object(
                'rpc','obtener_leaderboard_a_gogo_ronda',
                'metricUnit','STROKES'
            ),

            'status',
                v_team_payload->'status',

            'summary',
                v_team_payload->'summary',

            'categories',
                v_team_payload->'categories'
        );
    END IF;

    RETURN public._obtener_leaderboard_operativo_ronda_pre211(
        p_tournament_round_id
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_leaderboard_operativo_ronda(uuid)
FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.obtener_leaderboard_operativo_ronda(uuid)
TO authenticated,service_role;

COMMIT;
