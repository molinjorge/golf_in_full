-- 445-MIGRACION_RECUPERACION_INGRESOS_INCOMPLETOS
-- VERSION FINAL PROPUESTA: vencimiento automatico, auditoria, recuperacion por puerta.
-- EJECUCION MANUAL EXCLUSIVA DEL USUARIO. No ejecutada por ChatGPT.
BEGIN;

ALTER TABLE public.tournament_access_entries
 ADD COLUMN IF NOT EXISTS estado_identificacion_445 text;

-- Los registros previos a 445 con fotografia se consideran completos.
UPDATE public.tournament_access_entries
SET estado_identificacion_445 = CASE
 WHEN identificacion_foto_path IS NOT NULL THEN 'COMPLETADO'
 WHEN entered_at <= now() - interval '30 minutes' THEN 'FALLIDO'
 ELSE 'PENDIENTE' END
WHERE estado_identificacion_445 IS NULL;

ALTER TABLE public.tournament_access_entries
 ALTER COLUMN estado_identificacion_445 SET DEFAULT 'PENDIENTE',
 ALTER COLUMN estado_identificacion_445 SET NOT NULL;

ALTER TABLE public.tournament_access_entries
 ADD CONSTRAINT tournament_access_entries_estado_445_chk
 CHECK (estado_identificacion_445 IN ('PENDIENTE','COMPLETADO','FALLIDO'));

-- Invariante en BD: ninguna confirmacion puede completar un registro vencido.
-- La confirmacion 444 actualiza identificacion_foto_path, por lo que este trigger
-- cubre tanto llamadas a la RPC como actualizaciones directas.
CREATE OR REPLACE FUNCTION public.proteger_estado_ingreso_445()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $fn$
BEGIN
 IF TG_OP='INSERT' THEN
   IF NEW.identificacion_foto_path IS NOT NULL THEN
     NEW.estado_identificacion_445 := 'COMPLETADO';
   ELSE
     NEW.estado_identificacion_445 := 'PENDIENTE';
   END IF;
   RETURN NEW;
 END IF;
 IF OLD.estado_identificacion_445='FALLIDO' AND
    (NEW.identificacion_foto_path IS DISTINCT FROM OLD.identificacion_foto_path OR
     NEW.estado_identificacion_445 IS DISTINCT FROM OLD.estado_identificacion_445) THEN
    RAISE EXCEPTION 'Ingreso fallido: debe registrar un nuevo ingreso.' USING errcode='22023';
 END IF;
 IF OLD.identificacion_foto_path IS NULL AND NEW.identificacion_foto_path IS NOT NULL THEN
    IF OLD.entered_at <= now() - interval '30 minutes' THEN
      RAISE EXCEPTION 'Ingreso vencido: debe registrar un nuevo ingreso.' USING errcode='22023';
    END IF;
    NEW.estado_identificacion_445 := 'COMPLETADO';
 END IF;
 IF OLD.identificacion_foto_path IS NOT NULL AND NEW.identificacion_foto_path IS NULL THEN
    RAISE EXCEPTION 'No se permite retirar una identificacion confirmada.' USING errcode='22023';
 END IF;
 RETURN NEW;
END;$fn$;
DROP TRIGGER IF EXISTS trg_proteger_estado_ingreso_445 ON public.tournament_access_entries;
CREATE TRIGGER trg_proteger_estado_ingreso_445
BEFORE INSERT OR UPDATE OF identificacion_foto_path,estado_identificacion_445
ON public.tournament_access_entries FOR EACH ROW
EXECUTE FUNCTION public.proteger_estado_ingreso_445();

CREATE UNIQUE INDEX IF NOT EXISTS access_audit_failed_once_445
ON public.tournament_access_audit_events(entry_id)
WHERE event_type='ACCESS_ENTRY_FAILED' AND entry_id IS NOT NULL;

-- Procesa lotes acotados, bloquea filas para no competir con confirmacion.
CREATE OR REPLACE FUNCTION public.marcar_ingresos_fallidos_445(p_limit integer DEFAULT 500)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_n integer;
BEGIN
 IF current_user NOT IN ('postgres','service_role') THEN
   RAISE EXCEPTION 'Solo servicio.' USING errcode='42501';
 END IF;
 WITH vencidos AS (
   SELECT e.id FROM public.tournament_access_entries e
   WHERE e.estado_identificacion_445='PENDIENTE'
     AND e.identificacion_foto_path IS NULL
     AND e.entered_at <= now()-interval '30 minutes'
   ORDER BY e.entered_at,e.id
   LIMIT greatest(1,least(coalesce(p_limit,500),5000))
   FOR UPDATE SKIP LOCKED
 ), marcados AS (
   UPDATE public.tournament_access_entries e
   SET estado_identificacion_445='FALLIDO'
   FROM vencidos v WHERE e.id=v.id
   RETURNING e.id,e.tournament_id,e.player_id,e.entered_at,e.assignment_id
 ), eventos AS (
   INSERT INTO public.tournament_access_audit_events
     (tournament_id,entry_id,player_id,actor_id,actor_role,event_type,outcome,event_at,context)
   SELECT m.tournament_id,m.id,m.player_id,NULL,'SYSTEM',
          'ACCESS_ENTRY_FAILED','ERROR',now(),
          jsonb_build_object('reason','IDENTITY_NOT_CONFIRMED_30_MIN',
                             'originalEnteredAt',m.entered_at,'assignmentId',m.assignment_id)
   FROM marcados m
   ON CONFLICT DO NOTHING
   RETURNING id
 )
 SELECT count(*)::integer INTO v_n FROM marcados;
 RETURN v_n;
