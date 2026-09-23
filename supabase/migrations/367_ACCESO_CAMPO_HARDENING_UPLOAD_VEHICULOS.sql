BEGIN;

-- ============================================================
-- MIGRACIÓN 367
-- ACCESO AL CAMPO
-- Endurecimiento de carga de fotografías de vehículos
-- ============================================================

CREATE TABLE public.tournament_access_vehicle_upload_authorizations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entry_id uuid NOT NULL
        REFERENCES public.tournament_access_entries(id) ON DELETE CASCADE,
    assignment_id uuid NOT NULL
        REFERENCES public.tournament_access_point_assignments(id) ON DELETE RESTRICT,
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    storage_path text NOT NULL UNIQUE,
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_access_vehicle_upload_auth_path_chk
      CHECK (btrim(storage_path) <> '' AND length(storage_path) <= 500),
    CONSTRAINT tournament_access_vehicle_upload_auth_expiry_chk
      CHECK (expires_at > created_at)
);

CREATE INDEX tournament_access_vehicle_upload_auth_entry_idx
ON public.tournament_access_vehicle_upload_authorizations(entry_id, created_at DESC);

CREATE INDEX tournament_access_vehicle_upload_auth_pending_idx
ON public.tournament_access_vehicle_upload_authorizations(expires_at)
WHERE consumed_at IS NULL;

ALTER TABLE public.tournament_access_vehicle_upload_authorizations ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_access_vehicle_upload_authorizations
FROM PUBLIC, anon, authenticated;


CREATE OR REPLACE FUNCTION public._storage_upload_vehiculo_autorizado_367(
    p_storage_path text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.tournament_access_vehicle_upload_authorizations u
        JOIN public.tournament_access_entries e ON e.id=u.entry_id
        JOIN public.tournament_access_point_assignments a ON a.id=u.assignment_id
        JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
        JOIN public.tournaments t ON t.id=u.tournament_id
        WHERE u.storage_path=p_storage_path
          AND u.consumed_at IS NULL
          AND u.expires_at>now()
          AND e.tournament_id=u.tournament_id
          AND e.assignment_id=u.assignment_id
          AND e.vehiculo_foto_path IS NULL
          AND a.tournament_id=u.tournament_id
          AND a.habilitado=true
          AND ap.activo=true
          AND t.activo=true
          AND t.usar_control_acceso_qr=true
          AND t.estatus NOT IN (
              'finalizado'::public.estatus_torneo,
              'cancelado'::public.estatus_torneo
          )
    );
$$;

REVOKE ALL ON FUNCTION public._storage_upload_vehiculo_autorizado_367(text)
FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public._storage_upload_vehiculo_autorizado_367(text)
TO anon;


