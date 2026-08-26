-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 186 Fase 1C
-- Contrato universal de resultado de hoyo: SCORE / PICKUP / PENDING
--
-- ALCANCE
--   - Modelo de datos únicamente.
--   - Digital, físico, resolución y eventos quedan preparados para distinguir
--     SCORE vs PICKUP sin usar scores ficticios.
--   - Backfill total y retrocompatible: todo dato histórico existente se marca
--     como SCORE; filas digitales pendientes se marcan como PENDING.
--
-- NO HACE TODAVÍA
--   - No habilita captura de PICKUP desde RPC/UI.
--   - No modifica cálculo de resultados.
--   - No modifica Stableford points.
--   - No modifica leaderboard.
--
-- SIGUIENTES FASES
--   1D: RPC/captura digital SCORE/PICKUP.
--   1E: captura física + conciliación + resolución universal.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. DIGITAL: resultado base y reclamación del jugador
-- ----------------------------------------------------------------------------

ALTER TABLE public.tournament_scorecard_hole_scores
    ADD COLUMN IF NOT EXISTS result_type text;

ALTER TABLE public.tournament_scorecard_hole_scores
    ADD COLUMN IF NOT EXISTS player_claimed_result_type text;

-- Backfill determinista sobre datos históricos.
UPDATE public.tournament_scorecard_hole_scores
SET result_type =
    CASE
        WHEN status = 'pending' AND gross_score IS NULL THEN 'PENDING'
        ELSE 'SCORE'
    END
WHERE result_type IS NULL;

UPDATE public.tournament_scorecard_hole_scores
SET player_claimed_result_type = 'SCORE'
WHERE player_claimed_result_type IS NULL
  AND player_claimed_gross_score IS NOT NULL;

ALTER TABLE public.tournament_scorecard_hole_scores
    ALTER COLUMN result_type SET DEFAULT 'PENDING';

ALTER TABLE public.tournament_scorecard_hole_scores
    ALTER COLUMN result_type SET NOT NULL;

ALTER TABLE public.tournament_scorecard_hole_scores
    DROP CONSTRAINT IF EXISTS tournament_scorecard_hole_scores_result_type_ck;

ALTER TABLE public.tournament_scorecard_hole_scores
    ADD CONSTRAINT tournament_scorecard_hole_scores_result_type_ck
    CHECK (result_type IN ('PENDING','SCORE','PICKUP'));

ALTER TABLE public.tournament_scorecard_hole_scores
    DROP CONSTRAINT IF EXISTS tournament_scorecard_hole_scores_claimed_result_type_ck;

ALTER TABLE public.tournament_scorecard_hole_scores
    ADD CONSTRAINT tournament_scorecard_hole_scores_claimed_result_type_ck
    CHECK (
        player_claimed_result_type IS NULL
        OR player_claimed_result_type IN ('SCORE','PICKUP')
    );

-- Reemplazamos la equivalencia histórica "resuelto = gross no nulo"
-- por el contrato explícito de result_type.
ALTER TABLE public.tournament_scorecard_hole_scores
    DROP CONSTRAINT IF EXISTS tournament_scorecard_hole_scores_state_ck;

