BEGIN;

-- 343 · Best Ball: previsualización correcta de tarjetas TEAM antes de emitir.

CREATE OR REPLACE FUNCTION public.previsualizar_tarjetas_best_ball_ronda_343(
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
    v_validation public.tournament_round_start_validations%ROWTYPE;
    v_capability jsonb;
    v_ctx record;
    v_bad_units integer;
    v_already_issued boolean;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id es obligatorio.' USING ERRCODE='22023';
    END IF;

    SELECT tr.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.' USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para previsualizar tarjetas.' USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_validation
      FROM public.tournament_round_start_validations
     WHERE tournament_round_id=p_tournament_round_id
       AND status='validated'
     ORDER BY version DESC
     LIMIT 1;

    IF v_validation.id IS NULL THEN
        RAISE EXCEPTION 'Las salidas deben estar validadas antes de previsualizar tarjetas.' USING ERRCODE='23514';
    END IF;

    IF v_validation.start_format IS DISTINCT FROM 'shotgun'
       OR v_validation.participation_type IS DISTINCT FROM 'equipo'
       OR v_validation.scoring_engine IS DISTINCT FROM 'best_ball'
       OR v_validation.validator_engine IS DISTINCT FROM 'best_ball_team_shotgun_v1'
    THEN
        RAISE EXCEPTION 'Esta previsualización corresponde únicamente a Best Ball Shotgun TEAM.' USING ERRCODE='0A000';
    END IF;

    v_capability:=public._resolver_capacidad_emision_tarjetas_ronda(p_tournament_round_id);

    IF NOT COALESCE((v_capability->>'supported')::boolean,false)
       OR v_capability->>'unitType' IS DISTINCT FROM 'team'
       OR v_capability->>'scorecardEmissionEngine' IS DISTINCT FROM 'official_scorecard_best_ball_team_v1'
    THEN
        RAISE EXCEPTION 'El motor Best Ball validado no tiene emisión TEAM habilitada.'
            USING ERRCODE='0A000', DETAIL=v_capability::text;
    END IF;

    IF (v_capability->>'validationId')::uuid IS DISTINCT FROM v_validation.id THEN
        RAISE EXCEPTION 'La capacidad de emisión no corresponde a la validación activa.' USING ERRCODE='55000';
    END IF;

    SELECT public._contar_unidades_invalidas_emision_tarjetas(v_validation.id,'team')
      INTO v_bad_units;

    IF v_bad_units>0 THEN
        RAISE EXCEPTION 'La validación contiene unidades incompatibles con tarjeta TEAM.'
            USING ERRCODE='0A000', DETAIL=format('unidades_no_soportadas=%s',v_bad_units);
    END IF;

    -- La composición que se imprimirá debe seguir siendo válida.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_round_start_validation_units u
        LEFT JOIN LATERAL (
            SELECT count(*)::integer n
            FROM public.tournament_registrations reg
            WHERE reg.tournament_id=v_tournament_id
              AND reg.tournament_team_id=u.tournament_team_id
              AND reg.activo=true
        ) x ON true
        WHERE u.validation_id=v_validation.id
          AND u.unit_type='team'
          AND x.n NOT BETWEEN 2 AND 5
    ) THEN
        RAISE EXCEPTION 'Uno o más equipos Best Ball ya no tienen entre 2 y 5 integrantes activos. Revalida antes de emitir.'
            USING ERRCODE='23514';
    END IF;

    -- Todos los integrantes deben conservar su HCP individual congelado de esta ronda.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_round_start_validation_units u
        JOIN public.tournament_registrations reg
          ON reg.tournament_id=v_tournament_id
         AND reg.tournament_team_id=u.tournament_team_id
         AND reg.activo=true
        LEFT JOIN public.tournament_round_handicap_snapshots rhs
          ON rhs.round_condition_snapshot_id=v_validation.round_condition_snapshot_id
         AND rhs.tournament_round_id=p_tournament_round_id
         AND rhs.tournament_registration_id=reg.id
         AND rhs.player_id=reg.player_id
        WHERE u.validation_id=v_validation.id
          AND u.unit_type='team'
          AND rhs.id IS NULL
    ) THEN
        RAISE EXCEPTION 'Falta HCP individual congelado de uno o más integrantes Best Ball.' USING ERRCODE='23514';
    END IF;

    SELECT
        rcs.round_number,
        rcs.round_date,
        rcs.course_id,
        rcs.course_name,
        rcs.course_timezone,
        rcs.course_par,
        rcs.format_code,
        rcs.format_name,
        t.nombre tournament_name,
        t.logo_url tournament_logo_url,
        t.es_beneficencia
      INTO v_ctx
      FROM public.tournament_round_condition_snapshots rcs
      JOIN public.tournaments t ON t.id=rcs.tournament_id
     WHERE rcs.id=v_validation.round_condition_snapshot_id
       AND rcs.tournament_round_id=p_tournament_round_id;

    IF v_ctx.round_number IS NULL THEN
        RAISE EXCEPTION 'No existe snapshot congelado de condiciones para la validación Best Ball.' USING ERRCODE='55000';
    END IF;

    SELECT public._ronda_tiene_tarjetas_emitidas(p_tournament_round_id)
      INTO v_already_issued;

    RETURN (
      WITH card_base AS (
        SELECT
          u.id validation_unit_id,
          u.tournament_team_id,
          u.tournament_category_id,
          COALESCE(u.unit_name,tt.nombre_equipo) team_name,
          g.id validation_group_id,
          g.category_name,
          g.hole_number,
          g.start_position,
          g.start_at,
          g.shift_number,
          g.shift_time,
          g.group_label,
          g.source_format_metadata,
          u.order_in_group,
          row_number() OVER(
            ORDER BY g.shift_number,g.hole_number,g.start_position,u.order_in_group,u.id
          )::integer card_number
        FROM public.tournament_round_start_validation_units u
        JOIN public.tournament_round_start_validation_groups g
          ON g.id=u.validation_group_id AND g.validation_id=u.validation_id
        JOIN public.tournament_teams tt
          ON tt.id=u.tournament_team_id AND tt.tournament_id=v_tournament_id
        WHERE u.validation_id=v_validation.id
          AND u.unit_type='team'
      ),
      member_rows AS (
        SELECT
          cb.validation_unit_id,
          reg.id registration_id,
          reg.player_id,
          concat_ws(' ',p.nombres,p.apellidos) player_name,
          rhs.tee_id,
          rhs.course_handicap,
          rhs.playing_handicap,
          hs.handicap_index,
          ms.nombre tee_name,
          ms.color_hex tee_color_hex,
          row_number() OVER(
            PARTITION BY cb.validation_unit_id
            ORDER BY CASE WHEN reg.player_id=tt.captain_player_id THEN 0 ELSE 1 END,
                     p.apellidos,p.nombres,reg.id
          ) member_order
        FROM card_base cb
        JOIN public.tournament_teams tt ON tt.id=cb.tournament_team_id
        JOIN public.tournament_registrations reg
          ON reg.tournament_id=v_tournament_id
         AND reg.tournament_team_id=cb.tournament_team_id
         AND reg.activo=true
        JOIN public.players p ON p.id=reg.player_id AND p.activo=true
        JOIN public.tournament_round_handicap_snapshots rhs
          ON rhs.round_condition_snapshot_id=v_validation.round_condition_snapshot_id
         AND rhs.tournament_round_id=p_tournament_round_id
         AND rhs.tournament_registration_id=reg.id
         AND rhs.player_id=reg.player_id
        LEFT JOIN public.tournament_handicap_snapshots hs ON hs.id=rhs.handicap_snapshot_id
        LEFT JOIN public.marcas_salida ms ON ms.id=rhs.tee_id
      ),
      members_json AS (
        SELECT validation_unit_id,
          jsonb_agg(jsonb_build_object(
            'registrationId',registration_id,
            'playerId',player_id,
            'name',player_name,
            'nombre',player_name,
            'nombreCompleto',player_name,
            'handicapIndex',handicap_index,
            'courseHandicap',course_handicap,
            'playingHandicap',playing_handicap,
            'teeId',tee_id,
            'teeName',tee_name,
            'teeNombre',tee_name,
            'teeColorHex',tee_color_hex
          ) ORDER BY member_order) members
        FROM member_rows
        GROUP BY validation_unit_id
      ),
      cards_json AS (
        SELECT COALESCE(jsonb_agg(
          jsonb_build_object(
            'prospectiveCardNumber',cb.card_number,
            'prospectiveCardFolio','R'||lpad(v_ctx.round_number::text,2,'0')||'-V'||lpad(v_validation.version::text,2,'0')||'-'||lpad(cb.card_number::text,4,'0'),
            'officiallyIssued',false,
            'validationUnitId',cb.validation_unit_id,
            'registrationId',NULL,
            'registrationFolio',NULL,
            'unit',jsonb_build_object('kind','team'),
            'player',NULL,
            'team',jsonb_build_object(
              'id',cb.tournament_team_id,
              'name',cb.team_name,
              'nombre',cb.team_name,
              'members',COALESCE(mj.members,'[]'::jsonb)
            ),
            'category',jsonb_build_object(
              'tournamentCategoryId',cb.tournament_category_id,
              'name',cb.category_name,
              'nombre',cb.category_name
            ),
            -- Best Ball no tiene HCP TEAM. Se conserva el campo común vacío.
            'handicap',jsonb_build_object(
              'kind','individual_members',
              'valor',NULL,
              'origen',NULL,
              'estatus',NULL,
              'courseHandicap',NULL,
              'playingHandicap',NULL,
              'allowancePct',NULL
            ),
            'teamHandicap',NULL,
            'tee',NULL,
            'start',jsonb_build_object(
              'validationGroupId',cb.validation_group_id,
              'holeNumber',cb.hole_number,
              'position',cb.start_position,
              'startAt',cb.start_at,
              'shiftNumber',cb.shift_number,
              'shiftTime',cb.shift_time,
              'groupLabel',cb.group_label,
              'orderInGroup',cb.order_in_group,
              'numeroHoyo',cb.hole_number,
              'posicion',cb.start_position,
              'hora',cb.start_at,
              'horaLocalTexto',CASE WHEN cb.start_at IS NULL THEN NULL ELSE to_char(cb.start_at AT TIME ZONE v_ctx.course_timezone,'HH24:MI') END,
              'numeroTurno',cb.shift_number,
              'horaTurno',cb.shift_time,
              'etiqueta',cb.group_label,
              'ordenEnGrupo',cb.order_in_group,
              'formatMetadata',cb.source_format_metadata,
              'companeros','[]'::jsonb
            ),
            'holes',(
              SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'hoyoId',h.source_hole_id,
                'numero',h.hole_number,
                'par',h.par,
                'strokeIndex',h.stroke_index,
                'distancia',NULL,
                'distanciasPorTee',COALESCE((
                  SELECT jsonb_agg(DISTINCT jsonb_build_object(
                    'teeId',mr.tee_id,
                    'nombre',mr.tee_name,
                    'teeName',mr.tee_name,
                    'distancia',CASE WHEN h.tee_distances_yards ? mr.tee_id::text THEN (h.tee_distances_yards->>mr.tee_id::text)::integer ELSE NULL END
                  ))
                  FROM member_rows mr
                  WHERE mr.validation_unit_id=cb.validation_unit_id AND mr.tee_id IS NOT NULL
                ),'[]'::jsonb)
              ) ORDER BY h.hole_number),'[]'::jsonb)
              FROM public.tournament_round_hole_snapshots h
              WHERE h.round_condition_snapshot_id=v_validation.round_condition_snapshot_id
                AND h.tournament_round_id=p_tournament_round_id
            ),
            'totals',jsonb_build_object(
              'parOut',(SELECT sum(h.par) FROM public.tournament_round_hole_snapshots h WHERE h.round_condition_snapshot_id=v_validation.round_condition_snapshot_id AND h.hole_number BETWEEN 1 AND 9),
              'parIn',(SELECT sum(h.par) FROM public.tournament_round_hole_snapshots h WHERE h.round_condition_snapshot_id=v_validation.round_condition_snapshot_id AND h.hole_number BETWEEN 10 AND 18),
              'parTotal',(SELECT sum(h.par) FROM public.tournament_round_hole_snapshots h WHERE h.round_condition_snapshot_id=v_validation.round_condition_snapshot_id),
              'yardsOut',NULL,'yardsIn',NULL,'yardsTotal',NULL
            )
          ) ORDER BY cb.card_number
        ),'[]'::jsonb) cards
        FROM card_base cb
        LEFT JOIN members_json mj ON mj.validation_unit_id=cb.validation_unit_id
      )
      SELECT jsonb_build_object(
        'schemaVersion',2,
        'preview',true,
        'officiallyIssued',COALESCE(v_already_issued,false),
        'emissionCapability',v_capability,
        'validation',jsonb_build_object(
          'id',v_validation.id,
          'version',v_validation.version,
          'validatedAt',v_validation.validated_at,
          'validatorEngine',v_validation.validator_engine,
          'startFormat',v_validation.start_format,
          'participationType',v_validation.participation_type,
          'scoringEngine',v_validation.scoring_engine,
          'startContractVersion',v_validation.start_contract_version,
          'expectedCardCount',v_validation.unit_count
        ),
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
          'fecha',v_ctx.round_date,'formatoSalida',v_validation.start_format
        ),
        'format',jsonb_build_object(
          'code',v_ctx.format_code,'name',v_ctx.format_name,
          'participationType',v_validation.participation_type,
          'scoringEngine',v_validation.scoring_engine,
          'validatorEngine',v_validation.validator_engine
        ),
        'cards',cj.cards,
        'counts',jsonb_build_object(
          'cards',jsonb_array_length(cj.cards),
          'expectedCards',v_validation.unit_count,
          'holes',(SELECT count(*) FROM public.tournament_round_hole_snapshots h WHERE h.round_condition_snapshot_id=v_validation.round_condition_snapshot_id)
        )
      )
      FROM cards_json cj
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.previsualizar_tarjetas_best_ball_ronda_343(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.previsualizar_tarjetas_best_ball_ronda_343(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.previsualizar_tarjetas_best_ball_ronda_343(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.previsualizar_tarjetas_best_ball_ronda_343(uuid) TO service_role;

-- Dispatcher común: Best Ball deja de caer en el preview específico A-Go-Go.
CREATE OR REPLACE FUNCTION public.previsualizar_tarjetas_score_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_capability jsonb;
    v_emission_engine text;
    v_payload jsonb;
BEGIN
    v_capability:=public._resolver_capacidad_emision_tarjetas_ronda(p_tournament_round_id);

    IF COALESCE((v_capability->>'supported')::boolean,false) THEN
        v_emission_engine:=v_capability->>'scorecardEmissionEngine';

        IF v_emission_engine='official_scorecard_best_ball_team_v1'
           AND v_capability->>'unitType'='team'
        THEN
            v_payload:=public.previsualizar_tarjetas_best_ball_ronda_343(p_tournament_round_id);
        ELSIF v_emission_engine='official_scorecard_team_v1'
              AND v_capability->>'unitType'='team'
        THEN
            v_payload:=public.previsualizar_tarjetas_equipo_a_gogo_ronda(p_tournament_round_id);
        ELSE
            v_payload:=public._previsualizar_tarjetas_score_ronda_individual_208(p_tournament_round_id);
        END IF;
    ELSE
        v_payload:=public._previsualizar_tarjetas_score_ronda_individual_208(p_tournament_round_id);
    END IF;

    RETURN public._aplicar_fecha_operativa_payload_ronda_314(
        p_tournament_round_id,
        v_payload
    );
END;
$function$;

COMMIT;
