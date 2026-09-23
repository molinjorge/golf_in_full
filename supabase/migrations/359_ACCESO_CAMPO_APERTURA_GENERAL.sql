BEGIN;

-- ============================================================
-- MIGRACIÓN 359
-- ACCESO AL CAMPO
-- Apertura general manual o programada por torneo
-- ============================================================

CREATE TABLE public.tournament_access_control_settings (
    tournament_id uuid PRIMARY KEY
        REFERENCES public.tournaments(id)
        ON DELETE RESTRICT,

    apertura_manual_at timestamptz,
    apertura_programada_at timestamptz,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_access_control_settings_apertura_359
        CHECK (
            NOT (
                apertura_manual_at IS NOT NULL
                AND apertura_programada_at IS NOT NULL
            )
        )
);

COMMENT ON TABLE public.tournament_access_control_settings IS
'Configuración de apertura general del acceso al campo por torneo. La apertura puede ser manual o programada.';

COMMENT ON COLUMN public.tournament_access_control_settings.apertura_manual_at IS
'Momento en que el organizador abrió manualmente el acceso general.';

COMMENT ON COLUMN public.tournament_access_control_settings.apertura_programada_at IS
'Fecha y hora a partir de la cual el acceso general queda abierto automáticamente por evaluación de hora de servidor.';

CREATE OR REPLACE FUNCTION public.validar_configuracion_acceso_torneo_359()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_uses_access boolean;
    v_status public.estatus_torneo;
    v_auth_uid uuid;
BEGIN
    v_auth_uid := auth.uid();

    IF TG_OP = 'UPDATE'
       AND NEW.tournament_id IS DISTINCT FROM OLD.tournament_id THEN
        RAISE EXCEPTION 'No se puede cambiar el torneo de una configuración de acceso existente.';
    END IF;

    SELECT t.usar_control_acceso_qr, t.estatus
      INTO v_uses_access, v_status
      FROM public.tournaments t
     WHERE t.id = NEW.tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.';
    END IF;

    IF v_uses_access IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'El torneo no tiene habilitado el Control de Acceso QR de Tee Central.';
    END IF;

    IF v_status IN ('finalizado'::public.estatus_torneo, 'cancelado'::public.estatus_torneo) THEN
        RAISE EXCEPTION 'No se puede configurar la apertura de acceso de un torneo finalizado o cancelado.';
    END IF;

    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'Se requiere autenticación administrativa.';
    END IF;

    IF NOT (
        public.is_superadmin(v_auth_uid)
        OR public.is_tournament_organizer(v_auth_uid, NEW.tournament_id)
    ) THEN
        RAISE EXCEPTION 'No tiene permiso para administrar el acceso de este torneo.';
    END IF;

    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validar_configuracion_acceso_torneo_359
BEFORE INSERT OR UPDATE
ON public.tournament_access_control_settings
FOR EACH ROW
EXECUTE FUNCTION public.validar_configuracion_acceso_torneo_359();

ALTER TABLE public.tournament_access_control_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY tournament_access_control_settings_select_359
ON public.tournament_access_control_settings
FOR SELECT TO authenticated
USING (
    public.is_superadmin(auth.uid())
    OR public.is_tournament_organizer(auth.uid(), tournament_id)
);

CREATE POLICY tournament_access_control_settings_insert_359
ON public.tournament_access_control_settings
FOR INSERT TO authenticated
WITH CHECK (
    public.is_superadmin(auth.uid())
    OR public.is_tournament_organizer(auth.uid(), tournament_id)
);

CREATE POLICY tournament_access_control_settings_update_359
ON public.tournament_access_control_settings
FOR UPDATE TO authenticated
USING (
    public.is_superadmin(auth.uid())
    OR public.is_tournament_organizer(auth.uid(), tournament_id)
)
WITH CHECK (
    public.is_superadmin(auth.uid())
    OR public.is_tournament_organizer(auth.uid(), tournament_id)
);

REVOKE ALL ON TABLE public.tournament_access_control_settings
FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE
ON TABLE public.tournament_access_control_settings
TO authenticated;