ALTER TABLE public.tournament_scorecard_hole_scores
    ADD CONSTRAINT tournament_scorecard_hole_scores_state_ck
    CHECK (
        (
            status = 'pending'
            AND result_type = 'PENDING'
            AND gross_score IS NULL
            AND marker_assignment_id IS NULL
            AND entered_by_player_id IS NULL
            AND entered_at IS NULL
            AND confirmed_by_player_id IS NULL
            AND confirmed_at IS NULL
            AND player_claimed_result_type IS NULL
            AND player_claimed_gross_score IS NULL
            AND dispute_note IS NULL
            AND disputed_at IS NULL
        )
        OR
        (
            status = 'entered'
            AND result_type IN ('SCORE','PICKUP')
            AND (
                (result_type = 'SCORE' AND gross_score IS NOT NULL)
                OR
                (result_type = 'PICKUP' AND gross_score IS NULL)
            )
            AND marker_assignment_id IS NOT NULL
            AND entered_by_player_id IS NOT NULL
            AND entered_at IS NOT NULL
            AND confirmed_by_player_id IS NULL
            AND confirmed_at IS NULL
            AND player_claimed_result_type IS NULL
            AND player_claimed_gross_score IS NULL
            AND dispute_note IS NULL
            AND disputed_at IS NULL
        )
        OR
        (
            status = 'confirmed'
            AND result_type IN ('SCORE','PICKUP')
            AND (
                (result_type = 'SCORE' AND gross_score IS NOT NULL)
                OR
                (result_type = 'PICKUP' AND gross_score IS NULL)
            )
            AND marker_assignment_id IS NOT NULL
            AND entered_by_player_id IS NOT NULL
            AND entered_at IS NOT NULL
            AND confirmed_by_player_id IS NOT NULL
            AND confirmed_at IS NOT NULL
            AND player_claimed_result_type IS NULL
            AND player_claimed_gross_score IS NULL
            AND dispute_note IS NULL
            AND disputed_at IS NULL
        )
        OR
        (
            status = 'disputed'
            AND result_type IN ('SCORE','PICKUP')
            AND (
                (result_type = 'SCORE' AND gross_score IS NOT NULL)
                OR
                (result_type = 'PICKUP' AND gross_score IS NULL)
            )
            AND marker_assignment_id IS NOT NULL
            AND entered_by_player_id IS NOT NULL
            AND entered_at IS NOT NULL
            AND confirmed_by_player_id IS NULL
            AND confirmed_at IS NULL
            AND player_claimed_result_type IN ('SCORE','PICKUP')
            AND (
                (
                    player_claimed_result_type = 'SCORE'
                    AND player_claimed_gross_score IS NOT NULL
                )
                OR
                (
                    player_claimed_result_type = 'PICKUP'
                    AND player_claimed_gross_score IS NULL
                )
            )
            AND (
                player_claimed_result_type IS DISTINCT FROM result_type
                OR player_claimed_gross_score IS DISTINCT FROM gross_score
            )
            AND disputed_at IS NOT NULL
        )
    );

COMMENT ON COLUMN public.tournament_scorecard_hole_scores.result_type IS
'Resultado capturado del hoyo: PENDING, SCORE o PICKUP. PICKUP es un hoyo resuelto sin gross.';

COMMENT ON COLUMN public.tournament_scorecard_hole_scores.player_claimed_result_type IS
'Resultado reclamado por el jugador durante una disputa: SCORE o PICKUP.';

-- ----------------------------------------------------------------------------
-- 2. FÍSICO: SCORE o PICKUP
-- ----------------------------------------------------------------------------

ALTER TABLE public.tournament_scorecard_physical_hole_scores
    ADD COLUMN IF NOT EXISTS physical_result_type text;

UPDATE public.tournament_scorecard_physical_hole_scores
SET physical_result_type = 'SCORE'
WHERE physical_result_type IS NULL;

ALTER TABLE public.tournament_scorecard_physical_hole_scores
    ALTER COLUMN physical_result_type SET DEFAULT 'SCORE';

ALTER TABLE public.tournament_scorecard_physical_hole_scores
    ALTER COLUMN physical_result_type SET NOT NULL;

ALTER TABLE public.tournament_scorecard_physical_hole_scores
    ALTER COLUMN physical_gross_score DROP NOT NULL;

ALTER TABLE public.tournament_scorecard_physical_hole_scores
    DROP CONSTRAINT IF EXISTS tournament_scorecard_physical_hole_s_physical_gross_score_check;

ALTER TABLE public.tournament_scorecard_physical_hole_scores
    DROP CONSTRAINT IF EXISTS tournament_scorecard_physical_hole_scores_result_ck;

