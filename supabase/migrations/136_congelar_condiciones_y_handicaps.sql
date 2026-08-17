BEGIN;

-- ============================================================================
-- MIGRACIÓN 136
-- Fase 1 del motor de resultados:
--   1. Congela las condiciones deportivas del torneo.
--   2. Congela el Handicap Index de cada inscripción activa.
--   3. Calcula Course Handicap y Playing Handicap por ronda.
--
-- IMPORTANTE:
-- - Esta migración NO crea tarjetas, scores, cortes ni clasificaciones.
-- - Los cortes continúan siendo configurables después de cada ronda.
-- - La captura futura debe leer estos snapshots, nunca el hándicap vivo.
-- ============================================================================

CREATE TABLE public.tournament_condition_freezes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL UNIQUE
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    schema_version integer NOT NULL DEFAULT 1
        CHECK (schema_version > 0),
    frozen_at timestamptz NOT NULL DEFAULT now(),
    frozen_by uuid NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    tournament_updated_at_source timestamptz NOT NULL,
    round_count integer NOT NULL CHECK (round_count > 0),
    participant_count integer NOT NULL CHECK (participant_count > 0),
    conditions_snapshot jsonb NOT NULL
        CHECK (jsonb_typeof(conditions_snapshot) = 'object'),
    warnings_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb
        CHECK (jsonb_typeof(warnings_snapshot) = 'array')
);

-- Asignación opcional de tee por jugador y ronda. Si no existe fila, se usa
-- tournament_registrations.marca_salida_id. Es obligatoria en la práctica
-- cuando una ronda se juega en otro campo y el tee general no pertenece a él.
CREATE TABLE public.tournament_round_registration_tees (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,
    tournament_registration_id uuid NOT NULL
        REFERENCES public.tournament_registrations(id) ON DELETE RESTRICT,
    tee_id uuid NOT NULL
        REFERENCES public.marcas_salida(id) ON DELETE RESTRICT,
    created_by uuid NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_round_registration_tees_round_registration_uk
        UNIQUE (tournament_round_id, tournament_registration_id)
);

CREATE TABLE public.tournament_round_condition_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    freeze_id uuid NOT NULL
        REFERENCES public.tournament_condition_freezes(id) ON DELETE RESTRICT,
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,
    round_number integer NOT NULL CHECK (round_number > 0),
    round_date date NOT NULL,
    course_id uuid NOT NULL
        REFERENCES public.campos_golf(id) ON DELETE RESTRICT,
    course_name text NOT NULL,
    course_timezone text NOT NULL,
    tournament_format_id uuid NOT NULL
        REFERENCES public.tournament_formats(id) ON DELETE RESTRICT,
    format_code text NOT NULL,
    format_name text NOT NULL,
    participation_type text NOT NULL,
    scoring_engine text NOT NULL,
    format_source text NOT NULL
        CHECK (format_source IN ('tournament', 'round')),
    handicap_allowance_pct numeric NOT NULL
        CHECK (handicap_allowance_pct >= 0 AND handicap_allowance_pct <= 100),
    course_par integer NOT NULL CHECK (course_par > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_round_condition_snapshots_freeze_round_uk
        UNIQUE (freeze_id, tournament_round_id),
    CONSTRAINT tournament_round_condition_snapshots_tournament_round_uk
        UNIQUE (tournament_id, tournament_round_id)
);

CREATE TABLE public.tournament_round_hole_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    freeze_id uuid NOT NULL
        REFERENCES public.tournament_condition_freezes(id) ON DELETE RESTRICT,
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    round_condition_snapshot_id uuid NOT NULL
        REFERENCES public.tournament_round_condition_snapshots(id) ON DELETE RESTRICT,
    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,
    source_hole_id uuid NOT NULL
        REFERENCES public.hoyos(id) ON DELETE RESTRICT,
    hole_number integer NOT NULL CHECK (hole_number BETWEEN 1 AND 18),
    par integer NOT NULL CHECK (par BETWEEN 3 AND 6),
    stroke_index integer NOT NULL CHECK (stroke_index BETWEEN 1 AND 18),
    tee_distances_yards jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(tee_distances_yards) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_round_hole_snapshots_round_number_uk
        UNIQUE (round_condition_snapshot_id, hole_number),
    CONSTRAINT tournament_round_hole_snapshots_round_source_uk
        UNIQUE (round_condition_snapshot_id, source_hole_id)
);

CREATE TABLE public.tournament_handicap_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    freeze_id uuid NOT NULL
        REFERENCES public.tournament_condition_freezes(id) ON DELETE RESTRICT,
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    tournament_registration_id uuid NOT NULL
        REFERENCES public.tournament_registrations(id) ON DELETE RESTRICT,
    player_id uuid NOT NULL
        REFERENCES public.players(id) ON DELETE RESTRICT,
    tournament_category_id uuid NULL
        REFERENCES public.tournament_categories(id) ON DELETE RESTRICT,
    tee_id uuid NULL
        REFERENCES public.marcas_salida(id) ON DELETE RESTRICT,
    registration_folio text NULL,
    player_name text NOT NULL,
    category_name text NULL,
    tee_name text NULL,
    player_sex text NOT NULL CHECK (player_sex IN ('M', 'F')),
    handicap_index numeric NOT NULL,
    handicap_source text NOT NULL
        CHECK (handicap_source IN ('verified', 'declared')),
    handicap_source_date date NULL,
    handicap_status text NOT NULL,
    player_updated_at_source timestamptz NOT NULL,
    registration_updated_at_source timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_handicap_snapshots_freeze_registration_uk
        UNIQUE (freeze_id, tournament_registration_id),
    CONSTRAINT tournament_handicap_snapshots_tournament_registration_uk
        UNIQUE (tournament_id, tournament_registration_id)
);

