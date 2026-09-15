-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 318
-- BEST BALL F4 — CAPTURA DIGITAL: TABLA AISLADA + INICIALIZACION ATOMICA
-- ============================================================================
-- OBJETIVO
--   1) Crear la tabla digital propia de Best Ball con identidad:
--        score_card_id + best_ball_scorecard_member_id + round_hole_snapshot_id
--   2) Reutilizar tournament_scorecard_capture_sessions (1 por tarjeta TEAM).
--   3) Inicializar una fila PENDING por integrante x hoyo.
--   4) Agregar rama best_ball al dispatcher inicializar_captura_scores_ronda().
--   5) Hacer atómica la emisión Best Ball + inicialización de captura.
--
-- NO HACE
--   - No toca tournament_scorecard_hole_scores.
--   - No crea marcadores (F5).
--   - No habilita RPCs de captura SCORE/PICKUP (F6).
--   - No calcula Best Ball Gross/Neto (F7).
--   - No modifica funciones internas Stroke/Stableford/A-Go-Go.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1. TABLA DIGITAL PROPIA BEST BALL
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_best_ball_hole_scores (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    capture_session_id uuid NOT NULL
        REFERENCES public.tournament_scorecard_capture_sessions(id)
        ON DELETE RESTRICT,

    score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id)
        ON DELETE RESTRICT,

    best_ball_scorecard_member_id uuid NOT NULL
        REFERENCES public.tournament_best_ball_scorecard_members(id)
        ON DELETE RESTRICT,

    player_id uuid NOT NULL
        REFERENCES public.players(id)
        ON DELETE RESTRICT,

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id)
        ON DELETE RESTRICT,

    round_hole_snapshot_id uuid NOT NULL
        REFERENCES public.tournament_round_hole_snapshots(id)
        ON DELETE RESTRICT,

    hole_number integer NOT NULL,
    play_sequence integer NOT NULL,

    gross_score integer NULL,

    status text NOT NULL DEFAULT 'pending',
    result_type text NOT NULL DEFAULT 'PENDING',

    -- Se usarán desde F5/F6. En F4 permanecen NULL.
    marker_assignment_id uuid NULL
        REFERENCES public.tournament_scorecard_marker_assignments(id)
        ON DELETE RESTRICT,

    entered_by_player_id uuid NULL
        REFERENCES public.players(id)
        ON DELETE RESTRICT,
    entered_at timestamptz NULL,

    confirmed_by_player_id uuid NULL
        REFERENCES public.players(id)
        ON DELETE RESTRICT,
    confirmed_at timestamptz NULL,

    player_claimed_result_type text NULL,
    player_claimed_gross_score integer NULL,
    dispute_note text NULL,
    disputed_at timestamptz NULL,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_best_ball_hole_scores_hole_number_ck
        CHECK (hole_number > 0),

    CONSTRAINT tournament_best_ball_hole_scores_play_sequence_ck
        CHECK (play_sequence > 0),

    CONSTRAINT tournament_best_ball_hole_scores_gross_score_ck
        CHECK (gross_score IS NULL OR gross_score > 0),

    CONSTRAINT tournament_best_ball_hole_scores_claimed_gross_ck
        CHECK (
            player_claimed_gross_score IS NULL
            OR player_claimed_gross_score > 0
        ),

    CONSTRAINT tournament_best_ball_hole_scores_result_type_ck
        CHECK (result_type IN ('PENDING','SCORE','PICKUP')),

    CONSTRAINT tournament_best_ball_hole_scores_status_ck
        CHECK (status IN ('pending','entered','confirmed','disputed')),

    CONSTRAINT tournament_best_ball_hole_scores_claimed_result_type_ck
        CHECK (
            player_claimed_result_type IS NULL
            OR player_claimed_result_type IN ('SCORE','PICKUP')
        ),

    -- En F4 sólo se materializan filas PENDING.
    -- El mismo contrato de estados queda listo para F6.
    CONSTRAINT tournament_best_ball_hole_scores_state_ck
        CHECK (
            (
                status='pending'
                AND result_type='PENDING'
                AND gross_score IS NULL
                AND marker_assignment_id IS NULL
                AND entered_by_player_id IS NULL
                AND entered_at IS NULL
                AND confirmed_by_player_id IS NULL
                AND confirmed_at IS NULL
                AND player_claimed_result_type IS NULL
                AND player_claimed_gross_score IS NULL
                AND dispute_note IS NULL
                AND disputed_at IS NULL
            )
            OR
            (
                status='entered'
                AND result_type IN ('SCORE','PICKUP')
                AND (
                    (result_type='SCORE' AND gross_score IS NOT NULL)
                    OR
                    (result_type='PICKUP' AND gross_score IS NULL)
                )
                AND marker_assignment_id IS NOT NULL
                AND entered_by_player_id IS NOT NULL
                AND entered_at IS NOT NULL
                AND confirmed_by_player_id IS NULL
                AND confirmed_at IS NULL
                AND player_claimed_result_type IS NULL
                AND player_claimed_gross_score IS NULL
                AND dispute_note IS NULL
                AND disputed_at IS NULL
            )
            OR
            (
                status='confirmed'
                AND result_type IN ('SCORE','PICKUP')
                AND (
                    (result_type='SCORE' AND gross_score IS NOT NULL)
                    OR
                    (result_type='PICKUP' AND gross_score IS NULL)
                )
                AND marker_assignment_id IS NOT NULL
                AND entered_by_player_id IS NOT NULL
                AND entered_at IS NOT NULL
                AND confirmed_by_player_id IS NOT NULL
                AND confirmed_at IS NOT NULL
                AND player_claimed_result_type IS NULL
                AND player_claimed_gross_score IS NULL
                AND dispute_note IS NULL
                AND disputed_at IS NULL
            )
            OR
            (
                status='disputed'
                AND result_type IN ('SCORE','PICKUP')
                AND (
                    (result_type='SCORE' AND gross_score IS NOT NULL)
                    OR
                    (result_type='PICKUP' AND gross_score IS NULL)
                )
                AND marker_assignment_id IS NOT NULL
                AND entered_by_player_id IS NOT NULL
                AND entered_at IS NOT NULL
                AND confirmed_by_player_id IS NULL
                AND confirmed_at IS NULL
                AND player_claimed_result_type IN ('SCORE','PICKUP')
                AND (
                    (
                        player_claimed_result_type='SCORE'
                        AND player_claimed_gross_score IS NOT NULL
                    )
                    OR
                    (
                        player_claimed_result_type='PICKUP'
                        AND player_claimed_gross_score IS NULL
                    )
                )
                AND (
                    player_claimed_result_type IS DISTINCT FROM result_type
                    OR player_claimed_gross_score IS DISTINCT FROM gross_score
                )
                AND disputed_at IS NOT NULL
            )
        ),

    CONSTRAINT tournament_best_ball_hole_scores_card_member_hole_uk
        UNIQUE (
            score_card_id,
            best_ball_scorecard_member_id,
            round_hole_snapshot_id
        ),

    CONSTRAINT tournament_best_ball_hole_scores_card_member_sequence_uk
        UNIQUE (
            score_card_id,
            best_ball_scorecard_member_id,
            play_sequence
        )
);

