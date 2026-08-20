-- ============================================================================
-- 161_persistencia_resolucion_manual_desempates.sql
-- GOLF IN FULL / Tee Central
--
-- MIGRACIÓN 161 — PERSISTENCIA DE RESOLUCIÓN MANUAL DE DESEMPATES
--
-- OBJETIVO
-- Registrar de forma auditable la resolución manual de grupos de empate que el
-- motor 160 NO puede cerrar automáticamente.
--
-- CASOS SOPORTADOS
-- 1) MANUAL_PENDING
--    El motor llegó a un método manual configurado, por ejemplo:
--      - MUERTE_SUBITA
--      - SORTEO
--
--    La resolución usa forzosamente ese método configurado.
--
-- 2) TIE_PERSISTS_AFTER_RULES
--    Se agotaron los criterios automáticos y el empate continúa.
--    Se permite una resolución administrativa explícita:
--      resolution_mode = COMMITTEE_OVERRIDE
--    y exige nota/motivo.
--
-- NO SOPORTA
-- - CONFIG_MISSING:
--   primero debe corregirse la configuración de desempate.
--
-- PRINCIPIOS
-- - No modifica score.
-- - No modifica GROSS/NETO.
-- - No modifica el motor 160.
-- - No modifica el leaderboard 158.
-- - No decide premiación.
-- - No publica resultados.
-- - La corrección de una resolución se hace anulando la anterior y creando
--   una nueva; no se sobreescribe la historia.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 0. GUARDAS
-- ============================================================================

DO $$
BEGIN
    IF to_regprocedure('public.obtener_desempates_ronda(uuid)') IS NULL THEN
        RAISE EXCEPTION
            'Migración 161 requiere public.obtener_desempates_ronda(uuid) de la 160.';
    END IF;

    IF to_regclass('public.admin_users') IS NULL THEN
        RAISE EXCEPTION
            'Migración 161 requiere public.admin_users.';
    END IF;
END;
$$;

-- ============================================================================
-- 1. CABECERA DE RESOLUCIÓN MANUAL
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tournament_tiebreak_resolutions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,

    tournament_category_id uuid NOT NULL
        REFERENCES public.tournament_categories(id) ON DELETE RESTRICT,

    tipo_resultado public.tipo_resultado_desempate NOT NULL,

    base_rank integer NOT NULL CHECK (base_rank > 0),
    tied_total integer NOT NULL,
    tie_size integer NOT NULL CHECK (tie_size >= 2),

    source_engine_status text NOT NULL
        CHECK (
            source_engine_status IN (
                'MANUAL_PENDING',
                'TIE_PERSISTS_AFTER_RULES'
            )
        ),

    resolution_mode text NOT NULL
        CHECK (
            resolution_mode IN (
                'CONFIGURED_MANUAL_METHOD',
                'COMMITTEE_OVERRIDE'
            )
        ),

    method_code text NOT NULL,
    method_name text NOT NULL,

    notes text,

    status text NOT NULL DEFAULT 'COMPLETED'
        CHECK (status IN ('COMPLETED','VOIDED')),

    resolved_by_admin_user_id uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,

    resolved_at timestamptz NOT NULL DEFAULT now(),

    voided_by_admin_user_id uuid
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,

    voided_at timestamptz,

    void_reason text,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CHECK (
        (
            status='COMPLETED'
            AND voided_by_admin_user_id IS NULL
            AND voided_at IS NULL
            AND void_reason IS NULL
        )
        OR
        (
            status='VOIDED'
            AND voided_by_admin_user_id IS NOT NULL
            AND voided_at IS NOT NULL
            AND char_length(btrim(COALESCE(void_reason,''))) >= 5
        )
    ),

    CHECK (
        resolution_mode <> 'COMMITTEE_OVERRIDE'
        OR char_length(btrim(COALESCE(notes,''))) >= 10
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS
    tournament_tiebreak_resolutions_one_active
ON public.tournament_tiebreak_resolutions (
    tournament_round_id,
    tournament_category_id,
    tipo_resultado,
    base_rank,
    tied_total
)
WHERE status='COMPLETED';

CREATE INDEX IF NOT EXISTS
    idx_tournament_tiebreak_resolutions_round
ON public.tournament_tiebreak_resolutions (
    tournament_round_id,
    tournament_category_id,
    tipo_resultado,
    base_rank
);

-- ============================================================================
-- 2. PARTICIPANTES / ORDEN FINAL DEL GRUPO EMPATADO
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tournament_tiebreak_resolution_players (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    resolution_id uuid NOT NULL
        REFERENCES public.tournament_tiebreak_resolutions(id)
        ON DELETE CASCADE,

    score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id)
        ON DELETE RESTRICT,

    player_id uuid,

    player_name_snapshot text NOT NULL,

    order_in_tiebreak integer NOT NULL
        CHECK (order_in_tiebreak > 0),

    final_rank integer NOT NULL
        CHECK (final_rank > 0),

    created_at timestamptz NOT NULL DEFAULT now(),

    UNIQUE (resolution_id, score_card_id),
    UNIQUE (resolution_id, order_in_tiebreak),
    UNIQUE (resolution_id, final_rank)
);

