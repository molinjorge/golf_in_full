-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 325
-- BEST BALL F11 — RESULTADO OFICIAL TEAM GROSS / NET
-- ============================================================================
-- No persiste score TEAM. Deriva el resultado oficial desde evidencia
-- individual ya conciliada.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_resultado_oficial_best_ball_325(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_card record;
    v_snapshot record;
    v_rec public.tournament_scorecard_reconciliations;
    v_reception public.tournament_scorecard_physical_receptions;
    v_holes_count integer;
    v_distinct_si integer;
    v_min_si integer;
    v_max_si integer;
    v_member_count integer;
    v_expected integer;
    v_rows integer;
    v_invalid integer;
    v_no_score integer;
    v_gross_total integer;
    v_net_total integer;
    v_holes jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT
        sc.id,sc.tournament_id,sc.tournament_round_id,sc.validation_id,
        sc.tournament_team_id,sc.tournament_category_id,
        sc.card_number,sc.card_folio,sc.unit_type,sc.status,
        v.participation_type,v.scoring_engine,
        g.category_name
      INTO v_card
      FROM public.tournament_score_cards sc
      JOIN public.tournament_round_start_validations v
        ON v.id=sc.validation_id
      JOIN public.tournament_round_start_validation_groups g
        ON g.id=sc.validation_group_id
       AND g.validation_id=sc.validation_id
     WHERE sc.id=p_score_card_id
       AND sc.status='issued'
     LIMIT 1;

    IF v_card.id IS NULL
       OR v_card.unit_type IS DISTINCT FROM 'team'
       OR v_card.tournament_team_id IS NULL
       OR v_card.participation_type IS DISTINCT FROM 'equipo'
       OR v_card.scoring_engine IS DISTINCT FROM 'best_ball'
    THEN
        RAISE EXCEPTION 'La tarjeta no corresponde a Best Ball TEAM.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_card.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar el resultado oficial Best Ball.'
            USING ERRCODE='42501';
    END IF;

    SELECT * INTO v_snapshot
      FROM public.tournament_best_ball_scorecard_snapshots
     WHERE score_card_id=v_card.id
     LIMIT 1;

    IF v_snapshot.id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta Best Ball no tiene snapshot oficial.'
            USING ERRCODE='55000';
    END IF;

    SELECT * INTO v_reception
      FROM public.tournament_scorecard_physical_receptions
     WHERE score_card_id=v_card.id
     LIMIT 1;

    IF v_reception.id IS NULL OR v_reception.status<>'CAPTURED' THEN
        RAISE EXCEPTION 'El resultado oficial Best Ball requiere captura física finalizada.'
            USING ERRCODE='55000';
    END IF;

    SELECT * INTO v_rec
      FROM public.tournament_scorecard_reconciliations
     WHERE score_card_id=v_card.id
     LIMIT 1;

    IF v_rec.id IS NULL OR v_rec.status<>'COMPLETED' THEN
        RAISE EXCEPTION 'El resultado oficial Best Ball requiere conciliación completada.'
            USING ERRCODE='55000';
    END IF;

    SELECT count(*) INTO v_member_count
      FROM public.tournament_best_ball_scorecard_members
     WHERE best_ball_scorecard_snapshot_id=v_snapshot.id;

    IF v_member_count NOT BETWEEN 2 AND 5 THEN
        RAISE EXCEPTION 'El snapshot Best Ball debe contener entre 2 y 5 integrantes.'
            USING ERRCODE='55000';
    END IF;

    SELECT count(*),count(DISTINCT stroke_index),min(stroke_index),max(stroke_index)
      INTO v_holes_count,v_distinct_si,v_min_si,v_max_si
      FROM public.tournament_round_hole_snapshots h
      JOIN public.tournament_round_condition_snapshots rcs
        ON rcs.id=h.round_condition_snapshot_id
      JOIN public.tournament_round_start_validations v
        ON v.round_condition_snapshot_id=rcs.id
     WHERE v.id=v_card.validation_id;

    IF v_holes_count<>18 OR v_distinct_si<>18 OR v_min_si<>1 OR v_max_si<>18 THEN
        RAISE EXCEPTION 'Best Ball F11 requiere 18 hoyos y Stroke Index completo 1..18.'
            USING ERRCODE='55000';
    END IF;

    v_expected:=v_member_count*v_holes_count;

    -- Debe existir exactamente una evidencia digital y física por miembro/hoyo.
    SELECT count(*) INTO v_rows
      FROM public.tournament_best_ball_hole_scores d
     WHERE d.score_card_id=v_card.id;
    IF v_rows<>v_expected THEN
        RAISE EXCEPTION 'Estructura digital Best Ball incompleta: % de %.',v_rows,v_expected
            USING ERRCODE='55000';
    END IF;

    SELECT count(*) INTO v_rows
      FROM public.tournament_best_ball_physical_hole_scores ph
     WHERE ph.score_card_id=v_card.id;
    IF v_rows<>v_expected THEN
        RAISE EXCEPTION 'Estructura física Best Ball incompleta: % de %.',v_rows,v_expected
            USING ERRCODE='55000';
    END IF;

    -- Cada integrante debe conservar su RHS individual congelado.
    SELECT count(*) INTO v_invalid
      FROM public.tournament_best_ball_scorecard_members bm
      LEFT JOIN public.tournament_round_handicap_snapshots rhs
        ON rhs.id=bm.round_handicap_snapshot_id
       AND rhs.tournament_round_id=v_card.tournament_round_id
       AND rhs.player_id=bm.player_id
       AND rhs.tournament_registration_id=bm.tournament_registration_id
     WHERE bm.best_ball_scorecard_snapshot_id=v_snapshot.id
       AND (rhs.id IS NULL OR rhs.playing_handicap IS NULL);

    IF v_invalid>0 THEN
        RAISE EXCEPTION 'Hay integrantes Best Ball sin Playing Handicap individual congelado válido.'
            USING ERRCODE='55000';
    END IF;

    /*
      Fuente oficial individual:
      - Si F10 generó resolución: usar resolución.
      - Si no existe resolución: digital y físico DEBEN coincidir y el digital
        debe estar resuelto (SCORE/PICKUP, no disputed).
      Luego se calcula el net individual con el helper común y sólo después
      se elige el mínimo Gross y el mínimo Net del TEAM.
    */
    WITH evidence AS (
        SELECT
            d.best_ball_scorecard_member_id,
            d.player_id,
            bm.member_order,
            d.round_hole_snapshot_id,
            d.hole_number,
            d.play_sequence,
            h.par,
            h.stroke_index,
            rhs.playing_handicap,
            d.result_type AS digital_type,
            d.gross_score AS digital_gross,
            d.status AS digital_status,
            ph.physical_result_type AS physical_type,
            ph.physical_gross_score AS physical_gross,
            r.id AS resolution_id,
            r.resolution_source,
            r.resolved_result_type,
            r.resolved_gross_score,
            CASE
              WHEN r.id IS NOT NULL THEN r.resolved_result_type
              WHEN d.status<>'disputed'
               AND d.result_type<>'PENDING'
               AND d.result_type IS NOT DISTINCT FROM ph.physical_result_type
               AND d.gross_score IS NOT DISTINCT FROM ph.physical_gross_score
              THEN d.result_type
              ELSE NULL
            END AS official_type,
            CASE
              WHEN r.id IS NOT NULL THEN r.resolved_gross_score
              WHEN d.status<>'disputed'
               AND d.result_type='SCORE'
               AND d.result_type IS NOT DISTINCT FROM ph.physical_result_type
               AND d.gross_score IS NOT DISTINCT FROM ph.physical_gross_score
              THEN d.gross_score
              ELSE NULL
            END AS official_gross,
            CASE
              WHEN r.id IS NOT NULL THEN r.resolution_source
              WHEN d.status<>'disputed'
               AND d.result_type<>'PENDING'
               AND d.result_type IS NOT DISTINCT FROM ph.physical_result_type
               AND d.gross_score IS NOT DISTINCT FROM ph.physical_gross_score
              THEN 'MATCHED'
              ELSE NULL
            END AS official_source
        FROM public.tournament_best_ball_hole_scores d
        JOIN public.tournament_best_ball_scorecard_members bm
          ON bm.id=d.best_ball_scorecard_member_id
         AND bm.best_ball_scorecard_snapshot_id=v_snapshot.id
        JOIN public.tournament_round_handicap_snapshots rhs
          ON rhs.id=bm.round_handicap_snapshot_id
        JOIN public.tournament_round_hole_snapshots h
          ON h.id=d.round_hole_snapshot_id
        JOIN public.tournament_best_ball_physical_hole_scores ph
          ON ph.score_card_id=d.score_card_id
         AND ph.best_ball_scorecard_member_id=d.best_ball_scorecard_member_id
         AND ph.round_hole_snapshot_id=d.round_hole_snapshot_id
        LEFT JOIN public.tournament_best_ball_hole_resolutions r
          ON r.reconciliation_id=v_rec.id
         AND r.score_card_id=d.score_card_id
         AND r.best_ball_scorecard_member_id=d.best_ball_scorecard_member_id
         AND r.round_hole_snapshot_id=d.round_hole_snapshot_id
        WHERE d.score_card_id=v_card.id
    )
    SELECT count(*) INTO v_invalid
      FROM evidence
     WHERE official_type IS NULL
        OR official_type NOT IN ('SCORE','PICKUP')
        OR (official_type='SCORE' AND (official_gross IS NULL OR official_gross<=0))
        OR (official_type='PICKUP' AND official_gross IS NOT NULL);

    IF v_invalid>0 THEN
        RAISE EXCEPTION
            'La conciliación Best Ball está marcada COMPLETED pero existen % evidencias individuales sin resultado oficial válido.',
            v_invalid USING ERRCODE='55000';
    END IF;

    WITH evidence AS (
        SELECT
            d.best_ball_scorecard_member_id,d.player_id,bm.member_order,
            d.round_hole_snapshot_id,d.hole_number,d.play_sequence,
            h.par,h.stroke_index,rhs.playing_handicap,
            COALESCE(r.resolved_result_type,d.result_type) official_type,
            CASE WHEN r.id IS NOT NULL THEN r.resolved_gross_score ELSE d.gross_score END official_gross,
            CASE WHEN r.id IS NOT NULL THEN r.resolution_source ELSE 'MATCHED' END official_source,
            r.id resolution_id
        FROM public.tournament_best_ball_hole_scores d
        JOIN public.tournament_best_ball_scorecard_members bm
          ON bm.id=d.best_ball_scorecard_member_id
         AND bm.best_ball_scorecard_snapshot_id=v_snapshot.id
        JOIN public.tournament_round_handicap_snapshots rhs ON rhs.id=bm.round_handicap_snapshot_id
        JOIN public.tournament_round_hole_snapshots h ON h.id=d.round_hole_snapshot_id
        JOIN public.tournament_best_ball_physical_hole_scores ph
          ON ph.score_card_id=d.score_card_id
         AND ph.best_ball_scorecard_member_id=d.best_ball_scorecard_member_id
         AND ph.round_hole_snapshot_id=d.round_hole_snapshot_id
        LEFT JOIN public.tournament_best_ball_hole_resolutions r
          ON r.reconciliation_id=v_rec.id
         AND r.score_card_id=d.score_card_id
         AND r.best_ball_scorecard_member_id=d.best_ball_scorecard_member_id
         AND r.round_hole_snapshot_id=d.round_hole_snapshot_id
        WHERE d.score_card_id=v_card.id
          AND (
            r.id IS NOT NULL
            OR (
              d.status<>'disputed'
              AND d.result_type<>'PENDING'
              AND d.result_type IS NOT DISTINCT FROM ph.physical_result_type
              AND d.gross_score IS NOT DISTINCT FROM ph.physical_gross_score
            )
          )
    ),
    candidates AS (
        SELECT e.*,
               public.calcular_golpes_handicap_hoyo(
                   e.playing_handicap,e.stroke_index,v_holes_count
               ) handicap_strokes,
               CASE WHEN e.official_type='SCORE'
                    THEN e.official_gross-public.calcular_golpes_handicap_hoyo(
                        e.playing_handicap,e.stroke_index,v_holes_count
                    ) END net_score
        FROM evidence e
    ),
    holes AS (
        SELECT
            round_hole_snapshot_id,hole_number,play_sequence,par,stroke_index,
            min(official_gross) FILTER(WHERE official_type='SCORE') best_gross,
            min(net_score) FILTER(WHERE official_type='SCORE') best_net
        FROM candidates
        GROUP BY round_hole_snapshot_id,hole_number,play_sequence,par,stroke_index
    )
    SELECT count(*) FILTER(WHERE best_gross IS NULL OR best_net IS NULL)
      INTO v_no_score
      FROM holes;

    IF v_no_score>0 THEN
        RAISE EXCEPTION
            'Best Ball no puede producir resultado oficial: % hoyos no tienen ningún SCORE individual válido.',
            v_no_score
            USING ERRCODE='55000';
    END IF;

    WITH evidence AS (
        SELECT
            d.best_ball_scorecard_member_id,d.player_id,bm.member_order,
            d.round_hole_snapshot_id,d.hole_number,d.play_sequence,
            h.par,h.stroke_index,rhs.playing_handicap,
            COALESCE(r.resolved_result_type,d.result_type) official_type,
            CASE WHEN r.id IS NOT NULL THEN r.resolved_gross_score ELSE d.gross_score END official_gross,
            CASE WHEN r.id IS NOT NULL THEN r.resolution_source ELSE 'MATCHED' END official_source,
            r.id resolution_id
        FROM public.tournament_best_ball_hole_scores d
        JOIN public.tournament_best_ball_scorecard_members bm
          ON bm.id=d.best_ball_scorecard_member_id
         AND bm.best_ball_scorecard_snapshot_id=v_snapshot.id
        JOIN public.tournament_round_handicap_snapshots rhs ON rhs.id=bm.round_handicap_snapshot_id
        JOIN public.tournament_round_hole_snapshots h ON h.id=d.round_hole_snapshot_id
        JOIN public.tournament_best_ball_physical_hole_scores ph
          ON ph.score_card_id=d.score_card_id
         AND ph.best_ball_scorecard_member_id=d.best_ball_scorecard_member_id
         AND ph.round_hole_snapshot_id=d.round_hole_snapshot_id
        LEFT JOIN public.tournament_best_ball_hole_resolutions r
          ON r.reconciliation_id=v_rec.id
         AND r.score_card_id=d.score_card_id
         AND r.best_ball_scorecard_member_id=d.best_ball_scorecard_member_id
         AND r.round_hole_snapshot_id=d.round_hole_snapshot_id
        WHERE d.score_card_id=v_card.id
          AND (
            r.id IS NOT NULL
            OR (
              d.status<>'disputed'
              AND d.result_type<>'PENDING'
              AND d.result_type IS NOT DISTINCT FROM ph.physical_result_type
              AND d.gross_score IS NOT DISTINCT FROM ph.physical_gross_score
            )
          )
    ),
    candidates AS (
        SELECT e.*,
               public.calcular_golpes_handicap_hoyo(
                   e.playing_handicap,e.stroke_index,v_holes_count
               ) handicap_strokes,
               CASE WHEN e.official_type='SCORE'
                    THEN e.official_gross-public.calcular_golpes_handicap_hoyo(
                        e.playing_handicap,e.stroke_index,v_holes_count
                    ) END net_score
        FROM evidence e
    ),
    minima AS (
        SELECT round_hole_snapshot_id,
               min(official_gross) FILTER(WHERE official_type='SCORE') best_gross,
               min(net_score) FILTER(WHERE official_type='SCORE') best_net
        FROM candidates GROUP BY round_hole_snapshot_id
    ),
    hole_payload AS (
        SELECT
          c.round_hole_snapshot_id,c.hole_number,c.play_sequence,c.par,c.stroke_index,
          m.best_gross,m.best_net,
          jsonb_agg(jsonb_build_object(
             'bestBallScorecardMemberId',c.best_ball_scorecard_member_id,
             'playerId',c.player_id,
             'memberOrder',c.member_order,
             'officialResultType',c.official_type,
             'officialGrossScore',c.official_gross,
             'officialSource',c.official_source,
             'resolutionId',c.resolution_id,
             'playingHandicap',c.playing_handicap,
             'handicapStrokes',c.handicap_strokes,
             'officialNetScore',c.net_score,
             'countsForGross',(c.official_type='SCORE' AND c.official_gross=m.best_gross),
             'countsForNet',(c.official_type='SCORE' AND c.net_score=m.best_net)
          ) ORDER BY c.member_order,c.player_id) members,
          jsonb_agg(jsonb_build_object(
             'bestBallScorecardMemberId',c.best_ball_scorecard_member_id,
             'playerId',c.player_id,'memberOrder',c.member_order
          ) ORDER BY c.member_order,c.player_id)
          FILTER(WHERE c.official_type='SCORE' AND c.official_gross=m.best_gross) gross_players,
          jsonb_agg(jsonb_build_object(
             'bestBallScorecardMemberId',c.best_ball_scorecard_member_id,
             'playerId',c.player_id,'memberOrder',c.member_order
          ) ORDER BY c.member_order,c.player_id)
          FILTER(WHERE c.official_type='SCORE' AND c.net_score=m.best_net) net_players
        FROM candidates c
        JOIN minima m USING(round_hole_snapshot_id)
        GROUP BY c.round_hole_snapshot_id,c.hole_number,c.play_sequence,c.par,c.stroke_index,
                 m.best_gross,m.best_net
    )
    SELECT
      jsonb_agg(jsonb_build_object(
        'roundHoleSnapshotId',round_hole_snapshot_id,
        'holeNumber',hole_number,'playSequence',play_sequence,
        'par',par,'strokeIndex',stroke_index,
        'officialBestGross',best_gross,
        'officialBestNet',best_net,
        'grossCountingPlayers',COALESCE(gross_players,'[]'::jsonb),
        'netCountingPlayers',COALESCE(net_players,'[]'::jsonb),
        'grossTie',jsonb_array_length(COALESCE(gross_players,'[]'::jsonb))>1,
        'netTie',jsonb_array_length(COALESCE(net_players,'[]'::jsonb))>1,
        'members',members
      ) ORDER BY play_sequence,hole_number),
      sum(best_gross)::integer,
      sum(best_net)::integer
    INTO v_holes,v_gross_total,v_net_total
    FROM hole_payload;

    IF jsonb_array_length(COALESCE(v_holes,'[]'::jsonb))<>v_holes_count
       OR v_gross_total IS NULL OR v_net_total IS NULL
    THEN
        RAISE EXCEPTION 'No fue posible construir los 18 hoyos oficiales Best Ball.'
            USING ERRCODE='55000';
    END IF;

    RETURN jsonb_build_object(
      'schemaVersion',1,
      'engine','best_ball',
      'official',true,
      'scoreCard',jsonb_build_object(
        'id',v_card.id,'cardNumber',v_card.card_number,'cardFolio',v_card.card_folio,
        'tournamentId',v_card.tournament_id,'tournamentRoundId',v_card.tournament_round_id,
        'tournamentTeamId',v_card.tournament_team_id,
        'tournamentCategoryId',v_card.tournament_category_id,
        'categoryName',v_card.category_name,
        'memberCount',v_member_count
      ),
      'source',jsonb_build_object(
        'physicalReceptionId',v_reception.id,
        'reconciliationId',v_rec.id,
        'reconciliationStatus',v_rec.status
      ),
      'officialTotals',jsonb_build_object(
        'gross',v_gross_total,
        'net',v_net_total,
        'holes',v_holes_count
      ),
      'holes',v_holes
    );
END;
$function$;

COMMIT;