CREATE OR REPLACE FUNCTION public.preparar_foto_vehiculo_acceso_363(
    p_access_token text,
    p_entry_id uuid,
    p_extension text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','storage','pg_temp'
AS $$
DECLARE
    v_token text;
    v_ext text;
    v_assignment_id uuid;
    v_tournament_id uuid;
    v_entry_tournament_id uuid;
    v_entry_assignment_id uuid;
    v_existing_path text;
    v_object_path text;
BEGIN
    v_token := lower(btrim(coalesce(p_access_token,'')));
    v_ext := lower(btrim(coalesce(p_extension,'')));

    IF v_token !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'Código de acceso de puerta inválido.' USING errcode='22023';
    END IF;

    IF v_ext NOT IN ('jpg','jpeg','png','webp') THEN
        RAISE EXCEPTION 'Formato de imagen no permitido.' USING errcode='22023';
    END IF;

    SELECT a.id,a.tournament_id
      INTO v_assignment_id,v_tournament_id
      FROM public.tournament_access_point_credentials c
      JOIN public.tournament_access_point_assignments a ON a.id=c.assignment_id
      JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
      JOIN public.tournaments t ON t.id=a.tournament_id
     WHERE c.access_token=v_token
       AND c.activo=true
       AND a.habilitado=true
       AND ap.activo=true
       AND t.activo=true
       AND t.usar_control_acceso_qr=true
       AND t.estatus NOT IN (
           'finalizado'::public.estatus_torneo,
           'cancelado'::public.estatus_torneo
       )
     LIMIT 1;

    IF v_assignment_id IS NULL THEN
        RAISE EXCEPTION 'Este punto de acceso ya no está disponible.'
            USING errcode='42501';
    END IF;

    SELECT e.tournament_id,e.assignment_id,e.vehiculo_foto_path
      INTO v_entry_tournament_id,v_entry_assignment_id,v_existing_path
      FROM public.tournament_access_entries e
     WHERE e.id=p_entry_id;

    IF v_entry_tournament_id IS NULL
       OR v_entry_tournament_id<>v_tournament_id
       OR v_entry_assignment_id<>v_assignment_id THEN
        RAISE EXCEPTION 'El ingreso no corresponde a este punto de acceso.'
            USING errcode='42501';
    END IF;

    IF v_existing_path IS NOT NULL THEN
        RAISE EXCEPTION 'Este ingreso ya tiene fotografía de vehículo registrada.'
            USING errcode='23505';
    END IF;

    v_object_path :=
        v_tournament_id::text || '/' ||
        p_entry_id::text || '/' ||
        gen_random_uuid()::text || '.' ||
        CASE WHEN v_ext='jpeg' THEN 'jpg' ELSE v_ext END;

    -- Invalida autorizaciones previas pendientes del mismo ingreso.
    UPDATE public.tournament_access_vehicle_upload_authorizations
       SET consumed_at=now()
     WHERE entry_id=p_entry_id
       AND consumed_at IS NULL;

    INSERT INTO public.tournament_access_vehicle_upload_authorizations(
        entry_id,assignment_id,tournament_id,storage_path,expires_at
    )
    VALUES(
        p_entry_id,v_assignment_id,v_tournament_id,v_object_path,
        now()+interval '10 minutes'
    );

    RETURN jsonb_build_object(
        'ok',true,
        'bucket','acceso-campo-vehiculos',
        'path',v_object_path,
        'entryId',p_entry_id,
        'expiresAt',now()+interval '10 minutes'
    );
END;
$$;


CREATE OR REPLACE FUNCTION public.confirmar_evidencia_vehiculo_acceso_363(
    p_access_token text,
    p_entry_id uuid,
    p_storage_path text DEFAULT NULL,
    p_vehiculo_placa text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','storage','pg_temp'
AS $$
DECLARE
    v_token text;
    v_path text;
    v_plate text;
    v_assignment_id uuid;
    v_tournament_id uuid;
    v_entry_tournament_id uuid;
    v_entry_assignment_id uuid;
    v_existing_path text;
    v_object_exists boolean;
    v_auth_id uuid;
BEGIN
    v_token := lower(btrim(coalesce(p_access_token,'')));
    v_path := nullif(btrim(coalesce(p_storage_path,'')),'');
    v_plate := nullif(upper(btrim(coalesce(p_vehiculo_placa,''))),'');

    IF v_token !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'Código de acceso de puerta inválido.' USING errcode='22023';
    END IF;

    IF v_path IS NULL AND v_plate IS NULL THEN
        RAISE EXCEPTION 'Debe proporcionar fotografía o placa del vehículo.'
            USING errcode='22023';
    END IF;

    IF v_plate IS NOT NULL AND length(v_plate)>30 THEN
        RAISE EXCEPTION 'La placa no puede exceder 30 caracteres.'
            USING errcode='22023';
    END IF;

    SELECT a.id,a.tournament_id
      INTO v_assignment_id,v_tournament_id
      FROM public.tournament_access_point_credentials c
      JOIN public.tournament_access_point_assignments a ON a.id=c.assignment_id
      JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
      JOIN public.tournaments t ON t.id=a.tournament_id
     WHERE c.access_token=v_token
       AND c.activo=true
       AND a.habilitado=true
       AND ap.activo=true
       AND t.activo=true
       AND t.usar_control_acceso_qr=true
       AND t.estatus NOT IN (
           'finalizado'::public.estatus_torneo,
           'cancelado'::public.estatus_torneo
       )
     LIMIT 1;

    IF v_assignment_id IS NULL THEN
        RAISE EXCEPTION 'Este punto de acceso ya no está disponible.'
            USING errcode='42501';
    END IF;

    SELECT e.tournament_id,e.assignment_id,e.vehiculo_foto_path
      INTO v_entry_tournament_id,v_entry_assignment_id,v_existing_path
      FROM public.tournament_access_entries e
     WHERE e.id=p_entry_id
     FOR UPDATE;

    IF v_entry_tournament_id IS NULL
       OR v_entry_tournament_id<>v_tournament_id
       OR v_entry_assignment_id<>v_assignment_id THEN
        RAISE EXCEPTION 'El ingreso no corresponde a este punto de acceso.'
            USING errcode='42501';
    END IF;

    IF v_existing_path IS NOT NULL AND v_path IS NOT NULL
       AND v_existing_path<>v_path THEN
        RAISE EXCEPTION 'Este ingreso ya tiene otra fotografía registrada.'
            USING errcode='23505';
    END IF;

    IF v_path IS NOT NULL THEN
        SELECT u.id
          INTO v_auth_id
          FROM public.tournament_access_vehicle_upload_authorizations u
         WHERE u.entry_id=p_entry_id
           AND u.assignment_id=v_assignment_id
           AND u.tournament_id=v_tournament_id
           AND u.storage_path=v_path
           AND u.consumed_at IS NULL
           AND u.expires_at>now()
         FOR UPDATE;

        IF v_auth_id IS NULL THEN
            RAISE EXCEPTION 'La autorización de carga no existe, venció o ya fue utilizada.'
                USING errcode='42501';
        END IF;

        SELECT EXISTS (
            SELECT 1
              FROM storage.objects o
             WHERE o.bucket_id='acceso-campo-vehiculos'
               AND o.name=v_path
        ) INTO v_object_exists;

        IF NOT v_object_exists THEN
            RAISE EXCEPTION 'La fotografía todavía no existe en el almacenamiento privado.'
                USING errcode='22023';
        END IF;
    END IF;

    UPDATE public.tournament_access_entries
       SET vehiculo_foto_path=coalesce(v_existing_path,v_path),
           vehiculo_placa=v_plate
     WHERE id=p_entry_id;

    IF v_auth_id IS NOT NULL THEN
        UPDATE public.tournament_access_vehicle_upload_authorizations
           SET consumed_at=now()
         WHERE id=v_auth_id;
    END IF;

    RETURN jsonb_build_object(
        'ok',true,
        'entryId',p_entry_id,
        'photoStored',coalesce(v_existing_path,v_path) IS NOT NULL,
        'plateStored',v_plate IS NOT NULL
    );
END;
$$;


DROP POLICY IF EXISTS acceso_campo_vehiculos_insert_363 ON storage.objects;

CREATE POLICY acceso_campo_vehiculos_insert_367
ON storage.objects
FOR INSERT
TO anon,authenticated
WITH CHECK (
    bucket_id='acceso-campo-vehiculos'
    AND public._storage_upload_vehiculo_autorizado_367(name)
);

COMMIT;
