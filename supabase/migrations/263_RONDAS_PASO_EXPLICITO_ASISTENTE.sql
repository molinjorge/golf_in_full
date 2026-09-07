-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 263
-- Paso explícito RONDAS / CONFIGURACIÓN DE RONDA en el Asistente
-- ============================================================
--
-- HALLAZGO
-- El backend ya valida muchos aspectos estructurales de las rondas antes
-- del congelamiento, pero el Asistente no tenía un paso explícito RONDAS.
-- Como resultado, podía indicar que correspondía congelar aun cuando:
--   - una ronda no tuviera formato de salida;
--   - no tuviera turno activo;
--   - no tuviera motor de salida soportado;
--   - el formato/participación/scoring no fueran compatibles.
--
-- OBJETIVO
-- Añadir ROUND_CONFIGURATION inmediatamente antes de FREEZE.
--
-- REGLA
-- Para cada ronda activa se exige:
--   - número de rondas activas = número declarado;
--   - fecha y campo válidos;
--   - formato efectivo activo;
--   - Handicap Allowance efectivo válido 0..100;
--   - formato de salida definido;
--   - al menos un turno activo;
--   - combinación de salida/participación/scoring soportada por registry.
--
-- Si el torneo ya está congelado, el paso se considera COMPLETE:
-- la configuración estructural ya fue superada y no debe reaparecer
-- como deuda retroactiva.
--
-- No modifica datos de rondas ni salidas.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_estado_configuracion_rondas_263(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament public.tournaments%ROWTYPE;
    v_declared integer := 0;
    v_active integer := 0;
    v_frozen boolean := false;
    v_errors jsonb := '[]'::jsonb;
    v_rounds jsonb := '[]'::jsonb;
    v_error_count integer := 0;
BEGIN
    SELECT *
      INTO v_tournament
      FROM public.tournaments
     WHERE id=p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.'
            USING ERRCODE='22023';
    END IF;

    v_declared := COALESCE(v_tournament.numero_rondas,0);

    SELECT count(*)::integer
      INTO v_active
      FROM public.tournament_rounds tr
     WHERE tr.tournament_id=p_tournament_id
       AND tr.activo=true;

    SELECT EXISTS(
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id=p_tournament_id
    )
    INTO v_frozen;

    IF v_frozen THEN
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'roundId',tr.id,
                    'roundNumber',tr.numero_ronda,
                    'date',tr.fecha,
                    'courseId',tr.campo_golf_id,
                    'startFormat',tr.formato_salida,
                    'status','COMPLETE',
                    'grandfatheredByFreeze',true
                )
                ORDER BY tr.numero_ronda
            ),
            '[]'::jsonb
        )
        INTO v_rounds
        FROM public.tournament_rounds tr
        WHERE tr.tournament_id=p_tournament_id
          AND tr.activo=true;

        RETURN jsonb_build_object(
            'complete',true,
            'status','COMPLETE',
            'frozen',true,
            'declaredRounds',v_declared,
            'activeRounds',v_active,
            'errors','[]'::jsonb,
            'rounds',v_rounds,
            'message','La configuración estructural de rondas ya fue superada antes del congelamiento.',
            'recommendation',NULL
        );
    END IF;

    IF v_declared<=0 OR v_active<>v_declared THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'code','round_count_mismatch',
                'message',format(
                    'El torneo declara %s ronda(s) y actualmente tiene %s ronda(s) activa(s).',
                    v_declared,v_active
                )
            )
        );
    END IF;

    WITH round_state AS (
        SELECT
            tr.id,
            tr.numero_ronda,
            tr.fecha,
            tr.campo_golf_id,
            tr.formato_salida::text AS start_format,
            COALESCE(tr.tournament_format_id,t.tournament_format_id)
                AS effective_format_id,
            tf.code AS format_code,
            tf.name AS format_name,
            tf.activo AS format_active,
            tf.tipo_participacion::text AS participation_type,
            tf.scoring_engine::text AS scoring_engine,
            COALESCE(
                tr.handicap_allowance_pct,
                tf.handicap_allowance_default
            ) AS effective_allowance,
            cg.activo AS course_active,
            (
                SELECT count(*)::integer
                FROM public.tournament_round_shifts s
                WHERE s.tournament_round_id=tr.id
                  AND s.activo=true
            ) AS active_shifts,
            EXISTS(
                SELECT 1
                FROM public.tournament_start_engine_registry r
                WHERE r.start_format::text=COALESCE(tr.formato_salida::text,'')
                  AND r.participation_type=COALESCE(tf.tipo_participacion::text,'')
                  AND r.scoring_engine=COALESCE(tf.scoring_engine::text,'')
                  AND r.activo=true
            ) AS engine_supported
        FROM public.tournament_rounds tr
        JOIN public.tournaments t
          ON t.id=tr.tournament_id
        LEFT JOIN public.tournament_formats tf
          ON tf.id=COALESCE(tr.tournament_format_id,t.tournament_format_id)
        LEFT JOIN public.campos_golf cg
          ON cg.id=tr.campo_golf_id
        WHERE tr.tournament_id=p_tournament_id
          AND tr.activo=true
    ),
    per_round AS (
        SELECT
            rs.*,
            (
                CASE WHEN rs.fecha IS NULL THEN
                    jsonb_build_array(jsonb_build_object(
                        'code','round_date_missing',
                        'message',format(
                            'La ronda %s no tiene fecha.',
                            rs.numero_ronda
                        )
                    ))
                ELSE '[]'::jsonb END
                ||
                CASE WHEN rs.campo_golf_id IS NULL
                          OR COALESCE(rs.course_active,false)=false THEN
                    jsonb_build_array(jsonb_build_object(
                        'code','round_course_missing_or_inactive',
                        'message',format(
                            'La ronda %s no tiene un campo activo válido.',
                            rs.numero_ronda
                        )
                    ))
                ELSE '[]'::jsonb END
                ||
                CASE WHEN rs.effective_format_id IS NULL
                          OR rs.format_code IS NULL
                          OR COALESCE(rs.format_active,false)=false THEN
                    jsonb_build_array(jsonb_build_object(
                        'code','round_format_missing_or_inactive',
                        'message',format(
                            'La ronda %s no tiene una modalidad competitiva activa válida.',
                            rs.numero_ronda
                        )
                    ))
                ELSE '[]'::jsonb END
                ||
                CASE WHEN rs.effective_allowance IS NULL
                          OR rs.effective_allowance<0
                          OR rs.effective_allowance>100 THEN
                    jsonb_build_array(jsonb_build_object(
                        'code','round_handicap_allowance_invalid',
                        'message',format(
                            'La ronda %s no tiene Handicap Allowance efectivo válido entre 0 y 100.',
                            rs.numero_ronda
                        )
                    ))
                ELSE '[]'::jsonb END
                ||
                CASE WHEN rs.start_format IS NULL THEN
                    jsonb_build_array(jsonb_build_object(
                        'code','round_start_format_missing',
                        'message',format(
                            'La ronda %s no tiene modalidad de salida definida.',
                            rs.numero_ronda
                        )
                    ))
                ELSE '[]'::jsonb END
                ||
                CASE WHEN rs.active_shifts=0 THEN
                    jsonb_build_array(jsonb_build_object(
                        'code','round_shift_missing',
                        'message',format(
                            'La ronda %s no tiene ningún turno activo.',
                            rs.numero_ronda
                        )
                    ))
                ELSE '[]'::jsonb END
                ||
                CASE WHEN rs.start_format IS NOT NULL
                          AND rs.effective_format_id IS NOT NULL
                          AND NOT rs.engine_supported THEN
                    jsonb_build_array(jsonb_build_object(
                        'code','round_start_engine_unsupported',
                        'message',format(
                            'La combinación de salida y modalidad de la ronda %s no tiene un motor operativo soportado.',
                            rs.numero_ronda
                        ),
                        'startFormat',rs.start_format,
                        'participationType',rs.participation_type,
                        'scoringEngine',rs.scoring_engine
                    ))
                ELSE '[]'::jsonb END
            ) AS errors
        FROM round_state rs
    )
    SELECT
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'roundId',pr.id,
                    'roundNumber',pr.numero_ronda,
                    'date',pr.fecha,
                    'courseId',pr.campo_golf_id,
                    'formatId',pr.effective_format_id,
                    'formatCode',pr.format_code,
                    'formatName',pr.format_name,
                    'participationType',pr.participation_type,
                    'scoringEngine',pr.scoring_engine,
                    'handicapAllowancePct',pr.effective_allowance,
                    'startFormat',pr.start_format,
                    'activeShifts',pr.active_shifts,
                    'engineSupported',pr.engine_supported,
                    'status',
                        CASE
                            WHEN jsonb_array_length(pr.errors)=0
                                THEN 'COMPLETE'
                            ELSE 'BLOCKED'
                        END,
                    'errors',pr.errors
                )
                ORDER BY pr.numero_ronda
            ),
            '[]'::jsonb
        ),
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'roundId',pr2.id,
                        'roundNumber',pr2.numero_ronda
                    ) || e.value
                    ORDER BY pr2.numero_ronda
                )
                FROM per_round pr2
                CROSS JOIN LATERAL
                    jsonb_array_elements(pr2.errors) e(value)
            ),
            '[]'::jsonb
        )
    INTO v_rounds,v_errors
    FROM per_round pr;

    -- Reincorporar mismatch de cantidad, si lo hubiera.
    IF v_declared<=0 OR v_active<>v_declared THEN
        v_errors :=
            jsonb_build_array(
                jsonb_build_object(
                    'code','round_count_mismatch',
                    'message',format(
                        'El torneo declara %s ronda(s) y actualmente tiene %s ronda(s) activa(s).',
                        v_declared,v_active
                    )
                )
            ) || COALESCE(v_errors,'[]'::jsonb);
    END IF;

    v_error_count := jsonb_array_length(COALESCE(v_errors,'[]'::jsonb));

    RETURN jsonb_build_object(
        'complete',v_error_count=0,
        'status',CASE WHEN v_error_count=0 THEN 'COMPLETE' ELSE 'INCOMPLETE' END,
        'frozen',false,
        'declaredRounds',v_declared,
        'activeRounds',v_active,
        'errors',COALESCE(v_errors,'[]'::jsonb),
        'rounds',COALESCE(v_rounds,'[]'::jsonb),
        'message',
            CASE
                WHEN v_error_count=0
                    THEN 'Todas las rondas tienen completa su configuración estructural.'
                ELSE 'Una o más rondas tienen configuración estructural pendiente.'
            END,
        'recommendation',
            CASE
                WHEN v_error_count=0 THEN NULL
                ELSE 'Revisa la pestaña Rondas y completa fecha, campo, modalidad, Handicap Allowance, formato de salida y al menos un turno activo.'
            END
    );
