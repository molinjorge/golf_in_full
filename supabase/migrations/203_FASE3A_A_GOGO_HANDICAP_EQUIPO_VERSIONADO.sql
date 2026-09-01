-- ============================================================================
-- MIGRACIÓN 203 FASE 3A
-- A-Go-Go — Hándicap competitivo de equipo versionado y auditable
-- Proyecto: Tee Central / GOLF IN FULL
--
-- PRINCIPIOS
-- - NO reutiliza tournament_handicap_snapshots como autoridad de HCP de equipo.
-- - Cada cálculo crea una versión por equipo/ronda.
-- - Guarda evidencia individual usada en el cálculo.
-- - Recalcular nunca borra versiones anteriores.
-- - Soporta:
--      GROSS_ONLY
--      AVERAGE_HI_PCT
--      ASSIGNED_TABLE_SUM_HI
--      WHS_SCRAMBLE
-- - WHS_SCRAMBLE solo 2, 3 o 4 jugadores. No se inventa fórmula para 5.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Configuración del HCP de equipo por torneo
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_team_handicap_configs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL UNIQUE
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,

    method text NOT NULL
        CHECK (method IN (
            'GROSS_ONLY',
            'AVERAGE_HI_PCT',
            'ASSIGNED_TABLE_SUM_HI',
            'WHS_SCRAMBLE'
        )),

    average_pct numeric NULL
        CHECK (average_pct IS NULL OR (average_pct >= 0 AND average_pct <= 100)),

    rounding_mode text NOT NULL DEFAULT 'NEAREST_INTEGER'
        CHECK (rounding_mode IN ('NEAREST_INTEGER')),

    active boolean NOT NULL DEFAULT true,

    created_by uuid NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    updated_by uuid NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT team_hcp_average_pct_required
        CHECK (
            method <> 'AVERAGE_HI_PCT'
            OR average_pct IS NOT NULL
        )
);

DROP TRIGGER IF EXISTS set_updated_at_tournament_team_handicap_configs
    ON public.tournament_team_handicap_configs;

CREATE TRIGGER set_updated_at_tournament_team_handicap_configs
BEFORE UPDATE ON public.tournament_team_handicap_configs
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.tournament_team_handicap_configs ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_team_handicap_configs
FROM anon, authenticated;

GRANT ALL ON TABLE public.tournament_team_handicap_configs
TO service_role;

-- ----------------------------------------------------------------------------
-- 2. Rangos para ASSIGNED_TABLE_SUM_HI
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_team_handicap_ranges (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    config_id uuid NOT NULL
        REFERENCES public.tournament_team_handicap_configs(id)
        ON DELETE CASCADE,

    handicap_sum_from numeric NOT NULL,
    handicap_sum_to numeric NULL,
    assigned_team_handicap numeric NOT NULL,

    display_order integer NOT NULL DEFAULT 0,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT team_hcp_range_valid
        CHECK (
            handicap_sum_to IS NULL
            OR handicap_sum_to >= handicap_sum_from
        )
);

CREATE INDEX IF NOT EXISTS idx_team_hcp_ranges_config
    ON public.tournament_team_handicap_ranges(config_id, display_order);

ALTER TABLE public.tournament_team_handicap_ranges ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_team_handicap_ranges
FROM anon, authenticated;

GRANT ALL ON TABLE public.tournament_team_handicap_ranges
TO service_role;

-- ----------------------------------------------------------------------------
-- 3. Versiones del HCP competitivo por equipo/ronda
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_round_team_handicap_versions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,

    tournament_team_id uuid NOT NULL
        REFERENCES public.tournament_teams(id) ON DELETE RESTRICT,

    config_id uuid NOT NULL
        REFERENCES public.tournament_team_handicap_configs(id)
        ON DELETE RESTRICT,

    version integer NOT NULL,

    method text NOT NULL,
    member_count integer NOT NULL,

    input_handicap_sum numeric NOT NULL DEFAULT 0,
    input_handicap_average numeric NULL,

    team_handicap_unrounded numeric NOT NULL,
    team_playing_handicap integer NOT NULL,

    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active','superseded','voided')),

    formula_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,

    calculated_by uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    calculated_at timestamptz NOT NULL DEFAULT now(),

    superseded_at timestamptz NULL,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT team_hcp_version_unique
        UNIQUE (tournament_round_id, tournament_team_id, version)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_round_team_hcp_active
    ON public.tournament_round_team_handicap_versions(
        tournament_round_id,
        tournament_team_id
    )
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_round_team_hcp_versions_team
    ON public.tournament_round_team_handicap_versions(
        tournament_team_id,
        tournament_round_id,
        version DESC
    );

