-- ============================================================================
-- 156_estados_competitivos_terminales_ronda.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 156 — ESTADOS COMPETITIVOS TERMINALES DE RONDA
--
-- OBJETIVO
-- Permitir que una ronda quede "resuelta para resultados" aunque no todas las
-- tarjetas terminen en OFFICIAL_READY.
--
-- RESULTADO DE RONDA
-- - OFFICIAL  -> DERIVADO, no se almacena: lo determina la Migración 155.
-- - WD        -> Withdrawn / retirado.
-- - DNF       -> Did Not Finish / inició pero no terminó.
-- - DQ        -> Disqualified / descalificado.
-- - DNS       -> Did Not Start / no inició.
-- - NO_CARD   -> jugó o participó pero no entregó tarjeta válida.
--
-- MC (Missed Cut)
-- NO es un resultado de una tarjeta de ronda. Es un estado competitivo del
-- torneo posterior a aplicar un corte. Se modela aparte como estado de corte:
-- - MC
-- - QUALIFIED
--
-- PRINCIPIOS
-- - NO reutiliza tournament_score_cards.status, que sigue siendo issued/voided.
-- - OFFICIAL sigue derivándose del pipeline físico + conciliación + NETO.
-- - Las excepciones no sobreescriben DIGITAL, FÍSICO ni conciliación.
-- - DNF conserva scores parciales para consulta.
-- - MC no altera la tarjeta de la ronda que ya puede ser OFFICIAL.
-- - No implementa todavía el algoritmo de corte ni leaderboard.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 0. GUARDAS
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('public.tournament_score_cards') IS NULL
       OR to_regclass('public.tournament_rounds') IS NULL
       OR to_regclass('public.tournament_registrations') IS NULL
       OR to_regclass('public.admin_users') IS NULL
    THEN
        RAISE EXCEPTION
            'Migración 156 requiere score cards, rondas, inscripciones y admin_users.';
    END IF;

    IF to_regprocedure('public._scorecard_current_admin_id()') IS NULL THEN
        RAISE EXCEPTION
            'Migración 156 requiere public._scorecard_current_admin_id().';
    END IF;

    IF to_regprocedure('public.puede_administrar_congelamiento_torneo(uuid)') IS NULL THEN
        RAISE EXCEPTION
            'Migración 156 requiere public.puede_administrar_congelamiento_torneo(uuid).';
    END IF;

    IF to_regprocedure('public.obtener_resultados_oficiales_ronda(uuid)') IS NULL THEN
        RAISE EXCEPTION
            'Migración 156 requiere public.obtener_resultados_oficiales_ronda(uuid) de la Migración 155.';
    END IF;
END;
$$;

-- ============================================================================
-- 1. ESTADO EXCEPCIONAL DE RESULTADO DE RONDA
--    Ausencia de fila = el resultado sigue el pipeline normal.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tournament_scorecard_round_outcomes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    score_card_id uuid NOT NULL UNIQUE
        REFERENCES public.tournament_score_cards(id) ON DELETE RESTRICT,

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,

    tournament_registration_id uuid NULL
        REFERENCES public.tournament_registrations(id) ON DELETE RESTRICT,

    player_id uuid NULL
        REFERENCES public.players(id) ON DELETE RESTRICT,

    outcome_code text NOT NULL
        CHECK (outcome_code IN ('WD','DNF','DQ','DNS','NO_CARD')),

    reason text NOT NULL
        CHECK (length(btrim(reason)) >= 5),

    effective_at timestamptz NOT NULL DEFAULT now(),

    recorded_by_admin_user_id uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_scorecard_round_outcomes_identity_ck
    CHECK (
        tournament_id IS NOT NULL
        AND tournament_round_id IS NOT NULL
    )
);

CREATE INDEX IF NOT EXISTS idx_scorecard_round_outcomes_round
ON public.tournament_scorecard_round_outcomes(
    tournament_round_id,
    outcome_code,
    score_card_id
);