CREATE TABLE public.tournament_round_handicap_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    freeze_id uuid NOT NULL
        REFERENCES public.tournament_condition_freezes(id) ON DELETE RESTRICT,
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    round_condition_snapshot_id uuid NOT NULL
        REFERENCES public.tournament_round_condition_snapshots(id) ON DELETE RESTRICT,
    handicap_snapshot_id uuid NOT NULL
        REFERENCES public.tournament_handicap_snapshots(id) ON DELETE RESTRICT,
    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,
    tournament_registration_id uuid NOT NULL
        REFERENCES public.tournament_registrations(id) ON DELETE RESTRICT,
    player_id uuid NOT NULL
        REFERENCES public.players(id) ON DELETE RESTRICT,
    tee_id uuid NOT NULL
        REFERENCES public.marcas_salida(id) ON DELETE RESTRICT,
    course_rating numeric NOT NULL,
    slope_rating integer NOT NULL CHECK (slope_rating BETWEEN 55 AND 155),
    rating_source text NOT NULL CHECK (rating_source IN ('tee', 'tournament_override')),
    course_par integer NOT NULL CHECK (course_par > 0),
    handicap_allowance_pct numeric NOT NULL
        CHECK (handicap_allowance_pct >= 0 AND handicap_allowance_pct <= 100),
    course_handicap_unrounded numeric NOT NULL,
    course_handicap integer NOT NULL,
    playing_handicap integer NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_round_handicap_snapshots_round_registration_uk
        UNIQUE (round_condition_snapshot_id, tournament_registration_id)
);

CREATE INDEX idx_tournament_round_condition_snapshots_tournament
    ON public.tournament_round_condition_snapshots(tournament_id, round_number);
CREATE INDEX idx_tournament_round_hole_snapshots_round
    ON public.tournament_round_hole_snapshots(tournament_round_id, hole_number);
CREATE INDEX idx_tournament_handicap_snapshots_player
    ON public.tournament_handicap_snapshots(player_id, tournament_id);
CREATE INDEX idx_tournament_round_handicap_snapshots_registration
    ON public.tournament_round_handicap_snapshots(tournament_registration_id, tournament_round_id);
CREATE INDEX idx_tournament_round_handicap_snapshots_player
    ON public.tournament_round_handicap_snapshots(player_id, tournament_round_id);
CREATE INDEX idx_tournament_round_registration_tees_tournament
    ON public.tournament_round_registration_tees(tournament_id, tournament_round_id);

COMMENT ON TABLE public.tournament_condition_freezes IS
    'Cabecera inmutable del congelamiento de condiciones y Handicap Index de un torneo.';
COMMENT ON TABLE public.tournament_round_registration_tees IS
    'Override de marca de salida por inscripción y ronda; permite torneos multicampo y tees distintos por ronda.';
COMMENT ON TABLE public.tournament_round_condition_snapshots IS
    'Condiciones efectivas e inmutables de cada ronda: campo, formato, motor y allowance.';
COMMENT ON TABLE public.tournament_round_hole_snapshots IS
    'Par, Stroke Index y distancias por tee congelados por ronda.';
COMMENT ON TABLE public.tournament_handicap_snapshots IS
    'Handicap Index y datos deportivos de cada inscripción activa al congelar.';
COMMENT ON TABLE public.tournament_round_handicap_snapshots IS
    'Course Handicap y Playing Handicap calculados para cada jugador y ronda.';

-- ---------------------------------------------------------------------------
-- Fórmulas WHS reutilizables.
-- El redondeo usa floor(valor + 0.5), por lo que un valor plus terminado en .5
-- se redondea hacia cero, conforme al tratamiento WHS de hándicaps plus.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.redondear_handicap_whs(p_value numeric)
RETURNS integer
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = public
AS $$
    SELECT floor(p_value + 0.5)::integer;
$$;

CREATE OR REPLACE FUNCTION public.calcular_course_handicap_sin_redondear(
    p_handicap_index numeric,
    p_slope_rating integer,
    p_course_rating numeric,
    p_par integer
)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = public
AS $$
BEGIN
    IF p_slope_rating < 55 OR p_slope_rating > 155 THEN
        RAISE EXCEPTION 'Slope Rating fuera del rango 55..155.' USING ERRCODE = '22023';
    END IF;
    IF p_par <= 0 THEN
        RAISE EXCEPTION 'El PAR debe ser positivo.' USING ERRCODE = '22023';
    END IF;

    RETURN (p_handicap_index * (p_slope_rating::numeric / 113::numeric))
           + (p_course_rating - p_par::numeric);
END;
$$;

