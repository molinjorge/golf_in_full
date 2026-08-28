-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 194 Fase 1
-- Cierre formal competitivo por categoría
--
-- OBJETIVO
--   Permitir cerrar competitivamente una categoría de una ronda sin esperar
--   a que las demás categorías de la misma ronda hayan terminado.
--
-- PRINCIPIOS
--   - Agnóstico de modalidad.
--   - Reutiliza 193 para determinar READY_TO_CLOSE.
--   - Reutiliza 192 para congelar en snapshot el leaderboard operativo de la
--     categoría al momento del cierre.
--   - El cierre es idempotente.
--   - El cierre formal de categoría vuelve inmutables los datos competitivos
--     de esa categoría en las tablas ya protegidas por el trigger común.
--   - No publica resultados. Publicación/reporte corresponde a una fase
--     posterior.
-- ============================================================================

-- ============================================================================
-- 1. TABLA DE CIERRES FORMALES POR CATEGORÍA
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tournament_round_category_competitive_closures (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id),

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id),

    tournament_category_id uuid NOT NULL
        REFERENCES public.tournament_categories(id),

    round_number integer NOT NULL,
    round_date date NOT NULL,

    competitive_status text NOT NULL
        CHECK (competitive_status = 'FINAL'),

    closure_snapshot jsonb NOT NULL,

    closed_at timestamptz NOT NULL DEFAULT now(),

    closed_by_admin_user_id uuid NOT NULL
        REFERENCES public.admin_users(id),

    notes text NULL,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_tournament_round_category_competitive_closure
        UNIQUE (tournament_round_id, tournament_category_id)
);

CREATE INDEX IF NOT EXISTS
    idx_tournament_round_category_competitive_closures_tournament
ON public.tournament_round_category_competitive_closures(
    tournament_id
);

CREATE INDEX IF NOT EXISTS
    idx_tournament_round_category_competitive_closures_round
ON public.tournament_round_category_competitive_closures(
    tournament_round_id
);

CREATE INDEX IF NOT EXISTS
    idx_tournament_round_category_competitive_closures_category
ON public.tournament_round_category_competitive_closures(
    tournament_category_id
);

ALTER TABLE
    public.tournament_round_category_competitive_closures
ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE
    public.tournament_round_category_competitive_closures
FROM PUBLIC;

REVOKE ALL ON TABLE
    public.tournament_round_category_competitive_closures
FROM anon;

REVOKE ALL ON TABLE
    public.tournament_round_category_competitive_closures
FROM authenticated;

-- La tabla se consume exclusivamente mediante RPCs SECURITY DEFINER.
GRANT ALL ON TABLE
    public.tournament_round_category_competitive_closures
TO service_role;

-- ============================================================================
-- 2. HELPER: ¿LA CATEGORÍA DE LA RONDA YA ESTÁ CERRADA?
-- ============================================================================

