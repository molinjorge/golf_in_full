-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 232 — REPARACIÓN CONTROLADA DE HCP TEAM FALTANTE EN FREEZE HISTÓRICO
--
-- Objetivo:
-- Resolver exclusivamente el hueco histórico previo a la Migración 231:
-- un torneo A-Go-Go/team_stroke con clasificación Neto que ya quedó congelado
-- sin configuración HCP TEAM.
--
-- Principios:
-- 1) NO elimina, modifica ni sustituye el freeze ni ningún snapshot congelado.
-- 2) Sólo opera si el torneo ya está congelado y todas sus rondas congeladas
--    son A_GOGO + equipo + team_stroke.
-- 3) Exige que el freeze tenga clasificación Neto.
-- 4) Exige ausencia TOTAL de configuración/versión HCP TEAM previa.
-- 5) Exige ausencia TOTAL de evidencia competitiva posterior:
--    validaciones de salida, emisiones, score cards, snapshots/revisiones TEAM.
-- 6) No permite GROSS_ONLY porque la reparación sólo aplica a un freeze con Neto.
-- 7) Configura y recalcula todos los HCP TEAM de todas las rondas activas
--    dentro de la MISMA transacción. Si un recálculo falla, todo se revierte.
-- 8) Registra la reparación en audit_log como INSERT de la configuración,
--    incluyendo freezeId y marcador MIGRATION_232_HISTORICAL_REPAIR.
--
-- NO hace:
-- - No cambia Stroke Play ni Stableford.
-- - No cambia composición, categorías, tees, grupos ni salidas.
-- - No reabre ni elimina congelamientos.
-- - No modifica funciones existentes de captura, tarjetas, resultados o cierre.
-- - No habilita cambios generales de HCP TEAM post-freeze.
-- - No contiene IDs de torneos ni datos específicos del caso de prueba.

BEGIN;