CREATE INDEX IF NOT EXISTS
    ix_tournament_best_ball_hole_scores_session
ON public.tournament_best_ball_hole_scores(capture_session_id);

CREATE INDEX IF NOT EXISTS
    ix_tournament_best_ball_hole_scores_card
ON public.tournament_best_ball_hole_scores(score_card_id);

CREATE INDEX IF NOT EXISTS
    ix_tournament_best_ball_hole_scores_player
ON public.tournament_best_ball_hole_scores(player_id);

CREATE INDEX IF NOT EXISTS
    ix_tournament_best_ball_hole_scores_round
ON public.tournament_best_ball_hole_scores(tournament_round_id);

CREATE INDEX IF NOT EXISTS
    ix_tournament_best_ball_hole_scores_hole
ON public.tournament_best_ball_hole_scores(round_hole_snapshot_id);

ALTER TABLE public.tournament_best_ball_hole_scores ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_best_ball_hole_scores
FROM anon, authenticated;

-- --------------------------------------------------------------------------
-- 2. VALIDADOR DE INTEGRIDAD DE FILA BEST BALL
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._validar_best_ball_hole_score_318()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_ctx record;
BEGIN
    SELECT
        cs.score_card_id AS session_score_card_id,
        cs.tournament_round_id AS session_round_id,
        cs.validation_id AS session_validation_id,

        sc.tournament_round_id AS card_round_id,
        sc.validation_id AS card_validation_id,
        sc.unit_type AS card_unit_type,
        sc.tournament_team_id,

        v.participation_type,
        v.scoring_engine,

        ss.id AS best_ball_snapshot_id,
        ss.tournament_round_id AS snapshot_round_id,
        ss.tournament_team_id AS snapshot_team_id,

        m.id AS member_id,
        m.player_id AS member_player_id,

        h.tournament_round_id AS hole_round_id
    INTO v_ctx
    FROM public.tournament_scorecard_capture_sessions cs
    JOIN public.tournament_score_cards sc
      ON sc.id=NEW.score_card_id
    JOIN public.tournament_round_start_validations v
      ON v.id=sc.validation_id
    JOIN public.tournament_best_ball_scorecard_snapshots ss
      ON ss.score_card_id=sc.id
    JOIN public.tournament_best_ball_scorecard_members m
      ON m.id=NEW.best_ball_scorecard_member_id
     AND m.best_ball_scorecard_snapshot_id=ss.id
    JOIN public.tournament_round_hole_snapshots h
      ON h.id=NEW.round_hole_snapshot_id
    WHERE cs.id=NEW.capture_session_id
    LIMIT 1;

    IF v_ctx.session_score_card_id IS NULL THEN
        RAISE EXCEPTION
            'La fila Best Ball no tiene un contexto de captura válido.'
            USING ERRCODE='23514';
    END IF;

    IF v_ctx.session_score_card_id IS DISTINCT FROM NEW.score_card_id
       OR v_ctx.session_round_id IS DISTINCT FROM NEW.tournament_round_id
       OR v_ctx.session_validation_id IS DISTINCT FROM v_ctx.card_validation_id
       OR v_ctx.card_round_id IS DISTINCT FROM NEW.tournament_round_id
       OR v_ctx.snapshot_round_id IS DISTINCT FROM NEW.tournament_round_id
       OR v_ctx.hole_round_id IS DISTINCT FROM NEW.tournament_round_id
    THEN
        RAISE EXCEPTION
            'Tarjeta, sesión, snapshot o hoyo no pertenecen a la misma ronda Best Ball.'
            USING ERRCODE='23514';
    END IF;

    IF v_ctx.card_unit_type IS DISTINCT FROM 'team'
       OR v_ctx.participation_type IS DISTINCT FROM 'equipo'
       OR v_ctx.scoring_engine IS DISTINCT FROM 'best_ball'
       OR v_ctx.tournament_team_id IS DISTINCT FROM v_ctx.snapshot_team_id
    THEN
        RAISE EXCEPTION
            'La fila sólo puede pertenecer a una tarjeta TEAM del motor best_ball.'
            USING ERRCODE='23514';
    END IF;

    IF v_ctx.member_id IS DISTINCT FROM NEW.best_ball_scorecard_member_id
       OR v_ctx.member_player_id IS DISTINCT FROM NEW.player_id
    THEN
        RAISE EXCEPTION
            'El jugador no corresponde al integrante congelado de la tarjeta Best Ball.'
            USING ERRCODE='23514';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_validar_best_ball_hole_score_318
