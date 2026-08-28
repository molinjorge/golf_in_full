-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 193 Fase 1
-- Estado competitivo por categoría — agnóstico de modalidad
--
-- OBJETIVO
--   Determinar, por categoría y sin esperar al resto de la ronda, si:
--     - todavía existen participantes sin resolver;
--     - existen desempates pendientes;
--     - la categoría está competitivamente lista para cierre.
--
-- PRINCIPIOS
--   - No calcula scores, puntos, golpes ni desempates.
--   - Reutiliza el contrato agnóstico 192:
--       obtener_leaderboard_operativo_ronda(uuid)
--   - Reutiliza el estado competitivo común:
--       obtener_estado_cierre_competitivo_ronda(uuid)
--   - No crea todavía cierre formal ni publicación por categoría.
--   - No modifica captura, outcomes, freeze, snapshots ni resultados.
--
-- ESTADOS POR CATEGORÍA
--   PROVISIONAL        -> faltan participantes por resolver.
--   TIEBREAKS_PENDING  -> todos resueltos, pero hay desempates pendientes.
--   READY_TO_CLOSE     -> todos resueltos y sin desempates pendientes.
--
-- NOTA
--   READY_TO_CLOSE significa "competitivamente lista para cierre".
--   NO significa cerrada ni publicada.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_estado_competitivo_categorias_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_operational jsonb;
    v_round_state jsonb;
    v_supported boolean;
    v_tournament_id uuid;
    v_scoring_engine text;
    v_participation_type text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    v_operational :=
        public.obtener_leaderboard_operativo_ronda(
            p_tournament_round_id
        );

    v_supported :=
        COALESCE(
            (v_operational->>'supported')::boolean,
            false
        );

    v_tournament_id :=
        NULLIF(
            v_operational#>>'{round,tournamentId}',
            ''
        )::uuid;

    v_scoring_engine :=
        v_operational#>>'{round,scoringEngine}';

    v_participation_type :=
        v_operational#>>'{round,participationType}';

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION
            'No fue posible resolver el torneo de la ronda.'
            USING ERRCODE='55000';
    END IF;

    IF NOT v_supported THEN
        RETURN jsonb_build_object(
            'schemaVersion', 1,
            'supported', false,
            'unsupportedReason',
                COALESCE(
                    v_operational->>'unsupportedReason',
                    'CATEGORY_COMPETITIVE_STATE_NOT_SUPPORTED'
                ),
            'round', v_operational->'round',
            'summary', jsonb_build_object(
                'totalCategories', 0,
                'provisionalCategories', 0,
                'tiebreakPendingCategories', 0,
                'readyToCloseCategories', 0
            ),
            'categories', '[]'::jsonb
        );
    END IF;

    v_round_state :=
        public.obtener_estado_cierre_competitivo_ronda(
            p_tournament_round_id
        );

    RETURN (
        WITH operational_categories AS (
            SELECT
                c,
                NULLIF(
                    c->>'tournamentCategoryId',
                    ''
                )::uuid AS tournament_category_id,
                c->>'categoryCode' AS category_code,
                c->>'categoryName' AS category_name,
                NULLIF(
                    c->>'categoryDisplayOrder',
                    ''
                )::integer AS category_display_order,

                COALESCE(
                    NULLIF(
                        c#>>'{summary,totalParticipants}',
                        ''
                    )::integer,
                    0
                ) AS total_participants,

                COALESCE(
                    NULLIF(
                        c#>>'{summary,rankedParticipants}',
                        ''
                    )::integer,
                    0
                ) AS ranked_participants,

                COALESCE(
                    NULLIF(
                        c#>>'{summary,resolvedParticipants}',
                        ''
                    )::integer,
                    0
                ) AS resolved_participants,

                COALESCE(
                    NULLIF(
                        c#>>'{summary,unresolvedParticipants}',
                        ''
                    )::integer,
                    0
                ) AS unresolved_participants,

                COALESCE(
                    NULLIF(
                        c#>>'{summary,terminalExceptions}',
                        ''
                    )::integer,
                    0
                ) AS terminal_exceptions

            FROM jsonb_array_elements(
                COALESCE(
                    v_operational->'categories',
                    '[]'::jsonb
                )
            ) c
        ),

        pending_ties AS (
            SELECT
                NULLIF(
                    g->>'tournamentCategoryId',
                    ''
                )::uuid AS tournament_category_id,
                count(*)::integer AS pending_tie_groups
            FROM jsonb_array_elements(
                COALESCE(
                    v_round_state->'pendingTiebreaks',
                    '[]'::jsonb
                )
            ) g
            GROUP BY
                NULLIF(
                    g->>'tournamentCategoryId',
                    ''
                )::uuid
        ),

        resolved_ties AS (
            SELECT
                NULLIF(
                    g->>'tournamentCategoryId',
                    ''
                )::uuid AS tournament_category_id,
                count(*)::integer AS resolved_tie_groups
            FROM jsonb_array_elements(
                COALESCE(
                    v_round_state->'resolvedTiebreaks',
                    '[]'::jsonb
                )
            ) g
            GROUP BY
                NULLIF(
                    g->>'tournamentCategoryId',
                    ''
                )::uuid
        ),

        category_state AS (
            SELECT
                oc.*,

                COALESCE(
                    pt.pending_tie_groups,
                    0
                ) AS pending_tie_groups,

                COALESCE(
                    rt.resolved_tie_groups,
                    0
                ) AS resolved_tie_groups,

                CASE
                    WHEN oc.total_participants <= 0
                        THEN false

                    WHEN oc.unresolved_participants > 0
                        THEN false

                    WHEN COALESCE(
                        pt.pending_tie_groups,
                        0
                    ) > 0
                        THEN false

                    ELSE true
                END AS ready_to_close,

                CASE
                    WHEN oc.unresolved_participants > 0
                        THEN 'PROVISIONAL'

                    WHEN COALESCE(
                        pt.pending_tie_groups,
                        0
                    ) > 0
                        THEN 'TIEBREAKS_PENDING'

                    WHEN oc.total_participants > 0
                        THEN 'READY_TO_CLOSE'

                    ELSE 'PROVISIONAL'
                END AS competitive_status

            FROM operational_categories oc

            LEFT JOIN pending_ties pt
              ON pt.tournament_category_id
                 IS NOT DISTINCT FROM
                 oc.tournament_category_id

            LEFT JOIN resolved_ties rt
              ON rt.tournament_category_id
                 IS NOT DISTINCT FROM
                 oc.tournament_category_id
        ),

        global_summary AS (
            SELECT
                count(*)::integer
                    AS total_categories,

                count(*) FILTER (
                    WHERE competitive_status='PROVISIONAL'
                )::integer
                    AS provisional_categories,

                count(*) FILTER (
                    WHERE competitive_status='TIEBREAKS_PENDING'
                )::integer
                    AS tiebreak_pending_categories,

                count(*) FILTER (
                    WHERE competitive_status='READY_TO_CLOSE'
                )::integer
                    AS ready_to_close_categories

            FROM category_state
        )

        SELECT jsonb_build_object(
            'schemaVersion', 1,
            'supported', true,
            'unsupportedReason', NULL,

            'round', jsonb_build_object(
                'tournamentId',
                    v_tournament_id,
                'tournamentRoundId',
                    p_tournament_round_id,
                'scoringEngine',
                    v_scoring_engine,
                'participationType',
                    v_participation_type
            ),

            'summary', (
                SELECT jsonb_build_object(
                    'totalCategories',
                        total_categories,
                    'provisionalCategories',
                        provisional_categories,
                    'tiebreakPendingCategories',
                        tiebreak_pending_categories,
                    'readyToCloseCategories',
                        ready_to_close_categories
                )
                FROM global_summary
            ),

            'categories',
                COALESCE((
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

                            'status',
                                cs.competitive_status,

                            'readyToClose',
                                cs.ready_to_close,

                            'summary',
                                jsonb_build_object(
                                    'totalParticipants',
                                        cs.total_participants,
                                    'rankedParticipants',
                                        cs.ranked_participants,
                                    'resolvedParticipants',
                                        cs.resolved_participants,
                                    'unresolvedParticipants',
                                        cs.unresolved_participants,
                                    'terminalExceptions',
                                        cs.terminal_exceptions,
                                    'pendingTieGroups',
                                        cs.pending_tie_groups,
                                    'resolvedTieGroups',
                                        cs.resolved_tie_groups
                                )
                        )
                        ORDER BY
                            cs.category_display_order NULLS LAST,
                            cs.category_name NULLS LAST
                    )
                    FROM category_state cs
                ), '[]'::jsonb)
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.obtener_estado_competitivo_categorias_ronda(uuid)
FROM PUBLIC;

REVOKE ALL ON FUNCTION
    public.obtener_estado_competitivo_categorias_ronda(uuid)
FROM anon;

GRANT EXECUTE ON FUNCTION
    public.obtener_estado_competitivo_categorias_ronda(uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION
    public.obtener_estado_competitivo_categorias_ronda(uuid)
TO service_role;

COMMENT ON FUNCTION
    public.obtener_estado_competitivo_categorias_ronda(uuid)
IS
'Estado competitivo agnóstico por categoría. Reutiliza el leaderboard '
'operativo común y el estado de cierre competitivo de la ronda para '
'determinar PROVISIONAL, TIEBREAKS_PENDING o READY_TO_CLOSE sin crear '
'cierre formal ni publicación por categoría.';
