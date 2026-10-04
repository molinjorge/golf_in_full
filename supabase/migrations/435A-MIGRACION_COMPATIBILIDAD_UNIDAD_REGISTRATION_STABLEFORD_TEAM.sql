-- 435A-MIGRACION_COMPATIBILIDAD_UNIDAD_REGISTRATION_STABLEFORD_TEAM.sql
-- TEE CENTRAL / GOLF IN FULL
--
-- OBJETIVO
-- Permitir que una unidad validada de tipo registration conserve tournament_team_id
-- cuando la tarjeta sigue siendo individual pero el jugador pertenece a un equipo,
-- como requiere STABLEFORD_EQUIPO.
--
-- NO cambia el motor, HCP, grupos ni emisión.
-- NO convierte la tarjeta en TEAM.
-- Mantiene registration_id, player_id y snapshots individuales obligatorios.
-- Mantiene unit_type='team' exactamente con su contrato anterior.

BEGIN;

ALTER TABLE public.tournament_round_start_validation_units
DROP CONSTRAINT round_start_validation_units_type_consistency;

ALTER TABLE public.tournament_round_start_validation_units
ADD CONSTRAINT round_start_validation_units_type_consistency
CHECK (
    (
        unit_type = 'registration'
        AND tournament_registration_id IS NOT NULL
        AND player_id IS NOT NULL
        AND handicap_snapshot_id IS NOT NULL
        AND round_handicap_snapshot_id IS NOT NULL
        -- tournament_team_id puede ser NULL (individual) o UUID (jugador de TEAM).
    )
    OR
    (
        unit_type = 'team'
        AND tournament_registration_id IS NULL
        AND tournament_team_id IS NOT NULL
        AND player_id IS NULL
        AND handicap_snapshot_id IS NULL
        AND round_handicap_snapshot_id IS NULL
    )
);

COMMENT ON CONSTRAINT round_start_validation_units_type_consistency
ON public.tournament_round_start_validation_units IS
'435A: registration siempre representa tarjeta/jugador individual y exige registration, player y snapshots HCP; tournament_team_id puede ser NULL en modalidades individuales o contener el equipo en Stableford TEAM. team conserva el contrato de unidad competitiva de equipo.';

COMMIT;
