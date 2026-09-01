-- ============================================================================
-- MIGRACIÓN 208 FASE 5
-- A-Go-Go — tarjeta oficial por equipo + refresco rápido de grupo
-- Proyecto: Tee Central / GOLF IN FULL
--
-- ALCANCE
-- - Habilita emisión oficial para Shotgun + equipo + team_stroke.
-- - Reutiliza tournament_score_cards; NO crea un segundo sistema de tarjetas.
-- - Una tarjeta = un equipo.
-- - La tarjeta queda vinculada a la versión de HCP de equipo que formó parte
--   de la validación formal de salidas.
-- - Guarda snapshot imprimible de equipo/miembros/HCP.
-- - La captura digital/física por hoyo NO se inicializa todavía (Fase 6).
-- - Agrega RPC de preview de tarjetas de equipo.
-- - Agrega RPC para refrescar rápidamente todas las tarjetas de un grupo.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Snapshot específico del contenido de tarjeta de equipo
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_team_scorecard_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    score_card_id uuid NOT NULL UNIQUE
        REFERENCES public.tournament_score_cards(id) ON DELETE RESTRICT,

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,

    tournament_team_id uuid NOT NULL
        REFERENCES public.tournament_teams(id) ON DELETE RESTRICT,

    team_handicap_version_id uuid NOT NULL
        REFERENCES public.tournament_round_team_handicap_versions(id)
        ON DELETE RESTRICT,

    team_name text NOT NULL,

    team_handicap_method text NOT NULL,
    team_handicap_unrounded numeric NOT NULL,
    team_playing_handicap integer NOT NULL,

    member_count integer NOT NULL CHECK (member_count > 0),

    members_snapshot jsonb NOT NULL
        CHECK (jsonb_typeof(members_snapshot)='array'),

    signature_requirements jsonb NOT NULL DEFAULT
        jsonb_build_object(
            'teamSigner',true,
            'opposingMarkerSigner',true
        ),

    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_team_scorecard_snapshots_round_team
    ON public.tournament_team_scorecard_snapshots(
        tournament_round_id,
        tournament_team_id
    );

ALTER TABLE public.tournament_team_scorecard_snapshots
    ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_team_scorecard_snapshots
FROM anon,authenticated;

GRANT ALL ON TABLE public.tournament_team_scorecard_snapshots
TO service_role;

COMMENT ON TABLE public.tournament_team_scorecard_snapshots IS
'Snapshot imprimible de tarjeta oficial A-Go-Go. Conserva nombre de equipo, versión exacta de HCP competitivo y evidencia de integrantes al momento de emisión.';

-- ----------------------------------------------------------------------------
-- 2. Activar emisión de scorecard por TEAM en registry
-- ----------------------------------------------------------------------------

UPDATE public.tournament_start_engine_registry
   SET supports_scorecard_emission=true,
       scorecard_unit_type='team',
       scorecard_emission_engine='official_scorecard_team_v1',
       updated_at=now()
 WHERE start_format::text='shotgun'
   AND participation_type='equipo'
   AND scoring_engine='team_stroke'
   AND validation_engine='team_stroke_team_shotgun_v1'
   AND activo=true;

-- ----------------------------------------------------------------------------
-- 3. Helper: resolver teamHandicapVersionId desde snapshot VALIDADO
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._team_hcp_version_from_validation_208(
    p_validation_id uuid,
    p_tournament_team_id uuid
)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
    SELECT NULLIF(u->>'teamHandicapVersionId','')::uuid
    FROM public.tournament_round_start_validations v
    CROSS JOIN LATERAL jsonb_array_elements(
        v.validation_snapshot->'groups'
    ) g
    CROSS JOIN LATERAL jsonb_array_elements(
        g->'units'
    ) u
    WHERE v.id=p_validation_id
      AND NULLIF(u->>'teamId','')::uuid=p_tournament_team_id
      AND u->>'unitType'='team'
    LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public._team_hcp_version_from_validation_208(
    uuid,uuid
) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public._team_hcp_version_from_validation_208(
    uuid,uuid
) TO service_role;

