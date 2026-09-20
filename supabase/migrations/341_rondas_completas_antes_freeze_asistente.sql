-- ============================================================================
-- MIGRACIÓN 341
-- RONDAS DECLARADAS COMPLETAS ANTES DE FREEZE + ASISTENTE OPERATIVO
-- TEE CENTRAL / GOLF IN FULL
--
-- REGLA:
--   * numero_rondas es el máximo/declaración del torneo.
--   * Las rondas se crean/reactivan desde Rondas, una por una.
--   * Freeze NO cambia: después de Freeze no se crean ni reactivan rondas.
--   * Antes de Freeze deben existir activas todas las rondas 1..numero_rondas.
--   * No toca cortes, motores deportivos ni reprogramación de fecha/hora.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.reconstruir_workflow_extendido_341(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base jsonb;
    v_declared integer;
    v_active integer;
    v_missing integer[];
    v_has_freeze boolean;
    v_reg_status text;
    v_status text;
    v_block text;
    v_nodes integer;
BEGIN
    -- Conserva íntegramente el workflow 337.
    v_base := public.reconstruir_workflow_extendido_337(p_tournament_id);

    SELECT t.numero_rondas
      INTO v_declared
      FROM public.tournaments t
     WHERE t.id = p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo indicado no existe.' USING ERRCODE='22023';
    END IF;

    SELECT count(*)::integer
      INTO v_active
      FROM public.tournament_rounds r
     WHERE r.tournament_id = p_tournament_id
       AND r.activo = true
       AND r.numero_ronda BETWEEN 1 AND COALESCE(v_declared,0);

    SELECT COALESCE(array_agg(gs ORDER BY gs), ARRAY[]::integer[])
      INTO v_missing
      FROM generate_series(1,COALESCE(v_declared,0)) gs
     WHERE NOT EXISTS (
         SELECT 1
           FROM public.tournament_rounds r
          WHERE r.tournament_id=p_tournament_id
            AND r.numero_ronda=gs
            AND r.activo=true
     );

    SELECT EXISTS (
        SELECT 1
          FROM public.tournament_condition_freezes f
         WHERE f.tournament_id=p_tournament_id
    ) INTO v_has_freeze;

    SELECT n.status
      INTO v_reg_status
      FROM public.tournament_workflow_nodes n
     WHERE n.tournament_id=p_tournament_id
       AND n.scope='TOURNAMENT'
       AND n.tournament_round_id IS NULL
       AND n.code='REGISTRATIONS';

    IF v_declared IS NULL OR v_declared < 1 THEN
        v_status := 'BLOCKED';
        v_block := 'CONFIGURATION';
    ELSIF cardinality(v_missing)=0 THEN
        v_status := 'COMPLETE';
        v_block := NULL;
    ELSIF v_has_freeze THEN
        -- Invariante histórica anómala: no se abre ninguna excepción al Freeze.
        v_status := 'BLOCKED';
        v_block := 'FREEZE';
    ELSIF COALESCE(v_reg_status,'BLOCKED')='COMPLETE' THEN
        v_status := 'AVAILABLE';
        v_block := NULL;
    ELSE
        v_status := 'BLOCKED';
        v_block := 'REGISTRATIONS';
    END IF;

    PERFORM public._upsert_workflow_node_332(
        p_tournament_id,
        NULL,
        'TOURNAMENT',
        'ROUND_STRUCTURE',
        25,
        v_status,
        'REGISTRATIONS',
        'FREEZE',
        v_block,
        jsonb_build_object(
            'source','ROUND_STRUCTURE_341',
            'declaredRounds',v_declared,
            'activeRounds',v_active,
            'missingRounds',to_jsonb(v_missing),
            'hasFreeze',v_has_freeze,
            'freezeRuleUnchanged',true
        ),
        CASE
            WHEN v_declared IS NULL OR v_declared < 1
                THEN 'Define el número de rondas del torneo.'
            WHEN cardinality(v_missing)=0
                THEN format('Las %s ronda(s) declaradas están creadas y activas.',v_declared)
            WHEN v_has_freeze
                THEN 'El torneo ya está congelado y existen rondas declaradas faltantes; requiere revisión administrativa.'
            WHEN COALESCE(v_reg_status,'BLOCKED')<>'COMPLETE'
                THEN format('Antes de congelar deberán existir las %s ronda(s) declaradas.',v_declared)
            WHEN cardinality(v_missing)=1
                THEN format('Falta crear la ronda %s antes de congelar el torneo.',v_missing[1])
            ELSE
                format('Faltan crear las rondas %s antes de congelar el torneo.',
                       array_to_string(v_missing,', '))
        END,
        CASE WHEN cardinality(v_missing)=0 THEN now() ELSE NULL END
    );

    UPDATE public.tournament_workflow_nodes
       SET next_code='ROUND_STRUCTURE',
           updated_at=now()
     WHERE tournament_id=p_tournament_id
       AND scope='TOURNAMENT'
       AND tournament_round_id IS NULL
       AND code='REGISTRATIONS';

    UPDATE public.tournament_workflow_nodes
       SET previous_code='ROUND_STRUCTURE',
           status = CASE
               WHEN status='COMPLETE' THEN 'COMPLETE'
               WHEN cardinality(v_missing)>0 THEN 'BLOCKED'
               ELSE status
           END,
           blocked_by_code = CASE
               WHEN status='COMPLETE' THEN blocked_by_code
               WHEN cardinality(v_missing)>0 THEN 'ROUND_STRUCTURE'
               ELSE blocked_by_code
           END,
           detail = CASE
               WHEN status='COMPLETE' THEN detail
               WHEN cardinality(v_missing)>0
                   THEN 'Antes de congelar el torneo deben estar creadas y activas todas las rondas declaradas.'
               ELSE detail
           END,
           updated_at=now()
     WHERE tournament_id=p_tournament_id
       AND scope='TOURNAMENT'
       AND tournament_round_id IS NULL
       AND code='FREEZE';

    SELECT count(*)::integer INTO v_nodes
      FROM public.tournament_workflow_nodes
     WHERE tournament_id=p_tournament_id;

    RETURN jsonb_build_object(
        'ok',true,
        'tournament_id',p_tournament_id,
        'node_count',v_nodes,
        'base',v_base,
        'extended_version',341,
        'round_structure_source','ROUND_STRUCTURE_341',
        'declared_rounds',v_declared,
        'active_rounds',v_active,
        'missing_rounds',to_jsonb(v_missing),
        'freeze_rule_unchanged',true,
        'reconciled_at',now()
    );
END;
$function$;

-- La reconciliación pública/materializada conserva el mismo contrato,
-- pero a partir de 341 incorpora la estructura completa de rondas.
CREATE OR REPLACE FUNCTION public.reconciliar_workflow_torneo_332(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(),p_tournament_id)
        OR public.puede_administrar_congelamiento_torneo(p_tournament_id)
    ) THEN
        RAISE EXCEPTION 'No tienes permiso para reconciliar el workflow de este torneo.'
            USING ERRCODE='42501';
    END IF;

    RETURN public.reconstruir_workflow_extendido_341(p_tournament_id);
