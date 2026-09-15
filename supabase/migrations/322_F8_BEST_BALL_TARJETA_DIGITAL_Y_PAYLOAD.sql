-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 322
-- BEST BALL F8 — TARJETA DIGITAL + PAYLOAD ADMINISTRATIVO
-- ============================================================================
-- OBJETIVO
--   1) Crear contrato digital Best Ball por score_card_id, SIN QR.
--   2) Mostrar integrantes, scores individuales, Best Gross/Net provisional,
--      marcador, "a quién marcamos", permisos de captura/confirmación/disputa.
--   3) Integrar Best Ball al payload administrativo de tarjetas oficiales.
--
-- PRINCIPIOS
--   - No se toca abrir_captura_tarjeta_score(qr): Best Ball NO usa QR.
--   - No se modifica la rama A-Go-Go ni la rama PLAYER del payload histórico.
--   - El cálculo TEAM sigue siendo derivado por F7.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_tarjeta_digital_best_ball_322(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_calc jsonb;
    v_card record;
    v_snapshot record;
    v_session record;
    v_player_id uuid;
    v_is_member boolean:=false;
    v_is_marker boolean:=false;
    v_is_admin boolean:=false;
    v_marker jsonb;
    v_we_mark jsonb;
    v_members jsonb;
    v_holes jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT sc.*,v.scoring_engine,v.participation_type
      INTO v_card
      FROM public.tournament_score_cards sc
      JOIN public.tournament_round_start_validations v ON v.id=sc.validation_id
     WHERE sc.id=p_score_card_id AND sc.status='issued'
     LIMIT 1;

    IF v_card.id IS NULL
       OR v_card.unit_type IS DISTINCT FROM 'team'
       OR v_card.participation_type IS DISTINCT FROM 'equipo'
       OR v_card.scoring_engine IS DISTINCT FROM 'best_ball'
    THEN
        RAISE EXCEPTION 'La tarjeta no corresponde a Best Ball TEAM.'
            USING ERRCODE='22023';
    END IF;

    SELECT * INTO v_snapshot
      FROM public.tournament_best_ball_scorecard_snapshots
     WHERE score_card_id=v_card.id
     LIMIT 1;

    IF v_snapshot.id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta Best Ball no tiene snapshot oficial.'
            USING ERRCODE='55000';
    END IF;

    SELECT * INTO v_session
      FROM public.tournament_scorecard_capture_sessions
     WHERE score_card_id=v_card.id;

    IF v_session.id IS NULL THEN
        RAISE EXCEPTION
            'La captura de esta tarjeta Best Ball no está inicializada.'
            USING ERRCODE='55000';
    END IF;

    v_player_id:=public._scorecard_current_player_id();

    IF v_player_id IS NOT NULL THEN
        SELECT EXISTS(
            SELECT 1
              FROM public.tournament_best_ball_scorecard_members bm
             WHERE bm.best_ball_scorecard_snapshot_id=v_snapshot.id
               AND bm.player_id=v_player_id
        ) INTO v_is_member;

        SELECT EXISTS(
            SELECT 1
              FROM public.tournament_scorecard_marker_assignments ma
             WHERE ma.score_card_id=v_card.id
               AND ma.status='active'
               AND ma.marker_player_id=v_player_id
        ) INTO v_is_marker;
    END IF;

    v_is_admin:=public.puede_administrar_congelamiento_torneo(v_card.tournament_id);

    IF NOT (v_is_member OR v_is_marker OR v_is_admin) THEN
        RAISE EXCEPTION 'No tienes permiso para abrir esta tarjeta Best Ball.'
            USING ERRCODE='42501';
    END IF;

    v_calc:=public.obtener_best_ball_digital_tarjeta_321(v_card.id);

    SELECT jsonb_build_object(
        'assignmentId',ma.id,
        'assignmentSource',ma.assignment_source,
        'validFromSequence',ma.valid_from_sequence,
        'validToSequence',ma.valid_to_sequence,
        'playerId',ma.marker_player_id,
        'playerName',btrim(concat_ws(' ',p.nombres,p.apellidos)),
        'teamId',msc.tournament_team_id,
        'teamName',mss.team_name,
        'scoreCardId',ma.marker_score_card_id,
        'selfMarker',ma.marker_score_card_id=ma.score_card_id
    )
      INTO v_marker
      FROM public.tournament_scorecard_marker_assignments ma
      JOIN public.tournament_score_cards msc ON msc.id=ma.marker_score_card_id
      LEFT JOIN public.tournament_best_ball_scorecard_snapshots mss
        ON mss.score_card_id=ma.marker_score_card_id
      LEFT JOIN public.players p ON p.id=ma.marker_player_id
     WHERE ma.score_card_id=v_card.id
       AND ma.status='active'
     ORDER BY ma.assigned_at DESC,ma.id DESC
     LIMIT 1;

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'assignmentId',ma.id,
            'assignmentSource',ma.assignment_source,
            'validFromSequence',ma.valid_from_sequence,
            'validToSequence',ma.valid_to_sequence,
            'playerId',ma.marker_player_id,
            'playerName',btrim(concat_ws(' ',p.nombres,p.apellidos)),
            'targetScoreCardId',ma.score_card_id,
            'targetTeamId',tsc.tournament_team_id,
            'targetTeamName',tss.team_name,
            'selfMarker',ma.marker_score_card_id=ma.score_card_id
        )
        ORDER BY tsc.card_number,ma.assigned_at,ma.id
    ),'[]'::jsonb)
      INTO v_we_mark
      FROM public.tournament_scorecard_marker_assignments ma
      JOIN public.tournament_score_cards tsc ON tsc.id=ma.score_card_id
      LEFT JOIN public.tournament_best_ball_scorecard_snapshots tss
        ON tss.score_card_id=ma.score_card_id
      LEFT JOIN public.players p ON p.id=ma.marker_player_id
     WHERE ma.marker_score_card_id=v_card.id
       AND ma.status='active';

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'bestBallScorecardMemberId',bm.id,
            'playerId',bm.player_id,
            'tournamentRegistrationId',bm.tournament_registration_id,
            'memberOrder',bm.member_order,
            'name',btrim(concat_ws(' ',p.nombres,p.apellidos)),
            'roundHandicapSnapshotId',bm.round_handicap_snapshot_id,
            'playingHandicap',rhs.playing_handicap,
            'handicapAllowancePct',rhs.handicap_allowance_pct,
            'teeId',rhs.tee_id
        )
        ORDER BY bm.member_order,bm.player_id
    ),'[]'::jsonb)
      INTO v_members
      FROM public.tournament_best_ball_scorecard_members bm
      JOIN public.tournament_round_handicap_snapshots rhs
        ON rhs.id=bm.round_handicap_snapshot_id
      LEFT JOIN public.players p ON p.id=bm.player_id
     WHERE bm.best_ball_scorecard_snapshot_id=v_snapshot.id;

    -- Enriquecer cada miembro/hoyo con permisos efectivos del usuario actual.
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'roundHoleSnapshotId',h->'roundHoleSnapshotId',
            'holeNumber',h->'holeNumber',
            'playSequence',h->'playSequence',
            'par',h->'par',
            'strokeIndex',h->'strokeIndex',
            'state',h->'state',
            'bestGross',h->'bestGross',
            'grossTie',h->'grossTie',
            'grossCountingPlayers',h->'grossCountingPlayers',
            'bestNet',h->'bestNet',
            'netTie',h->'netTie',
            'netCountingPlayers',h->'netCountingPlayers',
            'members',COALESCE((
                SELECT jsonb_agg(
                    m
                    || jsonb_build_object(
                        'canCapture',
                            v_is_marker
                            AND COALESCE(m->>'status','') IN ('pending','entered'),
                        'canConfirm',
                            COALESCE(m->>'status','')='entered'
                            AND public._puede_confirmar_disputar_best_ball_320(
                                NULLIF(m->>'holeScoreId','')::uuid,
                                v_player_id
                            ),
                        'canDispute',
                            COALESCE(m->>'status','')='entered'
                            AND public._puede_confirmar_disputar_best_ball_320(
                                NULLIF(m->>'holeScoreId','')::uuid,
                                v_player_id
                            )
                    )
                    ORDER BY NULLIF(m->>'memberOrder','')::integer,
                             m->>'playerId'
                )
                FROM jsonb_array_elements(COALESCE(h->'members','[]'::jsonb)) m
            ),'[]'::jsonb)
        )
        ORDER BY NULLIF(h->>'playSequence','')::integer,
                 NULLIF(h->>'holeNumber','')::integer
    ),'[]'::jsonb)
      INTO v_holes
      FROM jsonb_array_elements(COALESCE(v_calc->'holes','[]'::jsonb)) h;

    RETURN jsonb_build_object(
        'schemaVersion',1,
        'engine','best_ball',
        'scoreCard',
            (v_calc->'scoreCard')
            || jsonb_build_object(
                'members',v_members,
                'group',jsonb_build_object(
                    'validationGroupId',v_card.validation_group_id,
                    'start',(
                        SELECT jsonb_build_object(
                            'holeNumber',g.hole_number,
                            'position',g.start_position,
                            'startAt',g.start_at,
                            'shiftNumber',g.shift_number,
                            'shiftTime',g.shift_time,
                            'groupLabel',g.group_label
                        )
                        FROM public.tournament_round_start_validation_groups g
                        WHERE g.id=v_card.validation_group_id
                          AND g.validation_id=v_card.validation_id
                    )
                )
            ),
        'access',jsonb_build_object(
            'isTeamMember',v_is_member,
            'isMarker',v_is_marker,
            'isAdmin',v_is_admin,
            'canCapture',v_is_marker
        ),
        'marker',v_marker,
        'weMark',v_we_mark,
        'capture',jsonb_build_object(
            'status',v_session.status,
            'holesExpected',v_session.holes_expected,
            'startedAt',v_session.started_at,
            'capturedAt',v_session.captured_at
        ),
        'calculation',v_calc->'calculation',
        'summary',v_calc->'summary',
        'holes',v_holes
    );
