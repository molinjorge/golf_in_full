-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 186 Fase 1H
-- Resultado oficial universal por hoyo + motor Stableford Gross/Net
--
-- OBJETIVO
--   1) Versionar el motor Stableford dentro del freeze.
--   2) Crear una frontera oficial universal de hoyo:
--        SCORE -> gross > 0
--        PICKUP -> gross NULL
--   3) Calcular puntos Stableford estándar por hoyo:
--        > +1 / sin resultado = 0
--        +1 = 1
--         0 = 2
--        -1 = 3
--        -2 = 4
--        -3 = 5
--        -4 o mejor = 6
--   4) Para NET: aplicar primero Playing Handicap por Stroke Index.
--   5) Aplicar reglas especiales congeladas, hoy:
--        HOLE_IN_ONE_OVERRIDE.
--
-- COMPATIBILIDAD
--   - NO modifica obtener_score_oficial_tarjeta().
--   - NO modifica obtener_resultado_neto_oficial_tarjeta().
--   - Stroke Play continúa usando su pipeline vigente.
--   - Stableford consume la nueva frontera universal.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Snapshot/versionado del motor Stableford.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_stableford_engine_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    freeze_id uuid NOT NULL
        REFERENCES public.tournament_condition_freezes(id) ON DELETE RESTRICT,
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,
    round_condition_snapshot_id uuid NOT NULL
        REFERENCES public.tournament_round_condition_snapshots(id) ON DELETE RESTRICT,

    engine_version text NOT NULL,
    points_table_version text NOT NULL,
    target_score_basis text NOT NULL,
    minimum_points integer NOT NULL,
    maximum_points integer NOT NULL,
    pickup_points integer NOT NULL,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_stableford_engine_snapshots_engine_ck
        CHECK (engine_version = 'stableford_individual_v1'),
    CONSTRAINT tournament_stableford_engine_snapshots_points_table_ck
        CHECK (points_table_version = 'R21.1_STANDARD_V1'),
    CONSTRAINT tournament_stableford_engine_snapshots_target_ck
        CHECK (target_score_basis = 'PAR'),
    CONSTRAINT tournament_stableford_engine_snapshots_range_ck
        CHECK (
            minimum_points = 0
            AND maximum_points = 6
            AND pickup_points = 0
        ),
    CONSTRAINT tournament_stableford_engine_snapshots_uk
        UNIQUE (freeze_id, tournament_round_id)
);

ALTER TABLE public.tournament_stableford_engine_snapshots
    ENABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS trg_no_mutar_stableford_engine_snapshots
ON public.tournament_stableford_engine_snapshots;

CREATE TRIGGER trg_no_mutar_stableford_engine_snapshots
BEFORE UPDATE OR DELETE
ON public.tournament_stableford_engine_snapshots
FOR EACH ROW
EXECUTE FUNCTION public.impedir_mutacion_snapshot_torneo();

-- ----------------------------------------------------------------------------
-- 2. Freeze: preservar 1F/1G y añadir versión del motor para cada ronda
--    Stableford Individual.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.congelar_condiciones_y_handicaps_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_result jsonb;
    v_freeze_id uuid;
    v_category_count integer;
    v_snapshot_category_count integer;
    v_category_snapshot_rows integer;
    v_special_rule_snapshot_rows integer;
    v_engine_snapshot_rows integer;
