-- TEE CENTRAL / GOLF IN FULL
-- Migración 222
-- A-Go-Go: invited_by_player_id opcional en roster provisional/operativo.
--
-- Motivo:
-- tournament_team_roster_slots.invited_by_player_id nació como obligatorio
-- para invitaciones originadas por un jugador/capitán.
--
-- En sustituciones administrativas A-Go-Go puede no existir capitán del equipo.
-- En ese caso no hay un jugador "invitador" legítimo, y la autoría administrativa
-- ya se conserva en tournament_team_substitution_requests.requested_by_admin_id
-- y tournament_team_composition_changes.changed_by_admin_id.
--
-- Esta migración NO hace obligatorio el capitán y NO modifica funciones/RPCs.
-- Sólo permite NULL en invited_by_player_id.
--
-- IMPORTANTE: ejecutar manualmente en Supabase.

BEGIN;

ALTER TABLE public.tournament_team_roster_slots
    ALTER COLUMN invited_by_player_id DROP NOT NULL;

COMMIT;
