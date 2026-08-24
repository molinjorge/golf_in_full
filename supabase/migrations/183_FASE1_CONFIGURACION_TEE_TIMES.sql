-- ============================================================================
-- 183_FASE1_CONFIGURACION_TEE_TIMES.sql
-- TEE CENTRAL
--
-- OBJETIVO
-- Crear exclusivamente la configuración propia del formato de salida TEE TIMES
-- sobre la arquitectura común construida en Migración 182.
--
-- PRINCIPIOS
-- - `formato_salida` continúa perteneciendo a `tournament_rounds`.
-- - La hora inicial del turno ya existe en `tournament_round_shifts.hora_salida`
--   y se reutiliza como fuente de verdad; NO se duplica.
-- - La configuración TEE TIMES se divide en:
--     A) configuración del turno/stream temporal;
--     B) tee(s)/hoyo(s) de inicio del turno;
--     C) tamaño y orden de las categorías dentro del turno.
-- - Soporta 1 o 2 tees de salida sin hardcodear hoyos 1/10.
-- - NO prepara grupos todavía.
-- - NO valida definitivamente todavía.
-- - NO habilita emisión de tarjetas todavía.
-- - NO modifica el motor Shotgun.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. CONFIGURACIÓN TEE TIMES POR TURNO
--
-- tournament_round_shifts.hora_salida = primera hora del turno.
-- intervalo_grupos_minutos = separación temporal entre grupos del mismo stream.
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.tournament_tee_time_shift_configs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_round_shift_id uuid NOT NULL
        REFERENCES public.tournament_round_shifts(id)
        ON DELETE RESTRICT,

    intervalo_grupos_minutos integer NOT NULL DEFAULT 10,

    activo boolean NOT NULL DEFAULT true,
    fecha_baja timestamptz,
    dado_de_baja_por uuid
        REFERENCES public.admin_users(id)
        ON DELETE RESTRICT,
    motivo_baja text,

    created_by uuid
        REFERENCES public.admin_users(id)
        ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT chk_tee_time_intervalo_grupos
        CHECK (
            intervalo_grupos_minutos >= 1
            AND intervalo_grupos_minutos <= 60
        )
);

CREATE INDEX IF NOT EXISTS idx_tee_time_shift_configs_shift
ON public.tournament_tee_time_shift_configs(
    tournament_round_shift_id
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_tee_time_shift_config_activa
ON public.tournament_tee_time_shift_configs(
    tournament_round_shift_id
)
WHERE activo = true;

COMMENT ON TABLE public.tournament_tee_time_shift_configs IS
'Configuración temporal del motor Tee Times por turno. La primera hora se toma de tournament_round_shifts.hora_salida.';

COMMENT ON COLUMN public.tournament_tee_time_shift_configs.intervalo_grupos_minutos IS
'Minutos entre salidas sucesivas de grupos en cada tee/stream activo.';


-- ============================================================================
-- 02. TEES / HOYOS DE INICIO DEL TURNO
--
-- Una fila = un stream de salida.
-- lane_order 1/2 permite single tee o double tee.
-- offset_inicio_minutos permite que el segundo tee arranque simultáneamente
-- (0) o con un pequeño desfase, sin duplicar la hora base del turno.
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.tournament_tee_time_shift_start_holes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_tee_time_shift_config_id uuid NOT NULL
        REFERENCES public.tournament_tee_time_shift_configs(id)
        ON DELETE RESTRICT,

    hoyo_id uuid NOT NULL
        REFERENCES public.hoyos(id)
        ON DELETE RESTRICT,

    lane_order smallint NOT NULL,
    offset_inicio_minutos integer NOT NULL DEFAULT 0,

    activo boolean NOT NULL DEFAULT true,
    fecha_baja timestamptz,
    dado_de_baja_por uuid
        REFERENCES public.admin_users(id)
        ON DELETE RESTRICT,
    motivo_baja text,

    created_by uuid
        REFERENCES public.admin_users(id)
        ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT chk_tee_time_lane_order
        CHECK (lane_order IN (1, 2)),

    CONSTRAINT chk_tee_time_offset_inicio
        CHECK (
            offset_inicio_minutos >= 0
            AND offset_inicio_minutos <= 180
        )
);

