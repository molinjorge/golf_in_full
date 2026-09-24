-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 381 — TURNO ACTIVO OBLIGATORIO ANTES DE INSCRIPCIONES
BEGIN;
CREATE OR REPLACE FUNCTION public._estado_apertura_inscripciones_379(p_tournament_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
 v_t public.tournaments%ROWTYPE; v_min_ready boolean:=false; v_min_errors jsonb:='[]';
 v_hcp jsonb:='{}'; v_tiebreak jsonb:='{}'; v_declared integer:=0; v_active integer:=0;
 v_missing integer[]:=ARRAY[]::integer[]; v_unconfigured jsonb:='[]'; v_rounds_ready boolean:=false;
 v_base_ready boolean:=false; v_categories integer:=0; v_bad_category_caps integer:=0;
 v_category_capacity bigint:=0; v_course_club uuid;
BEGIN
 SELECT * INTO v_t FROM public.tournaments WHERE id=p_tournament_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='22023'; END IF;
 SELECT count(*)::integer,count(*) FILTER(WHERE cupo_maximo IS NULL OR cupo_maximo<=0)::integer,COALESCE(sum(cupo_maximo),0)
 INTO v_categories,v_bad_category_caps,v_category_capacity FROM public.tournament_categories WHERE tournament_id=p_tournament_id;
 IF v_t.campo_golf_id IS NOT NULL THEN SELECT club_id INTO v_course_club FROM public.campos_golf WHERE id=v_t.campo_golf_id; END IF;
 v_base_ready:=v_t.campo_golf_id IS NOT NULL AND v_course_club IS NOT NULL
 AND v_t.club_id IS NOT DISTINCT FROM v_course_club AND v_t.tournament_format_id IS NOT NULL
 AND v_t.cupo_maximo>0 AND v_t.numero_rondas>0 AND v_categories>0 AND v_bad_category_caps=0 AND v_category_capacity=v_t.cupo_maximo;
 v_hcp:=public.validar_franjas_handicap_torneo(p_tournament_id);
 v_tiebreak:=public.obtener_estado_configuracion_desempates_261(p_tournament_id);
 v_declared:=COALESCE(v_t.numero_rondas,0);
 SELECT count(*)::integer INTO v_active FROM public.tournament_rounds r
 WHERE r.tournament_id=p_tournament_id AND r.activo=true AND r.numero_ronda BETWEEN 1 AND v_declared;
 IF v_declared>0 THEN
   SELECT COALESCE(array_agg(gs ORDER BY gs),ARRAY[]::integer[]) INTO v_missing FROM generate_series(1,v_declared) gs
   WHERE NOT EXISTS(SELECT 1 FROM public.tournament_rounds r WHERE r.tournament_id=p_tournament_id AND r.numero_ronda=gs AND r.activo=true);
   SELECT COALESCE(jsonb_agg(jsonb_build_object('roundId',q.id,'roundNumber',q.numero_ronda,'date',q.fecha,
     'courseId',q.campo_golf_id,'startFormat',q.formato_salida,'activeShifts',q.active_shifts,'missing',q.missing)
     ORDER BY q.numero_ronda),'[]'::jsonb) INTO v_unconfigured
   FROM (
     SELECT r.id,r.numero_ronda,r.fecha,r.campo_golf_id,r.formato_salida,
       (SELECT count(*)::integer FROM public.tournament_round_shifts s WHERE s.tournament_round_id=r.id AND s.activo=true) active_shifts,
       (SELECT jsonb_agg(x) FROM unnest(ARRAY[
         CASE WHEN r.fecha IS NULL THEN 'FECHA' END,
         CASE WHEN r.campo_golf_id IS NULL THEN 'CAMPO' END,
         CASE WHEN r.campo_golf_id IS DISTINCT FROM v_t.campo_golf_id THEN 'CAMPO_DISTINTO_TORNEO' END,
         CASE WHEN r.formato_salida IS NULL THEN 'FORMATO_SALIDA' END,
         CASE WHEN NOT EXISTS(SELECT 1 FROM public.tournament_round_shifts s WHERE s.tournament_round_id=r.id AND s.activo=true) THEN 'TURNO_ACTIVO' END
       ]) x WHERE x IS NOT NULL) missing
     FROM public.tournament_rounds r WHERE r.tournament_id=p_tournament_id AND r.activo=true AND r.numero_ronda BETWEEN 1 AND v_declared
   ) q WHERE q.missing IS NOT NULL;
 END IF;
 v_rounds_ready:=v_declared>0 AND cardinality(v_missing)=0 AND v_active=v_declared AND jsonb_array_length(v_unconfigured)=0;
 SELECT v.listo,v.errores INTO v_min_ready,v_min_errors FROM public.validar_configuracion_minima_torneo(p_tournament_id) v;
 RETURN jsonb_build_object('baseConfigurationReady',v_base_ready,'handicapRangesReady',COALESCE((v_hcp->>'valid')::boolean,false),
 'handicapRanges',v_hcp,'tiebreakReady',COALESCE((v_tiebreak->>'complete')::boolean,false),'tiebreak',v_tiebreak,
 'roundStructureReady',v_rounds_ready,'declaredRounds',v_declared,'activeRounds',v_active,'missingRounds',to_jsonb(v_missing),
 'unconfiguredRounds',v_unconfigured,'minimumConfigurationReady',COALESCE(v_min_ready,false),
 'minimumConfigurationErrors',COALESCE(v_min_errors,'[]'::jsonb),'readyToOpen',
 v_base_ready AND COALESCE((v_hcp->>'valid')::boolean,false) AND COALESCE((v_tiebreak->>'complete')::boolean,false)
 AND v_rounds_ready AND COALESCE(v_min_ready,false));
END;$function$;
COMMENT ON FUNCTION public._estado_apertura_inscripciones_379(uuid) IS
'381: cada ronda debe tener fecha, campo del torneo, formato de salida y al menos un turno activo antes de inscripciones.';
COMMIT;
