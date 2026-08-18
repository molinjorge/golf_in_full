BEGIN;

-- ============================================================================
-- MIGRACIÓN 140
-- VALIDACIÓN, VERSIONADO Y CIERRE DE SALIDAS POR RONDA
--
-- NÚCLEO REUTILIZABLE:
-- - La validación pertenece a la ronda, no a una categoría/configuración.
-- - Los grupos validados son independientes del motor de resultados.
-- - Las unidades validadas admiten registration o team.
-- - El primer motor habilitado es Stroke Play individual + Shotgun.
-- - Motores futuros reutilizarán tablas, versionado, RLS, reapertura y locks.
--
-- ESTA MIGRACIÓN NO CREA:
-- - tarjetas, QR o PDF emitidos;
-- - resultados, sanciones ni clasificaciones;
-- - inicio/cierre deportivo de la ronda;
-- - cambio automático del torneo a en_curso.
-- ============================================================================

DO $$
DECLARE
    v_faltantes text;
BEGIN
    WITH requeridos(tipo, firma) AS (
        VALUES
            ('tabla', 'public.admin_users'),
            ('tabla', 'public.players'),
            ('tabla', 'public.tournaments'),
            ('tabla', 'public.tournament_rounds'),
            ('tabla', 'public.tournament_condition_freezes'),
            ('tabla', 'public.tournament_round_condition_snapshots'),
            ('tabla', 'public.tournament_handicap_snapshots'),
            ('tabla', 'public.tournament_round_handicap_snapshots'),
            ('tabla', 'public.tournament_round_hole_snapshots'),
            ('tabla', 'public.tournament_round_shifts'),
            ('tabla', 'public.tournament_round_shift_categories'),
            ('tabla', 'public.tournament_shotgun_category_configs'),
            ('tabla', 'public.tournament_shotgun_category_holes'),
            ('tabla', 'public.tournament_groups'),
            ('tabla', 'public.tournament_group_players'),
            ('tabla', 'public.tournament_group_teams'),
            ('función', 'public.puede_administrar_congelamiento_torneo(uuid)')
    )
    SELECT string_agg(tipo || ': ' || firma, E'\n' ORDER BY tipo, firma)
      INTO v_faltantes
      FROM requeridos
     WHERE (tipo = 'tabla' AND to_regclass(firma) IS NULL)
        OR (tipo = 'función' AND to_regprocedure(firma) IS NULL);

    IF v_faltantes IS NOT NULL THEN
        RAISE EXCEPTION
            'No puede ejecutarse la Migración 140. Faltan dependencias:%',
            E'\n' || v_faltantes
            USING ERRCODE = '55000';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. Registro versionado de validaciones por ronda.
-- ---------------------------------------------------------------------------

CREATE TABLE public.tournament_round_start_validations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,
    freeze_id uuid NOT NULL
        REFERENCES public.tournament_condition_freezes(id) ON DELETE RESTRICT,
    round_condition_snapshot_id uuid NOT NULL
        REFERENCES public.tournament_round_condition_snapshots(id) ON DELETE RESTRICT,
    version integer NOT NULL CHECK (version > 0),
    status text NOT NULL DEFAULT 'validated'
        CHECK (status IN ('validated', 'reopened')),
    validator_engine text NOT NULL,
    start_format text NOT NULL,
    participation_type text NOT NULL,
    scoring_engine text NOT NULL,
    config_count integer NOT NULL CHECK (config_count >= 0),
    group_count integer NOT NULL CHECK (group_count >= 0),
    unit_count integer NOT NULL CHECK (unit_count >= 0),
    validation_snapshot jsonb NOT NULL
        CHECK (jsonb_typeof(validation_snapshot) = 'object'),
    content_hash text NOT NULL CHECK (length(content_hash) = 32),
    validated_at timestamptz NOT NULL DEFAULT now(),
    validated_by uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    reopened_at timestamptz,
    reopened_by uuid
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    reopen_reason text,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_round_start_validations_round_version_uk
        UNIQUE (tournament_round_id, version),
    CONSTRAINT tournament_round_start_validations_tournament_round_consistency
        CHECK (tournament_id IS NOT NULL AND tournament_round_id IS NOT NULL),
    CONSTRAINT tournament_round_start_validations_reopen_consistency
        CHECK (
            (status = 'validated'
                AND reopened_at IS NULL
                AND reopened_by IS NULL
                AND reopen_reason IS NULL)
            OR
            (status = 'reopened'
                AND reopened_at IS NOT NULL
                AND reopened_by IS NOT NULL
                AND length(btrim(reopen_reason)) >= 5)
        )
);

CREATE UNIQUE INDEX tournament_round_start_validations_one_active_uk
    ON public.tournament_round_start_validations(tournament_round_id)
    WHERE status = 'validated';

CREATE INDEX idx_round_start_validations_tournament
    ON public.tournament_round_start_validations(tournament_id, tournament_round_id);

CREATE INDEX idx_round_start_validations_status
    ON public.tournament_round_start_validations(status, tournament_round_id);

-- ---------------------------------------------------------------------------
-- 2. Fotografía normalizada de grupos. Los identificadores source_* se
--    conservan como referencias históricas deliberadamente sin FK: una futura
--    reapertura puede desactivar/reemplazar objetos vivos sin borrar el pasado.
-- ---------------------------------------------------------------------------

CREATE TABLE public.tournament_round_start_validation_groups (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    validation_id uuid NOT NULL
        REFERENCES public.tournament_round_start_validations(id) ON DELETE RESTRICT,
    source_group_id uuid NOT NULL,
    source_config_id uuid NOT NULL,
    source_shift_id uuid NOT NULL,
    source_shift_category_id uuid NOT NULL,
    tournament_category_id uuid NOT NULL,
    category_name text NOT NULL,
    source_shotgun_hole_id uuid,
    source_hole_id uuid NOT NULL,
    hole_number integer NOT NULL CHECK (hole_number BETWEEN 1 AND 18),
    start_position text NOT NULL CHECK (start_position IN ('A', 'B')),
    start_at timestamptz NOT NULL,
    shift_number integer NOT NULL CHECK (shift_number > 0),
    shift_time time NOT NULL,
    group_label text,
    normal_size integer NOT NULL CHECK (normal_size > 0),
    maximum_size integer NOT NULL CHECK (maximum_size >= normal_size),
    unit_count integer NOT NULL CHECK (unit_count > 0),
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT round_start_validation_groups_source_group_uk
        UNIQUE (validation_id, source_group_id),
    CONSTRAINT round_start_validation_groups_position_uk
        UNIQUE (
            validation_id,
            source_config_id,
            source_shotgun_hole_id,
            start_position
        )
);

CREATE INDEX idx_round_start_validation_groups_validation
    ON public.tournament_round_start_validation_groups(validation_id, shift_number, hole_number);

-- ---------------------------------------------------------------------------
-- 3. Unidades genéricas. La primera implementación inserta registration;
--    team queda preparado para motores por equipos posteriores.
-- ---------------------------------------------------------------------------

