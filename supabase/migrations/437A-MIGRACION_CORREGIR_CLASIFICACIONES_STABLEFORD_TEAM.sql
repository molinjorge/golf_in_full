-- 437A-MIGRACION_CORREGIR_CLASIFICACIONES_STABLEFORD_TEAM.sql
-- TEE CENTRAL / GOLF IN FULL
-- Corrección puntual de 437.
-- No ejecutar desde Lovable. Ejecutar manualmente en Supabase.
--
-- Causa:
-- tournament_category_classification_snapshots no tiene columnas
-- clasifica_gross / clasifica_neto. La clasificación congelada se representa
-- mediante una fila por tipo_resultado ('gross' / 'neto').
--
-- Alcance:
-- Reemplaza únicamente obtener_leaderboard_stableford_team_ronda_437(uuid).
-- No toca motor 434, tarjetas, QR, dispatchers, resultados ni desempates.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_leaderboard_stableford_team_ronda_437(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_round record;
    v_rcs record;
    v_teams jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT tr.id,tr.tournament_id,tr.numero_ronda,tr.fecha
      INTO v_round
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id
       AND tr.activo=true;

    IF v_round.id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe o no está activa.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_round.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para consultar resultados de esta ronda.'
            USING ERRCODE='42501';
    END IF;

    SELECT rcs.scoring_engine,rcs.participation_type,rcs.format_code
      INTO v_rcs
      FROM public.tournament_round_condition_snapshots rcs
     WHERE rcs.tournament_round_id=p_tournament_round_id
     ORDER BY rcs.created_at DESC,rcs.id DESC
     LIMIT 1;

    IF v_rcs.scoring_engine<>'stableford'
       OR v_rcs.participation_type<>'equipo'
       OR COALESCE(v_rcs.format_code,'')<>'STABLEFORD_EQUIPO'
    THEN
        RAISE EXCEPTION 'La ronda indicada no corresponde a Stableford por equipos.'
            USING ERRCODE='0A000';
    END IF;

    -- Una llamada al motor 434 por equipo activo. No se crea ni se usa tarjeta TEAM.
    SELECT COALESCE(
        jsonb_agg(
            public.obtener_resultado_stableford_equipo_ronda_434(
                p_tournament_round_id,tt.id
            )
            ORDER BY tt.nombre_equipo,tt.id
        ),
        '[]'::jsonb
    )
      INTO v_teams
      FROM public.tournament_teams tt
     WHERE tt.tournament_id=v_round.tournament_id
       AND tt.activo=true
       AND EXISTS (
           SELECT 1
           FROM public.tournament_score_cards sc
           WHERE sc.tournament_round_id=p_tournament_round_id
             AND sc.tournament_team_id=tt.id
             AND sc.status='issued'
             AND sc.unit_type='registration'
       );

    RETURN (
      WITH team_raw AS (
        SELECT
            t AS team_json,
            NULLIF(t->>'tournamentTeamId','')::uuid AS team_id,
            t->>'teamName' AS team_name,
            NULLIF(t->>'tournamentCategoryId','')::uuid AS category_id,
            COALESCE(NULLIF(t#>>'{result,grossPointsTotal}','')::integer,0) AS gross_points,
            COALESCE(NULLIF(t#>>'{result,netPointsTotal}','')::integer,0) AS net_points,
            COALESCE(t->'holes','[]'::jsonb) AS holes
        FROM jsonb_array_elements(v_teams) t
      ),
      category_info AS (
        SELECT
            tc.id AS category_id,
            c.codigo AS category_code,
            c.nombre AS category_name,
            c.display_order AS category_display_order,
            EXISTS (
                SELECT 1
                FROM public.tournament_category_classification_snapshots s
                WHERE s.tournament_id=v_round.tournament_id
                  AND s.tournament_category_id=tc.id
                  AND s.tipo_resultado::text='gross'
            ) AS gross_enabled,
            EXISTS (
                SELECT 1
                FROM public.tournament_category_classification_snapshots s
                WHERE s.tournament_id=v_round.tournament_id
                  AND s.tournament_category_id=tc.id
                  AND s.tipo_resultado::text='neto'
            ) AS net_enabled
        FROM public.tournament_categories tc
        JOIN public.categories c ON c.id=tc.category_id
        WHERE tc.tournament_id=v_round.tournament_id
      ),
      readiness AS (
        SELECT
            tr.team_id,
            count(*)::integer AS member_cards,
            count(*) FILTER (
                WHERE
                    o.outcome_code IN ('WD','DNF','DQ','DNS','NO_CARD')
                    OR (
                        pr.status='CAPTURED'
                        AND rec.status='COMPLETED'
                    )
            )::integer AS resolved_member_cards,
            count(*) FILTER (
                WHERE NOT (
                    o.outcome_code IN ('WD','DNF','DQ','DNS','NO_CARD')
                    OR (
                        pr.status='CAPTURED'
                        AND rec.status='COMPLETED'
                    )
                )
            )::integer AS unresolved_member_cards
        FROM team_raw tr
        JOIN public.tournament_score_cards sc
          ON sc.tournament_round_id=p_tournament_round_id
         AND sc.tournament_team_id=tr.team_id
         AND sc.status='issued'
         AND sc.unit_type='registration'
        LEFT JOIN public.tournament_scorecard_round_outcomes o
          ON o.score_card_id=sc.id
        LEFT JOIN public.tournament_scorecard_physical_receptions pr
          ON pr.score_card_id=sc.id
        LEFT JOIN public.tournament_scorecard_reconciliations rec
          ON rec.score_card_id=sc.id
        GROUP BY tr.team_id
      ),
      base AS (
        SELECT
            tr.*,
            ci.category_code,ci.category_name,ci.category_display_order,
            ci.gross_enabled,ci.net_enabled,
            COALESCE(r.member_cards,0) AS member_cards,
            COALESCE(r.resolved_member_cards,0) AS resolved_member_cards,
            COALESCE(r.unresolved_member_cards,0) AS unresolved_member_cards,
            (COALESCE(r.member_cards,0)>0 AND COALESCE(r.unresolved_member_cards,0)=0) AS official_ready
        FROM team_raw tr
        LEFT JOIN category_info ci ON ci.category_id=tr.category_id
        LEFT JOIN readiness r ON r.team_id=tr.team_id
      ),
      ranked AS (
        SELECT
            b.*,
            CASE WHEN b.official_ready AND b.gross_enabled THEN
                rank() OVER (
                    PARTITION BY b.category_id
                    ORDER BY b.gross_points DESC
                )::integer
            END AS gross_rank,
            CASE WHEN b.official_ready AND b.gross_enabled THEN
                count(*) OVER (
                    PARTITION BY b.category_id,b.gross_points
                )::integer
            END AS gross_tie_size,
            CASE WHEN b.official_ready AND b.net_enabled THEN
                rank() OVER (
                    PARTITION BY b.category_id
                    ORDER BY b.net_points DESC
                )::integer
            END AS net_rank,
            CASE WHEN b.official_ready AND b.net_enabled THEN
                count(*) OVER (
                    PARTITION BY b.category_id,b.net_points
                )::integer
            END AS net_tie_size
        FROM base b
      ),
      category_summary AS (
        SELECT
            category_id,category_code,category_name,category_display_order,
            count(*)::integer AS total_participants,
            count(*) FILTER(WHERE official_ready)::integer AS ranked_participants,
            count(*) FILTER(WHERE official_ready)::integer AS resolved_participants,
            count(*) FILTER(WHERE NOT official_ready)::integer AS unresolved_participants,
            count(*) FILTER(
                WHERE official_ready AND (
                    (gross_enabled AND COALESCE(gross_tie_size,0)>1)
                    OR
                    (net_enabled AND COALESCE(net_tie_size,0)>1)
                )
            )::integer AS participants_in_ties
        FROM ranked
        GROUP BY category_id,category_code,category_name,category_display_order
      ),
      global_state AS (
        SELECT
            count(*) FILTER(WHERE NOT official_ready)::integer AS unresolved_teams,
            count(*) FILTER(
                WHERE official_ready
                  AND gross_enabled
                  AND COALESCE(gross_tie_size,0)>1
            )::integer
            +
            count(*) FILTER(
                WHERE official_ready
                  AND net_enabled
                  AND COALESCE(net_tie_size,0)>1
            )::integer AS unresolved_tie_entries
        FROM ranked
      )
      SELECT jsonb_build_object(
        'supported',true,
        'applicable',true,
        'round',jsonb_build_object(
            'tournamentId',v_round.tournament_id,
            'tournamentRoundId',v_round.id,
            'roundNumber',v_round.numero_ronda,
            'roundDate',v_round.fecha,
            'scoringEngine','stableford',
            'participationType','equipo',
            'formatCode','STABLEFORD_EQUIPO',
            'competitiveUnit','TEAM'
        ),
        'status',(
            SELECT jsonb_build_object(
                'unresolvedTeams',unresolved_teams,
                'unresolvedTieEntries',unresolved_tie_entries,
                'leaderboardStatus',
                    CASE
                        WHEN unresolved_teams>0 THEN 'PROVISIONAL'
                        WHEN unresolved_tie_entries>0 THEN 'READY_FOR_TIEBREAK'
                        ELSE 'READY_FOR_PUBLICATION'
                    END
            )
            FROM global_state
        ),
        'summary',(
            SELECT jsonb_build_object(
                'totalParticipants',count(*)::integer,
                'rankedParticipants',count(*) FILTER(WHERE official_ready)::integer,
                'resolvedParticipants',count(*) FILTER(WHERE official_ready)::integer,
                'unresolvedParticipants',count(*) FILTER(WHERE NOT official_ready)::integer,
                'terminalExceptions',0,
                'competitiveUnit','TEAM'
            )
            FROM ranked
        ),
        'categories',COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'tournamentCategoryId',cs.category_id,
                    'categoryCode',cs.category_code,
                    'categoryName',cs.category_name,
                    'categoryDisplayOrder',cs.category_display_order,
                    'summary',jsonb_build_object(
                        'totalParticipants',cs.total_participants,
                        'rankedParticipants',cs.ranked_participants,
                        'resolvedParticipants',cs.resolved_participants,
                        'unresolvedParticipants',cs.unresolved_participants,
                        'terminalExceptions',0
                    ),
                    -- Se conserva la llave "players" porque es el contrato histórico
                    -- consumido por la formalización común. Cada elemento declara
                    -- competitiveUnit=TEAM y contiene teamId/teamName.
                    'players',COALESCE((
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'competitiveUnit','TEAM',
                                'teamId',r.team_id,
                                'teamName',r.team_name,
                                'playerId',NULL,
                                'playerName',r.team_name,
                                'eligibleForRanking',r.official_ready,
                                'competitionStatus',
                                    CASE WHEN r.official_ready THEN 'OFFICIAL' ELSE 'PENDING' END,
                                'memberCards',r.member_cards,
                                'resolvedMemberCards',r.resolved_member_cards,
                                'unresolvedMemberCards',r.unresolved_member_cards,
                                'gross',jsonb_build_object(
                                    'enabled',r.gross_enabled,
                                    'points',r.gross_points,
                                    'baseRank',r.gross_rank,
                                    'tieSize',r.gross_tie_size,
                                    'finalRank',
                                        CASE WHEN COALESCE(r.gross_tie_size,0)<=1
                                             THEN r.gross_rank ELSE NULL END,
                                    'tiebreakStatus',
                                        CASE
                                            WHEN NOT r.gross_enabled THEN NULL
                                            WHEN NOT r.official_ready THEN NULL
                                            WHEN COALESCE(r.gross_tie_size,0)<=1 THEN 'NOT_NEEDED'
                                            ELSE 'PENDING'
                                        END
                                ),
                                'net',jsonb_build_object(
                                    'enabled',r.net_enabled,
                                    'points',r.net_points,
                                    'baseRank',r.net_rank,
                                    'tieSize',r.net_tie_size,
                                    'finalRank',
                                        CASE WHEN COALESCE(r.net_tie_size,0)<=1
                                             THEN r.net_rank ELSE NULL END,
                                    'tiebreakStatus',
                                        CASE
                                            WHEN NOT r.net_enabled THEN NULL
                                            WHEN NOT r.official_ready THEN NULL
                                            WHEN COALESCE(r.net_tie_size,0)<=1 THEN 'NOT_NEEDED'
                                            ELSE 'PENDING'
                                        END
                                ),
                                'holes',r.holes,
                                'members',COALESCE(r.team_json->'members','[]'::jsonb)
                            )
                            ORDER BY
                                CASE WHEN r.official_ready THEN 0 ELSE 1 END,
                                COALESCE(r.net_rank,r.gross_rank) NULLS LAST,
                                r.team_name,r.team_id
                        )
                        FROM ranked r
                        WHERE r.category_id IS NOT DISTINCT FROM cs.category_id
                    ),'[]'::jsonb)
                )
                ORDER BY cs.category_display_order NULLS LAST,cs.category_name
            )
            FROM category_summary cs
        ),'[]'::jsonb)
      )
    );
END;
$function$;


COMMENT ON FUNCTION public.obtener_leaderboard_stableford_team_ronda_437(uuid)
IS '437A: leaderboard operativo Stableford TEAM derivado del motor 434; habilitación Gross/Neto leída correctamente desde filas tipo_resultado de tournament_category_classification_snapshots.';

COMMIT;
