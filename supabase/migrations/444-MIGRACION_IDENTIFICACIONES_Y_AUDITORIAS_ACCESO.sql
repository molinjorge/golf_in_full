-- TEE CENTRAL / GOLF IN FULL | MIGRACIÓN 444
-- EJECUCIÓN MANUAL POR EL USUARIO. REQUIERE DESPLIEGUE COORDINADO
-- DE EDGE FUNCTIONS (ver README). No habilitar captura hasta completarlo.
BEGIN;

-- Identificaciones aisladas del bucket de vehículos (no heredan sus SELECT policies).
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES ('acceso-campo-identificaciones','acceso-campo-identificaciones',false,10485760,
 ARRAY['image/jpeg','image/png','image/webp']::text[])
ON CONFLICT (id) DO UPDATE SET public=false,file_size_limit=excluded.file_size_limit,
 allowed_mime_types=excluded.allowed_mime_types;

ALTER TABLE public.tournament_access_entries
 ADD COLUMN IF NOT EXISTS identificacion_foto_path text,
 ADD COLUMN IF NOT EXISTS viene_en_vehiculo boolean;
ALTER TABLE public.tournament_access_entries
 ADD CONSTRAINT access_444_identificacion_path_chk CHECK (
 identificacion_foto_path IS NULL OR
 (length(identificacion_foto_path) BETWEEN 1 AND 500));
ALTER TABLE public.tournament_access_entries
 ADD CONSTRAINT access_444_vehiculo_placa_chk CHECK (
 viene_en_vehiculo IS DISTINCT FROM false OR vehiculo_placa IS NULL);
COMMENT ON COLUMN public.tournament_access_entries.identificacion_foto_path IS
 'Ruta confidencial de identificación oficial, nunca incluir en reportes; solo consulta auditada mediante servicio.';

CREATE TABLE public.tournament_access_identity_upload_authorizations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 entry_id uuid NOT NULL REFERENCES public.tournament_access_entries(id) ON DELETE CASCADE,
 tournament_id uuid NOT NULL REFERENCES public.tournaments(id),
 assignment_id uuid NOT NULL REFERENCES public.tournament_access_point_assignments(id),
 storage_path text NOT NULL UNIQUE,
 expires_at timestamptz NOT NULL,
 consumed_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON public.tournament_access_identity_upload_authorizations(entry_id,created_at DESC);
ALTER TABLE public.tournament_access_identity_upload_authorizations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tournament_access_identity_upload_authorizations FROM PUBLIC,anon,authenticated;

-- Auditoría con instantáneas: no tiene FK a entradas, para sobrevivir a su purga.
CREATE TABLE public.tournament_access_audit_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tournament_id uuid NOT NULL REFERENCES public.tournaments(id),
 entry_id uuid,
 player_id uuid,
 actor_id uuid,
 actor_role text NOT NULL,
 event_type text NOT NULL,
 outcome text NOT NULL CHECK (outcome IN ('ALLOWED','DENIED','ERROR')),
 event_at timestamptz NOT NULL DEFAULT now(),
 context jsonb NOT NULL DEFAULT '{}'::jsonb,
 identity_purged_at timestamptz,
 CONSTRAINT access_444_audit_event_type_chk CHECK(length(event_type) BETWEEN 1 AND 100)
);
CREATE INDEX ON public.tournament_access_audit_events(tournament_id,event_at DESC);
CREATE INDEX ON public.tournament_access_audit_events(identity_purged_at) WHERE identity_purged_at IS NOT NULL;
ALTER TABLE public.tournament_access_audit_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tournament_access_audit_events FROM PUBLIC,anon,authenticated;

-- Función de control para INSERT Storage, sin SELECT/UPDATE/DELETE de imágenes por cliente.
CREATE OR REPLACE FUNCTION public._identity_upload_authorized_444(p_path text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='public','pg_temp' AS $$
 SELECT EXISTS(
  SELECT 1 FROM public.tournament_access_identity_upload_authorizations u
  JOIN public.tournament_access_entries e ON e.id=u.entry_id
  JOIN public.tournament_access_point_assignments a ON a.id=u.assignment_id
  JOIN public.tournaments t ON t.id=u.tournament_id
  WHERE u.storage_path=p_path AND u.consumed_at IS NULL AND u.expires_at>now()
    AND e.tournament_id=u.tournament_id AND e.assignment_id=u.assignment_id
    AND e.identificacion_foto_path IS NULL AND a.habilitado=true
    AND t.activo=true AND t.usar_control_acceso_qr=true
    AND t.estatus NOT IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo)
 );
$$;
REVOKE ALL ON FUNCTION public._identity_upload_authorized_444(text) FROM PUBLIC,authenticated;
GRANT EXECUTE ON FUNCTION public._identity_upload_authorized_444(text) TO anon;
CREATE POLICY access_identity_insert_444 ON storage.objects FOR INSERT TO anon,authenticated
WITH CHECK(bucket_id='acceso-campo-identificaciones' AND public._identity_upload_authorized_444(name));