CREATE TABLE public.tournament_round_start_validation_units (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    validation_id uuid NOT NULL
        REFERENCES public.tournament_round_start_validations(id) ON DELETE RESTRICT,
    validation_group_id uuid NOT NULL
        REFERENCES public.tournament_round_start_validation_groups(id) ON DELETE RESTRICT,
    unit_type text NOT NULL CHECK (unit_type IN ('registration', 'team')),
    tournament_registration_id uuid
        REFERENCES public.tournament_registrations(id) ON DELETE RESTRICT,
    tournament_team_id uuid
        REFERENCES public.tournament_teams(id) ON DELETE RESTRICT,
    player_id uuid
        REFERENCES public.players(id) ON DELETE RESTRICT,
    tournament_category_id uuid NOT NULL,
    unit_name text NOT NULL,
    unit_folio text,
    order_in_group smallint NOT NULL CHECK (order_in_group > 0),
    handicap_snapshot_id uuid
        REFERENCES public.tournament_handicap_snapshots(id) ON DELETE RESTRICT,
    round_handicap_snapshot_id uuid
        REFERENCES public.tournament_round_handicap_snapshots(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT round_start_validation_units_type_consistency
        CHECK (
            (
                unit_type = 'registration'
                AND tournament_registration_id IS NOT NULL
                AND tournament_team_id IS NULL
                AND player_id IS NOT NULL
                AND handicap_snapshot_id IS NOT NULL
                AND round_handicap_snapshot_id IS NOT NULL
            )
            OR
            (
                unit_type = 'team'
                AND tournament_registration_id IS NULL
                AND tournament_team_id IS NOT NULL
                AND player_id IS NULL
                AND handicap_snapshot_id IS NULL
                AND round_handicap_snapshot_id IS NULL
            )
        ),
    CONSTRAINT round_start_validation_units_group_order_uk
        UNIQUE (validation_group_id, order_in_group)
);

CREATE UNIQUE INDEX round_start_validation_units_registration_uk
    ON public.tournament_round_start_validation_units(
        validation_id,
        tournament_registration_id
    )
    WHERE unit_type = 'registration';

CREATE UNIQUE INDEX round_start_validation_units_team_uk
    ON public.tournament_round_start_validation_units(
        validation_id,
        tournament_team_id
    )
    WHERE unit_type = 'team';

CREATE INDEX idx_round_start_validation_units_validation
    ON public.tournament_round_start_validation_units(validation_id, validation_group_id);

-- ---------------------------------------------------------------------------
-- 4. RLS. Sin escritura directa: las mutaciones pasan por RPC.
-- ---------------------------------------------------------------------------

ALTER TABLE public.tournament_round_start_validations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_round_start_validation_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_round_start_validation_units ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tournament_round_start_validations_select
    ON public.tournament_round_start_validations;
CREATE POLICY tournament_round_start_validations_select
ON public.tournament_round_start_validations
FOR SELECT TO authenticated
USING (public.puede_administrar_congelamiento_torneo(tournament_id));

DROP POLICY IF EXISTS tournament_round_start_validation_groups_select
    ON public.tournament_round_start_validation_groups;
CREATE POLICY tournament_round_start_validation_groups_select
ON public.tournament_round_start_validation_groups
FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.tournament_round_start_validations v
        WHERE v.id = validation_id
          AND public.puede_administrar_congelamiento_torneo(v.tournament_id)
    )
);

DROP POLICY IF EXISTS tournament_round_start_validation_units_select
    ON public.tournament_round_start_validation_units;
CREATE POLICY tournament_round_start_validation_units_select
ON public.tournament_round_start_validation_units
FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.tournament_round_start_validations v
        WHERE v.id = validation_id
          AND public.puede_administrar_congelamiento_torneo(v.tournament_id)
    )
);