REVOKE ALL ON FUNCTION public.validar_configuracion_acceso_torneo_359()
FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Función administrativa: ABRIR AHORA
-- Crea o sustituye la programación por apertura manual.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.abrir_acceso_campo_ahora_359(
    p_tournament_id uuid
)
RETURNS public.tournament_access_control_settings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_result public.tournament_access_control_settings;
    v_status public.estatus_torneo;
    v_uses_access boolean;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Se requiere autenticación administrativa.';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(), p_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No tiene permiso para administrar el acceso de este torneo.';
    END IF;

    SELECT estatus, usar_control_acceso_qr
      INTO v_status, v_uses_access
      FROM public.tournaments
     WHERE id = p_tournament_id;

    IF NOT FOUND THEN RAISE EXCEPTION 'El torneo indicado no existe.'; END IF;
    IF v_uses_access IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'El torneo no tiene habilitado el Control de Acceso QR de Tee Central.';
    END IF;
    IF v_status IN ('finalizado'::public.estatus_torneo, 'cancelado'::public.estatus_torneo) THEN
        RAISE EXCEPTION 'No se puede abrir el acceso de un torneo finalizado o cancelado.';
    END IF;

    INSERT INTO public.tournament_access_control_settings (
        tournament_id, apertura_manual_at, apertura_programada_at
    )
    VALUES (p_tournament_id, now(), NULL)
    ON CONFLICT (tournament_id)
    DO UPDATE SET
        apertura_manual_at = now(),
        apertura_programada_at = NULL,
        updated_at = now()
    RETURNING * INTO v_result;

    RETURN v_result;
END;
$$;

-- ------------------------------------------------------------
-- Función administrativa: PROGRAMAR APERTURA
-- La apertura se vuelve efectiva cuando now() alcanza la fecha/hora.
-- No requiere cron ni job.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.programar_apertura_acceso_campo_359(
    p_tournament_id uuid,
    p_apertura_programada_at timestamptz
)
RETURNS public.tournament_access_control_settings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_result public.tournament_access_control_settings;
    v_status public.estatus_torneo;
    v_uses_access boolean;
BEGIN
    IF p_apertura_programada_at IS NULL THEN
        RAISE EXCEPTION 'Debe indicar la fecha y hora programada de apertura.';
    END IF;

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Se requiere autenticación administrativa.';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(), p_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No tiene permiso para administrar el acceso de este torneo.';
    END IF;

    SELECT estatus, usar_control_acceso_qr
      INTO v_status, v_uses_access
      FROM public.tournaments
     WHERE id = p_tournament_id;

    IF NOT FOUND THEN RAISE EXCEPTION 'El torneo indicado no existe.'; END IF;
    IF v_uses_access IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'El torneo no tiene habilitado el Control de Acceso QR de Tee Central.';
    END IF;
    IF v_status IN ('finalizado'::public.estatus_torneo, 'cancelado'::public.estatus_torneo) THEN
        RAISE EXCEPTION 'No se puede programar el acceso de un torneo finalizado o cancelado.';
    END IF;

    INSERT INTO public.tournament_access_control_settings (
        tournament_id, apertura_manual_at, apertura_programada_at
    )
    VALUES (p_tournament_id, NULL, p_apertura_programada_at)
    ON CONFLICT (tournament_id)
    DO UPDATE SET
        apertura_manual_at = NULL,
        apertura_programada_at = EXCLUDED.apertura_programada_at,
        updated_at = now()
    RETURNING * INTO v_result;

    RETURN v_result;
END;
$$;

-- ------------------------------------------------------------
-- Función de evaluación: ¿está abierto el acceso general?
-- Hard block para finalizado/cancelado y para módulo QR apagado.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.acceso_campo_abierto_359(
    p_tournament_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
    SELECT COALESCE(
        (
            SELECT
                t.usar_control_acceso_qr = true
                AND t.estatus NOT IN (
                    'finalizado'::public.estatus_torneo,
                    'cancelado'::public.estatus_torneo
                )
                AND (
                    s.apertura_manual_at IS NOT NULL
                    OR (
                        s.apertura_programada_at IS NOT NULL
                        AND now() >= s.apertura_programada_at
                    )
                )
            FROM public.tournaments t
            LEFT JOIN public.tournament_access_control_settings s
              ON s.tournament_id = t.id
            WHERE t.id = p_tournament_id
        ),
        false
    );
$$;

REVOKE ALL ON FUNCTION public.abrir_acceso_campo_ahora_359(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.abrir_acceso_campo_ahora_359(uuid)
TO authenticated;

REVOKE ALL ON FUNCTION public.programar_apertura_acceso_campo_359(uuid, timestamptz)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.programar_apertura_acceso_campo_359(uuid, timestamptz)
TO authenticated;

REVOKE ALL ON FUNCTION public.acceso_campo_abierto_359(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.acceso_campo_abierto_359(uuid)
TO authenticated;

COMMIT;
