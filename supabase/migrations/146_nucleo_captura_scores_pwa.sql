-- ============================================================================
-- 146_nucleo_captura_scores_pwa.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 146 — NÚCLEO DE CAPTURA DE SCORES PARA PWA
--
-- OBJETIVO
-- Construir el backend transaccional de captura de GROSS por hoyo para
-- Stroke Play individual, preparado para una PWA con marcador circular:
--
--   A marca a B
--   B marca a C
--   C marca a D
--   D marca a A
--
-- REGLAS CENTRALES
-- 1. Un jugador NO captura su propio score.
-- 2. El marcador asignado captura el GROSS del jugador cuya tarjeta lleva.
-- 3. El dueño de la tarjeta confirma o disputa lo capturado por su marcador.
-- 4. El QR de tournament_score_cards identifica/localiza la tarjeta, pero
--    NO concede permiso de escritura por sí solo.
-- 5. La autorización se resuelve siempre desde auth.uid()
--       -> players.auth_user_id
--       -> player_id
--       -> asignación vigente de marcador / dueño de tarjeta.
-- 6. Se captura GROSS. NETO, leaderboard, cortes y desempates quedan fuera.
-- 7. Las tarjetas oficiales de la Migración 143 permanecen inmutables.
-- 8. Los hoyos se toman de tournament_round_hole_snapshots.
-- 9. El orden de juego (play_sequence) respeta el hoyo inicial Shotgun:
--       inicio 7 => 7..18, 1..6.
-- 10. Toda corrección/confirmación/disputa deja evento auditable.
--
-- ALCANCE
-- - 4 tablas:
--   tournament_scorecard_capture_sessions
--   tournament_scorecard_marker_assignments
--   tournament_scorecard_hole_scores
--   tournament_scorecard_events
-- - inicialización idempotente por ronda;
-- - asignación circular automática;
-- - cambio administrativo auditado de marcador;
-- - apertura segura por QR;
-- - panel del jugador por ronda;
-- - captura/corrección de gross por marcador;
-- - confirmación/disputa por dueño de tarjeta;
-- - RLS de sólo lectura autorizada;
-- - sin escritura directa de cliente.
--
-- NO INCLUYE
-- - UI/PWA;
-- - WhatsApp/push;
-- - Gross/Net calculado;
-- - resultados/leaderboard;
-- - cortes;
-- - reconciliación de tarjeta física;
-- - cierre oficial de score;
-- - corrección del Comité posterior a devolución;
-- - anulación/reemisión de tarjetas;
-- - QR de inscripción/control de acceso.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 0. GUARDAS PREVIAS
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('public.tournament_score_cards') IS NULL THEN
        RAISE EXCEPTION
            'Migración 146 requiere tournament_score_cards (Migración 143).';
    END IF;

    IF to_regclass('public.tournament_round_hole_snapshots') IS NULL THEN
        RAISE EXCEPTION
            'Migración 146 requiere tournament_round_hole_snapshots.';
    END IF;

    IF to_regclass('public.tournament_round_start_validation_groups') IS NULL
       OR to_regclass('public.tournament_round_start_validation_units') IS NULL
    THEN
        RAISE EXCEPTION
            'Migración 146 requiere snapshots de validación de salidas (Migración 140).';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'players'
          AND con.contype = 'f'
          AND pg_get_constraintdef(con.oid) ILIKE '%auth.users%'
    ) THEN
        RAISE EXCEPTION
            'Migración 146 requiere players.auth_user_id vinculado a auth.users.';
    END IF;
END;
$$;

-- ============================================================================
-- 1. SESIÓN OPERATIVA DE CAPTURA POR TARJETA
-- ============================================================================

CREATE TABLE public.tournament_scorecard_capture_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id)
        ON DELETE RESTRICT,

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id)
        ON DELETE RESTRICT,

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id)
        ON DELETE RESTRICT,

    validation_id uuid NOT NULL
        REFERENCES public.tournament_round_start_validations(id)
        ON DELETE RESTRICT,

    status text NOT NULL DEFAULT 'ready'
        CHECK (status IN ('ready', 'in_progress', 'captured')),

    holes_expected integer NOT NULL
        CHECK (holes_expected > 0),

    started_at timestamptz,
    captured_at timestamptz,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_scorecard_capture_sessions_card_uk
        UNIQUE (score_card_id),

    CONSTRAINT tournament_scorecard_capture_sessions_status_ck
        CHECK (
            (status = 'ready'
                AND started_at IS NULL
                AND captured_at IS NULL)
            OR
            (status = 'in_progress'
                AND started_at IS NOT NULL
                AND captured_at IS NULL)
            OR
            (status = 'captured'
                AND started_at IS NOT NULL
                AND captured_at IS NOT NULL)
        )
);

COMMENT ON TABLE public.tournament_scorecard_capture_sessions IS
'Estado operativo de captura de una tarjeta oficial. No contiene resultados calculados; sólo controla el ciclo ready/in_progress/captured.';

COMMENT ON COLUMN public.tournament_scorecard_capture_sessions.holes_expected IS
'Cantidad de hoyos congelados para la ronda al inicializar captura. No es un conteo vivo del catálogo.';

CREATE INDEX idx_scorecard_capture_sessions_round
    ON public.tournament_scorecard_capture_sessions(
        tournament_round_id,
        status,
        score_card_id
    );

-- ============================================================================
-- 2. ASIGNACIONES DE MARCADOR
-- ============================================================================

CREATE TABLE public.tournament_scorecard_marker_assignments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id)
        ON DELETE RESTRICT,

    validation_group_id uuid NOT NULL
        REFERENCES public.tournament_round_start_validation_groups(id)
        ON DELETE RESTRICT,

    -- Tarjeta cuyo score captura el marcador.
    score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id)
        ON DELETE RESTRICT,

    -- Tarjeta propia del jugador que actúa como marcador.
    marker_score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id)
        ON DELETE RESTRICT,

    marker_player_id uuid NOT NULL
        REFERENCES public.players(id)
        ON DELETE RESTRICT,

    marker_registration_id uuid NOT NULL
        REFERENCES public.tournament_registrations(id)
        ON DELETE RESTRICT,

    assignment_source text NOT NULL DEFAULT 'circular'
        CHECK (assignment_source IN ('circular', 'admin')),

    valid_from_sequence integer NOT NULL DEFAULT 1
        CHECK (valid_from_sequence > 0),

    -- NULL mientras está vigente. Para una asignación terminada puede ser NULL
    -- si fue sustituida antes de que llegara a utilizarse.
    valid_to_sequence integer
        CHECK (
            valid_to_sequence IS NULL
            OR valid_to_sequence > 0
        ),

    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'ended')),

    assigned_at timestamptz NOT NULL DEFAULT now(),
    assigned_by uuid
        REFERENCES public.admin_users(id)
        ON DELETE RESTRICT,

    ended_at timestamptz,

    change_reason text,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_scorecard_marker_not_self_ck
        CHECK (marker_score_card_id <> score_card_id),

    CONSTRAINT tournament_scorecard_marker_range_ck
        CHECK (
            valid_to_sequence IS NULL
            OR valid_to_sequence >= valid_from_sequence
        ),

    CONSTRAINT tournament_scorecard_marker_status_ck
        CHECK (
            (status = 'active'
                AND ended_at IS NULL
                AND valid_to_sequence IS NULL)
            OR
            (status = 'ended'
                AND ended_at IS NOT NULL)
        )
);