-- ----------------------------------------------------------------------------
-- 4. Preview específico de tarjetas TEAM
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.previsualizar_tarjetas_equipo_a_gogo_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_tournament_id uuid;
    v_round_number integer;
    v_validation public.tournament_round_start_validations%ROWTYPE;
    v_capability jsonb;
    v_bad_units integer;
    v_already_issued boolean;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT tr.tournament_id,tr.numero_ronda
      INTO v_tournament_id,v_round_number
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para previsualizar tarjetas.'
            USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_validation
      FROM public.tournament_round_start_validations
     WHERE tournament_round_id=p_tournament_round_id
       AND status='validated'
     ORDER BY version DESC
     LIMIT 1;

    IF v_validation.id IS NULL THEN
        RAISE EXCEPTION
            'Las salidas deben estar validadas antes de previsualizar tarjetas.';
    END IF;

    IF v_validation.start_format IS DISTINCT FROM 'shotgun'
       OR v_validation.participation_type IS DISTINCT FROM 'equipo'
       OR v_validation.scoring_engine IS DISTINCT FROM 'team_stroke'
    THEN
        RAISE EXCEPTION
            'Esta RPC corresponde únicamente a A-Go-Go Shotgun por equipo.';
    END IF;

    v_capability :=
        public._resolver_capacidad_emision_tarjetas_ronda(
            p_tournament_round_id
        );

    IF NOT COALESCE((v_capability->>'supported')::boolean,false)
       OR v_capability->>'unitType' IS DISTINCT FROM 'team'
    THEN
        RAISE EXCEPTION
            'El motor validado no tiene emisión de tarjeta TEAM habilitada.'
            USING ERRCODE='0A000',
                  DETAIL=v_capability::text;
    END IF;

    SELECT public._contar_unidades_invalidas_emision_tarjetas(
        v_validation.id,
        'team'
    )
    INTO v_bad_units;

    IF v_bad_units>0 THEN
        RAISE EXCEPTION
            'La validación contiene unidades incompatibles con tarjeta TEAM.';
    END IF;

    -- Debe existir y continuar vigente la versión HCP que estaba en el
    -- snapshot de validación. No se toma "la última" por conveniencia.
    IF EXISTS(
        SELECT 1
        FROM public.tournament_round_start_validation_units u
        LEFT JOIN LATERAL (
            SELECT public._team_hcp_version_from_validation_208(
                v_validation.id,
                u.tournament_team_id
            ) AS hcp_version_id
        ) x ON true
        LEFT JOIN public.tournament_round_team_handicap_versions hv
          ON hv.id=x.hcp_version_id
        WHERE u.validation_id=v_validation.id
          AND u.unit_type='team'
          AND (
              x.hcp_version_id IS NULL
              OR hv.id IS NULL
              OR hv.status IS DISTINCT FROM 'active'
              OR hv.is_stale
              OR hv.tournament_round_id IS DISTINCT FROM
                 p_tournament_round_id
              OR hv.tournament_team_id IS DISTINCT FROM
                 u.tournament_team_id
          )
    ) THEN
        RAISE EXCEPTION
            'Una o más tarjetas apuntan a un HCP de equipo faltante u obsoleto. Recalcula y revalida las salidas antes de emitir.'
            USING ERRCODE='23514';
    END IF;

    v_already_issued :=
        public._ronda_tiene_tarjetas_emitidas(
            p_tournament_round_id
        );

    RETURN (
        WITH ordered AS (
            SELECT
                u.id AS validation_unit_id,
                u.validation_group_id,
                u.tournament_team_id,
                u.tournament_category_id,
                u.unit_name,
                u.order_in_group,
                g.category_name,
                g.hole_number,
                g.start_position,
                g.start_at,
                g.shift_number,
                g.shift_time,
                g.group_label,
                row_number() OVER(
                    ORDER BY
                        g.shift_number,
                        g.hole_number,
                        g.start_position,
                        u.order_in_group,
                        u.id
                )::integer AS card_number
            FROM public.tournament_round_start_validation_units u
            JOIN public.tournament_round_start_validation_groups g
              ON g.id=u.validation_group_id
             AND g.validation_id=u.validation_id
            WHERE u.validation_id=v_validation.id
              AND u.unit_type='team'
        ),
        cards AS (
            SELECT
                o.*,
                hv.id AS team_hcp_version_id,
                hv.version AS team_hcp_version,
                hv.method,
                hv.team_handicap_unrounded,
                hv.team_playing_handicap,
                COALESCE((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'registrationId',m.tournament_registration_id,
                            'playerId',m.player_id,
                            'name',m.player_name,
                            'handicapIndex',m.handicap_index,
                            'handicapSource',m.handicap_source,
                            'handicapStatus',m.handicap_status,
                            'teeId',m.tee_id,
                            'courseHandicapUnrounded',
                                m.course_handicap_unrounded
                        )
                        ORDER BY
                            COALESCE(m.whs_rank,2147483647),
                            m.player_name,
                            m.player_id
                    )
                    FROM public.tournament_round_team_handicap_members m
                    WHERE m.team_handicap_version_id=hv.id
                ),'[]'::jsonb) AS members
            FROM ordered o
            JOIN public.tournament_round_team_handicap_versions hv
              ON hv.id=public._team_hcp_version_from_validation_208(
                    v_validation.id,
                    o.tournament_team_id
                 )
        )
        SELECT jsonb_build_object(
            'schemaVersion',1,
            'preview',true,
            'officiallyIssued',v_already_issued,
            'validation',jsonb_build_object(
                'id',v_validation.id,
                'version',v_validation.version,
                'expectedCardCount',v_validation.unit_count
            ),
            'cards',COALESCE(jsonb_agg(
                jsonb_build_object(
                    'prospectiveCardNumber',c.card_number,
                    'prospectiveCardFolio',
                        'R'||lpad(v_round_number::text,2,'0')||
                        '-V'||lpad(v_validation.version::text,2,'0')||
                        '-'||lpad(c.card_number::text,4,'0'),
                    'validationUnitId',c.validation_unit_id,
                    'team',jsonb_build_object(
                        'id',c.tournament_team_id,
                        'name',c.unit_name,
                        'members',c.members
                    ),
                    'category',jsonb_build_object(
                        'tournamentCategoryId',c.tournament_category_id,
                        'name',c.category_name
                    ),
                    'teamHandicap',jsonb_build_object(
                        'versionId',c.team_hcp_version_id,
                        'version',c.team_hcp_version,
                        'method',c.method,
                        'unrounded',c.team_handicap_unrounded,
                        'playingHandicap',c.team_playing_handicap
                    ),
                    'start',jsonb_build_object(
                        'validationGroupId',c.validation_group_id,
                        'holeNumber',c.hole_number,
                        'position',c.start_position,
                        'startAt',c.start_at,
                        'shiftNumber',c.shift_number,
                        'shiftTime',c.shift_time,
                        'groupLabel',c.group_label,
                        'orderInGroup',c.order_in_group
                    ),
                    'signatures',jsonb_build_object(
                        'teamPlayerRequired',true,
                        'opposingMarkerRequired',true
                    )
                )
                ORDER BY c.card_number
            ),'[]'::jsonb),
            'counts',jsonb_build_object(
                'cards',count(*),
                'expectedCards',v_validation.unit_count
            )
        )
        FROM cards c
    );