ON public.tournament_best_ball_hole_scores;

CREATE TRIGGER trg_validar_best_ball_hole_score_318
BEFORE INSERT OR UPDATE
ON public.tournament_best_ball_hole_scores
FOR EACH ROW
EXECUTE FUNCTION public._validar_best_ball_hole_score_318();

-- Protecciones compartidas que sí son compatibles con la tabla nueva.
DROP TRIGGER IF EXISTS trg_best_ball_cancelado_318
ON public.tournament_best_ball_hole_scores;
CREATE TRIGGER trg_best_ball_cancelado_318
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_best_ball_hole_scores
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_scorecard_cancelado_233();

DROP TRIGGER IF EXISTS trg_best_ball_vencido_318
ON public.tournament_best_ball_hole_scores;
CREATE TRIGGER trg_best_ball_vencido_318
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_best_ball_hole_scores
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_scorecard_torneo_vencido_295();

DROP TRIGGER IF EXISTS trg_best_ball_ronda_cerrada_318
ON public.tournament_best_ball_hole_scores;
CREATE TRIGGER trg_best_ball_ronda_cerrada_318
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_best_ball_hole_scores
FOR EACH ROW
EXECUTE FUNCTION public.proteger_datos_ronda_competitiva_cerrada();

DROP TRIGGER IF EXISTS trg_best_ball_inicio_torneo_318
ON public.tournament_best_ball_hole_scores;
CREATE TRIGGER trg_best_ball_inicio_torneo_318
BEFORE INSERT OR UPDATE
ON public.tournament_best_ball_hole_scores
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_score_competitivo_antes_inicio_256();