ALTER TABLE public.tournament_scorecard_round_outcomes
ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_scorecard_round_outcomes
FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 2. BITÁCORA APPEND-ONLY DE CAMBIOS DE OUTCOME
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tournament_scorecard_round_outcome_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id) ON DELETE RESTRICT,

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,

    old_outcome_code text NULL,
    new_outcome_code text NULL,

    reason text NOT NULL
        CHECK (length(btrim(reason)) >= 5),

    actor_admin_user_id uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,

    created_at timestamptz NOT NULL DEFAULT now(),

    CHECK (
        old_outcome_code IS NULL
        OR old_outcome_code IN ('WD','DNF','DQ','DNS','NO_CARD')
    ),

    CHECK (
        new_outcome_code IS NULL
        OR new_outcome_code IN ('WD','DNF','DQ','DNS','NO_CARD')
    ),

    CHECK (
        old_outcome_code IS DISTINCT FROM new_outcome_code
    )
);

CREATE INDEX IF NOT EXISTS idx_scorecard_round_outcome_events_card
ON public.tournament_scorecard_round_outcome_events(
    score_card_id,
    created_at,
    id
);

ALTER TABLE public.tournament_scorecard_round_outcome_events
ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_scorecard_round_outcome_events
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._impedir_mutacion_scorecard_round_outcome_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION
        'Los eventos de outcome competitivo son inmutables.'
        USING ERRCODE = '55000';
END;
$$;

DROP TRIGGER IF EXISTS trg_impedir_mutacion_scorecard_round_outcome_event
ON public.tournament_scorecard_round_outcome_events;

CREATE TRIGGER trg_impedir_mutacion_scorecard_round_outcome_event
BEFORE UPDATE OR DELETE
ON public.tournament_scorecard_round_outcome_events
FOR EACH ROW
EXECUTE FUNCTION public._impedir_mutacion_scorecard_round_outcome_event();

-- ============================================================================
-- 3. ESTADO DE CORTE DEL TORNEO — MC / QUALIFIED
--    Se mantiene separado del resultado de ronda.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tournament_cut_player_statuses (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,

    cut_after_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,

    tournament_registration_id uuid NOT NULL
        REFERENCES public.tournament_registrations(id) ON DELETE RESTRICT,

    player_id uuid NOT NULL
        REFERENCES public.players(id) ON DELETE RESTRICT,

    cut_status text NOT NULL
        CHECK (cut_status IN ('MC','QUALIFIED')),

    reason text NULL,

    decided_at timestamptz NOT NULL DEFAULT now(),

    decided_by_admin_user_id uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    UNIQUE (
        tournament_id,
        cut_after_round_id,
        tournament_registration_id
    )
);

CREATE INDEX IF NOT EXISTS idx_tournament_cut_player_statuses_round
ON public.tournament_cut_player_statuses(
    tournament_id,
    cut_after_round_id,
    cut_status
);

ALTER TABLE public.tournament_cut_player_statuses
ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_cut_player_statuses
FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 4. RPC — FIJAR/CAMBIAR OUTCOME EXCEPCIONAL DE RONDA
-- ============================================================================

