-- 383_compatibilidad_snapshot_hcp_override_competitivo.sql
-- TEE CENTRAL / GOLF IN FULL
-- Corrige exclusivamente el CHECK de handicap_source del snapshot.
-- EJECUCIÓN MANUAL EN PROD.

BEGIN;

ALTER TABLE public.tournament_handicap_snapshots
  DROP CONSTRAINT IF EXISTS tournament_handicap_snapshots_handicap_source_check;

ALTER TABLE public.tournament_handicap_snapshots
  ADD CONSTRAINT tournament_handicap_snapshots_handicap_source_check
  CHECK (handicap_source = ANY (ARRAY[
    'verified'::text,
    'declared'::text,
    'tournament_override'::text
  ]));

COMMIT;