DROP TRIGGER IF EXISTS trg_best_ball_updated_at_318
ON public.tournament_best_ball_hole_scores;
CREATE TRIGGER trg_best_ball_updated_at_318
BEFORE UPDATE
ON public.tournament_best_ball_hole_scores
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

-- --------------------------------------------------------------------------
-- 3. INICIALIZADOR BEST BALL
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._inicializar_captura_scores_best_ball_318(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_validation_id uuid;
    v_round_condition_snapshot_id uuid;
    v_emission_id uuid;

    v_card_count integer:=0;
    v_hole_count integer:=0;
    v_member_count integer:=0;
    v_session_count integer:=0;
    v_score_row_count integer:=0;
    v_expected_rows integer:=0;
    v_bad_cards integer:=0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    SELECT tr.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para inicializar la captura Best Ball.'
            USING ERRCODE='42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(p_tournament_round_id);

    SELECT
        e.id,
        e.validation_id,
        v.round_condition_snapshot_id
      INTO
        v_emission_id,
        v_validation_id,
        v_round_condition_snapshot_id
      FROM public.tournament_score_card_emissions e
      JOIN public.tournament_round_start_validations v
        ON v.id=e.validation_id
       AND v.tournament_round_id=e.tournament_round_id
     WHERE e.tournament_round_id=p_tournament_round_id
       AND e.status='issued'
       AND v.start_format='shotgun'
       AND v.participation_type='equipo'
       AND v.scoring_engine='best_ball'
       AND v.validator_engine='best_ball_team_shotgun_v1'
     LIMIT 1;

    IF v_emission_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda no tiene emisión oficial Best Ball TEAM.'
            USING ERRCODE='23514';
    END IF;

    SELECT
        count(*),
        count(*) FILTER (
            WHERE sc.unit_type IS DISTINCT FROM 'team'
               OR sc.tournament_team_id IS NULL
               OR sc.player_id IS NOT NULL
               OR sc.tournament_registration_id IS NOT NULL
        )
      INTO v_card_count,v_bad_cards
      FROM public.tournament_score_cards sc
     WHERE sc.emission_id=v_emission_id
       AND sc.status='issued';

    IF v_card_count=0 OR v_bad_cards>0 THEN
        RAISE EXCEPTION
            'La emisión Best Ball contiene tarjetas incompatibles con captura TEAM.'
            USING ERRCODE='23514';
    END IF;

    SELECT count(*)
      INTO v_hole_count
      FROM public.tournament_round_hole_snapshots h
     WHERE h.round_condition_snapshot_id=v_round_condition_snapshot_id;

    IF v_hole_count<>18 THEN
        RAISE EXCEPTION
            'Best Ball requiere 18 hoyos congelados para inicializar captura.'
            USING ERRCODE='55000',
                  DETAIL=format('hoyos=%s',v_hole_count);
    END IF;

    -- Debe existir exactamente un snapshot Best Ball por tarjeta emitida.
    IF (
        SELECT count(*)
        FROM public.tournament_best_ball_scorecard_snapshots ss
        JOIN public.tournament_score_cards sc
          ON sc.id=ss.score_card_id
        WHERE sc.emission_id=v_emission_id
          AND sc.status='issued'
    ) <> v_card_count THEN
        RAISE EXCEPTION
            'Los snapshots Best Ball no corresponden uno a uno con las tarjetas emitidas.'
            USING ERRCODE='55000';
    END IF;

    -- Cada tarjeta debe tener entre 2 y 5 integrantes congelados.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_best_ball_scorecard_snapshots ss
        JOIN public.tournament_score_cards sc
          ON sc.id=ss.score_card_id
         AND sc.emission_id=v_emission_id
         AND sc.status='issued'
        LEFT JOIN public.tournament_best_ball_scorecard_members m
          ON m.best_ball_scorecard_snapshot_id=ss.id
        GROUP BY ss.id
        HAVING count(m.id) NOT BETWEEN 2 AND 5
    ) THEN
        RAISE EXCEPTION
            'Una o más tarjetas Best Ball no tienen entre 2 y 5 integrantes congelados.'
            USING ERRCODE='55000';
    END IF;

    SELECT count(*)
      INTO v_member_count
      FROM public.tournament_best_ball_scorecard_members m
      JOIN public.tournament_best_ball_scorecard_snapshots ss
        ON ss.id=m.best_ball_scorecard_snapshot_id
      JOIN public.tournament_score_cards sc
        ON sc.id=ss.score_card_id
     WHERE sc.emission_id=v_emission_id
       AND sc.status='issued';

    -- 3.1 Una sesión por tarjeta TEAM.
    INSERT INTO public.tournament_scorecard_capture_sessions(
        score_card_id,
        tournament_id,
        tournament_round_id,
        validation_id,
        status,
        holes_expected
    )
    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.validation_id,
        'ready',
        v_hole_count
    FROM public.tournament_score_cards sc
    WHERE sc.emission_id=v_emission_id
      AND sc.status='issued'
      AND sc.unit_type='team'
    ON CONFLICT(score_card_id) DO NOTHING;

    SELECT count(*)
      INTO v_session_count
      FROM public.tournament_scorecard_capture_sessions cs
      JOIN public.tournament_score_cards sc
        ON sc.id=cs.score_card_id
     WHERE sc.emission_id=v_emission_id
       AND sc.status='issued';

    IF v_session_count<>v_card_count THEN
        RAISE EXCEPTION
            'La inicialización de sesiones Best Ball quedó incompleta.'
            USING ERRCODE='55000',
                  DETAIL=format(
                    'sesiones=%s; tarjetas=%s',
                    v_session_count,v_card_count
                  );
    END IF;

    -- 3.2 Una fila PENDING por tarjeta x integrante x hoyo.
    INSERT INTO public.tournament_best_ball_hole_scores(
        capture_session_id,
        score_card_id,
        best_ball_scorecard_member_id,
        player_id,
        tournament_round_id,
        round_hole_snapshot_id,
        hole_number,
        play_sequence,
        gross_score,
        status,
        result_type
    )
    SELECT
        cs.id,
        sc.id,
        m.id,
        m.player_id,
        sc.tournament_round_id,
        h.id,
        h.hole_number,
        row_number() OVER(
            PARTITION BY sc.id,m.id
            ORDER BY
                CASE WHEN h.hole_number>=g.hole_number THEN 0 ELSE 1 END,
                h.hole_number
        )::integer,
        NULL,
        'pending',
        'PENDING'
    FROM public.tournament_score_cards sc
    JOIN public.tournament_scorecard_capture_sessions cs
      ON cs.score_card_id=sc.id
    JOIN public.tournament_round_start_validation_groups g
      ON g.id=sc.validation_group_id
     AND g.validation_id=sc.validation_id
    JOIN public.tournament_best_ball_scorecard_snapshots ss
      ON ss.score_card_id=sc.id
    JOIN public.tournament_best_ball_scorecard_members m
      ON m.best_ball_scorecard_snapshot_id=ss.id
    JOIN public.tournament_round_hole_snapshots h
      ON h.round_condition_snapshot_id=v_round_condition_snapshot_id
    WHERE sc.emission_id=v_emission_id
      AND sc.status='issued'
      AND sc.unit_type='team'
    ON CONFLICT(
        score_card_id,
        best_ball_scorecard_member_id,
        round_hole_snapshot_id
    ) DO NOTHING;

    SELECT count(*)
      INTO v_score_row_count
      FROM public.tournament_best_ball_hole_scores hs
      JOIN public.tournament_score_cards sc
        ON sc.id=hs.score_card_id
     WHERE sc.emission_id=v_emission_id
       AND sc.status='issued';

    v_expected_rows:=v_member_count*v_hole_count;

    IF v_score_row_count<>v_expected_rows THEN
        RAISE EXCEPTION
            'La inicialización Best Ball quedó incompleta y debe revertirse.'
            USING ERRCODE='55000',
                  DETAIL=format(
                    'filas_score=%s; esperadas=%s; integrantes=%s; hoyos=%s',
                    v_score_row_count,
                    v_expected_rows,
                    v_member_count,
                    v_hole_count
                  );
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_best_ball_hole_scores hs
        JOIN public.tournament_score_cards sc
          ON sc.id=hs.score_card_id
        WHERE sc.emission_id=v_emission_id
          AND (
              hs.status IS DISTINCT FROM 'pending'
              OR hs.result_type IS DISTINCT FROM 'PENDING'
              OR hs.gross_score IS NOT NULL
              OR hs.marker_assignment_id IS NOT NULL
          )
    ) THEN
        RAISE EXCEPTION
            'F4 sólo puede inicializar filas Best Ball en estado PENDING.'
            USING ERRCODE='55000';
    END IF;

    RETURN jsonb_build_object(
        'tournamentRoundId',p_tournament_round_id,
        'engine','best_ball',
        'initialized',true,
        'cardCount',v_card_count,
        'sessionCount',v_session_count,
        'memberCount',v_member_count,
        'holesPerMember',v_hole_count,
        'holeScoreRows',v_score_row_count,
        'markersInitialized',false
    );
