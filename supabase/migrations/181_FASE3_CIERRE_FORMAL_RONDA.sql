-- ============================================================================
-- 181_FASE3_CIERRE_FORMAL_RONDA.sql
-- TEE CENTRAL
--
-- OBJETIVOS
-- 1) Persistir un cierre formal y auditable por ronda.
-- 2) Permitir cerrar sólo cuando el estado competitivo derivado sea FINAL.
-- 3) Funcionar tanto con empates como sin empates:
--      - sin empates: pendingGroups=0 => FINAL si cardsReady=true
--      - con empates: todos deben estar resueltos => FINAL
-- 4) Congelar los datos competitivos de la ronda después del cierre:
--      captura digital, físico, conciliación, outcomes, tarjetas y desempates.
--
-- NO IMPLEMENTA:
-- - finalizar_torneo()  -> queda para 181 Fase 4
-- - reapertura de ronda cerrada
-- - UI
-- - cálculo automático de cortes
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. TABLA DE CIERRE FORMAL
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.tournament_round_competitive_closures (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id),

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id),

    round_number integer NOT NULL,
    round_date date NOT NULL,

    competitive_status text NOT NULL
        CHECK (competitive_status = 'FINAL'),

    closure_snapshot jsonb NOT NULL,

    closed_at timestamptz NOT NULL DEFAULT now(),
    closed_by_admin_user_id uuid NOT NULL
        REFERENCES public.admin_users(id),

    notes text,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_tournament_round_competitive_closure
        UNIQUE (tournament_round_id)
);

CREATE INDEX IF NOT EXISTS
idx_tournament_round_competitive_closures_tournament
ON public.tournament_round_competitive_closures(tournament_id);


-- ============================================================================
-- 02. RLS / PRIVILEGIOS TABLA
-- ============================================================================
ALTER TABLE public.tournament_round_competitive_closures
ENABLE ROW LEVEL SECURITY;

REVOKE ALL
ON TABLE public.tournament_round_competitive_closures
FROM PUBLIC, anon, authenticated;

GRANT ALL
ON TABLE public.tournament_round_competitive_closures
TO service_role;


-- ============================================================================
-- 03. INMUTABILIDAD DEL SELLO DE CIERRE
-- ============================================================================
CREATE OR REPLACE FUNCTION public.impedir_mutacion_cierre_competitivo_ronda()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION
        'El cierre competitivo de una ronda es histórico e inmutable.'
        USING ERRCODE = '55000',
              HINT =
                  'No edites ni elimines el cierre. Cualquier proceso extraordinario de reapertura deberá diseñarse como una operación administrativa auditada.';
END;
$function$;

DROP TRIGGER IF EXISTS
trg_impedir_mutacion_cierre_competitivo_ronda
ON public.tournament_round_competitive_closures;

CREATE TRIGGER trg_impedir_mutacion_cierre_competitivo_ronda
BEFORE UPDATE OR DELETE
ON public.tournament_round_competitive_closures
FOR EACH ROW
EXECUTE FUNCTION public.impedir_mutacion_cierre_competitivo_ronda();


