-- 432A-MIGRACION_WORKFLOW_ORDEN_FREEZE_TODAS_MODALIDADES.sql
-- Corrección de la Migración 432 ya aplicada.
-- Objetivo:
--   1) Restablecer CONGELAR CONDICIONES antes de PREPARAR GRUPOS para TODAS las modalidades.
--   2) Mantener FORMAR EQUIPOS antes del freeze para modalidades por equipos.
--   3) Mantener HCP TEAM antes del freeze exclusivamente para A-Go-Go.
--   4) No modificar motores deportivos ni autorizaciones.
--
-- Orden resultante:
--   60 Cerrar inscripciones
--   70 Formar equipos              (sólo modalidades por equipos)
--   80 HCP TEAM                    (sólo A-Go-Go)
--   85 Congelar condiciones        (todas)
--   90 Preparar grupos
--  100 Preparar salidas
--  110 Validar salidas
--  120 Emitir tarjetas
--  130 Iniciar torneo

BEGIN;

DO $$
DECLARE
  v_template_id uuid;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT id INTO v_template_id
  FROM public.workflow_master_templates
  WHERE template_code='TEE_CENTRAL_STANDARD'
    AND version=1
    AND active=true
  LIMIT 1;

  IF v_template_id IS NULL THEN
    RAISE EXCEPTION '432A: plantilla TEE_CENTRAL_STANDARD v1 activa no encontrada.';
  END IF;

  -- 1. Orden maestro. Evitar conflictos de UNIQUE durante el reacomodo.
  UPDATE public.workflow_master_nodes
     SET sequence_no = sequence_no + 1000,
         display_order = display_order + 1000
   WHERE template_id=v_template_id
     AND active=true
     AND code IN (
       'REGISTRATIONS_CLOSE','TEAM_COMPOSITION','ROUND_TEAM_HCP','FREEZE',
       'ROUND_GROUPS','ROUND_STARTS_PREPARE','ROUND_STARTS_VALIDATE',
       'SCORECARD_EMISSION','START_TOURNAMENT'
     );

  UPDATE public.workflow_master_nodes
     SET sequence_no = CASE code
       WHEN 'REGISTRATIONS_CLOSE' THEN 60
       WHEN 'TEAM_COMPOSITION' THEN 70
       WHEN 'ROUND_TEAM_HCP' THEN 80
       WHEN 'FREEZE' THEN 85
       WHEN 'ROUND_GROUPS' THEN 90
       WHEN 'ROUND_STARTS_PREPARE' THEN 100
       WHEN 'ROUND_STARTS_VALIDATE' THEN 110
       WHEN 'SCORECARD_EMISSION' THEN 120
       WHEN 'START_TOURNAMENT' THEN 130
     END,
     display_order = CASE code
       WHEN 'REGISTRATIONS_CLOSE' THEN 6
       WHEN 'TEAM_COMPOSITION' THEN 7
       WHEN 'ROUND_TEAM_HCP' THEN 8
       WHEN 'FREEZE' THEN 9
       WHEN 'ROUND_GROUPS' THEN 10
       WHEN 'ROUND_STARTS_PREPARE' THEN 11
       WHEN 'ROUND_STARTS_VALIDATE' THEN 12
       WHEN 'SCORECARD_EMISSION' THEN 13
       WHEN 'START_TOURNAMENT' THEN 14
     END
   WHERE template_id=v_template_id
     AND active=true
     AND code IN (
       'REGISTRATIONS_CLOSE','TEAM_COMPOSITION','ROUND_TEAM_HCP','FREEZE',
       'ROUND_GROUPS','ROUND_STARTS_PREPARE','ROUND_STARTS_VALIDATE',
       'SCORECARD_EMISSION','START_TOURNAMENT'
     );

  -- TEAM_COMPOSITION aplica a cualquier modalidad cuya participación sea EQUIPO.
  UPDATE public.workflow_master_nodes
     SET applicability_rule='TEAM_COMPOSITION_REQUIRED',
         completion_rule='TEAM_COMPOSITION_COMPLETE',
         title='Formar equipos',
         action_label='Formar equipos',
         navigation_target='equipos'
   WHERE template_id=v_template_id
     AND active=true
     AND code='TEAM_COMPOSITION';

  IF NOT FOUND THEN
    RAISE EXCEPTION '432A: nodo TEAM_COMPOSITION no encontrado.';
  END IF;

  -- 2. Corregir evaluador 395 sin tocar su firma, seguridad o volatilidad.
  SELECT pg_get_functiondef(p.oid)
    INTO v_def
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public'
     AND p.proname='obtener_workflow_evaluado_395'
     AND p.oid::regprocedure::text='obtener_workflow_evaluado_395(uuid)';

  IF v_def IS NULL THEN
    RAISE EXCEPTION '432A: función obtener_workflow_evaluado_395(uuid) no encontrada.';
  END IF;

  v_def := replace(v_def, E'\r\n', E'\n');

  -- 2A. Aplicabilidad de FORMAR EQUIPOS: cualquier formato de participación equipo.
  v_old := E'WHEN ''A_GOGO_TEAM_COMPOSITION_REQUIRED'' THEN\n'
        || E'        SELECT EXISTS(\n'
        || E'          SELECT 1\n'
        || E'            FROM public.tournament_formats tf\n'
        || E'           WHERE tf.id=v_t.tournament_format_id\n'
        || E'             AND tf.activo=true\n'
        || E'             AND tf.code=''A_GOGO''\n'
        || E'             AND tf.tipo_participacion::text=''equipo''\n'
        || E'             AND tf.scoring_engine::text=''team_stroke''\n'
        || E'        ) INTO v_applicable;';

  v_new := E'WHEN ''TEAM_COMPOSITION_REQUIRED'' THEN\n'
        || E'        SELECT EXISTS(\n'
        || E'          SELECT 1\n'
        || E'            FROM public.tournament_formats tf\n'
        || E'           WHERE tf.id=v_t.tournament_format_id\n'
        || E'             AND tf.activo=true\n'
        || E'             AND tf.tipo_participacion::text=''equipo''\n'
        || E'        ) INTO v_applicable;';

  IF strpos(v_def,v_old)=0 THEN
    RAISE EXCEPTION '432A: no se encontró bloque de aplicabilidad TEAM_COMPOSITION de 432.';
  END IF;
  v_def := replace(v_def,v_old,v_new);

  -- 2B. Composición:
  --     A-Go-Go conserva la evidencia especializada 274.
  --     Best Ball y Stableford equipo quedan completos cuando todas las
  --     inscripciones activas están asignadas a un equipo activo.
  v_old := E'WHEN ''A_GOGO_TEAM_COMPOSITION_COMPLETE'' THEN\n'
        || E'        IF v_applicable THEN\n'
        || E'          v_evidence := public.obtener_estado_equipos_incompletos_a_gogo_274(p_tournament_id);\n'
        || E'          v_complete := COALESCE((v_evidence->>''compositionReady'')::boolean,false);\n'
        || E'        ELSE\n'
        || E'          v_complete := false;\n'
        || E'          v_evidence := jsonb_build_object(''applicable'',false);\n'
        || E'        END IF;';

  v_new := E'WHEN ''TEAM_COMPOSITION_COMPLETE'' THEN\n'
        || E'        IF v_applicable THEN\n'
        || E'          IF EXISTS (\n'
        || E'            SELECT 1 FROM public.tournament_formats tf\n'
        || E'             WHERE tf.id=v_t.tournament_format_id\n'
        || E'               AND tf.activo=true\n'
        || E'               AND tf.code=''A_GOGO''\n'
        || E'               AND tf.tipo_participacion::text=''equipo''\n'
        || E'               AND tf.scoring_engine::text=''team_stroke''\n'
        || E'          ) THEN\n'
        || E'            v_evidence := public.obtener_estado_equipos_incompletos_a_gogo_274(p_tournament_id);\n'
        || E'            v_complete := COALESCE((v_evidence->>''compositionReady'')::boolean,false);\n'
        || E'          ELSE\n'
        || E'            SELECT count(*) INTO v_team_total\n'
        || E'              FROM public.tournament_registrations reg\n'
        || E'             WHERE reg.tournament_id=p_tournament_id AND reg.activo=true;\n'
        || E'            SELECT count(*) INTO v_team_current\n'
        || E'              FROM public.tournament_registrations reg\n'
        || E'              JOIN public.tournament_teams tt ON tt.id=reg.tournament_team_id\n'
        || E'             WHERE reg.tournament_id=p_tournament_id\n'
        || E'               AND reg.activo=true AND tt.activo=true;\n'
        || E'            v_complete := v_team_total>0 AND v_team_current=v_team_total;\n'
        || E'            v_evidence := jsonb_build_object(\n'
        || E'              ''activeRegistrations'',v_team_total,\n'
        || E'              ''assignedToActiveTeam'',v_team_current,\n'
        || E'              ''unassigned'',GREATEST(v_team_total-v_team_current,0)\n'
        || E'            );\n'
        || E'          END IF;\n'
        || E'        ELSE\n'
        || E'          v_complete := false;\n'
        || E'          v_evidence := jsonb_build_object(''applicable'',false);\n'
        || E'        END IF;';

  IF strpos(v_def,v_old)=0 THEN
    RAISE EXCEPTION '432A: no se encontró bloque de completion TEAM_COMPOSITION de 432.';
  END IF;
  v_def := replace(v_def,v_old,v_new);

  -- 2C. Antes del freeze sólo puede quedar HCP TEAM (A-Go-Go).
  v_old := E'AND (elem->>''sequenceNo'')::integer < 115';
  v_new := E'AND (elem->>''sequenceNo'')::integer < 85';
  IF strpos(v_def,v_old)=0 THEN
    RAISE EXCEPTION '432A: no se encontró límite pre-freeze <115.';
  END IF;
  v_def := replace(v_def,v_old,v_new);

  -- 2D. Después del freeze: grupos, salidas, validación y emisión.
  v_old := E'AND (elem->>''sequenceNo'')::integer >= 115';
  v_new := E'AND (elem->>''sequenceNo'')::integer >= 90';
  IF strpos(v_def,v_old)=0 THEN
    RAISE EXCEPTION '432A: no se encontró límite post-freeze >=115.';
  END IF;
  v_def := replace(v_def,v_old,v_new);

  -- Comentarios descriptivos, sin efecto funcional.
  v_def := replace(v_def,
    '-- C1a. Preparación deportiva previa al freeze:',
    '-- C1a. Pasos específicos de modalidad previos al freeze:');
  v_def := replace(v_def,
    '-- C1b. FREEZE después de validar salidas de la primera ronda.',
    '-- C1b. FREEZE antes de grupos/salidas de la primera ronda.');
  v_def := replace(v_def,
    '-- C1c. Preparación posterior al freeze: emisión.',
    '-- C1c. Preparación posterior al freeze: grupos, salidas, validación y emisión.');

  EXECUTE v_def;
