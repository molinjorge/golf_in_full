-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 186 Fase 1P
-- Finalización global del torneo consciente de Stableford multirronda
--
-- OBJETIVO
--   1) Preservar el gate histórico de rondas cerradas.
--   2) Si TODAS las rondas activas congeladas son Stableford Individual:
--        - exigir leaderboard acumulado READY_FOR_PUBLICATION;
--        - incorporar ese leaderboard al snapshot de finalización.
--   3) Si el torneo no es Stableford, preservar el comportamiento histórico.
--   4) Si aparece una mezcla de scoring engines/participation types que incluya
--      Stableford, bloquear finalización hasta diseñar explícitamente ese caso.
--
-- IMPORTANTE
--   finalizar_torneo(uuid,text) ya consume readyToFinalize del preview.
--   No necesita duplicarse ni reescribirse.
--
-- POLÍTICA CONSERVADORA
--   Los outcomes excepcionales por ronda siguen sin recibir efecto global
--   automático. Si el acumulado queda PROVISIONAL por una excepción, el torneo
--   no podrá finalizar hasta que exista una política explícita posterior.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.previsualizar_finalizacion_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
    v_existing public.tournament_competitive_finalizations%ROWTYPE;

    v_total_rounds integer := 0;
    v_closed_rounds integer := 0;
    v_pending_rounds integer := 0;
    v_rounds jsonb := '[]'::jsonb;

    v_frozen_active_rounds integer := 0;
    v_stableford_individual_rounds integer := 0;
    v_stableford_other_rounds integer := 0;
    v_non_stableford_rounds integer := 0;

    v_competition_mode text := 'LEGACY_OR_NON_STABLEFORD';
    v_aggregate_required boolean := false;
    v_aggregate_ready boolean := true;
    v_aggregate_status text := 'NOT_REQUIRED';
    v_aggregate_leaderboard jsonb := NULL;

    v_ready_to_finalize boolean := false;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(
            auth.uid(),
            p_tournament_id
        )
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden consultar la finalización del torneo.'
            USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id=p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El torneo indicado no existe.'
            USING ERRCODE='22023';
    END IF;

    SELECT *
      INTO v_existing
      FROM public.tournament_competitive_finalizations f
     WHERE f.tournament_id=p_tournament_id;

    -- ------------------------------------------------------------------------
    -- Gate histórico: todas las rondas activas deben tener cierre FINAL.
    -- ------------------------------------------------------------------------

    SELECT
        count(*)::integer,

        count(*) FILTER (
            WHERE c.id IS NOT NULL
              AND c.competitive_status='FINAL'
        )::integer,

        count(*) FILTER (
            WHERE c.id IS NULL
               OR c.competitive_status<>'FINAL'
        )::integer,

        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'tournamentRoundId',
                        tr.id,
                    'roundNumber',
                        tr.numero_ronda,
                    'roundDate',
                        tr.fecha,
                    'active',
                        tr.activo,
                    'closed',
                        c.id IS NOT NULL,
                    'competitiveStatus',
                        c.competitive_status,
                    'closureId',
                        c.id,
                    'closedAt',
                        c.closed_at,
                    'closedByAdminUserId',
                        c.closed_by_admin_user_id
                )
                ORDER BY
                    tr.numero_ronda,
                    tr.fecha,
                    tr.id
            ),
            '[]'::jsonb
        )

      INTO
        v_total_rounds,
        v_closed_rounds,
        v_pending_rounds,
        v_rounds

      FROM public.tournament_rounds tr

      LEFT JOIN public.tournament_round_competitive_closures c
        ON c.tournament_round_id=tr.id

     WHERE tr.tournament_id=p_tournament_id
       AND tr.activo=true;

    -- ------------------------------------------------------------------------
    -- Clasificación del scoring de las rondas activas congeladas.
    -- Se toma un snapshot por ronda.
    -- ------------------------------------------------------------------------

    WITH active_round_modes AS (
        SELECT
            tr.id AS tournament_round_id,
            s.scoring_engine,
            s.participation_type

        FROM public.tournament_rounds tr

        LEFT JOIN LATERAL (
            SELECT
                rcs.scoring_engine,
                rcs.participation_type
            FROM public.tournament_round_condition_snapshots rcs
            WHERE rcs.tournament_round_id=tr.id
            ORDER BY
                rcs.created_at DESC,
                rcs.id DESC
            LIMIT 1
        ) s ON true

        WHERE tr.tournament_id=p_tournament_id
          AND tr.activo=true
    )

    SELECT
        count(*) FILTER (
            WHERE scoring_engine IS NOT NULL
        )::integer,

        count(*) FILTER (
            WHERE scoring_engine='stableford'
              AND participation_type='individual'
        )::integer,

        count(*) FILTER (
            WHERE scoring_engine='stableford'
              AND participation_type IS DISTINCT FROM 'individual'
        )::integer,

        count(*) FILTER (
            WHERE scoring_engine IS NOT NULL
              AND scoring_engine<>'stableford'
        )::integer

      INTO
        v_frozen_active_rounds,
        v_stableford_individual_rounds,
        v_stableford_other_rounds,
        v_non_stableford_rounds

      FROM active_round_modes;

    -- ------------------------------------------------------------------------
    -- Gate acumulado Stableford.
    -- ------------------------------------------------------------------------

    IF v_total_rounds>0
       AND v_frozen_active_rounds=v_total_rounds
       AND v_stableford_individual_rounds=v_total_rounds
    THEN
        v_competition_mode := 'STABLEFORD_INDIVIDUAL';
        v_aggregate_required := true;

        v_aggregate_leaderboard :=
            public.obtener_leaderboard_stableford_torneo(
                p_tournament_id
            );

        v_aggregate_status :=
            COALESCE(
                v_aggregate_leaderboard #>>
                    '{status,leaderboardStatus}',
                'UNKNOWN'
            );

        v_aggregate_ready :=
            v_aggregate_status='READY_FOR_PUBLICATION';

    ELSIF v_stableford_individual_rounds>0
       OR v_stableford_other_rounds>0
    THEN
        -- Mezclar Stableford con otro engine o participación todavía no está
        -- diseñado para una clasificación global única.
        v_competition_mode := 'MIXED_OR_UNSUPPORTED';
        v_aggregate_required := true;
        v_aggregate_ready := false;
        v_aggregate_status := 'UNSUPPORTED_TOURNAMENT_COMPOSITION';

    ELSE
        -- Preserva exactamente la lógica histórica para Stroke Play y torneos
        -- previos que no utilicen Stableford.
        v_competition_mode := 'LEGACY_OR_NON_STABLEFORD';
        v_aggregate_required := false;
        v_aggregate_ready := true;
        v_aggregate_status := 'NOT_REQUIRED';
        v_aggregate_leaderboard := NULL;
    END IF;

    v_ready_to_finalize :=
        (
            v_t.estatus='en_curso'::public.estatus_torneo
            AND v_total_rounds>0
            AND v_pending_rounds=0
            AND v_aggregate_ready
        );

    RETURN jsonb_build_object(
        'schemaVersion',
            2,

        'tournamentId',
            p_tournament_id,

        'tournamentName',
            v_t.nombre,

        'estatus',
            v_t.estatus::text,

        'alreadyFinalized',
            (
                v_existing.id IS NOT NULL
                OR
                v_t.estatus='finalizado'::public.estatus_torneo
            ),

        'readyToFinalize',
            v_ready_to_finalize,

        'summary',
            jsonb_build_object(
                'activeRounds',
                    v_total_rounds,
                'closedRounds',
                    v_closed_rounds,
                'pendingRounds',
                    v_pending_rounds
            ),

        'competition',
            jsonb_build_object(
                'mode',
                    v_competition_mode,

                'frozenActiveRounds',
                    v_frozen_active_rounds,

                'stablefordIndividualRounds',
                    v_stableford_individual_rounds,

                'stablefordOtherRounds',
                    v_stableford_other_rounds,

                'nonStablefordRounds',
                    v_non_stableford_rounds
            ),

        'aggregateCompetition',
            jsonb_build_object(
                'required',
                    v_aggregate_required,

                'ready',
                    v_aggregate_ready,

                'leaderboardStatus',
                    v_aggregate_status,

                'leaderboard',
                    v_aggregate_leaderboard
            ),

        'rounds',
            v_rounds,

        'finalization',
            CASE
                WHEN v_existing.id IS NULL
                    THEN NULL

                ELSE jsonb_build_object(
                    'id',
                        v_existing.id,

                    'status',
                        v_existing.status,

                    'finalizedAt',
                        v_existing.finalized_at,

                    'finalizedByAdminUserId',
                        v_existing.finalized_by_admin_user_id,

                    'notes',
                        v_existing.notes,

                    'snapshot',
                        v_existing.finalization_snapshot
                )
            END
    );
END;
$function$;

COMMIT;

-- ============================================================================
-- FIN MIGRACIÓN 186 FASE 1P
-- ============================================================================