END;
$$;

REVOKE ALL ON FUNCTION public.previsualizar_tarjetas_equipo_a_gogo_ronda(
    uuid
) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.previsualizar_tarjetas_equipo_a_gogo_ronda(
    uuid
) TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 5. Conservar preview individual existente y crear dispatcher común.
-- ----------------------------------------------------------------------------

ALTER FUNCTION public.previsualizar_tarjetas_score_ronda(uuid)
RENAME TO _previsualizar_tarjetas_score_ronda_individual_208;

CREATE OR REPLACE FUNCTION public.previsualizar_tarjetas_score_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_capability jsonb;
BEGIN
    v_capability :=
        public._resolver_capacidad_emision_tarjetas_ronda(
            p_tournament_round_id
        );

    IF COALESCE((v_capability->>'supported')::boolean,false)
       AND v_capability->>'unitType'='team'
    THEN
        RETURN public.previsualizar_tarjetas_equipo_a_gogo_ronda(
            p_tournament_round_id
        );
    END IF;

    RETURN public._previsualizar_tarjetas_score_ronda_individual_208(
        p_tournament_round_id
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 6. Emisor TEAM específico.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._emitir_tarjetas_equipo_a_gogo_ronda_208(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_tournament_id uuid;
    v_round_number integer;
    v_admin_id uuid;
    v_validation public.tournament_round_start_validations%ROWTYPE;
    v_emission_id uuid;
    v_inserted integer;
    v_bad integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT tournament_id,numero_ronda
      INTO v_tournament_id,v_round_number
      FROM public.tournament_rounds
     WHERE id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para emitir tarjetas.'
            USING ERRCODE='42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(
        p_tournament_round_id
    );

    IF public._ronda_tiene_tarjetas_emitidas(
        p_tournament_round_id
    ) THEN
        RETURN public.obtener_estado_emision_tarjetas_ronda(
            p_tournament_round_id
        );
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id=auth.uid()
       AND au.activo
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No existe administrador activo asociado.';
    END IF;

    SELECT *
      INTO v_validation
      FROM public.tournament_round_start_validations
     WHERE tournament_round_id=p_tournament_round_id
       AND status='validated'
     ORDER BY version DESC
     LIMIT 1
     FOR UPDATE;

    IF v_validation.id IS NULL THEN
        RAISE EXCEPTION
            'Las salidas deben estar validadas antes de emitir.';
    END IF;

    IF v_validation.start_format IS DISTINCT FROM 'shotgun'
       OR v_validation.participation_type IS DISTINCT FROM 'equipo'
       OR v_validation.scoring_engine IS DISTINCT FROM 'team_stroke'
    THEN
        RAISE EXCEPTION
            'Esta emisión corresponde únicamente a A-Go-Go Shotgun.';
    END IF;

    SELECT public._contar_unidades_invalidas_emision_tarjetas(
        v_validation.id,
        'team'
    )
    INTO v_bad;

    IF v_bad>0 THEN
        RAISE EXCEPTION
            'La validación contiene unidades incompatibles con tarjeta TEAM.';
    END IF;

    -- Garantizar que cada versión HCP de la validación continúa vigente.
    IF EXISTS(
        SELECT 1
        FROM public.tournament_round_start_validation_units u
        LEFT JOIN public.tournament_round_team_handicap_versions hv
          ON hv.id=public._team_hcp_version_from_validation_208(
                v_validation.id,
                u.tournament_team_id
             )
        WHERE u.validation_id=v_validation.id
          AND u.unit_type='team'
          AND (
              hv.id IS NULL
              OR hv.status IS DISTINCT FROM 'active'
              OR hv.is_stale
              OR hv.tournament_round_id IS DISTINCT FROM
                 p_tournament_round_id
              OR hv.tournament_team_id IS DISTINCT FROM
                 u.tournament_team_id
          )
    ) THEN
        RAISE EXCEPTION
            'Existe HCP de equipo faltante u obsoleto. Recalcula y revalida antes de emitir.'
            USING ERRCODE='23514';
    END IF;

    INSERT INTO public.tournament_score_card_emissions(
        tournament_id,
        tournament_round_id,
        validation_id,
        validation_version,
        status,
        card_count,
        issued_by
    )
    VALUES(
        v_tournament_id,
        p_tournament_round_id,
        v_validation.id,
        v_validation.version,
        'issued',
        v_validation.unit_count,
        v_admin_id
    )
    RETURNING id INTO v_emission_id;

    WITH ordered_units AS (
        SELECT
            u.id AS validation_unit_id,
            u.validation_group_id,
            u.tournament_team_id,
            u.tournament_category_id,
            row_number() OVER(
                ORDER BY
                    g.shift_number,
                    g.hole_number,
                    g.start_position,
                    u.order_in_group,
                    u.id
            )::integer AS card_number
        FROM public.tournament_round_start_validation_units u
        JOIN public.tournament_round_start_validation_groups g
          ON g.id=u.validation_group_id
         AND g.validation_id=u.validation_id
        WHERE u.validation_id=v_validation.id
          AND u.unit_type='team'
    )
    INSERT INTO public.tournament_score_cards(
        emission_id,
        tournament_id,
        tournament_round_id,
        validation_id,
        validation_version,
        validation_group_id,
        validation_unit_id,
        unit_type,
        tournament_registration_id,
        tournament_team_id,
        player_id,
        tournament_category_id,
        card_number,
        card_folio,
        status
    )
    SELECT
        v_emission_id,
        v_tournament_id,
        p_tournament_round_id,
        v_validation.id,
        v_validation.version,
        ou.validation_group_id,
        ou.validation_unit_id,
        'team',
        NULL,
        ou.tournament_team_id,
        NULL,
        ou.tournament_category_id,
        ou.card_number,
        'R'||lpad(v_round_number::text,2,'0')||
        '-V'||lpad(v_validation.version::text,2,'0')||
        '-'||lpad(ou.card_number::text,4,'0'),
        'issued'
    FROM ordered_units ou
    ORDER BY ou.card_number;

    GET DIAGNOSTICS v_inserted=ROW_COUNT;

    IF v_inserted<>v_validation.unit_count THEN
        RAISE EXCEPTION
            'La emisión TEAM quedó incompleta y fue revertida.'
            USING ERRCODE='55000';
    END IF;

    -- Snapshot imprimible de cada tarjeta.
    INSERT INTO public.tournament_team_scorecard_snapshots(
        score_card_id,
        tournament_id,
        tournament_round_id,
        tournament_team_id,
        team_handicap_version_id,
        team_name,
        team_handicap_method,
        team_handicap_unrounded,
        team_playing_handicap,
        member_count,
        members_snapshot
    )
    SELECT
        sc.id,
        sc.tournament_id,
        sc.tournament_round_id,
        sc.tournament_team_id,
        hv.id,
        tt.nombre_equipo,
        hv.method,
        hv.team_handicap_unrounded,
        hv.team_playing_handicap,
        hv.member_count,
        COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'registrationId',m.tournament_registration_id,
                    'playerId',m.player_id,
                    'name',m.player_name,
                    'handicapIndex',m.handicap_index,
                    'handicapSource',m.handicap_source,
                    'handicapStatus',m.handicap_status,
                    'teeId',m.tee_id,
                    'courseRating',m.course_rating,
                    'slopeRating',m.slope_rating,
                    'courseHandicapUnrounded',
                        m.course_handicap_unrounded,
                    'whsRank',m.whs_rank,
                    'whsWeightPct',m.whs_weight_pct
                )
                ORDER BY
                    COALESCE(m.whs_rank,2147483647),
                    m.player_name,
                    m.player_id
            )
            FROM public.tournament_round_team_handicap_members m
            WHERE m.team_handicap_version_id=hv.id
        ),'[]'::jsonb)
    FROM public.tournament_score_cards sc
    JOIN public.tournament_teams tt
      ON tt.id=sc.tournament_team_id
    JOIN public.tournament_round_team_handicap_versions hv
      ON hv.id=public._team_hcp_version_from_validation_208(
            v_validation.id,
            sc.tournament_team_id
         )
    WHERE sc.emission_id=v_emission_id
      AND sc.unit_type='team'
      AND sc.status='issued';

    -- IMPORTANTE:
    -- NO llamar inicializar_captura_scores_ronda().
    -- La captura A-Go-Go se habilita en Fase 6.

    RETURN public.obtener_estado_emision_tarjetas_ronda(
        p_tournament_round_id
    );