REVOKE ALL ON TABLE public.tournament_round_start_validations FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.tournament_round_start_validation_groups FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.tournament_round_start_validation_units FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE public.tournament_round_start_validations TO authenticated;
GRANT SELECT ON TABLE public.tournament_round_start_validation_groups TO authenticated;
GRANT SELECT ON TABLE public.tournament_round_start_validation_units TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Locks y resolución genérica de ronda para cualquier mutación de salida.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._bloquear_salida_ronda(
    p_tournament_round_id uuid
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF p_tournament_round_id IS NULL THEN
        RETURN;
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended('round-start:' || p_tournament_round_id::text, 0)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public._salida_ronda_esta_validada(
    p_tournament_round_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.tournament_round_start_validations v
        WHERE v.tournament_round_id = p_tournament_round_id
          AND v.status = 'validated'
    );
$$;

CREATE OR REPLACE FUNCTION public._resolver_ronda_fila_salida(
    p_table_name text,
    p_row jsonb
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id uuid;
BEGIN
    IF p_row IS NULL THEN
        RETURN NULL;
    END IF;

    CASE p_table_name
        WHEN 'tournament_round_shifts' THEN
            RETURN nullif(p_row->>'tournament_round_id', '')::uuid;

        WHEN 'tournament_round_shift_categories' THEN
            SELECT rs.tournament_round_id
              INTO v_id
              FROM public.tournament_round_shifts rs
             WHERE rs.id = nullif(p_row->>'tournament_round_shift_id', '')::uuid;
            RETURN v_id;

        WHEN 'tournament_shotgun_category_configs' THEN
            SELECT rs.tournament_round_id
              INTO v_id
              FROM public.tournament_round_shift_categories sc
              JOIN public.tournament_round_shifts rs
                ON rs.id = sc.tournament_round_shift_id
             WHERE sc.id = nullif(
                 p_row->>'tournament_round_shift_category_id', ''
             )::uuid;
            RETURN v_id;

        WHEN 'tournament_shotgun_category_holes' THEN
            SELECT rs.tournament_round_id
              INTO v_id
              FROM public.tournament_shotgun_category_configs cfg
              JOIN public.tournament_round_shift_categories sc
                ON sc.id = cfg.tournament_round_shift_category_id
              JOIN public.tournament_round_shifts rs
                ON rs.id = sc.tournament_round_shift_id
             WHERE cfg.id = nullif(
                 p_row->>'tournament_shotgun_category_config_id', ''
             )::uuid;
            RETURN v_id;

        WHEN 'tournament_groups' THEN
            SELECT rs.tournament_round_id
              INTO v_id
              FROM public.tournament_round_shifts rs
             WHERE rs.id = nullif(
                 p_row->>'tournament_round_shift_id', ''
             )::uuid;
            RETURN v_id;

        WHEN 'tournament_group_players' THEN
            SELECT rs.tournament_round_id
              INTO v_id
              FROM public.tournament_groups g
              JOIN public.tournament_round_shifts rs
                ON rs.id = g.tournament_round_shift_id
             WHERE g.id = nullif(p_row->>'tournament_group_id', '')::uuid;
            RETURN v_id;

        WHEN 'tournament_group_teams' THEN
            SELECT rs.tournament_round_id
              INTO v_id
              FROM public.tournament_groups g
              JOIN public.tournament_round_shifts rs
                ON rs.id = g.tournament_round_shift_id
             WHERE g.id = nullif(p_row->>'tournament_group_id', '')::uuid;
            RETURN v_id;

        ELSE
            RAISE EXCEPTION 'Tabla de salida no soportada: %.', p_table_name
                USING ERRCODE = '22023';
    END CASE;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Protección de la fotografía validada y sus filas normalizadas.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._proteger_validacion_salida_ronda()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'Las validaciones de salida son históricas y no pueden eliminarse.'
            USING ERRCODE = '55000';
    END IF;

    IF current_setting(
        'app.reabrir_validacion_salida_ronda', true
    ) IS DISTINCT FROM 'true' THEN
        RAISE EXCEPTION
            'Una validación de salida sólo puede reabrirse mediante la RPC autorizada.'
            USING ERRCODE = '55000';
    END IF;

    IF OLD.status IS DISTINCT FROM 'validated'
       OR NEW.status IS DISTINCT FROM 'reopened'
       OR (
            to_jsonb(NEW)
            - ARRAY['status', 'reopened_at', 'reopened_by', 'reopen_reason']
          ) IS DISTINCT FROM (
            to_jsonb(OLD)
            - ARRAY['status', 'reopened_at', 'reopened_by', 'reopen_reason']
          )
    THEN
        RAISE EXCEPTION
            'La fotografía validada es inmutable; sólo se permite marcarla como reabierta.'
            USING ERRCODE = '55000';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_proteger_validacion_salida_ronda
    ON public.tournament_round_start_validations;
CREATE TRIGGER trg_proteger_validacion_salida_ronda
BEFORE UPDATE OR DELETE ON public.tournament_round_start_validations
FOR EACH ROW
EXECUTE FUNCTION public._proteger_validacion_salida_ronda();

CREATE OR REPLACE FUNCTION public._impedir_mutacion_detalle_validacion_salida()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION
        'Los grupos y unidades de una validación de salida son inmutables.'
        USING ERRCODE = '55000';
END;
$$;

DROP TRIGGER IF EXISTS trg_impedir_mutacion_validation_groups
    ON public.tournament_round_start_validation_groups;
CREATE TRIGGER trg_impedir_mutacion_validation_groups
BEFORE UPDATE OR DELETE ON public.tournament_round_start_validation_groups
FOR EACH ROW
EXECUTE FUNCTION public._impedir_mutacion_detalle_validacion_salida();

DROP TRIGGER IF EXISTS trg_impedir_mutacion_validation_units
    ON public.tournament_round_start_validation_units;
CREATE TRIGGER trg_impedir_mutacion_validation_units
BEFORE UPDATE OR DELETE ON public.tournament_round_start_validation_units
FOR EACH ROW
EXECUTE FUNCTION public._impedir_mutacion_detalle_validacion_salida();

-- ---------------------------------------------------------------------------
-- 7. Trigger común: todas las rutas directas y todas las RPC existentes quedan
--    serializadas contra la validación mediante el mismo advisory lock.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._proteger_objeto_salida_ronda_validada()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_old_round_id uuid;
    v_new_round_id uuid;
    v_round_id uuid;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old_round_id := public._resolver_ronda_fila_salida(
            TG_TABLE_NAME,
            to_jsonb(OLD)
        );
    END IF;

    IF TG_OP <> 'DELETE' THEN
        v_new_round_id := public._resolver_ronda_fila_salida(
            TG_TABLE_NAME,
            to_jsonb(NEW)
        );
    END IF;

    FOR v_round_id IN
        SELECT DISTINCT x.round_id
        FROM unnest(ARRAY[v_old_round_id, v_new_round_id]) AS x(round_id)
        WHERE x.round_id IS NOT NULL
        ORDER BY x.round_id
    LOOP
        PERFORM public._bloquear_salida_ronda(v_round_id);

        IF public._salida_ronda_esta_validada(v_round_id) THEN
            RAISE EXCEPTION
                'Las salidas de la ronda están validadas y no pueden modificarse.'
                USING ERRCODE = '55000',
                      HINT = 'Reabra primero las salidas de la ronda, indicando un motivo, y vuelva a validarlas después de los cambios.';
        END IF;
    END LOOP;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

DO $$
DECLARE
    v_table text;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'tournament_round_shifts',
        'tournament_round_shift_categories',
        'tournament_shotgun_category_configs',
        'tournament_shotgun_category_holes',
        'tournament_groups',
        'tournament_group_players',
        'tournament_group_teams'
    ]
    LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trg_proteger_cierre_salidas_ronda ON public.%I',
            v_table
        );
        EXECUTE format(
            'CREATE TRIGGER trg_proteger_cierre_salidas_ronda '
            'BEFORE INSERT OR UPDATE OR DELETE ON public.%I '
            'FOR EACH ROW EXECUTE FUNCTION public._proteger_objeto_salida_ronda_validada()',
            v_table
        );
    END LOOP;
END;
$$;

-- Una baja o reactivación cambia el universo competitivo de cualquier ronda
-- validada donde la inscripción tenga snapshot. Debe reabrirse primero.
CREATE OR REPLACE FUNCTION public._proteger_estado_inscripcion_salida_validada()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_round_id uuid;
BEGIN
    IF NEW.activo IS NOT DISTINCT FROM OLD.activo THEN
        RETURN NEW;
    END IF;

    FOR v_round_id IN
        SELECT DISTINCT rhs.tournament_round_id
        FROM public.tournament_round_handicap_snapshots rhs
        WHERE rhs.tournament_registration_id = OLD.id
        ORDER BY rhs.tournament_round_id
    LOOP
        PERFORM public._bloquear_salida_ronda(v_round_id);

        IF public._salida_ronda_esta_validada(v_round_id) THEN
            RAISE EXCEPTION
                'No puede retirarse ni reactivarse esta inscripción mientras tenga una salida de ronda validada.'
                USING ERRCODE = '55000',
                      HINT = 'Reabra las salidas afectadas, realice la baja o reactivación y vuelva a validarlas.';
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_proteger_estado_inscripcion_salida_validada
    ON public.tournament_registrations;
CREATE TRIGGER trg_proteger_estado_inscripcion_salida_validada
BEFORE UPDATE OF activo ON public.tournament_registrations
FOR EACH ROW
EXECUTE FUNCTION public._proteger_estado_inscripcion_salida_validada();