CREATE INDEX IF NOT EXISTS
    idx_tiebreak_resolution_players_score_card
ON public.tournament_tiebreak_resolution_players(score_card_id);

-- ============================================================================
-- 3. BITÁCORA APPEND-ONLY
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tournament_tiebreak_resolution_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    resolution_id uuid NOT NULL
        REFERENCES public.tournament_tiebreak_resolutions(id)
        ON DELETE RESTRICT,

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,

    event_type text NOT NULL
        CHECK (
            event_type IN (
                'MANUAL_TIEBREAK_RESOLVED',
                'MANUAL_TIEBREAK_VOIDED'
            )
        ),

    payload jsonb NOT NULL DEFAULT '{}'::jsonb,

    actor_admin_user_id uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,

    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS
    idx_tiebreak_resolution_events_resolution
ON public.tournament_tiebreak_resolution_events(
    resolution_id,
    created_at
);

-- ============================================================================
-- 4. RLS + PRIVILEGIOS DE TABLAS
-- ============================================================================

ALTER TABLE public.tournament_tiebreak_resolutions
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.tournament_tiebreak_resolution_players
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.tournament_tiebreak_resolution_events
    ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.tournament_tiebreak_resolutions
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON public.tournament_tiebreak_resolution_players
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON public.tournament_tiebreak_resolution_events
FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 5. RPC — OBTENER RESOLUCIONES MANUALES DE UNA RONDA
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_resoluciones_desempate_ronda(
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
            USING ERRCODE='42501';
    END IF;

    SELECT tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds
     WHERE id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar resoluciones de desempate.'
            USING ERRCODE='42501';
    END IF;

    RETURN jsonb_build_object(
        'tournamentId', v_tournament_id,
        'tournamentRoundId', p_tournament_round_id,

        'resolutions',
        COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'resolutionId', r.id,
                    'tournamentCategoryId', r.tournament_category_id,
                    'resultType', r.tipo_resultado,
                    'baseRank', r.base_rank,
                    'tiedTotal', r.tied_total,
                    'tieSize', r.tie_size,

                    'sourceEngineStatus', r.source_engine_status,
                    'resolutionMode', r.resolution_mode,

                    'methodCode', r.method_code,
                    'methodName', r.method_name,
                    'notes', r.notes,

                    'status', r.status,
                    'resolvedAt', r.resolved_at,
                    'resolvedByAdminUserId',
                        r.resolved_by_admin_user_id,

                    'voidedAt', r.voided_at,
                    'voidReason', r.void_reason,

                    'players',
                    COALESCE((
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'scoreCardId', p.score_card_id,
                                'playerId', p.player_id,
                                'playerName', p.player_name_snapshot,
                                'tiebreakOrder', p.order_in_tiebreak,
                                'finalRank', p.final_rank
                            )
                            ORDER BY p.order_in_tiebreak
                        )
                        FROM public.tournament_tiebreak_resolution_players p
                        WHERE p.resolution_id=r.id
                    ), '[]'::jsonb)
                )
                ORDER BY
                    r.status,
                    r.tournament_category_id,
                    r.tipo_resultado,
                    r.base_rank,
                    r.created_at
            )
            FROM public.tournament_tiebreak_resolutions r
            WHERE r.tournament_round_id=p_tournament_round_id
        ), '[]'::jsonb)
    );