-- Preparar fotografía: solo puerta válida, solo ingreso de esa puerta.
CREATE OR REPLACE FUNCTION public.preparar_identificacion_acceso_444(
 p_access_token text,p_entry_id uuid,p_extension text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public','pg_temp' AS $$
DECLARE v_a uuid;v_t uuid;v_path text;v_ext text;
BEGIN
 v_ext:=lower(btrim(coalesce(p_extension,'')));
 IF v_ext NOT IN ('jpg','jpeg','png','webp') THEN RAISE EXCEPTION 'Formato inválido.' USING errcode='22023'; END IF;
 SELECT a.id,a.tournament_id INTO v_a,v_t
 FROM public.tournament_access_point_credentials c
 JOIN public.tournament_access_point_assignments a ON a.id=c.assignment_id
 JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
 JOIN public.tournaments t ON t.id=a.tournament_id
 WHERE c.access_token=lower(btrim(coalesce(p_access_token,''))) AND c.activo
 AND a.habilitado AND ap.activo AND t.activo
 AND t.usar_control_acceso_qr
 AND t.estatus NOT IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo);
 IF v_a IS NULL OR NOT EXISTS(
 SELECT 1 FROM public.tournament_access_entries e WHERE e.id=p_entry_id
 AND e.assignment_id=v_a AND e.tournament_id=v_t AND e.identificacion_foto_path IS NULL
 ) THEN RAISE EXCEPTION 'Ingreso o puerta no autorizados.' USING errcode='42501'; END IF;
 v_path:=v_t::text||'/'||p_entry_id::text||'/'||gen_random_uuid()::text||'.'||CASE WHEN v_ext='jpeg' THEN 'jpg' ELSE v_ext END;
 UPDATE public.tournament_access_identity_upload_authorizations
 SET consumed_at=now() WHERE entry_id=p_entry_id AND consumed_at IS NULL;
 INSERT INTO public.tournament_access_identity_upload_authorizations(entry_id,tournament_id,assignment_id,storage_path,expires_at)
 VALUES(p_entry_id,v_t,v_a,v_path,now()+interval '10 minutes');
 RETURN jsonb_build_object('ok',true,'bucket','acceso-campo-identificaciones','path',v_path,'entryId',p_entry_id);
