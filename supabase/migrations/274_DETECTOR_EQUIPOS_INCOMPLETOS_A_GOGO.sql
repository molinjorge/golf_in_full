-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 274
-- Detector de equipos incompletos / jugadores sueltos A-Go-Go
--
-- OBJETIVO
--   Crear una fuente única, de sólo lectura, para conocer la
--   composición competitiva REAL de un torneo A-Go-Go TEAM
--   antes de START_TOURNAMENT.
--
-- ALCANCE
--   - Sólo A_GOGO + equipo + team_stroke.
--   - No modifica equipos, inscripciones, HCP TEAM, salidas,
--     tarjetas, marcadores, scores ni resultados.
--   - Un equipo activo con 1 inscripción activa se considera
--     INCOMPLETE y su único integrante es un "loose player".
--   - Un equipo activo con 0 integrantes se reporta como EMPTY,
--     pero no genera por sí solo un jugador suelto.
--   - También reporta inscripciones activas sin equipo.
--   - El mínimo competitivo formal queda expresado como 2.
--
-- NOTA
--   Esta migración NO bloquea todavía START_TOURNAMENT.
--   Esa integración corresponde a la fase siguiente.
-- ============================================================

CREATE OR REPLACE FUNCTION public.obtener_estado_equipos_incompletos_a_gogo_274(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament public.tournaments%ROWTYPE;
    v_format record;

    v_teams jsonb := '[]'::jsonb;
    v_incomplete_teams jsonb := '[]'::jsonb;
    v_empty_teams jsonb := '[]'::jsonb;
    v_loose_players jsonb := '[]'::jsonb;
    v_unassigned_players jsonb := '[]'::jsonb;

    v_active_team_count integer := 0;
    v_incomplete_team_count integer := 0;
    v_empty_team_count integer := 0;
    v_loose_player_count integer := 0;
    v_unassigned_player_count integer := 0;
    v_configured_team_size integer;
BEGIN
    IF p_tournament_id IS NULL THEN
        RAISE EXCEPTION 'Debes indicar el torneo.'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
      INTO v_tournament
      FROM public.tournaments
     WHERE id = p_tournament_id
       AND activo = true;

    IF v_tournament.id IS NULL THEN
        RAISE EXCEPTION 'El torneo no existe o está inactivo.'
            USING ERRCODE = 'P0002';
    END IF;

    SELECT tf.code,
           tf.tipo_participacion::text AS participation_type,
           tf.scoring_engine::text AS scoring_engine
      INTO v_format
      FROM public.tournament_formats tf
     WHERE tf.id = v_tournament.tournament_format_id
       AND tf.activo = true;

    IF v_format.code IS DISTINCT FROM 'A_GOGO'
       OR v_format.participation_type IS DISTINCT FROM 'equipo'
       OR v_format.scoring_engine IS DISTINCT FROM 'team_stroke'
    THEN
        RAISE EXCEPTION
            'Este diagnóstico sólo aplica a torneos A-Go-Go TEAM (A_GOGO/equipo/team_stroke).'
            USING ERRCODE = '22023';
    END IF;

    -- Lectura administrativa: el mismo ámbito usado por las
    -- operaciones controladas post-freeze del torneo.
    IF auth.uid() IS NOT NULL
       AND NOT public.puede_administrar_congelamiento_torneo(v_tournament.id)
    THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar la composición administrativa de este torneo.'
            USING ERRCODE = '42501';
    END IF;

    v_configured_team_size := v_tournament.jugadores_por_equipo;

    WITH team_state AS (
        SELECT
            tt.id AS team_id,
            tt.nombre_equipo AS team_name,
            tt.tournament_category_id AS category_id,
            COUNT(tr.id)::integer AS active_member_count,
            COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'registrationId', tr.id,
                        'playerId', tr.player_id,
                        'name', btrim(concat_ws(' ', p.nombres, p.apellidos)),
                        'email', p.email::text,
                        'teeId', tr.marca_salida_id
                    )
                    ORDER BY p.apellidos, p.nombres, tr.id
                ) FILTER (WHERE tr.id IS NOT NULL),
                '[]'::jsonb
            ) AS members
        FROM public.tournament_teams tt
        LEFT JOIN public.tournament_registrations tr
          ON tr.tournament_team_id = tt.id
         AND tr.tournament_id = tt.tournament_id
         AND tr.activo = true
        LEFT JOIN public.players p
          ON p.id = tr.player_id
        WHERE tt.tournament_id = v_tournament.id
          AND tt.activo = true
        GROUP BY
            tt.id,
            tt.nombre_equipo,
            tt.tournament_category_id
    ),
    normalized AS (
        SELECT
            ts.*,
            CASE
                WHEN ts.active_member_count = 0 THEN 'EMPTY'
                WHEN ts.active_member_count = 1 THEN 'INCOMPLETE'
                ELSE 'COMPETITIVE'
            END AS composition_status
        FROM team_state ts
    )
    SELECT
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'teamId', n.team_id,
                    'teamName', n.team_name,
                    'categoryId', n.category_id,
                    'activeMemberCount', n.active_member_count,
                    'configuredTeamSize', v_configured_team_size,
                    'minimumCompetitiveMembers', 2,
                    'compositionStatus', n.composition_status,
                    'members', n.members
                )
                ORDER BY n.team_name, n.team_id
            ),
            '[]'::jsonb
        ),
        COUNT(*)::integer,
        COUNT(*) FILTER (WHERE n.composition_status = 'INCOMPLETE')::integer,
        COUNT(*) FILTER (WHERE n.composition_status = 'EMPTY')::integer
    INTO
        v_teams,
        v_active_team_count,
        v_incomplete_team_count,
        v_empty_team_count
    FROM normalized n;

    SELECT COALESCE(
               jsonb_agg(x.item ORDER BY x.team_name, x.team_id),
               '[]'::jsonb
           )
      INTO v_incomplete_teams
      FROM (
          SELECT
              tt.nombre_equipo AS team_name,
              tt.id AS team_id,
              jsonb_build_object(
                  'teamId', tt.id,
                  'teamName', tt.nombre_equipo,
                  'categoryId', tt.tournament_category_id,
                  'activeMemberCount', 1,
                  'configuredTeamSize', v_configured_team_size,
                  'minimumCompetitiveMembers', 2,
                  'compositionStatus', 'INCOMPLETE',
                  'members',
                      jsonb_build_array(
                          jsonb_build_object(
                              'registrationId', tr.id,
                              'playerId', tr.player_id,
                              'name', btrim(concat_ws(' ', p.nombres, p.apellidos)),
                              'email', p.email::text,
                              'teeId', tr.marca_salida_id
                          )
                      )
              ) AS item
          FROM public.tournament_teams tt
          JOIN public.tournament_registrations tr
            ON tr.tournament_team_id = tt.id
           AND tr.tournament_id = tt.tournament_id
           AND tr.activo = true
          JOIN public.players p
            ON p.id = tr.player_id
          WHERE tt.tournament_id = v_tournament.id
            AND tt.activo = true
            AND (
                SELECT COUNT(*)
                FROM public.tournament_registrations tr2
                WHERE tr2.tournament_id = tt.tournament_id
                  AND tr2.tournament_team_id = tt.id
                  AND tr2.activo = true
            ) = 1
      ) x;

    SELECT COALESCE(
               jsonb_agg(x.item ORDER BY x.team_name, x.team_id),
               '[]'::jsonb
           )
      INTO v_empty_teams
      FROM (
          SELECT
              tt.nombre_equipo AS team_name,
              tt.id AS team_id,
              jsonb_build_object(
                  'teamId', tt.id,
                  'teamName', tt.nombre_equipo,
                  'categoryId', tt.tournament_category_id,
                  'activeMemberCount', 0,
                  'configuredTeamSize', v_configured_team_size,
                  'minimumCompetitiveMembers', 2,
                  'compositionStatus', 'EMPTY',
                  'members', '[]'::jsonb
              ) AS item
          FROM public.tournament_teams tt
          WHERE tt.tournament_id = v_tournament.id
            AND tt.activo = true
            AND NOT EXISTS (
                SELECT 1
                FROM public.tournament_registrations tr
                WHERE tr.tournament_id = tt.tournament_id
                  AND tr.tournament_team_id = tt.id
                  AND tr.activo = true
            )
      ) x;

    SELECT
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'registrationId', tr.id,
                    'playerId', tr.player_id,
                    'name', btrim(concat_ws(' ', p.nombres, p.apellidos)),
                    'email', p.email::text,
                    'teeId', tr.marca_salida_id,
                    'teamId', tt.id,
                    'teamName', tt.nombre_equipo,
                    'categoryId', tt.tournament_category_id
                )
                ORDER BY tt.nombre_equipo, p.apellidos, p.nombres, tr.id
            ),
            '[]'::jsonb
        ),
        COUNT(*)::integer
    INTO
        v_loose_players,
        v_loose_player_count
    FROM public.tournament_teams tt
    JOIN public.tournament_registrations tr
      ON tr.tournament_team_id = tt.id
     AND tr.tournament_id = tt.tournament_id
     AND tr.activo = true
    JOIN public.players p
      ON p.id = tr.player_id
    WHERE tt.tournament_id = v_tournament.id
      AND tt.activo = true
      AND (
          SELECT COUNT(*)
          FROM public.tournament_registrations tr2
          WHERE tr2.tournament_id = tt.tournament_id
            AND tr2.tournament_team_id = tt.id
            AND tr2.activo = true
      ) = 1;

    -- Inscripciones activas sin equipo no se mezclan semánticamente
    -- con "loosePlayers", pero se reportan porque también representan
    -- composición pendiente antes del inicio.
    SELECT
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'registrationId', tr.id,
                    'playerId', tr.player_id,
                    'name', btrim(concat_ws(' ', p.nombres, p.apellidos)),
                    'email', p.email::text,
                    'teeId', tr.marca_salida_id,
                    'categoryId', tr.tournament_category_id
                )
                ORDER BY p.apellidos, p.nombres, tr.id
            ),
            '[]'::jsonb
        ),
        COUNT(*)::integer
    INTO
        v_unassigned_players,
        v_unassigned_player_count
    FROM public.tournament_registrations tr
    JOIN public.players p
      ON p.id = tr.player_id
    WHERE tr.tournament_id = v_tournament.id
      AND tr.activo = true
      AND tr.tournament_team_id IS NULL;

    RETURN jsonb_build_object(
        'schemaVersion', 1,
        'tournamentId', v_tournament.id,
        'formatCode', v_format.code,
        'participationType', v_format.participation_type,
        'scoringEngine', v_format.scoring_engine,
        'tournamentStatus', v_tournament.estatus::text,
        'configuredTeamSize', v_configured_team_size,
        'minimumCompetitiveMembers', 2,

        'activeTeamCount', v_active_team_count,
        'incompleteTeamCount', v_incomplete_team_count,
        'emptyTeamCount', v_empty_team_count,
        'loosePlayerCount', v_loose_player_count,
        'unassignedActivePlayerCount', v_unassigned_player_count,

        'hasUnresolvedIncompleteTeams', v_incomplete_team_count > 0,
        'hasUnassignedActivePlayers', v_unassigned_player_count > 0,
        'hasUnresolvedComposition',
            (v_incomplete_team_count > 0 OR v_unassigned_player_count > 0),
        'compositionReady',
            (v_incomplete_team_count = 0 AND v_unassigned_player_count = 0),

        'teams', v_teams,
        'incompleteTeams', v_incomplete_teams,
        'emptyTeams', v_empty_teams,
        'loosePlayers', v_loose_players,
        'unassignedActivePlayers', v_unassigned_players
    );
END;
$function$;

COMMENT ON FUNCTION public.obtener_estado_equipos_incompletos_a_gogo_274(uuid)
IS '274: Diagnóstico de sólo lectura de equipos A-Go-Go incompletos, jugadores sueltos e inscripciones activas sin equipo antes de START_TOURNAMENT.';

REVOKE ALL ON FUNCTION public.obtener_estado_equipos_incompletos_a_gogo_274(uuid)
FROM PUBLIC;

REVOKE ALL ON FUNCTION public.obtener_estado_equipos_incompletos_a_gogo_274(uuid)
FROM anon;

GRANT EXECUTE ON FUNCTION public.obtener_estado_equipos_incompletos_a_gogo_274(uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.obtener_estado_equipos_incompletos_a_gogo_274(uuid)
TO service_role;