END;$fn$;
REVOKE ALL ON FUNCTION public.marcar_ingresos_fallidos_445(integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marcar_ingresos_fallidos_445(integer) TO service_role;

-- Backfill de auditoria de vencidos anteriores a la migracion, sin duplicados.
INSERT INTO public.tournament_access_audit_events
 (tournament_id,entry_id,player_id,actor_id,actor_role,event_type,outcome,event_at,context)
SELECT e.tournament_id,e.id,e.player_id,NULL,'SYSTEM','ACCESS_ENTRY_FAILED','ERROR',now(),
 jsonb_build_object('reason','IDENTITY_NOT_CONFIRMED_30_MIN','originalEnteredAt',e.entered_at,'assignmentId',e.assignment_id)
FROM public.tournament_access_entries e
WHERE e.estado_identificacion_445='FALLIDO'
ON CONFLICT DO NOTHING;

CREATE OR REPLACE VIEW public.tournament_access_entries_operational_445
WITH (security_invoker=true) AS
SELECT e.id,e.tournament_id,e.assignment_id,e.registration_id,e.player_id,
 e.access_date,e.entered_at,e.qr_uso_numero,e.viene_acompanado,
 e.viene_en_vehiculo,e.vehiculo_placa,
 CASE WHEN e.estado_identificacion_445='PENDIENTE' AND
           e.entered_at <= now()-interval '30 minutes' THEN 'FALLIDO'
      ELSE e.estado_identificacion_445 END::text AS estado_operativo
FROM public.tournament_access_entries e;
REVOKE ALL ON public.tournament_access_entries_operational_445 FROM PUBLIC,anon;
GRANT SELECT ON public.tournament_access_entries_operational_445 TO authenticated;

CREATE OR REPLACE FUNCTION public.registrar_o_recuperar_ingreso_acceso_445(
    p_access_token text,
    p_player_qr_token text,
    p_identidad_confirmada boolean,
    p_advertencia_reutilizacion_confirmada boolean DEFAULT false,
    p_viene_acompanado boolean DEFAULT false,
    p_confirmar_nuevo_ingreso_con_pendiente boolean DEFAULT false,
    p_es_reingreso_nuevo boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_access_token text := lower(btrim(coalesce(p_access_token,'')));
    v_player_token text := lower(btrim(coalesce(p_player_qr_token,'')));
    v_assignment_id uuid;
    v_tournament_id uuid;
    v_registration_id uuid;
    v_timezone text;
    v_access_date date;
    v_pending record;
    v_other_pending boolean;
    v_stale_same_pending boolean;
    v_result jsonb;
BEGIN
    IF p_identidad_confirmada IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Debe confirmar visualmente la identidad del jugador.' USING errcode='22023';
    END IF;
    IF v_access_token !~ '^[0-9a-f]{64}$' OR v_player_token !~ '^[0-9a-f]{32}$' THEN
        RAISE EXCEPTION 'QR o vínculo de acceso inválido.' USING errcode='22023';
    END IF;

    SELECT a.id, a.tournament_id, cg.timezone_id
      INTO v_assignment_id, v_tournament_id, v_timezone
      FROM public.tournament_access_point_credentials c
      JOIN public.tournament_access_point_assignments a ON a.id=c.assignment_id
      JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
      JOIN public.tournaments t ON t.id=a.tournament_id
      JOIN public.campos_golf cg ON cg.id=t.campo_golf_id
     WHERE c.access_token=v_access_token AND c.activo=true
       AND a.habilitado=true AND a.operativa_abierta=true AND a.retirado_at IS NULL
       AND ap.activo=true AND t.activo=true AND t.usar_control_acceso_qr=true
       AND t.estatus NOT IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo)
       AND public.acceso_campo_abierto_359(t.id)=true
     LIMIT 1;
    IF v_assignment_id IS NULL THEN
        RAISE EXCEPTION 'Punto de acceso no autorizado o cerrado.' USING errcode='42501';
    END IF;

    SELECT r.id INTO v_registration_id
      FROM public.tournament_registrations r
     WHERE lower(btrim(r.qr_token))=v_player_token
       AND r.tournament_id=v_tournament_id AND r.activo=true
     LIMIT 1;
    IF v_registration_id IS NULL THEN
        RAISE EXCEPTION 'QR del jugador no válido para este torneo.' USING errcode='42501';
    END IF;

    -- Serialización entre puertas para la misma inscripción. El frontend
    -- debe usar exclusivamente 445; las llamadas antiguas a 362 no participan.
    PERFORM pg_advisory_xact_lock(hashtextextended(v_registration_id::text,445));
    -- Cerrar primero vencidos del jugador: no son recuperables ni válidos.
    -- El cron cierra vencidos; las validaciones usan además el reloj en tiempo real.
    v_access_date := (now() AT TIME ZONE v_timezone)::date;

    -- Recuperación únicamente en la misma puerta, el mismo día y durante
    -- los primeros 30 minutos. No exponer datos de otras puertas.
    SELECT e.id, e.entered_at, e.qr_uso_numero, e.qr_reutilizado,
           e.reutilizado_mismo_dia, e.viene_acompanado
      INTO v_pending
      FROM public.tournament_access_entries e
     WHERE e.registration_id=v_registration_id
       AND e.assignment_id=v_assignment_id
       AND e.access_date=v_access_date
       AND e.identificacion_foto_path IS NULL
       AND e.estado_identificacion_445 = 'PENDIENTE'
       AND e.entered_at > now() - interval '30 minutes'
     ORDER BY e.entered_at DESC, e.id DESC LIMIT 1;

    IF v_pending.id IS NOT NULL AND p_es_reingreso_nuevo IS DISTINCT FROM true THEN
        RETURN jsonb_build_object(
          'ok',true,'action','RECOVER','entryId',v_pending.id,
          'accessDate',v_access_date,'enteredAt',v_pending.entered_at,
          'qrUseNumber',v_pending.qr_uso_numero,
          'qrReused',v_pending.qr_reutilizado,
          'reusedSameDay',v_pending.reutilizado_mismo_dia,
          'accompanied',v_pending.viene_acompanado,
          'recovered',true,'identityStored',false
        );
    END IF;

    SELECT EXISTS (
      SELECT 1 FROM public.tournament_access_entries e
       WHERE e.registration_id=v_registration_id
         AND e.access_date=v_access_date
         AND e.identificacion_foto_path IS NULL
         AND e.estado_identificacion_445 = 'PENDIENTE'
         AND e.entered_at > now() - interval '30 minutes'
         AND e.assignment_id<>v_assignment_id
    ) INTO v_other_pending;

    SELECT EXISTS (
      SELECT 1 FROM public.tournament_access_entries e
       WHERE e.registration_id=v_registration_id
         AND e.access_date=v_access_date
         AND e.identificacion_foto_path IS NULL
         AND (e.estado_identificacion_445 = 'FALLIDO' OR e.entered_at <= now() - interval '30 minutes')
         AND e.assignment_id=v_assignment_id
    ) INTO v_stale_same_pending;

    IF (v_other_pending OR v_stale_same_pending OR (v_pending.id IS NOT NULL AND p_es_reingreso_nuevo=true))
       AND p_confirmar_nuevo_ingreso_con_pendiente IS DISTINCT FROM true THEN
        -- Advertencia genérica, sin puerta, ID ni datos del registro pendiente.
        RETURN jsonb_build_object(
          'ok',false,'action','CONFIRM_NEW_ENTRY',
          'reason','PENDING_ENTRY_EXISTS',
          'message','Existe un registro de ingreso incompleto. Confirme que se trata de un nuevo ingreso y capture una nueva identificación.'
        );
    END IF;

    -- 362 mantiene sus validaciones y advertencia de QR reutilizado.
    -- Los registros pendientes antiguos permanecen pendientes; nunca se
    -- completan ni modifican desde otra puerta.
    v_result := public.registrar_ingreso_acceso_362(
      v_access_token,v_player_token,p_identidad_confirmada,
      p_advertencia_reutilizacion_confirmada,p_viene_acompanado
    );
    RETURN v_result || jsonb_build_object(
      'action','CREATED','recovered',false,'identityStored',false,
      'previousPendingExists',v_other_pending OR v_stale_same_pending OR v_pending.id IS NOT NULL
    );
END;
$function$;

-- Cron por minuto. Las fallas son visibles en cron.job_run_details.
SELECT cron.schedule('tee-central-failed-access-445','* * * * *',
 $$SELECT public.marcar_ingresos_fallidos_445(5000);$$);

-- Retirar firmas preliminares, si existieran.
DROP FUNCTION IF EXISTS public.registrar_o_recuperar_ingreso_acceso_445(text,text,boolean,boolean,boolean);
DROP FUNCTION IF EXISTS public.registrar_o_recuperar_ingreso_acceso_445(text,text,boolean,boolean,boolean,boolean);
REVOKE ALL ON FUNCTION public.registrar_o_recuperar_ingreso_acceso_445(text,text,boolean,boolean,boolean,boolean,boolean) FROM PUBLIC,authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_o_recuperar_ingreso_acceso_445(text,text,boolean,boolean,boolean,boolean,boolean) TO anon,service_role;
COMMIT;
