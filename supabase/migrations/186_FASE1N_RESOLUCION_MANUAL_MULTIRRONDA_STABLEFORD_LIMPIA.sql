-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 186 Fase 1N
-- Resolución manual multirronda + leaderboard final acumulado
--
-- DISEÑO
--   Las tablas de resolución por ronda existentes NO se deforman:
--   - tournament_round_id es obligatorio;
--   - sus participantes se identifican por score_card_id.
--
--   Para acumulados se crea infraestructura genérica a nivel torneo:
--   - identidad: tournament_registration_id;
--   - scoring_engine explícito;
--   - sin ronda ficticia;
--   - RLS + acceso operativo sólo por RPC SECURITY DEFINER.
--
-- ALCANCE
--   1) Persistir resolución manual de empates acumulados.
--   2) Anular resolución acumulada con bitácora.
--   3) Consultar resoluciones acumuladas.
--   4) Aplicar automáticos 1M + manuales al leaderboard final del torneo.
--
-- NO HACE
--   - No modifica resoluciones por ronda.
--   - No modifica Stroke Play.
--   - No define propagación global de DQ/WD/DNF/DNS/NO_CARD.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Cabecera genérica de resolución acumulada.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_aggregate_tiebreak_resolutions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,

    tournament_category_id uuid NOT NULL
        REFERENCES public.tournament_categories(id) ON DELETE RESTRICT,

    scoring_engine text NOT NULL,
    tipo_resultado public.tipo_resultado_desempate NOT NULL,

    base_rank integer NOT NULL,
    tied_total integer NOT NULL,
    tie_size integer NOT NULL,

    source_engine_status text NOT NULL,
    resolution_mode text NOT NULL,

    method_code text NOT NULL,
    method_name text NOT NULL,

    notes text NULL,

    status text NOT NULL DEFAULT 'COMPLETED',

    resolved_by_admin_user_id uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    resolved_at timestamptz NOT NULL DEFAULT now(),

    voided_by_admin_user_id uuid NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    voided_at timestamptz NULL,
    void_reason text NULL,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_aggregate_tiebreak_resolutions_engine_ck
        CHECK (char_length(btrim(scoring_engine)) >= 3),

    CONSTRAINT tournament_aggregate_tiebreak_resolutions_base_rank_ck
        CHECK (base_rank > 0),

    CONSTRAINT tournament_aggregate_tiebreak_resolutions_tie_size_ck
        CHECK (tie_size >= 2),

    CONSTRAINT tournament_aggregate_tiebreak_resolutions_source_status_ck
        CHECK (
            source_engine_status IN (
                'MANUAL_PENDING',
                'TIE_PERSISTS_AFTER_RULES'
            )
        ),

    CONSTRAINT tournament_aggregate_tiebreak_resolutions_mode_ck
        CHECK (
            resolution_mode IN (
                'CONFIGURED_MANUAL_METHOD',
                'COMMITTEE_OVERRIDE'
            )
        ),

    CONSTRAINT tournament_aggregate_tiebreak_resolutions_status_ck
        CHECK (status IN ('COMPLETED','VOIDED')),

    CONSTRAINT tournament_aggregate_tiebreak_resolutions_override_notes_ck
        CHECK (
            resolution_mode <> 'COMMITTEE_OVERRIDE'
            OR char_length(btrim(COALESCE(notes,''))) >= 10
        ),

    CONSTRAINT tournament_aggregate_tiebreak_resolutions_void_ck
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
        )
);

