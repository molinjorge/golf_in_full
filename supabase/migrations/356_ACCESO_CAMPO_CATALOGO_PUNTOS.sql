BEGIN;

-- ============================================================
-- MIGRACIÓN 356
-- ACCESO AL CAMPO
-- Catálogo reutilizable de puntos de acceso del organizador
-- ============================================================

CREATE TABLE public.tournament_access_points (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    organizer_admin_user_id uuid NOT NULL
        REFERENCES public.admin_users(id)
        ON DELETE RESTRICT,

    nombre text NOT NULL,
    descripcion text,

    activo boolean NOT NULL DEFAULT true,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_access_points_nombre_no_vacio_356
        CHECK (length(btrim(nombre)) > 0),

    CONSTRAINT tournament_access_points_nombre_longitud_356
        CHECK (length(btrim(nombre)) <= 100),

    CONSTRAINT tournament_access_points_descripcion_longitud_356
        CHECK (
            descripcion IS NULL
            OR length(descripcion) <= 500
        )
);

COMMENT ON TABLE public.tournament_access_points IS
'Catálogo reutilizable de puntos físicos de acceso al campo propiedad de cada organizador. No representa usuarios ni guardias.';

COMMENT ON COLUMN public.tournament_access_points.organizer_admin_user_id IS
'Admin user propietario del catálogo de puntos de acceso.';

COMMENT ON COLUMN public.tournament_access_points.nombre IS
'Nombre operativo del punto: PUERTA 1, PUERTA 2, ESTACIONAMIENTO, ACCESO CASA CLUB, etc.';

COMMENT ON COLUMN public.tournament_access_points.activo IS
'Permite retirar temporalmente un punto del catálogo sin eliminar su historial.';

CREATE UNIQUE INDEX tournament_access_points_owner_nombre_uidx_356
    ON public.tournament_access_points (
        organizer_admin_user_id,
        lower(btrim(nombre))
    );

CREATE INDEX tournament_access_points_owner_activo_idx_356
    ON public.tournament_access_points (
        organizer_admin_user_id,
        activo
    );

CREATE OR REPLACE FUNCTION public.actualizar_updated_at_access_point_356()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tournament_access_points_updated_at_356
BEFORE UPDATE ON public.tournament_access_points
FOR EACH ROW
EXECUTE FUNCTION public.actualizar_updated_at_access_point_356();

ALTER TABLE public.tournament_access_points ENABLE ROW LEVEL SECURITY;

CREATE POLICY tournament_access_points_select_own_356
ON public.tournament_access_points
FOR SELECT
TO authenticated
USING (
    public.is_superadmin(auth.uid())
    OR EXISTS (
        SELECT 1
        FROM public.admin_users au
        WHERE au.id = tournament_access_points.organizer_admin_user_id
          AND au.auth_user_id = auth.uid()
          AND au.activo = true
    )
);

CREATE POLICY tournament_access_points_insert_own_356
ON public.tournament_access_points
FOR INSERT
TO authenticated
WITH CHECK (
    public.is_superadmin(auth.uid())
    OR EXISTS (
        SELECT 1
        FROM public.admin_users au
        WHERE au.id = tournament_access_points.organizer_admin_user_id
          AND au.auth_user_id = auth.uid()
          AND au.activo = true
    )
);

CREATE POLICY tournament_access_points_update_own_356
ON public.tournament_access_points
FOR UPDATE
TO authenticated
USING (
    public.is_superadmin(auth.uid())
    OR EXISTS (
        SELECT 1
        FROM public.admin_users au
        WHERE au.id = tournament_access_points.organizer_admin_user_id
          AND au.auth_user_id = auth.uid()
          AND au.activo = true
    )
)
WITH CHECK (
    public.is_superadmin(auth.uid())
    OR EXISTS (
        SELECT 1
        FROM public.admin_users au
        WHERE au.id = tournament_access_points.organizer_admin_user_id
          AND au.auth_user_id = auth.uid()
          AND au.activo = true
    )
);

REVOKE ALL ON TABLE public.tournament_access_points
FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE
ON TABLE public.tournament_access_points
TO authenticated;

REVOKE ALL ON FUNCTION public.actualizar_updated_at_access_point_356()
FROM PUBLIC, anon, authenticated;

COMMIT;