CREATE INDEX IF NOT EXISTS idx_tee_time_start_holes_config
ON public.tournament_tee_time_shift_start_holes(
    tournament_tee_time_shift_config_id
);

CREATE INDEX IF NOT EXISTS idx_tee_time_start_holes_hoyo
ON public.tournament_tee_time_shift_start_holes(
    hoyo_id
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_tee_time_start_hole_activo
ON public.tournament_tee_time_shift_start_holes(
    tournament_tee_time_shift_config_id,
    hoyo_id
)
WHERE activo = true;

CREATE UNIQUE INDEX IF NOT EXISTS uq_tee_time_lane_order_activo
ON public.tournament_tee_time_shift_start_holes(
    tournament_tee_time_shift_config_id,
    lane_order
)
WHERE activo = true;

COMMENT ON TABLE public.tournament_tee_time_shift_start_holes IS
'Streams/tees de inicio de un turno Tee Times. Permite uno o dos hoyos de salida sin hardcodear 1/10.';

COMMENT ON COLUMN public.tournament_tee_time_shift_start_holes.lane_order IS
'Orden lógico del stream de salida: 1 = principal; 2 = segundo tee opcional.';

COMMENT ON COLUMN public.tournament_tee_time_shift_start_holes.offset_inicio_minutos IS
'Desfase respecto de tournament_round_shifts.hora_salida. Cero permite double tee simultáneo.';


-- ============================================================================
-- 03. CONFIGURACIÓN TEE TIMES POR CATEGORÍA/TURNO
--
-- Mantiene el mismo concepto de tamaño normal/máximo usado en Shotgun,
-- pero sin contaminarlo con A/B ni hoyos múltiples.
--
-- sequence_order define el orden de bloque de categoría dentro del turno.
-- La secuencia final de grupos se materializará en Fase 2.
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.tournament_tee_time_category_configs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_round_shift_category_id uuid NOT NULL
        REFERENCES public.tournament_round_shift_categories(id)
        ON DELETE RESTRICT,

    tamano_grupo_normal integer NOT NULL,
    tamano_grupo_maximo integer NOT NULL,
    sequence_order integer NOT NULL DEFAULT 1,

    activo boolean NOT NULL DEFAULT true,
    fecha_baja timestamptz,
    dado_de_baja_por uuid
        REFERENCES public.admin_users(id)
        ON DELETE RESTRICT,
    motivo_baja text,

    created_by uuid
        REFERENCES public.admin_users(id)
        ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT chk_tee_time_tamano_grupo_normal
        CHECK (tamano_grupo_normal >= 1),

    CONSTRAINT chk_tee_time_tamano_grupo_maximo
        CHECK (tamano_grupo_maximo >= tamano_grupo_normal),

    CONSTRAINT chk_tee_time_sequence_order
        CHECK (sequence_order >= 1)
);

