-- 447-MIGRACION_ESTADOS_REPORTES_ACCESO.sql
-- TEE CENTRAL / GOLF IN FULL. Ejecutar MANUALMENTE en Supabase.
-- Ampliacion aditiva de JSON 361/366; auditoria ampliada por RPC nueva 447.
BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_reporte_acceso_torneo_366(p_tournament_id uuid,p_access_date date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_timezone text;v_date date;v_summary jsonb;v_rows jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT (public.is_superadmin(auth.uid()) OR public.is_tournament_organizer(auth.uid(),p_tournament_id)) THEN
  RAISE EXCEPTION 'No autorizado.' USING errcode='42501'; END IF;
 SELECT nullif(btrim(c.timezone_id),'') INTO v_timezone FROM public.tournaments t
 JOIN public.campos_golf c ON c.id=t.campo_golf_id WHERE t.id=p_tournament_id;
 IF v_timezone IS NULL THEN RAISE EXCEPTION 'El torneo no tiene zona horaria operativa válida.' USING errcode='22023'; END IF;
 v_date:=coalesce(p_access_date,(now() AT TIME ZONE v_timezone)::date);
 SELECT jsonb_build_object(
 'accessDate',v_date,
 'totalEntries',count(*) FILTER (WHERE e.estado_identificacion_445='COMPLETADO'),
 'uniquePlayers',count(DISTINCT e.player_id) FILTER (WHERE e.estado_identificacion_445='COMPLETADO'),
 'sameDayReuses',count(*) FILTER (WHERE e.reutilizado_mismo_dia AND e.estado_identificacion_445='COMPLETADO'),
 'accompaniedEntries',count(*) FILTER (WHERE e.viene_acompanado AND e.estado_identificacion_445='COMPLETADO'),
 'vehiclePhotos',count(*) FILTER (WHERE e.vehiculo_foto_path IS NOT NULL AND e.estado_identificacion_445='COMPLETADO'),
 'platesCaptured',count(*) FILTER (WHERE e.vehiculo_placa IS NOT NULL AND e.estado_identificacion_445='COMPLETADO'),
 'totalAttempts',count(*),
 'completedEntries',count(*) FILTER (WHERE e.estado_identificacion_445='COMPLETADO'),
 'pendingEntries',count(*) FILTER (WHERE e.estado_identificacion_445='PENDIENTE' AND e.entered_at>now()-interval '30 minutes'),
 'failedEntries',count(*) FILTER (WHERE e.estado_identificacion_445='FALLIDO' OR (e.estado_identificacion_445='PENDIENTE' AND e.entered_at<=now()-interval '30 minutes'))
 ) INTO v_summary FROM public.tournament_access_entries e WHERE e.tournament_id=p_tournament_id AND e.access_date=v_date;
 SELECT coalesce(jsonb_agg(z.obj ORDER BY z.entered_at DESC),'[]'::jsonb) INTO v_rows FROM (
 SELECT e.entered_at,jsonb_build_object(
 'entryId',e.id,'accessDate',e.access_date,'enteredAt',e.entered_at,
 'registrationId',e.registration_id,'playerId',e.player_id,
 'entryStatus',CASE WHEN e.estado_identificacion_445='PENDIENTE' AND e.entered_at<=now()-interval '30 minutes' THEN 'FALLIDO' ELSE e.estado_identificacion_445 END,
 'isEffectiveEntry',(e.estado_identificacion_445='COMPLETADO'),
 'player',jsonb_build_object('nombres',pl.nombres,'apellidos',pl.apellidos),
 'accessPoint',jsonb_build_object('assignmentId',e.assignment_id,'accessPointId',a.access_point_id,'nombre',a.alias_operativo,'nombreBase',ap.nombre,'responsableNombre',a.responsable_nombre),
 'qr',jsonb_build_object('useNumber',e.qr_uso_numero,'reused',e.qr_reutilizado,'sameDayReuse',e.reutilizado_mismo_dia,'reuseWarningConfirmed',e.advertencia_reutilizacion_confirmada),
 'identityConfirmed',e.identidad_confirmada,'accompanied',e.viene_acompanado,
 'vehicle',jsonb_build_object('hasPhoto',e.vehiculo_foto_path IS NOT NULL,'photoPath',e.vehiculo_foto_path,'plate',e.vehiculo_placa),
 'review',jsonb_build_object('required',e.reutilizado_mismo_dia,'level',CASE WHEN e.reutilizado_mismo_dia THEN 'REVIEW' ELSE 'NONE' END,'reason',CASE WHEN e.reutilizado_mismo_dia THEN 'QR reutilizado el mismo día. Revisar el registro; no implica por sí solo uso indebido.' ELSE NULL END)
 ) obj FROM public.tournament_access_entries e
 JOIN public.players pl ON pl.id=e.player_id
 JOIN public.tournament_access_point_assignments a ON a.id=e.assignment_id
 JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
 WHERE e.tournament_id=p_tournament_id AND e.access_date=v_date
 ) z;
 RETURN jsonb_build_object('ok',true,'tournamentId',p_tournament_id,'timezone',v_timezone,'summary',v_summary,'entries',v_rows);
END;$fn$;

CREATE OR REPLACE FUNCTION public.validar_qr_jugador_acceso_361(p_access_token text,p_player_qr_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE
 v_access_token text:=lower(btrim(coalesce(p_access_token,'')));
 v_player_token text:=lower(btrim(coalesce(p_player_qr_token,'')));
 v_a uuid;v_t uuid;v_ap uuid;v_apname text;v_resp text;v_tname text;v_start date;v_end date;v_tz text;v_date date;
 v_reg uuid;v_player uuid;v_folio text;v_names text;v_surnames text;
 v_total int;v_today int;v_total_completed int;v_today_completed int;v_today_pending int;v_today_failed int;
 v_last timestamptz;v_last_gate text;
BEGIN
 IF v_access_token !~ '^[0-9a-f]{64}$' OR v_player_token !~ '^[0-9a-f]{32}$' THEN
 RAISE EXCEPTION 'Código QR o puerta inválido.' USING errcode='22023'; END IF;
 SELECT a.id,a.tournament_id,a.access_point_id,a.alias_operativo,a.responsable_nombre,t.nombre,t.fecha_inicio,t.fecha_fin,cg.timezone_id
 INTO v_a,v_t,v_ap,v_apname,v_resp,v_tname,v_start,v_end,v_tz
 FROM public.tournament_access_point_credentials c
 JOIN public.tournament_access_point_assignments a ON a.id=c.assignment_id
 JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
 JOIN public.tournaments t ON t.id=a.tournament_id
 JOIN public.campos_golf cg ON cg.id=t.campo_golf_id
 WHERE c.access_token=v_access_token AND c.activo=true AND a.habilitado=true AND a.operativa_abierta=true AND a.retirado_at IS NULL
 AND ap.activo=true AND t.activo=true AND t.usar_control_acceso_qr=true
 AND t.estatus NOT IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo)
 AND public.acceso_campo_abierto_359(t.id)=true LIMIT 1;
 IF v_a IS NULL THEN RAISE EXCEPTION 'La puerta está cerrada/no disponible o el acceso general al campo aún no está abierto.' USING errcode='42501'; END IF;
 IF nullif(btrim(coalesce(v_tz,'')),'') IS NULL THEN RAISE EXCEPTION 'El campo del torneo no tiene zona horaria configurada.' USING errcode='55000'; END IF;
 v_date:=(now() AT TIME ZONE v_tz)::date;
 SELECT r.id,r.player_id,r.folio,pl.nombres,pl.apellidos INTO v_reg,v_player,v_folio,v_names,v_surnames
 FROM public.tournament_registrations r JOIN public.players pl ON pl.id=r.player_id
 WHERE lower(btrim(r.qr_token))=v_player_token AND r.tournament_id=v_t AND r.activo=true LIMIT 1;
 IF v_reg IS NULL THEN RAISE EXCEPTION 'El QR no corresponde a una inscripción activa de este torneo.' USING errcode='42501'; END IF;
 SELECT count(*)::int,count(*) FILTER (WHERE e.access_date=v_date)::int,
 count(*) FILTER (WHERE e.estado_identificacion_445='COMPLETADO')::int,
 count(*) FILTER (WHERE e.access_date=v_date AND e.estado_identificacion_445='COMPLETADO')::int,
 count(*) FILTER (WHERE e.access_date=v_date AND e.estado_identificacion_445='PENDIENTE' AND e.entered_at>now()-interval '30 minutes')::int,
 count(*) FILTER (WHERE e.access_date=v_date AND (e.estado_identificacion_445='FALLIDO' OR (e.estado_identificacion_445='PENDIENTE' AND e.entered_at<=now()-interval '30 minutes')))::int
 INTO v_total,v_today,v_total_completed,v_today_completed,v_today_pending,v_today_failed
 FROM public.tournament_access_entries e WHERE e.registration_id=v_reg;
 SELECT e.entered_at,a.alias_operativo INTO v_last,v_last_gate
 FROM public.tournament_access_entries e JOIN public.tournament_access_point_assignments a ON a.id=e.assignment_id
 WHERE e.registration_id=v_reg ORDER BY e.entered_at DESC LIMIT 1;
 RETURN jsonb_build_object('ok',true,'valid',true,
 'tournament',jsonb_build_object('id',v_t,'name',v_tname,'startDate',v_start,'endDate',v_end,'courseTimezone',v_tz),
 'accessDate',v_date,'registration',jsonb_build_object('id',v_reg,'folio',v_folio),
 'player',jsonb_build_object('id',v_player,'firstNames',v_names,'lastNames',v_surnames,'displayName',btrim(concat_ws(' ',v_names,v_surnames))),
 'accessPoint',jsonb_build_object('assignmentId',v_a,'id',v_ap,'name',v_apname,'responsibleName',v_resp),
 'accessHistory',jsonb_build_object(
 'priorEntries',v_total,'priorEntriesToday',v_today,'hasPriorEntries',v_total>0,'hasPriorEntryToday',v_today>0,
 'completedEntries',v_total_completed,'completedEntriesToday',v_today_completed,'pendingAttemptsToday',v_today_pending,'failedAttemptsToday',v_today_failed,
 'lastEntryAt',v_last,'lastAccessPoint',v_last_gate,
 'warningLevel',CASE WHEN v_today>0 THEN 'STRONG' WHEN v_total>0 THEN 'INFO' ELSE 'NONE' END,
 'warningMessage',CASE WHEN v_today>0 THEN 'QR UTILIZADO ANTERIORMENTE HOY — IDENTIFIQUE A LA PERSONA BAJO SU RESPONSABILIDAD'
 WHEN v_total>0 THEN 'Este QR tiene ingresos registrados en días anteriores del torneo.' ELSE NULL END),
 'instructions',jsonb_build_object('physicalIdRequired',true,'message','Solicite una identificación física y confirme que corresponde a la persona mostrada antes de registrar el ingreso.'));
END;$fn$;

-- La RPC 444 devuelve TABLE tipada. Se conserva intacta para no romper consumidores.
CREATE OR REPLACE FUNCTION public.obtener_auditorias_acceso_447(p_tournament_id uuid DEFAULT NULL,p_limit integer DEFAULT 100)
RETURNS TABLE(id uuid,tournament_id uuid,entry_id uuid,player_id uuid,actor_id uuid,actor_role text,event_type text,outcome text,event_at timestamptz,access_point_name text,access_point_id uuid,reason text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'No autenticado.' USING errcode='42501'; END IF;
 IF p_tournament_id IS NULL AND NOT public.is_superadmin(auth.uid()) THEN RAISE EXCEPTION 'Seleccione un torneo.' USING errcode='42501'; END IF;
 IF p_tournament_id IS NOT NULL AND NOT (public.is_superadmin(auth.uid()) OR public.is_tournament_organizer(auth.uid(),p_tournament_id)) THEN
 RAISE EXCEPTION 'No autorizado.' USING errcode='42501'; END IF;
 RETURN QUERY SELECT au.id,au.tournament_id,au.entry_id,au.player_id,au.actor_id,au.actor_role,au.event_type,au.outcome,au.event_at,
 coalesce(a.alias_operativo,ap.nombre)::text,ap.id,
 CASE WHEN au.event_type='ACCESS_ENTRY_FAILED' AND au.context->>'reason'='IDENTITY_NOT_CONFIRMED_30_MIN'
 THEN 'IDENTIFICACIÓN NO COMPLETADA EN 30 MINUTOS'
 ELSE nullif(au.context->>'reason','') END::text
 FROM public.tournament_access_audit_events au
 LEFT JOIN public.tournament_access_entries e ON e.id=au.entry_id AND e.tournament_id=au.tournament_id
 LEFT JOIN public.tournament_access_point_assignments a ON a.id=coalesce(e.assignment_id,
 CASE WHEN (au.context->>'assignmentId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN (au.context->>'assignmentId')::uuid ELSE NULL END)
 LEFT JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
 WHERE (p_tournament_id IS NULL OR au.tournament_id=p_tournament_id)
 AND (public.is_superadmin(auth.uid()) OR public.is_tournament_organizer(auth.uid(),au.tournament_id))
 ORDER BY au.event_at DESC LIMIT greatest(1,least(coalesce(p_limit,100),500));
END;$fn$;
REVOKE ALL ON FUNCTION public.obtener_auditorias_acceso_447(uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.obtener_auditorias_acceso_447(uuid,integer) TO authenticated,service_role;
COMMIT;