END
$$;

-- Salvaguardas estructurales antes del COMMIT.
DO $$
DECLARE
  v_template_id uuid;
  v_bad integer;
  v_def text;
BEGIN
  SELECT id INTO v_template_id
  FROM public.workflow_master_templates
  WHERE template_code='TEE_CENTRAL_STANDARD' AND version=1 AND active=true
  LIMIT 1;

  SELECT count(*) INTO v_bad
  FROM (VALUES
    ('REGISTRATIONS_CLOSE',60),
    ('TEAM_COMPOSITION',70),
    ('ROUND_TEAM_HCP',80),
    ('FREEZE',85),
    ('ROUND_GROUPS',90),
    ('ROUND_STARTS_PREPARE',100),
    ('ROUND_STARTS_VALIDATE',110),
    ('SCORECARD_EMISSION',120),
    ('START_TOURNAMENT',130)
  ) x(code,seq)
  LEFT JOIN public.workflow_master_nodes n
    ON n.template_id=v_template_id AND n.active=true AND n.code=x.code
   AND n.sequence_no=x.seq
  WHERE n.id IS NULL;

  IF v_bad<>0 THEN
    RAISE EXCEPTION '432A: orden maestro final no coincide con el esperado.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.proname='obtener_workflow_evaluado_395'
    AND p.oid::regprocedure::text='obtener_workflow_evaluado_395(uuid)';

  IF strpos(v_def, 'TEAM_COMPOSITION_REQUIRED')=0
     OR strpos(v_def, 'TEAM_COMPOSITION_COMPLETE')=0
     OR strpos(v_def, '(elem->>''sequenceNo'')::integer < 85')=0
     OR strpos(v_def, '(elem->>''sequenceNo'')::integer >= 90')=0
  THEN
    RAISE EXCEPTION '432A: 395 no contiene la lógica final esperada.';
  END IF;
END
$$;

COMMIT;
