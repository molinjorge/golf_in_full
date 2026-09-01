-- ============================================================================
-- MIGRACIÓN 210 FASE 7
-- A-Go-Go — resultado oficial por equipo Gross / Net
-- Proyecto: Tee Central / GOLF IN FULL
--
-- PRINCIPIOS
-- - Reutiliza obtener_resultado_oficial_universal_tarjeta().
-- - Tarjeta física obligatoria + conciliación COMPLETED.
-- - A-Go-Go exige SCORE en todos los hoyos; PICKUP nunca es resultado oficial.
-- - Exige firma de un jugador del equipo + firma de marcador contrario.
-- - Gross = suma de scores oficiales del equipo.
-- - Net   = Gross - team_playing_handicap congelado en la tarjeta oficial.
-- - Gross/Net habilitados según snapshots comunes de clasificación (Migración 198).
-- - No recalcula HCP con datos vivos.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Resultado oficial de UNA tarjeta A-Go-Go
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_resultado_a_gogo_oficial_tarjeta(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_universal jsonb;
    v_card record;
    v_validation public.tournament_round_start_validations%ROWTYPE;
    v_snapshot public.tournament_team_scorecard_snapshots%ROWTYPE;
    v_reception public.tournament_scorecard_physical_receptions%ROWTYPE;
    v_classifications jsonb;
    v_holes_expected integer;
    v_holes_official integer;
    v_pickup_holes integer;
    v_invalid_holes integer;
    v_gross_total integer;
    v_net_total integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.validation_id,
        sc.validation_unit_id,
        sc.tournament_team_id,
        sc.tournament_category_id,
        sc.card_number,
        sc.card_folio,
        sc.unit_type,
        sc.status,
        u.unit_name AS team_name,
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

    SELECT *
      INTO v_validation
      FROM public.tournament_round_start_validations
     WHERE id=v_card.validation_id
     LIMIT 1;

    IF v_card.unit_type IS DISTINCT FROM 'team'
       OR v_card.tournament_team_id IS NULL
       OR v_validation.participation_type IS DISTINCT FROM 'equipo'
       OR v_validation.scoring_engine IS DISTINCT FROM 'team_stroke'
    THEN
        RAISE EXCEPTION
            'Esta tarjeta no corresponde a A-Go-Go/team_stroke.'
            USING ERRCODE='0A000';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_card.tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar el resultado oficial de esta tarjeta.'
            USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_snapshot
      FROM public.tournament_team_scorecard_snapshots
     WHERE score_card_id=v_card.id
     LIMIT 1;

    IF v_snapshot.id IS NULL THEN
        RAISE EXCEPTION
            'La tarjeta A-Go-Go no tiene snapshot oficial de equipo/HCP.'
            USING ERRCODE='55000';
    END IF;

    SELECT *
      INTO v_reception
      FROM public.tournament_scorecard_physical_receptions
     WHERE score_card_id=v_card.id
     LIMIT 1;

    IF v_reception.id IS NULL
       OR v_reception.status IS DISTINCT FROM 'CAPTURED'
    THEN
        RAISE EXCEPTION
            'El resultado oficial requiere tarjeta física capturada.'
            USING ERRCODE='55000';
    END IF;

    -- Contrato operativo acordado para A-Go-Go:
    -- una firma del equipo y una firma de equipo contrario/marcador.
    IF NOT v_reception.player_signature_present
       OR NOT v_reception.marker_signature_present
    THEN
        RAISE EXCEPTION
            'La tarjeta física A-Go-Go requiere firma del equipo y del marcador contrario.'
            USING ERRCODE='55000',
                  DETAIL=format(
                    'team_signature=%s; marker_signature=%s',
                    v_reception.player_signature_present,
                    v_reception.marker_signature_present
                  );
    END IF;

    -- Fuente oficial común: física obligatoria + conciliación completada.
    v_universal :=
        public.obtener_resultado_oficial_universal_tarjeta(
            p_score_card_id
        );

    v_holes_expected :=
        NULLIF(v_universal#>>'{official,holesExpected}','')::integer;

    v_holes_official :=
        NULLIF(v_universal#>>'{official,holesOfficial}','')::integer;

    v_pickup_holes :=
        NULLIF(v_universal#>>'{official,pickupHoles}','')::integer;

    IF v_holes_expected IS NULL
       OR v_holes_expected<=0
       OR v_holes_official IS DISTINCT FROM v_holes_expected
    THEN
        RAISE EXCEPTION
            'El resultado oficial A-Go-Go no contiene todos los hoyos esperados.'
            USING ERRCODE='55000';
    END IF;

    IF COALESCE(v_pickup_holes,0)<>0 THEN
        RAISE EXCEPTION
            'A-Go-Go no admite PICKUP como resultado oficial.'
            USING ERRCODE='0A000',
                  DETAIL=format('pickup_holes=%s',v_pickup_holes);
    END IF;

    -- Blindaje adicional del contrato SCORE.
    SELECT count(*)
      INTO v_invalid_holes
      FROM jsonb_array_elements(v_universal->'holes') h
     WHERE h->>'officialResultType' IS DISTINCT FROM 'SCORE'
        OR NULLIF(h->>'officialGrossScore','')::integer IS NULL
        OR NULLIF(h->>'officialGrossScore','')::integer<=0;

    IF v_invalid_holes>0 THEN
        RAISE EXCEPTION
            'El resultado oficial A-Go-Go contiene hoyos distintos de SCORE.'
            USING ERRCODE='55000',
                  DETAIL=format('invalid_holes=%s',v_invalid_holes);
    END IF;

    SELECT sum(
        NULLIF(h->>'officialGrossScore','')::integer
    )::integer
      INTO v_gross_total
      FROM jsonb_array_elements(v_universal->'holes') h;

    IF v_gross_total IS NULL OR v_gross_total<=0 THEN
        RAISE EXCEPTION
            'No fue posible calcular el Gross oficial del equipo.'
            USING ERRCODE='55000';
    END IF;

    -- El HCP competitivo usado es el congelado en la TARJETA oficial.
    -- No se consulta ni recalcula desde players.
    v_net_total :=
        v_gross_total - v_snapshot.team_playing_handicap;

    SELECT COALESCE(
        jsonb_agg(
            s.tipo_resultado::text
            ORDER BY s.tipo_resultado::text
        ),
        '[]'::jsonb
    )
      INTO v_classifications
      FROM public.tournament_category_classification_snapshots s
     WHERE s.freeze_id=v_validation.freeze_id
       AND s.tournament_category_id=v_card.tournament_category_id;

    RETURN jsonb_build_object(
        'scoreCard',jsonb_build_object(
            'scoreCardId',v_card.id,
            'cardNumber',v_card.card_number,
            'cardFolio',v_card.card_folio,
            'tournamentId',v_card.tournament_id,
            'tournamentRoundId',v_card.tournament_round_id,
            'tournamentTeamId',v_card.tournament_team_id,
            'teamName',v_snapshot.team_name,
            'tournamentCategoryId',v_card.tournament_category_id,
            'categoryName',v_card.category_name
        ),

        'classification',jsonb_build_object(
            'configuredResultTypes',v_classifications,
            'grossEnabled',v_classifications ? 'gross',
            'netEnabled',v_classifications ? 'neto'
        ),

        'handicap',jsonb_build_object(
            'teamHandicapVersionId',
                v_snapshot.team_handicap_version_id,
            'method',
                v_snapshot.team_handicap_method,
            'teamHandicapUnrounded',
                v_snapshot.team_handicap_unrounded,
            'teamPlayingHandicap',
                v_snapshot.team_playing_handicap,
            'memberCount',
                v_snapshot.member_count,
            'members',
                v_snapshot.members_snapshot
        ),

        'physicalCard',jsonb_build_object(
            'status',v_reception.status,
            'teamSignaturePresent',
                v_reception.player_signature_present,
            'markerSignaturePresent',
                v_reception.marker_signature_present,
            'captureCompletedAt',
                v_reception.capture_completed_at
        ),

        'result',jsonb_build_object(
            'ready',true,
            'holes',v_holes_official,
            'officialGrossTotal',v_gross_total,
            'teamPlayingHandicap',
                v_snapshot.team_playing_handicap,
            'officialNetTotal',v_net_total
        ),

        'holes',COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'roundHoleSnapshotId',
                        NULLIF(h->>'roundHoleSnapshotId','')::uuid,
                    'holeNumber',
                        NULLIF(h->>'holeNumber','')::integer,
                    'playSequence',
                        NULLIF(h->>'playSequence','')::integer,
                    'par',
                        NULLIF(h->>'par','')::integer,
                    'strokeIndex',
                        NULLIF(h->>'strokeIndex','')::integer,
                    'officialResultType',
                        h->>'officialResultType',
                    'officialGrossScore',
                        NULLIF(h->>'officialGrossScore','')::integer,
                    'officialSource',
                        h->>'officialSource'
                )
                ORDER BY
                    NULLIF(h->>'playSequence','')::integer,
                    NULLIF(h->>'holeNumber','')::integer
            )
            FROM jsonb_array_elements(v_universal->'holes') h
        ),'[]'::jsonb)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_resultado_a_gogo_oficial_tarjeta(uuid)
FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.obtener_resultado_a_gogo_oficial_tarjeta(uuid)
TO authenticated,service_role;


-- ----------------------------------------------------------------------------
-- 2. Resultados oficiales de una ronda A-Go-Go
--    No crea leaderboard todavía: devuelve resultados por equipo listos para
--    ser consumidos por Fase 8.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_resultados_a_gogo_oficiales_ronda(
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
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT tr.id,tr.tournament_id,tr.numero_ronda,tr.fecha
      INTO v_round
      FROM public.tournament_rounds tr
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
            'No tienes permiso administrativo para consultar esta ronda.'
            USING ERRCODE='42501';
    END IF;

    SELECT v.id,v.start_format,v.participation_type,v.scoring_engine
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
                sc.id,
                sc.card_number,
                sc.tournament_team_id,
                ss.team_name,
                sc.tournament_category_id,
                g.category_name,
                c.display_order AS category_display_order,
                pr.status AS physical_status,
                pr.player_signature_present,
                pr.marker_signature_present,
                rec.status AS reconciliation_status
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
            WHERE sc.tournament_round_id=p_tournament_round_id
              AND sc.status='issued'
              AND sc.unit_type='team'
        ),
        prepared AS (
            SELECT
                c.*,
                (
                    c.physical_status='CAPTURED'
                    AND c.player_signature_present
                    AND c.marker_signature_present
                    AND c.reconciliation_status='COMPLETED'
                ) AS candidate_ready
            FROM cards c
        ),
        results AS (
            SELECT
                p.*,
                CASE
                    WHEN p.candidate_ready
                    THEN public.obtener_resultado_a_gogo_oficial_tarjeta(p.id)
                    ELSE NULL
                END AS official_result,
                CASE
                    WHEN p.physical_status IS NULL
                        THEN 'PHYSICAL_NOT_RECEIVED'
                    WHEN p.physical_status<>'CAPTURED'
                        THEN 'PHYSICAL_NOT_CAPTURED'
                    WHEN NOT COALESCE(p.player_signature_present,false)
                      OR NOT COALESCE(p.marker_signature_present,false)
                        THEN 'SIGNATURES_MISSING'
                    WHEN p.reconciliation_status IS NULL
                        THEN 'RECONCILIATION_NOT_STARTED'
                    WHEN p.reconciliation_status<>'COMPLETED'
                        THEN 'RECONCILIATION_NOT_COMPLETED'
                    ELSE 'OFFICIAL_READY'
                END AS result_status
            FROM prepared p
        )
        SELECT jsonb_build_object(
            'round',jsonb_build_object(
                'tournamentId',v_round.tournament_id,
                'tournamentRoundId',v_round.id,
                'roundNumber',v_round.numero_ronda,
                'roundDate',v_round.fecha,
                'participationType','equipo',
                'scoringEngine','team_stroke'
            ),
            'summary',jsonb_build_object(
                'totalTeams',count(*),
                'readyTeams',count(*) FILTER(
                    WHERE result_status='OFFICIAL_READY'
                ),
                'pendingTeams',count(*) FILTER(
                    WHERE result_status<>'OFFICIAL_READY'
                )
            ),
            'teams',COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'scoreCardId',r.id,
                        'teamId',r.tournament_team_id,
                        'teamName',r.team_name,
                        'tournamentCategoryId',
                            r.tournament_category_id,
                        'categoryName',r.category_name,
                        'categoryDisplayOrder',
                            r.category_display_order,
                        'resultStatus',r.result_status,
                        'ready',
                            r.result_status='OFFICIAL_READY',
                        'official',
                            r.official_result
                    )
                    ORDER BY
                        r.category_display_order NULLS LAST,
                        r.category_name NULLS LAST,
                        r.card_number,
                        r.team_name
                ),
                '[]'::jsonb
            )
        )
        FROM results r
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_resultados_a_gogo_oficiales_ronda(uuid)
FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.obtener_resultados_a_gogo_oficiales_ronda(uuid)
TO authenticated,service_role;

COMMIT;
