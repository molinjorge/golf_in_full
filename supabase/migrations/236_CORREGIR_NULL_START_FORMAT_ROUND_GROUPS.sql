-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 236
-- Corrección NULL-safe en helper ROUND_GROUPS Shotgun
--
-- OBJETIVO
--   Corregir _estado_conformacion_grupos_ronda_235(uuid) para que una ronda con
--   formato_salida NULL NO sea tratada como Shotgun.
--
-- ALCANCE
--   - Sólo reemplaza la condición:
--         start_format <> 'shotgun'
--     por:
--         start_format IS DISTINCT FROM 'shotgun'
--   - No modifica lógica de scoring.
--   - No modifica Stroke Play, Stableford ni A-Go-Go.
--   - No modifica frontend.
--   - No altera ROUND_GROUPS para rondas Shotgun reales.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._estado_conformacion_grupos_ronda_235(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_round record;
    v_tipo_participacion text;

    v_shift_count integer := 0;
    v_shift_category_count integer := 0;
    v_config_count integer := 0;
    v_group_count integer := 0;

    v_total_units integer := 0;
    v_assigned_units integer := 0;
    v_unassigned_units integer := 0;

    v_category_count integer := 0;
    v_single_category_id uuid := NULL;

    v_status text;
    v_message text;
    v_recommendation text;
BEGIN
    SELECT
        tr.id,
        tr.tournament_id,
        tr.numero_ronda,
        tr.formato_salida::text AS start_format,
        tf.tipo_participacion::text AS tipo_participacion,
        tf.scoring_engine::text AS scoring_engine
      INTO v_round
      FROM public.tournament_rounds tr
      JOIN public.tournaments t
        ON t.id = tr.tournament_id
      JOIN public.tournament_formats tf
        ON tf.id = COALESCE(tr.tournament_format_id, t.tournament_format_id)
     WHERE tr.id = p_tournament_round_id
       AND tr.activo = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La ronda indicada no existe o no está activa.'
            USING ERRCODE = '22023';
    END IF;

    -- 236:
    -- NULL, tee_times o cualquier otro valor distinto de shotgun
    -- quedan explícitamente fuera del contrato ROUND_GROUPS Shotgun.
    IF v_round.start_format IS DISTINCT FROM 'shotgun' THEN
        RETURN jsonb_build_object(
            'applicable', false,
            'status', 'NOT_APPLICABLE',
            'roundId', p_tournament_round_id,
            'roundNumber', v_round.numero_ronda,
            'startFormat', v_round.start_format
        );
    END IF;

    v_tipo_participacion := v_round.tipo_participacion;

    SELECT count(*)::integer
      INTO v_shift_count
      FROM public.tournament_round_shifts s
     WHERE s.tournament_round_id = p_tournament_round_id
       AND s.activo = true;

    SELECT
        count(*)::integer,
        count(DISTINCT sc.tournament_category_id)::integer,
        CASE
            WHEN count(DISTINCT sc.tournament_category_id) = 1
            THEN min(sc.tournament_category_id::text)::uuid
            ELSE NULL
        END
      INTO
        v_shift_category_count,
        v_category_count,
        v_single_category_id
      FROM public.tournament_round_shift_categories sc
      JOIN public.tournament_round_shifts s
        ON s.id = sc.tournament_round_shift_id
     WHERE s.tournament_round_id = p_tournament_round_id
       AND s.activo = true
       AND sc.activo = true;

    SELECT count(*)::integer
      INTO v_config_count
      FROM public.tournament_shotgun_category_configs cfg
      JOIN public.tournament_round_shift_categories sc
        ON sc.id = cfg.tournament_round_shift_category_id
      JOIN public.tournament_round_shifts s
        ON s.id = sc.tournament_round_shift_id
     WHERE s.tournament_round_id = p_tournament_round_id
       AND s.activo = true
       AND sc.activo = true
       AND cfg.activo = true;

    SELECT count(*)::integer
      INTO v_group_count
      FROM public.tournament_groups g
      JOIN public.tournament_round_shifts s
        ON s.id = g.tournament_round_shift_id
     WHERE s.tournament_round_id = p_tournament_round_id
       AND s.activo = true
       AND g.activo = true;

    IF v_tipo_participacion = 'individual' THEN
        SELECT count(*)::integer
          INTO v_total_units
          FROM public.tournament_registrations reg
         WHERE reg.tournament_id = v_round.tournament_id
           AND reg.activo = true
           AND EXISTS (
               SELECT 1
                 FROM public.tournament_round_shift_categories sc
                 JOIN public.tournament_round_shifts s
                   ON s.id = sc.tournament_round_shift_id
                WHERE s.tournament_round_id = p_tournament_round_id
                  AND s.activo = true
                  AND sc.activo = true
                  AND sc.tournament_category_id = reg.tournament_category_id
           );

        SELECT count(*)::integer
          INTO v_assigned_units
          FROM public.tournament_registrations reg
         WHERE reg.tournament_id = v_round.tournament_id
           AND reg.activo = true
           AND EXISTS (
               SELECT 1
                 FROM public.tournament_round_shift_categories sc
                 JOIN public.tournament_round_shifts s
                   ON s.id = sc.tournament_round_shift_id
                WHERE s.tournament_round_id = p_tournament_round_id
                  AND s.activo = true
                  AND sc.activo = true
                  AND sc.tournament_category_id = reg.tournament_category_id
           )
           AND EXISTS (
               SELECT 1
                 FROM public.tournament_group_players gp
                 JOIN public.tournament_groups g
                   ON g.id = gp.tournament_group_id
                 JOIN public.tournament_round_shifts s
                   ON s.id = g.tournament_round_shift_id
                WHERE gp.tournament_registration_id = reg.id
                  AND g.activo = true
                  AND s.activo = true
                  AND s.tournament_round_id = p_tournament_round_id
           );

    ELSIF v_tipo_participacion = 'equipo' THEN
        SELECT count(*)::integer
          INTO v_total_units
          FROM public.tournament_teams tt
         WHERE tt.tournament_id = v_round.tournament_id
           AND tt.activo = true
           AND (
               EXISTS (
                   SELECT 1
                     FROM public.tournament_round_shift_categories sc
                     JOIN public.tournament_round_shifts s
                       ON s.id = sc.tournament_round_shift_id
                    WHERE s.tournament_round_id = p_tournament_round_id
                      AND s.activo = true
                      AND sc.activo = true
                      AND sc.tournament_category_id = tt.tournament_category_id
               )
               OR (
                   tt.tournament_category_id IS NULL
                   AND v_category_count = 1
                   AND v_single_category_id IS NOT NULL
               )
           );

        SELECT count(*)::integer
          INTO v_assigned_units
          FROM public.tournament_teams tt
         WHERE tt.tournament_id = v_round.tournament_id
           AND tt.activo = true
           AND (
               EXISTS (
                   SELECT 1
                     FROM public.tournament_round_shift_categories sc
                     JOIN public.tournament_round_shifts s
                       ON s.id = sc.tournament_round_shift_id
                    WHERE s.tournament_round_id = p_tournament_round_id
                      AND s.activo = true
                      AND sc.activo = true
                      AND sc.tournament_category_id = tt.tournament_category_id
               )
               OR (
                   tt.tournament_category_id IS NULL
                   AND v_category_count = 1
                   AND v_single_category_id IS NOT NULL
               )
           )
           AND EXISTS (
               SELECT 1
                 FROM public.tournament_group_teams gt
                 JOIN public.tournament_groups g
                   ON g.id = gt.tournament_group_id
                 JOIN public.tournament_round_shifts s
                   ON s.id = g.tournament_round_shift_id
                WHERE gt.tournament_team_id = tt.id
                  AND gt.activo = true
                  AND g.activo = true
                  AND s.activo = true
                  AND s.tournament_round_id = p_tournament_round_id
           );
    ELSE
        v_total_units := 0;
        v_assigned_units := 0;
    END IF;

    v_unassigned_units := GREATEST(v_total_units - v_assigned_units, 0);

    IF v_shift_count = 0 THEN
        v_status := 'BLOCKED';
        v_message := format(
            'La ronda %s no tiene turnos activos para preparar los grupos Shotgun.',
            v_round.numero_ronda
        );
        v_recommendation := 'Revisa la configuración estructural de la ronda.';
    ELSIF v_shift_category_count = 0 THEN
        v_status := 'BLOCKED';
        v_message := format(
            'La ronda %s no tiene categorías activas asignadas a sus turnos.',
            v_round.numero_ronda
        );
        v_recommendation := 'Revisa la configuración de categorías por turno.';
    ELSIF v_config_count = 0 THEN
        v_status := 'PENDING';
        v_message := format(
            'La ronda %s todavía no tiene configuración Shotgun materializada para conformar sus grupos.',
            v_round.numero_ronda
        );
        v_recommendation := 'Configura el Shotgun y conforma los grupos de la ronda.';
    ELSIF v_group_count > 0 AND v_unassigned_units = 0 THEN
        v_status := 'COMPLETE';
        v_message := format(
            'Los grupos de la ronda %s están conformados: %s unidad(es) competitiva(s) asignada(s).',
            v_round.numero_ronda,
            v_assigned_units
        );
        v_recommendation := NULL;
    ELSE
        v_status := 'PENDING';
        v_message := format(
            'La ronda %s aún tiene %s de %s unidad(es) competitiva(s) sin grupo de salida.',
            v_round.numero_ronda,
            v_unassigned_units,
            v_total_units
        );
        v_recommendation := 'Completa la conformación de grupos antes de revisar y validar las salidas.';
    END IF;

    RETURN jsonb_build_object(
        'applicable', true,
        'status', v_status,
        'roundId', p_tournament_round_id,
        'roundNumber', v_round.numero_ronda,
        'startFormat', v_round.start_format,
        'tipoParticipacion', v_tipo_participacion,
        'scoringEngine', v_round.scoring_engine,
        'unitKind', CASE
            WHEN v_tipo_participacion = 'equipo' THEN 'TEAM'
            WHEN v_tipo_participacion = 'individual' THEN 'PLAYER'
            ELSE 'UNKNOWN'
        END,
        'shiftCount', v_shift_count,
        'shiftCategoryCount', v_shift_category_count,
        'shotgunConfigCount', v_config_count,
        'shotgunConfigured', v_config_count > 0,
        'activeGroups', v_group_count,
        'totalUnits', v_total_units,
        'assignedUnits', v_assigned_units,
        'unassignedUnits', v_unassigned_units,
        'message', v_message,
        'recommendation', v_recommendation
    );
END;
$function$;

REVOKE ALL ON FUNCTION public._estado_conformacion_grupos_ronda_235(uuid)
FROM PUBLIC, anon, authenticated;

COMMIT;