CREATE OR REPLACE FUNCTION public.reparar_hcp_team_faltante_freeze_historico_232(
    p_tournament_id uuid,
    p_method text,
    p_average_pct numeric DEFAULT NULL,
    p_ranges jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_admin_id uuid;
    v_freeze_id uuid;
    v_config_id uuid;
    v_ranges jsonb := COALESCE(p_ranges, '[]'::jsonb);
    v_round record;
    v_round_results jsonb := '[]'::jsonb;
    v_round_result jsonb;
    v_round_count integer := 0;
    v_team_count integer := 0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para reparar este torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo = true
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No existe administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    -- Serializa cualquier intento de reparación/configuración sobre el torneo.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_tournament_id::text, 232)
    );

    PERFORM 1
      FROM public.tournaments t
     WHERE t.id = p_tournament_id
       AND t.activo = true
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El torneo no existe o está inactivo.'
            USING ERRCODE = '22023';
    END IF;

    SELECT f.id
      INTO v_freeze_id
      FROM public.tournament_condition_freezes f
     WHERE f.tournament_id = p_tournament_id
     LIMIT 1;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION
            'La reparación 232 sólo aplica a un torneo que ya tiene congelamiento histórico.'
            USING ERRCODE = '55000';
    END IF;

    -- Contrato ultra estricto: TODAS las rondas activas/congeladas del torneo
    -- deben corresponder al motor A-Go-Go TEAM.
    IF NOT EXISTS (
        SELECT 1
        FROM public.tournament_round_condition_snapshots rcs
        WHERE rcs.freeze_id = v_freeze_id
    ) THEN
        RAISE EXCEPTION
            'El congelamiento no contiene snapshots de ronda.'
            USING ERRCODE = '55000';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_round_condition_snapshots rcs
        WHERE rcs.freeze_id = v_freeze_id
          AND (
              rcs.format_code IS DISTINCT FROM 'A_GOGO'
              OR rcs.participation_type IS DISTINCT FROM 'equipo'
              OR rcs.scoring_engine IS DISTINCT FROM 'team_stroke'
          )
    ) THEN
        RAISE EXCEPTION
            'La reparación 232 sólo aplica a congelamientos exclusivamente A_GOGO/equipo/team_stroke.'
            USING ERRCODE = '55000';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_rounds tr
        WHERE tr.tournament_id = p_tournament_id
          AND tr.activo = true
          AND NOT EXISTS (
              SELECT 1
              FROM public.tournament_round_condition_snapshots rcs
              WHERE rcs.freeze_id = v_freeze_id
                AND rcs.tournament_round_id = tr.id
                AND rcs.format_code = 'A_GOGO'
                AND rcs.participation_type = 'equipo'
                AND rcs.scoring_engine = 'team_stroke'
          )
    ) THEN
        RAISE EXCEPTION
            'Las rondas activas actuales no coinciden íntegramente con el freeze A-Go-Go.'
            USING ERRCODE = '55000';
    END IF;

    -- El motivo de esta reparación debe existir EN EL FREEZE:
    -- al menos una clasificación Neto congelada.
    IF NOT EXISTS (
        SELECT 1
        FROM public.tournament_category_classification_snapshots ccs
        WHERE ccs.freeze_id = v_freeze_id
          AND ccs.tipo_resultado::text = 'neto'
    ) THEN
        RAISE EXCEPTION
            'La reparación 232 sólo aplica si el freeze contiene clasificación Neto.'
            USING ERRCODE = '55000';
    END IF;

    -- Debe ser exactamente el hueco histórico: nunca hubo configuración TEAM HCP.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_team_handicap_configs c
        WHERE c.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'El torneo ya tiene o tuvo configuración HCP TEAM; la reparación 232 no puede usarse.'
            USING ERRCODE = '55000';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_round_team_handicap_versions v
        WHERE v.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'Ya existen versiones HCP TEAM; la reparación 232 no puede usarse.'
            USING ERRCODE = '55000';
    END IF;

    -- CANDADOS DE NO INICIO COMPETITIVO.
    -- Se revisa la existencia histórica, no sólo estados activos, para evitar
    -- "reparar" un torneo que ya generó evidencia y luego la anuló/reabrió.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_round_start_validations v
        WHERE v.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'Ya existe historial de validación de salidas; no procede la reparación 232.'
            USING ERRCODE = '55000';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_score_card_emissions e
        WHERE e.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'Ya existe historial de emisión de tarjetas; no procede la reparación 232.'
            USING ERRCODE = '55000';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_score_cards sc
        WHERE sc.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'Ya existen score cards; no procede la reparación 232.'
            USING ERRCODE = '55000';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_team_scorecard_snapshots ts
        WHERE ts.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'Ya existen snapshots de tarjeta TEAM; no procede la reparación 232.'
            USING ERRCODE = '55000';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_team_scorecard_revisions trv
        WHERE trv.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'Ya existen revisiones de tarjeta TEAM; no procede la reparación 232.'
            USING ERRCODE = '55000';
    END IF;

    -- Métodos permitidos para una clasificación Neto.
    IF p_method NOT IN (
        'AVERAGE_HI_PCT',
        'ASSIGNED_TABLE_SUM_HI',
        'WHS_SCRAMBLE'
    ) THEN
        RAISE EXCEPTION
            'Método inválido para reparación Neto. Use AVERAGE_HI_PCT, ASSIGNED_TABLE_SUM_HI o WHS_SCRAMBLE.'
            USING ERRCODE = '22023';
    END IF;

    IF p_method = 'AVERAGE_HI_PCT'
       AND (
           p_average_pct IS NULL
           OR p_average_pct < 0
           OR p_average_pct > 100
       ) THEN
        RAISE EXCEPTION
            'AVERAGE_HI_PCT requiere porcentaje entre 0 y 100.'
            USING ERRCODE = '22023';
    END IF;

    IF jsonb_typeof(v_ranges) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'p_ranges debe ser un arreglo JSON.'
            USING ERRCODE = '22023';
    END IF;

    IF p_method = 'ASSIGNED_TABLE_SUM_HI' THEN
        IF jsonb_array_length(v_ranges) = 0 THEN
            RAISE EXCEPTION
                'ASSIGNED_TABLE_SUM_HI requiere al menos un rango.'
                USING ERRCODE = '22023';
        END IF;

        IF EXISTS (
            SELECT 1
            FROM jsonb_to_recordset(v_ranges)
                 AS x(
                     "from" numeric,
                     "to" numeric,
                     "assignedTeamHandicap" numeric,
                     "displayOrder" integer
                 )
            WHERE x."from" IS NULL
               OR x."assignedTeamHandicap" IS NULL
               OR (
                   x."to" IS NOT NULL
                   AND x."to" < x."from"
               )
        ) THEN
            RAISE EXCEPTION
                'Cada rango requiere from y assignedTeamHandicap; to no puede ser menor que from.'
                USING ERRCODE = '22023';
        END IF;

        IF EXISTS (
            WITH input_ranges AS (
                SELECT
                    row_number() OVER () AS rn,
                    x."from" AS h_from,
                    x."to" AS h_to
                FROM jsonb_to_recordset(v_ranges)
                     AS x(
                         "from" numeric,
                         "to" numeric,
                         "assignedTeamHandicap" numeric,
                         "displayOrder" integer
                     )
            )
            SELECT 1
            FROM input_ranges a
            JOIN input_ranges b
              ON a.rn < b.rn
             AND numrange(a.h_from, a.h_to, '[]')
                 && numrange(b.h_from, b.h_to, '[]')
        ) THEN
            RAISE EXCEPTION 'Los rangos HCP TEAM no pueden traslaparse.'
                USING ERRCODE = '22023';
        END IF;
    ELSE
        IF jsonb_array_length(v_ranges) <> 0 THEN
            RAISE EXCEPTION
                'p_ranges sólo puede enviarse con ASSIGNED_TABLE_SUM_HI.'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    -- Inserción única. NO se usa UPSERT deliberadamente:
    -- si aparece una configuración concurrente, la transacción debe fallar.
    INSERT INTO public.tournament_team_handicap_configs(
        tournament_id,
        method,
        average_pct,
        rounding_mode,
        active,
        created_by,
        updated_by
    )
    VALUES(
        p_tournament_id,
        p_method,
        CASE
            WHEN p_method = 'AVERAGE_HI_PCT' THEN p_average_pct
            ELSE NULL
        END,
        'NEAREST_INTEGER',
        true,
        v_admin_id,
        v_admin_id
    )
    RETURNING id INTO v_config_id;

    IF p_method = 'ASSIGNED_TABLE_SUM_HI' THEN
        INSERT INTO public.tournament_team_handicap_ranges(
            config_id,
            handicap_sum_from,
            handicap_sum_to,
            assigned_team_handicap,
            display_order
        )
        SELECT
            v_config_id,
            (e.obj->>'from')::numeric,
            NULLIF(e.obj->>'to','')::numeric,
            (e.obj->>'assignedTeamHandicap')::numeric,
            COALESCE(
                NULLIF(e.obj->>'displayOrder','')::integer,
                e.ordinality::integer - 1
            )
        FROM jsonb_array_elements(v_ranges) WITH ORDINALITY
             AS e(obj, ordinality);
    END IF;

    -- Recalcula TODAS las rondas activas A-Go-Go dentro de esta misma
    -- transacción. Cualquier error revierte configuración, rangos y versiones.
    FOR v_round IN
        SELECT tr.id, tr.numero_ronda
        FROM public.tournament_rounds tr
        WHERE tr.tournament_id = p_tournament_id
          AND tr.activo = true
        ORDER BY tr.numero_ronda, tr.id
    LOOP
        v_round_result :=
            public.recalcular_handicaps_equipos_a_gogo_ronda(v_round.id);

        v_round_results :=
            v_round_results || jsonb_build_array(
                jsonb_build_object(
                    'roundId', v_round.id,
                    'roundNumber', v_round.numero_ronda,
                    'result', v_round_result
                )
            );

        v_round_count := v_round_count + 1;
        v_team_count := v_team_count
            + COALESCE((v_round_result->>'recalculatedCount')::integer, 0);
    END LOOP;

    -- Auditoría explícita de la excepción histórica.
    INSERT INTO public.audit_log(
        tabla,
        registro_id,
        accion,
        realizado_por,
        datos_nuevos
    )
    VALUES(
        'tournament_team_handicap_configs',
        v_config_id,
        'INSERT',
        v_admin_id,
        jsonb_build_object(
            'repairCode', 'MIGRATION_232_HISTORICAL_REPAIR',
            'tournamentId', p_tournament_id,
            'freezeId', v_freeze_id,
            'configId', v_config_id,
            'method', p_method,
            'averagePct',
                CASE
                    WHEN p_method = 'AVERAGE_HI_PCT' THEN p_average_pct
                    ELSE NULL
                END,
            'rangeCount',
                CASE
                    WHEN p_method = 'ASSIGNED_TABLE_SUM_HI'
                    THEN jsonb_array_length(v_ranges)
                    ELSE 0
                END,
            'roundsRecalculated', v_round_count,
            'teamVersionsCreated', v_team_count,
            'reason',
                'Reparación controlada de freeze histórico creado antes de Migración 231 sin HCP TEAM requerido para Neto.'
        )
    );

    RETURN jsonb_build_object(
        'ok', true,
        'repairCode', 'MIGRATION_232_HISTORICAL_REPAIR',
        'tournamentId', p_tournament_id,
        'freezeId', v_freeze_id,
        'configId', v_config_id,
        'method', p_method,
        'roundsRecalculated', v_round_count,
        'teamVersionsCreated', v_team_count,
        'roundResults', v_round_results
    );
END;
$function$;

COMMENT ON FUNCTION public.reparar_hcp_team_faltante_freeze_historico_232(
    uuid, text, numeric, jsonb
) IS
'Reparación excepcional y atómica para freezes históricos A-Go-Go/team_stroke con Neto creados antes de la Migración 231 sin HCP TEAM. No modifica snapshots ni permite uso si ya existe evidencia competitiva.';

REVOKE ALL ON FUNCTION public.reparar_hcp_team_faltante_freeze_historico_232(
    uuid, text, numeric, jsonb
) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.reparar_hcp_team_faltante_freeze_historico_232(
    uuid, text, numeric, jsonb
) FROM anon;

GRANT EXECUTE ON FUNCTION public.reparar_hcp_team_faltante_freeze_historico_232(
    uuid, text, numeric, jsonb
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.reparar_hcp_team_faltante_freeze_historico_232(
    uuid, text, numeric, jsonb
) TO service_role;

COMMIT;
