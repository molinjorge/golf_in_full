-- ============================================================================
-- 159_fix_tipo_holes_motor_neto_masivo.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 159 — FIX bigint -> integer EN FUENTE MASIVA 155
--
-- PROBLEMA DETECTADO EN UI REAL DE RESULTADOS
--
-- Error:
--   42883
--   function public.calcular_golpes_handicap_hoyo(integer, integer, bigint)
--   does not exist
--
-- CAUSA
-- En obtener_resultados_oficiales_ronda(uuid), expected_holes se deriva con
-- COALESCE(c.holes_expected, s.hole_rows).
--
-- s.hole_rows proviene de count(*) y por PostgreSQL es bigint.
-- Por promoción de tipos, expected_holes termina siendo bigint.
--
-- calcular_golpes_handicap_hoyo(...) está correctamente definida como:
--   (integer, integer, integer)
--
-- Por tanto la llamada masiva debe castear explícitamente expected_holes a
-- integer.
--
-- ESTA MIGRACIÓN:
-- - reemplaza únicamente obtener_resultados_oficiales_ronda(uuid);
-- - conserva toda la lógica de la Migración 155;
-- - agrega ::integer donde expected_holes entra al motor de hándicap;
-- - no modifica datos ni tablas;
-- - no cambia GROSS, NETO, conciliación, outcomes ni leaderboard.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_resultados_oficiales_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_round record;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id es obligatorio.'
            USING ERRCODE = '22023';
    END IF;

    SELECT
        tr.id,
        tr.tournament_id,
        tr.numero_ronda,
        tr.fecha
      INTO v_round
      FROM public.tournament_rounds tr
     WHERE tr.id = p_tournament_round_id
     LIMIT 1;

    IF v_round.id IS NULL THEN
        RAISE EXCEPTION
            'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_round.tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar resultados de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    RETURN (
        WITH
        cards AS (
            SELECT
                sc.id AS score_card_id,
                sc.card_number,
                sc.card_folio,
                sc.tournament_id,
                sc.tournament_round_id,
                sc.validation_id,
                sc.validation_unit_id,
                sc.status AS score_card_status,
                sc.issued_at,

                u.player_id,
                u.tournament_registration_id,
                u.tournament_category_id,
                u.unit_name AS player_name,
                u.handicap_snapshot_id,
                u.round_handicap_snapshot_id,

                c.id AS category_id,
                c.codigo AS category_code,
                c.nombre AS category_name,
                c.display_order AS category_display_order,

                hs.handicap_index,
                hs.handicap_source,
                hs.handicap_status,
                hs.tee_name AS handicap_tee_name,

                rhs.id AS rhs_id,
                rhs.tee_id,
                rhs.course_rating,
                rhs.slope_rating,
                rhs.course_par,
                rhs.handicap_allowance_pct,
                rhs.course_handicap_unrounded,
                rhs.course_handicap,
                rhs.playing_handicap,

                COALESCE(
                    (
                        SELECT rhts.tee_name
                        FROM public.tournament_round_handicap_tee_snapshots rhts
                        WHERE rhts.round_handicap_snapshot_id = rhs.id
                          AND rhts.tee_id = rhs.tee_id
                        ORDER BY rhts.created_at DESC, rhts.id DESC
                        LIMIT 1
                    ),
                    hs.tee_name
                ) AS tee_name,

                cs.holes_expected,

                pr.id AS physical_reception_id,
                COALESCE(pr.status, 'NOT_RECEIVED') AS physical_status,

                rec.id AS reconciliation_id,
                COALESCE(rec.status, 'NOT_STARTED') AS reconciliation_status,
                rec.completed_at AS reconciliation_completed_at

            FROM public.tournament_score_cards sc

            JOIN public.tournament_round_start_validation_units u
              ON u.id = sc.validation_unit_id
             AND u.validation_id = sc.validation_id

            LEFT JOIN public.tournament_categories tc
              ON tc.id = u.tournament_category_id

            LEFT JOIN public.categories c
              ON c.id = tc.category_id

            LEFT JOIN public.tournament_handicap_snapshots hs
              ON hs.id = u.handicap_snapshot_id

            LEFT JOIN public.tournament_round_handicap_snapshots rhs
              ON rhs.id = u.round_handicap_snapshot_id

            LEFT JOIN public.tournament_scorecard_capture_sessions cs
              ON cs.score_card_id = sc.id

            LEFT JOIN public.tournament_scorecard_physical_receptions pr
              ON pr.score_card_id = sc.id

            LEFT JOIN public.tournament_scorecard_reconciliations rec
              ON rec.score_card_id = sc.id

            WHERE sc.tournament_round_id = p_tournament_round_id
              AND sc.status = 'issued'
        ),

        last_dispute AS (
            SELECT DISTINCT ON (e.hole_score_id)
                e.hole_score_id,
                e.claimed_gross_score,
                e.created_at AS last_disputed_at
            FROM public.tournament_scorecard_events e
            JOIN cards c
              ON c.score_card_id = e.score_card_id
            WHERE e.event_type = 'player_disputed'
              AND e.hole_score_id IS NOT NULL
            ORDER BY e.hole_score_id, e.created_at DESC, e.id DESC
        ),

        last_confirm AS (
            SELECT DISTINCT ON (e.hole_score_id)
                e.hole_score_id,
                e.created_at AS last_confirmed_at
            FROM public.tournament_scorecard_events e
            JOIN cards c
              ON c.score_card_id = e.score_card_id
            WHERE e.event_type = 'player_confirmed'
              AND e.hole_score_id IS NOT NULL
            ORDER BY e.hole_score_id, e.created_at DESC, e.id DESC
        ),

        evidence AS (
            SELECT
                c.score_card_id,

                hs.id AS hole_score_id,
                hs.round_hole_snapshot_id,
                hs.hole_number,
                hs.play_sequence,

                rh.par,
                rh.stroke_index,

                hs.gross_score AS digital_gross_score,
                hs.status AS digital_status,

                phs.physical_gross_score,

                res.id AS resolution_id,
                res.resolution_source,
                res.resolved_gross_score,

                CASE
                    WHEN phs.physical_gross_score IS NULL
                        THEN 'PENDIENTE_CAPTURA_FISICA'
                    WHEN hs.gross_score IS NULL
                        THEN 'SIN_CAPTURA_DIGITAL'
                    WHEN hs.gross_score = phs.physical_gross_score
                        THEN 'COINCIDE'
                    ELSE 'DIFERENCIA'
                END AS comparison_status,

                CASE
                    WHEN ld.last_disputed_at IS NULL
                        THEN 'NONE'
                    WHEN hs.status = 'disputed'
                        THEN 'ACTIVE'
                    WHEN lc.last_confirmed_at IS NULL
                         OR lc.last_confirmed_at < ld.last_disputed_at
                        THEN 'HISTORICAL_PENDING'
                    ELSE 'HISTORICAL_RESOLVED'
                END AS dispute_status,

                CASE
                    WHEN res.id IS NOT NULL
                        THEN res.resolved_gross_score
                    ELSE phs.physical_gross_score
                END AS official_gross_score,

                CASE
                    WHEN res.id IS NOT NULL
                        THEN res.resolution_source
                    WHEN hs.gross_score IS NULL
                         AND phs.physical_gross_score IS NOT NULL
                        THEN 'PHYSICAL_ONLY'
                    WHEN hs.gross_score IS NOT NULL
                         AND hs.gross_score = phs.physical_gross_score
                        THEN 'MATCHED'
                    ELSE 'INVALID_UNRESOLVED'
                END AS official_source

            FROM cards c

            JOIN public.tournament_scorecard_hole_scores hs
              ON hs.score_card_id = c.score_card_id

            JOIN public.tournament_round_hole_snapshots rh
              ON rh.id = hs.round_hole_snapshot_id

            LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
              ON phs.score_card_id = hs.score_card_id
             AND phs.round_hole_snapshot_id = hs.round_hole_snapshot_id

            LEFT JOIN public.tournament_scorecard_hole_resolutions res
              ON res.score_card_id = hs.score_card_id
             AND res.round_hole_snapshot_id = hs.round_hole_snapshot_id

            LEFT JOIN last_dispute ld
              ON ld.hole_score_id = hs.id

            LEFT JOIN last_confirm lc
              ON lc.hole_score_id = hs.id
        ),

        classified AS (
            SELECT
                e.*,
                (
                    e.comparison_status = 'DIFERENCIA'
                    OR e.dispute_status IN ('ACTIVE','HISTORICAL_PENDING')
                    OR e.comparison_status = 'PENDIENTE_CAPTURA_FISICA'
                ) AS needs_review
            FROM evidence e
        ),

        shape AS (
            SELECT
                c.score_card_id,

                count(cl.hole_score_id) AS hole_rows,
                count(DISTINCT cl.stroke_index) AS distinct_si,
                min(cl.stroke_index) AS min_si,
                max(cl.stroke_index) AS max_si,

                count(*) FILTER (
                    WHERE cl.physical_gross_score IS NOT NULL
                ) AS physical_holes,

                count(*) FILTER (
                    WHERE cl.official_gross_score IS NOT NULL
                ) AS official_holes,

                count(*) FILTER (
                    WHERE cl.official_source = 'INVALID_UNRESOLVED'
                ) AS invalid_official_source,

                count(*) FILTER (
                    WHERE cl.needs_review
                ) AS review_holes,

                count(*) FILTER (
                    WHERE cl.needs_review
                      AND cl.resolution_id IS NULL
                ) AS unresolved_review_holes

            FROM cards c
            LEFT JOIN classified cl
              ON cl.score_card_id = c.score_card_id
            GROUP BY c.score_card_id
        ),

        readiness AS (
            SELECT
                c.*,
                s.hole_rows,
                s.distinct_si,
                s.min_si,
                s.max_si,
                s.physical_holes,
                s.official_holes,
                s.invalid_official_source,
                s.review_holes,
                s.unresolved_review_holes,

                COALESCE(c.holes_expected, s.hole_rows) AS expected_holes,

                (
                    c.physical_status = 'CAPTURED'
                    AND c.reconciliation_status = 'COMPLETED'
                    AND c.round_handicap_snapshot_id IS NOT NULL
                    AND c.rhs_id IS NOT NULL
                    AND COALESCE(c.holes_expected, s.hole_rows) > 0
                    AND s.hole_rows = COALESCE(c.holes_expected, s.hole_rows)
                    AND s.physical_holes = COALESCE(c.holes_expected, s.hole_rows)
                    AND s.official_holes = COALESCE(c.holes_expected, s.hole_rows)
                    AND s.invalid_official_source = 0
                    AND s.unresolved_review_holes = 0
                    AND s.distinct_si = COALESCE(c.holes_expected, s.hole_rows)
                    AND s.min_si = 1
                    AND s.max_si = COALESCE(c.holes_expected, s.hole_rows)
                ) AS structurally_ready,

                CASE
                    WHEN c.physical_status = 'NOT_RECEIVED'
                        THEN 'PHYSICAL_NOT_RECEIVED'
                    WHEN c.physical_status = 'RECEIVED'
                        THEN 'PHYSICAL_RECEIVED'
                    WHEN c.physical_status = 'IN_CAPTURE'
                        THEN 'PHYSICAL_IN_CAPTURE'
                    WHEN c.physical_status = 'VOIDED'
                        THEN 'PHYSICAL_VOIDED'
                    WHEN c.physical_status = 'CAPTURED'
                         AND c.reconciliation_status = 'NOT_STARTED'
                        THEN 'RECONCILIATION_NOT_STARTED'
                    WHEN c.physical_status = 'CAPTURED'
                         AND c.reconciliation_status = 'PENDING'
                        THEN 'RECONCILIATION_PENDING'
                    WHEN c.physical_status = 'CAPTURED'
                         AND c.reconciliation_status = 'IN_REVIEW'
                        THEN 'RECONCILIATION_IN_REVIEW'
                    WHEN c.reconciliation_status = 'VOIDED'
                        THEN 'RECONCILIATION_VOIDED'
                    WHEN c.physical_status = 'CAPTURED'
                         AND c.reconciliation_status = 'COMPLETED'
                         AND c.round_handicap_snapshot_id IS NULL
                        THEN 'HANDICAP_SNAPSHOT_MISSING'
                    WHEN c.physical_status = 'CAPTURED'
                         AND c.reconciliation_status = 'COMPLETED'
                         AND (
                            s.distinct_si <> COALESCE(c.holes_expected, s.hole_rows)
                            OR s.min_si <> 1
                            OR s.max_si <> COALESCE(c.holes_expected, s.hole_rows)
                         )
                        THEN 'STROKE_INDEX_INVALID'
                    WHEN c.physical_status = 'CAPTURED'
                         AND c.reconciliation_status = 'COMPLETED'
                         AND (
                            s.official_holes <> COALESCE(c.holes_expected, s.hole_rows)
                            OR s.invalid_official_source > 0
                            OR s.unresolved_review_holes > 0
                         )
                        THEN 'OFFICIAL_DATA_INCOMPLETE'
                    WHEN c.physical_status = 'CAPTURED'
                         AND c.reconciliation_status = 'COMPLETED'
                        THEN 'OFFICIAL_READY'
                    ELSE 'NOT_READY'
                END AS preliminary_status

            FROM cards c
            JOIN shape s
              ON s.score_card_id = c.score_card_id
        ),

        hole_calc AS (
            SELECT
                r.score_card_id,
                cl.hole_number,
                cl.play_sequence,
                cl.par,
                cl.stroke_index,
                cl.official_gross_score,
                cl.official_source,

                CASE
                    WHEN r.structurally_ready
                    THEN public.calcular_golpes_handicap_hoyo(
                        r.playing_handicap,
                        cl.stroke_index,
                        r.expected_holes::integer
                    )
                    ELSE NULL
                END AS handicap_strokes

            FROM readiness r
            JOIN classified cl
              ON cl.score_card_id = r.score_card_id
        ),

        totals AS (
            SELECT
                r.score_card_id,

                sum(hc.official_gross_score) FILTER (
                    WHERE r.structurally_ready
                ) AS official_gross_total,

                sum(hc.handicap_strokes) FILTER (
                    WHERE r.structurally_ready
                ) AS handicap_strokes_total,

                sum(
                    hc.official_gross_score - hc.handicap_strokes
                ) FILTER (
                    WHERE r.structurally_ready
                ) AS official_net_total

            FROM readiness r
            LEFT JOIN hole_calc hc
              ON hc.score_card_id = r.score_card_id
            GROUP BY r.score_card_id
        ),

        final_cards AS (
            SELECT
                r.*,
                t.official_gross_total,
                t.handicap_strokes_total,
                t.official_net_total,

                (
                    r.structurally_ready
                    AND t.handicap_strokes_total = r.playing_handicap
                ) AS ready,

                CASE
                    WHEN r.structurally_ready
                         AND t.handicap_strokes_total = r.playing_handicap
                        THEN 'OFFICIAL_READY'
                    WHEN r.structurally_ready
                         AND t.handicap_strokes_total IS DISTINCT FROM r.playing_handicap
                        THEN 'HANDICAP_DISTRIBUTION_INVALID'
                    ELSE r.preliminary_status
                END AS result_status

            FROM readiness r
            LEFT JOIN totals t
              ON t.score_card_id = r.score_card_id
        ),

        result_rows AS (
            SELECT
                fc.*,

                CASE
                    WHEN fc.ready THEN '[]'::jsonb
                    ELSE (
                        SELECT COALESCE(jsonb_agg(issue), '[]'::jsonb)
                        FROM (
                            SELECT to_jsonb(x.issue) AS issue
                            FROM (
                                VALUES
                                    (
                                        CASE
                                            WHEN fc.physical_status <> 'CAPTURED'
                                            THEN 'PHYSICAL_NOT_CAPTURED'
                                        END
                                    ),
                                    (
                                        CASE
                                            WHEN fc.reconciliation_status <> 'COMPLETED'
                                            THEN 'RECONCILIATION_NOT_COMPLETED'
                                        END
                                    ),
                                    (
                                        CASE
                                            WHEN fc.round_handicap_snapshot_id IS NULL
                                              OR fc.rhs_id IS NULL
                                            THEN 'ROUND_HANDICAP_SNAPSHOT_MISSING'
                                        END
                                    ),
                                    (
                                        CASE
                                            WHEN fc.hole_rows <> fc.expected_holes
                                            THEN 'HOLE_ROWS_INCOMPLETE'
                                        END
                                    ),
                                    (
                                        CASE
                                            WHEN fc.physical_holes <> fc.expected_holes
                                            THEN 'PHYSICAL_HOLES_INCOMPLETE'
                                        END
                                    ),
                                    (
                                        CASE
                                            WHEN fc.official_holes <> fc.expected_holes
                                            THEN 'OFFICIAL_HOLES_INCOMPLETE'
                                        END
                                    ),
                                    (
                                        CASE
                                            WHEN fc.unresolved_review_holes > 0
                                            THEN 'UNRESOLVED_REVIEW_HOLES'
                                        END
                                    ),
                                    (
                                        CASE
                                            WHEN fc.invalid_official_source > 0
                                            THEN 'INVALID_OFFICIAL_SOURCE'
                                        END
                                    ),
                                    (
                                        CASE
                                            WHEN fc.distinct_si <> fc.expected_holes
                                              OR fc.min_si <> 1
                                              OR fc.max_si <> fc.expected_holes
                                            THEN 'STROKE_INDEX_INVALID'
                                        END
                                    ),
                                    (
                                        CASE
                                            WHEN fc.structurally_ready
                                             AND fc.handicap_strokes_total
                                                 IS DISTINCT FROM fc.playing_handicap
                                            THEN 'HANDICAP_DISTRIBUTION_INVALID'
                                        END
                                    )
                            ) x(issue)
                            WHERE x.issue IS NOT NULL
                        ) q
                    )
                END AS issues

            FROM final_cards fc
        ),

        status_summary AS (
            SELECT
                count(*) AS total_cards,
                count(*) FILTER (WHERE ready) AS ready_cards,
                count(*) FILTER (WHERE NOT ready) AS pending_cards,

                count(*) FILTER (
                    WHERE result_status = 'PHYSICAL_NOT_RECEIVED'
                ) AS physical_not_received,

                count(*) FILTER (
                    WHERE result_status IN (
                        'PHYSICAL_RECEIVED',
                        'PHYSICAL_IN_CAPTURE'
                    )
                ) AS physical_pending,

                count(*) FILTER (
                    WHERE result_status IN (
                        'RECONCILIATION_NOT_STARTED',
                        'RECONCILIATION_PENDING',
                        'RECONCILIATION_IN_REVIEW'
                    )
                ) AS reconciliation_pending,

                count(*) FILTER (
                    WHERE result_status = 'OFFICIAL_READY'
                ) AS official_ready

            FROM result_rows
        )

        SELECT jsonb_build_object(
            'round',
            jsonb_build_object(
                'tournamentId', v_round.tournament_id,
                'tournamentRoundId', v_round.id,
                'roundNumber', v_round.numero_ronda,
                'roundDate', v_round.fecha
            ),

            'summary',
            (
                SELECT jsonb_build_object(
                    'totalCards', total_cards,
                    'readyCards', ready_cards,
                    'pendingCards', pending_cards,
                    'physicalNotReceived', physical_not_received,
                    'physicalPending', physical_pending,
                    'reconciliationPending', reconciliation_pending,
                    'officialReady', official_ready
                )
                FROM status_summary
            ),

            'cards',
            COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'scoreCardId', rr.score_card_id,
                        'cardNumber', rr.card_number,
                        'cardFolio', rr.card_folio,

                        'playerId', rr.player_id,
                        'playerName', rr.player_name,

                        'tournamentRegistrationId',
                            rr.tournament_registration_id,

                        'tournamentCategoryId',
                            rr.tournament_category_id,

                        'categoryCode', rr.category_code,
                        'categoryName', rr.category_name,
                        'categoryDisplayOrder',
                            rr.category_display_order,

                        'teeId', rr.tee_id,
                        'teeName', rr.tee_name,

                        'handicapIndex', rr.handicap_index,
                        'handicapSource', rr.handicap_source,
                        'handicapStatus', rr.handicap_status,
                        'courseRating', rr.course_rating,
                        'slopeRating', rr.slope_rating,
                        'coursePar', rr.course_par,
                        'handicapAllowancePct',
                            rr.handicap_allowance_pct,
                        'courseHandicapUnrounded',
                            rr.course_handicap_unrounded,
                        'courseHandicap', rr.course_handicap,
                        'playingHandicap', rr.playing_handicap,

                        'physicalStatus', rr.physical_status,
                        'reconciliationStatus',
                            rr.reconciliation_status,
                        'reconciliationCompletedAt',
                            rr.reconciliation_completed_at,

                        'resultStatus', rr.result_status,
                        'ready', rr.ready,
                        'issues', rr.issues,

                        'holesExpected', rr.expected_holes,
                        'holesOfficial',
                            CASE WHEN rr.ready
                                 THEN rr.official_holes
                                 ELSE NULL END,

                        'officialGrossTotal',
                            CASE WHEN rr.ready
                                 THEN rr.official_gross_total
                                 ELSE NULL END,

                        'handicapStrokesTotal',
                            CASE WHEN rr.ready
                                 THEN rr.handicap_strokes_total
                                 ELSE NULL END,

                        'officialNetTotal',
                            CASE WHEN rr.ready
                                 THEN rr.official_net_total
                                 ELSE NULL END,

                        'holes',
                            CASE
                                WHEN rr.ready THEN COALESCE((
                                    SELECT jsonb_agg(
                                        jsonb_build_object(
                                            'holeNumber', hc.hole_number,
                                            'playSequence', hc.play_sequence,
                                            'par', hc.par,
                                            'strokeIndex', hc.stroke_index,
                                            'officialGrossScore',
                                                hc.official_gross_score,
                                            'officialGrossSource',
                                                hc.official_source,
                                            'handicapStrokes',
                                                hc.handicap_strokes,
                                            'officialNetScore',
                                                hc.official_gross_score
                                                - hc.handicap_strokes
                                        )
                                        ORDER BY hc.play_sequence
                                    )
                                    FROM hole_calc hc
                                    WHERE hc.score_card_id = rr.score_card_id
                                ), '[]'::jsonb)
                                ELSE '[]'::jsonb
                            END
                    )
                    ORDER BY
                        rr.category_display_order NULLS LAST,
                        rr.category_name NULLS LAST,
                        rr.card_number,
                        rr.player_name
                )
                FROM result_rows rr
            ), '[]'::jsonb)
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_resultados_oficiales_ronda(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.obtener_resultados_oficiales_ronda(uuid)
TO authenticated;

COMMIT;
