BEGIN;

-- ============================================================
-- MIGRACIÓN 363
-- ACCESO AL CAMPO
-- Evidencia de vehículo: fotografía privada + placa opcional
-- ============================================================

-- 1) Bucket privado específico del módulo.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'acceso-campo-vehiculos',
    'acceso-campo-vehiculos',
    false,
    10485760,
    ARRAY['image/jpeg','image/png','image/webp']::text[]
)
ON CONFLICT (id) DO UPDATE
SET public = false,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 2) Metadatos de evidencia vinculados al evento de ingreso.
ALTER TABLE public.tournament_access_entries
    ADD COLUMN vehiculo_foto_path text NULL,
    ADD COLUMN vehiculo_placa text NULL;

ALTER TABLE public.tournament_access_entries
    ADD CONSTRAINT tournament_access_entries_vehicle_path_363
        CHECK (
            vehiculo_foto_path IS NULL
            OR (
                btrim(vehiculo_foto_path) <> ''
                AND length(vehiculo_foto_path) <= 500
            )
        ),
    ADD CONSTRAINT tournament_access_entries_vehicle_plate_363
        CHECK (
            vehiculo_placa IS NULL
            OR (
                btrim(vehiculo_placa) <> ''
                AND length(vehiculo_placa) <= 30
            )
        );

COMMENT ON COLUMN public.tournament_access_entries.vehiculo_foto_path IS
'Ruta privada en bucket acceso-campo-vehiculos. No es URL pública.';
COMMENT ON COLUMN public.tournament_access_entries.vehiculo_placa IS
'Placa capturada manualmente; opcional. No se realiza OCR en esta fase.';

-- 3) Validar, antes del upload, que la puerta y el evento corresponden.
-- Devuelve una ruta única que el cliente deberá usar exactamente.
CREATE OR REPLACE FUNCTION public.preparar_foto_vehiculo_acceso_363(
    p_access_token text,
    p_entry_id uuid,
    p_extension text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'storage', 'pg_temp'
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
       AND t.estatus NOT IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo)
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

    RETURN jsonb_build_object(
        'ok',true,
        'bucket','acceso-campo-vehiculos',
        'path',v_object_path,
        'entryId',p_entry_id
    );
END;
$$;

-- 4) Confirmar la evidencia después del upload.
-- Verifica que el objeto exista en el bucket privado antes de guardar la ruta.
CREATE OR REPLACE FUNCTION public.confirmar_evidencia_vehiculo_acceso_363(
    p_access_token text,
    p_entry_id uuid,
    p_storage_path text DEFAULT NULL,
    p_vehiculo_placa text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'storage', 'pg_temp'
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
       AND t.estatus NOT IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo)
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
        IF v_path NOT LIKE v_tournament_id::text || '/' || p_entry_id::text || '/%' THEN
            RAISE EXCEPTION 'Ruta de fotografía inválida para este ingreso.'
                USING errcode='22023';
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

    RETURN jsonb_build_object(
        'ok',true,
        'entryId',p_entry_id,
        'photoStored',coalesce(v_existing_path,v_path) IS NOT NULL,
        'plateStored',v_plate IS NOT NULL
    );
END;
$$;

-- 5) Política de carga pública, pero sólo sobre una ruta previamente
-- autorizable por el esquema torneo/entry. La vinculación final se valida RPC.
CREATE POLICY acceso_campo_vehiculos_insert_363
ON storage.objects
FOR INSERT TO anon, authenticated
WITH CHECK (
    bucket_id='acceso-campo-vehiculos'
    AND (storage.foldername(name))[1] IS NOT NULL
    AND (storage.foldername(name))[2] IS NOT NULL
    AND EXISTS (
        SELECT 1
          FROM public.tournament_access_entries e
         WHERE e.id=((storage.foldername(name))[2])::uuid
           AND e.tournament_id=((storage.foldername(name))[1])::uuid
           AND e.vehiculo_foto_path IS NULL
    )
);

-- Sólo organizador del torneo o Superadmin pueden leer la evidencia.
CREATE POLICY acceso_campo_vehiculos_select_363
ON storage.objects
FOR SELECT TO authenticated
USING (
    bucket_id='acceso-campo-vehiculos'
    AND (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(
            auth.uid(),
            ((storage.foldername(name))[1])::uuid
        )
    )
);

REVOKE ALL ON FUNCTION public.preparar_foto_vehiculo_acceso_363(text,uuid,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.preparar_foto_vehiculo_acceso_363(text,uuid,text)
TO anon,authenticated;

REVOKE ALL ON FUNCTION public.confirmar_evidencia_vehiculo_acceso_363(text,uuid,text,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.confirmar_evidencia_vehiculo_acceso_363(text,uuid,text,text)
TO anon,authenticated;

COMMIT;
