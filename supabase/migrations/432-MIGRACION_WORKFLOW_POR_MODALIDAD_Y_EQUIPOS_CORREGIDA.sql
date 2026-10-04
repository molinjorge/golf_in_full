-- 432-MIGRACION_WORKFLOW_POR_MODALIDAD_Y_EQUIPOS.sql
-- TEE CENTRAL / GOLF IN FULL
-- Objetivo:
--   Corregir el Workflow Maestro para que A-Go-Go no pueda avanzar desde
--   CERRAR INSCRIPCIONES directamente a CONGELAR CONDICIONES cuando la
--   composición de equipos y el HCP TEAM aún están pendientes.
--
-- Alcance:
--   * agrega FORMAR EQUIPOS como nodo condicional del torneo;
--   * usa la evidencia A-Go-Go existente de la 274 (no crea reglas deportivas nuevas);
--   * restringe HCP TEAM a A_GOGO/equipo/team_stroke;
--   * mueve FREEZE después de VALIDAR SALIDAS y antes de EMITIR TARJETAS;
--   * ajusta solamente la selección descriptiva de nextAction del 395.
--
-- NO modifica motores, cálculo HCP TEAM, inscripciones, salidas, freeze,
-- emisión de tarjetas ni estados deportivos. El Asistente sigue GUIDE_ONLY.

BEGIN;

DO $migration$
DECLARE
    v_template_id uuid;
    v_def text;
    v_before text;
    v_pos integer;
    v_rel integer;