CREATE OR REPLACE FUNCTION public.calcular_playing_handicap(
    p_course_handicap_unrounded numeric,
    p_handicap_allowance_pct numeric
)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = public
AS $$
BEGIN
    IF p_handicap_allowance_pct < 0 OR p_handicap_allowance_pct > 100 THEN
        RAISE EXCEPTION 'Handicap allowance fuera del rango 0..100.' USING ERRCODE = '22023';
    END IF;

    RETURN public.redondear_handicap_whs(
        p_course_handicap_unrounded * p_handicap_allowance_pct / 100::numeric
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- Acceso y protección de snapshots.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.puede_administrar_congelamiento_torneo(
    p_tournament_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT auth.uid() IS NOT NULL
       AND (
            public.is_superadmin(auth.uid())
            OR public.is_tournament_organizer(auth.uid(), p_tournament_id)
            OR EXISTS (
                SELECT 1
                FROM public.tournaments t
                WHERE t.id = p_tournament_id
                  AND public.is_club_admin(auth.uid(), t.club_id)
            )
       );
$$;

CREATE OR REPLACE FUNCTION public.puede_ver_congelamiento_torneo(
    p_tournament_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT public.puede_administrar_congelamiento_torneo(p_tournament_id)
        OR EXISTS (
            SELECT 1
            FROM public.tournament_registrations tr
            JOIN public.players p ON p.id = tr.player_id
            WHERE tr.tournament_id = p_tournament_id
              AND tr.activo = true
              AND p.auth_user_id = auth.uid()
        )
        OR EXISTS (
            SELECT 1
            FROM public.tournament_handicap_snapshots hs
            JOIN public.players p ON p.id = hs.player_id
            WHERE hs.tournament_id = p_tournament_id
              AND p.auth_user_id = auth.uid()
        );
$$;

CREATE OR REPLACE FUNCTION public.impedir_mutacion_snapshot_torneo()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    RAISE EXCEPTION
        'Los snapshots congelados son inmutables. Cree un proceso explícito de corrección/versionado; no edite ni elimine estas filas.'
        USING ERRCODE = '55000';
END;
$$;

CREATE OR REPLACE FUNCTION public.validar_tee_inscripcion_ronda()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_round_tournament_id uuid;
    v_round_course_id uuid;
    v_registration_tournament_id uuid;
    v_tee_course_id uuid;
    v_tee_active boolean;
BEGIN
    SELECT tr.tournament_id, tr.campo_golf_id
      INTO v_round_tournament_id, v_round_course_id
      FROM public.tournament_rounds tr
     WHERE tr.id = NEW.tournament_round_id
       AND tr.activo = true;

    SELECT reg.tournament_id
      INTO v_registration_tournament_id
      FROM public.tournament_registrations reg
     WHERE reg.id = NEW.tournament_registration_id
       AND reg.activo = true;

    SELECT ms.campo_golf_id, ms.activo
      INTO v_tee_course_id, v_tee_active
      FROM public.marcas_salida ms
     WHERE ms.id = NEW.tee_id;

    IF v_round_tournament_id IS NULL OR v_registration_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda o la inscripción no existe o está inactiva.' USING ERRCODE = '23514';
    END IF;

    IF NEW.tournament_id IS DISTINCT FROM v_round_tournament_id
       OR NEW.tournament_id IS DISTINCT FROM v_registration_tournament_id THEN
        RAISE EXCEPTION 'La ronda, la inscripción y el override de tee deben pertenecer al mismo torneo.'
            USING ERRCODE = '23514';
    END IF;

    IF COALESCE(v_tee_active, false) = false OR v_tee_course_id IS DISTINCT FROM v_round_course_id THEN
        RAISE EXCEPTION 'La marca de salida debe estar activa y pertenecer al campo de la ronda.'
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = NEW.tournament_id
    ) THEN
        RAISE EXCEPTION 'No se pueden cambiar tees por ronda después de congelar el torneo.'
            USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'INSERT' THEN
        NEW.created_by := (
            SELECT au.id
            FROM public.admin_users au
            WHERE au.auth_user_id = auth.uid() AND au.activo = true
            ORDER BY au.id LIMIT 1
        );
    ELSE
        NEW.created_by := OLD.created_by;
        NEW.created_at := OLD.created_at;
    END IF;

    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.bloquear_borrado_tee_inscripcion_ronda_congelado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = OLD.tournament_id
    ) THEN
        RAISE EXCEPTION 'No se pueden borrar tees por ronda después de congelar el torneo.'
            USING ERRCODE = '55000';
    END IF;
    RETURN OLD;
END;
$$;

CREATE TRIGGER trg_validar_tournament_round_registration_tees
BEFORE INSERT OR UPDATE ON public.tournament_round_registration_tees
FOR EACH ROW EXECUTE FUNCTION public.validar_tee_inscripcion_ronda();

CREATE TRIGGER trg_bloquear_borrado_tournament_round_registration_tees
BEFORE DELETE ON public.tournament_round_registration_tees
FOR EACH ROW EXECUTE FUNCTION public.bloquear_borrado_tee_inscripcion_ronda_congelado();

CREATE TRIGGER trg_audit_tournament_round_registration_tees
AFTER INSERT OR UPDATE OR DELETE ON public.tournament_round_registration_tees
FOR EACH ROW EXECUTE FUNCTION public.log_audit();

CREATE TRIGGER trg_no_mutar_tournament_condition_freezes
BEFORE UPDATE OR DELETE ON public.tournament_condition_freezes
FOR EACH ROW EXECUTE FUNCTION public.impedir_mutacion_snapshot_torneo();

CREATE TRIGGER trg_no_mutar_tournament_round_condition_snapshots
BEFORE UPDATE OR DELETE ON public.tournament_round_condition_snapshots
FOR EACH ROW EXECUTE FUNCTION public.impedir_mutacion_snapshot_torneo();

CREATE TRIGGER trg_no_mutar_tournament_round_hole_snapshots
BEFORE UPDATE OR DELETE ON public.tournament_round_hole_snapshots
FOR EACH ROW EXECUTE FUNCTION public.impedir_mutacion_snapshot_torneo();

CREATE TRIGGER trg_no_mutar_tournament_handicap_snapshots
BEFORE UPDATE OR DELETE ON public.tournament_handicap_snapshots
FOR EACH ROW EXECUTE FUNCTION public.impedir_mutacion_snapshot_torneo();

CREATE TRIGGER trg_no_mutar_tournament_round_handicap_snapshots
BEFORE UPDATE OR DELETE ON public.tournament_round_handicap_snapshots
FOR EACH ROW EXECUTE FUNCTION public.impedir_mutacion_snapshot_torneo();

CREATE TRIGGER trg_audit_tournament_condition_freezes
AFTER INSERT ON public.tournament_condition_freezes
FOR EACH ROW EXECUTE FUNCTION public.log_audit();

ALTER TABLE public.tournament_condition_freezes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_round_registration_tees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_round_condition_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_round_hole_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_handicap_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_round_handicap_snapshots ENABLE ROW LEVEL SECURITY;

CREATE POLICY tournament_condition_freezes_select
ON public.tournament_condition_freezes
FOR SELECT TO authenticated
USING (public.puede_ver_congelamiento_torneo(tournament_id));

CREATE POLICY tournament_round_registration_tees_select
ON public.tournament_round_registration_tees
FOR SELECT TO authenticated
USING (public.puede_ver_congelamiento_torneo(tournament_id));

CREATE POLICY tournament_round_registration_tees_write
ON public.tournament_round_registration_tees
FOR ALL TO authenticated
USING (public.puede_administrar_congelamiento_torneo(tournament_id))
WITH CHECK (public.puede_administrar_congelamiento_torneo(tournament_id));

CREATE POLICY tournament_round_condition_snapshots_select
ON public.tournament_round_condition_snapshots
FOR SELECT TO authenticated
USING (public.puede_ver_congelamiento_torneo(tournament_id));

CREATE POLICY tournament_round_hole_snapshots_select
ON public.tournament_round_hole_snapshots
FOR SELECT TO authenticated
USING (public.puede_ver_congelamiento_torneo(tournament_id));

CREATE POLICY tournament_handicap_snapshots_select
ON public.tournament_handicap_snapshots
FOR SELECT TO authenticated
USING (public.puede_ver_congelamiento_torneo(tournament_id));

CREATE POLICY tournament_round_handicap_snapshots_select
ON public.tournament_round_handicap_snapshots
FOR SELECT TO authenticated
USING (public.puede_ver_congelamiento_torneo(tournament_id));

-- ---------------------------------------------------------------------------
-- Preview de validación. No escribe nada.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.previsualizar_congelamiento_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para congelar este torneo.' USING ERRCODE = '42501';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.tournaments WHERE id = p_tournament_id) THEN
        RAISE EXCEPTION 'El torneo no existe.' USING ERRCODE = '22023';
    END IF;

    WITH tournament_ctx AS (
        SELECT t.*,
               (SELECT count(*) FROM public.tournament_rounds r
                WHERE r.tournament_id = t.id AND r.activo = true) AS active_rounds,
               (SELECT count(*) FROM public.tournament_registrations reg
                WHERE reg.tournament_id = t.id AND reg.activo = true) AS active_registrations,
               (SELECT count(*) FROM public.tournament_categories tc
                WHERE tc.tournament_id = t.id) AS category_count
        FROM public.tournaments t
        WHERE t.id = p_tournament_id
    ),
    effective_rounds AS (
        SELECT tr.id AS round_id,
               tr.numero_ronda,
               tr.campo_golf_id,
               tr.tournament_format_id,
               COALESCE(tr.tournament_format_id, t.tournament_format_id) AS effective_format_id,
               COALESCE(tr.handicap_allowance_pct, tf.handicap_allowance_default) AS effective_allowance,
               tf.code AS format_code,
               tf.scoring_engine::text AS scoring_engine,
               tf.tipo_participacion::text AS participation_type,
               cg.activo AS course_active,
               cg.nombre_oficial AS course_name
        FROM public.tournament_rounds tr
        JOIN public.tournaments t ON t.id = tr.tournament_id
        LEFT JOIN public.tournament_formats tf
          ON tf.id = COALESCE(tr.tournament_format_id, t.tournament_format_id)
        LEFT JOIN public.campos_golf cg ON cg.id = tr.campo_golf_id
        WHERE tr.tournament_id = p_tournament_id
          AND tr.activo = true
    ),
    active_regs AS (
        SELECT reg.id AS registration_id,
               reg.player_id,
               reg.tournament_category_id,
               reg.marca_salida_id AS tee_id,
               p.activo AS player_active,
               p.sexo::text AS player_sex,
               p.handicap_verificado,
               p.handicap_declarado,
               p.handicap_estatus::text AS handicap_status,
               (tc.id IS NOT NULL) AS category_valid
        FROM public.tournament_registrations reg
        LEFT JOIN public.players p ON p.id = reg.player_id
        LEFT JOIN public.tournament_categories tc
          ON tc.id = reg.tournament_category_id
         AND tc.tournament_id = reg.tournament_id
        WHERE reg.tournament_id = p_tournament_id
          AND reg.activo = true
    ),
    round_regs AS (
        SELECT ar.*,
               er.round_id,
               er.numero_ronda,
               er.campo_golf_id,
               COALESCE(rrt.tee_id, ar.tee_id) AS effective_tee_id,
               (rrt.id IS NOT NULL) AS uses_round_tee_override,
               ms.activo AS effective_tee_active,
               ms.campo_golf_id AS effective_tee_course_id
        FROM active_regs ar
        CROSS JOIN effective_rounds er
        LEFT JOIN public.tournament_round_registration_tees rrt
          ON rrt.tournament_round_id = er.round_id
         AND rrt.tournament_registration_id = ar.registration_id
         AND rrt.tournament_id = p_tournament_id
        LEFT JOIN public.marcas_salida ms
          ON ms.id = COALESCE(rrt.tee_id, ar.tee_id)
    ),
    errors AS (
        SELECT 'tournament_inactive'::text AS code,
               'El torneo está inactivo.'::text AS message,
               NULL::uuid AS round_id, NULL::uuid AS registration_id
        FROM tournament_ctx t WHERE t.activo = false

        UNION ALL
        SELECT 'tournament_closed',
               'No se puede congelar un torneo cancelado o finalizado.', NULL, NULL
        FROM tournament_ctx t WHERE t.estatus::text IN ('cancelado', 'finalizado')

        UNION ALL
        SELECT 'already_frozen',
               'El torneo ya tiene condiciones y hándicaps congelados.', NULL, NULL
        WHERE EXISTS (
            SELECT 1 FROM public.tournament_condition_freezes f
            WHERE f.tournament_id = p_tournament_id
        )

        UNION ALL
        SELECT 'round_count_mismatch',
               format('El torneo declara %s ronda(s), pero tiene %s ronda(s) activa(s).',
                      t.numero_rondas, t.active_rounds), NULL, NULL
        FROM tournament_ctx t
        WHERE t.active_rounds <> t.numero_rondas OR t.active_rounds = 0

        UNION ALL
        SELECT 'no_active_participants',
               'No existen inscripciones activas para congelar.', NULL, NULL
        FROM tournament_ctx t WHERE t.active_registrations = 0

        UNION ALL
        SELECT 'round_without_format',
               format('La ronda %s no tiene formato efectivo.', er.numero_ronda),
               er.round_id, NULL
        FROM effective_rounds er WHERE er.effective_format_id IS NULL OR er.format_code IS NULL

        UNION ALL
        SELECT 'round_without_allowance',
               format('La ronda %s no tiene Handicap Allowance efectivo.', er.numero_ronda),
               er.round_id, NULL
        FROM effective_rounds er WHERE er.effective_allowance IS NULL

        UNION ALL
        SELECT 'round_allowance_invalid',
               format('La ronda %s tiene Handicap Allowance fuera de 0..100.', er.numero_ronda),
               er.round_id, NULL
        FROM effective_rounds er
        WHERE er.effective_allowance IS NOT NULL
          AND (er.effective_allowance < 0 OR er.effective_allowance > 100)

        UNION ALL
        SELECT 'round_course_inactive_or_missing',
               format('El campo de la ronda %s no existe o está inactivo.', er.numero_ronda),
               er.round_id, NULL
        FROM effective_rounds er WHERE COALESCE(er.course_active, false) = false

        UNION ALL
        SELECT 'round_course_not_18_holes',
               format('La ronda %s tiene %s hoyos en catálogo; esta fase exige exactamente 18.',
                      er.numero_ronda, count(h.id)), er.round_id, NULL
        FROM effective_rounds er
        LEFT JOIN public.hoyos h ON h.campo_golf_id = er.campo_golf_id
        GROUP BY er.round_id, er.numero_ronda
        HAVING count(h.id) <> 18

        UNION ALL
        SELECT 'round_stroke_index_invalid',
               format('La ronda %s no tiene Stroke Index único y completo de 1 a 18.', er.numero_ronda),
               er.round_id, NULL
        FROM effective_rounds er
        LEFT JOIN public.hoyos h ON h.campo_golf_id = er.campo_golf_id
        GROUP BY er.round_id, er.numero_ronda
        HAVING NOT (
            count(h.id) = 18
            AND count(DISTINCT h.handicap_hoyo) = 18
            AND min(h.handicap_hoyo) = 1
            AND max(h.handicap_hoyo) = 18
        )

        UNION ALL
        SELECT 'player_missing_or_inactive',
               'La inscripción activa no tiene un jugador activo.', NULL, ar.registration_id
        FROM active_regs ar WHERE COALESCE(ar.player_active, false) = false

        UNION ALL
        SELECT 'handicap_index_missing',
               'El jugador no tiene Handicap Index verificado ni declarado.', NULL, ar.registration_id
        FROM active_regs ar
        WHERE ar.handicap_verificado IS NULL AND ar.handicap_declarado IS NULL

        UNION ALL
        SELECT 'category_missing',
               'La inscripción no tiene categoría, aunque el torneo sí usa categorías.', NULL, ar.registration_id
        FROM active_regs ar
        CROSS JOIN tournament_ctx t
        WHERE t.category_count > 0 AND ar.tournament_category_id IS NULL

        UNION ALL
        SELECT 'category_from_another_tournament',
               'La categoría de la inscripción no pertenece al torneo.', NULL, ar.registration_id
        FROM active_regs ar
        WHERE ar.tournament_category_id IS NOT NULL
          AND ar.category_valid = false

        UNION ALL
        SELECT 'tee_missing_or_inactive',
               format('La inscripción no tiene una marca de salida activa para la ronda %s.', rr.numero_ronda),
               rr.round_id, rr.registration_id
        FROM round_regs rr
        WHERE rr.effective_tee_id IS NULL OR COALESCE(rr.effective_tee_active, false) = false

        UNION ALL
        SELECT 'tee_not_from_round_course',
               format('La marca de salida efectiva del jugador no pertenece al campo de la ronda %s; asigna un tee específico para esa ronda.', rr.numero_ronda),
               rr.round_id, rr.registration_id
        FROM round_regs rr
        WHERE rr.effective_tee_id IS NOT NULL
          AND rr.effective_tee_course_id IS DISTINCT FROM rr.campo_golf_id

        UNION ALL
        SELECT 'rating_or_slope_missing',
               format('Falta Course Rating o Slope efectivo para el sexo del jugador en la ronda %s.',
                      rr.numero_ronda), rr.round_id, rr.registration_id
        FROM round_regs rr
        JOIN public.marcas_salida ms ON ms.id = rr.effective_tee_id
        LEFT JOIN public.tournament_tee_overrides tto
          ON tto.tournament_id = p_tournament_id
         AND tto.marca_salida_id = ms.id
        WHERE CASE rr.player_sex
                WHEN 'F' THEN COALESCE(tto.rating_damas, ms.rating_damas) IS NULL
                           OR COALESCE(tto.slope_damas, ms.slope_damas) IS NULL
                ELSE COALESCE(tto.rating_caballeros, ms.rating_caballeros) IS NULL
                     OR COALESCE(tto.slope_caballeros, ms.slope_caballeros) IS NULL
              END
    ),
    warnings AS (
        SELECT 'declared_handicap_used'::text AS code,
               'Se usará el hándicap declarado porque no existe uno verificado.'::text AS message,
               NULL::uuid AS round_id, ar.registration_id
        FROM active_regs ar
        WHERE ar.handicap_verificado IS NULL AND ar.handicap_declarado IS NOT NULL

        UNION ALL
        SELECT 'expired_handicap',
               'El hándicap del jugador figura como vencido; se congelará con advertencia.',
               NULL, ar.registration_id
        FROM active_regs ar WHERE ar.handicap_status = 'vencido'

        UNION ALL
        SELECT 'missing_tee_distance',
               format('Falta al menos una distancia de la marca para la ronda %s; no afecta el cálculo de hándicap.',
                      rr.numero_ronda), rr.round_id, rr.registration_id
        FROM round_regs rr
        WHERE rr.effective_tee_id IS NOT NULL
          AND rr.effective_tee_course_id = rr.campo_golf_id
          AND EXISTS (
              SELECT 1
              FROM public.hoyos h
              LEFT JOIN public.distancias_hoyo dh
                ON dh.hoyo_id = h.id AND dh.marca_salida_id = rr.effective_tee_id
              WHERE h.campo_golf_id = rr.campo_golf_id
                AND dh.id IS NULL
          )
    ),
    errors_json AS (
        SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                    'code', code, 'message', message,
                    'roundId', round_id, 'registrationId', registration_id
               )) ORDER BY code, message), '[]'::jsonb) AS data,
               count(*) AS n
        FROM errors
    ),
    warnings_json AS (
        SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                    'code', code, 'message', message,
                    'roundId', round_id, 'registrationId', registration_id
               )) ORDER BY code, message), '[]'::jsonb) AS data,
               count(*) AS n
        FROM warnings
    )
    SELECT jsonb_build_object(
        'tournamentId', p_tournament_id,
        'ready', ej.n = 0,
        'errors', ej.data,
        'warnings', wj.data,
        'counts', jsonb_build_object(
            'errors', ej.n,
            'warnings', wj.n,
            'rounds', t.active_rounds,
            'participants', t.active_registrations
        )
    )
    INTO v_result
    FROM tournament_ctx t
    CROSS JOIN errors_json ej
    CROSS JOIN warnings_json wj;

    RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Estado ligero para pintar el botón y el resumen en Lovable.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_estado_congelamiento_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    IF NOT public.puede_ver_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar este torneo.' USING ERRCODE = '42501';
    END IF;

    SELECT jsonb_build_object(
        'tournamentId', p_tournament_id,
        'frozen', f.id IS NOT NULL,
        'freezeId', f.id,
        'frozenAt', f.frozen_at,
        'rounds', COALESCE(f.round_count, 0),
        'participants', COALESCE(f.participant_count, 0),
        'warnings', COALESCE(f.warnings_snapshot, '[]'::jsonb)
    )
    INTO v_result
    FROM (SELECT 1) seed
    LEFT JOIN public.tournament_condition_freezes f
      ON f.tournament_id = p_tournament_id;

    RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Congelamiento atómico.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.congelar_condiciones_y_handicaps_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_preview jsonb;
    v_freeze_id uuid;
    v_admin_id uuid;
    v_conditions jsonb;
    v_round_count integer;
    v_participant_count integer;
    v_round_snapshot_count integer;
    v_hole_snapshot_count integer;
    v_round_handicap_count integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para congelar este torneo.' USING ERRCODE = '42501';
    END IF;

    -- Serializa dos intentos de congelamiento del mismo torneo.
    PERFORM pg_advisory_xact_lock(hashtextextended(p_tournament_id::text, 136));

    -- Bloquea las filas fuente relevantes durante la fotografía.
    PERFORM 1 FROM public.tournaments
     WHERE id = p_tournament_id FOR UPDATE;
    PERFORM 1 FROM public.tournament_rounds
     WHERE tournament_id = p_tournament_id AND activo = true FOR SHARE;
    PERFORM 1 FROM public.tournament_registrations
     WHERE tournament_id = p_tournament_id AND activo = true FOR SHARE;
    PERFORM 1 FROM public.players p
     WHERE EXISTS (
        SELECT 1 FROM public.tournament_registrations r
        WHERE r.tournament_id = p_tournament_id AND r.activo = true AND r.player_id = p.id
     ) FOR SHARE;
    PERFORM 1 FROM public.marcas_salida ms
     WHERE EXISTS (
        SELECT 1 FROM public.tournament_registrations r
        WHERE r.tournament_id = p_tournament_id
          AND r.activo = true
          AND r.marca_salida_id = ms.id
     ) OR EXISTS (
        SELECT 1 FROM public.tournament_round_registration_tees rrt
        WHERE rrt.tournament_id = p_tournament_id
          AND rrt.tee_id = ms.id
     ) FOR SHARE;
    PERFORM 1 FROM public.tournament_round_registration_tees
     WHERE tournament_id = p_tournament_id FOR SHARE;
    PERFORM 1 FROM public.hoyos h
     WHERE EXISTS (
        SELECT 1 FROM public.tournament_rounds r
        WHERE r.tournament_id = p_tournament_id
          AND r.activo = true
          AND r.campo_golf_id = h.campo_golf_id
     ) FOR SHARE;
    PERFORM 1 FROM public.tournament_tee_overrides
     WHERE tournament_id = p_tournament_id FOR SHARE;
    PERFORM 1 FROM public.tournament_categories
     WHERE tournament_id = p_tournament_id FOR SHARE;
    PERFORM 1 FROM public.tournament_franjas_handicap
     WHERE tournament_id = p_tournament_id FOR SHARE;
    PERFORM 1 FROM public.tournament_tiebreak_rules
     WHERE tournament_id = p_tournament_id FOR SHARE;

    v_preview := public.previsualizar_congelamiento_torneo(p_tournament_id);

    IF COALESCE((v_preview #>> '{counts,errors}')::integer, 0) > 0 THEN
        RAISE EXCEPTION 'El torneo no está listo para congelarse.'
            USING ERRCODE = '22023', DETAIL = v_preview::text;
    END IF;

    SELECT count(*)
      INTO v_round_count
      FROM public.tournament_rounds
     WHERE tournament_id = p_tournament_id AND activo = true;

    SELECT count(*)
      INTO v_participant_count
      FROM public.tournament_registrations
     WHERE tournament_id = p_tournament_id AND activo = true;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo = true
     ORDER BY au.id
     LIMIT 1;

    SELECT jsonb_build_object(
        'schemaVersion', 1,
        'formulaVersion', 'WHS-2024',
        'cutRulesIncluded', false,
        'cutRulesNote', 'Los cortes se deciden y aplican después de cada ronda; no se congelan aquí.',
        'tournament', to_jsonb(t),
        'categories', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'tournamentCategory', to_jsonb(tc),
                    'category', to_jsonb(c)
                ) ORDER BY c.display_order NULLS LAST, c.nombre, tc.id
            )
            FROM public.tournament_categories tc
            JOIN public.categories c ON c.id = tc.category_id
            WHERE tc.tournament_id = t.id
        ), '[]'::jsonb),
        'teeOverrides', COALESCE((
            SELECT jsonb_agg(to_jsonb(tto) ORDER BY tto.marca_salida_id)
            FROM public.tournament_tee_overrides tto
            WHERE tto.tournament_id = t.id
        ), '[]'::jsonb),
        'roundRegistrationTees', COALESCE((
            SELECT jsonb_agg(to_jsonb(rrt)
                             ORDER BY rrt.tournament_round_id, rrt.tournament_registration_id)
            FROM public.tournament_round_registration_tees rrt
            WHERE rrt.tournament_id = t.id
        ), '[]'::jsonb),
        'handicapBands', COALESCE((
            SELECT jsonb_agg(to_jsonb(fh) ORDER BY fh.id)
            FROM public.tournament_franjas_handicap fh
            WHERE fh.tournament_id = t.id
        ), '[]'::jsonb),
        'tiebreakRules', COALESCE((
            SELECT jsonb_agg(to_jsonb(tb) ORDER BY tb.id)
            FROM public.tournament_tiebreak_rules tb
            WHERE tb.tournament_id = t.id
        ), '[]'::jsonb)
    )
    INTO v_conditions
    FROM public.tournaments t
    WHERE t.id = p_tournament_id;

    INSERT INTO public.tournament_condition_freezes (
        tournament_id,
        frozen_by,
        tournament_updated_at_source,
        round_count,
        participant_count,
        conditions_snapshot,
        warnings_snapshot
    )
    SELECT t.id,
           v_admin_id,
           t.updated_at,
           v_round_count,
           v_participant_count,
           v_conditions,
           COALESCE(v_preview->'warnings', '[]'::jsonb)
    FROM public.tournaments t
    WHERE t.id = p_tournament_id
    RETURNING id INTO v_freeze_id;

    INSERT INTO public.tournament_round_condition_snapshots (
        freeze_id, tournament_id, tournament_round_id,
        round_number, round_date, course_id, course_name, course_timezone,
        tournament_format_id, format_code, format_name,
        participation_type, scoring_engine, format_source,
        handicap_allowance_pct, course_par
    )
    SELECT v_freeze_id,
           t.id,
           tr.id,
           tr.numero_ronda,
           tr.fecha,
           tr.campo_golf_id,
           cg.nombre_oficial,
           cg.timezone_id,
           tf.id,
           tf.code,
           tf.name,
           tf.tipo_participacion::text,
           tf.scoring_engine::text,
           CASE WHEN tr.tournament_format_id IS NULL THEN 'tournament' ELSE 'round' END,
           COALESCE(tr.handicap_allowance_pct, tf.handicap_allowance_default),
           hp.course_par
    FROM public.tournament_rounds tr
    JOIN public.tournaments t ON t.id = tr.tournament_id
    JOIN public.tournament_formats tf
      ON tf.id = COALESCE(tr.tournament_format_id, t.tournament_format_id)
    JOIN public.campos_golf cg ON cg.id = tr.campo_golf_id
    CROSS JOIN LATERAL (
        SELECT sum(h.par)::integer AS course_par
        FROM public.hoyos h
        WHERE h.campo_golf_id = tr.campo_golf_id
    ) hp
    WHERE tr.tournament_id = p_tournament_id
      AND tr.activo = true;

    GET DIAGNOSTICS v_round_snapshot_count = ROW_COUNT;

    INSERT INTO public.tournament_round_hole_snapshots (
        freeze_id, tournament_id, round_condition_snapshot_id,
        tournament_round_id, source_hole_id,
        hole_number, par, stroke_index, tee_distances_yards
    )
    SELECT v_freeze_id,
           p_tournament_id,
           rcs.id,
           rcs.tournament_round_id,
           h.id,
           h.numero_hoyo,
           h.par,
           h.handicap_hoyo,
           COALESCE((
               SELECT jsonb_object_agg(ut.tee_id::text, dh.distancia_yardas)
               FROM (
                   SELECT DISTINCT COALESCE(rrt.tee_id, reg.marca_salida_id) AS tee_id
                   FROM public.tournament_registrations reg
                   LEFT JOIN public.tournament_round_registration_tees rrt
                     ON rrt.tournament_id = p_tournament_id
                    AND rrt.tournament_round_id = rcs.tournament_round_id
                    AND rrt.tournament_registration_id = reg.id
                   WHERE reg.tournament_id = p_tournament_id
                     AND reg.activo = true
                     AND COALESCE(rrt.tee_id, reg.marca_salida_id) IS NOT NULL
               ) ut
               LEFT JOIN public.distancias_hoyo dh
                 ON dh.hoyo_id = h.id AND dh.marca_salida_id = ut.tee_id
           ), '{}'::jsonb)
    FROM public.tournament_round_condition_snapshots rcs
    JOIN public.hoyos h ON h.campo_golf_id = rcs.course_id
    WHERE rcs.freeze_id = v_freeze_id;

    GET DIAGNOSTICS v_hole_snapshot_count = ROW_COUNT;

    INSERT INTO public.tournament_handicap_snapshots (
        freeze_id, tournament_id, tournament_registration_id,
        player_id, tournament_category_id, tee_id,
        registration_folio, player_name, category_name, tee_name, player_sex,
        handicap_index, handicap_source, handicap_source_date, handicap_status,
        player_updated_at_source, registration_updated_at_source
    )
    SELECT v_freeze_id,
           p_tournament_id,
           reg.id,
           p.id,
           reg.tournament_category_id,
           reg.marca_salida_id,
           reg.folio,
           trim(concat_ws(' ', p.nombres, p.apellidos)),
           c.nombre,
           ms.nombre,
           p.sexo::text,
           COALESCE(p.handicap_verificado, p.handicap_declarado),
           CASE WHEN p.handicap_verificado IS NOT NULL THEN 'verified' ELSE 'declared' END,
           CASE WHEN p.handicap_verificado IS NOT NULL
                THEN p.handicap_verificado_fecha
                ELSE p.handicap_declarado_fecha END,
           p.handicap_estatus::text,
           p.updated_at,
           reg.updated_at
    FROM public.tournament_registrations reg
    JOIN public.players p ON p.id = reg.player_id
    LEFT JOIN public.marcas_salida ms ON ms.id = reg.marca_salida_id
    LEFT JOIN public.tournament_categories tc ON tc.id = reg.tournament_category_id
    LEFT JOIN public.categories c ON c.id = tc.category_id
    WHERE reg.tournament_id = p_tournament_id
      AND reg.activo = true;

    INSERT INTO public.tournament_round_handicap_snapshots (
        freeze_id, tournament_id, round_condition_snapshot_id,
        handicap_snapshot_id, tournament_round_id,
        tournament_registration_id, player_id, tee_id,
        course_rating, slope_rating, rating_source,
        course_par, handicap_allowance_pct,
        course_handicap_unrounded, course_handicap, playing_handicap
    )
    SELECT v_freeze_id,
           p_tournament_id,
           rcs.id,
           hs.id,
           rcs.tournament_round_id,
           hs.tournament_registration_id,
           hs.player_id,
           effective_tee.tee_id,
           calc.course_rating,
           calc.slope_rating,
           CASE
             WHEN (hs.player_sex = 'F' AND (tto.rating_damas IS NOT NULL OR tto.slope_damas IS NOT NULL))
               OR (hs.player_sex = 'M' AND (tto.rating_caballeros IS NOT NULL OR tto.slope_caballeros IS NOT NULL))
             THEN 'tournament_override'
             ELSE 'tee'
           END,
           rcs.course_par,
           rcs.handicap_allowance_pct,
           ch.value,
           public.redondear_handicap_whs(ch.value),
           public.calcular_playing_handicap(ch.value, rcs.handicap_allowance_pct)
    FROM public.tournament_round_condition_snapshots rcs
    JOIN public.tournament_handicap_snapshots hs
      ON hs.freeze_id = rcs.freeze_id
    LEFT JOIN public.tournament_round_registration_tees rrt
      ON rrt.tournament_id = p_tournament_id
     AND rrt.tournament_round_id = rcs.tournament_round_id
     AND rrt.tournament_registration_id = hs.tournament_registration_id
    CROSS JOIN LATERAL (
        SELECT COALESCE(rrt.tee_id, hs.tee_id) AS tee_id
    ) effective_tee
    JOIN public.marcas_salida ms ON ms.id = effective_tee.tee_id
    LEFT JOIN public.tournament_tee_overrides tto
      ON tto.tournament_id = p_tournament_id
     AND tto.marca_salida_id = effective_tee.tee_id
    CROSS JOIN LATERAL (
        SELECT CASE hs.player_sex
                 WHEN 'F' THEN COALESCE(tto.rating_damas, ms.rating_damas)
                 ELSE COALESCE(tto.rating_caballeros, ms.rating_caballeros)
               END::numeric AS course_rating,
               CASE hs.player_sex
                 WHEN 'F' THEN COALESCE(tto.slope_damas, ms.slope_damas)
                 ELSE COALESCE(tto.slope_caballeros, ms.slope_caballeros)
               END::integer AS slope_rating
    ) calc
    CROSS JOIN LATERAL (
        SELECT public.calcular_course_handicap_sin_redondear(
            hs.handicap_index,
            calc.slope_rating,
            calc.course_rating,
            rcs.course_par
        ) AS value
    ) ch
    WHERE rcs.freeze_id = v_freeze_id;

    GET DIAGNOSTICS v_round_handicap_count = ROW_COUNT;

    IF v_round_snapshot_count <> v_round_count
       OR v_hole_snapshot_count <> v_round_count * 18
       OR v_round_handicap_count <> v_round_count * v_participant_count THEN
        RAISE EXCEPTION 'El congelamiento quedó incompleto y fue revertido automáticamente.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'rondas=%s/%s, hoyos=%s/%s, handicaps_ronda=%s/%s',
                      v_round_snapshot_count, v_round_count,
                      v_hole_snapshot_count, v_round_count * 18,
                      v_round_handicap_count, v_round_count * v_participant_count
                  );
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'freezeId', v_freeze_id,
        'tournamentId', p_tournament_id,
        'frozenAt', now(),
        'counts', jsonb_build_object(
            'rounds', v_round_snapshot_count,
            'participants', v_participant_count,
            'holes', v_hole_snapshot_count,
            'roundPlayerHandicaps', v_round_handicap_count
        ),
        'warnings', COALESCE(v_preview->'warnings', '[]'::jsonb)
    );