END;
$function$;

-- --------------------------------------------------------------------------
-- Payload administrativo Best Ball. Se crea función propia y el dispatcher
-- público sólo agrega una rama explícita best_ball.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._obtener_payload_tarjetas_best_ball_ronda_322(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_ctx record;
    v_cards jsonb;
    v_holes jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT tournament_id INTO v_tournament_id
      FROM public.tournament_rounds
     WHERE id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.' USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar las tarjetas oficiales de esta ronda.'
            USING ERRCODE='42501';
    END IF;

    SELECT
        e.id emission_id,e.validation_id,e.validation_version,e.card_count,
        e.issued_at,e.issued_by,
        v.round_condition_snapshot_id,v.validator_engine,v.start_format,
        v.participation_type,v.scoring_engine,
        rcs.round_number,rcs.round_date,rcs.course_id,rcs.course_name,
        rcs.course_timezone,rcs.format_code,rcs.format_name,
        rcs.handicap_allowance_pct,rcs.course_par,
        t.nombre tournament_name,t.logo_url tournament_logo_url,t.es_beneficencia
      INTO v_ctx
      FROM public.tournament_score_card_emissions e
      JOIN public.tournament_round_start_validations v
        ON v.id=e.validation_id AND v.tournament_round_id=e.tournament_round_id
      JOIN public.tournament_round_condition_snapshots rcs
        ON rcs.id=v.round_condition_snapshot_id
      JOIN public.tournaments t ON t.id=e.tournament_id
     WHERE e.tournament_round_id=p_tournament_round_id
       AND e.status='issued'
       AND v.participation_type='equipo'
       AND v.scoring_engine='best_ball'
     LIMIT 1;

    IF v_ctx.emission_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda no tiene una emisión oficial Best Ball.'
            USING ERRCODE='23514';
    END IF;

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'hoyoId',h.source_hole_id,
            'numero',h.hole_number,
            'par',h.par,
            'strokeIndex',h.stroke_index
        ) ORDER BY h.hole_number
    ),'[]'::jsonb)
      INTO v_holes
      FROM public.tournament_round_hole_snapshots h
     WHERE h.round_condition_snapshot_id=v_ctx.round_condition_snapshot_id;

    SELECT COALESCE(jsonb_agg(card ORDER BY card_number),'[]'::jsonb)
      INTO v_cards
      FROM (
        SELECT
            sc.card_number,
            jsonb_build_object(
                'scoreCardId',sc.id,
                'cardNumber',sc.card_number,
                'cardFolio',sc.card_folio,
                'status',sc.status,
                'issuedAt',sc.issued_at,
                'captureInitialized',cs.id IS NOT NULL,
                'unit',jsonb_build_object('kind','team'),
                'team',jsonb_build_object(
                    'id',sc.tournament_team_id,
                    'name',ss.team_name,
                    'nombre',ss.team_name,
                    'members',COALESCE((
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'bestBallScorecardMemberId',bm.id,
                                'registrationId',bm.tournament_registration_id,
                                'playerId',bm.player_id,
                                'name',btrim(concat_ws(' ',p.nombres,p.apellidos)),
                                'memberOrder',bm.member_order,
                                'playingHandicap',rhs.playing_handicap,
                                'handicapAllowancePct',rhs.handicap_allowance_pct,
                                'teeId',rhs.tee_id
                            )
                            ORDER BY bm.member_order,bm.player_id
                        )
                        FROM public.tournament_best_ball_scorecard_members bm
                        JOIN public.tournament_round_handicap_snapshots rhs
                          ON rhs.id=bm.round_handicap_snapshot_id
                        LEFT JOIN public.players p ON p.id=bm.player_id
                        WHERE bm.best_ball_scorecard_snapshot_id=ss.id
                    ),'[]'::jsonb)
                ),
                'category',jsonb_build_object(
                    'tournamentCategoryId',sc.tournament_category_id,
                    'name',g.category_name,
                    'nombre',g.category_name
                ),
                'handicap',jsonb_build_object(
                    'kind','individual_members',
                    'allowancePct',v_ctx.handicap_allowance_pct
                ),
                'start',jsonb_build_object(
                    'validationGroupId',sc.validation_group_id,
                    'holeNumber',g.hole_number,
                    'position',g.start_position,
                    'startAt',g.start_at,
                    'shiftNumber',g.shift_number,
                    'shiftTime',g.shift_time,
                    'groupLabel',g.group_label,
                    'orderInGroup',u.order_in_group,
                    'numeroHoyo',g.hole_number,
                    'posicion',g.start_position,
                    'hora',g.start_at,
                    'horaLocalTexto',CASE WHEN g.start_at IS NULL THEN NULL
                        ELSE to_char(g.start_at AT TIME ZONE v_ctx.course_timezone,'HH24:MI') END,
                    'numeroTurno',g.shift_number,
                    'horaTurno',g.shift_time,
                    'etiqueta',g.group_label,
                    'ordenEnGrupo',u.order_in_group
                ),
                'marker',(
                    SELECT jsonb_build_object(
                        'assignmentId',ma.id,
                        'assignmentSource',ma.assignment_source,
                        'validFromSequence',ma.valid_from_sequence,
                        'playerId',ma.marker_player_id,
                        'playerName',btrim(concat_ws(' ',mp.nombres,mp.apellidos)),
                        'teamId',msc.tournament_team_id,
                        'teamName',mss.team_name,
                        'scoreCardId',ma.marker_score_card_id,
                        'selfMarker',ma.marker_score_card_id=ma.score_card_id
                    )
                    FROM public.tournament_scorecard_marker_assignments ma
                    JOIN public.tournament_score_cards msc ON msc.id=ma.marker_score_card_id
                    LEFT JOIN public.tournament_best_ball_scorecard_snapshots mss
                      ON mss.score_card_id=ma.marker_score_card_id
                    LEFT JOIN public.players mp ON mp.id=ma.marker_player_id
                    WHERE ma.score_card_id=sc.id AND ma.status='active'
                    ORDER BY ma.assigned_at DESC,ma.id DESC LIMIT 1
                ),
                'weMark',COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        'assignmentId',ma.id,
                        'playerId',ma.marker_player_id,
                        'playerName',btrim(concat_ws(' ',mp.nombres,mp.apellidos)),
                        'targetScoreCardId',ma.score_card_id,
                        'targetTeamId',tsc.tournament_team_id,
                        'targetTeamName',tss.team_name,
                        'selfMarker',ma.marker_score_card_id=ma.score_card_id
                    ) ORDER BY tsc.card_number)
                    FROM public.tournament_scorecard_marker_assignments ma
                    JOIN public.tournament_score_cards tsc ON tsc.id=ma.score_card_id
                    LEFT JOIN public.tournament_best_ball_scorecard_snapshots tss
                      ON tss.score_card_id=ma.score_card_id
                    LEFT JOIN public.players mp ON mp.id=ma.marker_player_id
                    WHERE ma.marker_score_card_id=sc.id AND ma.status='active'
                ),'[]'::jsonb),
                'holes',v_holes,
                'totals',jsonb_build_object(
                    'parOut',(SELECT sum(h.par) FROM public.tournament_round_hole_snapshots h
                              WHERE h.round_condition_snapshot_id=v_ctx.round_condition_snapshot_id
                                AND h.hole_number BETWEEN 1 AND 9),
                    'parIn',(SELECT sum(h.par) FROM public.tournament_round_hole_snapshots h
                             WHERE h.round_condition_snapshot_id=v_ctx.round_condition_snapshot_id
                               AND h.hole_number BETWEEN 10 AND 18),
                    'parTotal',v_ctx.course_par
                )
            ) AS card
        FROM public.tournament_score_cards sc
        JOIN public.tournament_round_start_validation_units u
          ON u.id=sc.validation_unit_id AND u.validation_id=sc.validation_id
        JOIN public.tournament_round_start_validation_groups g
          ON g.id=sc.validation_group_id AND g.validation_id=sc.validation_id
        JOIN public.tournament_best_ball_scorecard_snapshots ss
          ON ss.score_card_id=sc.id
        LEFT JOIN public.tournament_scorecard_capture_sessions cs
          ON cs.score_card_id=sc.id
        WHERE sc.emission_id=v_ctx.emission_id
          AND sc.status='issued'
          AND sc.unit_type='team'
      ) q;

    IF jsonb_array_length(v_cards)<>v_ctx.card_count THEN
        RAISE EXCEPTION
            'La emisión Best Ball no contiene el número esperado de tarjetas.'
            USING ERRCODE='55000';
    END IF;

    RETURN jsonb_build_object(
        'schemaVersion',4,
        'tournament',jsonb_build_object(
            'id',v_tournament_id,'nombre',v_ctx.tournament_name,
            'logoUrl',v_ctx.tournament_logo_url,'esBeneficencia',v_ctx.es_beneficencia
        ),
        'course',jsonb_build_object(
            'id',v_ctx.course_id,'nombreOficial',v_ctx.course_name,
            'timezone',v_ctx.course_timezone,'par',v_ctx.course_par
        ),
        'round',jsonb_build_object(
            'id',p_tournament_round_id,'numeroRonda',v_ctx.round_number,
            'fecha',v_ctx.round_date,'formatoSalida',v_ctx.start_format
        ),
        'format',jsonb_build_object(
            'code',v_ctx.format_code,'name',v_ctx.format_name,
            'participationType',v_ctx.participation_type,
            'scoringEngine',v_ctx.scoring_engine,
            'validatorEngine',v_ctx.validator_engine
        ),
        'emission',jsonb_build_object(
            'id',v_ctx.emission_id,'validationId',v_ctx.validation_id,
            'validationVersion',v_ctx.validation_version,
            'cardCount',v_ctx.card_count,'issuedAt',v_ctx.issued_at,
            'issuedBy',v_ctx.issued_by
        ),
        'holes',v_holes,
        'cards',v_cards,
        'counts',jsonb_build_object(
            'cards',jsonb_array_length(v_cards),
            'holes',jsonb_array_length(v_holes)
        )
    );