CREATE OR REPLACE FUNCTION public.establecer_outcome_competitivo_tarjeta(
    p_score_card_id uuid,
    p_outcome_code text,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_card record;
    v_admin_id uuid;
    v_new_code text;
    v_reason text;
    v_old_code text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    v_new_code := upper(btrim(COALESCE(p_outcome_code,'')));
    v_reason := btrim(COALESCE(p_reason,''));

    IF v_new_code NOT IN ('WD','DNF','DQ','DNS','NO_CARD') THEN
        RAISE EXCEPTION
            'outcome_code inválido. Permitidos: WD, DNF, DQ, DNS, NO_CARD.'
            USING ERRCODE = '22023';
    END IF;

    IF length(v_reason) < 5 THEN
        RAISE EXCEPTION
            'El motivo debe tener al menos 5 caracteres.'
            USING ERRCODE = '22023';
    END IF;

    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.tournament_registration_id,
        sc.player_id,
        sc.status
      INTO v_card
      FROM public.tournament_score_cards sc
     WHERE sc.id = p_score_card_id
     FOR UPDATE;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF v_card.status <> 'issued' THEN
        RAISE EXCEPTION
            'Sólo puede establecerse outcome sobre una tarjeta emitida.'
            USING ERRCODE = '55000';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_card.tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para modificar esta tarjeta.'
            USING ERRCODE = '42501';
    END IF;

    v_admin_id := public._scorecard_current_admin_id();

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT outcome_code
      INTO v_old_code
      FROM public.tournament_scorecard_round_outcomes
     WHERE score_card_id = p_score_card_id;

    IF v_old_code IS NOT DISTINCT FROM v_new_code THEN
        RETURN jsonb_build_object(
            'scoreCardId', p_score_card_id,
            'outcomeCode', v_new_code,
            'changed', false
        );
    END IF;

    INSERT INTO public.tournament_scorecard_round_outcomes (
        score_card_id,
        tournament_id,
        tournament_round_id,
        tournament_registration_id,
        player_id,
        outcome_code,
        reason,
        effective_at,
        recorded_by_admin_user_id,
        created_at,
        updated_at
    )
    VALUES (
        v_card.id,
        v_card.tournament_id,
        v_card.tournament_round_id,
        v_card.tournament_registration_id,
        v_card.player_id,
        v_new_code,
        v_reason,
        now(),
        v_admin_id,
        now(),
        now()
    )
    ON CONFLICT (score_card_id)
    DO UPDATE SET
        outcome_code = EXCLUDED.outcome_code,
        reason = EXCLUDED.reason,
        effective_at = now(),
        recorded_by_admin_user_id = EXCLUDED.recorded_by_admin_user_id,
        updated_at = now();

    INSERT INTO public.tournament_scorecard_round_outcome_events (
        score_card_id,
        tournament_id,
        tournament_round_id,
        old_outcome_code,
        new_outcome_code,
        reason,
        actor_admin_user_id
    )
    VALUES (
        v_card.id,
        v_card.tournament_id,
        v_card.tournament_round_id,
        v_old_code,
        v_new_code,
        v_reason,
        v_admin_id
    );

    RETURN jsonb_build_object(
        'scoreCardId', v_card.id,
        'tournamentId', v_card.tournament_id,
        'tournamentRoundId', v_card.tournament_round_id,
        'oldOutcomeCode', v_old_code,
        'outcomeCode', v_new_code,
        'changed', true
    );
END;
$$;

-- ============================================================================
-- 5. RPC — QUITAR OUTCOME EXCEPCIONAL Y REGRESAR AL PIPELINE NORMAL
-- ============================================================================

CREATE OR REPLACE FUNCTION public.limpiar_outcome_competitivo_tarjeta(
    p_score_card_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_row record;
    v_admin_id uuid;
    v_reason text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    v_reason := btrim(COALESCE(p_reason,''));

    IF length(v_reason) < 5 THEN
        RAISE EXCEPTION
            'El motivo debe tener al menos 5 caracteres.'
            USING ERRCODE = '22023';
    END IF;

    SELECT o.*
      INTO v_row
      FROM public.tournament_scorecard_round_outcomes o
     WHERE o.score_card_id = p_score_card_id
     FOR UPDATE;

    IF v_row.id IS NULL THEN
        RETURN jsonb_build_object(
            'scoreCardId', p_score_card_id,
            'changed', false
        );
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_row.tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para modificar esta tarjeta.'
            USING ERRCODE = '42501';
    END IF;

    v_admin_id := public._scorecard_current_admin_id();

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.tournament_scorecard_round_outcome_events (
        score_card_id,
        tournament_id,
        tournament_round_id,
        old_outcome_code,
        new_outcome_code,
        reason,
        actor_admin_user_id
    )
    VALUES (
        v_row.score_card_id,
        v_row.tournament_id,
        v_row.tournament_round_id,
        v_row.outcome_code,
        NULL,
        v_reason,
        v_admin_id
    );

    DELETE FROM public.tournament_scorecard_round_outcomes
    WHERE id = v_row.id;

    RETURN jsonb_build_object(
        'scoreCardId', p_score_card_id,
        'oldOutcomeCode', v_row.outcome_code,
        'outcomeCode', NULL,
        'changed', true
    );
END;
$$;

-- ============================================================================
-- 6. RPC — REGISTRAR ESTADO DE CORTE (MC / QUALIFIED)
--    NO calcula el corte; sólo registra la decisión.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.establecer_estado_corte_jugador(
    p_tournament_registration_id uuid,
    p_cut_after_round_id uuid,
    p_cut_status text,
    p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_reg record;
    v_round record;
    v_admin_id uuid;
    v_status text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    v_status := upper(btrim(COALESCE(p_cut_status,'')));

    IF v_status NOT IN ('MC','QUALIFIED') THEN
        RAISE EXCEPTION
            'cut_status inválido. Permitidos: MC, QUALIFIED.'
            USING ERRCODE = '22023';
    END IF;

    SELECT id, tournament_id, player_id
      INTO v_reg
      FROM public.tournament_registrations
     WHERE id = p_tournament_registration_id;

    IF v_reg.id IS NULL THEN
        RAISE EXCEPTION 'La inscripción indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    SELECT id, tournament_id
      INTO v_round
      FROM public.tournament_rounds
     WHERE id = p_cut_after_round_id;

    IF v_round.id IS NULL
       OR v_round.tournament_id <> v_reg.tournament_id
    THEN
        RAISE EXCEPTION
            'La ronda de corte no corresponde al torneo de la inscripción.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_reg.tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para registrar este corte.'
            USING ERRCODE = '42501';
    END IF;

    v_admin_id := public._scorecard_current_admin_id();

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.tournament_cut_player_statuses (
        tournament_id,
        cut_after_round_id,
        tournament_registration_id,
        player_id,
        cut_status,
        reason,
        decided_at,
        decided_by_admin_user_id,
        created_at,
        updated_at
    )
    VALUES (
        v_reg.tournament_id,
        v_round.id,
        v_reg.id,
        v_reg.player_id,
        v_status,
        nullif(btrim(COALESCE(p_reason,'')),''),
        now(),
        v_admin_id,
        now(),
        now()
    )
    ON CONFLICT (
        tournament_id,
        cut_after_round_id,
        tournament_registration_id
    )
    DO UPDATE SET
        cut_status = EXCLUDED.cut_status,
        reason = EXCLUDED.reason,
        decided_at = now(),
        decided_by_admin_user_id = EXCLUDED.decided_by_admin_user_id,
        updated_at = now();

    RETURN jsonb_build_object(
        'tournamentId', v_reg.tournament_id,
        'tournamentRegistrationId', v_reg.id,
        'playerId', v_reg.player_id,
        'cutAfterRoundId', v_round.id,
        'cutStatus', v_status
    );
END;
$$;

-- ============================================================================
-- 7. RPC — VALIDAR SI LA RONDA ESTÁ RESUELTA PARA RESULTADOS
--
-- Una tarjeta cuenta como resuelta cuando:
-- - está OFFICIAL_READY en la fuente 155; O
-- - tiene outcome excepcional WD/DNF/DQ/DNS/NO_CARD.
--
-- DNF puede conservar scores parciales, pero NO se considera resultado
-- individual oficial completo.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.validar_cierre_resultados_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_massive jsonb;
    v_tournament_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds
     WHERE id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para validar esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    v_massive := public.obtener_resultados_oficiales_ronda(
        p_tournament_round_id
    );

    RETURN (
        WITH cards AS (
            SELECT
                c->>'scoreCardId' AS score_card_id_text,
                (c->>'scoreCardId')::uuid AS score_card_id,
                c->>'playerName' AS player_name,
                c->>'cardFolio' AS card_folio,
                COALESCE((c->>'ready')::boolean,false) AS official_ready,
                c->>'resultStatus' AS pipeline_status
            FROM jsonb_array_elements(v_massive->'cards') c
        ),
        resolved AS (
            SELECT
                c.*,
                o.outcome_code,
                o.reason AS outcome_reason,
                (
                    c.official_ready
                    OR o.outcome_code IN ('WD','DNF','DQ','DNS','NO_CARD')
                ) AS resolved_for_round
            FROM cards c
            LEFT JOIN public.tournament_scorecard_round_outcomes o
              ON o.score_card_id = c.score_card_id
        ),
        counts AS (
            SELECT
                count(*) AS total_cards,
                count(*) FILTER (WHERE official_ready) AS official_cards,
                count(*) FILTER (WHERE outcome_code='WD') AS wd,
                count(*) FILTER (WHERE outcome_code='DNF') AS dnf,
                count(*) FILTER (WHERE outcome_code='DQ') AS dq,
                count(*) FILTER (WHERE outcome_code='DNS') AS dns,
                count(*) FILTER (WHERE outcome_code='NO_CARD') AS no_card,
                count(*) FILTER (WHERE resolved_for_round) AS resolved_cards,
                count(*) FILTER (WHERE NOT resolved_for_round) AS unresolved_cards
            FROM resolved
        )
        SELECT jsonb_build_object(
            'tournamentId', v_tournament_id,
            'tournamentRoundId', p_tournament_round_id,
            'readyToCloseResults',
                (SELECT unresolved_cards=0 AND total_cards>0 FROM counts),
            'summary', (
                SELECT jsonb_build_object(
                    'totalCards', total_cards,
                    'officialCards', official_cards,
                    'WD', wd,
                    'DNF', dnf,
                    'DQ', dq,
                    'DNS', dns,
                    'NO_CARD', no_card,
                    'resolvedCards', resolved_cards,
                    'unresolvedCards', unresolved_cards
                )
                FROM counts
            ),
            'unresolved', COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'scoreCardId', score_card_id,
                        'cardFolio', card_folio,
                        'playerName', player_name,
                        'pipelineStatus', pipeline_status
                    )
                    ORDER BY card_folio
                )
                FROM resolved
                WHERE NOT resolved_for_round
            ), '[]'::jsonb)
        )
    );