CREATE INDEX IF NOT EXISTS idx_aggregate_tiebreak_resolutions_tournament
ON public.tournament_aggregate_tiebreak_resolutions(
    tournament_id,
    tournament_category_id,
    scoring_engine,
    tipo_resultado,
    base_rank
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_aggregate_tiebreak_resolution_active
ON public.tournament_aggregate_tiebreak_resolutions(
    tournament_id,
    tournament_category_id,
    scoring_engine,
    tipo_resultado,
    base_rank,
    tied_total
)
WHERE status='COMPLETED';

ALTER TABLE public.tournament_aggregate_tiebreak_resolutions
ENABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS trg_aggregate_tiebreak_resolutions_updated_at
ON public.tournament_aggregate_tiebreak_resolutions;

CREATE TRIGGER trg_aggregate_tiebreak_resolutions_updated_at
BEFORE UPDATE
ON public.tournament_aggregate_tiebreak_resolutions
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 2. Participantes de resolución acumulada.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_aggregate_tiebreak_resolution_players (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    resolution_id uuid NOT NULL
        REFERENCES public.tournament_aggregate_tiebreak_resolutions(id)
        ON DELETE CASCADE,

    tournament_registration_id uuid NOT NULL
        REFERENCES public.tournament_registrations(id)
        ON DELETE RESTRICT,

    player_id uuid NULL
        REFERENCES public.players(id)
        ON DELETE RESTRICT,

    player_name_snapshot text NOT NULL,

    order_in_tiebreak integer NOT NULL,
    final_rank integer NOT NULL,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_aggregate_tiebreak_players_order_ck
        CHECK (order_in_tiebreak > 0),

    CONSTRAINT tournament_aggregate_tiebreak_players_rank_ck
        CHECK (final_rank > 0),

    CONSTRAINT tournament_aggregate_tiebreak_players_resolution_registration_uk
        UNIQUE (resolution_id,tournament_registration_id),

    CONSTRAINT tournament_aggregate_tiebreak_players_resolution_order_uk
        UNIQUE (resolution_id,order_in_tiebreak),

    CONSTRAINT tournament_aggregate_tiebreak_players_resolution_rank_uk
        UNIQUE (resolution_id,final_rank)
);

ALTER TABLE public.tournament_aggregate_tiebreak_resolution_players
ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- 3. Bitácora inmutable de resolución acumulada.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_aggregate_tiebreak_resolution_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    resolution_id uuid NOT NULL
        REFERENCES public.tournament_aggregate_tiebreak_resolutions(id)
        ON DELETE RESTRICT,

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id)
        ON DELETE RESTRICT,

    event_type text NOT NULL,

    payload jsonb NOT NULL DEFAULT '{}'::jsonb,

    actor_admin_user_id uuid NOT NULL
        REFERENCES public.admin_users(id)
        ON DELETE RESTRICT,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_aggregate_tiebreak_events_type_ck
        CHECK (
            event_type IN (
                'MANUAL_AGGREGATE_TIEBREAK_RESOLVED',
                'MANUAL_AGGREGATE_TIEBREAK_VOIDED'
            )
        )
);

ALTER TABLE public.tournament_aggregate_tiebreak_resolution_events
ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public._impedir_mutacion_evento_desempate_acumulado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION
        'La bitácora de desempates acumulados es inmutable.'
        USING ERRCODE='55000';
END;
$function$;

DROP TRIGGER IF EXISTS trg_impedir_mutacion_evento_desempate_acumulado
ON public.tournament_aggregate_tiebreak_resolution_events;

CREATE TRIGGER trg_impedir_mutacion_evento_desempate_acumulado
BEFORE UPDATE OR DELETE
ON public.tournament_aggregate_tiebreak_resolution_events
FOR EACH ROW
EXECUTE FUNCTION public._impedir_mutacion_evento_desempate_acumulado();

-- Sin acceso directo desde clientes.
REVOKE ALL ON TABLE public.tournament_aggregate_tiebreak_resolutions
FROM anon,authenticated;

REVOKE ALL ON TABLE public.tournament_aggregate_tiebreak_resolution_players
FROM anon,authenticated;

REVOKE ALL ON TABLE public.tournament_aggregate_tiebreak_resolution_events
FROM anon,authenticated;