END;
$$;

-- ============================================================================
-- 6. RPC — REGISTRAR RESOLUCIÓN MANUAL
--
-- p_score_card_order:
--   arreglo UUID en orden final del desempate.
--
-- Ejemplo para empate de dos jugadores:
--   ARRAY[
--     '<score_card ganador>',
--     '<score_card segundo>'
--   ]::uuid[]
--
-- El grupo se localiza por:
--   ronda + categoría + tipo_resultado + base_rank + tied_total
-- ============================================================================

CREATE OR REPLACE FUNCTION public.resolver_desempate_manual_ronda(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid,
    p_tipo_resultado public.tipo_resultado_desempate,
    p_base_rank integer,
    p_tied_total integer,
    p_score_card_order uuid[],
    p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tournament_id uuid;
    v_admin_user_id uuid;

    v_engine jsonb;
    v_group jsonb;

    v_group_status text;
    v_manual_method_code text;
    v_manual_method_name text;

    v_resolution_mode text;
    v_method_code text;
    v_method_name text;

    v_group_size integer;
    v_order_size integer;
    v_distinct_order_size integer;
    v_group_player_match integer;

    v_resolution_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL
       OR p_tournament_category_id IS NULL
       OR p_tipo_resultado IS NULL
       OR p_base_rank IS NULL
       OR p_tied_total IS NULL
    THEN
        RAISE EXCEPTION
            'Ronda, categoría, tipo de resultado, posición base y total empatado son obligatorios.'
            USING ERRCODE='22023';
    END IF;

    SELECT tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds
     WHERE id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para resolver este desempate.'
            USING ERRCODE='42501';
    END IF;

    SELECT au.id
      INTO v_admin_user_id
      FROM public.admin_users au
     WHERE au.auth_user_id=auth.uid()
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_user_id IS NULL THEN
        RAISE EXCEPTION
            'No fue posible resolver el admin_user asociado al usuario autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_score_card_order IS NULL
       OR COALESCE(array_length(p_score_card_order,1),0) < 2
    THEN
        RAISE EXCEPTION
            'Debe indicar el orden completo de al menos dos tarjetas empatadas.'
            USING ERRCODE='22023';
    END IF;

    v_engine := public.obtener_desempates_ronda(
        p_tournament_round_id
    );

    SELECT g
      INTO v_group
      FROM jsonb_array_elements(
          COALESCE(v_engine->'tieGroups','[]'::jsonb)
      ) g
     WHERE NULLIF(g->>'tournamentCategoryId','')::uuid
           = p_tournament_category_id
       AND g->>'resultType' = p_tipo_resultado::text
       AND (g->>'baseRank')::integer = p_base_rank
       AND (g->>'tiedTotal')::integer = p_tied_total
     LIMIT 1;

    IF v_group IS NULL THEN
        RAISE EXCEPTION
            'No existe actualmente ese grupo de empate en el motor 160.'
            USING ERRCODE='55000';
    END IF;

    v_group_status := v_group->>'status';
    v_group_size := COALESCE((v_group->>'tieSize')::integer,0);

    IF v_group_status NOT IN (
        'MANUAL_PENDING',
        'TIE_PERSISTS_AFTER_RULES'
    ) THEN
        RAISE EXCEPTION
            'El grupo no requiere resolución manual. Estado actual: %',
            COALESCE(v_group_status,'NULL')
            USING ERRCODE='55000';
    END IF;

    SELECT
        count(*)::integer,
        count(DISTINCT x)::integer
      INTO v_order_size, v_distinct_order_size
      FROM unnest(p_score_card_order) x;

    IF v_order_size <> v_group_size
       OR v_distinct_order_size <> v_group_size
    THEN
        RAISE EXCEPTION
            'El orden debe contener exactamente las % tarjetas del grupo, sin duplicados.',
            v_group_size
            USING ERRCODE='22023';
    END IF;

    SELECT count(*)::integer
      INTO v_group_player_match
      FROM unnest(p_score_card_order) x
     WHERE EXISTS (
        SELECT 1
        FROM jsonb_array_elements(
            COALESCE(v_group->'players','[]'::jsonb)
        ) gp
        WHERE (gp->>'scoreCardId')::uuid=x
     );

    IF v_group_player_match <> v_group_size THEN
        RAISE EXCEPTION
            'El orden contiene tarjetas que no pertenecen exactamente al grupo de empate.'
            USING ERRCODE='22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_tiebreak_resolutions r
        WHERE r.tournament_round_id=p_tournament_round_id
          AND r.tournament_category_id=p_tournament_category_id
          AND r.tipo_resultado=p_tipo_resultado
          AND r.base_rank=p_base_rank
          AND r.tied_total=p_tied_total
          AND r.status='COMPLETED'
    ) THEN
        RAISE EXCEPTION
            'Este grupo ya tiene una resolución manual activa. Debe anularla antes de registrar otra.'
            USING ERRCODE='55000';
    END IF;

    IF v_group_status='MANUAL_PENDING' THEN
        v_manual_method_code := v_group->>'manualMethodCode';
        v_manual_method_name := v_group->>'manualMethodName';

        IF v_manual_method_code IS NULL
           OR v_manual_method_name IS NULL
        THEN
            RAISE EXCEPTION
                'El motor reportó MANUAL_PENDING pero no devolvió el método manual configurado.'
                USING ERRCODE='55000';
        END IF;

        v_resolution_mode := 'CONFIGURED_MANUAL_METHOD';
        v_method_code := v_manual_method_code;
        v_method_name := v_manual_method_name;

    ELSE
        IF char_length(btrim(COALESCE(p_notes,''))) < 10 THEN
            RAISE EXCEPTION
                'Cuando el empate persiste después de las reglas, la resolución administrativa requiere un motivo de al menos 10 caracteres.'
                USING ERRCODE='22023';
        END IF;

        v_resolution_mode := 'COMMITTEE_OVERRIDE';
        v_method_code := 'COMMITTEE_OVERRIDE';
        v_method_name := 'Resolución administrativa';
    END IF;

    INSERT INTO public.tournament_tiebreak_resolutions (
        tournament_id,
        tournament_round_id,
        tournament_category_id,
        tipo_resultado,
        base_rank,
        tied_total,
        tie_size,
        source_engine_status,
        resolution_mode,
        method_code,
        method_name,
        notes,
        status,
        resolved_by_admin_user_id,
        resolved_at
    )
    VALUES (
        v_tournament_id,
        p_tournament_round_id,
        p_tournament_category_id,
        p_tipo_resultado,
        p_base_rank,
        p_tied_total,
        v_group_size,
        v_group_status,
        v_resolution_mode,
        v_method_code,
        v_method_name,
        NULLIF(btrim(COALESCE(p_notes,'')),''),
        'COMPLETED',
        v_admin_user_id,
        now()
    )
    RETURNING id INTO v_resolution_id;

    INSERT INTO public.tournament_tiebreak_resolution_players (
        resolution_id,
        score_card_id,
        player_id,
        player_name_snapshot,
        order_in_tiebreak,
        final_rank
    )
    SELECT
        v_resolution_id,
        x.score_card_id,
        NULLIF(gp->>'playerId','')::uuid,
        COALESCE(gp->>'playerName','(SIN NOMBRE)'),
        x.ord::integer,
        p_base_rank + x.ord::integer - 1
    FROM unnest(p_score_card_order)
         WITH ORDINALITY AS x(score_card_id,ord)
    JOIN LATERAL (
        SELECT gp
        FROM jsonb_array_elements(
            COALESCE(v_group->'players','[]'::jsonb)
        ) gp
        WHERE (gp->>'scoreCardId')::uuid=x.score_card_id
        LIMIT 1
    ) q(gp) ON true;

    INSERT INTO public.tournament_tiebreak_resolution_events (
        resolution_id,
        tournament_id,
        tournament_round_id,
        event_type,
        payload,
        actor_admin_user_id
    )
    VALUES (
        v_resolution_id,
        v_tournament_id,
        p_tournament_round_id,
        'MANUAL_TIEBREAK_RESOLVED',
        jsonb_build_object(
            'tournamentCategoryId', p_tournament_category_id,
            'resultType', p_tipo_resultado,
            'baseRank', p_base_rank,
            'tiedTotal', p_tied_total,
            'tieSize', v_group_size,
            'sourceEngineStatus', v_group_status,
            'resolutionMode', v_resolution_mode,
            'methodCode', v_method_code,
            'methodName', v_method_name,
            'scoreCardOrder', to_jsonb(p_score_card_order),
            'notes', NULLIF(btrim(COALESCE(p_notes,'')),'')
        ),
        v_admin_user_id
    );

    RETURN jsonb_build_object(
        'resolutionId', v_resolution_id,
        'status', 'COMPLETED',
        'sourceEngineStatus', v_group_status,
        'resolutionMode', v_resolution_mode,
        'methodCode', v_method_code,
        'methodName', v_method_name,
        'players',
        (
            SELECT jsonb_agg(
                jsonb_build_object(
                    'scoreCardId', p.score_card_id,
                    'playerId', p.player_id,
                    'playerName', p.player_name_snapshot,
                    'tiebreakOrder', p.order_in_tiebreak,
                    'finalRank', p.final_rank
                )
                ORDER BY p.order_in_tiebreak
            )
            FROM public.tournament_tiebreak_resolution_players p
            WHERE p.resolution_id=v_resolution_id
        )
    );
