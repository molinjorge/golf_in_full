-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 286
-- Amplía el CHECK de tournament_team_composition_changes.change_type
-- para admitir el retiro competitivo auditado de equipos A-Go-Go.
--
-- IMPORTANTE:
-- - No modifica datos históricos.
-- - No modifica la RPC 284/285.
-- - No debilita auditoría ni permisos.
-- - Conserva todos los valores previamente permitidos.
-- ============================================================

BEGIN;

ALTER TABLE public.tournament_team_composition_changes
    DROP CONSTRAINT IF EXISTS tournament_team_composition_changes_change_type_check;

ALTER TABLE public.tournament_team_composition_changes
    ADD CONSTRAINT tournament_team_composition_changes_change_type_check
    CHECK (
        change_type = ANY (
            ARRAY[
                'team_reassignment'::text,
                'player_substitution'::text,
                'captain_change'::text,
                'player_withdrawal'::text,
                'team_competitive_withdrawal'::text
            ]
        )
    );

COMMIT;