END;
$function$;

-- --------------------------------------------------------------------------
-- 4. DISPATCHER DE INICIALIZACION
--    Sólo agrega la rama best_ball; no modifica funciones internas existentes.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.inicializar_captura_scores_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_unit_type text;
    v_engine text;
BEGIN
    SELECT sc.unit_type,v.scoring_engine
      INTO v_unit_type,v_engine
      FROM public.tournament_score_card_emissions e
      JOIN public.tournament_score_cards sc
        ON sc.emission_id=e.id
       AND sc.status='issued'
      JOIN public.tournament_round_start_validations v
        ON v.id=e.validation_id
     WHERE e.tournament_round_id=p_tournament_round_id
       AND e.status='issued'
     LIMIT 1;

    IF v_unit_type='team' AND v_engine='best_ball' THEN
        RETURN public._inicializar_captura_scores_best_ball_318(
            p_tournament_round_id
        );
    END IF;

    IF v_unit_type='team' AND v_engine='team_stroke' THEN
        RETURN public._inicializar_captura_scores_equipo_a_gogo_209(
            p_tournament_round_id
        );
    END IF;

    RETURN public._inicializar_captura_scores_ronda_individual_209(
        p_tournament_round_id
    );
END;
$function$;

-- --------------------------------------------------------------------------
-- 5. EMISION + INICIALIZACION ATOMICA BEST BALL
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._emitir_tarjetas_best_ball_ronda_318(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_issue jsonb;
    v_init jsonb;
BEGIN
    -- La función 317 es idempotente si ya existe una emisión activa.
    v_issue:=public._emitir_tarjetas_best_ball_ronda_317(
        p_tournament_round_id
    );

    v_init:=public.inicializar_captura_scores_ronda(
        p_tournament_round_id
    );

    IF NOT COALESCE((v_init->>'initialized')::boolean,false)
       OR v_init->>'engine' IS DISTINCT FROM 'best_ball'
    THEN
        RAISE EXCEPTION
            'La emisión Best Ball no pudo completar la inicialización de captura.'
            USING ERRCODE='55000',
                  DETAIL=COALESCE(v_init::text,'NULL');
    END IF;

    RETURN v_issue || jsonb_build_object(
        'captureInitialization',v_init
    );
END;
$function$;

-- Dispatcher oficial de emisión: mantiene las ramas existentes
-- y sustituye únicamente la llamada Best Ball 317 por el wrapper atómico 318.
CREATE OR REPLACE FUNCTION public.emitir_tarjetas_score_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_capability jsonb;
    v_emission_engine text;
BEGIN
    v_capability:=public._resolver_capacidad_emision_tarjetas_ronda(
        p_tournament_round_id
    );

    IF NOT COALESCE((v_capability->>'supported')::boolean,false) THEN
        RETURN public._emitir_tarjetas_score_ronda_individual_208(
            p_tournament_round_id
        );
    END IF;

    v_emission_engine:=v_capability->>'scorecardEmissionEngine';

    IF v_emission_engine='official_scorecard_best_ball_team_v1' THEN
        RETURN public._emitir_tarjetas_best_ball_ronda_318(
            p_tournament_round_id
        );
    END IF;

    IF v_emission_engine='official_scorecard_team_v1'
       AND v_capability->>'unitType'='team'
    THEN
        RETURN public._emitir_tarjetas_equipo_a_gogo_ronda_246(
            p_tournament_round_id
        );
    END IF;

    RETURN public._emitir_tarjetas_score_ronda_individual_208(
        p_tournament_round_id
    );
END;
$function$;

COMMIT;