END;
$function$;

COMMENT ON FUNCTION
public.obtener_estado_configuracion_rondas_263(uuid)
IS
'M263: valida la configuración estructural de rondas previa al congelamiento, incluyendo motor de salida soportado.';

REVOKE ALL
ON FUNCTION public.obtener_estado_configuracion_rondas_263(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.obtener_estado_configuracion_rondas_263(uuid)
TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Asistente v16
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._obtener_asistente_operativo_torneo_v16_263(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_result jsonb;
    v_source_steps jsonb := '[]'::jsonb;
    v_with_rounds jsonb := '[]'::jsonb;
    v_final_steps jsonb := '[]'::jsonb;

    v_state jsonb;
    v_rounds_complete boolean := false;

    v_step jsonb;
    v_elem jsonb;
    v_current_actionable boolean := true;

    v_blockers jsonb := '[]'::jsonb;
    v_next_action jsonb := NULL;
    v_total integer := 0;
    v_completed integer := 0;
BEGIN
    v_result :=
        public._obtener_asistente_operativo_torneo_v15_262(
            p_tournament_id
        );

    v_source_steps := COALESCE(v_result->'steps','[]'::jsonb);

    v_state :=
        public.obtener_estado_configuracion_rondas_263(
            p_tournament_id
        );

    v_rounds_complete := COALESCE(
        (v_state->>'complete')::boolean,
        false
    );

    v_step := jsonb_build_object(
        'code','ROUND_CONFIGURATION',
        'scope','TOURNAMENT',
        'title','Rondas',
        'status',
            CASE
                WHEN v_rounds_complete THEN 'COMPLETE'
                ELSE 'BLOCKED'
            END,
        'message',v_state->>'message',
        'recommendation',v_state->>'recommendation',
        'details',v_state,
        'action',
            CASE
                WHEN v_rounds_complete THEN NULL
                ELSE jsonb_build_object(
                    'label','Revisar rondas',
                    'target','rondas'
                )
            END,
        'requiredRole','TOURNAMENT_OPERATOR',
        'availability',jsonb_build_object(
            'actionable',NOT v_rounds_complete,
            'state',
                CASE
                    WHEN v_rounds_complete THEN 'COMPLETE'
                    ELSE 'AVAILABLE'
                END,
            'waitingFor',NULL
        )
    );

    -- Insertar RONDAS inmediatamente antes de FREEZE.
    FOR v_elem IN
        SELECT elem
        FROM jsonb_array_elements(v_source_steps) x(elem)
    LOOP
        IF v_elem->>'code'='FREEZE' THEN
            v_with_rounds :=
                v_with_rounds || jsonb_build_array(v_step);
        END IF;

        v_with_rounds :=
            v_with_rounds || jsonb_build_array(v_elem);
    END LOOP;

    -- FREEZE no puede ser accionable hasta completar RONDAS.
    -- Si ya esperaba por un requisito previo, se conserva esa dependencia.
    FOR v_elem IN
        SELECT elem
        FROM jsonb_array_elements(v_with_rounds) x(elem)
    LOOP
        IF v_elem->>'code'='FREEZE'
           AND NOT v_rounds_complete
        THEN
            v_current_actionable := COALESCE(
                (v_elem #>> '{availability,actionable}')::boolean,
                true
            );

            IF v_current_actionable THEN
                v_elem := jsonb_set(
                    v_elem,
                    '{availability}',
                    jsonb_build_object(
                        'actionable',false,
                        'state','WAITING',
                        'waitingFor','ROUND_CONFIGURATION'
                    ),
                    true
                );

                v_elem := jsonb_set(
                    v_elem,
                    '{action}',
                    'null'::jsonb,
                    true
                );
            END IF;
        END IF;

        v_final_steps :=
            v_final_steps || jsonb_build_array(v_elem);
    END LOOP;

    SELECT COALESCE(
        jsonb_agg(s.elem ORDER BY s.ord),
        '[]'::jsonb
    )
      INTO v_blockers
      FROM jsonb_array_elements(v_final_steps)
           WITH ORDINALITY AS s(elem,ord)
     WHERE s.elem->>'status'='BLOCKED'
       AND COALESCE(
           (s.elem #>> '{availability,actionable}')::boolean,
           true
       );

    SELECT s.elem->'action'
      INTO v_next_action
      FROM jsonb_array_elements(v_final_steps)
           WITH ORDINALITY AS s(elem,ord)
     WHERE s.elem->>'status' IN('BLOCKED','PENDING')
       AND s.elem->'action' IS NOT NULL
       AND s.elem->'action'<>'null'::jsonb
       AND COALESCE(
           (s.elem #>> '{availability,actionable}')::boolean,
           true
       )
     ORDER BY s.ord
     LIMIT 1;

    SELECT
        count(*)::integer,
        count(*) FILTER(
            WHERE elem->>'status'='COMPLETE'
        )::integer
      INTO v_total,v_completed
      FROM jsonb_array_elements(v_final_steps) x(elem);

    v_result := jsonb_set(v_result,'{steps}',v_final_steps,true);
    v_result := jsonb_set(v_result,'{blockers}',v_blockers,true);
    v_result := jsonb_set(
        v_result,
        '{summary,blockingIssues}',
        to_jsonb(jsonb_array_length(v_blockers)),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{progress,completed}',
        to_jsonb(v_completed),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{progress,total}',
        to_jsonb(v_total),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{progress,percent}',
        to_jsonb(
            CASE
                WHEN v_total=0 THEN 0
                ELSE round(100.0*v_completed/v_total,0)
            END
        ),
        true
    );
    v_result := jsonb_set(
        v_result,
        '{nextAction}',
        COALESCE(v_next_action,'null'::jsonb),
        true
    );

    RETURN
        v_result || jsonb_build_object('schemaVersion',16);
END;
$function$;

COMMENT ON FUNCTION
public._obtener_asistente_operativo_torneo_v16_263(uuid)
IS
'M263: agrega ROUND_CONFIGURATION antes de FREEZE y evita recomendar congelamiento con rondas estructuralmente incompletas.';

REVOKE ALL
ON FUNCTION public._obtener_asistente_operativo_torneo_v16_263(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public._obtener_asistente_operativo_torneo_v16_263(uuid)
TO postgres, service_role;

CREATE OR REPLACE FUNCTION public.obtener_asistente_operativo_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RETURN
        public._obtener_asistente_operativo_torneo_v16_263(
            p_tournament_id
        );
END;
$function$;

COMMENT ON FUNCTION public.obtener_asistente_operativo_torneo(uuid)
IS
'M263: Asistente operativo schemaVersion 16; Rondas es paso explícito previo a Congelar condiciones.';

COMMIT;
