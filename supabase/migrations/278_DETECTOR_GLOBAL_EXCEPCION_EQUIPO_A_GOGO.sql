-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 278 - VERSION CORREGIDA
-- Amplía el detector 274 con control global de equipos excepción +1.
--
-- ESTA VERSION SUSTITUYE LA 278 ANTERIOR QUE NO SE EJECUTO.
-- No mueve jugadores. No modifica salidas. No modifica tarjetas.
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
    v_exception_teams jsonb := '[]'::jsonb;
    v_over_capacity_teams jsonb := '[]'::jsonb;
    v_loose_players jsonb := '[]'::jsonb;
    v_unassigned_players jsonb := '[]'::jsonb;

    v_active_team_count integer := 0;
    v_incomplete_team_count integer := 0;
    v_empty_team_count integer := 0;
    v_exception_team_count integer := 0;
    v_over_capacity_team_count integer := 0;
    v_loose_player_count integer := 0;
    v_unassigned_player_count integer := 0;

    v_configured_team_size integer;
    v_has_multiple_exceptions boolean := false;
    v_has_exception_with_loose boolean := false;
    v_composition_ready boolean := false;
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

    IF auth.uid() IS NOT NULL
       AND NOT public.puede_administrar_congelamiento_torneo(v_tournament.id)
    THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar la composición administrativa de este torneo.'
            USING ERRCODE = '42501';
    END IF;

    v_configured_team_size := v_tournament.jugadores_por_equipo;

    IF v_configured_team_size IS NULL OR v_configured_team_size < 2 THEN
        RAISE EXCEPTION
            'El torneo no tiene un tamaño de equipo competitivo válido.'
            USING ERRCODE = '23514';
    END IF;

    -- --------------------------------------------------------
    -- Estado general de cada equipo activo.
    -- EXCEPTION_PLUS_ONE = exactamente tamaño normal + 1,
    -- siempre que no exceda el máximo absoluto de 4.
    -- --------------------------------------------------------
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
                WHEN ts.active_member_count = v_configured_team_size + 1
                     AND ts.active_member_count <= 4
                    THEN 'EXCEPTION_PLUS_ONE'
                WHEN ts.active_member_count > v_configured_team_size
                    THEN 'OVER_CAPACITY'
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
        COUNT(*) FILTER (WHERE n.composition_status = 'EMPTY')::integer,
        COUNT(*) FILTER (WHERE n.composition_status = 'EXCEPTION_PLUS_ONE')::integer,
        COUNT(*) FILTER (WHERE n.composition_status = 'OVER_CAPACITY')::integer
    INTO
        v_teams,
        v_active_team_count,
        v_incomplete_team_count,
        v_empty_team_count,
        v_exception_team_count,
        v_over_capacity_team_count
    FROM normalized n;

    -- Equipos incompletos: exactamente un integrante activo.
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

    -- Equipos activos vacíos.
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

    -- Equipos que usan la excepción +1.
    SELECT COALESCE(
               jsonb_agg(x.item ORDER BY x.team_name, x.team_id),
               '[]'::jsonb
           )
      INTO v_exception_teams
      FROM (
          SELECT
              s.team_name,
              s.team_id,
              jsonb_build_object(
                  'teamId', s.team_id,
                  'teamName', s.team_name,
                  'categoryId', s.category_id,
                  'activeMemberCount', s.active_member_count,
                  'configuredTeamSize', v_configured_team_size,
                  'exceptionDelta', 1,
                  'compositionStatus', 'EXCEPTION_PLUS_ONE',
                  'members', s.members
              ) AS item
          FROM (
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
                      ),
                      '[]'::jsonb
                  ) AS members
              FROM public.tournament_teams tt
              JOIN public.tournament_registrations tr
                ON tr.tournament_team_id = tt.id
               AND tr.tournament_id = tt.tournament_id
               AND tr.activo = true
              JOIN public.players p
                ON p.id = tr.player_id
              WHERE tt.tournament_id = v_tournament.id
                AND tt.activo = true
              GROUP BY
                  tt.id,
                  tt.nombre_equipo,
                  tt.tournament_category_id
          ) s
          WHERE s.active_member_count = v_configured_team_size + 1
            AND s.active_member_count <= 4
      ) x;

    -- Cualquier sobrecupo que NO sea la excepción válida +1.
    SELECT COALESCE(
               jsonb_agg(x.item ORDER BY x.team_name, x.team_id),
               '[]'::jsonb
           )
      INTO v_over_capacity_teams
      FROM (
          SELECT
              s.team_name,
              s.team_id,
              jsonb_build_object(
                  'teamId', s.team_id,
                  'teamName', s.team_name,
                  'categoryId', s.category_id,
                  'activeMemberCount', s.active_member_count,
                  'configuredTeamSize', v_configured_team_size,
                  'compositionStatus', 'OVER_CAPACITY'
              ) AS item
          FROM (
              SELECT
                  tt.id AS team_id,
                  tt.nombre_equipo AS team_name,
                  tt.tournament_category_id AS category_id,
                  COUNT(tr.id)::integer AS active_member_count
              FROM public.tournament_teams tt
              JOIN public.tournament_registrations tr
                ON tr.tournament_team_id = tt.id
               AND tr.tournament_id = tt.tournament_id
               AND tr.activo = true
              WHERE tt.tournament_id = v_tournament.id
                AND tt.activo = true
              GROUP BY
                  tt.id,
                  tt.nombre_equipo,
                  tt.tournament_category_id
          ) s
          WHERE s.active_member_count > v_configured_team_size
            AND NOT (
                s.active_member_count = v_configured_team_size + 1
                AND s.active_member_count <= 4
            )
      ) x;

    -- Jugadores sueltos derivados de equipos con exactamente un activo.
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

    -- Activos sin equipo.
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

    v_has_multiple_exceptions := v_exception_team_count > 1;

    v_has_exception_with_loose :=
        v_exception_team_count > 0
        AND (
            v_loose_player_count > 0
            OR v_unassigned_player_count > 0
        );

    v_composition_ready :=
        v_incomplete_team_count = 0
        AND v_unassigned_player_count = 0
        AND v_over_capacity_team_count = 0
        AND NOT v_has_multiple_exceptions
        AND NOT v_has_exception_with_loose;

    RETURN jsonb_build_object(
        'schemaVersion', 2,
        'tournamentId', v_tournament.id,
        'formatCode', v_format.code,
        'participationType', v_format.participation_type,
        'scoringEngine', v_format.scoring_engine,
        'tournamentStatus', v_tournament.estatus::text,

        'configuredTeamSize', v_configured_team_size,
        'minimumCompetitiveMembers', 2,
        'maximumExceptionTeams', 1,
        'absoluteMaximumTeamSize', 4,

        'activeTeamCount', v_active_team_count,
        'incompleteTeamCount', v_incomplete_team_count,
        'emptyTeamCount', v_empty_team_count,
        'loosePlayerCount', v_loose_player_count,
        'unassignedActivePlayerCount', v_unassigned_player_count,
        'exceptionTeamCount', v_exception_team_count,
        'overCapacityTeamCount', v_over_capacity_team_count,

        'hasUnresolvedIncompleteTeams', v_incomplete_team_count > 0,
        'hasUnassignedActivePlayers', v_unassigned_player_count > 0,
        'hasMultipleExceptionTeams', v_has_multiple_exceptions,
        'hasExceptionTeamWithLoosePlayers', v_has_exception_with_loose,
        'requiresExceptionReconfiguration', v_has_exception_with_loose,
        'hasOverCapacityTeams', v_over_capacity_team_count > 0,

        'hasUnresolvedComposition', NOT v_composition_ready,
        'compositionReady', v_composition_ready,

        'teams', v_teams,
        'incompleteTeams', v_incomplete_teams,
        'emptyTeams', v_empty_teams,
        'exceptionTeams', v_exception_teams,
        'overCapacityTeams', v_over_capacity_teams,
        'loosePlayers', v_loose_players,
        'unassignedActivePlayers', v_unassigned_players
    );
END;
$function$;

COMMENT ON FUNCTION public.obtener_estado_equipos_incompletos_a_gogo_274(uuid)
IS '274/278: detector global A-Go-Go de equipos incompletos, jugadores sueltos y única excepción +1. Si una excepción coexiste con un suelto, la composición vuelve a quedar pendiente antes de START_TOURNAMENT.';

REVOKE ALL ON FUNCTION public.obtener_estado_equipos_incompletos_a_gogo_274(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_estado_equipos_incompletos_a_gogo_274(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_estado_equipos_incompletos_a_gogo_274(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_estado_equipos_incompletos_a_gogo_274(uuid) TO service_role;
