-- ============================================================================
-- 154_motor_neto_oficial_tarjeta.sql
-- GOLF IN FULL / Tee Central
-- MIGRACIÓN 154 — MOTOR NETO OFICIAL POR TARJETA
-- ============================================================================

BEGIN;

DO $$
BEGIN
    IF to_regprocedure('public.obtener_score_oficial_tarjeta(uuid)') IS NULL THEN
        RAISE EXCEPTION
            'Migración 154 requiere public.obtener_score_oficial_tarjeta(uuid) de la Migración 153.';
    END IF;

    IF to_regclass('public.tournament_score_cards') IS NULL
       OR to_regclass('public.tournament_round_start_validation_units') IS NULL
       OR to_regclass('public.tournament_round_handicap_snapshots') IS NULL
       OR to_regclass('public.tournament_handicap_snapshots') IS NULL
    THEN
        RAISE EXCEPTION
            'Migración 154 requiere tarjetas oficiales y snapshots de hándicap de ronda.';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.calcular_golpes_handicap_hoyo(
    p_playing_handicap integer,
    p_stroke_index integer,
    p_holes_in_round integer DEFAULT 18
)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
    v_abs integer;
    v_base integer;
    v_remainder integer;
BEGIN
    IF p_playing_handicap IS NULL THEN
        RAISE EXCEPTION 'playing_handicap es obligatorio.'
            USING ERRCODE = '22023';
    END IF;

    IF p_holes_in_round IS NULL OR p_holes_in_round <= 0 THEN
        RAISE EXCEPTION 'holes_in_round debe ser mayor que cero.'
            USING ERRCODE = '22023';
    END IF;

    IF p_stroke_index IS NULL
       OR p_stroke_index < 1
       OR p_stroke_index > p_holes_in_round
    THEN
        RAISE EXCEPTION
            'stroke_index fuera de rango: debe estar entre 1 y %.',
            p_holes_in_round
            USING ERRCODE = '22023';
    END IF;

    IF p_playing_handicap = 0 THEN
        RETURN 0;
    END IF;

    IF p_playing_handicap > 0 THEN
        v_base := p_playing_handicap / p_holes_in_round;
        v_remainder := mod(p_playing_handicap, p_holes_in_round);

        RETURN v_base
            + CASE
                WHEN v_remainder > 0
                 AND p_stroke_index <= v_remainder
                THEN 1 ELSE 0
              END;
    END IF;

    -- Plus handicap: golpes cedidos empezando por SI más alto.
    v_abs := abs(p_playing_handicap);
    v_base := v_abs / p_holes_in_round;
    v_remainder := mod(v_abs, p_holes_in_round);

    RETURN -(
        v_base
        + CASE
            WHEN v_remainder > 0
             AND p_stroke_index > (p_holes_in_round - v_remainder)
            THEN 1 ELSE 0
          END
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.obtener_resultado_neto_oficial_tarjeta(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_official jsonb;
    v_card record;
    v_unit record;
    v_rhs record;
    v_hs record;
    v_holes_count integer;
    v_distinct_si integer;
    v_min_si integer;
    v_max_si integer;
    v_strokes_total integer;
    v_gross_total integer;
    v_net_total integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF p_score_card_id IS NULL THEN
        RAISE EXCEPTION 'score_card_id es obligatorio.'
            USING ERRCODE = '22023';
    END IF;

    -- La Migración 153 es la autoridad del GROSS oficial.
    v_official := public.obtener_score_oficial_tarjeta(p_score_card_id);

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
     WHERE sc.id = p_score_card_id
       AND sc.status = 'issued'
     LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION
            'La tarjeta indicada no existe o no está emitida.'
            USING ERRCODE = '22023';
    END IF;

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
     WHERE u.id = v_card.validation_unit_id
       AND u.validation_id = v_card.validation_id
     LIMIT 1;

    IF v_unit.id IS NULL THEN
        RAISE EXCEPTION
            'La tarjeta no tiene una unidad validada de salida.'
            USING ERRCODE = '55000';
    END IF;

    IF v_unit.round_handicap_snapshot_id IS NULL THEN
        RAISE EXCEPTION
            'La unidad validada no tiene round_handicap_snapshot_id.'
            USING ERRCODE = '55000';
    END IF;

    SELECT rhs.*
      INTO v_rhs
      FROM public.tournament_round_handicap_snapshots rhs
     WHERE rhs.id = v_unit.round_handicap_snapshot_id
     LIMIT 1;

    IF v_rhs.id IS NULL THEN
        RAISE EXCEPTION
            'No existe el snapshot de hándicap de la ronda asociado a la tarjeta.'
            USING ERRCODE = '55000';
    END IF;

    IF v_rhs.tournament_round_id <> v_card.tournament_round_id THEN
        RAISE EXCEPTION
            'El snapshot de hándicap no corresponde a la ronda de la tarjeta.'
            USING ERRCODE = '55000';
    END IF;

    IF v_rhs.tournament_registration_id
       IS DISTINCT FROM v_unit.tournament_registration_id
    THEN
        RAISE EXCEPTION
            'El snapshot de hándicap no corresponde a la inscripción de la tarjeta.'
            USING ERRCODE = '55000';
    END IF;

    SELECT hs.*
      INTO v_hs
      FROM public.tournament_handicap_snapshots hs
     WHERE hs.id = v_rhs.handicap_snapshot_id
     LIMIT 1;

    IF v_hs.id IS NULL THEN
        RAISE EXCEPTION
            'No existe el snapshot congelado de Handicap Index.'
            USING ERRCODE = '55000';
    END IF;

    WITH parsed AS (
        SELECT (h->>'strokeIndex')::integer AS stroke_index
        FROM jsonb_array_elements(v_official->'holes') h
    )
    SELECT
        count(*),
        count(DISTINCT stroke_index),
        min(stroke_index),
        max(stroke_index)
      INTO v_holes_count, v_distinct_si, v_min_si, v_max_si
      FROM parsed;

    IF v_holes_count <= 0 THEN
        RAISE EXCEPTION 'El score oficial no contiene hoyos.'
            USING ERRCODE = '55000';
    END IF;

    IF v_distinct_si <> v_holes_count
       OR v_min_si <> 1
       OR v_max_si <> v_holes_count
    THEN
        RAISE EXCEPTION
            'El Stroke Index congelado no forma una secuencia completa 1..N.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'holes=%s; distinct_si=%s; min_si=%s; max_si=%s',
                      v_holes_count, v_distinct_si, v_min_si, v_max_si
                  );
    END IF;

    WITH parsed AS (
        SELECT
            (h->>'officialGrossScore')::integer AS gross,
            (h->>'strokeIndex')::integer AS stroke_index
        FROM jsonb_array_elements(v_official->'holes') h
    ),
    calc AS (
        SELECT
            p.gross,
            public.calcular_golpes_handicap_hoyo(
                v_rhs.playing_handicap,
                p.stroke_index,
                v_holes_count
            ) AS handicap_strokes
        FROM parsed p
    )
    SELECT
        sum(gross),
        sum(handicap_strokes),
        sum(gross - handicap_strokes)
      INTO v_gross_total, v_strokes_total, v_net_total
      FROM calc;

    IF v_strokes_total <> v_rhs.playing_handicap THEN
        RAISE EXCEPTION
            'La distribución por Stroke Index no suma el Playing Handicap.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'playing_handicap=%s; distributed_strokes=%s',
                      v_rhs.playing_handicap, v_strokes_total
                  );
    END IF;

    RETURN (
        WITH parsed AS (
            SELECT
                (h->>'holeNumber')::integer AS hole_number,
                (h->>'playSequence')::integer AS play_sequence,
                (h->>'par')::integer AS par,
                (h->>'strokeIndex')::integer AS stroke_index,
                (h->>'officialGrossScore')::integer AS gross,
                h->>'officialSource' AS gross_source
            FROM jsonb_array_elements(v_official->'holes') h
        ),
        calc AS (
            SELECT
                p.*,
                public.calcular_golpes_handicap_hoyo(
                    v_rhs.playing_handicap,
                    p.stroke_index,
                    v_holes_count
                ) AS handicap_strokes
            FROM parsed p
        )
        SELECT jsonb_build_object(
            'scoreCard', jsonb_build_object(
                'scoreCardId', v_card.id,
                'cardNumber', v_card.card_number,
                'cardFolio', v_card.card_folio,
                'playerId', v_unit.player_id,
                'playerName', v_unit.unit_name,
                'tournamentRegistrationId', v_unit.tournament_registration_id,
                'tournamentCategoryId', v_unit.tournament_category_id,
                'tournamentId', v_card.tournament_id,
                'tournamentRoundId', v_card.tournament_round_id
            ),
            'handicap', jsonb_build_object(
                'handicapSnapshotId', v_hs.id,
                'roundHandicapSnapshotId', v_rhs.id,
                'handicapIndex', v_hs.handicap_index,
                'handicapSource', v_hs.handicap_source,
                'handicapStatus', v_hs.handicap_status,
                'teeId', v_rhs.tee_id,
                'courseRating', v_rhs.course_rating,
                'slopeRating', v_rhs.slope_rating,
                'coursePar', v_rhs.course_par,
                'handicapAllowancePct', v_rhs.handicap_allowance_pct,
                'courseHandicapUnrounded', v_rhs.course_handicap_unrounded,
                'courseHandicap', v_rhs.course_handicap,
                'playingHandicap', v_rhs.playing_handicap
            ),
            'result', jsonb_build_object(
                'ready', true,
                'holes', v_holes_count,
                'officialGrossTotal', v_gross_total,
                'handicapStrokesTotal', v_strokes_total,
                'officialNetTotal', v_net_total
            ),
            'holes', COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'holeNumber', c.hole_number,
                        'playSequence', c.play_sequence,
                        'par', c.par,
                        'strokeIndex', c.stroke_index,
                        'officialGrossScore', c.gross,
                        'officialGrossSource', c.gross_source,
                        'handicapStrokes', c.handicap_strokes,
                        'officialNetScore', c.gross - c.handicap_strokes
                    )
                    ORDER BY c.play_sequence
                ),
                '[]'::jsonb
            )
        )
        FROM calc c
    );
END;
$$;

REVOKE ALL ON FUNCTION public.calcular_golpes_handicap_hoyo(
    integer, integer, integer
) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.obtener_resultado_neto_oficial_tarjeta(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.obtener_resultado_neto_oficial_tarjeta(uuid)
TO authenticated;

COMMIT;