END;
$function$;

-- Adaptador final: conserva 340 (incluido PENDING_PAYMENTS) y únicamente
-- convierte ROUND_STRUCTURE AVAILABLE en la acción operativa "Crear ronda N".
CREATE OR REPLACE FUNCTION public._adaptar_asistente_rondas_341(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_result jsonb;
    v_node record;
    v_next_round integer;
    v_action jsonb;
BEGIN
    v_result := public._adaptar_asistente_pagos_pendientes_340(p_tournament_id);

    SELECT n.*
      INTO v_node
      FROM public.tournament_workflow_nodes n
     WHERE n.tournament_id=p_tournament_id
       AND n.scope='TOURNAMENT'
       AND n.tournament_round_id IS NULL
       AND n.code='ROUND_STRUCTURE';

    IF FOUND AND v_node.status='AVAILABLE' THEN
        SELECT gs
          INTO v_next_round
          FROM generate_series(
              1,
              COALESCE((v_node.evidence->>'declaredRounds')::integer,0)
          ) gs
         WHERE NOT EXISTS (
             SELECT 1
               FROM public.tournament_rounds r
              WHERE r.tournament_id=p_tournament_id
                AND r.numero_ronda=gs
                AND r.activo=true
         )
         ORDER BY gs
         LIMIT 1;

        IF v_next_round IS NOT NULL THEN
            v_action := jsonb_build_object(
                'label',format('Crear ronda %s',v_next_round),
                'target','rondas',
                'roundNumber',v_next_round
            );

            -- En este punto ROUND_STRUCTURE es un requisito real e inmediato
            -- para poder llegar a Freeze.
            v_result := jsonb_set(v_result,'{nextAction}',v_action,true);
        END IF;
    END IF;

    v_result := jsonb_set(v_result,'{schemaVersion}','341'::jsonb,true);
    RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.obtener_asistente_operativo_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT public._adaptar_asistente_rondas_341($1);
$function$;

COMMIT;
