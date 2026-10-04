-- 435-MIGRACION_VALIDADOR_SALIDAS_STABLEFORD_EQUIPO.sql
-- STABLEFORD_EQUIPO: grupos por equipo, tarjetas/HCP por jugador. NO HCP TEAM.
BEGIN;

CREATE OR REPLACE FUNCTION public._previsualizar_validacion_salidas_stableford_team_shotgun_v1(p_tournament_round_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_tid uuid; v_code text; v_part text; v_engine text;
  v_base jsonb; v_errors jsonb := '[]'::jsonb; v_extra jsonb := '[]'::jsonb;
  v_max integer; v_n integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501'; END IF;

  SELECT tr.tournament_id,rcs.format_code,rcs.participation_type,rcs.scoring_engine
    INTO v_tid,v_code,v_part,v_engine
    FROM public.tournament_rounds tr
    LEFT JOIN public.tournament_condition_freezes f ON f.tournament_id=tr.tournament_id
    LEFT JOIN public.tournament_round_condition_snapshots rcs
      ON rcs.freeze_id=f.id AND rcs.tournament_round_id=tr.id
   WHERE tr.id=p_tournament_round_id;

  IF v_tid IS NULL THEN RAISE EXCEPTION 'La ronda indicada no existe.' USING ERRCODE='22023'; END IF;
  IF NOT public.puede_administrar_congelamiento_torneo(v_tid) THEN
    RAISE EXCEPTION 'No tienes permiso para validar las salidas de esta ronda.' USING ERRCODE='42501';
  END IF;

  IF COALESCE(v_code,'')<>'STABLEFORD_EQUIPO'
     OR COALESCE(v_part,'')<>'equipo'
     OR COALESCE(v_engine,'')<>'stableford' THEN
    RETURN jsonb_build_object(
      'schemaVersion',2,'validatorEngine','stableford_team_shotgun_v1','ready',false,
      'alreadyValidated',false,
      'errors',jsonb_build_array(jsonb_build_object(
        'code','modalidad_no_soportada',
        'message','Este validador corresponde únicamente a Stableford por Equipos.'
      )),
      'warnings','[]'::jsonb
    );
  END IF;

  -- Reutiliza las comprobaciones TEAM probadas: freeze, hoyos, grupos, categoría,
  -- asignación única, orden, máximo por grupo y HCP INDIVIDUAL congelado.
  v_base:=public._previsualizar_validacion_salidas_best_ball_shotgun_v1(p_tournament_round_id);

  -- Quita únicamente las reglas que son exclusivas de Best Ball.
  SELECT COALESCE(jsonb_agg(e),'[]'::jsonb) INTO v_errors
    FROM jsonb_array_elements(COALESCE(v_base->'errors','[]'::jsonb)) e
   WHERE e->>'code' NOT IN ('modalidad_no_soportada','tamano_equipo_best_ball_invalido');

  -- Stableford TEAM puede jugar disminuido. Sólo se bloquea exceder el tamaño configurado.
  SELECT jugadores_por_equipo INTO v_max FROM public.tournaments WHERE id=v_tid;
  IF v_max IS NULL OR v_max<2 OR v_max>5 THEN
    v_extra:=v_extra||jsonb_build_array(jsonb_build_object(
      'code','tamano_equipo_no_configurado',
      'message','Stableford por Equipos requiere jugadores_por_equipo configurado entre 2 y 5.'
    ));
  ELSE
    SELECT count(*) INTO v_n FROM (
      SELECT tt.id
      FROM public.tournament_teams tt
      LEFT JOIN public.tournament_registrations reg
        ON reg.tournament_team_id=tt.id AND reg.tournament_id=v_tid AND reg.activo=true
      WHERE tt.tournament_id=v_tid AND tt.activo=true
      GROUP BY tt.id
      HAVING count(reg.id)>v_max
    ) q;
    IF v_n>0 THEN
      v_extra:=v_extra||jsonb_build_array(jsonb_build_object(
        'code','tamano_equipo_stableford_excedido',
        'message',format('%s equipo(s) exceden los %s jugadores configurados por equipo.',v_n,v_max)
      ));
    END IF;
  END IF;

  v_errors:=v_errors||v_extra;

  RETURN
    (v_base-'errors'-'ready'-'validatorEngine'-'validationHandler')
    ||jsonb_build_object(
      'schemaVersion',2,
      'validatorEngine','stableford_team_shotgun_v1',
      'validationHandler','shotgun_stableford_team_v1',
      'ready',jsonb_array_length(v_errors)=0,
      'errors',v_errors,
      'counts',COALESCE(v_base->'counts','{}'::jsonb)||jsonb_build_object(
        'errors',jsonb_array_length(v_errors),
        'warnings',jsonb_array_length(COALESCE(v_base->'warnings','[]'::jsonb))
      )
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.previsualizar_validacion_salidas_ronda(p_tournament_round_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_tournament_id uuid; v_dispatch jsonb; v_handler text; v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501'; END IF;
  SELECT tournament_id INTO v_tournament_id FROM public.tournament_rounds WHERE id=p_tournament_round_id;
  IF v_tournament_id IS NULL THEN RAISE EXCEPTION 'La ronda indicada no existe.'; END IF;
  IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
    RAISE EXCEPTION 'No tienes permiso para validar las salidas de esta ronda.' USING ERRCODE='42501';
  END IF;

  v_dispatch:=public._resolver_validador_salida_ronda(p_tournament_round_id);
  IF NOT COALESCE((v_dispatch->>'supported')::boolean,false) THEN
    RETURN jsonb_build_object(
      'schemaVersion',2,'ready',false,
      'alreadyValidated',COALESCE((public.obtener_estado_validacion_salidas_ronda(p_tournament_round_id)->>'validated')::boolean,false),
      'errors',jsonb_build_array(jsonb_build_object(
        'code',COALESCE(v_dispatch->>'code','validacion_salida_no_soportada'),
        'message',COALESCE(v_dispatch->>'message','La ronda no tiene validador de salidas habilitado.'),
        'detail',v_dispatch)),
      'warnings','[]'::jsonb,'dispatch',v_dispatch);
  END IF;

  v_handler:=v_dispatch->>'validationHandler';
  CASE v_handler
    WHEN 'shotgun_v1' THEN v_result:=public._previsualizar_validacion_salidas_shotgun_v1(p_tournament_round_id);
    WHEN 'tee_times_v1' THEN v_result:=public._previsualizar_validacion_salidas_tee_times_v1(p_tournament_round_id);
    WHEN 'shotgun_team_v1' THEN v_result:=public._previsualizar_validacion_salidas_shotgun_team_v1(p_tournament_round_id);
    WHEN 'shotgun_best_ball_v1' THEN v_result:=public._previsualizar_validacion_salidas_best_ball_shotgun_v1(p_tournament_round_id);
    WHEN 'shotgun_stableford_team_v1' THEN v_result:=public._previsualizar_validacion_salidas_stableford_team_shotgun_v1(p_tournament_round_id);
    ELSE
      RETURN jsonb_build_object(
        'schemaVersion',2,'ready',false,'alreadyValidated',false,
        'errors',jsonb_build_array(jsonb_build_object(
          'code','handler_validacion_no_implementado',
          'message','El motor esta registrado, pero su handler de validacion no esta implementado.',
          'detail',v_dispatch)),
        'warnings','[]'::jsonb,'dispatch',v_dispatch);
  END CASE;

  RETURN v_result||jsonb_build_object('schemaVersion',2,'validationHandler',v_handler,'dispatch',v_dispatch);
END;
$function$;

UPDATE public.tournament_start_engine_registry
SET start_validation_handler='shotgun_stableford_team_v1',
    validation_engine='stableford_team_shotgun_v1'
WHERE activo=true
  AND start_format::text='shotgun'
  AND participation_type='equipo'
  AND scoring_engine='stableford';

DO $block$
DECLARE v_n integer;
BEGIN
  SELECT count(*) INTO v_n
  FROM public.tournament_start_engine_registry
  WHERE activo=true AND start_format::text='shotgun'
    AND participation_type='equipo' AND scoring_engine='stableford';
  IF v_n<>1 THEN
    RAISE EXCEPTION 'Se esperaba exactamente un motor activo Stableford TEAM Shotgun; encontrados: %',v_n;
  END IF;
END;
$block$;

COMMIT;