ALTER TABLE public.tournament_round_team_handicap_versions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_round_team_handicap_versions
FROM anon, authenticated;

GRANT ALL ON TABLE public.tournament_round_team_handicap_versions
TO service_role;

-- ----------------------------------------------------------------------------
-- 4. Evidencia individual usada por cada versión
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_round_team_handicap_members (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    team_handicap_version_id uuid NOT NULL
        REFERENCES public.tournament_round_team_handicap_versions(id)
        ON DELETE CASCADE,

    tournament_registration_id uuid NOT NULL
        REFERENCES public.tournament_registrations(id)
        ON DELETE RESTRICT,

    player_id uuid NOT NULL
        REFERENCES public.players(id) ON DELETE RESTRICT,

    player_name text NOT NULL,

    handicap_index numeric NOT NULL,
    handicap_source text NOT NULL,
    handicap_source_date date NULL,
    handicap_status text NOT NULL,

    tee_id uuid NULL
        REFERENCES public.marcas_salida(id) ON DELETE RESTRICT,

    course_rating numeric NULL,
    slope_rating integer NULL,
    course_par integer NULL,

    course_handicap_unrounded numeric NULL,

    whs_rank integer NULL,
    whs_weight_pct numeric NULL,

    contribution numeric NULL,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT team_hcp_member_unique
        UNIQUE (team_handicap_version_id, tournament_registration_id)
);

CREATE INDEX IF NOT EXISTS idx_team_hcp_members_player
    ON public.tournament_round_team_handicap_members(player_id);

ALTER TABLE public.tournament_round_team_handicap_members ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_round_team_handicap_members
FROM anon, authenticated;

GRANT ALL ON TABLE public.tournament_round_team_handicap_members
TO service_role;