COMMENT ON TABLE public.tournament_scorecard_marker_assignments IS
'Historial de quién marca la tarjeta de quién. La asignación circular inicial se deriva del order_in_group congelado; los cambios posteriores requieren operación administrativa auditada.';

CREATE UNIQUE INDEX tournament_scorecard_marker_one_active_uk
    ON public.tournament_scorecard_marker_assignments(score_card_id)
    WHERE status = 'active';

CREATE INDEX idx_scorecard_marker_by_player_round
    ON public.tournament_scorecard_marker_assignments(
        marker_player_id,
        tournament_round_id,
        status
    );

CREATE INDEX idx_scorecard_marker_target_history
    ON public.tournament_scorecard_marker_assignments(
        score_card_id,
        valid_from_sequence,
        assigned_at
    );

-- ============================================================================
-- 3. SCORE GROSS POR HOYO
-- ============================================================================

CREATE TABLE public.tournament_scorecard_hole_scores (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    capture_session_id uuid NOT NULL
        REFERENCES public.tournament_scorecard_capture_sessions(id)
        ON DELETE RESTRICT,

    score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id)
        ON DELETE RESTRICT,

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id)
        ON DELETE RESTRICT,

    round_hole_snapshot_id uuid NOT NULL
        REFERENCES public.tournament_round_hole_snapshots(id)
        ON DELETE RESTRICT,

    hole_number integer NOT NULL
        CHECK (hole_number > 0),

    -- Orden real de juego de esa tarjeta. En Shotgun puede ser 7,8,...18,1,...6
    -- a nivel de hole_number, pero play_sequence siempre es 1..N.
    play_sequence integer NOT NULL
        CHECK (play_sequence > 0),

    -- Dato CAPTURADO. Incluye penalidades que correspondan al score del hoyo.
    gross_score integer
        CHECK (gross_score IS NULL OR gross_score > 0),

    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'entered', 'confirmed', 'disputed')),

    -- Asignación vigente que autorizó la última captura/corrección.
    marker_assignment_id uuid
        REFERENCES public.tournament_scorecard_marker_assignments(id)
        ON DELETE RESTRICT,

    entered_by_player_id uuid
        REFERENCES public.players(id)
        ON DELETE RESTRICT,

    entered_at timestamptz,

    confirmed_by_player_id uuid
        REFERENCES public.players(id)
        ON DELETE RESTRICT,

    confirmed_at timestamptz,

    -- No sustituye gross_score. Es la cifra que el dueño declara al disputar.
    player_claimed_gross_score integer
        CHECK (
            player_claimed_gross_score IS NULL
            OR player_claimed_gross_score > 0
        ),

    dispute_note text,
    disputed_at timestamptz,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_scorecard_hole_scores_card_hole_uk
        UNIQUE (score_card_id, round_hole_snapshot_id),

    CONSTRAINT tournament_scorecard_hole_scores_card_sequence_uk
        UNIQUE (score_card_id, play_sequence),

    CONSTRAINT tournament_scorecard_hole_scores_state_ck
        CHECK (
            (
                status = 'pending'
                AND gross_score IS NULL
                AND marker_assignment_id IS NULL
                AND entered_by_player_id IS NULL
                AND entered_at IS NULL
                AND confirmed_by_player_id IS NULL
                AND confirmed_at IS NULL
                AND player_claimed_gross_score IS NULL
                AND dispute_note IS NULL
                AND disputed_at IS NULL
            )
            OR
            (
                status = 'entered'
                AND gross_score IS NOT NULL
                AND marker_assignment_id IS NOT NULL
                AND entered_by_player_id IS NOT NULL
                AND entered_at IS NOT NULL
                AND confirmed_by_player_id IS NULL
                AND confirmed_at IS NULL
                AND player_claimed_gross_score IS NULL
                AND dispute_note IS NULL
                AND disputed_at IS NULL
            )
            OR
            (
                status = 'confirmed'
                AND gross_score IS NOT NULL
                AND marker_assignment_id IS NOT NULL
                AND entered_by_player_id IS NOT NULL
                AND entered_at IS NOT NULL
                AND confirmed_by_player_id IS NOT NULL
                AND confirmed_at IS NOT NULL
                AND player_claimed_gross_score IS NULL
                AND dispute_note IS NULL
                AND disputed_at IS NULL
            )
            OR
            (
                status = 'disputed'
                AND gross_score IS NOT NULL
                AND marker_assignment_id IS NOT NULL
                AND entered_by_player_id IS NOT NULL
                AND entered_at IS NOT NULL
                AND confirmed_by_player_id IS NULL
                AND confirmed_at IS NULL
                AND player_claimed_gross_score IS NOT NULL
                AND player_claimed_gross_score <> gross_score
                AND disputed_at IS NOT NULL
            )
        )
);

COMMENT ON TABLE public.tournament_scorecard_hole_scores IS
'Captura transaccional de GROSS por tarjeta+hoyo. NETO y resultados derivados no se almacenan aquí.';

COMMENT ON COLUMN public.tournament_scorecard_hole_scores.player_claimed_gross_score IS
'Valor declarado por el dueño al disputar. Nunca sobrescribe automáticamente el gross capturado por el marcador.';

CREATE INDEX idx_scorecard_hole_scores_round_status
    ON public.tournament_scorecard_hole_scores(
        tournament_round_id,
        status,
        play_sequence
    );

CREATE INDEX idx_scorecard_hole_scores_card
    ON public.tournament_scorecard_hole_scores(
        score_card_id,
        play_sequence
    );

-- ============================================================================
-- 4. EVENTOS AUDITABLES
-- ============================================================================

CREATE TABLE public.tournament_scorecard_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id)
        ON DELETE RESTRICT,

    hole_score_id uuid
        REFERENCES public.tournament_scorecard_hole_scores(id)
        ON DELETE RESTRICT,

    marker_assignment_id uuid
        REFERENCES public.tournament_scorecard_marker_assignments(id)
        ON DELETE RESTRICT,

    event_type text NOT NULL
        CHECK (
            event_type IN (
                'score_entered',
                'score_corrected',
                'player_confirmed',
                'player_disputed',
                'marker_changed'
            )
        ),

    actor_player_id uuid
        REFERENCES public.players(id)
        ON DELETE RESTRICT,

    actor_admin_user_id uuid
        REFERENCES public.admin_users(id)
        ON DELETE RESTRICT,

    old_gross_score integer,
    new_gross_score integer,
    claimed_gross_score integer,

    reason text,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_scorecard_events_one_actor_ck
        CHECK (
            num_nonnulls(actor_player_id, actor_admin_user_id) = 1
        )
);