CREATE OR REPLACE FUNCTION
public._categoria_ronda_esta_cerrada_competitivamente(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT EXISTS (
        SELECT 1
        FROM public.tournament_round_category_competitive_closures c
        WHERE c.tournament_round_id = p_tournament_round_id
          AND c.tournament_category_id = p_tournament_category_id
    );
$function$;

REVOKE ALL ON FUNCTION
    public._categoria_ronda_esta_cerrada_competitivamente(uuid,uuid)
FROM PUBLIC;

REVOKE ALL ON FUNCTION
    public._categoria_ronda_esta_cerrada_competitivamente(uuid,uuid)
FROM anon;

REVOKE ALL ON FUNCTION
    public._categoria_ronda_esta_cerrada_competitivamente(uuid,uuid)
FROM authenticated;

GRANT EXECUTE ON FUNCTION
    public._categoria_ronda_esta_cerrada_competitivamente(uuid,uuid)
TO service_role;

-- ============================================================================
-- 3. HELPER: RESOLVER CATEGORÍA DESDE UNA FILA COMPETITIVA
--    Complementa _resolver_ronda_fila_competitiva(jsonb).
-- ============================================================================

CREATE OR REPLACE FUNCTION
public._resolver_categoria_fila_competitiva(
    p_row jsonb
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_category_id uuid;
    v_score_card_id uuid;
BEGIN
    IF p_row IS NULL THEN
        RETURN NULL;
    END IF;

    IF NULLIF(
        p_row->>'tournament_category_id',
        ''
    ) IS NOT NULL THEN
        RETURN (
            p_row->>'tournament_category_id'
        )::uuid;
    END IF;

    IF NULLIF(
        p_row->>'score_card_id',
        ''
    ) IS NOT NULL THEN
        v_score_card_id :=
            (
                p_row->>'score_card_id'
            )::uuid;

        SELECT sc.tournament_category_id
          INTO v_category_id
          FROM public.tournament_score_cards sc
         WHERE sc.id = v_score_card_id;

        RETURN v_category_id;
    END IF;

    RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION
    public._resolver_categoria_fila_competitiva(jsonb)
FROM PUBLIC;

REVOKE ALL ON FUNCTION
    public._resolver_categoria_fila_competitiva(jsonb)
FROM anon;

REVOKE ALL ON FUNCTION
    public._resolver_categoria_fila_competitiva(jsonb)
FROM authenticated;

GRANT EXECUTE ON FUNCTION
    public._resolver_categoria_fila_competitiva(jsonb)
TO service_role;

-- ============================================================================
-- 4. PROTECCIÓN DE DATOS COMPETITIVOS
--    Mantiene el bloqueo global de ronda y agrega bloqueo por categoría.
--
--    Esta función ya está conectada por trigger a:
--      tournament_score_cards
--      tournament_scorecard_capture_sessions
--      tournament_scorecard_hole_resolutions
--      tournament_scorecard_hole_scores
--      tournament_scorecard_physical_hole_scores
--      tournament_scorecard_physical_receptions
--      tournament_scorecard_reconciliations
--      tournament_scorecard_round_outcomes
--      tournament_tiebreak_resolutions
-- ============================================================================

CREATE OR REPLACE FUNCTION
public.proteger_datos_ronda_competitiva_cerrada()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old_round_id uuid;
    v_new_round_id uuid;
    v_round_id uuid;

    v_old_category_id uuid;
    v_new_category_id uuid;

    v_pair record;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old_round_id :=
            public._resolver_ronda_fila_competitiva(
                to_jsonb(OLD)
            );

        v_old_category_id :=
            public._resolver_categoria_fila_competitiva(
                to_jsonb(OLD)
            );
    END IF;

    IF TG_OP <> 'DELETE' THEN
        v_new_round_id :=
            public._resolver_ronda_fila_competitiva(
                to_jsonb(NEW)
            );

        v_new_category_id :=
            public._resolver_categoria_fila_competitiva(
                to_jsonb(NEW)
            );
    END IF;

    -- Bloqueo global ya existente.
    FOR v_round_id IN
        SELECT DISTINCT x.round_id
        FROM unnest(
            ARRAY[
                v_old_round_id,
                v_new_round_id
            ]
        ) AS x(round_id)
        WHERE x.round_id IS NOT NULL
        ORDER BY x.round_id
    LOOP
        IF public._ronda_esta_cerrada_competitivamente(
            v_round_id
        ) THEN
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

    -- Nuevo bloqueo granular por categoría.
    FOR v_pair IN
        SELECT DISTINCT
            x.round_id,
            x.category_id
        FROM (
            VALUES
                (
                    v_old_round_id,
                    v_old_category_id
                ),
                (
                    v_new_round_id,
                    v_new_category_id
                )
        ) AS x(
            round_id,
            category_id
        )
        WHERE x.round_id IS NOT NULL
          AND x.category_id IS NOT NULL
        ORDER BY
            x.round_id,
            x.category_id
    LOOP
        IF public._categoria_ronda_esta_cerrada_competitivamente(
            v_pair.round_id,
            v_pair.category_id
        ) THEN
            RAISE EXCEPTION
                'La categoría está cerrada competitivamente y sus resultados ya no pueden modificarse.'
                USING ERRCODE = '55000',
                      DETAIL = format(
                          'table=%s; tournament_round_id=%s; tournament_category_id=%s',
                          TG_TABLE_NAME,
                          v_pair.round_id,
                          v_pair.category_id
                      ),
                      HINT =
                          'El cierre competitivo por categoría es definitivo. Las demás categorías de la ronda permanecen operables.';
        END IF;
    END LOOP;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$function$;

-- ============================================================================
-- 5. CONSULTA DE CIERRE FORMAL DE UNA CATEGORÍA
-- ============================================================================

CREATE OR REPLACE FUNCTION
public.obtener_cierre_formal_categoria_ronda(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_category_tournament_id uuid;
    v_row
        public.tournament_round_category_competitive_closures%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL
       OR p_tournament_category_id IS NULL
    THEN
        RAISE EXCEPTION
            'tournament_round_id y tournament_category_id son obligatorios.'
            USING ERRCODE='22023';
    END IF;

    SELECT tr.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    SELECT tc.tournament_id
      INTO v_category_tournament_id
      FROM public.tournament_categories tc
     WHERE tc.id=p_tournament_category_id;

    IF v_category_tournament_id IS NULL
       OR v_category_tournament_id <> v_tournament_id
    THEN
        RAISE EXCEPTION
            'La categoría indicada no pertenece al torneo de la ronda.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar el cierre formal de esta categoría.'
            USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_row
      FROM public.tournament_round_category_competitive_closures c
     WHERE c.tournament_round_id=
            p_tournament_round_id
       AND c.tournament_category_id=
            p_tournament_category_id;

    IF v_row.id IS NULL THEN
        RETURN jsonb_build_object(
            'tournamentRoundId',
                p_tournament_round_id,
            'tournamentCategoryId',
                p_tournament_category_id,
            'closed',
                false,
            'closure',
                NULL
        );
    END IF;

    RETURN jsonb_build_object(
        'tournamentRoundId',
            p_tournament_round_id,
        'tournamentCategoryId',
            p_tournament_category_id,
        'closed',
            true,
        'closure',
            jsonb_build_object(
                'id',
                    v_row.id,
                'tournamentId',
                    v_row.tournament_id,
                'roundNumber',
                    v_row.round_number,
                'roundDate',
                    v_row.round_date,
                'competitiveStatus',
                    v_row.competitive_status,
                'closedAt',
                    v_row.closed_at,
                'closedByAdminUserId',
                    v_row.closed_by_admin_user_id,
                'notes',
                    v_row.notes,
                'snapshot',
                    v_row.closure_snapshot
            )
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.obtener_cierre_formal_categoria_ronda(uuid,uuid)
FROM PUBLIC;

REVOKE ALL ON FUNCTION
    public.obtener_cierre_formal_categoria_ronda(uuid,uuid)
FROM anon;

GRANT EXECUTE ON FUNCTION
    public.obtener_cierre_formal_categoria_ronda(uuid,uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION
    public.obtener_cierre_formal_categoria_ronda(uuid,uuid)
TO service_role;

-- ============================================================================
-- 6. CIERRE FORMAL DE UNA CATEGORÍA
-- ============================================================================

CREATE OR REPLACE FUNCTION
public.cerrar_categoria_competitiva_ronda(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid,
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
    v_category_tournament_id uuid;

    v_admin_id uuid;
    v_closure_id uuid;

    v_category_states jsonb;
    v_operational jsonb;

    v_category_state jsonb;
    v_leaderboard_category jsonb;

    v_ready_to_close boolean;
    v_category_status text;

    v_snapshot jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL
       OR p_tournament_category_id IS NULL
    THEN
        RAISE EXCEPTION
            'tournament_round_id y tournament_category_id son obligatorios.'
            USING ERRCODE='22023';
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
        ON t.id=tr.tournament_id
     WHERE tr.id=p_tournament_round_id
       AND tr.activo=true
     FOR UPDATE OF tr,t;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda indicada no existe o no está activa.'
            USING ERRCODE='22023';
    END IF;

    SELECT tc.tournament_id
      INTO v_category_tournament_id
      FROM public.tournament_categories tc
     WHERE tc.id=p_tournament_category_id;

    IF v_category_tournament_id IS NULL
       OR v_category_tournament_id <> v_tournament_id
    THEN
        RAISE EXCEPTION
            'La categoría indicada no pertenece al torneo de la ronda.'
            USING ERRCODE='22023';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(
            auth.uid(),
            v_tournament_id
        )
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden cerrar competitivamente la categoría.'
            USING ERRCODE='42501';
    END IF;

    IF v_tournament_status <>
       'en_curso'::public.estatus_torneo
    THEN
        RAISE EXCEPTION
            'La categoría sólo puede cerrarse formalmente cuando el torneo está EN CURSO. Estado actual: %.',
            v_tournament_status
            USING ERRCODE='23514';
    END IF;

    -- Serializa cierres y escrituras competitivas de la ronda.
    PERFORM public._bloquear_salida_ronda(
        p_tournament_round_id
    );

    -- Idempotencia.
    SELECT c.id
      INTO v_closure_id
      FROM public.tournament_round_category_competitive_closures c
     WHERE c.tournament_round_id=
            p_tournament_round_id
       AND c.tournament_category_id=
            p_tournament_category_id;

    IF v_closure_id IS NOT NULL THEN
        RETURN public.obtener_cierre_formal_categoria_ronda(
            p_tournament_round_id,
            p_tournament_category_id
        );
    END IF;

    v_category_states :=
        public.obtener_estado_competitivo_categorias_ronda(
            p_tournament_round_id
        );

    IF NOT COALESCE(
        (v_category_states->>'supported')::boolean,
        false
    ) THEN
        RAISE EXCEPTION
            'El cierre competitivo por categoría no está soportado para esta modalidad.'
            USING ERRCODE='0A000',
                  DETAIL=v_category_states::text;
    END IF;

    SELECT c
      INTO v_category_state
      FROM jsonb_array_elements(
        COALESCE(
            v_category_states->'categories',
            '[]'::jsonb
        )
      ) c
     WHERE NULLIF(
        c->>'tournamentCategoryId',
        ''
     )::uuid = p_tournament_category_id
     LIMIT 1;

    IF v_category_state IS NULL THEN
        RAISE EXCEPTION
            'La categoría no está presente en el estado competitivo de la ronda.'
            USING ERRCODE='23514';
    END IF;

    v_ready_to_close :=
        COALESCE(
            (
                v_category_state->
                'readyToClose'
            )::boolean,
            false
        );

    v_category_status :=
        v_category_state->>'status';

    IF NOT v_ready_to_close
       OR v_category_status IS DISTINCT FROM
          'READY_TO_CLOSE'
    THEN
        RAISE EXCEPTION
            'La categoría todavía no puede cerrarse competitivamente.'
            USING ERRCODE='23514',
                  DETAIL=v_category_state::text,
                  HINT=
                      'Todos los participantes de la categoría deben estar resueltos y todos sus desempates deben estar resueltos.';
    END IF;

    -- Snapshot de resultados operativos exactos al momento del cierre.
    v_operational :=
        public.obtener_leaderboard_operativo_ronda(
            p_tournament_round_id
        );

    SELECT c
      INTO v_leaderboard_category
      FROM jsonb_array_elements(
        COALESCE(
            v_operational->'categories',
            '[]'::jsonb
        )
      ) c
     WHERE NULLIF(
        c->>'tournamentCategoryId',
        ''
     )::uuid = p_tournament_category_id
     LIMIT 1;

    IF v_leaderboard_category IS NULL THEN
        RAISE EXCEPTION
            'No fue posible congelar el leaderboard de la categoría.'
            USING ERRCODE='55000';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id=auth.uid()
       AND au.activo=true
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No se encontró el usuario administrativo autenticado.'
            USING ERRCODE='42501';
    END IF;

    v_snapshot :=
        jsonb_build_object(
            'schemaVersion', 1,

            'round',
                v_category_states->'round',

            'categoryState',
                v_category_state,

            'leaderboardCategory',
                v_leaderboard_category,

            'capturedFrom',
                jsonb_build_object(
                    'categoryStateRpc',
                        'obtener_estado_competitivo_categorias_ronda',
                    'operationalLeaderboardRpc',
                        'obtener_leaderboard_operativo_ronda'
                )
        );

    INSERT INTO
        public.tournament_round_category_competitive_closures(
            tournament_id,
            tournament_round_id,
            tournament_category_id,
            round_number,
            round_date,
            competitive_status,
            closure_snapshot,
            closed_by_admin_user_id,
            notes
        )
    VALUES(
        v_tournament_id,
        p_tournament_round_id,
        p_tournament_category_id,
        v_round_number,
        v_round_date,
        'FINAL',
        v_snapshot,
        v_admin_id,
        NULLIF(
            btrim(
                COALESCE(
                    p_notas,
                    ''
                )
            ),
            ''
        )
    )
    RETURNING id
    INTO v_closure_id;

    RETURN public.obtener_cierre_formal_categoria_ronda(
        p_tournament_round_id,
        p_tournament_category_id
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.cerrar_categoria_competitiva_ronda(uuid,uuid,text)
FROM PUBLIC;

REVOKE ALL ON FUNCTION
    public.cerrar_categoria_competitiva_ronda(uuid,uuid,text)
FROM anon;

GRANT EXECUTE ON FUNCTION
    public.cerrar_categoria_competitiva_ronda(uuid,uuid,text)
TO authenticated;

GRANT EXECUTE ON FUNCTION
    public.cerrar_categoria_competitiva_ronda(uuid,uuid,text)
TO service_role;

COMMENT ON TABLE
    public.tournament_round_category_competitive_closures
IS
'Cierres competitivos formales e inmutables por categoría y ronda.';

COMMENT ON FUNCTION
    public.obtener_cierre_formal_categoria_ronda(uuid,uuid)
IS
'Consulta el cierre competitivo formal e inmutable de una categoría de una ronda.';

COMMENT ON FUNCTION
    public.cerrar_categoria_competitiva_ronda(uuid,uuid,text)
IS
'Cierra formalmente una categoría cuando 193 indica READY_TO_CLOSE. '
'Congela estado y leaderboard operativo en un snapshot y deja la categoría '
'inmutable sin cerrar las demás categorías de la ronda.';