-- ----------------------------------------------------------------------------
-- 5. Configurar método
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.configurar_handicap_equipo_a_gogo(
    p_tournament_id uuid,
    p_method text,
    p_average_pct numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_admin_id uuid;
    v_participation text;
    v_engine text;
    v_config public.tournament_team_handicap_configs%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para configurar este torneo.'
            USING ERRCODE='42501';
    END IF;

    SELECT au.id INTO v_admin_id
    FROM public.admin_users au
    WHERE au.auth_user_id=auth.uid()
      AND au.activo
    ORDER BY au.id
    LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No existe administrador activo asociado.';
    END IF;

    SELECT tf.tipo_participacion::text, tf.scoring_engine::text
      INTO v_participation, v_engine
      FROM public.tournaments t
      JOIN public.tournament_formats tf
        ON tf.id=t.tournament_format_id
     WHERE t.id=p_tournament_id
       AND t.activo=true;

    IF v_participation IS DISTINCT FROM 'equipo'
       OR v_engine IS DISTINCT FROM 'team_stroke' THEN
        RAISE EXCEPTION
            'La configuración de HCP de equipo solo aplica a A-Go-Go/team_stroke.';
    END IF;

    IF p_method NOT IN (
        'GROSS_ONLY',
        'AVERAGE_HI_PCT',
        'ASSIGNED_TABLE_SUM_HI',
        'WHS_SCRAMBLE'
    ) THEN
        RAISE EXCEPTION 'Método de HCP de equipo no reconocido.';
    END IF;

    IF p_method='AVERAGE_HI_PCT'
       AND (p_average_pct IS NULL OR p_average_pct<0 OR p_average_pct>100) THEN
        RAISE EXCEPTION
            'AVERAGE_HI_PCT requiere porcentaje entre 0 y 100.';
    END IF;

    INSERT INTO public.tournament_team_handicap_configs(
        tournament_id,
        method,
        average_pct,
        created_by,
        updated_by
    )
    VALUES(
        p_tournament_id,
        p_method,
        CASE WHEN p_method='AVERAGE_HI_PCT'
             THEN p_average_pct ELSE NULL END,
        v_admin_id,
        v_admin_id
    )
    ON CONFLICT (tournament_id)
    DO UPDATE SET
        method=EXCLUDED.method,
        average_pct=EXCLUDED.average_pct,
        active=true,
        updated_by=v_admin_id,
        updated_at=now()
    RETURNING * INTO v_config;

    RETURN jsonb_build_object(
        'configId',v_config.id,
        'tournamentId',v_config.tournament_id,
        'method',v_config.method,
        'averagePct',v_config.average_pct,
        'active',v_config.active
    );
END;
$$;

REVOKE ALL ON FUNCTION public.configurar_handicap_equipo_a_gogo(
    uuid,text,numeric
) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.configurar_handicap_equipo_a_gogo(
    uuid,text,numeric
) TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 6. Agregar/actualizar rango de tabla asignada
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.guardar_rango_handicap_equipo_a_gogo(
    p_config_id uuid,
    p_from numeric,
    p_to numeric,
    p_assigned_team_handicap numeric,
    p_display_order integer DEFAULT 0
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_config public.tournament_team_handicap_configs%ROWTYPE;
    v_id uuid;
BEGIN
    SELECT * INTO v_config
    FROM public.tournament_team_handicap_configs
    WHERE id=p_config_id;

    IF v_config.id IS NULL THEN
        RAISE EXCEPTION 'La configuración no existe.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_config.tournament_id
    ) THEN
        RAISE EXCEPTION 'No tienes permiso para configurar este torneo.'
            USING ERRCODE='42501';
    END IF;

    IF v_config.method <> 'ASSIGNED_TABLE_SUM_HI' THEN
        RAISE EXCEPTION
            'Los rangos solo aplican al método ASSIGNED_TABLE_SUM_HI.';
    END IF;

    IF p_to IS NOT NULL AND p_to < p_from THEN
        RAISE EXCEPTION 'El límite superior no puede ser menor al inferior.';
    END IF;

    IF EXISTS(
        SELECT 1
        FROM public.tournament_team_handicap_ranges r
        WHERE r.config_id=p_config_id
          AND numrange(
              r.handicap_sum_from,
              r.handicap_sum_to,
              '[]'
          ) && numrange(p_from,p_to,'[]')
    ) THEN
        RAISE EXCEPTION
            'El rango se traslapa con otro rango de la misma configuración.';
    END IF;

    INSERT INTO public.tournament_team_handicap_ranges(
        config_id,
        handicap_sum_from,
        handicap_sum_to,
        assigned_team_handicap,
        display_order
    )
    VALUES(
        p_config_id,p_from,p_to,p_assigned_team_handicap,p_display_order
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.guardar_rango_handicap_equipo_a_gogo(
    uuid,numeric,numeric,numeric,integer
) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.guardar_rango_handicap_equipo_a_gogo(
    uuid,numeric,numeric,numeric,integer
) TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 7. Recalcular HCP competitivo de un equipo/ronda
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.recalcular_handicap_equipo_a_gogo(
    p_tournament_round_id uuid,
    p_tournament_team_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_round public.tournament_rounds%ROWTYPE;
    v_team public.tournament_teams%ROWTYPE;
    v_config public.tournament_team_handicap_configs%ROWTYPE;
    v_admin_id uuid;

    v_member_count integer;
    v_sum_hi numeric;
    v_avg_hi numeric;

    v_unrounded numeric;
    v_playing integer;

    v_version integer;
    v_version_id uuid;

    v_range public.tournament_team_handicap_ranges%ROWTYPE;

    v_missing_rating integer;
    v_formula jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT * INTO v_round
    FROM public.tournament_rounds
    WHERE id=p_tournament_round_id
      AND activo=true;

    IF v_round.id IS NULL THEN
        RAISE EXCEPTION 'La ronda no existe o está inactiva.';
    END IF;

    SELECT * INTO v_team
    FROM public.tournament_teams
    WHERE id=p_tournament_team_id
      AND tournament_id=v_round.tournament_id
      AND activo=true;

    IF v_team.id IS NULL THEN
        RAISE EXCEPTION
            'El equipo no existe, está inactivo o pertenece a otro torneo.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_round.tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para recalcular el HCP del equipo.'
            USING ERRCODE='42501';
    END IF;

    SELECT au.id INTO v_admin_id
    FROM public.admin_users au
    WHERE au.auth_user_id=auth.uid()
      AND au.activo
    ORDER BY au.id
    LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No existe administrador activo asociado.';
    END IF;

    SELECT * INTO v_config
    FROM public.tournament_team_handicap_configs
    WHERE tournament_id=v_round.tournament_id
      AND active=true;

    IF v_config.id IS NULL THEN
        RAISE EXCEPTION
            'El torneo no tiene configuración activa de HCP de equipo.';
    END IF;

    -- Serializa recálculos del mismo equipo/ronda.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            p_tournament_round_id::text || ':' ||
            p_tournament_team_id::text,
            203
        )
    );

    -- Tabla temporal de evidencia calculada desde la composición ACTUAL.
    CREATE TEMP TABLE IF NOT EXISTS pg_temp.tmp_team_hcp_203 (
        tournament_registration_id uuid,
        player_id uuid,
        player_name text,
        handicap_index numeric,
        handicap_source text,
        handicap_source_date date,
        handicap_status text,
        tee_id uuid,
        course_rating numeric,
        slope_rating integer,
        course_par integer,
        course_handicap_unrounded numeric
    ) ON COMMIT DROP;

    TRUNCATE pg_temp.tmp_team_hcp_203;

    INSERT INTO pg_temp.tmp_team_hcp_203(
        tournament_registration_id,
        player_id,
        player_name,
        handicap_index,
        handicap_source,
        handicap_source_date,
        handicap_status,
        tee_id,
        course_rating,
        slope_rating,
        course_par,
        course_handicap_unrounded
    )
    SELECT
        reg.id,
        p.id,
        trim(concat_ws(' ',p.nombres,p.apellidos)),
        COALESCE(p.handicap_verificado,p.handicap_declarado),
        CASE WHEN p.handicap_verificado IS NOT NULL
             THEN 'verified' ELSE 'declared' END,
        CASE WHEN p.handicap_verificado IS NOT NULL
             THEN p.handicap_verificado_fecha
             ELSE p.handicap_declarado_fecha END,
        p.handicap_estatus::text,
        effective_tee.tee_id,
        ratings.course_rating,
        ratings.slope_rating,
        course.course_par,
        CASE
            WHEN COALESCE(p.handicap_verificado,p.handicap_declarado)
                 IS NOT NULL
             AND ratings.course_rating IS NOT NULL
             AND ratings.slope_rating IS NOT NULL
             AND course.course_par IS NOT NULL
            THEN public.calcular_course_handicap_sin_redondear(
                COALESCE(p.handicap_verificado,p.handicap_declarado),
                ratings.slope_rating,
                ratings.course_rating,
                course.course_par
            )
            ELSE NULL
        END
    FROM public.tournament_registrations reg
    JOIN public.players p
      ON p.id=reg.player_id
    LEFT JOIN public.tournament_round_registration_tees rrt
      ON rrt.tournament_id=reg.tournament_id
     AND rrt.tournament_round_id=p_tournament_round_id
     AND rrt.tournament_registration_id=reg.id
    CROSS JOIN LATERAL(
        SELECT COALESCE(rrt.tee_id,reg.marca_salida_id) AS tee_id
    ) effective_tee
    LEFT JOIN public.marcas_salida ms
      ON ms.id=effective_tee.tee_id
    LEFT JOIN public.tournament_tee_overrides tto
      ON tto.tournament_id=reg.tournament_id
     AND tto.marca_salida_id=effective_tee.tee_id
    CROSS JOIN LATERAL(
        SELECT CASE p.sexo::text
                 WHEN 'F' THEN COALESCE(
                     tto.rating_damas,ms.rating_damas
                 )
                 ELSE COALESCE(
                     tto.rating_caballeros,ms.rating_caballeros
                 )
               END::numeric AS course_rating,
               CASE p.sexo::text
                 WHEN 'F' THEN COALESCE(
                     tto.slope_damas,ms.slope_damas
                 )
                 ELSE COALESCE(
                     tto.slope_caballeros,ms.slope_caballeros
                 )
               END::integer AS slope_rating
    ) ratings
    CROSS JOIN LATERAL(
        SELECT sum(h.par)::integer AS course_par
        FROM public.hoyos h
        WHERE h.campo_golf_id=v_round.campo_golf_id
    ) course
    WHERE reg.tournament_id=v_round.tournament_id
      AND reg.tournament_team_id=p_tournament_team_id
      AND reg.activo=true;

    SELECT count(*),
           sum(handicap_index),
           avg(handicap_index),
           count(*) FILTER(
               WHERE handicap_index IS NULL
           )
      INTO v_member_count,
           v_sum_hi,
           v_avg_hi,
           v_missing_rating
      FROM pg_temp.tmp_team_hcp_203;

    IF v_member_count=0 THEN
        RAISE EXCEPTION 'El equipo no tiene integrantes activos.';
    END IF;

    IF EXISTS(
        SELECT 1
        FROM pg_temp.tmp_team_hcp_203
        WHERE handicap_index IS NULL
    ) THEN
        RAISE EXCEPTION
            'Todos los integrantes activos deben tener Handicap Index declarado o verificado.';
    END IF;

    IF v_config.method='GROSS_ONLY' THEN
        v_unrounded:=0;
        v_playing:=0;

        v_formula:=jsonb_build_object(
            'method','GROSS_ONLY',
            'memberCount',v_member_count
        );

    ELSIF v_config.method='AVERAGE_HI_PCT' THEN
        v_unrounded:=v_avg_hi*(v_config.average_pct/100.0);
        v_playing:=public.redondear_handicap_whs(v_unrounded);

        v_formula:=jsonb_build_object(
            'method','AVERAGE_HI_PCT',
            'averageHandicapIndex',v_avg_hi,
            'percentage',v_config.average_pct
        );

    ELSIF v_config.method='ASSIGNED_TABLE_SUM_HI' THEN
        SELECT * INTO v_range
        FROM public.tournament_team_handicap_ranges r
        WHERE r.config_id=v_config.id
          AND v_sum_hi>=r.handicap_sum_from
          AND (
              r.handicap_sum_to IS NULL
              OR v_sum_hi<=r.handicap_sum_to
          )
        ORDER BY r.display_order,r.handicap_sum_from
        LIMIT 1;

        IF v_range.id IS NULL THEN
            RAISE EXCEPTION
                'La suma de HCP del equipo (%) no cae en ningún rango configurado.',
                v_sum_hi;
        END IF;

        v_unrounded:=v_range.assigned_team_handicap;
        v_playing:=public.redondear_handicap_whs(v_unrounded);

        v_formula:=jsonb_build_object(
            'method','ASSIGNED_TABLE_SUM_HI',
            'handicapIndexSum',v_sum_hi,
            'rangeId',v_range.id,
            'rangeFrom',v_range.handicap_sum_from,
            'rangeTo',v_range.handicap_sum_to,
            'assignedTeamHandicap',v_range.assigned_team_handicap
        );

    ELSIF v_config.method='WHS_SCRAMBLE' THEN

        IF v_member_count NOT IN (2,3,4) THEN
            RAISE EXCEPTION
                'WHS_SCRAMBLE solo está definido aquí para equipos de 2, 3 o 4 jugadores. No se inventará una fórmula para % jugadores.',
                v_member_count;
        END IF;

        SELECT count(*) FILTER(
            WHERE course_handicap_unrounded IS NULL
        )
        INTO v_missing_rating
        FROM pg_temp.tmp_team_hcp_203;

        IF v_missing_rating>0 THEN
            RAISE EXCEPTION
                'No se puede calcular WHS_SCRAMBLE: faltan tee/rating/slope para uno o más integrantes.';
        END IF;

        WITH ranked AS (
            SELECT *,
                   row_number() OVER(
                       ORDER BY course_handicap_unrounded,
                                player_id
                   ) AS rn
            FROM pg_temp.tmp_team_hcp_203
        ),
        weighted AS (
            SELECT *,
                   CASE
                       WHEN v_member_count=2 AND rn=1 THEN 35
                       WHEN v_member_count=2 AND rn=2 THEN 15

                       WHEN v_member_count=3 AND rn=1 THEN 30
                       WHEN v_member_count=3 AND rn=2 THEN 20
                       WHEN v_member_count=3 AND rn=3 THEN 10

                       WHEN v_member_count=4 AND rn=1 THEN 25
                       WHEN v_member_count=4 AND rn=2 THEN 20
                       WHEN v_member_count=4 AND rn=3 THEN 15
                       WHEN v_member_count=4 AND rn=4 THEN 10
                   END::numeric AS weight_pct
            FROM ranked
        )
        SELECT sum(
            course_handicap_unrounded*(weight_pct/100.0)
        )
        INTO v_unrounded
        FROM weighted;

        v_playing:=public.redondear_handicap_whs(v_unrounded);

        v_formula:=jsonb_build_object(
            'method','WHS_SCRAMBLE',
            'memberCount',v_member_count,
            'basis','UNROUNDED_COURSE_HANDICAP',
            'weights',
                CASE v_member_count
                    WHEN 2 THEN '[35,15]'::jsonb
                    WHEN 3 THEN '[30,20,10]'::jsonb
                    WHEN 4 THEN '[25,20,15,10]'::jsonb
                END
        );

    ELSE
        RAISE EXCEPTION 'Método no implementado.';
    END IF;

    SELECT COALESCE(max(version),0)+1
      INTO v_version
      FROM public.tournament_round_team_handicap_versions
     WHERE tournament_round_id=p_tournament_round_id
       AND tournament_team_id=p_tournament_team_id;

    UPDATE public.tournament_round_team_handicap_versions
       SET status='superseded',
           superseded_at=now()
     WHERE tournament_round_id=p_tournament_round_id
       AND tournament_team_id=p_tournament_team_id
       AND status='active';

    INSERT INTO public.tournament_round_team_handicap_versions(
        tournament_id,
        tournament_round_id,
        tournament_team_id,
        config_id,
        version,
        method,
        member_count,
        input_handicap_sum,
        input_handicap_average,
        team_handicap_unrounded,
        team_playing_handicap,
        status,
        formula_snapshot,
        calculated_by
    )
    VALUES(
        v_round.tournament_id,
        p_tournament_round_id,
        p_tournament_team_id,
        v_config.id,
        v_version,
        v_config.method,
        v_member_count,
        COALESCE(v_sum_hi,0),
        v_avg_hi,
        v_unrounded,
        v_playing,
        'active',
        v_formula,
        v_admin_id
    )
    RETURNING id INTO v_version_id;

    -- Evidencia por integrante.
    IF v_config.method='WHS_SCRAMBLE' THEN
        INSERT INTO public.tournament_round_team_handicap_members(
            team_handicap_version_id,
            tournament_registration_id,
            player_id,
            player_name,
            handicap_index,
            handicap_source,
            handicap_source_date,
            handicap_status,
            tee_id,
            course_rating,
            slope_rating,
            course_par,
            course_handicap_unrounded,
            whs_rank,
            whs_weight_pct,
            contribution
        )
        SELECT
            v_version_id,
            x.tournament_registration_id,
            x.player_id,
            x.player_name,
            x.handicap_index,
            x.handicap_source,
            x.handicap_source_date,
            x.handicap_status,
            x.tee_id,
            x.course_rating,
            x.slope_rating,
            x.course_par,
            x.course_handicap_unrounded,
            x.rn,
            CASE
                WHEN v_member_count=2 AND x.rn=1 THEN 35
                WHEN v_member_count=2 AND x.rn=2 THEN 15
                WHEN v_member_count=3 AND x.rn=1 THEN 30
                WHEN v_member_count=3 AND x.rn=2 THEN 20
                WHEN v_member_count=3 AND x.rn=3 THEN 10
                WHEN v_member_count=4 AND x.rn=1 THEN 25
                WHEN v_member_count=4 AND x.rn=2 THEN 20
                WHEN v_member_count=4 AND x.rn=3 THEN 15
                WHEN v_member_count=4 AND x.rn=4 THEN 10
            END::numeric,
            x.course_handicap_unrounded*
            (
                CASE
                    WHEN v_member_count=2 AND x.rn=1 THEN 35
                    WHEN v_member_count=2 AND x.rn=2 THEN 15
                    WHEN v_member_count=3 AND x.rn=1 THEN 30
                    WHEN v_member_count=3 AND x.rn=2 THEN 20
                    WHEN v_member_count=3 AND x.rn=3 THEN 10
                    WHEN v_member_count=4 AND x.rn=1 THEN 25
                    WHEN v_member_count=4 AND x.rn=2 THEN 20
                    WHEN v_member_count=4 AND x.rn=3 THEN 15
                    WHEN v_member_count=4 AND x.rn=4 THEN 10
                END::numeric/100.0
            )
        FROM (
            SELECT t.*,
                   row_number() OVER(
                       ORDER BY t.course_handicap_unrounded,t.player_id
                   ) AS rn
            FROM pg_temp.tmp_team_hcp_203 t
        ) x;

    ELSE
        INSERT INTO public.tournament_round_team_handicap_members(
            team_handicap_version_id,
            tournament_registration_id,
            player_id,
            player_name,
            handicap_index,
            handicap_source,
            handicap_source_date,
            handicap_status,
            tee_id,
            course_rating,
            slope_rating,
            course_par,
            course_handicap_unrounded,
            contribution
        )
        SELECT
            v_version_id,
            t.tournament_registration_id,
            t.player_id,
            t.player_name,
            t.handicap_index,
            t.handicap_source,
            t.handicap_source_date,
            t.handicap_status,
            t.tee_id,
            t.course_rating,
            t.slope_rating,
            t.course_par,
            t.course_handicap_unrounded,
            CASE
                WHEN v_config.method='AVERAGE_HI_PCT'
                THEN
                    (t.handicap_index/v_member_count)*
                    (v_config.average_pct/100.0)
                ELSE NULL
            END
        FROM pg_temp.tmp_team_hcp_203 t;
    END IF;

    RETURN jsonb_build_object(
        'teamHandicapVersionId',v_version_id,
        'version',v_version,
        'tournamentId',v_round.tournament_id,
        'tournamentRoundId',p_tournament_round_id,
        'teamId',p_tournament_team_id,
        'method',v_config.method,
        'memberCount',v_member_count,
        'handicapIndexSum',v_sum_hi,
        'handicapIndexAverage',v_avg_hi,
        'teamHandicapUnrounded',v_unrounded,
        'teamPlayingHandicap',v_playing,
        'formula',v_formula
    );
END;
$$;

REVOKE ALL ON FUNCTION public.recalcular_handicap_equipo_a_gogo(
    uuid,uuid
) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.recalcular_handicap_equipo_a_gogo(
    uuid,uuid
) TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 8. Consultar versión activa e historial
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_handicap_equipo_a_gogo(
    p_tournament_round_id uuid,
    p_tournament_team_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_tournament_id uuid;
BEGIN
    SELECT tournament_id INTO v_tournament_id
    FROM public.tournament_rounds
    WHERE id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda no existe.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar este HCP.'
            USING ERRCODE='42501';
    END IF;

    RETURN jsonb_build_object(
        'active',(
            SELECT to_jsonb(v)
            FROM public.tournament_round_team_handicap_versions v
            WHERE v.tournament_round_id=p_tournament_round_id
              AND v.tournament_team_id=p_tournament_team_id
              AND v.status='active'
            LIMIT 1
        ),
        'history',COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'id',v.id,
                    'version',v.version,
                    'method',v.method,
                    'memberCount',v.member_count,
                    'teamHandicapUnrounded',v.team_handicap_unrounded,
                    'teamPlayingHandicap',v.team_playing_handicap,
                    'status',v.status,
                    'formula',v.formula_snapshot,
                    'calculatedAt',v.calculated_at,
                    'members',COALESCE((
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'registrationId',m.tournament_registration_id,
                                'playerId',m.player_id,
                                'playerName',m.player_name,
                                'handicapIndex',m.handicap_index,
                                'source',m.handicap_source,
                                'teeId',m.tee_id,
                                'courseHandicapUnrounded',
                                    m.course_handicap_unrounded,
                                'whsRank',m.whs_rank,
                                'whsWeightPct',m.whs_weight_pct,
                                'contribution',m.contribution
                            )
                            ORDER BY
                                m.whs_rank NULLS LAST,
                                m.player_name
                        )
                        FROM public.tournament_round_team_handicap_members m
                        WHERE m.team_handicap_version_id=v.id
                    ),'[]'::jsonb)
                )
                ORDER BY v.version DESC
            )
            FROM public.tournament_round_team_handicap_versions v
            WHERE v.tournament_round_id=p_tournament_round_id
              AND v.tournament_team_id=p_tournament_team_id
        ),'[]'::jsonb)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_handicap_equipo_a_gogo(
    uuid,uuid
) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.obtener_handicap_equipo_a_gogo(
    uuid,uuid
) TO authenticated,service_role;

COMMENT ON TABLE public.tournament_round_team_handicap_versions IS
'Versiones auditables del hándicap competitivo de un equipo A-Go-Go por ronda. Recalcular crea nueva versión y preserva la anterior.';

COMMENT ON TABLE public.tournament_round_team_handicap_members IS
'Evidencia individual exacta usada para calcular una versión de HCP competitivo de equipo.';

COMMIT;