-- ============================================================================
-- 04. HELPER — ¿RONDA FORMALMENTE CERRADA?
-- ============================================================================
CREATE OR REPLACE FUNCTION public._ronda_esta_cerrada_competitivamente(
    p_tournament_round_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT EXISTS (
        SELECT 1
        FROM public.tournament_round_competitive_closures c
        WHERE c.tournament_round_id = p_tournament_round_id
    );
$function$;


-- ============================================================================
-- 05. RESOLVER RONDA DESDE FILA COMPETITIVA
--
-- Prioridad:
-- 1) tournament_round_id directo
-- 2) score_card_id -> tournament_score_cards
--
-- Esto permite usar un único trigger en tablas de resultados diferentes.
-- ============================================================================
CREATE OR REPLACE FUNCTION public._resolver_ronda_fila_competitiva(
    p_row jsonb
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_round_id uuid;
    v_score_card_id uuid;
BEGIN
    IF p_row IS NULL THEN
        RETURN NULL;
    END IF;

    IF NULLIF(p_row->>'tournament_round_id', '') IS NOT NULL THEN
        RETURN (p_row->>'tournament_round_id')::uuid;
    END IF;

    IF NULLIF(p_row->>'score_card_id', '') IS NOT NULL THEN
        v_score_card_id := (p_row->>'score_card_id')::uuid;

        SELECT sc.tournament_round_id
          INTO v_round_id
          FROM public.tournament_score_cards sc
         WHERE sc.id = v_score_card_id;

        RETURN v_round_id;
    END IF;

    RETURN NULL;
END;
$function$;


-- ============================================================================
-- 06. GUARD GENÉRICO DE DATOS COMPETITIVOS DESPUÉS DEL CIERRE
-- ============================================================================
CREATE OR REPLACE FUNCTION public.proteger_datos_ronda_competitiva_cerrada()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old_round_id uuid;
    v_new_round_id uuid;
    v_round_id uuid;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old_round_id :=
            public._resolver_ronda_fila_competitiva(to_jsonb(OLD));
    END IF;

    IF TG_OP <> 'DELETE' THEN
        v_new_round_id :=
            public._resolver_ronda_fila_competitiva(to_jsonb(NEW));
    END IF;

    FOR v_round_id IN
        SELECT DISTINCT x.round_id
        FROM unnest(
            ARRAY[v_old_round_id, v_new_round_id]
        ) AS x(round_id)
        WHERE x.round_id IS NOT NULL
        ORDER BY x.round_id
    LOOP
        IF public._ronda_esta_cerrada_competitivamente(v_round_id) THEN
            RAISE EXCEPTION
                'La ronda está cerrada competitivamente y sus resultados ya no pueden modificarse.'
                USING ERRCODE = '55000',
                      DETAIL = format(
                          'table=%s; tournament_round_id=%s',
                          TG_TABLE_NAME,
                          v_round_id
                      ),
                      HINT =
                          'El cierre de ronda es definitivo. Cualquier reapertura futura deberá realizarse mediante un proceso administrativo extraordinario y auditado.';
        END IF;
    END LOOP;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$function$;


-- ============================================================================
-- 07. INSTALAR PROTECCIONES EN TABLAS MUTABLES DEL RESULTADO
--
-- Se crean sólo si la tabla existe, para mantener la migración defensiva.
-- ============================================================================
DO $migration$
DECLARE
    v_table text;
    v_tables text[] := ARRAY[
        'tournament_score_cards',
        'tournament_scorecard_capture_sessions',
        'tournament_scorecard_hole_scores',
        'tournament_scorecard_physical_receptions',
        'tournament_scorecard_physical_hole_scores',
        'tournament_scorecard_reconciliations',
        'tournament_scorecard_hole_resolutions',
        'tournament_scorecard_round_outcomes',
        'tournament_tiebreak_resolutions'
    ];
BEGIN
    FOREACH v_table IN ARRAY v_tables LOOP
        IF to_regclass('public.' || v_table) IS NOT NULL THEN
            EXECUTE format(
                'DROP TRIGGER IF EXISTS %I ON public.%I',
                'trg_proteger_ronda_competitiva_cerrada',
                v_table
            );

            EXECUTE format(
                'CREATE TRIGGER %I
                 BEFORE INSERT OR UPDATE OR DELETE
                 ON public.%I
                 FOR EACH ROW
                 EXECUTE FUNCTION public.proteger_datos_ronda_competitiva_cerrada()',
                'trg_proteger_ronda_competitiva_cerrada',
                v_table
            );
        END IF;
    END LOOP;
END;
$migration$;


-- ============================================================================
-- 08. RPC — CONSULTAR CIERRE FORMAL
-- ============================================================================
CREATE OR REPLACE FUNCTION public.obtener_cierre_formal_ronda(
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
    v_row public.tournament_round_competitive_closures%ROWTYPE;
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

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar el cierre formal de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_row
      FROM public.tournament_round_competitive_closures c
     WHERE c.tournament_round_id = p_tournament_round_id;

    IF v_row.id IS NULL THEN
        RETURN jsonb_build_object(
            'tournamentRoundId', p_tournament_round_id,
            'closed', false,
            'closure', NULL
        );
    END IF;

    RETURN jsonb_build_object(
        'tournamentRoundId', p_tournament_round_id,
        'closed', true,
        'closure', jsonb_build_object(
            'id', v_row.id,
            'tournamentId', v_row.tournament_id,
            'roundNumber', v_row.round_number,
            'roundDate', v_row.round_date,
            'competitiveStatus', v_row.competitive_status,
            'closedAt', v_row.closed_at,
            'closedByAdminUserId', v_row.closed_by_admin_user_id,
            'notes', v_row.notes,
            'snapshot', v_row.closure_snapshot
        )
    );
END;
$function$;


-- ============================================================================
-- 09. RPC — CERRAR RONDA COMPETITIVAMENTE
--
-- Autoridad:
-- obtener_estado_cierre_competitivo_ronda(round_id)
--
-- Única precondición competitiva:
-- status.competitiveStatus = FINAL
--
-- Por diseño:
-- - si NO hay empates, pendingGroups=0 y puede llegar a FINAL normalmente;
-- - si hay empates, todos deben estar resueltos antes de cerrar.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cerrar_ronda_competitiva(
    p_tournament_round_id uuid,
    p_notas text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_round_number integer;
    v_round_date date;
    v_tournament_status public.estatus_torneo;
    v_admin_id uuid;
    v_state jsonb;
    v_competitive_status text;
    v_closure_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        tr.tournament_id,
        tr.numero_ronda,
        tr.fecha,
        t.estatus
      INTO
        v_tournament_id,
        v_round_number,
        v_round_date,
        v_tournament_status
      FROM public.tournament_rounds tr
      JOIN public.tournaments t
        ON t.id = tr.tournament_id
     WHERE tr.id = p_tournament_round_id
       AND tr.activo = true
     FOR UPDATE OF tr, t;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda indicada no existe o no está activa.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(
            auth.uid(),
            v_tournament_id
        )
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden cerrar competitivamente la ronda.'
            USING ERRCODE = '42501';
    END IF;

    IF v_tournament_status <> 'en_curso'::public.estatus_torneo THEN
        RAISE EXCEPTION
            'La ronda sólo puede cerrarse formalmente cuando el torneo está EN CURSO. Estado actual: %.',
            v_tournament_status
            USING ERRCODE = '23514';
    END IF;

    -- Serializa cierres concurrentes de la misma ronda.
    PERFORM public._bloquear_salida_ronda(
        p_tournament_round_id
    );

    -- Idempotencia.
    SELECT c.id
      INTO v_closure_id
      FROM public.tournament_round_competitive_closures c
     WHERE c.tournament_round_id = p_tournament_round_id;

    IF v_closure_id IS NOT NULL THEN
        RETURN public.obtener_cierre_formal_ronda(
            p_tournament_round_id
        );
    END IF;

    v_state :=
        public.obtener_estado_cierre_competitivo_ronda(
            p_tournament_round_id
        );

    v_competitive_status :=
        v_state #>> '{status,competitiveStatus}';

    IF v_competitive_status IS DISTINCT FROM 'FINAL' THEN
        RAISE EXCEPTION
            'La ronda todavía no puede cerrarse competitivamente.'
            USING ERRCODE = '23514',
                  DETAIL = v_state::text,
                  HINT =
                      'Todas las tarjetas deben estar resueltas y, si existen empates, todos los desempates deben estar resueltos.';
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
            USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.tournament_round_competitive_closures (
        tournament_id,
        tournament_round_id,
        round_number,
        round_date,
        competitive_status,
        closure_snapshot,
        closed_by_admin_user_id,
        notes
    )
    VALUES (
        v_tournament_id,
        p_tournament_round_id,
        v_round_number,
        v_round_date,
        'FINAL',
        v_state,
        v_admin_id,
        NULLIF(btrim(COALESCE(p_notas, '')), '')
    )
    RETURNING id INTO v_closure_id;

    RETURN public.obtener_cierre_formal_ronda(
        p_tournament_round_id
    );
END;
$function$;


-- ============================================================================
-- 10. PRIVILEGIOS RPC
-- ============================================================================
REVOKE ALL
ON FUNCTION public.obtener_cierre_formal_ronda(uuid)
FROM PUBLIC, anon;

REVOKE ALL
ON FUNCTION public.cerrar_ronda_competitiva(uuid, text)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.obtener_cierre_formal_ronda(uuid)
TO authenticated, service_role;

GRANT EXECUTE
ON FUNCTION public.cerrar_ronda_competitiva(uuid, text)
TO authenticated, service_role;


COMMIT;