END;
$function$;

-- Dispatcher administrativo: Best Ball toma su función propia.
CREATE OR REPLACE FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_engine text;
    v_participation text;
    v_payload jsonb;
BEGIN
    SELECT v.scoring_engine,v.participation_type
      INTO v_engine,v_participation
      FROM public.tournament_score_card_emissions e
      JOIN public.tournament_round_start_validations v
        ON v.id=e.validation_id AND v.tournament_round_id=e.tournament_round_id
     WHERE e.tournament_round_id=p_tournament_round_id
       AND e.status='issued'
     LIMIT 1;

    IF v_engine='best_ball' AND v_participation='equipo' THEN
        v_payload:=public._obtener_payload_tarjetas_best_ball_ronda_322(
            p_tournament_round_id
        );
        RETURN public._aplicar_fecha_operativa_payload_ronda_314(
            p_tournament_round_id,v_payload
        );
    END IF;

    -- Stroke / Stableford / A-Go-Go conservan exactamente el contrato previo.
    v_payload:=public._obtener_payload_tarjetas_score_oficiales_ronda_pre314(
        p_tournament_round_id
    );

    RETURN public._aplicar_fecha_operativa_payload_ronda_314(
        p_tournament_round_id,v_payload
    );
END;
$function$;

COMMIT;
