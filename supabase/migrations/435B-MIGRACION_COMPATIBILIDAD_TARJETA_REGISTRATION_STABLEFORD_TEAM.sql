-- 435B-MIGRACION_COMPATIBILIDAD_TARJETA_REGISTRATION_STABLEFORD_TEAM.sql
-- TEE CENTRAL / GOLF IN FULL
--
-- OBJETIVO
-- Permitir que una tarjeta oficial individual (unit_type='registration')
-- conserve tournament_team_id cuando el jugador participa en STABLEFORD_EQUIPO.
--
-- La tarjeta sigue siendo INDIVIDUAL:
--   tournament_registration_id NOT NULL
--   player_id NOT NULL
-- tournament_team_id sólo conserva la pertenencia al equipo.
--
-- NO cambia tarjetas unit_type='team'.
-- NO crea HCP TEAM.
-- NO modifica el motor de emisión.

BEGIN;

ALTER TABLE public.tournament_score_cards
DROP CONSTRAINT tournament_score_cards_unit_consistency;

ALTER TABLE public.tournament_score_cards
ADD CONSTRAINT tournament_score_cards_unit_consistency
CHECK (
    (
        unit_type = 'registration'
        AND tournament_registration_id IS NOT NULL
        AND player_id IS NOT NULL
        -- tournament_team_id puede ser NULL en individual
        -- o UUID en Stableford por Equipos.
    )
    OR
    (
        unit_type = 'team'
        AND tournament_registration_id IS NULL
        AND tournament_team_id IS NOT NULL
        AND player_id IS NULL
    )
);

COMMENT ON CONSTRAINT tournament_score_cards_unit_consistency
ON public.tournament_score_cards IS
'435B: una tarjeta registration siempre pertenece a una inscripción/jugador individual; tournament_team_id puede ser NULL en modalidades individuales o identificar el equipo en Stableford TEAM. Las tarjetas unit_type=team conservan su contrato anterior.';

COMMIT;