COMMENT ON TABLE public.tournament_scorecard_events IS
'Bitácora inmutable de captura/corrección/confirmación/disputa y cambios de marcador.';

CREATE INDEX idx_scorecard_events_card_time
    ON public.tournament_scorecard_events(score_card_id, created_at, id);

CREATE INDEX idx_scorecard_events_hole_time
    ON public.tournament_scorecard_events(hole_score_id, created_at, id)
    WHERE hole_score_id IS NOT NULL;

-- ============================================================================
-- 5. UPDATED_AT
-- ============================================================================

DROP TRIGGER IF EXISTS trg_scorecard_capture_sessions_updated_at
ON public.tournament_scorecard_capture_sessions;

CREATE TRIGGER trg_scorecard_capture_sessions_updated_at
BEFORE UPDATE ON public.tournament_scorecard_capture_sessions
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_scorecard_hole_scores_updated_at
ON public.tournament_scorecard_hole_scores;

CREATE TRIGGER trg_scorecard_hole_scores_updated_at
BEFORE UPDATE ON public.tournament_scorecard_hole_scores
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

-- ============================================================================
-- 6. EVENTOS INMUTABLES
-- ============================================================================

CREATE OR REPLACE FUNCTION public._impedir_mutacion_evento_scorecard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION
        'La bitácora de captura de score es inmutable.'
        USING ERRCODE = '55000';
END;
$$;

DROP TRIGGER IF EXISTS trg_impedir_mutacion_scorecard_events
ON public.tournament_scorecard_events;

CREATE TRIGGER trg_impedir_mutacion_scorecard_events
BEFORE UPDATE OR DELETE ON public.tournament_scorecard_events
FOR EACH ROW
EXECUTE FUNCTION public._impedir_mutacion_evento_scorecard();

-- ============================================================================
-- 7. HELPERS INTERNOS DE IDENTIDAD
-- ============================================================================

CREATE OR REPLACE FUNCTION public._scorecard_current_player_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_player_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT p.id
      INTO v_player_id
      FROM public.players p
     WHERE p.auth_user_id = auth.uid()
       AND p.activo
     ORDER BY p.id
     LIMIT 1;

    RETURN v_player_id;
END;
$$;

CREATE OR REPLACE FUNCTION public._scorecard_current_admin_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_admin_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo
     ORDER BY au.id
     LIMIT 1;

    RETURN v_admin_id;
END;
$$;

