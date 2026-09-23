BEGIN;

CREATE TABLE public.tournament_access_point_assignments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    access_point_id uuid NOT NULL REFERENCES public.tournament_access_points(id) ON DELETE RESTRICT,
    responsable_nombre text,
    habilitado boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_access_point_assignments_unique_358 UNIQUE (tournament_id, access_point_id),
    CONSTRAINT tournament_access_point_assignments_responsable_358
      CHECK (responsable_nombre IS NULL OR
             (length(btrim(responsable_nombre)) > 0 AND length(btrim(responsable_nombre)) <= 150))
);

COMMENT ON TABLE public.tournament_access_point_assignments IS
'Asignación de puntos reutilizables de acceso a un torneo. El responsable es una persona operativa externa y no requiere usuario de Tee Central.';
COMMENT ON COLUMN public.tournament_access_point_assignments.responsable_nombre IS
'Nombre opcional de la persona responsable de operar este punto durante el torneo. No representa un usuario del sistema.';
COMMENT ON COLUMN public.tournament_access_point_assignments.habilitado IS
'Permite bloquear o rehabilitar individualmente esta puerta/punto dentro del torneo sin eliminar la asignación.';

CREATE INDEX tournament_access_point_assignments_tournament_idx_358
ON public.tournament_access_point_assignments (tournament_id, habilitado);

CREATE INDEX tournament_access_point_assignments_point_idx_358
ON public.tournament_access_point_assignments (access_point_id);

CREATE OR REPLACE FUNCTION public.validar_asignacion_punto_acceso_358()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_point_owner uuid;
    v_point_active boolean;
    v_uses_access boolean;
    v_auth_uid uuid;
BEGIN
    v_auth_uid := auth.uid();

    IF TG_OP = 'UPDATE' THEN
        IF NEW.tournament_id IS DISTINCT FROM OLD.tournament_id
           OR NEW.access_point_id IS DISTINCT FROM OLD.access_point_id THEN
            RAISE EXCEPTION 'No se puede cambiar el torneo ni el punto de una asignación existente.';
        END IF;
    END IF;

    SELECT t.usar_control_acceso_qr INTO v_uses_access
    FROM public.tournaments t WHERE t.id = NEW.tournament_id;

    IF NOT FOUND THEN RAISE EXCEPTION 'El torneo indicado no existe.'; END IF;
    IF v_uses_access IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'El torneo no tiene habilitado el Control de Acceso QR de Tee Central.';
    END IF;

    SELECT ap.organizer_admin_user_id, ap.activo
    INTO v_point_owner, v_point_active
    FROM public.tournament_access_points ap WHERE ap.id = NEW.access_point_id;

    IF NOT FOUND THEN RAISE EXCEPTION 'El punto de acceso indicado no existe.'; END IF;
    IF v_point_active IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'No se puede asignar un punto de acceso inactivo.';
    END IF;
    IF v_auth_uid IS NULL THEN RAISE EXCEPTION 'Se requiere autenticación administrativa.'; END IF;

    IF NOT public.is_superadmin(v_auth_uid) THEN
        IF NOT public.is_tournament_organizer(v_auth_uid, NEW.tournament_id) THEN
            RAISE EXCEPTION 'No tiene permiso para administrar los puntos de acceso de este torneo.';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM public.admin_users au
            WHERE au.id = v_point_owner AND au.auth_user_id = v_auth_uid AND au.activo = true
        ) THEN
            RAISE EXCEPTION 'El punto de acceso no pertenece al organizador de este torneo.';
        END IF;
    END IF;

    NEW.responsable_nombre :=
      CASE WHEN NEW.responsable_nombre IS NULL THEN NULL
           ELSE NULLIF(btrim(NEW.responsable_nombre), '') END;
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validar_asignacion_punto_acceso_358
BEFORE INSERT OR UPDATE ON public.tournament_access_point_assignments
FOR EACH ROW EXECUTE FUNCTION public.validar_asignacion_punto_acceso_358();

ALTER TABLE public.tournament_access_point_assignments ENABLE ROW LEVEL SECURITY;

CREATE POLICY tournament_access_point_assignments_select_358
ON public.tournament_access_point_assignments FOR SELECT TO authenticated
USING (public.is_superadmin(auth.uid()) OR public.is_tournament_organizer(auth.uid(), tournament_id));

CREATE POLICY tournament_access_point_assignments_insert_358
ON public.tournament_access_point_assignments FOR INSERT TO authenticated
WITH CHECK (public.is_superadmin(auth.uid()) OR public.is_tournament_organizer(auth.uid(), tournament_id));

CREATE POLICY tournament_access_point_assignments_update_358
ON public.tournament_access_point_assignments FOR UPDATE TO authenticated
USING (public.is_superadmin(auth.uid()) OR public.is_tournament_organizer(auth.uid(), tournament_id))
WITH CHECK (public.is_superadmin(auth.uid()) OR public.is_tournament_organizer(auth.uid(), tournament_id));

REVOKE ALL ON TABLE public.tournament_access_point_assignments FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.tournament_access_point_assignments TO authenticated;
REVOKE ALL ON FUNCTION public.validar_asignacion_punto_acceso_358() FROM PUBLIC, anon, authenticated;

COMMIT;