END;
$$;

REVOKE ALL ON TABLE public.tournament_condition_freezes FROM anon, authenticated;
REVOKE ALL ON TABLE public.tournament_round_registration_tees FROM anon, authenticated;
REVOKE ALL ON TABLE public.tournament_round_condition_snapshots FROM anon, authenticated;
REVOKE ALL ON TABLE public.tournament_round_hole_snapshots FROM anon, authenticated;
REVOKE ALL ON TABLE public.tournament_handicap_snapshots FROM anon, authenticated;
REVOKE ALL ON TABLE public.tournament_round_handicap_snapshots FROM anon, authenticated;

GRANT SELECT ON TABLE public.tournament_condition_freezes TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
    ON TABLE public.tournament_round_registration_tees TO authenticated;
GRANT SELECT ON TABLE public.tournament_round_condition_snapshots TO authenticated;
GRANT SELECT ON TABLE public.tournament_round_hole_snapshots TO authenticated;
GRANT SELECT ON TABLE public.tournament_handicap_snapshots TO authenticated;
GRANT SELECT ON TABLE public.tournament_round_handicap_snapshots TO authenticated;

REVOKE ALL ON FUNCTION public.redondear_handicap_whs(numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.calcular_course_handicap_sin_redondear(numeric, integer, numeric, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.calcular_playing_handicap(numeric, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.puede_administrar_congelamiento_torneo(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.puede_ver_congelamiento_torneo(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.previsualizar_congelamiento_torneo(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_estado_congelamiento_torneo(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.congelar_condiciones_y_handicaps_torneo(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.impedir_mutacion_snapshot_torneo() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.validar_tee_inscripcion_ronda() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.bloquear_borrado_tee_inscripcion_ronda_congelado() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.redondear_handicap_whs(numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.calcular_course_handicap_sin_redondear(numeric, integer, numeric, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.calcular_playing_handicap(numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.puede_administrar_congelamiento_torneo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.puede_ver_congelamiento_torneo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.previsualizar_congelamiento_torneo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_estado_congelamiento_torneo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.congelar_condiciones_y_handicaps_torneo(uuid) TO authenticated;

COMMIT;