CREATE INDEX IF NOT EXISTS idx_tee_time_category_configs_trsc
ON public.tournament_tee_time_category_configs(
    tournament_round_shift_category_id
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_tee_time_category_config_activa
ON public.tournament_tee_time_category_configs(
    tournament_round_shift_category_id
)
WHERE activo = true;

COMMENT ON TABLE public.tournament_tee_time_category_configs IS
'Configuración de tamaño y orden de cada categoría dentro de un turno Tee Times.';

COMMENT ON COLUMN public.tournament_tee_time_category_configs.sequence_order IS
'Orden del bloque de categoría dentro del turno. La secuencia de grupos se construirá en Fase 2.';


-- ============================================================================
-- 04. HELPERS DE PERMISOS
-- ============================================================================

CREATE OR REPLACE FUNCTION public.can_view_tournament_tee_time_shift_config(
    p_user_id uuid,
    p_config_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT
        public.is_superadmin(p_user_id)
        OR EXISTS (
            SELECT 1
            FROM public.tournament_tee_time_shift_configs cfg
            JOIN public.tournament_round_shifts rs
              ON rs.id = cfg.tournament_round_shift_id
            JOIN public.tournament_rounds tr
              ON tr.id = rs.tournament_round_id
            JOIN public.tournaments t
              ON t.id = tr.tournament_id
            WHERE cfg.id = p_config_id
              AND (
                  public.is_tournament_organizer(p_user_id, t.id)
                  OR public.is_club_admin(p_user_id, t.club_id)
              )
        );
$function$;


CREATE OR REPLACE FUNCTION public.can_manage_tournament_tee_time_shift_config(
    p_user_id uuid,
    p_config_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT public.can_view_tournament_tee_time_shift_config(
        p_user_id,
        p_config_id
    );
$function$;


-- ============================================================================
-- 05. RLS
-- ============================================================================

ALTER TABLE public.tournament_tee_time_shift_configs
ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.tournament_tee_time_shift_start_holes
ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.tournament_tee_time_category_configs
ENABLE ROW LEVEL SECURITY;


-- Shift config ---------------------------------------------------------------

DROP POLICY IF EXISTS tee_time_shift_configs_select
ON public.tournament_tee_time_shift_configs;

CREATE POLICY tee_time_shift_configs_select
ON public.tournament_tee_time_shift_configs
FOR SELECT
USING (
    public.is_superadmin(auth.uid())
    OR (
        activo = true
        AND EXISTS (
            SELECT 1
            FROM public.tournament_round_shifts rs
            JOIN public.tournament_rounds tr
              ON tr.id = rs.tournament_round_id
            WHERE rs.id =
                tournament_tee_time_shift_configs.tournament_round_shift_id
              AND rs.activo = true
              AND tr.activo = true
        )
    )
);

DROP POLICY IF EXISTS tee_time_shift_configs_write
ON public.tournament_tee_time_shift_configs;

CREATE POLICY tee_time_shift_configs_write
ON public.tournament_tee_time_shift_configs
FOR ALL
TO authenticated
USING (
    public.is_superadmin(auth.uid())
    OR EXISTS (
        SELECT 1
        FROM public.tournament_round_shifts rs
        JOIN public.tournament_rounds tr
          ON tr.id = rs.tournament_round_id
        JOIN public.tournaments t
          ON t.id = tr.tournament_id
        WHERE rs.id =
            tournament_tee_time_shift_configs.tournament_round_shift_id
          AND (
              public.is_tournament_organizer(auth.uid(), t.id)
              OR public.is_club_admin(auth.uid(), t.club_id)
          )
    )
)
WITH CHECK (
    public.is_superadmin(auth.uid())
    OR EXISTS (
        SELECT 1
        FROM public.tournament_round_shifts rs
        JOIN public.tournament_rounds tr
          ON tr.id = rs.tournament_round_id
        JOIN public.tournaments t
          ON t.id = tr.tournament_id
        WHERE rs.id =
            tournament_tee_time_shift_configs.tournament_round_shift_id
          AND (
              public.is_tournament_organizer(auth.uid(), t.id)
              OR public.is_club_admin(auth.uid(), t.club_id)
          )
    )
);


-- Start holes ----------------------------------------------------------------

DROP POLICY IF EXISTS tee_time_shift_start_holes_select
ON public.tournament_tee_time_shift_start_holes;

CREATE POLICY tee_time_shift_start_holes_select
ON public.tournament_tee_time_shift_start_holes
FOR SELECT
USING (
    public.can_view_tournament_tee_time_shift_config(
        auth.uid(),
        tournament_tee_time_shift_config_id
    )
);

DROP POLICY IF EXISTS tee_time_shift_start_holes_write
ON public.tournament_tee_time_shift_start_holes;

CREATE POLICY tee_time_shift_start_holes_write
ON public.tournament_tee_time_shift_start_holes
FOR ALL
TO authenticated
USING (
    public.can_manage_tournament_tee_time_shift_config(
        auth.uid(),
        tournament_tee_time_shift_config_id
    )
)
WITH CHECK (
    public.can_manage_tournament_tee_time_shift_config(
        auth.uid(),
        tournament_tee_time_shift_config_id
    )
);


-- Category configs ------------------------------------------------------------

DROP POLICY IF EXISTS tee_time_category_configs_select
ON public.tournament_tee_time_category_configs;

CREATE POLICY tee_time_category_configs_select
ON public.tournament_tee_time_category_configs
FOR SELECT
USING (
    public.is_superadmin(auth.uid())
    OR (
        activo = true
        AND EXISTS (
            SELECT 1
            FROM public.tournament_round_shift_categories sc
            JOIN public.tournament_round_shifts rs
              ON rs.id = sc.tournament_round_shift_id
            JOIN public.tournament_rounds tr
              ON tr.id = rs.tournament_round_id
            WHERE sc.id =
                tournament_tee_time_category_configs.tournament_round_shift_category_id
              AND sc.activo = true
              AND rs.activo = true
              AND tr.activo = true
        )
    )
);

DROP POLICY IF EXISTS tee_time_category_configs_write
ON public.tournament_tee_time_category_configs;

CREATE POLICY tee_time_category_configs_write
ON public.tournament_tee_time_category_configs
FOR ALL
TO authenticated
USING (
    public.is_superadmin(auth.uid())
    OR EXISTS (
        SELECT 1
        FROM public.tournament_round_shift_categories sc
        JOIN public.tournament_round_shifts rs
          ON rs.id = sc.tournament_round_shift_id
        JOIN public.tournament_rounds tr
          ON tr.id = rs.tournament_round_id
        JOIN public.tournaments t
          ON t.id = tr.tournament_id
        WHERE sc.id =
            tournament_tee_time_category_configs.tournament_round_shift_category_id
          AND (
              public.is_tournament_organizer(auth.uid(), t.id)
              OR public.is_club_admin(auth.uid(), t.club_id)
          )
    )
)
WITH CHECK (
    public.is_superadmin(auth.uid())
    OR EXISTS (
        SELECT 1
        FROM public.tournament_round_shift_categories sc
        JOIN public.tournament_round_shifts rs
          ON rs.id = sc.tournament_round_shift_id
        JOIN public.tournament_rounds tr
          ON tr.id = rs.tournament_round_id
        JOIN public.tournaments t
          ON t.id = tr.tournament_id
        WHERE sc.id =
            tournament_tee_time_category_configs.tournament_round_shift_category_id
          AND (
              public.is_tournament_organizer(auth.uid(), t.id)
              OR public.is_club_admin(auth.uid(), t.club_id)
          )
    )
);


-- ============================================================================
-- 06. PRIVILEGIOS
-- ============================================================================

REVOKE ALL ON TABLE public.tournament_tee_time_shift_configs
FROM PUBLIC, anon;

REVOKE ALL ON TABLE public.tournament_tee_time_shift_start_holes
FROM PUBLIC, anon;

REVOKE ALL ON TABLE public.tournament_tee_time_category_configs
FROM PUBLIC, anon;

GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLE public.tournament_tee_time_shift_configs
TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLE public.tournament_tee_time_shift_start_holes
TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLE public.tournament_tee_time_category_configs
TO authenticated;

GRANT ALL
ON TABLE public.tournament_tee_time_shift_configs,
         public.tournament_tee_time_shift_start_holes,
         public.tournament_tee_time_category_configs
TO service_role;


-- ============================================================================
-- 07. REGISTRAR MOTOR TEE TIMES INDIVIDUAL STROKE — NO OPERATIVO AÚN
--
-- Queda visible para el dispatcher, pero:
-- - supports_start_validation = false
-- - supports_scorecard_emission = false
--
-- Así la UI/backend pueden reconocer que el formato existe sin permitir
-- validación/emisión antes de implementar Fases posteriores.
-- ============================================================================

INSERT INTO public.tournament_start_engine_registry (
    start_format,
    participation_type,
    scoring_engine,
    preparation_engine,
    validation_engine,
    contract_version,
    activo,
    supports_scorecard_emission,
    scorecard_unit_type,
    scorecard_emission_engine,
    supports_start_validation,
    start_validation_handler
)
VALUES (
    'tee_times'::public.formato_salida_ronda,
    'individual',
    'stroke',
    'tee_times_v1',
    'stroke_individual_tee_times_v1',
    2,
    true,
    false,
    NULL,
    NULL,
    false,
    NULL
)
ON CONFLICT (
    start_format,
    participation_type,
    scoring_engine
)
DO UPDATE SET
    preparation_engine = EXCLUDED.preparation_engine,
    validation_engine = EXCLUDED.validation_engine,
    contract_version = EXCLUDED.contract_version,
    activo = true,

    -- Fail-closed hasta implementar F3/F4.
    supports_scorecard_emission = false,
    scorecard_unit_type = NULL,
    scorecard_emission_engine = NULL,
    supports_start_validation = false,
    start_validation_handler = NULL,

    updated_at = now();


COMMIT;