END;
$$;

REVOKE ALL ON FUNCTION public._emitir_tarjetas_equipo_a_gogo_ronda_208(
    uuid
) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public._emitir_tarjetas_equipo_a_gogo_ronda_208(
    uuid
) TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 7. Conservar emisor individual y crear dispatcher común.
-- ----------------------------------------------------------------------------

ALTER FUNCTION public.emitir_tarjetas_score_ronda(uuid)
RENAME TO _emitir_tarjetas_score_ronda_individual_208;

CREATE OR REPLACE FUNCTION public.emitir_tarjetas_score_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_capability jsonb;
BEGIN
    v_capability :=
        public._resolver_capacidad_emision_tarjetas_ronda(
            p_tournament_round_id
        );

    IF COALESCE((v_capability->>'supported')::boolean,false)
       AND v_capability->>'unitType'='team'
    THEN
        RETURN public._emitir_tarjetas_equipo_a_gogo_ronda_208(
            p_tournament_round_id
        );
    END IF;

    RETURN public._emitir_tarjetas_score_ronda_individual_208(
        p_tournament_round_id
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 8. Obtener tarjeta oficial A-Go-Go completa
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_tarjeta_equipo_a_gogo(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_tournament_id uuid;
    v_result jsonb;
BEGIN
    SELECT tournament_id
      INTO v_tournament_id
      FROM public.tournament_score_cards
     WHERE id=p_score_card_id
       AND unit_type='team'
       AND status='issued';

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION
            'La tarjeta de equipo no existe o no está emitida.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar esta tarjeta.'
            USING ERRCODE='42501';
    END IF;

    SELECT jsonb_build_object(
        'scoreCardId',sc.id,
        'cardNumber',sc.card_number,
        'cardFolio',sc.card_folio,
        'qrToken',sc.qr_token,
        'status',sc.status,
        'validationId',sc.validation_id,
        'validationVersion',sc.validation_version,
        'team',jsonb_build_object(
            'id',sc.tournament_team_id,
            'name',ss.team_name,
            'members',ss.members_snapshot
        ),
        'category',jsonb_build_object(
            'tournamentCategoryId',sc.tournament_category_id,
            'name',vg.category_name
        ),
        'teamHandicap',jsonb_build_object(
            'versionId',ss.team_handicap_version_id,
            'method',ss.team_handicap_method,
            'unrounded',ss.team_handicap_unrounded,
            'playingHandicap',ss.team_playing_handicap
        ),
        'start',jsonb_build_object(
            'validationGroupId',sc.validation_group_id,
            'holeNumber',vg.hole_number,
            'position',vg.start_position,
            'startAt',vg.start_at,
            'shiftNumber',vg.shift_number,
            'shiftTime',vg.shift_time,
            'groupLabel',vg.group_label,
            'orderInGroup',vu.order_in_group
        ),
        'signatures',ss.signature_requirements,
        'captureInitialized',EXISTS(
            SELECT 1
            FROM public.tournament_scorecard_capture_sessions cs
            WHERE cs.score_card_id=sc.id
        )
    )
    INTO v_result
    FROM public.tournament_score_cards sc
    JOIN public.tournament_team_scorecard_snapshots ss
      ON ss.score_card_id=sc.id
    JOIN public.tournament_round_start_validation_groups vg
      ON vg.id=sc.validation_group_id
     AND vg.validation_id=sc.validation_id
    JOIN public.tournament_round_start_validation_units vu
      ON vu.id=sc.validation_unit_id
     AND vu.validation_id=sc.validation_id
    WHERE sc.id=p_score_card_id;

    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_tarjeta_equipo_a_gogo(uuid)
FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.obtener_tarjeta_equipo_a_gogo(uuid)
TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 9. Refresco rápido de todas las tarjetas del mismo grupo de salida.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_tarjetas_grupo_salida_a_gogo(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_tournament_id uuid;
    v_group_id uuid;
BEGIN
    SELECT tournament_id,validation_group_id
      INTO v_tournament_id,v_group_id
      FROM public.tournament_score_cards
     WHERE id=p_score_card_id
       AND unit_type='team'
       AND status='issued';

    IF v_group_id IS NULL THEN
        RAISE EXCEPTION
            'La tarjeta de equipo no existe o no está emitida.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar este grupo.'
            USING ERRCODE='42501';
    END IF;

    RETURN jsonb_build_object(
        'validationGroupId',v_group_id,
        'cards',COALESCE((
            SELECT jsonb_agg(
                public.obtener_tarjeta_equipo_a_gogo(sc.id)
                ORDER BY vu.order_in_group,sc.id
            )
            FROM public.tournament_score_cards sc
            JOIN public.tournament_round_start_validation_units vu
              ON vu.id=sc.validation_unit_id
             AND vu.validation_id=sc.validation_id
            WHERE sc.validation_group_id=v_group_id
              AND sc.unit_type='team'
              AND sc.status='issued'
        ),'[]'::jsonb)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_tarjetas_grupo_salida_a_gogo(uuid)
FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.obtener_tarjetas_grupo_salida_a_gogo(uuid)
TO authenticated,service_role;

COMMIT;