BEGIN
    SELECT id
      INTO v_template_id
      FROM public.workflow_master_templates
     WHERE template_code='TEE_CENTRAL_STANDARD'
       AND version=1
       AND active=true;

    IF v_template_id IS NULL THEN
        RAISE EXCEPTION '432: no existe TEE_CENTRAL_STANDARD versión 1 activa.';
    END IF;

    -- ------------------------------------------------------------
    -- 1. Maestro: FORMAR EQUIPOS entra después de cerrar inscripciones.
    --    FREEZE pasa después de validar salidas (110) y antes de emitir (120).
    -- ------------------------------------------------------------
    UPDATE public.workflow_master_nodes
       SET sequence_no=115,
           updated_at=now()
     WHERE template_id=v_template_id
       AND code='FREEZE'
       AND sequence_no=70;

    IF NOT FOUND THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.workflow_master_nodes
             WHERE template_id=v_template_id AND code='FREEZE' AND sequence_no=115
        ) THEN
            RAISE EXCEPTION '432: FREEZE no está en la secuencia esperada 70/115.';
        END IF;
    END IF;

    -- Libera display_order=7 sin colisiones y conserva el orden relativo.
    IF NOT EXISTS (
        SELECT 1 FROM public.workflow_master_nodes
         WHERE template_id=v_template_id AND code='TEAM_COMPOSITION'
    ) THEN
        UPDATE public.workflow_master_nodes
           SET display_order=display_order+1000
         WHERE template_id=v_template_id
           AND display_order>=7;

        UPDATE public.workflow_master_nodes
           SET display_order=display_order-999
         WHERE template_id=v_template_id
           AND display_order>=1007;
    END IF;

    INSERT INTO public.workflow_master_nodes(
        template_id,code,sequence_no,scope,phase_code,title,description,
        action_label,navigation_target,is_actionable,is_required,is_conditional,
        applicability_rule,completion_rule,parallel_group,active,display_order,metadata
    ) VALUES (
        v_template_id,
        'TEAM_COMPOSITION',
        70,
        'TOURNAMENT',
        'PRE_ROUND',
        'Formar equipos',
        'Completar la composición competitiva de equipos cuando la modalidad lo requiere.',
        'Formar equipos',
        'equipos',
        true,true,true,
        'A_GOGO_TEAM_COMPOSITION_REQUIRED',
        'A_GOGO_TEAM_COMPOSITION_COMPLETE',
        NULL,true,7,
        jsonb_build_object(
            'formatCode','A_GOGO',
            'participationType','equipo',
            'scoringEngine','team_stroke',
            'evidence','obtener_estado_equipos_incompletos_a_gogo_274',
            'assistantOnly',true
        )
    )
    ON CONFLICT (template_id,code) DO UPDATE SET
        sequence_no=EXCLUDED.sequence_no,
        scope=EXCLUDED.scope,
        phase_code=EXCLUDED.phase_code,
        title=EXCLUDED.title,
        description=EXCLUDED.description,
        action_label=EXCLUDED.action_label,
        navigation_target=EXCLUDED.navigation_target,
        is_actionable=EXCLUDED.is_actionable,
        is_required=EXCLUDED.is_required,
        is_conditional=EXCLUDED.is_conditional,
        applicability_rule=EXCLUDED.applicability_rule,
        completion_rule=EXCLUDED.completion_rule,
        active=EXCLUDED.active,
        display_order=EXCLUDED.display_order,
        metadata=EXCLUDED.metadata,
        updated_at=now();

    -- FREEZE conserva su display_order desplazado; el orden operativo se rige
    -- por sequence_no. No se altera la regla deportiva del nodo.

    -- ------------------------------------------------------------
    -- 2. Evaluador 395.
    --    Se parte de SU definición vigente y se aplican reemplazos
    --    acotados con guardas. Así no se reescriben accidentalmente las
    --    demás reglas acumuladas del workflow.
    -- ------------------------------------------------------------
    SELECT pg_get_functiondef(p.oid)
      INTO v_def
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public'
       AND p.proname='obtener_workflow_evaluado_395'
       AND p.oid::regprocedure::text='obtener_workflow_evaluado_395(uuid)';

    IF v_def IS NULL THEN
        RAISE EXCEPTION '432: no existe obtener_workflow_evaluado_395(uuid).';
    END IF;

    v_def := replace(v_def, E'\r\n', E'\n');

    -- 2A. Aplicabilidad de nodos TORNEO por modalidad.
    --     Se inserta inmediatamente después del v_applicable inicial del
    --     LOOP TORNEO. Se localiza desde el comentario de ámbito para no
    --     depender de espacios/indentación de pg_get_functiondef.
    v_pos := strpos(v_def, '-- Nodos de ámbito TORNEO.');
    IF v_pos = 0 THEN
        RAISE EXCEPTION '432: no se encontró bloque TORNEO en 395.';
    END IF;

    v_rel := strpos(substr(v_def,v_pos), 'v_applicable := true;');
    IF v_rel = 0 THEN
        RAISE EXCEPTION '432: no se encontró inicialización de aplicabilidad TORNEO en 395.';
    END IF;
    v_pos := v_pos + v_rel - 1 + length('v_applicable := true;');
    v_def := overlay(
        v_def
        placing E'\n    CASE v_node.applicability_rule\n' ||
                E'      WHEN ''A_GOGO_TEAM_COMPOSITION_REQUIRED'' THEN\n' ||
                E'        SELECT EXISTS(\n' ||
                E'          SELECT 1\n' ||
                E'            FROM public.tournament_formats tf\n' ||
                E'           WHERE tf.id=v_t.tournament_format_id\n' ||
                E'             AND tf.activo=true\n' ||
                E'             AND tf.code=''A_GOGO''\n' ||
                E'             AND tf.tipo_participacion::text=''equipo''\n' ||
                E'             AND tf.scoring_engine::text=''team_stroke''\n' ||
                E'        ) INTO v_applicable;\n' ||
                E'      ELSE v_applicable := true;\n' ||
                E'    END CASE;\n'
        from v_pos + 1
        for 0
    );

    -- 2B. Evidencia existente 274 para composición A-Go-Go.
    --     Inserción por token semántico, independiente de espacios/indentación.
    v_pos := strpos(v_def, 'WHEN ''TOURNAMENT_FROZEN'' THEN');
    IF v_pos = 0 THEN
        RAISE EXCEPTION '432: no se encontró regla TOURNAMENT_FROZEN en 395.';
    END IF;
    v_def := overlay(
        v_def
        placing E'WHEN ''A_GOGO_TEAM_COMPOSITION_COMPLETE'' THEN\n' ||
                E'        IF v_applicable THEN\n' ||
                E'          v_evidence := public.obtener_estado_equipos_incompletos_a_gogo_274(p_tournament_id);\n' ||
                E'          v_complete := COALESCE((v_evidence->>''compositionReady'')::boolean,false);\n' ||
                E'        ELSE\n' ||
                E'          v_complete := false;\n' ||
                E'          v_evidence := jsonb_build_object(''applicable'',false);\n' ||
                E'        END IF;\n' ||
                E'      '
        from v_pos for 0
    );

    -- 2C. HCP TEAM sólo aplica a A-Go-Go TEAM.
    v_pos := strpos(v_def, 'WHEN ''TEAM_HCP_REQUIRED'' THEN');
    IF v_pos = 0 THEN
        RAISE EXCEPTION '432: no se encontró TEAM_HCP_REQUIRED en 395.';
    END IF;
    v_rel := strpos(substr(v_def,v_pos), ';');
    IF v_rel = 0 THEN
        RAISE EXCEPTION '432: TEAM_HCP_REQUIRED sin terminador esperado.';
    END IF;
    v_def := overlay(
        v_def
        placing E'WHEN ''TEAM_HCP_REQUIRED'' THEN\n' ||
                E'          SELECT EXISTS(\n' ||
                E'            SELECT 1 FROM public.tournament_formats tf\n' ||
                E'             WHERE tf.id=COALESCE(v_round.tournament_format_id,v_t.tournament_format_id)\n' ||
                E'               AND tf.activo=true AND tf.code=''A_GOGO''\n' ||
                E'               AND tf.tipo_participacion::text=''equipo''\n' ||
                E'               AND tf.scoring_engine::text=''team_stroke''\n' ||
                E'          ) INTO v_applicable;'
        from v_pos for v_rel
    );

    -- 2D. Pasos iniciales del torneo terminan en FORMAR EQUIPOS (<80).
    v_pos := strpos(v_def, '-- A. Pasos iniciales del torneo');
    IF v_pos = 0 THEN
        RAISE EXCEPTION '432: no se encontró selector inicial A.';
    END IF;
    v_rel := strpos(substr(v_def,v_pos), '(elem->>''sequenceNo'')::integer < 130');
    IF v_rel = 0 THEN
        RAISE EXCEPTION '432: no se encontró límite <130 del selector A.';
    END IF;
    v_pos := v_pos + v_rel - 1;
    v_def := overlay(v_def placing '(elem->>''sequenceNo'')::integer < 80'
                     from v_pos for length('(elem->>''sequenceNo'')::integer < 130'));

    -- 2E. Preparación de ronda: antes del freeze <115; después 115..129.
    v_pos := strpos(v_def, '-- C1. Preparación de la ronda antes de iniciar torneo/ronda.');
    IF v_pos = 0 THEN
        RAISE EXCEPTION '432: no se encontró inicio C1.';
    END IF;
    v_rel := strpos(substr(v_def,v_pos), '-- C2. Iniciar torneo una sola vez');
    IF v_rel = 0 THEN
        RAISE EXCEPTION '432: no se encontró inicio C2.';
    END IF;
    v_def := overlay(
        v_def
        placing E'-- C1a. Preparación deportiva previa al freeze:\n' ||
                E'        SELECT elem INTO v_candidate\n' ||
                E'          FROM jsonb_array_elements(v_round_json->''nodes'') elem\n' ||
                E'         WHERE COALESCE((elem->>''applicable'')::boolean,false)\n' ||
                E'           AND NOT COALESCE((elem->>''complete'')::boolean,false)\n' ||
                E'           AND COALESCE((elem->>''isActionable'')::boolean,false)\n' ||
                E'           AND (elem->>''sequenceNo'')::integer < 115\n' ||
                E'         ORDER BY (elem->>''sequenceNo'')::integer LIMIT 1;\n' ||
                E'        IF v_candidate IS NOT NULL THEN\n' ||
                E'          v_next := v_candidate - ''complete'' - ''evidence'' - ''isActionable'' - ''isRequired'' - ''applicable'' - ''status''; EXIT;\n' ||
                E'        END IF;\n\n' ||
                E'        -- C1b. FREEZE después de validar salidas de la primera ronda.\n' ||
                E'        IF COALESCE((v_round_json->>''roundNumber'')::integer,0)=1 THEN\n' ||
                E'          SELECT elem INTO v_candidate FROM jsonb_array_elements(v_tournament_nodes) elem\n' ||
                E'           WHERE elem->>''code''=''FREEZE''\n' ||
                E'             AND COALESCE((elem->>''applicable'')::boolean,false)\n' ||
                E'             AND NOT COALESCE((elem->>''complete'')::boolean,false)\n' ||
                E'             AND COALESCE((elem->>''isActionable'')::boolean,false) LIMIT 1;\n' ||
                E'          IF v_candidate IS NOT NULL THEN\n' ||
                E'            v_next := v_candidate - ''complete'' - ''evidence'' - ''isActionable'' - ''isRequired'' - ''applicable'' - ''status''; EXIT;\n' ||
                E'          END IF;\n' ||
                E'        END IF;\n\n' ||
                E'        -- C1c. Preparación posterior al freeze: emisión.\n' ||
                E'        v_candidate := NULL;\n' ||
                E'        SELECT elem INTO v_candidate FROM jsonb_array_elements(v_round_json->''nodes'') elem\n' ||
                E'         WHERE COALESCE((elem->>''applicable'')::boolean,false)\n' ||
                E'           AND NOT COALESCE((elem->>''complete'')::boolean,false)\n' ||
                E'           AND COALESCE((elem->>''isActionable'')::boolean,false)\n' ||
                E'           AND (elem->>''sequenceNo'')::integer >= 115\n' ||
                E'           AND (elem->>''sequenceNo'')::integer < 130\n' ||
                E'         ORDER BY (elem->>''sequenceNo'')::integer LIMIT 1;\n' ||
                E'        IF v_candidate IS NOT NULL THEN\n' ||
                E'          v_next := v_candidate - ''complete'' - ''evidence'' - ''isActionable'' - ''isRequired'' - ''applicable'' - ''status''; EXIT;\n' ||
                E'        END IF;\n\n        '
        from v_pos for v_rel - 1
    );

    EXECUTE v_def;
END
$migration$;

COMMIT;