-- Helper usado por RLS SELECT. Deliberadamente sólo responde booleano.
CREATE OR REPLACE FUNCTION public.puede_ver_score_card_captura(
    p_score_card_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT
        auth.uid() IS NOT NULL
        AND EXISTS (
            SELECT 1
            FROM public.tournament_score_cards sc
            WHERE sc.id = p_score_card_id
              AND sc.status = 'issued'
              AND (
                    public.puede_administrar_congelamiento_torneo(sc.tournament_id)
                    OR sc.player_id = public._scorecard_current_player_id()
                    OR EXISTS (
                        SELECT 1
                        FROM public.tournament_scorecard_marker_assignments ma
                        WHERE ma.score_card_id = sc.id
                          AND ma.status = 'active'
                          AND ma.marker_player_id =
                              public._scorecard_current_player_id()
                    )
              )
        );
$$;

-- ============================================================================
-- 8. RLS / PRIVILEGIOS
-- ============================================================================

ALTER TABLE public.tournament_scorecard_capture_sessions
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_scorecard_marker_assignments
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_scorecard_hole_scores
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_scorecard_events
    ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tournament_scorecard_capture_sessions_select
ON public.tournament_scorecard_capture_sessions;
CREATE POLICY tournament_scorecard_capture_sessions_select
ON public.tournament_scorecard_capture_sessions
FOR SELECT TO authenticated
USING (public.puede_ver_score_card_captura(score_card_id));

DROP POLICY IF EXISTS tournament_scorecard_marker_assignments_select
ON public.tournament_scorecard_marker_assignments;
CREATE POLICY tournament_scorecard_marker_assignments_select
ON public.tournament_scorecard_marker_assignments
FOR SELECT TO authenticated
USING (public.puede_ver_score_card_captura(score_card_id));

DROP POLICY IF EXISTS tournament_scorecard_hole_scores_select
ON public.tournament_scorecard_hole_scores;
CREATE POLICY tournament_scorecard_hole_scores_select
ON public.tournament_scorecard_hole_scores
FOR SELECT TO authenticated
USING (public.puede_ver_score_card_captura(score_card_id));

DROP POLICY IF EXISTS tournament_scorecard_events_select
ON public.tournament_scorecard_events;
CREATE POLICY tournament_scorecard_events_select
ON public.tournament_scorecard_events
FOR SELECT TO authenticated
USING (public.puede_ver_score_card_captura(score_card_id));

REVOKE ALL ON TABLE public.tournament_scorecard_capture_sessions
    FROM anon, authenticated;
REVOKE ALL ON TABLE public.tournament_scorecard_marker_assignments
    FROM anon, authenticated;
REVOKE ALL ON TABLE public.tournament_scorecard_hole_scores
    FROM anon, authenticated;
REVOKE ALL ON TABLE public.tournament_scorecard_events
    FROM anon, authenticated;

GRANT SELECT ON TABLE public.tournament_scorecard_capture_sessions
    TO authenticated;
GRANT SELECT ON TABLE public.tournament_scorecard_marker_assignments
    TO authenticated;
GRANT SELECT ON TABLE public.tournament_scorecard_hole_scores
    TO authenticated;
GRANT SELECT ON TABLE public.tournament_scorecard_events
    TO authenticated;

-- ============================================================================
-- 9. INICIALIZACIÓN IDEMPOTENTE POR RONDA
-- ============================================================================

CREATE OR REPLACE FUNCTION public.inicializar_captura_scores_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tournament_id uuid;
    v_validation_id uuid;
    v_round_condition_snapshot_id uuid;
    v_emission_id uuid;
    v_admin_id uuid;
    v_card_count integer := 0;
    v_hole_count integer := 0;
    v_session_count integer := 0;
    v_hole_row_count integer := 0;
    v_assignment_count integer := 0;
    v_pending_marker_count integer := 0;
    v_bad_cards integer := 0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tr.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds tr
     WHERE tr.id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para inicializar la captura de scores de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    v_admin_id := public._scorecard_current_admin_id();

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    -- Serializa contra operaciones estructurales de la ronda.
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
        ON v.id = e.validation_id
       AND v.tournament_round_id = e.tournament_round_id
     WHERE e.tournament_round_id = p_tournament_round_id
       AND e.status = 'issued'
     LIMIT 1;

    IF v_emission_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda no tiene tarjetas oficiales emitidas.'
            USING ERRCODE = '23514',
                  HINT = 'Emite primero las tarjetas oficiales de la ronda.';
    END IF;

    SELECT
        count(*),
        count(*) FILTER (
            WHERE sc.unit_type <> 'registration'
               OR sc.player_id IS NULL
               OR sc.tournament_registration_id IS NULL
        )
      INTO v_card_count, v_bad_cards
      FROM public.tournament_score_cards sc
     WHERE sc.emission_id = v_emission_id
       AND sc.status = 'issued';

    IF v_card_count = 0 THEN
        RAISE EXCEPTION
            'La emisión activa no contiene tarjetas.'
            USING ERRCODE = '55000';
    END IF;

    IF v_bad_cards > 0 THEN
        RAISE EXCEPTION
            'La captura V1 sólo soporta tarjetas individuales de jugadores.'
            USING ERRCODE = '0A000',
                  DETAIL = format('tarjetas_no_soportadas=%s', v_bad_cards);
    END IF;

    SELECT count(*)
      INTO v_hole_count
      FROM public.tournament_round_hole_snapshots h
     WHERE h.round_condition_snapshot_id = v_round_condition_snapshot_id;

    IF v_hole_count = 0 THEN
        RAISE EXCEPTION
            'La ronda no tiene hoyos congelados para captura.'
            USING ERRCODE = '55000';
    END IF;

    -- 9.1 Sesiones, una por tarjeta.
    INSERT INTO public.tournament_scorecard_capture_sessions (
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
    WHERE sc.emission_id = v_emission_id
      AND sc.status = 'issued'
    ON CONFLICT (score_card_id) DO NOTHING;

    SELECT count(*)
      INTO v_session_count
      FROM public.tournament_scorecard_capture_sessions cs
      JOIN public.tournament_score_cards sc
        ON sc.id = cs.score_card_id
     WHERE sc.emission_id = v_emission_id
       AND sc.status = 'issued';

    -- 9.2 Filas de score por hoyo.
    -- El play_sequence parte del hoyo Shotgun congelado de cada tarjeta.
    INSERT INTO public.tournament_scorecard_hole_scores (
        capture_session_id,
        score_card_id,
        tournament_round_id,
        round_hole_snapshot_id,
        hole_number,
        play_sequence
    )
    SELECT
        cs.id,
        sc.id,
        sc.tournament_round_id,
        h.id,
        h.hole_number,
        row_number() OVER (
            PARTITION BY sc.id
            ORDER BY
                CASE
                    WHEN h.hole_number >= g.hole_number THEN 0
                    ELSE 1
                END,
                h.hole_number
        )::integer
    FROM public.tournament_score_cards sc
    JOIN public.tournament_scorecard_capture_sessions cs
      ON cs.score_card_id = sc.id
    JOIN public.tournament_round_start_validation_groups g
      ON g.id = sc.validation_group_id
     AND g.validation_id = sc.validation_id
    JOIN public.tournament_round_hole_snapshots h
      ON h.round_condition_snapshot_id = v_round_condition_snapshot_id
    WHERE sc.emission_id = v_emission_id
      AND sc.status = 'issued'
    ON CONFLICT (score_card_id, round_hole_snapshot_id) DO NOTHING;

    SELECT count(*)
      INTO v_hole_row_count
      FROM public.tournament_scorecard_hole_scores hs
      JOIN public.tournament_score_cards sc
        ON sc.id = hs.score_card_id
     WHERE sc.emission_id = v_emission_id
       AND sc.status = 'issued';

    IF v_hole_row_count <> v_card_count * v_hole_count THEN
        RAISE EXCEPTION
            'La inicialización de hoyos de captura quedó incompleta.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'filas_score=%s; esperadas=%s',
                      v_hole_row_count,
                      v_card_count * v_hole_count
                  );
    END IF;

    -- 9.3 Asignación circular por grupo validado.
    --
    -- Para tarjetas ordenadas A,B,C,D:
    -- target A <- marker D
    -- target B <- marker A
    -- target C <- marker B
    -- target D <- marker C
    --
    -- Grupos de 1 jugador quedan deliberadamente sin marcador y se reportan
    -- como pendientes; nunca se autoasigna al propio jugador.
    WITH group_cards AS (
        SELECT
            sc.validation_group_id,
            array_agg(sc.id ORDER BY u.order_in_group, sc.id) AS card_ids,
            array_agg(sc.player_id ORDER BY u.order_in_group, sc.id) AS player_ids,
            array_agg(
                sc.tournament_registration_id
                ORDER BY u.order_in_group, sc.id
            ) AS registration_ids
        FROM public.tournament_score_cards sc
        JOIN public.tournament_round_start_validation_units u
          ON u.id = sc.validation_unit_id
         AND u.validation_id = sc.validation_id
        WHERE sc.emission_id = v_emission_id
          AND sc.status = 'issued'
        GROUP BY sc.validation_group_id
    ),
    proposed AS (
        SELECT
            gc.validation_group_id,
            gc.card_ids[i] AS target_card_id,
            gc.card_ids[
                CASE
                    WHEN i = 1 THEN array_length(gc.card_ids, 1)
                    ELSE i - 1
                END
            ] AS marker_card_id,
            gc.player_ids[
                CASE
                    WHEN i = 1 THEN array_length(gc.player_ids, 1)
                    ELSE i - 1
                END
            ] AS marker_player_id,
            gc.registration_ids[
                CASE
                    WHEN i = 1 THEN array_length(gc.registration_ids, 1)
                    ELSE i - 1
                END
            ] AS marker_registration_id,
            array_length(gc.card_ids, 1) AS group_size
        FROM group_cards gc
        CROSS JOIN LATERAL generate_subscripts(gc.card_ids, 1) AS s(i)
    )
    INSERT INTO public.tournament_scorecard_marker_assignments (
        tournament_round_id,
        validation_group_id,
        score_card_id,
        marker_score_card_id,
        marker_player_id,
        marker_registration_id,
        assignment_source,
        valid_from_sequence,
        status,
        assigned_by
    )
    SELECT
        p_tournament_round_id,
        p.validation_group_id,
        p.target_card_id,
        p.marker_card_id,
        p.marker_player_id,
        p.marker_registration_id,
        'circular',
        1,
        'active',
        v_admin_id
    FROM proposed p
    WHERE p.group_size >= 2
      AND p.target_card_id <> p.marker_card_id
      AND NOT EXISTS (
          SELECT 1
          FROM public.tournament_scorecard_marker_assignments ma
          WHERE ma.score_card_id = p.target_card_id
            AND ma.status = 'active'
      );

    SELECT count(*)
      INTO v_assignment_count
      FROM public.tournament_scorecard_marker_assignments ma
      JOIN public.tournament_score_cards sc
        ON sc.id = ma.score_card_id
     WHERE sc.emission_id = v_emission_id
       AND ma.status = 'active';

    SELECT count(*)
      INTO v_pending_marker_count
      FROM public.tournament_score_cards sc
     WHERE sc.emission_id = v_emission_id
       AND sc.status = 'issued'
       AND NOT EXISTS (
           SELECT 1
           FROM public.tournament_scorecard_marker_assignments ma
           WHERE ma.score_card_id = sc.id
             AND ma.status = 'active'
       );

    RETURN jsonb_build_object(
        'tournamentRoundId', p_tournament_round_id,
        'initialized', true,
        'cardCount', v_card_count,
        'sessionCount', v_session_count,
        'holesPerCard', v_hole_count,
        'holeScoreRows', v_hole_row_count,
        'activeMarkerAssignments', v_assignment_count,
        'cardsWithoutMarker', v_pending_marker_count
    );
END;
$$;

-- ============================================================================
-- 10. CAMBIO ADMINISTRATIVO DE MARCADOR
-- ============================================================================

CREATE OR REPLACE FUNCTION public.asignar_marcador_tarjeta_score(
    p_score_card_id uuid,
    p_marker_score_card_id uuid,
    p_from_sequence integer,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_target record;
    v_marker record;
    v_admin_id uuid;
    v_old_assignment record;
    v_new_assignment_id uuid;
    v_holes_expected integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF p_from_sequence IS NULL OR p_from_sequence <= 0 THEN
        RAISE EXCEPTION
            'La secuencia inicial del marcador debe ser mayor que cero.'
            USING ERRCODE = '22023';
    END IF;

    IF length(btrim(COALESCE(p_reason, ''))) < 5 THEN
        RAISE EXCEPTION
            'El motivo del cambio de marcador debe tener al menos 5 caracteres.'
            USING ERRCODE = '22023';
    END IF;

    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.validation_group_id,
        sc.player_id,
        sc.tournament_registration_id,
        sc.status
      INTO v_target
      FROM public.tournament_score_cards sc
     WHERE sc.id = p_score_card_id;

    IF v_target.id IS NULL OR v_target.status <> 'issued' THEN
        RAISE EXCEPTION
            'La tarjeta objetivo no existe o no está emitida.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_target.tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para cambiar el marcador de esta tarjeta.'
            USING ERRCODE = '42501';
    END IF;

    v_admin_id := public._scorecard_current_admin_id();

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.validation_group_id,
        sc.player_id,
        sc.tournament_registration_id,
        sc.status
      INTO v_marker
      FROM public.tournament_score_cards sc
     WHERE sc.id = p_marker_score_card_id;

    IF v_marker.id IS NULL
       OR v_marker.status <> 'issued'
       OR v_marker.player_id IS NULL
       OR v_marker.tournament_registration_id IS NULL
    THEN
        RAISE EXCEPTION
            'La tarjeta del nuevo marcador no es válida.'
            USING ERRCODE = '22023';
    END IF;

    IF v_marker.id = v_target.id
       OR v_marker.player_id = v_target.player_id
    THEN
        RAISE EXCEPTION
            'Un jugador no puede actuar como marcador de su propia tarjeta.'
            USING ERRCODE = '23514';
    END IF;

    IF v_marker.tournament_round_id <> v_target.tournament_round_id THEN
        RAISE EXCEPTION
            'El nuevo marcador debe pertenecer a la misma ronda.'
            USING ERRCODE = '23514';
    END IF;

    SELECT cs.holes_expected
      INTO v_holes_expected
      FROM public.tournament_scorecard_capture_sessions cs
     WHERE cs.score_card_id = p_score_card_id;

    IF v_holes_expected IS NULL THEN
        RAISE EXCEPTION
            'La captura de esta ronda todavía no está inicializada.'
            USING ERRCODE = '55000';
    END IF;

    IF p_from_sequence > v_holes_expected THEN
        RAISE EXCEPTION
            'La secuencia inicial excede el número de hoyos de la tarjeta.'
            USING ERRCODE = '22023';
    END IF;

    -- No permitir que un cambio retroactivo reescriba hoyos ya capturados
    -- desde esa secuencia.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_scorecard_hole_scores hs
        WHERE hs.score_card_id = p_score_card_id
          AND hs.play_sequence >= p_from_sequence
          AND hs.gross_score IS NOT NULL
    ) THEN
        RAISE EXCEPTION
            'No puede cambiarse retroactivamente el marcador sobre hoyos ya capturados.'
            USING ERRCODE = '55000',
                  HINT = 'Use una secuencia posterior al último hoyo ya capturado.';
    END IF;

    SELECT ma.*
      INTO v_old_assignment
      FROM public.tournament_scorecard_marker_assignments ma
     WHERE ma.score_card_id = p_score_card_id
       AND ma.status = 'active'
     FOR UPDATE;

    IF v_old_assignment.id IS NOT NULL THEN
        UPDATE public.tournament_scorecard_marker_assignments
           SET status = 'ended',
               valid_to_sequence =
                   CASE
                       WHEN p_from_sequence > v_old_assignment.valid_from_sequence
                       THEN p_from_sequence - 1
                       ELSE NULL
                   END,
               ended_at = now(),
               change_reason = p_reason
         WHERE id = v_old_assignment.id;
    END IF;

    INSERT INTO public.tournament_scorecard_marker_assignments (
        tournament_round_id,
        validation_group_id,
        score_card_id,
        marker_score_card_id,
        marker_player_id,
        marker_registration_id,
        assignment_source,
        valid_from_sequence,
        status,
        assigned_by,
        change_reason
    )
    VALUES (
        v_target.tournament_round_id,
        v_target.validation_group_id,
        v_target.id,
        v_marker.id,
        v_marker.player_id,
        v_marker.tournament_registration_id,
        'admin',
        p_from_sequence,
        'active',
        v_admin_id,
        p_reason
    )
    RETURNING id INTO v_new_assignment_id;

    INSERT INTO public.tournament_scorecard_events (
        score_card_id,
        marker_assignment_id,
        event_type,
        actor_admin_user_id,
        reason
    )
    VALUES (
        v_target.id,
        v_new_assignment_id,
        'marker_changed',
        v_admin_id,
        p_reason
    );

    RETURN jsonb_build_object(
        'scoreCardId', v_target.id,
        'markerAssignmentId', v_new_assignment_id,
        'markerPlayerId', v_marker.player_id,
        'validFromSequence', p_from_sequence,
        'status', 'active'
    );
END;
$$;

-- ============================================================================
-- 11. APERTURA SEGURA POR QR
--
-- El token localiza la tarjeta. Después se exige relación autorizada:
-- dueño, marcador activo o administrador del torneo.
-- El token NO se devuelve en el payload.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.abrir_captura_tarjeta_score(
    p_qr_token text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_card record;
    v_player_id uuid;
    v_is_owner boolean := false;
    v_is_marker boolean := false;
    v_is_admin boolean := false;
    v_session record;
    v_active_marker record;
    v_result jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF length(btrim(COALESCE(p_qr_token, ''))) < 16 THEN
        RAISE EXCEPTION 'QR de tarjeta inválido.'
            USING ERRCODE = '22023';
    END IF;

    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.validation_id,
        sc.validation_group_id,
        sc.validation_unit_id,
        sc.player_id,
        sc.tournament_registration_id,
        sc.card_folio,
        sc.status,
        u.unit_name,
        g.group_label,
        g.hole_number AS start_hole_number,
        g.start_position,
        g.shift_number,
        g.start_at
      INTO v_card
      FROM public.tournament_score_cards sc
      JOIN public.tournament_round_start_validation_units u
        ON u.id = sc.validation_unit_id
       AND u.validation_id = sc.validation_id
      JOIN public.tournament_round_start_validation_groups g
        ON g.id = sc.validation_group_id
       AND g.validation_id = sc.validation_id
     WHERE sc.qr_token = p_qr_token
       AND sc.status = 'issued'
     LIMIT 1;

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION
            'No se encontró una tarjeta oficial vigente para este QR.'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
      INTO v_session
      FROM public.tournament_scorecard_capture_sessions cs
     WHERE cs.score_card_id = v_card.id;

    IF v_session.id IS NULL THEN
        RAISE EXCEPTION
            'La captura de scores de esta ronda todavía no está inicializada.'
            USING ERRCODE = '55000';
    END IF;

    v_player_id := public._scorecard_current_player_id();
    v_is_owner := v_player_id IS NOT NULL
                  AND v_player_id = v_card.player_id;

    SELECT
        ma.id,
        ma.marker_player_id,
        mu.unit_name AS marker_name,
        ma.valid_from_sequence
      INTO v_active_marker
      FROM public.tournament_scorecard_marker_assignments ma
      JOIN public.tournament_score_cards msc
        ON msc.id = ma.marker_score_card_id
      JOIN public.tournament_round_start_validation_units mu
        ON mu.id = msc.validation_unit_id
       AND mu.validation_id = msc.validation_id
     WHERE ma.score_card_id = v_card.id
       AND ma.status = 'active'
     LIMIT 1;

    v_is_marker := v_player_id IS NOT NULL
                   AND v_active_marker.marker_player_id = v_player_id;

    v_is_admin :=
        public.puede_administrar_congelamiento_torneo(v_card.tournament_id);

    IF NOT (v_is_owner OR v_is_marker OR v_is_admin) THEN
        RAISE EXCEPTION
            'No tienes permiso para abrir esta tarjeta de score.'
            USING ERRCODE = '42501';
    END IF;

    SELECT jsonb_build_object(
        'scoreCard', jsonb_build_object(
            'id', v_card.id,
            'folio', v_card.card_folio,
            'playerName', v_card.unit_name,
            'tournamentRoundId', v_card.tournament_round_id,
            'groupLabel', v_card.group_label,
            'startHoleNumber', v_card.start_hole_number,
            'startPosition', v_card.start_position,
            'shiftNumber', v_card.shift_number,
            'startAt', v_card.start_at
        ),
        'access', jsonb_build_object(
            'isOwner', v_is_owner,
            'isMarker', v_is_marker,
            'isAdmin', v_is_admin,
            'canCapture', v_is_marker,
            'canConfirmOrDispute', v_is_owner
        ),
        'marker', CASE
            WHEN v_active_marker.id IS NULL THEN NULL
            ELSE jsonb_build_object(
                'displayName', v_active_marker.marker_name,
                'validFromSequence', v_active_marker.valid_from_sequence
            )
        END,
        'capture', jsonb_build_object(
            'status', v_session.status,
            'holesExpected', v_session.holes_expected,
            'startedAt', v_session.started_at,
            'capturedAt', v_session.captured_at
        ),
        'holes', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'holeScoreId', hs.id,
                    'roundHoleSnapshotId', hs.round_hole_snapshot_id,
                    'holeNumber', hs.hole_number,
                    'playSequence', hs.play_sequence,
                    'par', rh.par,
                    'strokeIndex', rh.stroke_index,
                    'grossScore', hs.gross_score,
                    'status', hs.status,
                    'playerClaimedGrossScore',
                        CASE
                            WHEN v_is_owner OR v_is_marker OR v_is_admin
                            THEN hs.player_claimed_gross_score
                            ELSE NULL
                        END,
                    'disputeNote',
                        CASE
                            WHEN v_is_owner OR v_is_marker OR v_is_admin
                            THEN hs.dispute_note
                            ELSE NULL
                        END,
                    'canCapture',
                        v_is_marker
                        AND hs.status IN ('pending', 'entered', 'disputed'),
                    'canConfirm',
                        v_is_owner
                        AND hs.status = 'entered',
                    'canDispute',
                        v_is_owner
                        AND hs.status = 'entered'
                )
                ORDER BY hs.play_sequence
            )
            FROM public.tournament_scorecard_hole_scores hs
            JOIN public.tournament_round_hole_snapshots rh
              ON rh.id = hs.round_hole_snapshot_id
            WHERE hs.score_card_id = v_card.id
        ), '[]'::jsonb)
    )
      INTO v_result;

    RETURN v_result;