END;
$$;

-- ============================================================================
-- 7. RPC — ANULAR RESOLUCIÓN MANUAL
-- ============================================================================

CREATE OR REPLACE FUNCTION public.anular_resolucion_desempate_manual(
    p_resolution_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_resolution public.tournament_tiebreak_resolutions%ROWTYPE;
    v_admin_user_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF char_length(btrim(COALESCE(p_reason,''))) < 5 THEN
        RAISE EXCEPTION
            'El motivo de anulación debe tener al menos 5 caracteres.'
            USING ERRCODE='22023';
    END IF;

    SELECT *
      INTO v_resolution
      FROM public.tournament_tiebreak_resolutions
     WHERE id=p_resolution_id
     FOR UPDATE;

    IF v_resolution.id IS NULL THEN
        RAISE EXCEPTION
            'La resolución indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_resolution.tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para anular esta resolución.'
            USING ERRCODE='42501';
    END IF;

    IF v_resolution.status <> 'COMPLETED' THEN
        RAISE EXCEPTION
            'La resolución ya no está activa.'
            USING ERRCODE='55000';
    END IF;

    SELECT au.id
      INTO v_admin_user_id
      FROM public.admin_users au
     WHERE au.auth_user_id=auth.uid()
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_user_id IS NULL THEN
        RAISE EXCEPTION
            'No fue posible resolver el admin_user asociado al usuario autenticado.'
            USING ERRCODE='42501';
    END IF;

    UPDATE public.tournament_tiebreak_resolutions
       SET status='VOIDED',
           voided_by_admin_user_id=v_admin_user_id,
           voided_at=now(),
           void_reason=btrim(p_reason),
           updated_at=now()
     WHERE id=p_resolution_id;

    INSERT INTO public.tournament_tiebreak_resolution_events (
        resolution_id,
        tournament_id,
        tournament_round_id,
        event_type,
        payload,
        actor_admin_user_id
    )
    VALUES (
        p_resolution_id,
        v_resolution.tournament_id,
        v_resolution.tournament_round_id,
        'MANUAL_TIEBREAK_VOIDED',
        jsonb_build_object(
            'reason', btrim(p_reason)
        ),
        v_admin_user_id
    );

    RETURN jsonb_build_object(
        'resolutionId', p_resolution_id,
        'status', 'VOIDED',
        'voidReason', btrim(p_reason)
    );
END;
$$;

-- ============================================================================
-- 8. PRIVILEGIOS RPC
-- ============================================================================

REVOKE ALL ON FUNCTION public.obtener_resoluciones_desempate_ronda(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.obtener_resoluciones_desempate_ronda(uuid)
TO authenticated;

REVOKE ALL ON FUNCTION public.resolver_desempate_manual_ronda(
    uuid,uuid,tipo_resultado_desempate,integer,integer,uuid[],text
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.resolver_desempate_manual_ronda(
    uuid,uuid,tipo_resultado_desempate,integer,integer,uuid[],text
)
TO authenticated;

REVOKE ALL ON FUNCTION public.anular_resolucion_desempate_manual(uuid,text)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.anular_resolucion_desempate_manual(uuid,text)
TO authenticated;

COMMIT;
