-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 254 — Franjas de handicap: validacion ordenada + requisito formal
BEGIN;

CREATE OR REPLACE FUNCTION public.validar_franjas_handicap_torneo(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_total int; v_open int; v_err jsonb := '[]'::jsonb;
  r record; prev_desde numeric; prev_hasta numeric; expected numeric;
BEGIN
  IF p_tournament_id IS NULL OR NOT EXISTS
    (SELECT 1 FROM public.tournaments WHERE id=p_tournament_id) THEN
    RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='22023';
  END IF;

  SELECT count(*)::int, count(*) FILTER (WHERE handicap_hasta IS NULL)::int
    INTO v_total,v_open
  FROM public.tournament_franjas_handicap WHERE tournament_id=p_tournament_id;

  IF v_total=0 THEN
    RETURN jsonb_build_object('valid',false,'configured',false,'totalRanges',0,
      'openRanges',0,'errors',jsonb_build_array(
      'Faltan definir las franjas de hándicap del torneo.'));
  END IF;

  IF v_open>1 THEN
    v_err:=v_err||jsonb_build_array(
      'Sólo puede existir una franja de hándicap sin tope superior ("y más").');
  END IF;

  FOR r IN
    SELECT id,handicap_desde,handicap_hasta,categoria_estandar
    FROM public.tournament_franjas_handicap
    WHERE tournament_id=p_tournament_id
    ORDER BY handicap_desde ASC, handicap_hasta ASC NULLS LAST, id
  LOOP
    IF r.handicap_hasta IS NOT NULL AND r.handicap_desde>r.handicap_hasta THEN
      v_err:=v_err||jsonb_build_array(format(
        'Rango inválido: la franja que inicia en %s termina en %s.',
        r.handicap_desde,r.handicap_hasta));
    END IF;

    IF prev_desde IS NOT NULL THEN
      IF prev_hasta IS NULL THEN
        v_err:=v_err||jsonb_build_array(format(
          'La franja abierta que inicia en %s debe ser la última al ordenar las franjas por hándicap.',
          prev_desde));
      ELSE
        expected:=round(prev_hasta+0.1,1);
        IF r.handicap_desde>expected THEN
          v_err:=v_err||jsonb_build_array(format(
            'Hueco detectado: una franja termina en %s y la siguiente inicia en %s; debe iniciar en %s.',
            prev_hasta,r.handicap_desde,expected));
        ELSIF r.handicap_desde<expected THEN
          v_err:=v_err||jsonb_build_array(format(
            'Traslape detectado: una franja termina en %s y la siguiente inicia en %s; debe iniciar en %s.',
            prev_hasta,r.handicap_desde,expected));
        END IF;
      END IF;
    END IF;
    prev_desde:=r.handicap_desde; prev_hasta:=r.handicap_hasta;
  END LOOP;

  RETURN jsonb_build_object('valid',jsonb_array_length(v_err)=0,'configured',true,
    'totalRanges',v_total,'openRanges',v_open,'errors',v_err);
END $$;
REVOKE ALL ON FUNCTION public.validar_franjas_handicap_torneo(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.validar_franjas_handicap_torneo(uuid)
TO authenticated,service_role;

-- Edicion: ya no exige orden ascendente. Bloquea solo invalidez objetiva.
CREATE OR REPLACE FUNCTION public.validar_franja_handicap_continua()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public','pg_temp'
AS $$
DECLARE c record;
BEGIN
  IF NEW.handicap_hasta IS NOT NULL AND NEW.handicap_desde>NEW.handicap_hasta THEN
    RAISE EXCEPTION 'Rango inválido: el hándicap desde (%) no puede ser mayor que el hándicap hasta (%).',
      NEW.handicap_desde,NEW.handicap_hasta USING ERRCODE='23514';
  END IF;

  IF NEW.handicap_hasta IS NULL AND EXISTS(
    SELECT 1 FROM public.tournament_franjas_handicap f
    WHERE f.tournament_id=NEW.tournament_id
      AND f.id<>COALESCE(NEW.id,'00000000-0000-0000-0000-000000000000'::uuid)
      AND f.handicap_hasta IS NULL) THEN
    RAISE EXCEPTION 'Ya existe una franja sin tope superior ("y más") para este torneo.'
      USING ERRCODE='23514';
  END IF;

  SELECT f.handicap_desde,f.handicap_hasta INTO c
  FROM public.tournament_franjas_handicap f
  WHERE f.tournament_id=NEW.tournament_id
    AND f.id<>COALESCE(NEW.id,'00000000-0000-0000-0000-000000000000'::uuid)
    AND (NEW.handicap_hasta IS NULL OR f.handicap_desde<=NEW.handicap_hasta)
    AND (f.handicap_hasta IS NULL OR NEW.handicap_desde<=f.handicap_hasta)
  ORDER BY f.handicap_desde LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Traslape detectado: la franja % - % entra en conflicto con una franja existente % - %.',
      NEW.handicap_desde,COALESCE(NEW.handicap_hasta::text,'y más'),
      c.handicap_desde,COALESCE(c.handicap_hasta::text,'y más') USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;

-- Preserva validaciones pre-254 y agrega franjas.
CREATE OR REPLACE FUNCTION public.validar_configuracion_minima_torneo(p_tournament_id uuid)
RETURNS TABLE(listo boolean,errores jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
 v_t public.tournaments%ROWTYPE; vr int; vra int; vc int; vsc int; suma bigint;
 e jsonb:='[]'::jsonb; f jsonb;
BEGIN
 SELECT * INTO v_t FROM public.tournaments WHERE id=p_tournament_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='22023'; END IF;
 SELECT count(*),count(*) FILTER(WHERE activo=true) INTO vr,vra
 FROM public.tournament_rounds WHERE tournament_id=p_tournament_id;
 SELECT count(*),count(*) FILTER(WHERE cupo_maximo IS NULL OR cupo_maximo<=0),
        COALESCE(sum(cupo_maximo),0)
 INTO vc,vsc,suma FROM public.tournament_categories WHERE tournament_id=p_tournament_id;

 IF v_t.club_id IS NULL THEN e:=e||jsonb_build_array('Falta asignar club.'); END IF;
 IF v_t.campo_golf_id IS NULL THEN e:=e||jsonb_build_array('Falta asignar campo de golf.'); END IF;
 IF v_t.tournament_format_id IS NULL THEN e:=e||jsonb_build_array('Falta asignar modalidad/formato del torneo.'); END IF;
 IF v_t.cupo_maximo IS NULL OR v_t.cupo_maximo<=0 THEN e:=e||jsonb_build_array('El cupo máximo debe ser mayor que cero.'); END IF;
 IF v_t.numero_rondas IS NULL OR v_t.numero_rondas<=0 THEN e:=e||jsonb_build_array('El número de rondas debe ser mayor que cero.'); END IF;
 IF vra<>v_t.numero_rondas THEN e:=e||jsonb_build_array(format(
   'Debe haber %s ronda(s) activa(s) configurada(s); actualmente hay %s.',v_t.numero_rondas,vra)); END IF;
 IF vc<=0 THEN e:=e||jsonb_build_array('El torneo no tiene categorías configuradas.');
 ELSE
   IF vsc>0 THEN e:=e||jsonb_build_array(format(
     'Todas las categorías deben tener un cupo máximo mayor que cero. Hay %s categoría(s) sin cupo válido.',vsc)); END IF;
   IF v_t.cupo_maximo IS NOT NULL AND v_t.cupo_maximo>0 AND suma<>v_t.cupo_maximo THEN
     e:=e||jsonb_build_array(format(
       'La suma de los cupos de las categorías (%s) debe ser igual al cupo máximo del torneo (%s).',suma,v_t.cupo_maximo));
   END IF;
 END IF;

 f:=public.validar_franjas_handicap_torneo(p_tournament_id);
 IF NOT COALESCE((f->>'valid')::boolean,false) THEN e:=e||COALESCE(f->'errors','[]'::jsonb); END IF;
 RETURN QUERY SELECT jsonb_array_length(e)=0,e;
END $$;

-- Defensa adicional al abrir inscripciones.
CREATE OR REPLACE FUNCTION public.abrir_inscripciones_torneo(p_tournament_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_t public.tournaments%ROWTYPE; f jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501'; END IF;
 IF NOT(public.is_superadmin(auth.uid()) OR public.is_tournament_organizer(auth.uid(),p_tournament_id))
 THEN RAISE EXCEPTION 'Sólo el organizador asignado o el Superadmin pueden abrir inscripciones.' USING ERRCODE='42501'; END IF;
 SELECT * INTO v_t FROM public.tournaments WHERE id=p_tournament_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='22023'; END IF;
 IF v_t.estatus='inscripciones_abiertas'::public.estatus_torneo THEN
   RETURN jsonb_build_object('ok',true,'tournamentId',p_tournament_id,'alreadyOpen',true,'estatus',v_t.estatus::text);
 END IF;
 IF v_t.estatus<>'planificado'::public.estatus_torneo THEN
   RAISE EXCEPTION 'Las inscripciones sólo pueden abrirse desde EN PLANIFICACIÓN. Estado actual: %.',v_t.estatus USING ERRCODE='23514'; END IF;
 IF v_t.configuracion_finalizada_at IS NULL OR v_t.configuracion_finalizada_por IS NULL THEN
   RAISE EXCEPTION 'No se pueden abrir inscripciones: la configuración del torneo aún no está finalizada.' USING ERRCODE='23514'; END IF;

 f:=public.validar_franjas_handicap_torneo(p_tournament_id);
 IF NOT COALESCE((f->>'valid')::boolean,false) THEN
   RAISE EXCEPTION 'No se pueden abrir inscripciones: las franjas de hándicap faltan o son inválidas. %',
     COALESCE((f->'errors')::text,'[]') USING ERRCODE='23514';
 END IF;

 IF v_t.estado_servicio<>'activo'::public.estado_servicio_torneo OR v_t.activo IS DISTINCT FROM true THEN
   RAISE EXCEPTION 'No se pueden abrir inscripciones: el torneo todavía no está liberado/activo en TEE CENTRAL.'
   USING ERRCODE='23514',DETAIL=format('estado_servicio=%s; activo=%s',v_t.estado_servicio,v_t.activo); END IF;
 PERFORM set_config('app.permitir_cambio_estatus_torneo','1',true);
 UPDATE public.tournaments SET estatus='inscripciones_abiertas'::public.estatus_torneo WHERE id=p_tournament_id;
 RETURN jsonb_build_object('ok',true,'tournamentId',p_tournament_id,'alreadyOpen',false,
   'estatusAnterior','planificado','estatus','inscripciones_abiertas');
END $$;

-- Asistente v11: paso explicito de Franjas antes de Configuracion.
CREATE OR REPLACE FUNCTION public._obtener_asistente_operativo_torneo_v11_254(p_tournament_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE res jsonb; src jsonb; fin jsonb; blockers jsonb; nexta jsonb; f jsonb; step jsonb;
 total int; completed int;
BEGIN
 res:=public._obtener_asistente_operativo_torneo_v10_249(p_tournament_id);
 src:=COALESCE(res->'steps','[]'::jsonb);
 f:=public.validar_franjas_handicap_torneo(p_tournament_id);
 step:=jsonb_build_object(
  'code','HANDICAP_RANGES','scope','TOURNAMENT','title','Franjas de hándicap',
  'status',CASE WHEN COALESCE((f->>'valid')::boolean,false) THEN 'COMPLETE' ELSE 'BLOCKED' END,
  'message',CASE WHEN COALESCE((f->>'valid')::boolean,false)
    THEN 'Las franjas de hándicap están configuradas y son continuas.'
    ELSE 'Las franjas de hándicap faltan o tienen inconsistencias.' END,
  'recommendation',CASE WHEN COALESCE((f->>'valid')::boolean,false) THEN NULL
    ELSE 'Configura y corrige las franjas en Categorías → Franjas de hándicap antes de finalizar la configuración o abrir inscripciones.' END,
  'details',f,'action',jsonb_build_object('label','Configurar franjas de hándicap',
    'target','categorias','section','franjas-handicap'),
  'requiredRole','TOURNAMENT_OPERATOR','availability',jsonb_build_object('actionable',true));

 SELECT COALESCE(jsonb_agg(x.elem ORDER BY x.k,x.ord),'[]'::jsonb) INTO fin
 FROM (
   SELECT elem,ord,CASE WHEN elem->>'code'='TOURNAMENT_CONFIGURATION' THEN 2 ELSE 3 END k
   FROM jsonb_array_elements(src) WITH ORDINALITY s(elem,ord)
   UNION ALL SELECT step,0::bigint,1
 ) x;

 SELECT COALESCE(jsonb_agg(s.elem ORDER BY s.ord),'[]'::jsonb) INTO blockers
 FROM jsonb_array_elements(fin) WITH ORDINALITY s(elem,ord)
 WHERE s.elem->>'status'='BLOCKED'
   AND COALESCE((s.elem#>>'{availability,actionable}')::boolean,true);

 SELECT s.elem->'action' INTO nexta
 FROM jsonb_array_elements(fin) WITH ORDINALITY s(elem,ord)
 WHERE s.elem->>'status' IN('BLOCKED','PENDING') AND s.elem->'action' IS NOT NULL
   AND s.elem->'action'<>'null'::jsonb
   AND COALESCE((s.elem#>>'{availability,actionable}')::boolean,true)
 ORDER BY s.ord LIMIT 1;

 SELECT count(*)::int,count(*) FILTER(WHERE elem->>'status'='COMPLETE')::int
 INTO total,completed FROM jsonb_array_elements(fin) elem;

 res:=jsonb_set(res,'{steps}',fin,true);
 res:=jsonb_set(res,'{blockers}',blockers,true);
 res:=jsonb_set(res,'{summary,blockingIssues}',to_jsonb(jsonb_array_length(blockers)),true);
 res:=jsonb_set(res,'{progress,completed}',to_jsonb(completed),true);
 res:=jsonb_set(res,'{progress,total}',to_jsonb(total),true);
 res:=jsonb_set(res,'{progress,percent}',to_jsonb(CASE WHEN total=0 THEN 0 ELSE round(100.0*completed/total,0) END),true);
 res:=jsonb_set(res,'{nextAction}',COALESCE(nexta,'null'::jsonb),true);
 RETURN res||jsonb_build_object('schemaVersion',11);
END $$;
REVOKE ALL ON FUNCTION public._obtener_asistente_operativo_torneo_v11_254(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._obtener_asistente_operativo_torneo_v11_254(uuid) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.obtener_asistente_operativo_torneo(p_tournament_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$ BEGIN RETURN public._obtener_asistente_operativo_torneo_v11_254(p_tournament_id); END $$;

COMMIT;