ALTER TABLE public.tournament_scorecard_physical_hole_scores
    ADD CONSTRAINT tournament_scorecard_physical_hole_scores_result_ck
    CHECK (
        (
            physical_result_type = 'SCORE'
            AND physical_gross_score IS NOT NULL
            AND physical_gross_score > 0
        )
        OR
        (
            physical_result_type = 'PICKUP'
            AND physical_gross_score IS NULL
        )
    );

COMMENT ON COLUMN public.tournament_scorecard_physical_hole_scores.physical_result_type IS
'Resultado transcrito desde tarjeta física: SCORE o PICKUP.';

-- ----------------------------------------------------------------------------
-- 3. RESOLUCIÓN: snapshots de evidencia y resultado oficial universal
-- ----------------------------------------------------------------------------

ALTER TABLE public.tournament_scorecard_hole_resolutions
    ADD COLUMN IF NOT EXISTS digital_result_type_snapshot text;

ALTER TABLE public.tournament_scorecard_hole_resolutions
    ADD COLUMN IF NOT EXISTS player_claim_result_type_snapshot text;

ALTER TABLE public.tournament_scorecard_hole_resolutions
    ADD COLUMN IF NOT EXISTS physical_result_type_snapshot text;

ALTER TABLE public.tournament_scorecard_hole_resolutions
    ADD COLUMN IF NOT EXISTS resolved_result_type text;

UPDATE public.tournament_scorecard_hole_resolutions
SET digital_result_type_snapshot =
        CASE WHEN digital_gross_snapshot IS NULL THEN NULL ELSE 'SCORE' END,
    player_claim_result_type_snapshot =
        CASE WHEN player_claim_gross_snapshot IS NULL THEN NULL ELSE 'SCORE' END,
    physical_result_type_snapshot =
        CASE WHEN physical_gross_snapshot IS NULL THEN NULL ELSE 'SCORE' END,
    resolved_result_type = 'SCORE'
WHERE resolved_result_type IS NULL
   OR digital_result_type_snapshot IS NULL
   OR player_claim_result_type_snapshot IS NULL
   OR physical_result_type_snapshot IS NULL;

ALTER TABLE public.tournament_scorecard_hole_resolutions
    ALTER COLUMN resolved_result_type SET DEFAULT 'SCORE';

ALTER TABLE public.tournament_scorecard_hole_resolutions
    ALTER COLUMN resolved_result_type SET NOT NULL;

ALTER TABLE public.tournament_scorecard_hole_resolutions
    ALTER COLUMN resolved_gross_score DROP NOT NULL;

ALTER TABLE public.tournament_scorecard_hole_resolutions
    DROP CONSTRAINT IF EXISTS tournament_scorecard_hole_resolution_resolved_gross_score_check;

ALTER TABLE public.tournament_scorecard_hole_resolutions
    DROP CONSTRAINT IF EXISTS tournament_scorecard_hole_resolutions_result_types_ck;

ALTER TABLE public.tournament_scorecard_hole_resolutions
    ADD CONSTRAINT tournament_scorecard_hole_resolutions_result_types_ck
    CHECK (
        (digital_result_type_snapshot IS NULL
            OR digital_result_type_snapshot IN ('SCORE','PICKUP'))
        AND
        (player_claim_result_type_snapshot IS NULL
            OR player_claim_result_type_snapshot IN ('SCORE','PICKUP'))
        AND
        (physical_result_type_snapshot IS NULL
            OR physical_result_type_snapshot IN ('SCORE','PICKUP'))
        AND
        resolved_result_type IN ('SCORE','PICKUP')
        AND
        (
            (resolved_result_type = 'SCORE'
                AND resolved_gross_score IS NOT NULL
                AND resolved_gross_score > 0)
            OR
            (resolved_result_type = 'PICKUP'
                AND resolved_gross_score IS NULL)
        )
    );

COMMENT ON COLUMN public.tournament_scorecard_hole_resolutions.resolved_result_type IS
'Resultado oficial resuelto del hoyo: SCORE o PICKUP.';