-- ---------------------------------------------------------------------------
-- 8. Previsualización. La respuesta mantiene un contrato común para futuros
--    motores; el despachador habilita inicialmente stroke_individual_shotgun_v1.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.previsualizar_validacion_salidas_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_ctx record;
    v_errors jsonb := '[]'::jsonb;
    v_warnings jsonb := '[]'::jsonb;
    v_n integer;
    v_config_count integer := 0;
    v_group_count integer := 0;
    v_unit_count integer := 0;
    v_eligible_count integer := 0;
    v_existing record;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    SELECT tr.id AS round_id,
           tr.tournament_id,
           tr.numero_ronda,
           tr.fecha,
           tr.activo AS round_active,
           tr.formato_salida::text AS live_start_format,
           t.nombre AS tournament_name,
           t.estatus::text AS tournament_status,
           f.id AS freeze_id,
           f.warnings_snapshot AS freeze_warnings,
           rcs.id AS round_condition_snapshot_id,
           rcs.format_code,
           rcs.format_name,
           rcs.participation_type,
           rcs.scoring_engine,
           rcs.tournament_format_id AS frozen_format_id,
           COALESCE(tr.tournament_format_id, t.tournament_format_id) AS live_format_id
      INTO v_ctx
      FROM public.tournament_rounds tr
      JOIN public.tournaments t ON t.id = tr.tournament_id
      LEFT JOIN public.tournament_condition_freezes f
        ON f.tournament_id = tr.tournament_id
      LEFT JOIN public.tournament_round_condition_snapshots rcs
        ON rcs.freeze_id = f.id
       AND rcs.tournament_round_id = tr.id
     WHERE tr.id = p_tournament_round_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La ronda indicada no existe.' USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_ctx.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para validar las salidas de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    SELECT v.id, v.version, v.validated_at, v.validated_by,
           v.content_hash, v.validator_engine
      INTO v_existing
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_round_id = p_tournament_round_id
       AND v.status = 'validated';

    IF NOT v_ctx.round_active THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'ronda_inactiva',
            'message', 'La ronda está inactiva y no puede validarse.'
        ));
    END IF;

    IF v_ctx.freeze_id IS NULL THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'torneo_no_congelado',
            'message', 'Las condiciones y hándicaps del torneo deben congelarse antes de validar salidas.'
        ));
    ELSIF v_ctx.round_condition_snapshot_id IS NULL THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'ronda_sin_snapshot',
            'message', 'La ronda no forma parte de las condiciones congeladas del torneo.'
        ));
    END IF;

    IF COALESCE(v_ctx.live_start_format, '') <> 'shotgun' THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'ronda_no_shotgun',
            'message', 'El primer validador habilitado requiere salida Shotgun.'
        ));
    END IF;

    IF COALESCE(v_ctx.participation_type, '') <> 'individual'
       OR COALESCE(v_ctx.scoring_engine, '') <> 'stroke' THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'modalidad_no_soportada',
            'message', 'Esta versión valida únicamente Stroke Play individual con salida Shotgun.',
            'detail', jsonb_build_object(
                'participationType', v_ctx.participation_type,
                'scoringEngine', v_ctx.scoring_engine
            )
        ));
    END IF;

    IF v_ctx.frozen_format_id IS DISTINCT FROM v_ctx.live_format_id THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'formato_distinto_del_congelado',
            'message', 'El formato efectivo vivo de la ronda no coincide con el formato congelado.'
        ));
    END IF;

    IF v_ctx.tournament_status NOT IN ('inscripcion_cerrada', 'en_curso') THEN
        v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
            'code', 'estatus_torneo_no_operativo',
            'message', format(
                'El torneo tiene estatus %s; normalmente las salidas se validan con inscripciones cerradas.',
                v_ctx.tournament_status
            )
        ));
    END IF;

    IF jsonb_array_length(COALESCE(v_ctx.freeze_warnings, '[]'::jsonb)) > 0 THEN
        v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
            'code', 'congelamiento_con_advertencias',
            'message', 'El congelamiento del torneo contiene advertencias que deben revisarse.',
            'detail', v_ctx.freeze_warnings
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_round_hole_snapshots rhs
     WHERE rhs.tournament_round_id = p_tournament_round_id;
    IF v_ctx.freeze_id IS NOT NULL AND v_n <> 18 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'snapshot_hoyos_incompleto',
            'message', format('La ronda tiene %s hoyos congelados; se requieren 18.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_config_count
      FROM public.tournament_shotgun_category_configs cfg
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = sc.tournament_round_shift_id AND rs.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND cfg.activo;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_round_shifts rs
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND rs.activo;
    IF v_n = 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'sin_turnos_activos',
            'message', 'La ronda no tiene turnos activos.'
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_round_shift_categories sc
      JOIN public.tournament_round_shifts rs
        ON rs.id = sc.tournament_round_shift_id AND rs.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND sc.activo
       AND NOT EXISTS (
           SELECT 1
           FROM public.tournament_shotgun_category_configs cfg
           WHERE cfg.tournament_round_shift_category_id = sc.id
             AND cfg.activo
       );
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'categoria_turno_sin_configuracion',
            'message', format('%s asignación(es) de categoría a turno no tienen configuración Shotgun activa.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_shotgun_category_configs cfg
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = sc.tournament_round_shift_id AND rs.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND cfg.activo
       AND NOT EXISTS (
           SELECT 1
           FROM public.tournament_shotgun_category_holes sh
           WHERE sh.tournament_shotgun_category_config_id = cfg.id
             AND sh.activo
       );
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'configuracion_sin_hoyos',
            'message', format('%s configuración(es) Shotgun activas no tienen hoyos habilitados.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_eligible_count
      FROM public.tournament_round_handicap_snapshots rhs
      JOIN public.tournament_registrations reg
        ON reg.id = rhs.tournament_registration_id AND reg.activo
     WHERE rhs.tournament_round_id = p_tournament_round_id;
    IF v_eligible_count = 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'sin_participantes_elegibles',
            'message', 'La ronda no tiene participantes activos con hándicap congelado.'
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM (
          SELECT hs.tournament_registration_id
          FROM public.tournament_handicap_snapshots hs
          JOIN public.tournament_round_handicap_snapshots rhs
            ON rhs.handicap_snapshot_id = hs.id
           AND rhs.tournament_round_id = p_tournament_round_id
          JOIN public.tournament_registrations reg
            ON reg.id = hs.tournament_registration_id AND reg.activo
          LEFT JOIN public.tournament_round_shift_categories sc
            ON sc.tournament_category_id = hs.tournament_category_id AND sc.activo
          LEFT JOIN public.tournament_round_shifts rs
            ON rs.id = sc.tournament_round_shift_id
           AND rs.tournament_round_id = p_tournament_round_id
           AND rs.activo
          GROUP BY hs.tournament_registration_id
          HAVING count(rs.id) <> 1
      ) x;
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'participante_sin_turno_unico',
            'message', format('%s participante(s) no pertenecen exactamente a un turno activo de su categoría.', v_n)
        ));
    END IF;

    WITH assigned AS (
        SELECT gp.tournament_registration_id, count(*) AS n
        FROM public.tournament_group_players gp
        JOIN public.tournament_groups g ON g.id = gp.tournament_group_id AND g.activo
        JOIN public.tournament_round_shifts rs
          ON rs.id = g.tournament_round_shift_id AND rs.activo
        JOIN public.tournament_shotgun_category_holes sh
          ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
        JOIN public.tournament_shotgun_category_configs cfg
          ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
        JOIN public.tournament_round_shift_categories sc
          ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
        WHERE rs.tournament_round_id = p_tournament_round_id
        GROUP BY gp.tournament_registration_id
    ), eligible AS (
        SELECT rhs.tournament_registration_id
        FROM public.tournament_round_handicap_snapshots rhs
        JOIN public.tournament_registrations reg
          ON reg.id = rhs.tournament_registration_id AND reg.activo
        WHERE rhs.tournament_round_id = p_tournament_round_id
    )
    SELECT count(*)
      INTO v_n
      FROM eligible e
      LEFT JOIN assigned a ON a.tournament_registration_id = e.tournament_registration_id
     WHERE COALESCE(a.n, 0) <> 1;
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'participante_sin_grupo_unico',
            'message', format('%s participante(s) elegibles no están asignados exactamente una vez.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_group_players gp
      JOIN public.tournament_groups g ON g.id = gp.tournament_group_id AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id AND rs.activo
      LEFT JOIN public.tournament_registrations reg
        ON reg.id = gp.tournament_registration_id
      LEFT JOIN public.tournament_round_handicap_snapshots rhs
        ON rhs.tournament_round_id = p_tournament_round_id
       AND rhs.tournament_registration_id = gp.tournament_registration_id
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND (reg.id IS NULL OR NOT COALESCE(reg.activo, false) OR rhs.id IS NULL);
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'asignacion_no_elegible',
            'message', format('%s asignación(es) corresponden a inscripciones inactivas, inexistentes o sin snapshot de ronda.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_group_teams gt
      JOIN public.tournament_groups g
        ON g.id = gt.tournament_group_id AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id AND rs.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND gt.activo;
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'unidades_equipo_en_modalidad_individual',
            'message', format('%s asignación(es) de equipo existen en una modalidad individual.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_group_players gp
      JOIN public.tournament_groups g ON g.id = gp.tournament_group_id AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id AND rs.activo
      JOIN public.tournament_shotgun_category_holes sh
        ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
      JOIN public.tournament_shotgun_category_configs cfg
        ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
      JOIN public.tournament_handicap_snapshots hs
        ON hs.tournament_registration_id = gp.tournament_registration_id
       AND hs.freeze_id = v_ctx.freeze_id
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND hs.tournament_category_id IS DISTINCT FROM sc.tournament_category_id;
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'categoria_asignada_incorrecta',
            'message', format('%s participante(s) están en un grupo de otra categoría.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_group_count
      FROM public.tournament_groups g
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id AND rs.activo
      JOIN public.tournament_shotgun_category_holes sh
        ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
      JOIN public.tournament_shotgun_category_configs cfg
        ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND g.activo;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_groups g
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id AND rs.activo
      LEFT JOIN public.tournament_shotgun_category_holes sh
        ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
      LEFT JOIN public.tournament_shotgun_category_configs cfg
        ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
      LEFT JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND g.activo
       AND (
           sh.id IS NULL
           OR cfg.id IS NULL
           OR sc.id IS NULL
           OR sc.tournament_round_shift_id IS DISTINCT FROM rs.id
       );
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'grupo_fuera_de_configuracion_activa',
            'message', format('%s grupo(s) activos no pertenecen a una cadena Shotgun activa y consistente.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_groups g
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id AND rs.activo
      JOIN public.tournament_shotgun_category_holes sh
        ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
      JOIN public.tournament_shotgun_category_configs cfg
        ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND g.activo
       AND NOT EXISTS (
           SELECT 1 FROM public.tournament_group_players gp
           WHERE gp.tournament_group_id = g.id
       );
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'grupo_vacio',
            'message', format('%s grupo(s) activos no contienen participantes.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM (
          SELECT g.id
          FROM public.tournament_groups g
          JOIN public.tournament_round_shifts rs
            ON rs.id = g.tournament_round_shift_id AND rs.activo
          JOIN public.tournament_shotgun_category_holes sh
            ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
          JOIN public.tournament_shotgun_category_configs cfg
            ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
          JOIN public.tournament_round_shift_categories sc
            ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
          LEFT JOIN public.tournament_group_players gp
            ON gp.tournament_group_id = g.id
          WHERE rs.tournament_round_id = p_tournament_round_id AND g.activo
          GROUP BY g.id, cfg.tamano_grupo_maximo
          HAVING count(gp.id) > cfg.tamano_grupo_maximo
      ) x;
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'grupo_excede_maximo',
            'message', format('%s grupo(s) exceden el tamaño máximo configurado.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM (
          SELECT cfg.id, sh.id, g.posicion_salida
          FROM public.tournament_groups g
          JOIN public.tournament_round_shifts rs
            ON rs.id = g.tournament_round_shift_id AND rs.activo
          JOIN public.tournament_shotgun_category_holes sh
            ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
          JOIN public.tournament_shotgun_category_configs cfg
            ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
          JOIN public.tournament_round_shift_categories sc
            ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
          WHERE rs.tournament_round_id = p_tournament_round_id AND g.activo
          GROUP BY cfg.id, sh.id, g.posicion_salida
          HAVING count(*) > 1
      ) x;
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'posicion_salida_duplicada',
            'message', format('%s posición(es) físicas de salida están ocupadas por más de un grupo.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_groups g
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id AND rs.activo
      JOIN public.tournament_shotgun_category_holes sh
        ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
      JOIN public.tournament_shotgun_category_configs cfg
        ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND g.activo
       AND (
           g.hoyo_id IS DISTINCT FROM sh.hoyo_id
           OR g.tournament_round_shift_id IS DISTINCT FROM sc.tournament_round_shift_id
           OR g.posicion_salida IS NULL
           OR g.posicion_salida NOT IN ('A', 'B')
           OR (g.posicion_salida = 'B' AND NOT sh.salida_doble)
           OR g.hora_salida IS NULL
       );
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'grupo_salida_inconsistente',
            'message', format('%s grupo(s) tienen hoyo, turno, posición u hora inconsistentes.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM (
          SELECT gp.tournament_group_id
          FROM public.tournament_group_players gp
          JOIN public.tournament_groups g ON g.id = gp.tournament_group_id AND g.activo
          JOIN public.tournament_round_shifts rs
            ON rs.id = g.tournament_round_shift_id AND rs.activo
          WHERE rs.tournament_round_id = p_tournament_round_id
          GROUP BY gp.tournament_group_id
          HAVING bool_or(gp.orden_en_grupo IS NULL)
             OR count(*) <> count(DISTINCT gp.orden_en_grupo)
      ) x;
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'orden_grupo_invalido',
            'message', format('%s grupo(s) tienen posiciones de participante nulas o duplicadas.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_unit_count
      FROM public.tournament_group_players gp
      JOIN public.tournament_groups g ON g.id = gp.tournament_group_id AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id = g.tournament_round_shift_id AND rs.activo
      JOIN public.tournament_shotgun_category_holes sh
        ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
      JOIN public.tournament_shotgun_category_configs cfg
        ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
     WHERE rs.tournament_round_id = p_tournament_round_id
       AND sc.tournament_round_shift_id = rs.id;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_round_handicap_snapshots rhs
      JOIN public.tournament_registrations reg
        ON reg.id = rhs.tournament_registration_id AND reg.activo
      JOIN public.tournament_round_hole_snapshots hole
        ON hole.tournament_round_id = rhs.tournament_round_id
     WHERE rhs.tournament_round_id = p_tournament_round_id
       AND (
           NOT (hole.tee_distances_yards ? rhs.tee_id::text)
           OR hole.tee_distances_yards->rhs.tee_id::text = 'null'::jsonb
       );
    IF v_n > 0 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'code', 'distancia_congelada_faltante',
            'message', format('%s combinación(es) participante-hoyo no tienen distancia congelada.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM public.tournament_handicap_snapshots hs
     WHERE hs.freeze_id = v_ctx.freeze_id
       AND EXISTS (
           SELECT 1
           FROM public.tournament_round_handicap_snapshots rhs
           WHERE rhs.handicap_snapshot_id = hs.id
             AND rhs.tournament_round_id = p_tournament_round_id
       )
       AND NOT EXISTS (
           SELECT 1
           FROM public.tournament_registrations reg
           WHERE reg.id = hs.tournament_registration_id AND reg.activo
       );
    IF v_n > 0 THEN
        v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
            'code', 'inscripciones_retiradas_excluidas',
            'message', format('%s inscripción(es) congeladas están retiradas y se excluyen de la salida.', v_n)
        ));
    END IF;

    SELECT count(*)
      INTO v_n
      FROM (
          SELECT g.id
          FROM public.tournament_groups g
          JOIN public.tournament_round_shifts rs
            ON rs.id = g.tournament_round_shift_id AND rs.activo
          JOIN public.tournament_shotgun_category_holes sh
            ON sh.id = g.tournament_shotgun_category_hole_id AND sh.activo
          JOIN public.tournament_shotgun_category_configs cfg
            ON cfg.id = sh.tournament_shotgun_category_config_id AND cfg.activo
          JOIN public.tournament_round_shift_categories sc
            ON sc.id = cfg.tournament_round_shift_category_id AND sc.activo
          LEFT JOIN public.tournament_group_players gp ON gp.tournament_group_id = g.id
          WHERE rs.tournament_round_id = p_tournament_round_id AND g.activo
          GROUP BY g.id, cfg.tamano_grupo_normal
          HAVING count(gp.id) > 0 AND count(gp.id) < cfg.tamano_grupo_normal
      ) x;
    IF v_n > 0 THEN
        v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
            'code', 'grupos_incompletos',
            'message', format('%s grupo(s) están por debajo del tamaño normal configurado.', v_n)
        ));
    END IF;

    RETURN jsonb_build_object(
        'schemaVersion', 1,
        'validatorEngine', 'stroke_individual_shotgun_v1',
        'generatedAt', now(),
        'ready', jsonb_array_length(v_errors) = 0,
        'alreadyValidated', v_existing.id IS NOT NULL,
        'tournament', jsonb_build_object(
            'id', v_ctx.tournament_id,
            'name', v_ctx.tournament_name,
            'status', v_ctx.tournament_status
        ),
        'round', jsonb_build_object(
            'id', v_ctx.round_id,
            'number', v_ctx.numero_ronda,
            'date', v_ctx.fecha,
            'startFormat', v_ctx.live_start_format
        ),
        'format', jsonb_build_object(
            'code', v_ctx.format_code,
            'name', v_ctx.format_name,
            'participationType', v_ctx.participation_type,
            'scoringEngine', v_ctx.scoring_engine
        ),
        'currentValidation', CASE WHEN v_existing.id IS NULL THEN NULL ELSE
            jsonb_build_object(
                'id', v_existing.id,
                'version', v_existing.version,
                'validatedAt', v_existing.validated_at,
                'contentHash', v_existing.content_hash,
                'validatorEngine', v_existing.validator_engine
            ) END,
        'counts', jsonb_build_object(
            'configs', v_config_count,
            'groups', v_group_count,
            'eligibleUnits', v_eligible_count,
            'assignedUnits', v_unit_count,
            'errors', jsonb_array_length(v_errors),
            'warnings', jsonb_array_length(v_warnings)
        ),
        'errors', v_errors,
        'warnings', v_warnings
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- 9. Constructor interno de la fotografía canónica. Sólo se invoca después
--    de que la previsualización resulte lista y bajo el lock de la ronda.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._construir_fotografia_salida_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    WITH ctx AS (
        SELECT tr.id AS round_id,
               tr.tournament_id,
               f.id AS freeze_id,
               rcs.id AS round_condition_snapshot_id,
               tr.numero_ronda,
               tr.fecha,
               tr.formato_salida::text AS start_format,
               rcs.format_code,
               rcs.format_name,
               rcs.participation_type,
               rcs.scoring_engine
        FROM public.tournament_rounds tr
        JOIN public.tournament_condition_freezes f
          ON f.tournament_id = tr.tournament_id
        JOIN public.tournament_round_condition_snapshots rcs
          ON rcs.freeze_id = f.id AND rcs.tournament_round_id = tr.id
        WHERE tr.id = p_tournament_round_id
    ), group_rows AS (
        SELECT g.id AS group_id,
               cfg.id AS config_id,
               rs.id AS shift_id,
               sc.id AS shift_category_id,
               sc.tournament_category_id,
               sh.id AS shotgun_hole_id,
               sh.hoyo_id,
               hole.hole_number,
               g.posicion_salida,
               g.hora_salida,
               rs.numero_turno,
               rs.hora_salida AS shift_time,
               g.etiqueta,
               cfg.tamano_grupo_normal,
               cfg.tamano_grupo_maximo
        FROM ctx
        JOIN public.tournament_round_shifts rs
          ON rs.tournament_round_id = ctx.round_id AND rs.activo
        JOIN public.tournament_round_shift_categories sc
          ON sc.tournament_round_shift_id = rs.id AND sc.activo
        JOIN public.tournament_shotgun_category_configs cfg
          ON cfg.tournament_round_shift_category_id = sc.id AND cfg.activo
        JOIN public.tournament_shotgun_category_holes sh
          ON sh.tournament_shotgun_category_config_id = cfg.id AND sh.activo
        JOIN public.tournament_groups g
          ON g.tournament_shotgun_category_hole_id = sh.id
         AND g.tournament_round_shift_id = rs.id
         AND g.activo
        JOIN public.tournament_round_hole_snapshots hole
          ON hole.tournament_round_id = ctx.round_id
         AND hole.source_hole_id = sh.hoyo_id
    ), unit_rows AS (
        SELECT gr.*,
               gp.tournament_registration_id AS registration_id,
               gp.orden_en_grupo,
               hs.id AS handicap_snapshot_id,
               rhs.id AS round_handicap_snapshot_id,
               hs.player_id,
               hs.player_name,
               hs.registration_folio,
               hs.category_name,
               hs.tee_id AS registration_tee_id,
               rhs.tee_id,
               hs.handicap_index,
               rhs.course_handicap,
               rhs.playing_handicap
        FROM group_rows gr
        JOIN public.tournament_group_players gp
          ON gp.tournament_group_id = gr.group_id
        JOIN public.tournament_round_handicap_snapshots rhs
          ON rhs.tournament_round_id = p_tournament_round_id
         AND rhs.tournament_registration_id = gp.tournament_registration_id
        JOIN public.tournament_handicap_snapshots hs
          ON hs.id = rhs.handicap_snapshot_id
        JOIN public.tournament_registrations reg
          ON reg.id = gp.tournament_registration_id AND reg.activo
    ), groups_json AS (
        SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
                'sourceGroupId', gr.group_id,
                'sourceConfigId', gr.config_id,
                'sourceShiftId', gr.shift_id,
                'sourceShiftCategoryId', gr.shift_category_id,
                'tournamentCategoryId', gr.tournament_category_id,
                'categoryName', (
                    SELECT min(u.category_name)
                    FROM unit_rows u WHERE u.group_id = gr.group_id
                ),
                'sourceShotgunHoleId', gr.shotgun_hole_id,
                'sourceHoleId', gr.hoyo_id,
                'holeNumber', gr.hole_number,
                'startPosition', gr.posicion_salida,
                'startAt', gr.hora_salida,
                'shiftNumber', gr.numero_turno,
                'shiftTime', gr.shift_time,
                'groupLabel', gr.etiqueta,
                'normalSize', gr.tamano_grupo_normal,
                'maximumSize', gr.tamano_grupo_maximo,
                'units', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        'unitType', 'registration',
                        'registrationId', u.registration_id,
                        'playerId', u.player_id,
                        'name', u.player_name,
                        'folio', u.registration_folio,
                        'orderInGroup', u.orden_en_grupo,
                        'handicapSnapshotId', u.handicap_snapshot_id,
                        'roundHandicapSnapshotId', u.round_handicap_snapshot_id,
                        'teeId', u.tee_id,
                        'handicapIndex', u.handicap_index,
                        'courseHandicap', u.course_handicap,
                        'playingHandicap', u.playing_handicap
                    ) ORDER BY u.orden_en_grupo, u.registration_id)
                    FROM unit_rows u WHERE u.group_id = gr.group_id
                ), '[]'::jsonb)
            ) ORDER BY gr.numero_turno, gr.hole_number,
                       gr.posicion_salida, gr.group_id
        ), '[]'::jsonb) AS data
        FROM group_rows gr
    )
    SELECT jsonb_build_object(
        'schemaVersion', 1,
        'validatorEngine', 'stroke_individual_shotgun_v1',
        'freezeId', ctx.freeze_id,
        'roundConditionSnapshotId', ctx.round_condition_snapshot_id,
        'tournament', jsonb_build_object('id', ctx.tournament_id),
        'round', jsonb_build_object(
            'id', ctx.round_id,
            'number', ctx.numero_ronda,
            'date', ctx.fecha,
            'startFormat', ctx.start_format
        ),
        'format', jsonb_build_object(
            'code', ctx.format_code,
            'name', ctx.format_name,
            'participationType', ctx.participation_type,
            'scoringEngine', ctx.scoring_engine
        ),
        'groups', gj.data
    )
    FROM ctx
    CROSS JOIN groups_json gj;
