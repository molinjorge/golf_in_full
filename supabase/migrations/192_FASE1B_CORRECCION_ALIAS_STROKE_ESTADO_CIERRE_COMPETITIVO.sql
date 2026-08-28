-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 192 Fase 1B
-- Corrección de alias Stroke en estado de cierre competitivo
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_estado_cierre_competitivo_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_round_number integer;
    v_round_date date;
    v_scoring_engine text;
    v_participation_type text;
    v_results_close jsonb;
    v_tiebreak_engine jsonb;
    v_manual_resolutions jsonb;
    v_cards_ready boolean;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    SELECT
        tr.tournament_id,
        tr.numero_ronda,
        tr.fecha,
        rcs.scoring_engine,
        rcs.participation_type
    INTO
        v_tournament_id,
        v_round_number,
        v_round_date,
        v_scoring_engine,
        v_participation_type
    FROM public.tournament_rounds tr
    LEFT JOIN LATERAL (
        SELECT s.scoring_engine, s.participation_type
        FROM public.tournament_round_condition_snapshots s
        WHERE s.tournament_round_id = tr.id
        ORDER BY s.created_at DESC, s.id DESC
        LIMIT 1
    ) rcs ON true
    WHERE tr.id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF v_scoring_engine IS NULL THEN
        RAISE EXCEPTION 'La ronda no tiene snapshot congelado de scoring.'
            USING ERRCODE='55000';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso administrativo para consultar el cierre competitivo.'
            USING ERRCODE='42501';
    END IF;

    v_results_close :=
        public.validar_cierre_resultados_ronda(p_tournament_round_id);

    IF v_scoring_engine IN ('stroke','stroke_play')
       AND v_participation_type='individual'
    THEN
        v_tiebreak_engine :=
            public.obtener_desempates_ronda(p_tournament_round_id);

    ELSIF v_scoring_engine='stableford'
          AND v_participation_type='individual'
    THEN
        v_tiebreak_engine :=
            public.obtener_desempates_stableford_ronda(p_tournament_round_id);

    ELSE
        RAISE EXCEPTION
            'El cierre competitivo todavía no soporta scoring_engine=% / participation_type=%.',
            v_scoring_engine,
            COALESCE(v_participation_type,'NULL')
            USING ERRCODE='0A000';
    END IF;

    v_manual_resolutions :=
        public.obtener_resoluciones_desempate_ronda(p_tournament_round_id);

    v_cards_ready :=
        COALESCE((v_results_close->>'readyToCloseResults')::boolean,false);

    RETURN (
        WITH tie_groups AS (
            SELECT
                g,
                NULLIF(g->>'tournamentCategoryId','')::uuid AS tournament_category_id,
                g->>'resultType' AS result_type,
                NULLIF(g->>'baseRank','')::integer AS base_rank,
                COALESCE(
                    NULLIF(g->>'tiedTotal','')::integer,
                    NULLIF(g->>'tiedPoints','')::integer
                ) AS tied_total,
                NULLIF(g->>'tieSize','')::integer AS tie_size,
                g->>'status' AS engine_status,
                g->>'categoryCode' AS category_code,
                g->>'categoryName' AS category_name
            FROM jsonb_array_elements(
                COALESCE(v_tiebreak_engine->'tieGroups','[]'::jsonb)
            ) g
        ),
        manual_active AS (
            SELECT
                NULLIF(r->>'resolutionId','')::uuid AS resolution_id,
                NULLIF(r->>'tournamentCategoryId','')::uuid AS tournament_category_id,
                r->>'resultType' AS result_type,
                NULLIF(r->>'baseRank','')::integer AS base_rank,
                NULLIF(r->>'tiedTotal','')::integer AS tied_total,
                r->>'methodCode' AS method_code,
                r->>'methodName' AS method_name,
                r->>'resolutionMode' AS resolution_mode,
                r->>'resolvedAt' AS resolved_at
            FROM jsonb_array_elements(
                COALESCE(v_manual_resolutions->'resolutions','[]'::jsonb)
            ) r
            WHERE r->>'status'='COMPLETED'
        ),
        effective_groups AS (
            SELECT
                tg.*,
                ma.resolution_id,
                ma.method_code AS manual_method_code,
                ma.method_name AS manual_method_name,
                ma.resolution_mode,
                ma.resolved_at,
                CASE
                    WHEN tg.engine_status='RESOLVED_AUTOMATIC' THEN true
                    WHEN ma.resolution_id IS NOT NULL THEN true
                    ELSE false
                END AS resolved_effectively,
                CASE
                    WHEN tg.engine_status='RESOLVED_AUTOMATIC' THEN 'AUTOMATIC'
                    WHEN ma.resolution_id IS NOT NULL THEN 'MANUAL'
                    ELSE 'PENDING'
                END AS resolution_source
            FROM tie_groups tg
            LEFT JOIN manual_active ma
              ON ma.tournament_category_id = tg.tournament_category_id
             AND ma.result_type = tg.result_type
             AND ma.base_rank = tg.base_rank
             AND ma.tied_total = tg.tied_total
        ),
        tie_summary AS (
            SELECT
                count(*)::integer AS tie_groups,
                count(*) FILTER (WHERE resolved_effectively)::integer AS resolved_groups,
                count(*) FILTER (WHERE engine_status='RESOLVED_AUTOMATIC')::integer AS automatic_resolved,
                count(*) FILTER (WHERE resolution_source='MANUAL')::integer AS manual_resolved,
                count(*) FILTER (WHERE NOT resolved_effectively)::integer AS pending_groups,
                count(*) FILTER (
                    WHERE NOT resolved_effectively
                      AND engine_status='CONFIG_MISSING'
                )::integer AS config_missing,
                count(*) FILTER (
                    WHERE NOT resolved_effectively
                      AND engine_status='MANUAL_PENDING'
                )::integer AS manual_pending,
                count(*) FILTER (
                    WHERE NOT resolved_effectively
                      AND engine_status='TIE_PERSISTS_AFTER_RULES'
                )::integer AS persists_after_rules
            FROM effective_groups
        ),
        final_state AS (
            SELECT
                ts.*,
                (ts.pending_groups=0) AS tiebreaks_ready,
                (v_cards_ready AND ts.pending_groups=0) AS competitively_closed,
                CASE
                    WHEN NOT v_cards_ready THEN 'PROVISIONAL'
                    WHEN ts.pending_groups>0 THEN 'TIEBREAKS_PENDING'
                    ELSE 'FINAL'
                END AS competitive_status
            FROM tie_summary ts
        )
        SELECT jsonb_build_object(
            'round', jsonb_build_object(
                'tournamentId', v_tournament_id,
                'tournamentRoundId', p_tournament_round_id,
                'roundNumber', v_round_number,
                'roundDate', v_round_date,
                'scoringEngine', v_scoring_engine,
                'participationType', v_participation_type
            ),
            'status', (
                SELECT jsonb_build_object(
                    'cardsReady', v_cards_ready,
                    'tiebreaksReady', tiebreaks_ready,
                    'competitivelyClosed', competitively_closed,
                    'competitiveStatus', competitive_status
                )
                FROM final_state
            ),
            'resultsClosure', v_results_close,
            'tiebreakSummary', (
                SELECT jsonb_build_object(
                    'tieGroups', tie_groups,
                    'resolvedGroups', resolved_groups,
                    'automaticResolved', automatic_resolved,
                    'manualResolved', manual_resolved,
                    'pendingGroups', pending_groups,
                    'configMissing', config_missing,
                    'manualPending', manual_pending,
                    'persistsAfterRules', persists_after_rules
                )
                FROM final_state
            ),
            'pendingTiebreaks', COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'tournamentCategoryId', eg.tournament_category_id,
                        'categoryCode', eg.category_code,
                        'categoryName', eg.category_name,
                        'resultType', eg.result_type,
                        'baseRank', eg.base_rank,
                        CASE WHEN v_scoring_engine='stableford'
                             THEN 'tiedPoints' ELSE 'tiedTotal' END,
                        eg.tied_total,
                        'tieSize', eg.tie_size,
                        'engineStatus', eg.engine_status
                    )
                    ORDER BY eg.category_name, eg.result_type, eg.base_rank
                )
                FROM effective_groups eg
                WHERE NOT eg.resolved_effectively
            ), '[]'::jsonb),
            'resolvedTiebreaks', COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'tournamentCategoryId', eg.tournament_category_id,
                        'categoryCode', eg.category_code,
                        'categoryName', eg.category_name,
                        'resultType', eg.result_type,
                        'baseRank', eg.base_rank,
                        CASE WHEN v_scoring_engine='stableford'
                             THEN 'tiedPoints' ELSE 'tiedTotal' END,
                        eg.tied_total,
                        'tieSize', eg.tie_size,
                        'resolutionSource', eg.resolution_source,
                        'engineStatus', eg.engine_status,
                        'manualResolutionId', eg.resolution_id,
                        'manualResolutionMode', eg.resolution_mode,
                        'manualMethodCode', eg.manual_method_code,
                        'manualMethodName', eg.manual_method_name,
                        'manualResolvedAt', eg.resolved_at
                    )
                    ORDER BY eg.category_name, eg.result_type, eg.base_rank
                )
                FROM effective_groups eg
                WHERE eg.resolved_effectively
            ), '[]'::jsonb)
        )
    );
END;
$function$;

COMMENT ON FUNCTION public.obtener_estado_cierre_competitivo_ronda(uuid)
IS 'Obtiene el estado competitivo de una ronda. Soporta Stroke Play individual con scoring_engine stroke o stroke_play, y Stableford individual.';