END;
$$;

-- ============================================================================
-- 8. RPC — CONSULTA MASIVA DE OUTCOMES + PARCIALES DNF
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_outcomes_competitivos_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tournament_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds
     WHERE id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar estos outcomes.'
            USING ERRCODE = '42501';
    END IF;

    RETURN jsonb_build_object(
        'tournamentId', v_tournament_id,
        'tournamentRoundId', p_tournament_round_id,
        'outcomes', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'scoreCardId', o.score_card_id,
                    'cardFolio', sc.card_folio,
                    'playerId', sc.player_id,
                    'playerName', u.unit_name,
                    'outcomeCode', o.outcome_code,
                    'reason', o.reason,
                    'effectiveAt', o.effective_at,
                    'partial', CASE
                        WHEN o.outcome_code='DNF' THEN jsonb_build_object(
                            'holesWithDigitalScore',
                                count(hs.gross_score) FILTER (
                                    WHERE hs.gross_score IS NOT NULL
                                ),
                            'digitalGrossPartial',
                                sum(hs.gross_score) FILTER (
                                    WHERE hs.gross_score IS NOT NULL
                                ),
                            'holes', COALESCE(
                                jsonb_agg(
                                    jsonb_build_object(
                                        'holeNumber', hs.hole_number,
                                        'playSequence', hs.play_sequence,
                                        'grossScore', hs.gross_score,
                                        'status', hs.status
                                    )
                                    ORDER BY hs.play_sequence
                                ) FILTER (
                                    WHERE hs.gross_score IS NOT NULL
                                ),
                                '[]'::jsonb
                            )
                        )
                        ELSE NULL
                    END
                )
                ORDER BY sc.card_number
            )
            FROM public.tournament_scorecard_round_outcomes o
            JOIN public.tournament_score_cards sc
              ON sc.id=o.score_card_id
            JOIN public.tournament_round_start_validation_units u
              ON u.id=sc.validation_unit_id
             AND u.validation_id=sc.validation_id
            LEFT JOIN public.tournament_scorecard_hole_scores hs
              ON hs.score_card_id=sc.id
            WHERE o.tournament_round_id=p_tournament_round_id
            GROUP BY
                o.score_card_id,
                o.outcome_code,
                o.reason,
                o.effective_at,
                sc.card_folio,
                sc.card_number,
                sc.player_id,
                u.unit_name
        ), '[]'::jsonb)
    );
END;
$$;

-- ============================================================================
-- 9. PRIVILEGIOS
-- ============================================================================

REVOKE ALL ON FUNCTION public.establecer_outcome_competitivo_tarjeta(
    uuid,text,text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.establecer_outcome_competitivo_tarjeta(
    uuid,text,text
) TO authenticated;

REVOKE ALL ON FUNCTION public.limpiar_outcome_competitivo_tarjeta(
    uuid,text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.limpiar_outcome_competitivo_tarjeta(
    uuid,text
) TO authenticated;

REVOKE ALL ON FUNCTION public.establecer_estado_corte_jugador(
    uuid,uuid,text,text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.establecer_estado_corte_jugador(
    uuid,uuid,text,text
) TO authenticated;

REVOKE ALL ON FUNCTION public.validar_cierre_resultados_ronda(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.validar_cierre_resultados_ronda(uuid)
TO authenticated;

REVOKE ALL ON FUNCTION public.obtener_outcomes_competitivos_ronda(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_outcomes_competitivos_ronda(uuid)
TO authenticated;

COMMIT;