-- ----------------------------------------------------------------------------
-- 4. EVENTOS DIGITALES: auditar tipo de resultado además del Gross
-- ----------------------------------------------------------------------------

ALTER TABLE public.tournament_scorecard_events
    ADD COLUMN IF NOT EXISTS old_result_type text;

ALTER TABLE public.tournament_scorecard_events
    ADD COLUMN IF NOT EXISTS new_result_type text;

ALTER TABLE public.tournament_scorecard_events
    ADD COLUMN IF NOT EXISTS claimed_result_type text;

ALTER TABLE public.tournament_scorecard_events
    DROP CONSTRAINT IF EXISTS tournament_scorecard_events_result_types_ck;

ALTER TABLE public.tournament_scorecard_events
    ADD CONSTRAINT tournament_scorecard_events_result_types_ck
    CHECK (
        (old_result_type IS NULL OR old_result_type IN ('PENDING','SCORE','PICKUP'))
        AND
        (new_result_type IS NULL OR new_result_type IN ('PENDING','SCORE','PICKUP'))
        AND
        (claimed_result_type IS NULL OR claimed_result_type IN ('SCORE','PICKUP'))
    );

-- Las bitácoras son append-only e inmutables. No se hace UPDATE histórico.
-- Los campos nuevos permanecen NULL en eventos anteriores a esta migración.
-- Las fases 1D/1E poblarán estos campos únicamente en eventos nuevos.

-- ----------------------------------------------------------------------------
-- 5. EVENTOS FÍSICOS
-- ----------------------------------------------------------------------------

ALTER TABLE public.tournament_scorecard_physical_events
    ADD COLUMN IF NOT EXISTS old_physical_result_type text;

ALTER TABLE public.tournament_scorecard_physical_events
    ADD COLUMN IF NOT EXISTS new_physical_result_type text;

ALTER TABLE public.tournament_scorecard_physical_events
    DROP CONSTRAINT IF EXISTS tournament_scorecard_physical_events_result_types_ck;

ALTER TABLE public.tournament_scorecard_physical_events
    ADD CONSTRAINT tournament_scorecard_physical_events_result_types_ck
    CHECK (
        (old_physical_result_type IS NULL
            OR old_physical_result_type IN ('SCORE','PICKUP'))
        AND
        (new_physical_result_type IS NULL
            OR new_physical_result_type IN ('SCORE','PICKUP'))
    );

-- No se hace backfill sobre esta bitácora porque es inmutable.
-- El constraint histórico de valores Gross se conserva en 1C.
-- Se generalizará en 1E, junto con las RPC que escriben eventos físicos,
-- para no habilitar una estructura que todavía no tiene escritor compatible.

-- ----------------------------------------------------------------------------
-- 6. EVENTOS DE CONCILIACIÓN
-- ----------------------------------------------------------------------------

ALTER TABLE public.tournament_scorecard_reconciliation_events
    ADD COLUMN IF NOT EXISTS old_resolved_result_type text;

ALTER TABLE public.tournament_scorecard_reconciliation_events
    ADD COLUMN IF NOT EXISTS new_resolved_result_type text;

ALTER TABLE public.tournament_scorecard_reconciliation_events
    DROP CONSTRAINT IF EXISTS tournament_scorecard_reconciliation_events_result_types_ck;

ALTER TABLE public.tournament_scorecard_reconciliation_events
    ADD CONSTRAINT tournament_scorecard_reconciliation_events_result_types_ck
    CHECK (
        (old_resolved_result_type IS NULL
            OR old_resolved_result_type IN ('SCORE','PICKUP'))
        AND
        (new_resolved_result_type IS NULL
            OR new_resolved_result_type IN ('SCORE','PICKUP'))
    );

-- No se hace backfill sobre esta bitácora porque es inmutable.
-- 1E poblará old/new_resolved_result_type en eventos nuevos de resolución.

COMMIT;

-- ============================================================================
-- FIN MIGRACIÓN 186 FASE 1C
-- ============================================================================