END;
$$;

-- ============================================================================
-- 12. PANEL DEL JUGADOR POR RONDA
--
-- Permite a la PWA saber:
-- - cuál es MI tarjeta;
-- - qué tarjeta(s) tengo asignadas como marcador.
-- No expone QR.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_mi_panel_scores_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_player_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    v_player_id := public._scorecard_current_player_id();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no está vinculado a un jugador activo.'
            USING ERRCODE = '42501';
    END IF;

    RETURN jsonb_build_object(
        'tournamentRoundId', p_tournament_round_id,
        'myCard', (
            SELECT jsonb_build_object(
                'scoreCardId', sc.id,
                'folio', sc.card_folio,
                'playerName', u.unit_name,
                'captureStatus', cs.status,
                'holesExpected', cs.holes_expected,
                'holesEntered', (
                    SELECT count(*)
                    FROM public.tournament_scorecard_hole_scores hs
                    WHERE hs.score_card_id = sc.id
                      AND hs.gross_score IS NOT NULL
                ),
                'holesConfirmed', (
                    SELECT count(*)
                    FROM public.tournament_scorecard_hole_scores hs
                    WHERE hs.score_card_id = sc.id
                      AND hs.status = 'confirmed'
                ),
                'holesDisputed', (
                    SELECT count(*)
                    FROM public.tournament_scorecard_hole_scores hs
                    WHERE hs.score_card_id = sc.id
                      AND hs.status = 'disputed'
                )
            )
            FROM public.tournament_score_cards sc
            JOIN public.tournament_round_start_validation_units u
              ON u.id = sc.validation_unit_id
             AND u.validation_id = sc.validation_id
            LEFT JOIN public.tournament_scorecard_capture_sessions cs
              ON cs.score_card_id = sc.id
            WHERE sc.tournament_round_id = p_tournament_round_id
              AND sc.player_id = v_player_id
              AND sc.status = 'issued'
            LIMIT 1
        ),
        'cardsIMark', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'scoreCardId', sc.id,
                    'folio', sc.card_folio,
                    'playerName', u.unit_name,
                    'validFromSequence', ma.valid_from_sequence,
                    'captureStatus', cs.status,
                    'holesExpected', cs.holes_expected,
                    'holesEntered', (
                        SELECT count(*)
                        FROM public.tournament_scorecard_hole_scores hs
                        WHERE hs.score_card_id = sc.id
                          AND hs.gross_score IS NOT NULL
                    )
                )
                ORDER BY sc.card_number
            )
            FROM public.tournament_scorecard_marker_assignments ma
            JOIN public.tournament_score_cards sc
              ON sc.id = ma.score_card_id
            JOIN public.tournament_round_start_validation_units u
              ON u.id = sc.validation_unit_id
             AND u.validation_id = sc.validation_id
            LEFT JOIN public.tournament_scorecard_capture_sessions cs
              ON cs.score_card_id = sc.id
            WHERE ma.tournament_round_id = p_tournament_round_id
              AND ma.marker_player_id = v_player_id
              AND ma.status = 'active'
              AND sc.status = 'issued'
        ), '[]'::jsonb)
    );
