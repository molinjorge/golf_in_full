-- ============================================================================
-- MIGRACION 185 FASE 1D
-- ENRIQUECER LECTURA DE SALIDAS PREPARADAS TEE TIMES
-- TEE CENTRAL
--
-- PROBLEMA
-- obtener_conformacion_tee_times(uuid) devolvía grupos materializados, pero:
-- - categoryConfigId sin nombre/código de categoría;
-- - unidades sólo con registration id + orden;
-- - horaSalida como timestamptz crudo, sin representación local HH:MM.
--
-- La materialización YA estaba correcta: los jugadores sí existen en
-- tournament_group_players y las horas están correctamente persistidas.
--
-- OBJETIVO
-- Hacer que la RPC de lectura sea autosuficiente para la UI:
-- - categoría real del grupo;
-- - jugadores congelados de la ronda;
-- - folio congelado;
-- - handicap index congelado;
-- - hora oficial timestamptz;
-- - hora local HH:MM según timezone del campo de golf;
-- - conservar todos los campos previos.
--
-- AUTORIDAD DE DATOS
-- Para jugador/folio/hándicap se usan snapshots congelados:
--   tournament_round_handicap_snapshots
--     -> tournament_handicap_snapshots
--
-- No se leen nombres/hándicaps vivos para reconstruir una salida ya preparada.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_conformacion_tee_times(
    p_shift_config_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_shift_id uuid;
    v_round_id uuid;
    v_tournament_id uuid;
    v_timezone text;
    v_result jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        cfg.tournament_round_shift_id,
        rs.tournament_round_id,
        tr.tournament_id,
        cg.timezone_id
      INTO
        v_shift_id,
        v_round_id,
        v_tournament_id,
        v_timezone
      FROM public.tournament_tee_time_shift_configs cfg
      JOIN public.tournament_round_shifts rs
        ON rs.id = cfg.tournament_round_shift_id
      JOIN public.tournament_rounds tr
        ON tr.id = rs.tournament_round_id
      JOIN public.campos_golf cg
        ON cg.id = tr.campo_golf_id
       AND cg.activo = true
      JOIN public.timezones tz
        ON tz.iana_id = cg.timezone_id
       AND tz.activo = true
     WHERE cfg.id = p_shift_config_id
       AND cfg.activo;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La configuración Tee Times del turno no existe, está inactiva o no tiene zona horaria válida.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar esta conformación Tee Times.'
            USING ERRCODE = '42501';
    END IF;

    SELECT jsonb_build_object(
        'shiftConfigId', p_shift_config_id,
        'tournamentRoundShiftId', v_shift_id,
        'roundId', v_round_id,
        'timezone', v_timezone,

        'groups', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'groupId', g.id,
                    'teeTimeGroupId', ttg.id,

                    'categoryConfigId',
                        ttg.tournament_tee_time_category_config_id,

                    'tournamentCategoryId',
                        sc.tournament_category_id,

                    'categoryId',
                        tc.category_id,

                    'categoryCode',
                        cat.codigo,

                    'categoryName',
                        cat.nombre,

                    'categoryDisplayOrder',
                        cat.display_order,

                    'categoryPreferredStartLane',
                        cc.preferred_start_lane,

                    'startHoleId',
                        ttg.tournament_tee_time_start_hole_id,

                    'actualLaneOrder',
                        sh.lane_order,

                    'startLaneOverride',
                        CASE
                            WHEN cc.preferred_start_lane = 'BOTH' THEN false
                            WHEN cc.preferred_start_lane = 'LANE_1'
                                 AND sh.lane_order = 1 THEN false
                            WHEN cc.preferred_start_lane = 'LANE_2'
                                 AND sh.lane_order = 2 THEN false
                            ELSE true
                        END,

                    'hoyoId',
                        g.hoyo_id,

                    'numeroHoyo',
                        h.numero_hoyo,

                    'sequenceNumber',
                        ttg.sequence_number,

                    'horaSalida',
                        g.hora_salida,

                    'horaSalidaLocal',
                        to_char(
                            g.hora_salida AT TIME ZONE v_timezone,
                            'HH24:MI'
                        ),

                    'etiqueta',
                        g.etiqueta,

                    'unidades', COALESCE((
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'id',
                                    gp.tournament_registration_id,

                                'registrationId',
                                    gp.tournament_registration_id,

                                'playerId',
                                    hs.player_id,

                                'playerName',
                                    hs.player_name,

                                'registrationFolio',
                                    hs.registration_folio,

                                'handicapIndex',
                                    hs.handicap_index,

                                'handicapSource',
                                    hs.handicap_source,

                                'tournamentCategoryId',
                                    hs.tournament_category_id,

                                'categoryName',
                                    hs.category_name,

                                'orden',
                                    gp.orden_en_grupo
                            )
                            ORDER BY
                                gp.orden_en_grupo NULLS LAST,
                                gp.created_at,
                                gp.id
                        )
                        FROM public.tournament_group_players gp
                        LEFT JOIN public.tournament_round_handicap_snapshots rhs
                          ON rhs.tournament_round_id = v_round_id
                         AND rhs.tournament_registration_id =
                             gp.tournament_registration_id
                        LEFT JOIN public.tournament_handicap_snapshots hs
                          ON hs.id = rhs.handicap_snapshot_id
                        WHERE gp.tournament_group_id = g.id
                    ), '[]'::jsonb)
                )
                ORDER BY
                    sh.lane_order,
                    ttg.sequence_number,
                    g.id
            )
            FROM public.tournament_tee_time_groups ttg
            JOIN public.tournament_groups g
              ON g.id = ttg.tournament_group_id
             AND g.activo

            JOIN public.tournament_tee_time_shift_start_holes sh
              ON sh.id = ttg.tournament_tee_time_start_hole_id
             AND sh.activo

            JOIN public.hoyos h
              ON h.id = g.hoyo_id

            JOIN public.tournament_tee_time_category_configs cc
              ON cc.id = ttg.tournament_tee_time_category_config_id
             AND cc.activo

            JOIN public.tournament_round_shift_categories sc
              ON sc.id = cc.tournament_round_shift_category_id
             AND sc.activo

            JOIN public.tournament_categories tc
              ON tc.id = sc.tournament_category_id

            JOIN public.categories cat
              ON cat.id = tc.category_id

            WHERE sh.tournament_tee_time_shift_config_id =
                p_shift_config_id
              AND ttg.activo
        ), '[]'::jsonb),

        'materialized', EXISTS (
            SELECT 1
            FROM public.tournament_tee_time_groups ttg
            JOIN public.tournament_tee_time_shift_start_holes sh
              ON sh.id = ttg.tournament_tee_time_start_hole_id
            WHERE sh.tournament_tee_time_shift_config_id =
                p_shift_config_id
              AND ttg.activo
        )
    )
    INTO v_result;

    RETURN v_result;
END;
$function$;

REVOKE ALL
ON FUNCTION public.obtener_conformacion_tee_times(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.obtener_conformacion_tee_times(uuid)
TO authenticated, service_role;

COMMIT;