BEGIN
    v_result :=
        public._congelar_condiciones_y_handicaps_torneo_core_1861a(
            p_tournament_id
        );

    v_freeze_id := NULLIF(v_result->>'freezeId','')::uuid;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION 'El congelamiento base no devolvió freezeId.'
            USING ERRCODE='55000';
    END IF;

    -- Clasificaciones Gross/Net.
    SELECT count(*)
      INTO v_category_count
      FROM public.tournament_categories
     WHERE tournament_id=p_tournament_id;

    INSERT INTO public.tournament_category_classification_snapshots(
        freeze_id,tournament_id,source_classification_id,
        tournament_category_id,category_id,category_code,
        category_name,category_display_order,tipo_resultado
    )
    SELECT
        v_freeze_id,tc.tournament_id,cc.id,tc.id,c.id,c.codigo,
        c.nombre,c.display_order,cc.tipo_resultado
    FROM public.tournament_categories tc
    JOIN public.categories c
      ON c.id=tc.category_id
    JOIN public.tournament_category_classifications cc
      ON cc.tournament_category_id=tc.id
     AND cc.tournament_id=tc.tournament_id
    WHERE tc.tournament_id=p_tournament_id
    ON CONFLICT (freeze_id,tournament_category_id,tipo_resultado)
    DO NOTHING;

    GET DIAGNOSTICS v_category_snapshot_rows=ROW_COUNT;

    SELECT count(DISTINCT tournament_category_id)
      INTO v_snapshot_category_count
      FROM public.tournament_category_classification_snapshots
     WHERE freeze_id=v_freeze_id;

    IF v_snapshot_category_count <> v_category_count THEN
        RAISE EXCEPTION
            'El snapshot de clasificaciones por categoría quedó incompleto y el congelamiento fue revertido.'
            USING ERRCODE='55000',
                  DETAIL=format(
                      'categorias_snapshot=%s/%s',
                      v_snapshot_category_count,
                      v_category_count
                  );
    END IF;

    -- Reglas especiales Stableford.
    INSERT INTO public.tournament_stableford_special_rule_snapshots(
        freeze_id,tournament_id,source_rule_id,
        rule_code,enabled,points,behavior
    )
    SELECT
        v_freeze_id,r.tournament_id,r.id,
        r.rule_code,r.enabled,r.points,r.behavior
    FROM public.tournament_stableford_special_rules r
    WHERE r.tournament_id=p_tournament_id
    ON CONFLICT (freeze_id,rule_code)
    DO NOTHING;

    GET DIAGNOSTICS v_special_rule_snapshot_rows=ROW_COUNT;

    -- Versión del motor por ronda Stableford Individual.
    INSERT INTO public.tournament_stableford_engine_snapshots(
        freeze_id,
        tournament_id,
        tournament_round_id,
        round_condition_snapshot_id,
        engine_version,
        points_table_version,
        target_score_basis,
        minimum_points,
        maximum_points,
        pickup_points
    )
    SELECT
        v_freeze_id,
        rcs.tournament_id,
        rcs.tournament_round_id,
        rcs.id,
        'stableford_individual_v1',
        'R21.1_STANDARD_V1',
        'PAR',
        0,
        6,
        0
    FROM public.tournament_round_condition_snapshots rcs
    WHERE rcs.freeze_id=v_freeze_id
      AND rcs.scoring_engine='stableford'
      AND rcs.participation_type='individual'
    ON CONFLICT (freeze_id,tournament_round_id)
    DO NOTHING;

    GET DIAGNOSTICS v_engine_snapshot_rows=ROW_COUNT;

    RETURN v_result || jsonb_build_object(
        'categoryClassificationSnapshots',
            v_category_snapshot_rows,
        'stablefordSpecialRuleSnapshots',
            v_special_rule_snapshot_rows,
        'stablefordEngineSnapshots',
            v_engine_snapshot_rows
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.congelar_condiciones_y_handicaps_torneo(uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.congelar_condiciones_y_handicaps_torneo(uuid)
TO anon,authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 3. Función pura de puntos estándar.
--    Se permite score neto <= 0 porque un Playing Handicap alto puede producir
--    un score neto teórico menor o igual a cero. La tabla oficial se topa en 6.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.calcular_puntos_stableford_estandar(
    p_score_ajustado integer,
    p_target_score integer
)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $function$
DECLARE
    v_points integer;
BEGIN
    IF p_score_ajustado IS NULL THEN
        RETURN 0;
    END IF;

    IF p_target_score IS NULL OR p_target_score <= 0 THEN
        RAISE EXCEPTION 'target_score debe ser mayor que cero.'
            USING ERRCODE='22023';
    END IF;

    v_points := 2 + p_target_score - p_score_ajustado;

    RETURN LEAST(6,GREATEST(0,v_points));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. Resultado oficial universal de tarjeta.
--    Autoridad común para motores que admiten SCORE/PICKUP.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_resultado_oficial_universal_tarjeta(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_card record;
    v_reception record;
    v_reconciliation record;
    v_expected integer;
    v_physical_count integer;
    v_unresolved integer;
    v_invalid_official integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_score_card_id IS NULL THEN
        RAISE EXCEPTION 'score_card_id es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.validation_id,
        sc.validation_unit_id,
        sc.card_number,
        sc.card_folio,
        u.player_id,
        u.tournament_registration_id,
        u.tournament_category_id,
        u.unit_name AS player_name,
        g.category_name
      INTO v_card
      FROM public.tournament_score_cards sc
      JOIN public.tournament_round_start_validation_units u
        ON u.id=sc.validation_unit_id
       AND u.validation_id=sc.validation_id
      JOIN public.tournament_round_start_validation_groups g
        ON g.id=sc.validation_group_id
       AND g.validation_id=sc.validation_id
     WHERE sc.id=p_score_card_id
       AND sc.status='issued'
     LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION
            'La tarjeta oficial indicada no existe o no está emitida.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_card.tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar el resultado oficial de esta tarjeta.'
            USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_reception
      FROM public.tournament_scorecard_physical_receptions
     WHERE score_card_id=v_card.id
     LIMIT 1;

    IF v_reception.id IS NULL
       OR v_reception.status<>'CAPTURED'
    THEN
        RAISE EXCEPTION
            'El resultado oficial requiere captura física finalizada.'
            USING ERRCODE='55000';
    END IF;

    SELECT *
      INTO v_reconciliation
      FROM public.tournament_scorecard_reconciliations
     WHERE score_card_id=v_card.id
     LIMIT 1;

    IF v_reconciliation.id IS NULL
       OR v_reconciliation.status<>'COMPLETED'
    THEN
        RAISE EXCEPTION
            'El resultado oficial requiere conciliación COMPLETADA.'
            USING ERRCODE='55000';
    END IF;

    SELECT cs.holes_expected
      INTO v_expected
      FROM public.tournament_scorecard_capture_sessions cs
     WHERE cs.score_card_id=v_card.id
     LIMIT 1;

    IF v_expected IS NULL THEN
        SELECT count(*)
          INTO v_expected
          FROM public.tournament_round_hole_snapshots rh
         WHERE rh.tournament_round_id=v_card.tournament_round_id;
    END IF;

    SELECT count(*)
      INTO v_physical_count
      FROM public.tournament_scorecard_physical_hole_scores phs
     WHERE phs.score_card_id=v_card.id;

    IF v_physical_count <> v_expected THEN
        RAISE EXCEPTION
            'El resultado oficial no puede construirse: captura física incompleta.'
            USING ERRCODE='55000',
                  DETAIL=format(
                      'physical_holes=%s; expected=%s',
                      v_physical_count,v_expected
                  );
    END IF;

    WITH evidence AS (
        SELECT
            rh.id AS round_hole_snapshot_id,

            hs.id AS hole_score_id,
            hs.result_type AS digital_result_type,
            hs.gross_score AS digital_gross_score,
            hs.status AS digital_status,

            phs.id AS physical_hole_score_id,
            phs.physical_result_type,
            phs.physical_gross_score,

            r.id AS resolution_id,
            r.resolution_source,
            r.resolved_result_type,
            r.resolved_gross_score,

            ld.created_at AS last_disputed_at,
            lc.created_at AS last_confirmed_at,

            CASE
                WHEN phs.id IS NULL
                    THEN 'PENDIENTE_CAPTURA_FISICA'
                WHEN hs.id IS NULL
                  OR hs.result_type='PENDING'
                    THEN 'SIN_CAPTURA_DIGITAL'
                WHEN hs.result_type
                        IS NOT DISTINCT FROM phs.physical_result_type
                 AND hs.gross_score
                        IS NOT DISTINCT FROM phs.physical_gross_score
                    THEN 'COINCIDE'
                ELSE 'DIFERENCIA'
            END AS comparison_status,

            CASE
                WHEN ld.created_at IS NULL
                    THEN 'NONE'
                WHEN hs.status='disputed'
                    THEN 'ACTIVE'
                WHEN lc.created_at IS NULL
                  OR lc.created_at<ld.created_at
                    THEN 'HISTORICAL_PENDING'
                ELSE 'HISTORICAL_RESOLVED'
            END AS dispute_status

        FROM public.tournament_round_hole_snapshots rh

        LEFT JOIN public.tournament_scorecard_hole_scores hs
          ON hs.score_card_id=v_card.id
         AND hs.round_hole_snapshot_id=rh.id

        LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
          ON phs.score_card_id=v_card.id
         AND phs.round_hole_snapshot_id=rh.id

        LEFT JOIN public.tournament_scorecard_hole_resolutions r
          ON r.score_card_id=v_card.id
         AND r.round_hole_snapshot_id=rh.id

        LEFT JOIN LATERAL (
            SELECT e.created_at
            FROM public.tournament_scorecard_events e
            WHERE hs.id IS NOT NULL
              AND e.hole_score_id=hs.id
              AND e.event_type='player_disputed'
            ORDER BY e.created_at DESC,e.id DESC
            LIMIT 1
        ) ld ON true

        LEFT JOIN LATERAL (
            SELECT e.created_at
            FROM public.tournament_scorecard_events e
            WHERE hs.id IS NOT NULL
              AND e.hole_score_id=hs.id
              AND e.event_type='player_confirmed'
            ORDER BY e.created_at DESC,e.id DESC
            LIMIT 1
        ) lc ON true

        WHERE rh.tournament_round_id=v_card.tournament_round_id
    ),
    review_holes AS (
        SELECT e.round_hole_snapshot_id
        FROM evidence e
        WHERE e.comparison_status='DIFERENCIA'
           OR e.dispute_status IN ('ACTIVE','HISTORICAL_PENDING')
           OR e.comparison_status='PENDIENTE_CAPTURA_FISICA'
    )
    SELECT count(*) FILTER (WHERE r.id IS NULL)
      INTO v_unresolved
      FROM review_holes x
      LEFT JOIN public.tournament_scorecard_hole_resolutions r
        ON r.score_card_id=v_card.id
       AND r.round_hole_snapshot_id=x.round_hole_snapshot_id;

    IF v_unresolved>0 THEN
        RAISE EXCEPTION
            'El resultado oficial no puede construirse: quedan hoyos por resolver.'
            USING ERRCODE='55000',
                  DETAIL=format(
                      'unresolved_review_holes=%s',
                      v_unresolved
                  );
    END IF;

    WITH official_rows AS (
        SELECT
            rh.id,
            CASE
                WHEN r.id IS NOT NULL
                    THEN r.resolved_result_type
                ELSE phs.physical_result_type
            END AS official_result_type,
            CASE
                WHEN r.id IS NOT NULL
                    THEN r.resolved_gross_score
                ELSE phs.physical_gross_score
            END AS official_gross_score
        FROM public.tournament_round_hole_snapshots rh
        LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
          ON phs.score_card_id=v_card.id
         AND phs.round_hole_snapshot_id=rh.id
        LEFT JOIN public.tournament_scorecard_hole_resolutions r
          ON r.score_card_id=v_card.id
         AND r.round_hole_snapshot_id=rh.id
        WHERE rh.tournament_round_id=v_card.tournament_round_id
    )
    SELECT count(*)
      INTO v_invalid_official
      FROM official_rows o
     WHERE o.official_result_type NOT IN ('SCORE','PICKUP')
        OR (
            o.official_result_type='SCORE'
            AND (
                o.official_gross_score IS NULL
                OR o.official_gross_score<=0
            )
        )
        OR (
            o.official_result_type='PICKUP'
            AND o.official_gross_score IS NOT NULL
        );

    IF v_invalid_official>0 THEN
        RAISE EXCEPTION
            'El resultado oficial contiene hoyos con contrato SCORE/PICKUP inválido.'
            USING ERRCODE='55000',
                  DETAIL=format(
                      'invalid_official_holes=%s',
                      v_invalid_official
                  );
    END IF;

    RETURN (
        WITH holes AS (
            SELECT
                rh.id AS round_hole_snapshot_id,
                rh.hole_number,
                COALESCE(
                    hs.play_sequence,
                    phs.play_sequence,
                    rh.hole_number
                ) AS play_sequence,
                rh.par,
                rh.stroke_index,

                hs.id AS hole_score_id,
                hs.result_type AS digital_result_type,
                hs.gross_score AS digital_gross_score,
                hs.status AS digital_status,

                phs.id AS physical_hole_score_id,
                phs.physical_result_type,
                phs.physical_gross_score,

                r.id AS resolution_id,
                r.resolution_source,
                r.resolved_result_type,
                r.resolved_gross_score,
                r.reason AS resolution_reason,

                CASE
                    WHEN r.id IS NOT NULL
                        THEN r.resolved_result_type
                    ELSE phs.physical_result_type
                END AS official_result_type,

                CASE
                    WHEN r.id IS NOT NULL
                        THEN r.resolved_gross_score
                    ELSE phs.physical_gross_score
                END AS official_gross_score,

                CASE
                    WHEN r.id IS NOT NULL
                        THEN r.resolution_source
                    WHEN hs.id IS NULL
                      OR hs.result_type='PENDING'
                        THEN 'PHYSICAL_ONLY'
                    WHEN hs.result_type
                            IS NOT DISTINCT FROM phs.physical_result_type
                     AND hs.gross_score
                            IS NOT DISTINCT FROM phs.physical_gross_score
                        THEN 'MATCHED'
                    ELSE 'INVALID_UNRESOLVED'
                END AS official_source

            FROM public.tournament_round_hole_snapshots rh
            LEFT JOIN public.tournament_scorecard_hole_scores hs
              ON hs.score_card_id=v_card.id
             AND hs.round_hole_snapshot_id=rh.id
            LEFT JOIN public.tournament_scorecard_physical_hole_scores phs
              ON phs.score_card_id=v_card.id
             AND phs.round_hole_snapshot_id=rh.id
            LEFT JOIN public.tournament_scorecard_hole_resolutions r
              ON r.score_card_id=v_card.id
             AND r.round_hole_snapshot_id=rh.id
            WHERE rh.tournament_round_id=v_card.tournament_round_id
        )
        SELECT jsonb_build_object(
            'scoreCard',jsonb_build_object(
                'scoreCardId',v_card.id,
                'cardNumber',v_card.card_number,
                'cardFolio',v_card.card_folio,
                'playerId',v_card.player_id,
                'playerName',v_card.player_name,
                'tournamentRegistrationId',
                    v_card.tournament_registration_id,
                'tournamentCategoryId',
                    v_card.tournament_category_id,
                'categoryName',v_card.category_name,
                'tournamentId',v_card.tournament_id,
                'tournamentRoundId',v_card.tournament_round_id
            ),
            'official',jsonb_build_object(
                'ready',true,
                'holesExpected',v_expected,
                'holesOfficial',count(*),
                'scoreHoles',
                    count(*) FILTER (
                        WHERE official_result_type='SCORE'
                    ),
                'pickupHoles',
                    count(*) FILTER (
                        WHERE official_result_type='PICKUP'
                    ),
                'physicalStatus',v_reception.status,
                'reconciliationStatus',v_reconciliation.status,
                'reconciliationCompletedAt',
                    v_reconciliation.completed_at
            ),
            'holes',COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'holeScoreId',hole_score_id,
                        'roundHoleSnapshotId',
                            round_hole_snapshot_id,
                        'holeNumber',hole_number,
                        'playSequence',play_sequence,
                        'par',par,
                        'strokeIndex',stroke_index,

                        'digitalResultType',
                            digital_result_type,
                        'digitalGrossScore',
                            digital_gross_score,
                        'digitalStatus',
                            digital_status,

                        'physicalResultType',
                            physical_result_type,
                        'physicalGrossScore',
                            physical_gross_score,

                        'resolutionId',resolution_id,
                        'resolutionSource',resolution_source,
                        'resolvedResultType',
                            resolved_result_type,
                        'resolvedGrossScore',
                            resolved_gross_score,
                        'resolutionReason',
                            resolution_reason,

                        'officialResultType',
                            official_result_type,
                        'officialGrossScore',
                            official_gross_score,
                        'officialSource',
                            official_source
                    )
                    ORDER BY play_sequence,hole_number
                ),
                '[]'::jsonb
            )
        )
        FROM holes
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.obtener_resultado_oficial_universal_tarjeta(uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    public.obtener_resultado_oficial_universal_tarjeta(uuid)
TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 5. Motor Stableford oficial Gross/Net.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_resultado_stableford_oficial_tarjeta(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_official jsonb;
    v_card record;
    v_unit record;
    v_rhs public.tournament_round_handicap_snapshots;
    v_rcs public.tournament_round_condition_snapshots;
    v_engine public.tournament_stableford_engine_snapshots;
    v_holes_count integer;
    v_distinct_si integer;
    v_min_si integer;
    v_max_si integer;
    v_handicap_strokes_total integer;
    v_hio_points integer;
    v_classifications jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    v_official :=
        public.obtener_resultado_oficial_universal_tarjeta(
            p_score_card_id
        );

    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.validation_id,
        sc.validation_unit_id,
        sc.card_number,
        sc.card_folio
      INTO v_card
      FROM public.tournament_score_cards sc
     WHERE sc.id=p_score_card_id
       AND sc.status='issued'
     LIMIT 1;

    SELECT
        u.id,
        u.player_id,
        u.tournament_registration_id,
        u.tournament_category_id,
        u.unit_name,
        u.handicap_snapshot_id,
        u.round_handicap_snapshot_id
      INTO v_unit
      FROM public.tournament_round_start_validation_units u
     WHERE u.id=v_card.validation_unit_id
       AND u.validation_id=v_card.validation_id
     LIMIT 1;

    IF v_unit.id IS NULL
       OR v_unit.round_handicap_snapshot_id IS NULL
    THEN
        RAISE EXCEPTION
            'La tarjeta no tiene snapshot de hándicap de ronda.'
            USING ERRCODE='55000';
    END IF;

    SELECT *
      INTO v_rhs
      FROM public.tournament_round_handicap_snapshots
     WHERE id=v_unit.round_handicap_snapshot_id
     LIMIT 1;

    IF v_rhs.id IS NULL THEN
        RAISE EXCEPTION
            'No existe el snapshot de hándicap de ronda.'
            USING ERRCODE='55000';
    END IF;

    SELECT *
      INTO v_rcs
      FROM public.tournament_round_condition_snapshots
     WHERE id=v_rhs.round_condition_snapshot_id
     LIMIT 1;

    IF v_rcs.id IS NULL
       OR v_rcs.scoring_engine<>'stableford'
       OR v_rcs.participation_type<>'individual'
    THEN
        RAISE EXCEPTION
            'Esta tarjeta no corresponde a Stableford Individual.'
            USING ERRCODE='0A000';
    END IF;

    SELECT *
      INTO v_engine
      FROM public.tournament_stableford_engine_snapshots
     WHERE freeze_id=v_rhs.freeze_id
       AND tournament_round_id=v_card.tournament_round_id
     LIMIT 1;

    IF v_engine.id IS NULL THEN
        RAISE EXCEPTION
            'La ronda Stableford no tiene snapshot de versión del motor.'
            USING ERRCODE='55000';
    END IF;

    SELECT s.points
      INTO v_hio_points
      FROM public.tournament_stableford_special_rule_snapshots s
     WHERE s.freeze_id=v_rhs.freeze_id
       AND s.rule_code='HOLE_IN_ONE_OVERRIDE'
       AND s.enabled=true
       AND s.behavior='OVERRIDE'
     LIMIT 1;

    SELECT COALESCE(
        jsonb_agg(
            s.tipo_resultado::text
            ORDER BY s.tipo_resultado::text
        ),
        '[]'::jsonb
    )
      INTO v_classifications
      FROM public.tournament_category_classification_snapshots s
     WHERE s.freeze_id=v_rhs.freeze_id
       AND s.tournament_category_id=v_unit.tournament_category_id;

    WITH parsed AS (
        SELECT
            (h->>'strokeIndex')::integer AS stroke_index
        FROM jsonb_array_elements(v_official->'holes') h
    )
    SELECT
        count(*),
        count(DISTINCT stroke_index),
        min(stroke_index),
        max(stroke_index)
      INTO
        v_holes_count,
        v_distinct_si,
        v_min_si,
        v_max_si
      FROM parsed;

    IF v_holes_count<=0
       OR v_distinct_si<>v_holes_count
       OR v_min_si<>1
       OR v_max_si<>v_holes_count
    THEN
        RAISE EXCEPTION
            'El Stroke Index congelado no forma una secuencia completa 1..N.'
            USING ERRCODE='55000';
    END IF;

    WITH parsed AS (
        SELECT
            (h->>'strokeIndex')::integer AS stroke_index
        FROM jsonb_array_elements(v_official->'holes') h
    )
    SELECT sum(
        public.calcular_golpes_handicap_hoyo(
            v_rhs.playing_handicap,
            p.stroke_index,
            v_holes_count
        )
    )
      INTO v_handicap_strokes_total
      FROM parsed p;

    IF v_handicap_strokes_total
       IS DISTINCT FROM v_rhs.playing_handicap
    THEN
        RAISE EXCEPTION
            'La distribución por Stroke Index no suma el Playing Handicap.'
            USING ERRCODE='55000',
                  DETAIL=format(
                      'playing_handicap=%s; distributed=%s',
                      v_rhs.playing_handicap,
                      v_handicap_strokes_total
                  );
    END IF;

    RETURN (
        WITH parsed AS (
            SELECT
                (h->>'roundHoleSnapshotId')::uuid
                    AS round_hole_snapshot_id,
                (h->>'holeNumber')::integer
                    AS hole_number,
                (h->>'playSequence')::integer
                    AS play_sequence,
                (h->>'par')::integer
                    AS par,
                (h->>'strokeIndex')::integer
                    AS stroke_index,
                h->>'officialResultType'
                    AS official_result_type,
                NULLIF(h->>'officialGrossScore','')::integer
                    AS official_gross_score,
                h->>'officialSource'
                    AS official_source
            FROM jsonb_array_elements(v_official->'holes') h
        ),
        handicapped AS (
            SELECT
                p.*,
                public.calcular_golpes_handicap_hoyo(
                    v_rhs.playing_handicap,
                    p.stroke_index,
                    v_holes_count
                ) AS handicap_strokes
            FROM parsed p
        ),
        base_points AS (
            SELECT
                h.*,

                CASE
                    WHEN h.official_result_type='PICKUP'
                        THEN 0
                    ELSE public.calcular_puntos_stableford_estandar(
                        h.official_gross_score,
                        h.par
                    )
                END AS gross_points_base,

                CASE
                    WHEN h.official_result_type='PICKUP'
                        THEN 0
                    ELSE public.calcular_puntos_stableford_estandar(
                        h.official_gross_score
                            - h.handicap_strokes,
                        h.par
                    )
                END AS net_points_base,

                CASE
                    WHEN h.official_result_type='SCORE'
                     AND h.official_gross_score=1
                     AND v_hio_points IS NOT NULL
                        THEN true
                    ELSE false
                END AS hio_override_applied

            FROM handicapped h
        ),
        final_points AS (
            SELECT
                b.*,

                CASE
                    WHEN b.hio_override_applied
                        THEN v_hio_points
                    ELSE b.gross_points_base
                END AS gross_points,

                CASE
                    WHEN b.hio_override_applied
                        THEN v_hio_points
                    ELSE b.net_points_base
                END AS net_points,

                CASE
                    WHEN b.official_result_type='SCORE'
                        THEN b.official_gross_score
                             - b.handicap_strokes
                    ELSE NULL
                END AS official_net_score

            FROM base_points b
        ),
        totals AS (
            SELECT
                sum(gross_points)::integer AS gross_points_total,
                sum(net_points)::integer AS net_points_total,
                count(*) FILTER (
                    WHERE official_result_type='PICKUP'
                )::integer AS pickup_holes,
                count(*) FILTER (
                    WHERE hio_override_applied
                )::integer AS hio_overrides_applied
            FROM final_points
        )
        SELECT jsonb_build_object(
            'scoreCard',
                v_official->'scoreCard',

            'engine',jsonb_build_object(
                'engineSnapshotId',v_engine.id,
                'engineVersion',v_engine.engine_version,
                'pointsTableVersion',
                    v_engine.points_table_version,
                'targetScoreBasis',
                    v_engine.target_score_basis,
                'minimumPoints',
                    v_engine.minimum_points,
                'maximumPoints',
                    v_engine.maximum_points,
                'pickupPoints',
                    v_engine.pickup_points
            ),

            'classification',jsonb_build_object(
                'configuredResultTypes',
                    v_classifications,
                'grossEnabled',
                    v_classifications ? 'gross',
                'netEnabled',
                    v_classifications ? 'neto'
            ),

            'handicap',jsonb_build_object(
                'roundHandicapSnapshotId',
                    v_rhs.id,
                'playingHandicap',
                    v_rhs.playing_handicap,
                'handicapStrokesTotal',
                    v_handicap_strokes_total
            ),

            'specialRules',jsonb_build_object(
                'holeInOneOverrideEnabled',
                    (v_hio_points IS NOT NULL),
                'holeInOneOverridePoints',
                    v_hio_points
            ),

            'result',jsonb_build_object(
                'ready',true,
                'holes',v_holes_count,
                'grossPointsTotal',
                    t.gross_points_total,
                'netPointsTotal',
                    t.net_points_total,
                'pickupHoles',
                    t.pickup_holes,
                'holeInOneOverridesApplied',
                    t.hio_overrides_applied
            ),

            'holes',COALESCE(
                (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'roundHoleSnapshotId',
                                f.round_hole_snapshot_id,
                            'holeNumber',
                                f.hole_number,
                            'playSequence',
                                f.play_sequence,
                            'par',
                                f.par,
                            'strokeIndex',
                                f.stroke_index,

                            'officialResultType',
                                f.official_result_type,
                            'officialGrossScore',
                                f.official_gross_score,
                            'officialSource',
                                f.official_source,

                            'handicapStrokes',
                                f.handicap_strokes,
                            'officialNetScore',
                                f.official_net_score,

                            'grossPointsBase',
                                f.gross_points_base,
                            'netPointsBase',
                                f.net_points_base,

                            'holeInOneOverrideApplied',
                                f.hio_override_applied,

                            'grossPoints',
                                f.gross_points,
                            'netPoints',
                                f.net_points
                        )
                        ORDER BY f.play_sequence,f.hole_number
                    )
                    FROM final_points f
                ),
                '[]'::jsonb
            )
        )
        FROM totals t
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.obtener_resultado_stableford_oficial_tarjeta(uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    public.obtener_resultado_stableford_oficial_tarjeta(uuid)
TO authenticated,service_role;

COMMIT;

-- ============================================================================
-- FIN MIGRACIÓN 186 FASE 1H
-- ============================================================================