END;$$;
REVOKE ALL ON FUNCTION public.preparar_identificacion_acceso_444(text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.preparar_identificacion_acceso_444(text,uuid,text) TO anon,authenticated;

-- Confirmar identidad subida y datos de vehículo. Se rechaza sin objeto en Storage.
CREATE OR REPLACE FUNCTION public.confirmar_identificacion_acceso_444(
 p_access_token text,p_entry_id uuid,p_path text,p_viene_en_vehiculo boolean,p_placa text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public','storage','pg_temp' AS $$
DECLARE v_t uuid;v_a uuid;v_plate text;v_auth uuid;
BEGIN
 SELECT a.tournament_id,a.id INTO v_t,v_a FROM public.tournament_access_point_credentials c
 JOIN public.tournament_access_point_assignments a ON a.id=c.assignment_id
 JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
 JOIN public.tournaments t ON t.id=a.tournament_id
 WHERE c.access_token=lower(btrim(coalesce(p_access_token,''))) AND c.activo
 AND a.habilitado AND ap.activo AND t.activo
 AND t.usar_control_acceso_qr
 AND t.estatus NOT IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo);
 IF v_a IS NULL THEN RAISE EXCEPTION 'Puerta no autorizada.' USING errcode='42501'; END IF;
 IF p_viene_en_vehiculo IS NULL THEN RAISE EXCEPTION 'Debe indicar si viene en vehículo.' USING errcode='22023'; END IF;
 v_plate:=nullif(upper(btrim(coalesce(p_placa,''))), '');
 IF v_plate IS NOT NULL AND (NOT p_viene_en_vehiculo OR length(v_plate)>30) THEN
 RAISE EXCEPTION 'Placa inválida.' USING errcode='22023'; END IF;
 SELECT u.id INTO v_auth FROM public.tournament_access_identity_upload_authorizations u
 JOIN public.tournament_access_entries e ON e.id=u.entry_id
 WHERE u.entry_id=p_entry_id AND u.tournament_id=v_t AND u.assignment_id=v_a
 AND u.storage_path=p_path AND u.consumed_at IS NULL AND u.expires_at>now()
 AND e.identificacion_foto_path IS NULL AND e.tournament_id=v_t AND e.assignment_id=v_a
 FOR UPDATE OF u;
 IF v_auth IS NULL OR NOT EXISTS(SELECT 1 FROM storage.objects o
 WHERE o.bucket_id='acceso-campo-identificaciones' AND o.name=p_path) THEN
 RAISE EXCEPTION 'No existe una identificación cargada y autorizada.' USING errcode='22023'; END IF;
 UPDATE public.tournament_access_entries SET identificacion_foto_path=p_path,
 viene_en_vehiculo=p_viene_en_vehiculo,vehiculo_placa=v_plate
 WHERE id=p_entry_id AND identificacion_foto_path IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'Identificación ya confirmada.' USING errcode='23505'; END IF;
 UPDATE public.tournament_access_identity_upload_authorizations SET consumed_at=now() WHERE id=v_auth;
 RETURN jsonb_build_object('ok',true,'entryId',p_entry_id,'identityStored',true);
END;$$;
REVOKE ALL ON FUNCTION public.confirmar_identificacion_acceso_444(text,uuid,text,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.confirmar_identificacion_acceso_444(text,uuid,text,boolean,text) TO anon,authenticated;

-- Servicio de consulta: único punto de acceso a path. Registra permitido/denegado.
-- La Edge Function debe usar SERVICE_ROLE y autenticar el JWT del solicitante.
CREATE OR REPLACE FUNCTION public.autorizar_consulta_identificacion_444(
 p_actor_id uuid,p_entry_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public','pg_temp' AS $$
DECLARE v_e record;v_allowed boolean;v_role text;
BEGIN
 IF current_user NOT IN ('postgres','service_role') THEN RAISE EXCEPTION 'Solo servicio.' USING errcode='42501'; END IF;
 SELECT e.id,e.tournament_id,e.player_id,e.identificacion_foto_path
 INTO v_e FROM public.tournament_access_entries e WHERE e.id=p_entry_id;
 IF v_e.id IS NULL THEN RETURN jsonb_build_object('ok',false,'reason','ENTRY_NOT_FOUND'); END IF;
 v_allowed:=public.is_superadmin(p_actor_id) OR public.is_tournament_organizer(p_actor_id,v_e.tournament_id);
 v_role:=CASE WHEN public.is_superadmin(p_actor_id) THEN 'SUPERADMIN'
 WHEN v_allowed THEN 'ORGANIZADOR' ELSE 'DENIED' END;
 INSERT INTO public.tournament_access_audit_events(tournament_id,entry_id,player_id,actor_id,actor_role,event_type,outcome)
 VALUES(v_e.tournament_id,p_entry_id,v_e.player_id,p_actor_id,v_role,'IDENTITY_IMAGE_VIEW',
 CASE WHEN v_allowed AND v_e.identificacion_foto_path IS NOT NULL THEN 'ALLOWED' ELSE 'DENIED' END);
 IF NOT v_allowed OR v_e.identificacion_foto_path IS NULL THEN RETURN jsonb_build_object('ok',false,'reason','NOT_AUTHORIZED_OR_MISSING'); END IF;
 RETURN jsonb_build_object('ok',true,'bucket','acceso-campo-identificaciones','path',v_e.identificacion_foto_path);
END;$$;
REVOKE ALL ON FUNCTION public.autorizar_consulta_identificacion_444(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.autorizar_consulta_identificacion_444(uuid,uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.obtener_auditorias_acceso_444(p_tournament_id uuid DEFAULT NULL,p_limit integer DEFAULT 100)
RETURNS TABLE(id uuid,tournament_id uuid,entry_id uuid,player_id uuid,actor_id uuid,actor_role text,event_type text,outcome text,event_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='public','pg_temp' AS $$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'No autenticado.' USING errcode='42501'; END IF;
 IF p_tournament_id IS NULL AND NOT public.is_superadmin(auth.uid()) THEN
 RAISE EXCEPTION 'Seleccione un torneo.' USING errcode='42501'; END IF;
 IF p_tournament_id IS NOT NULL AND NOT (public.is_superadmin(auth.uid()) OR
 public.is_tournament_organizer(auth.uid(),p_tournament_id)) THEN
 RAISE EXCEPTION 'No autorizado.' USING errcode='42501'; END IF;
 RETURN QUERY SELECT a.id,a.tournament_id,a.entry_id,a.player_id,a.actor_id,
 a.actor_role,a.event_type,a.outcome,a.event_at FROM public.tournament_access_audit_events a
 WHERE (p_tournament_id IS NULL OR a.tournament_id=p_tournament_id)
 AND (public.is_superadmin(auth.uid()) OR public.is_tournament_organizer(auth.uid(),a.tournament_id))
 ORDER BY a.event_at DESC LIMIT greatest(1,least(coalesce(p_limit,100),500));
END;$$;
REVOKE ALL ON FUNCTION public.obtener_auditorias_acceso_444(uuid,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_auditorias_acceso_444(uuid,integer) TO authenticated;

-- Lote adicional: el Edge de purga debe borrar estas rutas EN SU BUCKET antes de confirmar 368.
CREATE OR REPLACE FUNCTION public.obtener_identificaciones_purga_444(p_tournament_id uuid)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path='public','pg_temp' AS $$
DECLARE v_paths text[];
BEGIN
 IF current_user NOT IN ('postgres','service_role') THEN RAISE EXCEPTION 'Solo servicio.' USING errcode='42501'; END IF;
 SELECT coalesce(array_agg(DISTINCT x.path),ARRAY[]::text[]) INTO v_paths FROM (
 SELECT identificacion_foto_path AS path FROM public.tournament_access_entries
 WHERE tournament_id=p_tournament_id AND identificacion_foto_path IS NOT NULL
 UNION
 SELECT storage_path FROM public.tournament_access_identity_upload_authorizations
 WHERE tournament_id=p_tournament_id
 ) x;
 RETURN v_paths;
END;$$;
REVOKE ALL ON FUNCTION public.obtener_identificaciones_purga_444(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_identificaciones_purga_444(uuid) TO service_role;

-- Bloqueo de confirmación si persisten objetos de identificación en Storage.
-- IMPORTANTE: La Edge debe borrar físicamente ambos buckets antes de invocar confirmar 368.
CREATE OR REPLACE FUNCTION public.confirmar_purga_acceso_368(p_tournament_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public','storage','pg_temp' AS $$
DECLARE v_events integer:=0;v_now timestamptz:=now();
BEGIN
 IF current_user NOT IN ('postgres','service_role') THEN RAISE EXCEPTION 'Solo servicio.' USING errcode='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tournament_access_storage_purge_queue
 WHERE tournament_id=p_tournament_id AND completed_at IS NULL) THEN
 RAISE EXCEPTION 'No existe purga pendiente.' USING errcode='22023'; END IF;
 IF EXISTS(SELECT 1 FROM storage.objects o WHERE o.bucket_id='acceso-campo-identificaciones'
 AND o.name LIKE p_tournament_id::text||'/%') THEN
 RAISE EXCEPTION 'Faltan fotografías de identificación por eliminar.' USING errcode='22023'; END IF;
 -- Proteger también las fotografías de vehículo, aunque el Edge ya debe eliminarlas.
 IF EXISTS(SELECT 1 FROM storage.objects o WHERE o.bucket_id='acceso-campo-vehiculos'
 AND o.name LIKE p_tournament_id::text||'/%') THEN
 RAISE EXCEPTION 'Faltan fotografías de vehículo por eliminar.' USING errcode='22023'; END IF;
 UPDATE public.tournament_access_audit_events SET identity_purged_at=v_now
 WHERE tournament_id=p_tournament_id AND identity_purged_at IS NULL;
 DELETE FROM public.tournament_access_entries WHERE tournament_id=p_tournament_id;
 GET DIAGNOSTICS v_events=ROW_COUNT;
 UPDATE public.tournament_access_retention SET purged_at=v_now,updated_at=v_now
 WHERE tournament_id=p_tournament_id AND purged_at IS NULL;
 UPDATE public.tournament_access_storage_purge_queue SET completed_at=v_now,
 processing_started_at=NULL,last_error=NULL,updated_at=v_now WHERE tournament_id=p_tournament_id;
 RETURN jsonb_build_object('ok',true,'tournamentId',p_tournament_id,'accessEntriesDeleted',v_events,'photosPurgedAt',v_now);
END;$$;
REVOKE ALL ON FUNCTION public.confirmar_purga_acceso_368(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.confirmar_purga_acceso_368(uuid) TO service_role;

-- Purga de auditorías: un mes calendario desde purga REAL confirmada.
-- Se llama desde cron diario existente 365 al ejecutar 364.
CREATE OR REPLACE FUNCTION public.purgar_auditorias_acceso_444()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='public','pg_temp' AS $$
DECLARE v_n integer;
BEGIN
 IF current_user NOT IN ('postgres','service_role') THEN RAISE EXCEPTION 'Solo servicio.' USING errcode='42501'; END IF;
 DELETE FROM public.tournament_access_audit_events a
 WHERE a.identity_purged_at IS NOT NULL
 AND a.identity_purged_at + interval '1 month' <= now();
 GET DIAGNOSTICS v_n=ROW_COUNT;
 RETURN v_n;
END;$$;
REVOKE ALL ON FUNCTION public.purgar_auditorias_acceso_444() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.purgar_auditorias_acceso_444() TO service_role;

-- No modificar 364; ejecutar limpieza de auditoría en el mismo cron 365.
-- Se incorpora segundo cron independiente, sin tocar el cron operativo de Storage.
SELECT cron.schedule('tee-central-purge-access-audits-444','35 6 * * *',
 'SELECT public.purgar_auditorias_acceso_444();');

COMMIT;
