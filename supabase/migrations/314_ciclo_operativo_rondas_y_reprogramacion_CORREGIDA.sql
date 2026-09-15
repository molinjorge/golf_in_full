-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 314
-- Ciclo operativo obligatorio por ronda + reprogramación controlada de fecha
-- ============================================================================
-- REGLAS:
-- 1) Todas las rondas, incluso en torneos de una sola ronda, siguen:
--      PENDIENTE -> EN_JUEGO -> FINALIZADA
-- 2) INICIAR TORNEO no inicia automáticamente la primera ronda.
-- 3) No puede iniciarse la ronda N si una ronda anterior activa no finalizó.
-- 4) Sólo puede existir una ronda EN_JUEGO por torneo.
-- 5) Captura competitiva requiere torneo EN_CURSO y ronda EN_JUEGO.
-- 6) El cierre formal existente de ronda marca FINALIZADA.
-- 7) La fecha de una ronda puede cambiar sólo mientras está PENDIENTE.
-- 8) Nueva fecha >= fecha_inicio del torneo.
-- 9) Nueva fecha >= fecha de la última ronda FINALIZADA, si existe.
-- 10) Freeze, validación de salidas y tarjetas emitidas no bloquean por sí
--     mismos la reprogramación.
-- 11) Los snapshots congelados NO se modifican.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- A. Ciclo operativo por ronda
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_round_lifecycle (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL REFERENCES public.tournaments(id),
    tournament_round_id uuid NOT NULL UNIQUE REFERENCES public.tournament_rounds(id),
    started_at timestamptz,
    started_by_admin_user_id uuid REFERENCES public.admin_users(id),
    completed_at timestamptz,
    completed_by_admin_user_id uuid REFERENCES public.admin_users(id),
    start_source text,
    completion_source text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_round_lifecycle_dates_chk
        CHECK (
            completed_at IS NULL
            OR (
                started_at IS NOT NULL
                AND completed_at >= started_at
            )
        )
);

CREATE INDEX IF NOT EXISTS idx_tournament_round_lifecycle_tournament
ON public.tournament_round_lifecycle(tournament_id, tournament_round_id);

ALTER TABLE public.tournament_round_lifecycle ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.tournament_round_lifecycle
FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE
ON public.tournament_round_lifecycle
TO service_role;


CREATE OR REPLACE FUNCTION public._ensure_round_lifecycle_314()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO public.tournament_round_lifecycle(
        tournament_id,
        tournament_round_id
    )
    VALUES (
        NEW.tournament_id,
        NEW.id
    )
    ON CONFLICT (tournament_round_id) DO NOTHING;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ensure_round_lifecycle_314
ON public.tournament_rounds;

CREATE TRIGGER trg_ensure_round_lifecycle_314
AFTER INSERT
ON public.tournament_rounds
FOR EACH ROW
EXECUTE FUNCTION public._ensure_round_lifecycle_314();


-- Backfill histórico.
-- Cierre formal existente = FINALIZADA.
-- Evidencia competitiva sin cierre formal = EN_JUEGO histórico.
WITH activity AS (
    SELECT
        tournament_round_id,
        min(activity_at) AS first_activity_at
    FROM (
        SELECT
            hs.tournament_round_id,
            min(COALESCE(hs.entered_at, hs.created_at)) AS activity_at
        FROM public.tournament_scorecard_hole_scores hs
        WHERE hs.result_type IN ('SCORE','PICKUP')
          AND (
                hs.gross_score IS NOT NULL
                OR hs.result_type = 'PICKUP'
              )
        GROUP BY hs.tournament_round_id

        UNION ALL

        SELECT
            phs.tournament_round_id,
            min(phs.captured_at) AS activity_at
        FROM public.tournament_scorecard_physical_hole_scores phs
        WHERE phs.physical_result_type IN ('SCORE','PICKUP')
          AND (
                phs.physical_gross_score IS NOT NULL
                OR phs.physical_result_type = 'PICKUP'
              )
        GROUP BY phs.tournament_round_id

        UNION ALL

        SELECT
            o.tournament_round_id,
            min(COALESCE(o.effective_at, o.created_at)) AS activity_at
        FROM public.tournament_scorecard_round_outcomes o
        GROUP BY o.tournament_round_id
    ) x
    GROUP BY tournament_round_id
)
INSERT INTO public.tournament_round_lifecycle(
    tournament_id,
    tournament_round_id,
    started_at,
    started_by_admin_user_id,
    completed_at,
    completed_by_admin_user_id,
    start_source,
    completion_source
)
SELECT
    tr.tournament_id,
    tr.id,
    CASE
        WHEN c.id IS NOT NULL
            THEN COALESCE(a.first_activity_at, c.closed_at)
        ELSE a.first_activity_at
    END,
    NULL,
    c.closed_at,
    c.closed_by_admin_user_id,
    CASE
        WHEN c.id IS NOT NULL OR a.first_activity_at IS NOT NULL
            THEN 'LEGACY_BACKFILL'
        ELSE NULL
    END,
    CASE
        WHEN c.id IS NOT NULL THEN 'FORMAL_CLOSE_BACKFILL'
        ELSE NULL
    END
FROM public.tournament_rounds tr
LEFT JOIN activity a
  ON a.tournament_round_id = tr.id
LEFT JOIN public.tournament_round_competitive_closures c
  ON c.tournament_round_id = tr.id
ON CONFLICT (tournament_round_id) DO NOTHING;