-- ----------------------------------------------------------------------------
-- 4. Resolver manual acumulado Stableford.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.resolver_desempate_manual_stableford_torneo(
    p_tournament_id uuid,
    p_tournament_category_id uuid,
    p_tipo_resultado public.tipo_resultado_desempate,
    p_base_rank integer,
    p_tied_total integer,
    p_registration_order uuid[],
    p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
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

    IF p_tournament_id IS NULL
       OR p_tournament_category_id IS NULL
       OR p_tipo_resultado IS NULL
       OR p_base_rank IS NULL
       OR p_tied_total IS NULL
    THEN
        RAISE EXCEPTION
            'Torneo, categoría, tipo de resultado, posición base y puntos empatados son obligatorios.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para resolver este desempate acumulado.'
            USING ERRCODE='42501';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.tournament_categories tc
        WHERE tc.id=p_tournament_category_id
          AND tc.tournament_id=p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'La categoría indicada no pertenece al torneo.'
            USING ERRCODE='22023';
    END IF;

    v_admin_user_id := public._scorecard_current_admin_id();

    IF v_admin_user_id IS NULL THEN
        RAISE EXCEPTION
            'No fue posible resolver el admin_user asociado al usuario autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_registration_order IS NULL
       OR COALESCE(array_length(p_registration_order,1),0)<2
    THEN
        RAISE EXCEPTION
            'Debe indicar el orden completo de al menos dos inscripciones empatadas.'
            USING ERRCODE='22023';
    END IF;

    v_engine :=
        public.obtener_desempates_stableford_torneo(
            p_tournament_id
        );

    SELECT g
      INTO v_group
      FROM jsonb_array_elements(
          COALESCE(v_engine->'tieGroups','[]'::jsonb)
      ) g
     WHERE NULLIF(g->>'tournamentCategoryId','')::uuid
              =p_tournament_category_id
       AND g->>'resultType'=p_tipo_resultado::text
       AND (g->>'baseRank')::integer=p_base_rank
       AND (g->>'tiedPoints')::integer=p_tied_total
     LIMIT 1;

    IF v_group IS NULL THEN
        RAISE EXCEPTION
            'No existe actualmente ese grupo de empate acumulado Stableford.'
            USING ERRCODE='55000';
    END IF;

    v_group_status := v_group->>'status';
    v_group_size := COALESCE(
        (v_group->>'tieSize')::integer,
        0
    );

    IF v_group_status NOT IN (
        'MANUAL_PENDING',
        'TIE_PERSISTS_AFTER_RULES'
    ) THEN
        RAISE EXCEPTION
            'El grupo acumulado no requiere resolución manual. Estado actual: %',
            COALESCE(v_group_status,'NULL')
            USING ERRCODE='55000';
    END IF;

    SELECT
        count(*)::integer,
        count(DISTINCT x)::integer
      INTO
        v_order_size,
        v_distinct_order_size
      FROM unnest(p_registration_order) x;

    IF v_order_size<>v_group_size
       OR v_distinct_order_size<>v_group_size
    THEN
        RAISE EXCEPTION
            'El orden debe contener exactamente las % inscripciones del grupo, sin duplicados.',
            v_group_size
            USING ERRCODE='22023';
    END IF;

    SELECT count(*)::integer
      INTO v_group_player_match
      FROM unnest(p_registration_order) x
     WHERE EXISTS (
        SELECT 1
        FROM jsonb_array_elements(
            COALESCE(v_group->'players','[]'::jsonb)
        ) gp
        WHERE NULLIF(
            gp->>'tournamentRegistrationId',
            ''
        )::uuid=x
     );

    IF v_group_player_match<>v_group_size THEN
        RAISE EXCEPTION
            'El orden contiene inscripciones que no pertenecen exactamente al grupo de empate.'
            USING ERRCODE='22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_aggregate_tiebreak_resolutions r
        WHERE r.tournament_id=p_tournament_id
          AND r.tournament_category_id=p_tournament_category_id
          AND r.scoring_engine='stableford'
          AND r.tipo_resultado=p_tipo_resultado
          AND r.base_rank=p_base_rank
          AND r.tied_total=p_tied_total
          AND r.status='COMPLETED'
    ) THEN
        RAISE EXCEPTION
            'Este grupo acumulado ya tiene una resolución manual activa. Debe anularla antes de registrar otra.'
            USING ERRCODE='55000';
    END IF;

    IF v_group_status='MANUAL_PENDING' THEN
        v_manual_method_code :=
            v_group->>'manualMethodCode';

        v_manual_method_name :=
            v_group->>'manualMethodName';

        IF v_manual_method_code IS NULL
           OR v_manual_method_name IS NULL
        THEN
            RAISE EXCEPTION
                'El motor acumulado reportó MANUAL_PENDING sin método manual configurado.'
                USING ERRCODE='55000';
        END IF;

        v_resolution_mode :=
            'CONFIGURED_MANUAL_METHOD';

        v_method_code :=
            v_manual_method_code;

        v_method_name :=
            v_manual_method_name;
    ELSE
        IF char_length(
            btrim(COALESCE(p_notes,''))
        )<10 THEN
            RAISE EXCEPTION
                'Cuando el empate acumulado persiste después de las reglas, la resolución administrativa requiere un motivo de al menos 10 caracteres.'
                USING ERRCODE='22023';
        END IF;

        v_resolution_mode :=
            'COMMITTEE_OVERRIDE';

        v_method_code :=
            'COMMITTEE_OVERRIDE';

        v_method_name :=
            'Resolución administrativa';
    END IF;

    INSERT INTO public.tournament_aggregate_tiebreak_resolutions(
        tournament_id,
        tournament_category_id,
        scoring_engine,
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
    VALUES(
        p_tournament_id,
        p_tournament_category_id,
        'stableford',
        p_tipo_resultado,
        p_base_rank,
        p_tied_total,
        v_group_size,
        v_group_status,
        v_resolution_mode,
        v_method_code,
        v_method_name,
        NULLIF(
            btrim(COALESCE(p_notes,'')),
            ''
        ),
        'COMPLETED',
        v_admin_user_id,
        now()
    )
    RETURNING id
      INTO v_resolution_id;

    INSERT INTO public.tournament_aggregate_tiebreak_resolution_players(
        resolution_id,
        tournament_registration_id,
        player_id,
        player_name_snapshot,
        order_in_tiebreak,
        final_rank
    )
    SELECT
        v_resolution_id,
        x.tournament_registration_id,
        NULLIF(gp->>'playerId','')::uuid,
        COALESCE(
            gp->>'playerName',
            '(SIN NOMBRE)'
        ),
        x.ord::integer,
        p_base_rank+x.ord::integer-1

    FROM unnest(p_registration_order)
         WITH ORDINALITY AS
         x(tournament_registration_id,ord)

    JOIN LATERAL (
        SELECT gp
        FROM jsonb_array_elements(
            COALESCE(v_group->'players','[]'::jsonb)
        ) gp
        WHERE NULLIF(
            gp->>'tournamentRegistrationId',
            ''
        )::uuid=x.tournament_registration_id
        LIMIT 1
    ) q(gp)
      ON true;

    INSERT INTO public.tournament_aggregate_tiebreak_resolution_events(
        resolution_id,
        tournament_id,
        event_type,
        payload,
        actor_admin_user_id
    )
    VALUES(
        v_resolution_id,
        p_tournament_id,
        'MANUAL_AGGREGATE_TIEBREAK_RESOLVED',
        jsonb_build_object(
            'scoringEngine','stableford',
            'tournamentCategoryId',
                p_tournament_category_id,
            'resultType',
                p_tipo_resultado,
            'baseRank',
                p_base_rank,
            'tiedPoints',
                p_tied_total,
            'tieSize',
                v_group_size,
            'sourceEngineStatus',
                v_group_status,
            'resolutionMode',
                v_resolution_mode,
            'methodCode',
                v_method_code,
            'methodName',
                v_method_name,
            'registrationOrder',
                to_jsonb(p_registration_order),
            'notes',
                NULLIF(
                    btrim(COALESCE(p_notes,'')),
                    ''
                )
        ),
        v_admin_user_id
    );

    RETURN jsonb_build_object(
        'resolutionId',
            v_resolution_id,
        'tournamentId',
            p_tournament_id,
        'scoringEngine',
            'stableford',
        'status',
            'COMPLETED',
        'sourceEngineStatus',
            v_group_status,
        'resolutionMode',
            v_resolution_mode,
        'methodCode',
            v_method_code,
        'methodName',
            v_method_name,

        'players',(
            SELECT jsonb_agg(
                jsonb_build_object(
                    'tournamentRegistrationId',
                        p.tournament_registration_id,
                    'playerId',
                        p.player_id,
                    'playerName',
                        p.player_name_snapshot,
                    'tiebreakOrder',
                        p.order_in_tiebreak,
                    'finalRank',
                        p.final_rank
                )
                ORDER BY p.order_in_tiebreak
            )
            FROM public.tournament_aggregate_tiebreak_resolution_players p
            WHERE p.resolution_id=v_resolution_id
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.resolver_desempate_manual_stableford_torneo(
        uuid,uuid,public.tipo_resultado_desempate,
        integer,integer,uuid[],text
    )
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    public.resolver_desempate_manual_stableford_torneo(
        uuid,uuid,public.tipo_resultado_desempate,
        integer,integer,uuid[],text
    )
TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 5. Anular resolución acumulada.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.anular_resolucion_desempate_acumulado(
    p_resolution_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_resolution
        public.tournament_aggregate_tiebreak_resolutions%ROWTYPE;

    v_admin_user_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF char_length(
        btrim(COALESCE(p_reason,''))
    )<5 THEN
        RAISE EXCEPTION
            'El motivo de anulación debe tener al menos 5 caracteres.'
            USING ERRCODE='22023';
    END IF;

    SELECT *
      INTO v_resolution
      FROM public.tournament_aggregate_tiebreak_resolutions
     WHERE id=p_resolution_id
     FOR UPDATE;

    IF v_resolution.id IS NULL THEN
        RAISE EXCEPTION
            'La resolución acumulada indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_resolution.tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para anular esta resolución acumulada.'
            USING ERRCODE='42501';
    END IF;

    IF v_resolution.status<>'COMPLETED' THEN
        RAISE EXCEPTION
            'La resolución acumulada ya no está activa.'
            USING ERRCODE='55000';
    END IF;

    v_admin_user_id :=
        public._scorecard_current_admin_id();

    IF v_admin_user_id IS NULL THEN
        RAISE EXCEPTION
            'No fue posible resolver el admin_user asociado al usuario autenticado.'
            USING ERRCODE='42501';
    END IF;

    UPDATE public.tournament_aggregate_tiebreak_resolutions
       SET status='VOIDED',
           voided_by_admin_user_id=v_admin_user_id,
           voided_at=now(),
           void_reason=btrim(p_reason),
           updated_at=now()
     WHERE id=p_resolution_id;

    INSERT INTO public.tournament_aggregate_tiebreak_resolution_events(
        resolution_id,
        tournament_id,
        event_type,
        payload,
        actor_admin_user_id
    )
    VALUES(
        p_resolution_id,
        v_resolution.tournament_id,
        'MANUAL_AGGREGATE_TIEBREAK_VOIDED',
        jsonb_build_object(
            'scoringEngine',
                v_resolution.scoring_engine,
            'reason',
                btrim(p_reason)
        ),
        v_admin_user_id
    );

    RETURN jsonb_build_object(
        'resolutionId',
            p_resolution_id,
        'status',
            'VOIDED',
        'voidReason',
            btrim(p_reason)
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.anular_resolucion_desempate_acumulado(uuid,text)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    public.anular_resolucion_desempate_acumulado(uuid,text)
TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 6. Consultar resoluciones acumuladas del torneo.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_resoluciones_desempate_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.tournaments
        WHERE id=p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'El torneo indicado no existe.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso administrativo para consultar resoluciones acumuladas.'
            USING ERRCODE='42501';
    END IF;

    RETURN jsonb_build_object(
        'tournamentId',
            p_tournament_id,

        'resolutions',
            COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'resolutionId',
                            r.id,
                        'tournamentCategoryId',
                            r.tournament_category_id,
                        'scoringEngine',
                            r.scoring_engine,
                        'resultType',
                            r.tipo_resultado,
                        'baseRank',
                            r.base_rank,
                        'tiedTotal',
                            r.tied_total,
                        'tieSize',
                            r.tie_size,

                        'sourceEngineStatus',
                            r.source_engine_status,
                        'resolutionMode',
                            r.resolution_mode,

                        'methodCode',
                            r.method_code,
                        'methodName',
                            r.method_name,
                        'notes',
                            r.notes,

                        'status',
                            r.status,
                        'resolvedAt',
                            r.resolved_at,
                        'resolvedByAdminUserId',
                            r.resolved_by_admin_user_id,

                        'voidedAt',
                            r.voided_at,
                        'voidReason',
                            r.void_reason,

                        'players',
                            COALESCE((
                                SELECT jsonb_agg(
                                    jsonb_build_object(
                                        'tournamentRegistrationId',
                                            p.tournament_registration_id,
                                        'playerId',
                                            p.player_id,
                                        'playerName',
                                            p.player_name_snapshot,
                                        'tiebreakOrder',
                                            p.order_in_tiebreak,
                                        'finalRank',
                                            p.final_rank
                                    )
                                    ORDER BY p.order_in_tiebreak
                                )
                                FROM public.tournament_aggregate_tiebreak_resolution_players p
                                WHERE p.resolution_id=r.id
                            ),'[]'::jsonb)
                    )
                    ORDER BY
                        r.status,
                        r.tournament_category_id,
                        r.tipo_resultado,
                        r.base_rank,
                        r.created_at
                )
                FROM public.tournament_aggregate_tiebreak_resolutions r
                WHERE r.tournament_id=p_tournament_id
            ),'[]'::jsonb)
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.obtener_resoluciones_desempate_torneo(uuid)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    public.obtener_resoluciones_desempate_torneo(uuid)
TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 7. Leaderboard acumulado final: automático + manual.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_leaderboard_stableford_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_results jsonb;
    v_ties jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    v_results :=
        public.obtener_resultados_stableford_torneo(
            p_tournament_id
        );

    v_ties :=
        public.obtener_desempates_stableford_torneo(
            p_tournament_id
        );

    RETURN (
        WITH raw AS (
            SELECT
                NULLIF(
                    p->>'tournamentRegistrationId',
                    ''
                )::uuid
                    AS tournament_registration_id,

                NULLIF(p->>'playerId','')::uuid
                    AS player_id,

                p->>'playerName'
                    AS player_name,

                NULLIF(
                    p->>'tournamentCategoryId',
                    ''
                )::uuid
                    AS tournament_category_id,

                p->>'categoryCode'
                    AS category_code,

                p->>'categoryName'
                    AS category_name,

                NULLIF(
                    p->>'categoryDisplayOrder',
                    ''
                )::integer
                    AS category_display_order,

                COALESCE(
                    (p->>'ready')::boolean,
                    false
                )
                    AS accumulation_ready,

                p->>'accumulationStatus'
                    AS accumulation_status,

                COALESCE(
                    (p->>'grossEnabled')::boolean,
                    false
                )
                    AS gross_enabled,

                COALESCE(
                    (p->>'netEnabled')::boolean,
                    false
                )
                    AS net_enabled,

                NULLIF(
                    p->>'grossPointsTotal',
                    ''
                )::integer
                    AS gross_points_total,

                NULLIF(
                    p->>'netPointsTotal',
                    ''
                )::integer
                    AS net_points_total,

                p->'rounds'
                    AS rounds

            FROM jsonb_array_elements(
                v_results->'players'
            ) p
        ),

        gross_base AS (
            SELECT
                r.tournament_registration_id,

                rank() OVER (
                    PARTITION BY
                        r.tournament_category_id
                    ORDER BY
                        r.gross_points_total DESC
                )::integer
                    AS base_rank,

                count(*) OVER (
                    PARTITION BY
                        r.tournament_category_id,
                        r.gross_points_total
                )::integer
                    AS tie_size

            FROM raw r

            WHERE r.accumulation_ready
              AND r.gross_enabled
        ),

        net_base AS (
            SELECT
                r.tournament_registration_id,

                rank() OVER (
                    PARTITION BY
                        r.tournament_category_id
                    ORDER BY
                        r.net_points_total DESC
                )::integer
                    AS base_rank,

                count(*) OVER (
                    PARTITION BY
                        r.tournament_category_id,
                        r.net_points_total
                )::integer
                    AS tie_size

            FROM raw r

            WHERE r.accumulation_ready
              AND r.net_enabled
        ),

        automatic_players AS (
            SELECT
                NULLIF(
                    g->>'tournamentCategoryId',
                    ''
                )::uuid
                    AS tournament_category_id,

                g->>'resultType'
                    AS result_type,

                (g->>'tiedPoints')::integer
                    AS tied_points,

                (g->>'baseRank')::integer
                    AS base_rank,

                g->>'status'
                    AS group_status,

                NULLIF(
                    p->>'tournamentRegistrationId',
                    ''
                )::uuid
                    AS tournament_registration_id,

                NULLIF(
                    p->>'finalRank',
                    ''
                )::integer
                    AS final_rank,

                NULLIF(
                    p->>'tiebreakOrder',
                    ''
                )::integer
                    AS tiebreak_order,

                g->>'resolvedByMethodCode'
                    AS method_code,

                g->>'resolvedByMethodName'
                    AS method_name,

                NULL::uuid
                    AS resolution_id

            FROM jsonb_array_elements(
                COALESCE(
                    v_ties->'tieGroups',
                    '[]'::jsonb
                )
            ) g

            CROSS JOIN LATERAL
            jsonb_array_elements(
                COALESCE(
                    g->'players',
                    '[]'::jsonb
                )
            ) p

            WHERE g->>'status'='RESOLVED_AUTOMATIC'
        ),

        manual_players AS (
            SELECT
                r.tournament_category_id,

                r.tipo_resultado::text
                    AS result_type,

                r.tied_total
                    AS tied_points,

                r.base_rank,

                'RESOLVED_MANUAL'::text
                    AS group_status,

                p.tournament_registration_id,

                p.final_rank,

                p.order_in_tiebreak
                    AS tiebreak_order,

                r.method_code,

                r.method_name,

                r.id
                    AS resolution_id

            FROM public.tournament_aggregate_tiebreak_resolutions r

            JOIN public.tournament_aggregate_tiebreak_resolution_players p
              ON p.resolution_id=r.id

            WHERE r.tournament_id=p_tournament_id
              AND r.scoring_engine='stableford'
              AND r.status='COMPLETED'
        ),

        resolved_players AS (
            SELECT * FROM automatic_players

            UNION ALL

            SELECT * FROM manual_players
        ),

        combined AS (
            SELECT
                r.*,

                gb.base_rank
                    AS gross_base_rank,

                gb.tie_size
                    AS gross_tie_size,

                nb.base_rank
                    AS net_base_rank,

                nb.tie_size
                    AS net_tie_size,

                grp.final_rank
                    AS gross_resolved_rank,

                grp.group_status
                    AS gross_tiebreak_status,

                grp.method_code
                    AS gross_tiebreak_method_code,

                grp.method_name
                    AS gross_tiebreak_method_name,

                grp.resolution_id
                    AS gross_resolution_id,

                nrp.final_rank
                    AS net_resolved_rank,

                nrp.group_status
                    AS net_tiebreak_status,

                nrp.method_code
                    AS net_tiebreak_method_code,

                nrp.method_name
                    AS net_tiebreak_method_name,

                nrp.resolution_id
                    AS net_resolution_id,

                CASE
                    WHEN NOT r.gross_enabled
                        THEN NULL

                    WHEN NOT r.accumulation_ready
                        THEN NULL

                    WHEN COALESCE(
                        gb.tie_size,
                        0
                    )<=1
                        THEN gb.base_rank

                    ELSE grp.final_rank
                END
                    AS gross_final_rank,

                CASE
                    WHEN NOT r.net_enabled
                        THEN NULL

                    WHEN NOT r.accumulation_ready
                        THEN NULL

                    WHEN COALESCE(
                        nb.tie_size,
                        0
                    )<=1
                        THEN nb.base_rank

                    ELSE nrp.final_rank
                END
                    AS net_final_rank

            FROM raw r

            LEFT JOIN gross_base gb
              ON gb.tournament_registration_id
                    =r.tournament_registration_id

            LEFT JOIN net_base nb
              ON nb.tournament_registration_id
                    =r.tournament_registration_id

            LEFT JOIN resolved_players grp
              ON grp.tournament_registration_id
                    =r.tournament_registration_id
             AND grp.tournament_category_id
                    IS NOT DISTINCT FROM
                    r.tournament_category_id
             AND grp.result_type='gross'
             AND grp.base_rank=gb.base_rank
             AND grp.tied_points
                    =r.gross_points_total

            LEFT JOIN resolved_players nrp
              ON nrp.tournament_registration_id
                    =r.tournament_registration_id
             AND nrp.tournament_category_id
                    IS NOT DISTINCT FROM
                    r.tournament_category_id
             AND nrp.result_type='neto'
             AND nrp.base_rank=nb.base_rank
             AND nrp.tied_points
                    =r.net_points_total
        ),

        categories AS (
            SELECT
                tournament_category_id,
                category_code,
                category_name,
                category_display_order,

                count(*)
                    AS total_players,

                count(*) FILTER (
                    WHERE accumulation_ready
                )
                    AS official_players,

                bool_or(
                    gross_enabled
                    AND accumulation_ready
                    AND COALESCE(
                        gross_tie_size,
                        0
                    )>1
                    AND gross_final_rank IS NULL
                )
                    AS gross_tiebreak_pending,

                bool_or(
                    net_enabled
                    AND accumulation_ready
                    AND COALESCE(
                        net_tie_size,
                        0
                    )>1
                    AND net_final_rank IS NULL
                )
                    AS net_tiebreak_pending

            FROM combined

            GROUP BY
                tournament_category_id,
                category_code,
                category_name,
                category_display_order
        ),

        global_state AS (
            SELECT
                count(*) FILTER (
                    WHERE NOT accumulation_ready
                )
                    AS pending_players,

                count(*) FILTER (
                    WHERE gross_enabled
                      AND accumulation_ready
                      AND COALESCE(
                          gross_tie_size,
                          0
                      )>1
                      AND gross_final_rank IS NULL
                )
                +
                count(*) FILTER (
                    WHERE net_enabled
                      AND accumulation_ready
                      AND COALESCE(
                          net_tie_size,
                          0
                      )>1
                      AND net_final_rank IS NULL
                )
                    AS unresolved_tie_entries

            FROM combined
        )

        SELECT jsonb_build_object(
            'tournamentId',
                p_tournament_id,

            'roundsRequired',
                v_results->'roundsRequired',

            'status',(
                SELECT jsonb_build_object(
                    'pendingPlayers',
                        pending_players,

                    'unresolvedTieEntries',
                        unresolved_tie_entries,

                    'leaderboardStatus',
                        CASE
                            WHEN pending_players>0
                                THEN 'PROVISIONAL'

                            WHEN unresolved_tie_entries>0
                                THEN 'READY_FOR_TIEBREAK'

                            ELSE 'READY_FOR_PUBLICATION'
                        END
                )

                FROM global_state
            ),

            'categories',
                COALESCE((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'tournamentCategoryId',
                                c.tournament_category_id,

                            'categoryCode',
                                c.category_code,

                            'categoryName',
                                c.category_name,

                            'categoryDisplayOrder',
                                c.category_display_order,

                            'summary',
                                jsonb_build_object(
                                    'totalPlayers',
                                        c.total_players,

                                    'officialPlayers',
                                        c.official_players,

                                    'grossTiebreakPending',
                                        COALESCE(
                                            c.gross_tiebreak_pending,
                                            false
                                        ),

                                    'netTiebreakPending',
                                        COALESCE(
                                            c.net_tiebreak_pending,
                                            false
                                        )
                                ),

                            'players',
                                COALESCE((
                                    SELECT jsonb_agg(
                                        jsonb_build_object(
                                            'tournamentRegistrationId',
                                                p.tournament_registration_id,

                                            'playerId',
                                                p.player_id,

                                            'playerName',
                                                p.player_name,

                                            'accumulationStatus',
                                                p.accumulation_status,

                                            'eligibleForRanking',
                                                p.accumulation_ready,

                                            'gross',
                                                jsonb_build_object(
                                                    'enabled',
                                                        p.gross_enabled,

                                                    'points',
                                                        p.gross_points_total,

                                                    'baseRank',
                                                        p.gross_base_rank,

                                                    'tieSize',
                                                        p.gross_tie_size,

                                                    'finalRank',
                                                        p.gross_final_rank,

                                                    'tiebreakStatus',
                                                        CASE
                                                            WHEN NOT p.gross_enabled
                                                                THEN NULL

                                                            WHEN COALESCE(
                                                                p.gross_tie_size,
                                                                0
                                                            )<=1
                                                                THEN 'NOT_NEEDED'

                                                            WHEN p.gross_final_rank
                                                                 IS NOT NULL
                                                                THEN COALESCE(
                                                                    p.gross_tiebreak_status,
                                                                    'RESOLVED'
                                                                )

                                                            ELSE 'PENDING'
                                                        END,

                                                    'tiebreakMethodCode',
                                                        p.gross_tiebreak_method_code,

                                                    'tiebreakMethodName',
                                                        p.gross_tiebreak_method_name,

                                                    'resolutionId',
                                                        p.gross_resolution_id
                                                ),

                                            'net',
                                                jsonb_build_object(
                                                    'enabled',
                                                        p.net_enabled,

                                                    'points',
                                                        p.net_points_total,

                                                    'baseRank',
                                                        p.net_base_rank,

                                                    'tieSize',
                                                        p.net_tie_size,

                                                    'finalRank',
                                                        p.net_final_rank,

                                                    'tiebreakStatus',
                                                        CASE
                                                            WHEN NOT p.net_enabled
                                                                THEN NULL

                                                            WHEN COALESCE(
                                                                p.net_tie_size,
                                                                0
                                                            )<=1
                                                                THEN 'NOT_NEEDED'

                                                            WHEN p.net_final_rank
                                                                 IS NOT NULL
                                                                THEN COALESCE(
                                                                    p.net_tiebreak_status,
                                                                    'RESOLVED'
                                                                )

                                                            ELSE 'PENDING'
                                                        END,

                                                    'tiebreakMethodCode',
                                                        p.net_tiebreak_method_code,

                                                    'tiebreakMethodName',
                                                        p.net_tiebreak_method_name,

                                                    'resolutionId',
                                                        p.net_resolution_id
                                                ),

                                            'rounds',
                                                p.rounds
                                        )
                                        ORDER BY
                                            CASE
                                                WHEN p.accumulation_ready
                                                    THEN 0
                                                ELSE 1
                                            END,

                                            COALESCE(
                                                p.net_final_rank,
                                                p.gross_final_rank,
                                                p.net_base_rank,
                                                p.gross_base_rank
                                            ) NULLS LAST,

                                            p.player_name
                                    )
                                    FROM combined p
                                    WHERE
                                        p.tournament_category_id
                                        IS NOT DISTINCT FROM
                                        c.tournament_category_id
                                ),'[]'::jsonb)
                        )
                        ORDER BY
                            c.category_display_order NULLS LAST,
                            c.category_name NULLS LAST
                    )
                    FROM categories c
                ),'[]'::jsonb)
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.obtener_leaderboard_stableford_torneo(uuid)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    public.obtener_leaderboard_stableford_torneo(uuid)
TO authenticated,service_role;

COMMIT;

-- ============================================================================
-- FIN MIGRACIÓN 186 FASE 1N
-- ============================================================================