$$;

-- ---------------------------------------------------------------------------
-- 10. Estado, validación y reapertura.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_estado_validacion_salidas_ronda(
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
    v_result jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    SELECT tournament_id INTO v_tournament_id
    FROM public.tournament_rounds
    WHERE id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.' USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar el cierre de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    SELECT jsonb_build_object(
        'tournamentRoundId', p_tournament_round_id,
        'validated', COALESCE(bool_or(v.status = 'validated'), false),
        'active', COALESCE((
            jsonb_agg(jsonb_build_object(
                'id', v.id,
                'version', v.version,
                'status', v.status,
                'validatorEngine', v.validator_engine,
                'validatedAt', v.validated_at,
                'contentHash', v.content_hash,
                'counts', jsonb_build_object(
                    'configs', v.config_count,
                    'groups', v.group_count,
                    'units', v.unit_count
                )
            ) ORDER BY v.version DESC) FILTER (WHERE v.status = 'validated')
        )->0, 'null'::jsonb),
        'latestVersion', COALESCE(max(v.version), 0),
        'historyCount', count(v.id)
    )
    INTO v_result
    FROM public.tournament_round_start_validations v
    WHERE v.tournament_round_id = p_tournament_round_id;

    RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.validar_salidas_ronda(
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
    v_admin_id uuid;
    v_preview jsonb;
    v_snapshot jsonb;
    v_validation_id uuid;
    v_version integer;
    v_config_count integer;
    v_group_count integer;
    v_unit_count integer;
    v_inserted_groups integer;
    v_inserted_units integer;
    v_existing uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    SELECT tournament_id INTO v_tournament_id
    FROM public.tournament_rounds
    WHERE id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.' USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para validar las salidas de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(p_tournament_round_id);

    SELECT id INTO v_existing
    FROM public.tournament_round_start_validations
    WHERE tournament_round_id = p_tournament_round_id
      AND status = 'validated';

    IF v_existing IS NOT NULL THEN
        RETURN public.obtener_estado_validacion_salidas_ronda(p_tournament_round_id);
    END IF;

    v_preview := public.previsualizar_validacion_salidas_ronda(p_tournament_round_id);
    IF NOT COALESCE((v_preview->>'ready')::boolean, false) THEN
        RAISE EXCEPTION 'Las salidas de la ronda no están listas para validarse.'
            USING ERRCODE = '23514',
                  DETAIL = (v_preview->'errors')::text,
                  HINT = 'Corrige los errores indicados y vuelve a revisar las salidas.';
    END IF;

    SELECT au.id INTO v_admin_id
    FROM public.admin_users au
    WHERE au.auth_user_id = auth.uid() AND au.activo
    ORDER BY au.id
    LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    v_snapshot := public._construir_fotografia_salida_ronda(p_tournament_round_id);
    IF v_snapshot IS NULL THEN
        RAISE EXCEPTION 'No fue posible construir la fotografía de salidas.'
            USING ERRCODE = '55000';
    END IF;

    -- Conserva también las advertencias aceptadas en esa versión. No se agrega
    -- generatedAt para que el mismo contenido produzca siempre el mismo hash.
    v_snapshot := v_snapshot || jsonb_build_object(
        'warnings', COALESCE(v_preview->'warnings', '[]'::jsonb)
    );

    SELECT count(DISTINCT (g->>'sourceConfigId')::uuid),
           count(*),
           COALESCE(sum(jsonb_array_length(g->'units')), 0)::integer
      INTO v_config_count, v_group_count, v_unit_count
      FROM jsonb_array_elements(v_snapshot->'groups') AS x(g);

    SELECT COALESCE(max(version), 0) + 1
      INTO v_version
      FROM public.tournament_round_start_validations
     WHERE tournament_round_id = p_tournament_round_id;

    INSERT INTO public.tournament_round_start_validations (
        tournament_id, tournament_round_id,
        freeze_id, round_condition_snapshot_id,
        version, status,
        validator_engine, start_format, participation_type, scoring_engine,
        config_count, group_count, unit_count,
        validation_snapshot, content_hash, validated_by
    ) VALUES (
        v_tournament_id,
        p_tournament_round_id,
        (v_snapshot->>'freezeId')::uuid,
        (v_snapshot->>'roundConditionSnapshotId')::uuid,
        v_version,
        'validated',
        v_snapshot->>'validatorEngine',
        v_snapshot #>> '{round,startFormat}',
        v_snapshot #>> '{format,participationType}',
        v_snapshot #>> '{format,scoringEngine}',
        v_config_count,
        v_group_count,
        v_unit_count,
        v_snapshot,
        md5(v_snapshot::text),
        v_admin_id
    ) RETURNING id INTO v_validation_id;

    INSERT INTO public.tournament_round_start_validation_groups (
        validation_id, source_group_id, source_config_id,
        source_shift_id, source_shift_category_id,
        tournament_category_id, category_name,
        source_shotgun_hole_id, source_hole_id, hole_number,
        start_position, start_at, shift_number, shift_time,
        group_label, normal_size, maximum_size, unit_count
    )
    SELECT v_validation_id,
           (g->>'sourceGroupId')::uuid,
           (g->>'sourceConfigId')::uuid,
           (g->>'sourceShiftId')::uuid,
           (g->>'sourceShiftCategoryId')::uuid,
           (g->>'tournamentCategoryId')::uuid,
           g->>'categoryName',
           (g->>'sourceShotgunHoleId')::uuid,
           (g->>'sourceHoleId')::uuid,
           (g->>'holeNumber')::integer,
           g->>'startPosition',
           (g->>'startAt')::timestamptz,
           (g->>'shiftNumber')::integer,
           (g->>'shiftTime')::time,
           g->>'groupLabel',
           (g->>'normalSize')::integer,
           (g->>'maximumSize')::integer,
           jsonb_array_length(g->'units')
    FROM jsonb_array_elements(v_snapshot->'groups') AS x(g);
    GET DIAGNOSTICS v_inserted_groups = ROW_COUNT;

    INSERT INTO public.tournament_round_start_validation_units (
        validation_id, validation_group_id, unit_type,
        tournament_registration_id, tournament_team_id, player_id,
        tournament_category_id, unit_name, unit_folio, order_in_group,
        handicap_snapshot_id, round_handicap_snapshot_id
    )
    SELECT v_validation_id,
           vg.id,
           u->>'unitType',
           (u->>'registrationId')::uuid,
           NULL,
           (u->>'playerId')::uuid,
           vg.tournament_category_id,
           u->>'name',
           u->>'folio',
           (u->>'orderInGroup')::smallint,
           (u->>'handicapSnapshotId')::uuid,
           (u->>'roundHandicapSnapshotId')::uuid
    FROM jsonb_array_elements(v_snapshot->'groups') AS x(g)
    JOIN public.tournament_round_start_validation_groups vg
      ON vg.validation_id = v_validation_id
     AND vg.source_group_id = (g->>'sourceGroupId')::uuid
    CROSS JOIN LATERAL jsonb_array_elements(g->'units') AS y(u);
    GET DIAGNOSTICS v_inserted_units = ROW_COUNT;

    IF v_inserted_groups <> v_group_count
       OR v_inserted_units <> v_unit_count THEN
        RAISE EXCEPTION 'La validación quedó incompleta y fue revertida automáticamente.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'grupos=%s/%s; unidades=%s/%s',
                      v_inserted_groups, v_group_count,
                      v_inserted_units, v_unit_count
                  );
    END IF;

    RETURN public.obtener_estado_validacion_salidas_ronda(p_tournament_round_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.reabrir_salidas_ronda(
    p_tournament_round_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tournament_id uuid;
    v_admin_id uuid;
    v_validation_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    IF length(btrim(COALESCE(p_reason, ''))) < 5 THEN
        RAISE EXCEPTION 'El motivo de reapertura debe contener al menos 5 caracteres.'
            USING ERRCODE = '22023';
    END IF;

    SELECT tournament_id INTO v_tournament_id
    FROM public.tournament_rounds
    WHERE id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.' USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para reabrir las salidas de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(p_tournament_round_id);

    SELECT au.id INTO v_admin_id
    FROM public.admin_users au
    WHERE au.auth_user_id = auth.uid() AND au.activo
    ORDER BY au.id
    LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT id INTO v_validation_id
    FROM public.tournament_round_start_validations
    WHERE tournament_round_id = p_tournament_round_id
      AND status = 'validated'
    FOR UPDATE;

    IF v_validation_id IS NULL THEN
        RETURN public.obtener_estado_validacion_salidas_ronda(p_tournament_round_id);
    END IF;

    PERFORM set_config('app.reabrir_validacion_salida_ronda', 'true', true);

    UPDATE public.tournament_round_start_validations
       SET status = 'reopened',
           reopened_at = now(),
           reopened_by = v_admin_id,
           reopen_reason = btrim(p_reason)
     WHERE id = v_validation_id;

    RETURN public.obtener_estado_validacion_salidas_ronda(p_tournament_round_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- 11. Superficie RPC mínima y comentarios operativos.
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public._bloquear_salida_ronda(uuid)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._salida_ronda_esta_validada(uuid)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._resolver_ronda_fila_salida(text, jsonb)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._proteger_validacion_salida_ronda()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._impedir_mutacion_detalle_validacion_salida()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._proteger_objeto_salida_ronda_validada()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._proteger_estado_inscripcion_salida_validada()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._construir_fotografia_salida_ronda(uuid)
    FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.previsualizar_validacion_salidas_ronda(uuid)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.obtener_estado_validacion_salidas_ronda(uuid)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.validar_salidas_ronda(uuid)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reabrir_salidas_ronda(uuid, text)
    FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.previsualizar_validacion_salidas_ronda(uuid)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_estado_validacion_salidas_ronda(uuid)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.validar_salidas_ronda(uuid)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.reabrir_salidas_ronda(uuid, text)
    TO authenticated;

COMMENT ON TABLE public.tournament_round_start_validations IS
    'Validaciones versionadas del acomodo de salida por ronda. No son tarjetas ni resultados.';
COMMENT ON TABLE public.tournament_round_start_validation_groups IS
    'Fotografía normalizada e inmutable de grupos incluidos en una validación de salida.';
COMMENT ON TABLE public.tournament_round_start_validation_units IS
    'Unidades de participación validadas: registration hoy y team para motores futuros.';
COMMENT ON FUNCTION public.previsualizar_validacion_salidas_ronda(uuid) IS
    'Valida sin escribir. Despacha el motor según formato, participación y tipo de salida.';
COMMENT ON FUNCTION public.validar_salidas_ronda(uuid) IS
    'Cierra la conformación de salidas de una ronda y guarda una fotografía versionada.';
COMMENT ON FUNCTION public.reabrir_salidas_ronda(uuid, text) IS
    'Reabre una salida validada conservando su versión histórica y motivo.';

COMMIT;