END;
$$;

-- ============================================================================
-- 13. CAPTURA / CORRECCIÓN DE GROSS POR MARCADOR
-- ============================================================================

CREATE OR REPLACE FUNCTION public.registrar_score_hoyo(
    p_score_card_id uuid,
    p_round_hole_snapshot_id uuid,
    p_gross_score integer
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_player_id uuid;
    v_card record;
    v_hole record;
    v_assignment record;
    v_old_gross integer;
    v_event_type text;
    v_remaining integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF p_gross_score IS NULL OR p_gross_score <= 0 THEN
        RAISE EXCEPTION
            'El score gross debe ser un entero mayor que cero.'
            USING ERRCODE = '22023';
    END IF;

    v_player_id := public._scorecard_current_player_id();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no está vinculado a un jugador activo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT sc.*
      INTO v_card
      FROM public.tournament_score_cards sc
     WHERE sc.id = p_score_card_id
       AND sc.status = 'issued';

    IF v_card.id IS NULL THEN
        RAISE EXCEPTION 'Tarjeta oficial no encontrada.'
            USING ERRCODE = '22023';
    END IF;

    IF v_card.player_id = v_player_id THEN
        RAISE EXCEPTION
            'No puedes capturar tu propio score.'
            USING ERRCODE = '42501';
    END IF;

    SELECT hs.*
      INTO v_hole
      FROM public.tournament_scorecard_hole_scores hs
     WHERE hs.score_card_id = p_score_card_id
       AND hs.round_hole_snapshot_id = p_round_hole_snapshot_id
     FOR UPDATE;

    IF v_hole.id IS NULL THEN
        RAISE EXCEPTION
            'El hoyo indicado no pertenece a la captura de esta tarjeta.'
            USING ERRCODE = '22023';
    END IF;

    SELECT ma.*
      INTO v_assignment
      FROM public.tournament_scorecard_marker_assignments ma
     WHERE ma.score_card_id = p_score_card_id
       AND ma.marker_player_id = v_player_id
       AND ma.status = 'active'
       AND ma.valid_from_sequence <= v_hole.play_sequence
     LIMIT 1;

    IF v_assignment.id IS NULL THEN
        RAISE EXCEPTION
            'No eres el marcador vigente de esta tarjeta para este hoyo.'
            USING ERRCODE = '42501';
    END IF;

    IF v_hole.status = 'confirmed' THEN
        RAISE EXCEPTION
            'El jugador ya confirmó este hoyo y el marcador no puede modificarlo.'
            USING ERRCODE = '55000',
                  HINT = 'Las correcciones posteriores requerirán el flujo del Comité.';
    END IF;

    v_old_gross := v_hole.gross_score;
    v_event_type :=
        CASE
            WHEN v_old_gross IS NULL THEN 'score_entered'
            ELSE 'score_corrected'
        END;

    UPDATE public.tournament_scorecard_hole_scores
       SET gross_score = p_gross_score,
           status = 'entered',
           marker_assignment_id = v_assignment.id,
           entered_by_player_id = v_player_id,
           entered_at = now(),
           confirmed_by_player_id = NULL,
           confirmed_at = NULL,
           player_claimed_gross_score = NULL,
           dispute_note = NULL,
           disputed_at = NULL
     WHERE id = v_hole.id;

    INSERT INTO public.tournament_scorecard_events (
        score_card_id,
        hole_score_id,
        marker_assignment_id,
        event_type,
        actor_player_id,
        old_gross_score,
        new_gross_score
    )
    VALUES (
        p_score_card_id,
        v_hole.id,
        v_assignment.id,
        v_event_type,
        v_player_id,
        v_old_gross,
        p_gross_score
    );

    UPDATE public.tournament_scorecard_capture_sessions
       SET status =
               CASE
                   WHEN status = 'ready' THEN 'in_progress'
                   ELSE status
               END,
           started_at = COALESCE(started_at, now())
     WHERE score_card_id = p_score_card_id;

    SELECT count(*)
      INTO v_remaining
      FROM public.tournament_scorecard_hole_scores hs
     WHERE hs.score_card_id = p_score_card_id
       AND hs.gross_score IS NULL;

    IF v_remaining = 0 THEN
        UPDATE public.tournament_scorecard_capture_sessions
           SET status = 'captured',
               started_at = COALESCE(started_at, now()),
               captured_at = COALESCE(captured_at, now())
         WHERE score_card_id = p_score_card_id;
    END IF;

    RETURN jsonb_build_object(
        'holeScoreId', v_hole.id,
        'scoreCardId', p_score_card_id,
        'holeNumber', v_hole.hole_number,
        'playSequence', v_hole.play_sequence,
        'grossScore', p_gross_score,
        'status', 'entered'
    );
END;
$$;

-- ============================================================================
-- 14. CONFIRMACIÓN POR DUEÑO DE TARJETA
-- ============================================================================

CREATE OR REPLACE FUNCTION public.confirmar_score_hoyo(
    p_hole_score_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_player_id uuid;
    v_hole record;
    v_owner_player_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    v_player_id := public._scorecard_current_player_id();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no está vinculado a un jugador activo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT hs.*, sc.player_id AS owner_player_id
      INTO v_hole
      FROM public.tournament_scorecard_hole_scores hs
      JOIN public.tournament_score_cards sc
        ON sc.id = hs.score_card_id
       AND sc.status = 'issued'
     WHERE hs.id = p_hole_score_id
     FOR UPDATE OF hs;

    IF v_hole.id IS NULL THEN
        RAISE EXCEPTION 'Score de hoyo no encontrado.'
            USING ERRCODE = '22023';
    END IF;

    v_owner_player_id := v_hole.owner_player_id;

    IF v_owner_player_id <> v_player_id THEN
        RAISE EXCEPTION
            'Sólo el dueño de la tarjeta puede confirmar este score.'
            USING ERRCODE = '42501';
    END IF;

    IF v_hole.status <> 'entered' OR v_hole.gross_score IS NULL THEN
        RAISE EXCEPTION
            'Este hoyo no está disponible para confirmación.'
            USING ERRCODE = '55000';
    END IF;

    UPDATE public.tournament_scorecard_hole_scores
       SET status = 'confirmed',
           confirmed_by_player_id = v_player_id,
           confirmed_at = now()
     WHERE id = p_hole_score_id;

    INSERT INTO public.tournament_scorecard_events (
        score_card_id,
        hole_score_id,
        marker_assignment_id,
        event_type,
        actor_player_id,
        old_gross_score,
        new_gross_score
    )
    VALUES (
        v_hole.score_card_id,
        v_hole.id,
        v_hole.marker_assignment_id,
        'player_confirmed',
        v_player_id,
        v_hole.gross_score,
        v_hole.gross_score
    );

    RETURN jsonb_build_object(
        'holeScoreId', v_hole.id,
        'scoreCardId', v_hole.score_card_id,
        'holeNumber', v_hole.hole_number,
        'grossScore', v_hole.gross_score,
        'status', 'confirmed'
    );
END;
$$;

-- ============================================================================
-- 15. DISPUTA POR DUEÑO DE TARJETA
-- ============================================================================

CREATE OR REPLACE FUNCTION public.disputar_score_hoyo(
    p_hole_score_id uuid,
    p_claimed_gross_score integer,
    p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_player_id uuid;
    v_hole record;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF p_claimed_gross_score IS NULL OR p_claimed_gross_score <= 0 THEN
        RAISE EXCEPTION
            'El score que propones debe ser un entero mayor que cero.'
            USING ERRCODE = '22023';
    END IF;

    v_player_id := public._scorecard_current_player_id();

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no está vinculado a un jugador activo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT hs.*, sc.player_id AS owner_player_id
      INTO v_hole
      FROM public.tournament_scorecard_hole_scores hs
      JOIN public.tournament_score_cards sc
        ON sc.id = hs.score_card_id
       AND sc.status = 'issued'
     WHERE hs.id = p_hole_score_id
     FOR UPDATE OF hs;

    IF v_hole.id IS NULL THEN
        RAISE EXCEPTION 'Score de hoyo no encontrado.'
            USING ERRCODE = '22023';
    END IF;

    IF v_hole.owner_player_id <> v_player_id THEN
        RAISE EXCEPTION
            'Sólo el dueño de la tarjeta puede disputar este score.'
            USING ERRCODE = '42501';
    END IF;

    IF v_hole.status <> 'entered' OR v_hole.gross_score IS NULL THEN
        RAISE EXCEPTION
            'Este hoyo no está disponible para disputa.'
            USING ERRCODE = '55000';
    END IF;

    IF p_claimed_gross_score = v_hole.gross_score THEN
        RAISE EXCEPTION
            'El score indicado coincide con el score capturado; puedes confirmarlo.'
            USING ERRCODE = '22023';
    END IF;

    UPDATE public.tournament_scorecard_hole_scores
       SET status = 'disputed',
           player_claimed_gross_score = p_claimed_gross_score,
           dispute_note = NULLIF(btrim(COALESCE(p_reason, '')), ''),
           disputed_at = now(),
           confirmed_by_player_id = NULL,
           confirmed_at = NULL
     WHERE id = p_hole_score_id;

    INSERT INTO public.tournament_scorecard_events (
        score_card_id,
        hole_score_id,
        marker_assignment_id,
        event_type,
        actor_player_id,
        old_gross_score,
        new_gross_score,
        claimed_gross_score,
        reason
    )
    VALUES (
        v_hole.score_card_id,
        v_hole.id,
        v_hole.marker_assignment_id,
        'player_disputed',
        v_player_id,
        v_hole.gross_score,
        v_hole.gross_score,
        p_claimed_gross_score,
        NULLIF(btrim(COALESCE(p_reason, '')), '')
    );

    RETURN jsonb_build_object(
        'holeScoreId', v_hole.id,
        'scoreCardId', v_hole.score_card_id,
        'holeNumber', v_hole.hole_number,
        'grossScore', v_hole.gross_score,
        'playerClaimedGrossScore', p_claimed_gross_score,
        'status', 'disputed'
    );
END;
$$;

-- ============================================================================
-- 16. PRIVILEGIOS DE FUNCIONES
-- ============================================================================

-- Helpers internos: no invocables directamente por clientes.
REVOKE ALL ON FUNCTION public._impedir_mutacion_evento_scorecard()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._scorecard_current_player_id()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._scorecard_current_admin_id()
    FROM PUBLIC, anon, authenticated;

-- Helper booleano requerido por políticas SELECT.
REVOKE ALL ON FUNCTION public.puede_ver_score_card_captura(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.puede_ver_score_card_captura(uuid)
    TO authenticated;

-- RPC públicas autenticadas.
REVOKE ALL ON FUNCTION public.inicializar_captura_scores_ronda(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.inicializar_captura_scores_ronda(uuid)
    TO authenticated;

REVOKE ALL ON FUNCTION public.asignar_marcador_tarjeta_score(uuid,uuid,integer,text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.asignar_marcador_tarjeta_score(uuid,uuid,integer,text)
    TO authenticated;

REVOKE ALL ON FUNCTION public.abrir_captura_tarjeta_score(text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.abrir_captura_tarjeta_score(text)
    TO authenticated;

REVOKE ALL ON FUNCTION public.obtener_mi_panel_scores_ronda(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_mi_panel_scores_ronda(uuid)
    TO authenticated;

REVOKE ALL ON FUNCTION public.registrar_score_hoyo(uuid,uuid,integer)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_score_hoyo(uuid,uuid,integer)
    TO authenticated;

REVOKE ALL ON FUNCTION public.confirmar_score_hoyo(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.confirmar_score_hoyo(uuid)
    TO authenticated;

REVOKE ALL ON FUNCTION public.disputar_score_hoyo(uuid,integer,text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.disputar_score_hoyo(uuid,integer,text)
    TO authenticated;

COMMIT;