CREATE OR REPLACE FUNCTION public._round_operational_status_314(
    p_tournament_round_id uuid
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT
        CASE
            WHEN l.completed_at IS NOT NULL THEN 'FINALIZADA'
            WHEN l.started_at IS NOT NULL THEN 'EN_JUEGO'
            ELSE 'PENDIENTE'
        END
    FROM public.tournament_round_lifecycle l
    WHERE l.tournament_round_id = p_tournament_round_id;
$$;

REVOKE ALL
ON FUNCTION public._round_operational_status_314(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._round_operational_status_314(uuid)
TO service_role;


CREATE OR REPLACE FUNCTION public.obtener_estado_operativo_ronda_314(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_round public.tournament_rounds%ROWTYPE;
    v_lifecycle public.tournament_round_lifecycle%ROWTYPE;
    v_tournament_status text;
    v_status text;
    v_previous_pending integer := 0;
    v_other_open integer := 0;
    v_can_start boolean := false;
    v_start_block_reason text := NULL;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_round
      FROM public.tournament_rounds
     WHERE id = p_tournament_round_id;

    IF v_round.id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    SELECT t.estatus::text
      INTO v_tournament_status
      FROM public.tournaments t
     WHERE t.id = v_round.tournament_id;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(
            auth.uid(),
            v_round.tournament_id
        )
        OR public.puede_administrar_congelamiento_torneo(
            v_round.tournament_id
        )
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar esta ronda.'
            USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_lifecycle
      FROM public.tournament_round_lifecycle
     WHERE tournament_round_id = p_tournament_round_id;

    v_status :=
        CASE
            WHEN v_lifecycle.completed_at IS NOT NULL THEN 'FINALIZADA'
            WHEN v_lifecycle.started_at IS NOT NULL THEN 'EN_JUEGO'
            ELSE 'PENDIENTE'
        END;

    IF v_status = 'PENDIENTE' THEN
        SELECT count(*)::integer
          INTO v_previous_pending
          FROM public.tournament_rounds prev
          LEFT JOIN public.tournament_round_lifecycle l
            ON l.tournament_round_id = prev.id
         WHERE prev.tournament_id = v_round.tournament_id
           AND prev.activo = true
           AND prev.numero_ronda < v_round.numero_ronda
           AND l.completed_at IS NULL;

        SELECT count(*)::integer
          INTO v_other_open
          FROM public.tournament_round_lifecycle l
          JOIN public.tournament_rounds tr
            ON tr.id = l.tournament_round_id
         WHERE l.tournament_id = v_round.tournament_id
           AND tr.activo = true
           AND l.started_at IS NOT NULL
           AND l.completed_at IS NULL
           AND l.tournament_round_id <> v_round.id;

        IF v_tournament_status <> 'en_curso' THEN
            v_start_block_reason :=
                'Primero debe iniciarse formalmente el torneo.';
        ELSIF v_other_open > 0 THEN
            v_start_block_reason :=
                'Existe otra ronda EN JUEGO que debe finalizarse primero.';
        ELSIF v_previous_pending > 0 THEN
            v_start_block_reason :=
                'Existe una ronda anterior que todavía no ha finalizado.';
        END IF;

        v_can_start := v_start_block_reason IS NULL;
    END IF;

    RETURN jsonb_build_object(
        'tournamentId', v_round.tournament_id,
        'tournamentRoundId', v_round.id,
        'roundNumber', v_round.numero_ronda,
        'roundDate', v_round.fecha,
        'status', v_status,
        'startedAt', v_lifecycle.started_at,
        'startedByAdminUserId', v_lifecycle.started_by_admin_user_id,
        'completedAt', v_lifecycle.completed_at,
        'completedByAdminUserId', v_lifecycle.completed_by_admin_user_id,
        'canStart', v_can_start,
        'startBlockReason', v_start_block_reason,
        'canReprogramDate', v_status = 'PENDIENTE'
    );
END;
$$;

REVOKE ALL
ON FUNCTION public.obtener_estado_operativo_ronda_314(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.obtener_estado_operativo_ronda_314(uuid)
TO authenticated, service_role;


-- --------------------------------------------------------------------------
-- B. Inicio manual obligatorio de ronda
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.iniciar_ronda_314(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_round public.tournament_rounds%ROWTYPE;
    v_tournament public.tournaments%ROWTYPE;
    v_lifecycle public.tournament_round_lifecycle%ROWTYPE;
    v_admin_id uuid;
    v_previous_pending integer;
    v_other_open integer;
    v_validation_state jsonb;
    v_emission_state jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_round
      FROM public.tournament_rounds
     WHERE id = p_tournament_round_id
       AND activo = true
     FOR UPDATE;

    IF v_round.id IS NULL THEN
        RAISE EXCEPTION
            'La ronda indicada no existe o no está activa.'
            USING ERRCODE='22023';
    END IF;

    SELECT *
      INTO v_tournament
      FROM public.tournaments
     WHERE id = v_round.tournament_id
     FOR UPDATE;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(
            auth.uid(),
            v_round.tournament_id
        )
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden iniciar la ronda.'
            USING ERRCODE='42501';
    END IF;

    IF v_tournament.estatus <> 'en_curso'::public.estatus_torneo THEN
        RAISE EXCEPTION
            'Primero debes INICIAR TORNEO. Estado actual: %.',
            v_tournament.estatus
            USING ERRCODE='23514';
    END IF;

    INSERT INTO public.tournament_round_lifecycle(
        tournament_id,
        tournament_round_id
    )
    VALUES (
        v_round.tournament_id,
        v_round.id
    )
    ON CONFLICT (tournament_round_id) DO NOTHING;

    SELECT *
      INTO v_lifecycle
      FROM public.tournament_round_lifecycle
     WHERE tournament_round_id = v_round.id
     FOR UPDATE;

    IF v_lifecycle.completed_at IS NOT NULL THEN
        RETURN public.obtener_estado_operativo_ronda_314(v_round.id);
    END IF;

    IF v_lifecycle.started_at IS NOT NULL THEN
        RETURN public.obtener_estado_operativo_ronda_314(v_round.id);
    END IF;

    SELECT count(*)::integer
      INTO v_other_open
      FROM public.tournament_round_lifecycle l
      JOIN public.tournament_rounds tr
        ON tr.id = l.tournament_round_id
     WHERE l.tournament_id = v_round.tournament_id
       AND tr.activo = true
       AND l.started_at IS NOT NULL
       AND l.completed_at IS NULL
       AND l.tournament_round_id <> v_round.id;

    IF v_other_open > 0 THEN
        RAISE EXCEPTION
            'Ya existe otra ronda EN JUEGO en este torneo.'
            USING ERRCODE='23514',
                  HINT='Finaliza la ronda actualmente iniciada antes de iniciar otra.';
    END IF;

    SELECT count(*)::integer
      INTO v_previous_pending
      FROM public.tournament_rounds prev
      LEFT JOIN public.tournament_round_lifecycle l
        ON l.tournament_round_id = prev.id
     WHERE prev.tournament_id = v_round.tournament_id
       AND prev.activo = true
       AND prev.numero_ronda < v_round.numero_ronda
       AND l.completed_at IS NULL;

    IF v_previous_pending > 0 THEN
        RAISE EXCEPTION
            'No puedes iniciar la ronda % mientras exista una ronda anterior sin finalizar.',
            v_round.numero_ronda
            USING ERRCODE='23514';
    END IF;

    -- Preparación mínima operativa: salidas validadas y tarjetas emitidas.
    v_validation_state :=
        public.obtener_estado_validacion_salidas_ronda(v_round.id);

    IF NOT COALESCE(
        (v_validation_state->>'validated')::boolean,
        false
    ) THEN
        RAISE EXCEPTION
            'No puedes iniciar la ronda porque sus salidas aún no están validadas.'
            USING ERRCODE='23514';
    END IF;

    v_emission_state :=
        public.obtener_estado_emision_tarjetas_ronda(v_round.id);

    IF NOT COALESCE(
        (v_emission_state->>'issued')::boolean,
        false
    ) THEN
        RAISE EXCEPTION
            'No puedes iniciar la ronda porque sus tarjetas oficiales aún no han sido emitidas.'
            USING ERRCODE='23514';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo = true
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No se encontró el usuario administrativo autenticado.'
            USING ERRCODE='42501';
    END IF;

    UPDATE public.tournament_round_lifecycle
       SET started_at = now(),
           started_by_admin_user_id = v_admin_id,
           start_source = 'MANUAL',
           updated_at = now()
     WHERE tournament_round_id = v_round.id;

    RETURN public.obtener_estado_operativo_ronda_314(v_round.id);
END;
$$;

REVOKE ALL
ON FUNCTION public.iniciar_ronda_314(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.iniciar_ronda_314(uuid)
TO authenticated, service_role;


-- --------------------------------------------------------------------------
-- C. El cierre formal existente marca FINALIZADA
-- --------------------------------------------------------------------------

ALTER FUNCTION public.cerrar_ronda_competitiva(uuid,text)
RENAME TO _cerrar_ronda_competitiva_pre314;

REVOKE ALL
ON FUNCTION public._cerrar_ronda_competitiva_pre314(uuid,text)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._cerrar_ronda_competitiva_pre314(uuid,text)
TO service_role;


CREATE FUNCTION public.cerrar_ronda_competitiva(
    p_tournament_round_id uuid,
    p_notas text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_round public.tournament_rounds%ROWTYPE;
    v_lifecycle public.tournament_round_lifecycle%ROWTYPE;
    v_result jsonb;
    v_admin_id uuid;
BEGIN
    SELECT *
      INTO v_round
      FROM public.tournament_rounds
     WHERE id = p_tournament_round_id
       AND activo = true;

    IF v_round.id IS NULL THEN
        RAISE EXCEPTION
            'La ronda indicada no existe o no está activa.'
            USING ERRCODE='22023';
    END IF;

    INSERT INTO public.tournament_round_lifecycle(
        tournament_id,
        tournament_round_id
    )
    VALUES (
        v_round.tournament_id,
        v_round.id
    )
    ON CONFLICT (tournament_round_id) DO NOTHING;

    SELECT *
      INTO v_lifecycle
      FROM public.tournament_round_lifecycle
     WHERE tournament_round_id = v_round.id
     FOR UPDATE;

    IF v_lifecycle.started_at IS NULL THEN
        RAISE EXCEPTION
            'La ronda debe estar EN JUEGO antes de poder finalizarse.'
            USING ERRCODE='23514',
                  HINT='Ejecuta primero INICIAR RONDA.';
    END IF;

    v_result :=
        public._cerrar_ronda_competitiva_pre314(
            p_tournament_round_id,
            p_notas
        );

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo = true
     ORDER BY au.id
     LIMIT 1;

    UPDATE public.tournament_round_lifecycle
       SET completed_at = COALESCE(completed_at, now()),
           completed_by_admin_user_id =
               COALESCE(completed_by_admin_user_id, v_admin_id),
           completion_source =
               COALESCE(completion_source, 'FORMAL_CLOSE'),
           updated_at = now()
     WHERE tournament_round_id = v_round.id;

    RETURN v_result;
END;
$$;

REVOKE ALL
ON FUNCTION public.cerrar_ronda_competitiva(uuid,text)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.cerrar_ronda_competitiva(uuid,text)
TO authenticated, service_role;


-- --------------------------------------------------------------------------
-- D. Captura competitiva exige ronda EN_JUEGO
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._exigir_torneo_en_curso_scorecard_256(
    p_score_card_id uuid,
    p_contexto text DEFAULT 'operación competitiva'::text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tournament_id uuid;
    v_tournament_round_id uuid;
    v_status public.estatus_torneo;
    v_round_status text;
BEGIN
    SELECT
        sc.tournament_id,
        sc.tournament_round_id,
        t.estatus
      INTO
        v_tournament_id,
        v_tournament_round_id,
        v_status
      FROM public.tournament_score_cards sc
      JOIN public.tournaments t
        ON t.id = sc.tournament_id
     WHERE sc.id = p_score_card_id
     LIMIT 1;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La tarjeta indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF v_status <> 'en_curso'::public.estatus_torneo THEN
        RAISE EXCEPTION
            'No se puede realizar % antes de INICIAR TORNEO. Estado actual: %.',
            COALESCE(
                NULLIF(btrim(p_contexto),''),
                'esta operación competitiva'
            ),
            v_status
            USING ERRCODE='23514',
                  HINT='Ejecuta INICIAR TORNEO antes de capturar resultados.';
    END IF;

    v_round_status :=
        public._round_operational_status_314(
            v_tournament_round_id
        );

    IF v_round_status IS DISTINCT FROM 'EN_JUEGO' THEN
        RAISE EXCEPTION
            'No se puede realizar % porque la ronda no está EN JUEGO. Estado actual: %.',
            COALESCE(
                NULLIF(btrim(p_contexto),''),
                'esta operación competitiva'
            ),
            COALESCE(v_round_status,'PENDIENTE')
            USING ERRCODE='23514',
                  HINT='Ejecuta INICIAR RONDA antes de capturar resultados.';
    END IF;
END;
$$;


-- --------------------------------------------------------------------------
-- E. Reprogramación de fecha sólo mientras la ronda está PENDIENTE
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_round_date_reprogrammings (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL REFERENCES public.tournaments(id),
    tournament_round_id uuid NOT NULL REFERENCES public.tournament_rounds(id),
    old_date date NOT NULL,
    new_date date NOT NULL,
    reason text NOT NULL,
    changed_by_admin_user_id uuid NOT NULL REFERENCES public.admin_users(id),
    changed_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_round_date_reprogrammings_dates_chk
        CHECK (new_date IS DISTINCT FROM old_date),
    CONSTRAINT tournament_round_date_reprogrammings_reason_chk
        CHECK (char_length(btrim(reason)) >= 5)
);

CREATE INDEX IF NOT EXISTS idx_tournament_round_date_reprogrammings_round
ON public.tournament_round_date_reprogrammings(
    tournament_round_id,
    changed_at DESC
);

ALTER TABLE public.tournament_round_date_reprogrammings
ENABLE ROW LEVEL SECURITY;

REVOKE ALL
ON public.tournament_round_date_reprogrammings
FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT
ON public.tournament_round_date_reprogrammings
TO service_role;


CREATE OR REPLACE FUNCTION public.validar_limite_rondas()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tournament_id uuid;
    v_declared_rounds integer;
    v_first_missing integer;
    v_has_dependencies boolean;
    v_has_active_shifts boolean;
    v_has_groups boolean;
    v_has_validation boolean;
    v_has_emissions boolean;
    v_date_reprogramming boolean := false;
    v_only_date_change boolean := false;
BEGIN
    v_tournament_id := CASE WHEN TG_OP = 'DELETE'
                            THEN OLD.tournament_id
                            ELSE NEW.tournament_id END;

    v_date_reprogramming :=
        current_setting(
            'app.reprogramar_fecha_ronda_314',
            true
        ) IS NOT DISTINCT FROM 'true';

    IF TG_OP = 'UPDATE' THEN
        v_only_date_change :=
            NEW.fecha IS DISTINCT FROM OLD.fecha
            AND (
                to_jsonb(NEW) - ARRAY['fecha','updated_at']
            ) IS NOT DISTINCT FROM (
                to_jsonb(OLD) - ARRAY['fecha','updated_at']
            );
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = v_tournament_id
    )
    AND NOT (
        v_date_reprogramming
        AND v_only_date_change
    )
    THEN
        RAISE EXCEPTION
            'No se pueden crear, modificar, reactivar, desactivar ni eliminar rondas después de congelar el torneo.'
            USING ERRCODE = '55000';
    END IF;

    SELECT t.numero_rondas
      INTO v_declared_rounds
      FROM public.tournaments t
     WHERE t.id = v_tournament_id;

    IF v_declared_rounds IS NULL THEN
        RAISE EXCEPTION
            'El torneo de la ronda no existe.'
            USING ERRCODE = '23503';
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.numero_ronda > v_declared_rounds THEN
            RAISE EXCEPTION
                'La ronda % excede las % ronda(s) declaradas para el torneo.',
                NEW.numero_ronda,
                v_declared_rounds
                USING ERRCODE = '23514';
        END IF;

        IF NEW.activo = true THEN
            SELECT gs
              INTO v_first_missing
              FROM generate_series(1, v_declared_rounds) AS gs
             WHERE NOT EXISTS (
                 SELECT 1
                 FROM public.tournament_rounds tr
                 WHERE tr.tournament_id = NEW.tournament_id
                   AND tr.numero_ronda = gs
                   AND tr.activo = true
             )
             ORDER BY gs
             LIMIT 1;

            IF v_first_missing IS NULL THEN
                RAISE EXCEPTION
                    'Todas las % ronda(s) declaradas ya están activas.',
                    v_declared_rounds
                    USING ERRCODE = '23514';
            END IF;

            IF NEW.numero_ronda <> v_first_missing THEN
                RAISE EXCEPTION
                    'La siguiente ronda activa debe ser la número %, no la número %.',
                    v_first_missing,
                    NEW.numero_ronda
                    USING ERRCODE = '23514',
                          HINT = 'Utiliza crear_o_reactivar_siguiente_ronda para recuperar una ronda inactiva existente.';
            END IF;

            IF EXISTS (
                SELECT 1
                FROM public.tournament_rounds tr
                WHERE tr.tournament_id = NEW.tournament_id
                  AND tr.numero_ronda = NEW.numero_ronda
                  AND tr.activo = false
            ) THEN
                RAISE EXCEPTION
                    'La ronda % ya existe desactivada y debe reactivarse; no debe crearse una ronda nueva.',
                    NEW.numero_ronda
                    USING ERRCODE = '23505',
                          HINT = 'Utiliza crear_o_reactivar_siguiente_ronda.';
            END IF;
        END IF;

        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF NEW.tournament_id IS DISTINCT FROM OLD.tournament_id THEN
            RAISE EXCEPTION
                'Una ronda existente no puede trasladarse a otro torneo.'
                USING ERRCODE = '55000';
        END IF;

        IF NEW.numero_ronda IS DISTINCT FROM OLD.numero_ronda THEN
            RAISE EXCEPTION
                'El número de una ronda existente no puede cambiarse; debe conservar su identidad histórica.'
                USING ERRCODE = '55000';
        END IF;

        IF NEW.campo_golf_id IS DISTINCT FROM OLD.campo_golf_id THEN
            SELECT EXISTS (
                SELECT 1
                FROM public.tournament_round_shifts rs
                WHERE rs.tournament_round_id = OLD.id
            )
            INTO v_has_dependencies;

            IF v_has_dependencies THEN
                RAISE EXCEPTION
                    'La ronda % tiene turnos o salidas relacionados; no se puede cambiar su campo.',
                    OLD.numero_ronda
                    USING ERRCODE = '23514';
            END IF;
        END IF;

        IF NEW.fecha IS DISTINCT FROM OLD.fecha
           AND NOT (
                v_date_reprogramming
                AND v_only_date_change
           )
        THEN
            SELECT EXISTS (
                SELECT 1
                FROM public.tournament_round_shifts rs
                WHERE rs.tournament_round_id = OLD.id
            )
            INTO v_has_dependencies;

            IF v_has_dependencies THEN
                RAISE EXCEPTION
                    'La ronda % tiene turnos o salidas relacionados; la fecha debe cambiarse mediante la reprogramación controlada.',
                    OLD.numero_ronda
                    USING ERRCODE = '23514',
                          HINT = 'Utiliza reprogramar_fecha_ronda_314.';
            END IF;
        END IF;

        IF NEW.formato_salida IS DISTINCT FROM OLD.formato_salida THEN
            SELECT EXISTS (
                SELECT 1
                FROM public.tournament_round_shifts rs
                WHERE rs.tournament_round_id = OLD.id
                  AND rs.activo = true
            ) INTO v_has_active_shifts;

            SELECT EXISTS (
                SELECT 1
                FROM public.tournament_groups g
                JOIN public.tournament_round_shifts rs
                  ON rs.id = g.tournament_round_shift_id
                WHERE rs.tournament_round_id = OLD.id
                  AND g.activo = true
            ) INTO v_has_groups;

            SELECT EXISTS (
                SELECT 1
                FROM public.tournament_round_start_validations v
                WHERE v.tournament_round_id = OLD.id
                  AND v.status = 'validated'
            ) INTO v_has_validation;

            SELECT EXISTS (
                SELECT 1
                FROM public.tournament_score_card_emissions e
                WHERE e.tournament_round_id = OLD.id
                  AND e.voided_at IS NULL
            ) INTO v_has_emissions;

            IF v_has_groups THEN
                RAISE EXCEPTION
                    'La ronda % ya tiene grupos de salida preparados; no puede cambiarse su formato de salida.',
                    OLD.numero_ronda
                    USING ERRCODE = '23514';
            END IF;

            IF v_has_validation THEN
                RAISE EXCEPTION
                    'Las salidas de la ronda % ya fueron validadas; no puede cambiarse su formato de salida.',
                    OLD.numero_ronda
                    USING ERRCODE = '23514';
            END IF;

            IF v_has_emissions THEN
                RAISE EXCEPTION
                    'Ya existen tarjetas oficiales emitidas para la ronda %; no puede cambiarse su formato de salida.',
                    OLD.numero_ronda
                    USING ERRCODE = '23514';
            END IF;

            IF v_has_active_shifts THEN
                RAISE EXCEPTION
                    'Primero debes inactivar y eliminar los turnos existentes antes de cambiar el formato de salida.'
                    USING ERRCODE = '23514';
            END IF;
        END IF;

        IF OLD.activo = false AND NEW.activo = true THEN
            SELECT gs
              INTO v_first_missing
              FROM generate_series(1, v_declared_rounds) AS gs
             WHERE NOT EXISTS (
                 SELECT 1
                 FROM public.tournament_rounds tr
                 WHERE tr.tournament_id = OLD.tournament_id
                   AND tr.numero_ronda = gs
                   AND tr.activo = true
             )
             ORDER BY gs
             LIMIT 1;

            IF v_first_missing IS NULL
               OR OLD.numero_ronda <> v_first_missing
            THEN
                RAISE EXCEPTION
                    'La ronda que debe reactivarse primero es la número %, no la número %.',
                    COALESCE(v_first_missing::text,'ninguna'),
                    OLD.numero_ronda
                    USING ERRCODE = '23514';
            END IF;
        END IF;

        IF OLD.activo = true AND NEW.activo = false
           AND EXISTS (
               SELECT 1
               FROM public.tournament_rounds later_round
               WHERE later_round.tournament_id = OLD.tournament_id
                 AND later_round.activo = true
                 AND later_round.numero_ronda > OLD.numero_ronda
           )
        THEN
            RAISE EXCEPTION
                'No se puede desactivar la ronda % mientras existan rondas posteriores activas.',
                OLD.numero_ronda
                USING ERRCODE = '23514',
                      HINT = 'Desactiva primero las rondas posteriores, en orden descendente.';
        END IF;

        RETURN NEW;
    END IF;

    IF OLD.activo = true
       AND EXISTS (
           SELECT 1
           FROM public.tournament_rounds later_round
           WHERE later_round.tournament_id = OLD.tournament_id
             AND later_round.activo = true
             AND later_round.numero_ronda > OLD.numero_ronda
       )
    THEN
        RAISE EXCEPTION
            'No se puede eliminar la ronda % mientras existan rondas posteriores activas.',
            OLD.numero_ronda
            USING ERRCODE = '23514';
    END IF;

    RETURN OLD;
END;
$$;


CREATE OR REPLACE FUNCTION public.reprogramar_fecha_ronda_314(
    p_tournament_round_id uuid,
    p_nueva_fecha date,
    p_motivo text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_round public.tournament_rounds%ROWTYPE;
    v_tournament public.tournaments%ROWTYPE;
    v_lifecycle public.tournament_round_lifecycle%ROWTYPE;
    v_last_completed_date date;
    v_admin_id uuid;
    v_old_date date;
    v_history_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_nueva_fecha IS NULL THEN
        RAISE EXCEPTION
            'Debes indicar la nueva fecha.'
            USING ERRCODE='22023';
    END IF;

    IF char_length(btrim(COALESCE(p_motivo,''))) < 5 THEN
        RAISE EXCEPTION
            'El motivo debe contener al menos 5 caracteres.'
            USING ERRCODE='22023';
    END IF;

    SELECT *
      INTO v_round
      FROM public.tournament_rounds
     WHERE id = p_tournament_round_id
       AND activo = true
     FOR UPDATE;

    IF v_round.id IS NULL THEN
        RAISE EXCEPTION
            'La ronda indicada no existe o no está activa.'
            USING ERRCODE='22023';
    END IF;

    SELECT *
      INTO v_tournament
      FROM public.tournaments
     WHERE id = v_round.tournament_id
     FOR UPDATE;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(
            auth.uid(),
            v_round.tournament_id
        )
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden reprogramar la ronda.'
            USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_lifecycle
      FROM public.tournament_round_lifecycle
     WHERE tournament_round_id = v_round.id;

    IF v_lifecycle.started_at IS NOT NULL THEN
        RAISE EXCEPTION
            'La fecha sólo puede cambiarse mientras la ronda está PENDIENTE.'
            USING ERRCODE='23514';
    END IF;

    IF p_nueva_fecha < v_tournament.fecha_inicio THEN
        RAISE EXCEPTION
            'La nueva fecha (%) no puede ser anterior al inicio del torneo (%).',
            p_nueva_fecha,
            v_tournament.fecha_inicio
            USING ERRCODE='23514';
    END IF;

    SELECT max(tr.fecha)
      INTO v_last_completed_date
      FROM public.tournament_rounds tr
      JOIN public.tournament_round_lifecycle l
        ON l.tournament_round_id = tr.id
     WHERE tr.tournament_id = v_round.tournament_id
       AND tr.activo = true
       AND tr.numero_ronda < v_round.numero_ronda
       AND l.completed_at IS NOT NULL;

    IF v_last_completed_date IS NOT NULL
       AND p_nueva_fecha < v_last_completed_date
    THEN
        RAISE EXCEPTION
            'La nueva fecha (%) no puede ser anterior a la última ronda finalizada (%).',
            p_nueva_fecha,
            v_last_completed_date
            USING ERRCODE='23514';
    END IF;

    v_old_date := v_round.fecha;

    IF p_nueva_fecha = v_old_date THEN
        RETURN jsonb_build_object(
            'ok',true,
            'changed',false,
            'tournamentRoundId',v_round.id,
            'roundNumber',v_round.numero_ronda,
            'oldDate',v_old_date,
            'newDate',p_nueva_fecha
        );
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo = true
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No se encontró el usuario administrativo autenticado.'
            USING ERRCODE='42501';
    END IF;

    PERFORM set_config(
        'app.reprogramar_fecha_ronda_314',
        'true',
        true
    );

    UPDATE public.tournament_rounds
       SET fecha = p_nueva_fecha
     WHERE id = v_round.id;

    INSERT INTO public.tournament_round_date_reprogrammings(
        tournament_id,
        tournament_round_id,
        old_date,
        new_date,
        reason,
        changed_by_admin_user_id
    )
    VALUES(
        v_round.tournament_id,
        v_round.id,
        v_old_date,
        p_nueva_fecha,
        btrim(p_motivo),
        v_admin_id
    )
    RETURNING id INTO v_history_id;

    RETURN jsonb_build_object(
        'ok',true,
        'changed',true,
        'historyId',v_history_id,
        'tournamentRoundId',v_round.id,
        'roundNumber',v_round.numero_ronda,
        'oldDate',v_old_date,
        'newDate',p_nueva_fecha,
        'status','PENDIENTE'
    );
END;
$$;

REVOKE ALL
ON FUNCTION public.reprogramar_fecha_ronda_314(uuid,date,text)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.reprogramar_fecha_ronda_314(uuid,date,text)
TO authenticated, service_role;


-- --------------------------------------------------------------------------
-- F. Fecha operativa viva en preview/payload oficial sin mutar snapshots
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._aplicar_fecha_operativa_payload_ronda_314(
    p_tournament_round_id uuid,
    p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_live_date date;
    v_payload_date date;
    v_delta_days integer;
    v_result jsonb;
    v_cards jsonb;
BEGIN
    IF p_payload IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT fecha
      INTO v_live_date
      FROM public.tournament_rounds
     WHERE id = p_tournament_round_id;

    v_payload_date :=
        NULLIF(p_payload #>> '{round,fecha}','')::date;

    v_result :=
        jsonb_set(
            p_payload,
            '{round,fecha}',
            to_jsonb(v_live_date),
            true
        );

    IF v_payload_date IS NULL
       OR v_payload_date = v_live_date
       OR jsonb_typeof(COALESCE(v_result->'cards','[]'::jsonb))
          <> 'array'
    THEN
        RETURN v_result;
    END IF;

    v_delta_days := v_live_date - v_payload_date;

    SELECT COALESCE(
        jsonb_agg(
            CASE
                WHEN jsonb_typeof(c.card->'start')='object'
                THEN jsonb_set(
                    c.card,
                    '{start}',
                    (c.card->'start')
                    ||
                    CASE
                        WHEN NULLIF(c.card #>> '{start,hora}','') IS NULL
                        THEN '{}'::jsonb
                        ELSE jsonb_build_object(
                            'hora',
                            (
                                (c.card #>> '{start,hora}')::timestamptz
                                + make_interval(days=>v_delta_days)
                            )
                        )
                    END
                    ||
                    CASE
                        WHEN NULLIF(c.card #>> '{start,startAt}','') IS NULL
                        THEN '{}'::jsonb
                        ELSE jsonb_build_object(
                            'startAt',
                            (
                                (c.card #>> '{start,startAt}')::timestamptz
                                + make_interval(days=>v_delta_days)
                            )
                        )
                    END,
                    true
                )
                ELSE c.card
            END
            ORDER BY c.ord
        ),
        '[]'::jsonb
    )
    INTO v_cards
    FROM jsonb_array_elements(v_result->'cards')
         WITH ORDINALITY c(card,ord);

    RETURN jsonb_set(
        v_result,
        '{cards}',
        v_cards,
        true
    );
END;
$$;


CREATE OR REPLACE FUNCTION public.previsualizar_tarjetas_score_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_capability jsonb;
    v_payload jsonb;
BEGIN
    v_capability :=
        public._resolver_capacidad_emision_tarjetas_ronda(
            p_tournament_round_id
        );

    IF COALESCE((v_capability->>'supported')::boolean,false)
       AND v_capability->>'unitType'='team'
    THEN
        v_payload :=
            public.previsualizar_tarjetas_equipo_a_gogo_ronda(
                p_tournament_round_id
            );
    ELSE
        v_payload :=
            public._previsualizar_tarjetas_score_ronda_individual_208(
                p_tournament_round_id
            );
    END IF;

    RETURN public._aplicar_fecha_operativa_payload_ronda_314(
        p_tournament_round_id,
        v_payload
    );
END;
$$;


ALTER FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(uuid)
RENAME TO _obtener_payload_tarjetas_score_oficiales_ronda_pre314;

REVOKE ALL
ON FUNCTION public._obtener_payload_tarjetas_score_oficiales_ronda_pre314(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._obtener_payload_tarjetas_score_oficiales_ronda_pre314(uuid)
TO service_role;


CREATE FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_payload jsonb;
BEGIN
    v_payload :=
        public._obtener_payload_tarjetas_score_oficiales_ronda_pre314(
            p_tournament_round_id
        );

    RETURN public._aplicar_fecha_operativa_payload_ronda_314(
        p_tournament_round_id,
        v_payload
    );
END;
$$;

REVOKE ALL
ON FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(uuid)
TO authenticated, service_role;


-- --------------------------------------------------------------------------
-- G. Asistente operativo: reflejar ciclo de ronda
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._obtener_asistente_operativo_torneo_v22_314(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_base jsonb;
    v_source_steps jsonb;
    v_new_steps jsonb := '[]'::jsonb;
    v_step jsonb;
    v_round_id uuid;
    v_round_number integer;
    v_round_status text;
    v_round_state jsonb;
    v_lifecycle_step jsonb;
    v_blockers jsonb;
    v_next_action jsonb := NULL;
    v_total integer;
    v_completed integer;
BEGIN
    v_base :=
        public._obtener_asistente_operativo_torneo_v21_299(
            p_tournament_id
        );

    v_source_steps := COALESCE(v_base->'steps','[]'::jsonb);

    FOR v_step IN
        SELECT elem
        FROM jsonb_array_elements(v_source_steps) x(elem)
    LOOP
        -- Antes de captura/conciliación insertamos el paso explícito
        -- de ciclo operativo de la ronda.
        IF v_step->>'code'='ROUND_SCORING'
           AND v_step->>'roundId' IS NOT NULL
        THEN
            v_round_id := (v_step->>'roundId')::uuid;
            v_round_number := (v_step->>'roundNumber')::integer;
            v_round_state :=
                public.obtener_estado_operativo_ronda_314(v_round_id);
            v_round_status := v_round_state->>'status';

            v_lifecycle_step :=
                jsonb_build_object(
                    'code','ROUND_PLAY',
                    'scope','ROUND',
                    'roundId',v_round_id,
                    'roundNumber',v_round_number,
                    'title',format(
                        'Ronda %s · Estado de juego',
                        v_round_number
                    ),
                    'status',
                        CASE
                            WHEN v_round_status='FINALIZADA'
                                THEN 'COMPLETE'
                            WHEN v_round_status='EN_JUEGO'
                                THEN 'PENDING'
                            ELSE 'PENDING'
                        END,
                    'message',
                        CASE
                            WHEN v_round_status='FINALIZADA'
                                THEN format(
                                    'La ronda %s está finalizada.',
                                    v_round_number
                                )
                            WHEN v_round_status='EN_JUEGO'
                                THEN format(
                                    'La ronda %s está EN JUEGO.',
                                    v_round_number
                                )
                            ELSE format(
                                'La ronda %s todavía no ha sido iniciada.',
                                v_round_number
                            )
                        END,
                    'recommendation',
                        CASE
                            WHEN v_round_status='FINALIZADA'
                                THEN NULL
                            WHEN v_round_status='EN_JUEGO'
                                THEN
                                    'Completa captura, conciliación, resultados y cierre formal.'
                            ELSE
                                COALESCE(
                                    v_round_state->>'startBlockReason',
                                    'Cuando la ronda esté lista para jugarse, ejecútala mediante INICIAR RONDA.'
                                )
                        END,
                    'details',v_round_state,
                    'action',
                        CASE
                            WHEN v_round_status='PENDIENTE'
                                 AND COALESCE(
                                     (v_round_state->>'canStart')::boolean,
                                     false
                                 )
                            THEN jsonb_build_object(
                                'label','Iniciar ronda',
                                'target','tarjetas-resultados',
                                'actionKey','START_ROUND',
                                'roundId',v_round_id
                            )
                            WHEN v_round_status='PENDIENTE'
                            THEN NULL
                            ELSE jsonb_build_object(
                                'label','Revisar ronda',
                                'target','tarjetas-resultados',
                                'roundId',v_round_id
                            )
                        END,
                    'requiredRole','TOURNAMENT_OPERATOR'
                );

            v_new_steps :=
                v_new_steps
                || jsonb_build_array(v_lifecycle_step);
        END IF;

        v_new_steps :=
            v_new_steps
            || jsonb_build_array(v_step);
    END LOOP;

    SELECT COALESCE(
        jsonb_agg(s.elem ORDER BY s.ord),
        '[]'::jsonb
    )
      INTO v_blockers
      FROM jsonb_array_elements(v_new_steps)
           WITH ORDINALITY s(elem,ord)
     WHERE s.elem->>'status'='BLOCKED'
       AND COALESCE(
           (s.elem #>> '{availability,actionable}')::boolean,
           true
       );

    SELECT s.elem->'action'
      INTO v_next_action
      FROM jsonb_array_elements(v_new_steps)
           WITH ORDINALITY s(elem,ord)
     WHERE s.elem->>'status' IN ('BLOCKED','PENDING')
       AND s.elem->'action' IS NOT NULL
       AND s.elem->'action' <> 'null'::jsonb
       AND COALESCE(
           (s.elem #>> '{availability,actionable}')::boolean,
           true
       )
     ORDER BY s.ord
     LIMIT 1;

    SELECT
        count(*)::integer,
        count(*) FILTER(
            WHERE elem->>'status'='COMPLETE'
        )::integer
      INTO v_total,v_completed
      FROM jsonb_array_elements(v_new_steps) x(elem);

    v_base := jsonb_set(v_base,'{steps}',v_new_steps,true);
    v_base := jsonb_set(v_base,'{blockers}',v_blockers,true);
    v_base := jsonb_set(
        v_base,
        '{summary,blockingIssues}',
        to_jsonb(jsonb_array_length(v_blockers)),
        true
    );
    v_base := jsonb_set(
        v_base,
        '{progress,completed}',
        to_jsonb(v_completed),
        true
    );
    v_base := jsonb_set(
        v_base,
        '{progress,total}',
        to_jsonb(v_total),
        true
    );
    v_base := jsonb_set(
        v_base,
        '{progress,percent}',
        to_jsonb(
            CASE
                WHEN v_total=0 THEN 0
                ELSE round(100.0*v_completed/v_total,0)
            END
        ),
        true
    );
    v_base := jsonb_set(
        v_base,
        '{nextAction}',
        COALESCE(v_next_action,'null'::jsonb),
        true
    );

    RETURN v_base || jsonb_build_object(
        'schemaVersion',22,
        'roundLifecycleRequired',true
    );
END;
$$;


CREATE OR REPLACE FUNCTION public.obtener_asistente_operativo_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT public._obtener_asistente_operativo_torneo_v22_314(
        p_tournament_id
    );
$$;


-- --------------------------------------------------------------------------
-- H. Finalización del torneo: además exige ciclo FINALIZADA en todas las rondas
-- --------------------------------------------------------------------------

ALTER FUNCTION public.previsualizar_finalizacion_torneo(uuid)
RENAME TO _previsualizar_finalizacion_torneo_pre314;

REVOKE ALL
ON FUNCTION public._previsualizar_finalizacion_torneo_pre314(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._previsualizar_finalizacion_torneo_pre314(uuid)
TO service_role;


CREATE FUNCTION public.previsualizar_finalizacion_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_base jsonb;
    v_pending_lifecycle integer := 0;
BEGIN
    v_base :=
        public._previsualizar_finalizacion_torneo_pre314(
            p_tournament_id
        );

    SELECT count(*)::integer
      INTO v_pending_lifecycle
      FROM public.tournament_rounds tr
      LEFT JOIN public.tournament_round_lifecycle l
        ON l.tournament_round_id = tr.id
     WHERE tr.tournament_id = p_tournament_id
       AND tr.activo = true
       AND l.completed_at IS NULL;

    v_base := jsonb_set(
        v_base,
        '{roundLifecycle}',
        jsonb_build_object(
            'required',true,
            'pendingRounds',v_pending_lifecycle,
            'allRoundsFinalized',v_pending_lifecycle=0
        ),
        true
    );

    IF v_pending_lifecycle > 0 THEN
        v_base := jsonb_set(
            v_base,
            '{readyToFinalize}',
            'false'::jsonb,
            true
        );
    END IF;

    RETURN v_base;
END;
$$;

REVOKE ALL
ON FUNCTION public.previsualizar_finalizacion_torneo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.previsualizar_finalizacion_torneo(uuid)
TO authenticated, service_role;

COMMIT;
