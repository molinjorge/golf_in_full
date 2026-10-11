-- 446-MIGRACION_VALIDACION_IDENTIFICACION_30_MINUTOS.sql
-- TEE CENTRAL / ACCESO AL CAMPO
-- EJECUCION MANUAL POR EL USUARIO EN SUPABASE. No ejecutar desde Lovable.
-- Refuerza validaciones de 444; preserva trigger y cron 445.
BEGIN;

CREATE OR REPLACE FUNCTION public.preparar_identificacion_acceso_444(
 p_access_token text,p_entry_id uuid,p_extension text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_a uuid;v_t uuid;v_path text;v_ext text;v_entry record;
BEGIN
 v_ext:=lower(btrim(coalesce(p_extension,'')));
 IF v_ext NOT IN ('jpg','jpeg','png','webp') THEN
   RAISE EXCEPTION 'Formato inválido.' USING errcode='22023';
 END IF;
 SELECT a.id,a.tournament_id INTO v_a,v_t
 FROM public.tournament_access_point_credentials c
 JOIN public.tournament_access_point_assignments a ON a.id=c.assignment_id
 JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
 JOIN public.tournaments t ON t.id=a.tournament_id
 WHERE c.access_token=lower(btrim(coalesce(p_access_token,''))) AND c.activo
 AND a.habilitado AND a.operativa_abierta AND a.retirado_at IS NULL
 AND ap.activo AND t.activo AND t.usar_control_acceso_qr
 AND t.estatus NOT IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo)
 AND public.acceso_campo_abierto_359(t.id)=true;
 IF v_a IS NULL THEN
   RAISE EXCEPTION 'Puerta no autorizada o cerrada.' USING errcode='42501';
 END IF;
 SELECT e.id,e.entered_at,e.estado_identificacion_445,e.identificacion_foto_path
 INTO v_entry FROM public.tournament_access_entries e
 WHERE e.id=p_entry_id AND e.assignment_id=v_a AND e.tournament_id=v_t
 FOR UPDATE;
 IF v_entry.id IS NULL THEN
   RAISE EXCEPTION 'Ingreso o puerta no autorizados.' USING errcode='42501';
 END IF;
 IF v_entry.estado_identificacion_445 IS DISTINCT FROM 'PENDIENTE'
    OR v_entry.identificacion_foto_path IS NOT NULL
    OR v_entry.entered_at <= now()-interval '30 minutes' THEN
   RAISE EXCEPTION 'Ingreso vencido, fallido o completado. Si desea ingresar nuevamente, registre un nuevo ingreso.' USING errcode='22023';
 END IF;
 v_path:=v_t::text||'/'||p_entry_id::text||'/'||gen_random_uuid()::text||'.'||CASE WHEN v_ext='jpeg' THEN 'jpg' ELSE v_ext END;
 UPDATE public.tournament_access_identity_upload_authorizations
 SET consumed_at=now() WHERE entry_id=p_entry_id AND consumed_at IS NULL;
 INSERT INTO public.tournament_access_identity_upload_authorizations(entry_id,tournament_id,assignment_id,storage_path,expires_at)
 VALUES(p_entry_id,v_t,v_a,v_path,least(now()+interval '10 minutes',v_entry.entered_at+interval '30 minutes'));
 RETURN jsonb_build_object('ok',true,'bucket','acceso-campo-identificaciones','path',v_path,'entryId',p_entry_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.confirmar_identificacion_acceso_444(
 p_access_token text,p_entry_id uuid,p_path text,p_viene_en_vehiculo boolean,p_placa text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','storage','pg_temp'
AS $function$
DECLARE v_t uuid;v_a uuid;v_plate text;v_auth uuid;v_entry record;
BEGIN
 SELECT a.tournament_id,a.id INTO v_t,v_a
 FROM public.tournament_access_point_credentials c
 JOIN public.tournament_access_point_assignments a ON a.id=c.assignment_id
 JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
 JOIN public.tournaments t ON t.id=a.tournament_id
 WHERE c.access_token=lower(btrim(coalesce(p_access_token,''))) AND c.activo
 AND a.habilitado AND a.operativa_abierta AND a.retirado_at IS NULL
 AND ap.activo AND t.activo AND t.usar_control_acceso_qr
 AND t.estatus NOT IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo)
 AND public.acceso_campo_abierto_359(t.id)=true;
 IF v_a IS NULL THEN RAISE EXCEPTION 'Puerta no autorizada o cerrada.' USING errcode='42501'; END IF;
 IF p_viene_en_vehiculo IS NULL THEN RAISE EXCEPTION 'Debe indicar si viene en vehículo.' USING errcode='22023'; END IF;
 v_plate:=nullif(upper(btrim(coalesce(p_placa,''))), '');
 IF v_plate IS NOT NULL AND (NOT p_viene_en_vehiculo OR length(v_plate)>30) THEN
   RAISE EXCEPTION 'Placa inválida.' USING errcode='22023'; END IF;
 -- Bloqueo de fila: coordina confirmación con cron 445 y evita carreras.
 SELECT e.id,e.entered_at,e.estado_identificacion_445,e.identificacion_foto_path
 INTO v_entry FROM public.tournament_access_entries e
 WHERE e.id=p_entry_id AND e.tournament_id=v_t AND e.assignment_id=v_a
 FOR UPDATE;
 IF v_entry.id IS NULL THEN RAISE EXCEPTION 'Ingreso o puerta no autorizados.' USING errcode='42501'; END IF;
 IF v_entry.estado_identificacion_445 IS DISTINCT FROM 'PENDIENTE'
    OR v_entry.identificacion_foto_path IS NOT NULL
    OR v_entry.entered_at <= now()-interval '30 minutes' THEN
   RAISE EXCEPTION 'Ingreso vencido, fallido o completado. Debe registrar un nuevo ingreso si desea volver a entrar.' USING errcode='22023';
 END IF;
 SELECT u.id INTO v_auth FROM public.tournament_access_identity_upload_authorizations u
 WHERE u.entry_id=p_entry_id AND u.tournament_id=v_t AND u.assignment_id=v_a
 AND u.storage_path=p_path AND u.consumed_at IS NULL AND u.expires_at>now()
 FOR UPDATE OF u;
 IF v_auth IS NULL OR NOT EXISTS(SELECT 1 FROM storage.objects o
 WHERE o.bucket_id='acceso-campo-identificaciones' AND o.name=p_path) THEN
   RAISE EXCEPTION 'No existe una identificación cargada y autorizada.' USING errcode='22023'; END IF;
 UPDATE public.tournament_access_entries SET identificacion_foto_path=p_path,
 viene_en_vehiculo=p_viene_en_vehiculo,vehiculo_placa=v_plate
 WHERE id=p_entry_id AND estado_identificacion_445='PENDIENTE'
 AND identificacion_foto_path IS NULL AND entered_at>now()-interval '30 minutes';
 IF NOT FOUND THEN RAISE EXCEPTION 'Ingreso no disponible para confirmar.' USING errcode='22023'; END IF;
 UPDATE public.tournament_access_identity_upload_authorizations SET consumed_at=now() WHERE id=v_auth;
 RETURN jsonb_build_object('ok',true,'entryId',p_entry_id,'identityStored',true);
END;
$function$;
COMMIT;
