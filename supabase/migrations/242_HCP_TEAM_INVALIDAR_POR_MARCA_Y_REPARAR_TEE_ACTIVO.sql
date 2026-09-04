-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 242
-- HCP TEAM: invalidar por cambio de marca y reparar tee_id faltante
-- en versiones activas vinculadas a validación vigente.
--
-- Problema:
--   - La materialización de marca_salida_id podía ocurrir después de
--     calcular HCP TEAM.
--   - El trigger 204 no consideraba cambios de marca_salida_id.
--   - Resultado: HCP TEAM podía seguir CURRENT con miembros tee_id NULL.
--
-- Corrección:
--   1) marca_salida_id pasa a invalidar HCP TEAM.
--   2) reparación controlada SOLO para versiones activas actualmente
--      vinculadas a validaciones TEAM/team_stroke vigentes y tee_id NULL,
--      usando el snapshot congelado del mismo freeze/registro/jugador.
--
-- No recalcula HCP TEAM.
-- No crea una versión nueva.
-- No toca versiones superseded.
-- No cambia score cards.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._invalidar_hcp_equipo_por_registro_204()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old_relevant boolean := false;
    v_new_relevant boolean := false;
    v_reason text := 'TEAM_COMPOSITION_CHANGED';
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old_relevant :=
            COALESCE(OLD.activo,false)
            AND OLD.tournament_team_id IS NOT NULL;
    END IF;

    IF TG_OP <> 'DELETE' THEN
        v_new_relevant :=
            COALESCE(NEW.activo,false)
            AND NEW.tournament_team_id IS NOT NULL;
    END IF;

    IF TG_OP='INSERT' THEN
        IF v_new_relevant THEN
            PERFORM public._marcar_handicap_equipo_obsoleto_204(
                NEW.tournament_id,
                NEW.tournament_team_id,
                'TEAM_COMPOSITION_CHANGED',
                NULL
            );
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP='DELETE' THEN
        IF v_old_relevant THEN
            PERFORM public._marcar_handicap_equipo_obsoleto_204(
                OLD.tournament_id,
                OLD.tournament_team_id,
                'TEAM_COMPOSITION_CHANGED',
                NULL
            );
        END IF;
        RETURN OLD;
    END IF;

    IF OLD.player_id IS DISTINCT FROM NEW.player_id
       OR OLD.tournament_team_id IS DISTINCT FROM NEW.tournament_team_id
       OR OLD.activo IS DISTINCT FROM NEW.activo
       OR OLD.marca_salida_id IS DISTINCT FROM NEW.marca_salida_id
    THEN
        IF OLD.marca_salida_id IS DISTINCT FROM NEW.marca_salida_id
           AND OLD.player_id IS NOT DISTINCT FROM NEW.player_id
           AND OLD.tournament_team_id IS NOT DISTINCT FROM NEW.tournament_team_id
           AND OLD.activo IS NOT DISTINCT FROM NEW.activo
        THEN
            v_reason := 'TEAM_MEMBER_TEE_CHANGED';
        END IF;

        IF v_old_relevant THEN
            PERFORM public._marcar_handicap_equipo_obsoleto_204(
                OLD.tournament_id,
                OLD.tournament_team_id,
                v_reason,
                NULL
            );
        END IF;

        IF v_new_relevant THEN
            PERFORM public._marcar_handicap_equipo_obsoleto_204(
                NEW.tournament_id,
                NEW.tournament_team_id,
                v_reason,
                NULL
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_invalidar_hcp_equipo_por_registro_204
ON public.tournament_registrations;

CREATE TRIGGER trg_invalidar_hcp_equipo_por_registro_204
AFTER INSERT OR DELETE OR UPDATE OF
    player_id,
    tournament_team_id,
    activo,
    marca_salida_id
ON public.tournament_registrations
FOR EACH ROW
EXECUTE FUNCTION public._invalidar_hcp_equipo_por_registro_204();

-- ------------------------------------------------------------
-- Reparación controlada:
-- sólo versión activa enlazada a validación vigente TEAM/team_stroke,
-- miembro con tee_id NULL y snapshot congelado inequívoco.
-- Se excluye WHS_SCRAMBLE porque allí el tee forma parte del cálculo
-- competitivo del Course Handicap y no debe corregirse sólo como evidencia.
-- ------------------------------------------------------------

WITH linked_active_versions AS (
    SELECT DISTINCT
        v.freeze_id,
        v.tournament_id,
        v.tournament_round_id,
        u.tournament_team_id,
        public._team_hcp_version_from_validation_208(
            v.id,
            u.tournament_team_id
        ) AS team_hcp_version_id
    FROM public.tournament_round_start_validations v
    JOIN public.tournament_round_start_validation_units u
      ON u.validation_id = v.id
     AND u.unit_type = 'team'
    WHERE v.status = 'validated'
      AND v.participation_type = 'equipo'
      AND v.scoring_engine = 'team_stroke'
),
repair_candidates AS (
    SELECT
        m.id AS member_id,
        hs.tee_id,
        row_number() OVER (
            PARTITION BY m.id
            ORDER BY hs.created_at DESC, hs.id DESC
        ) AS rn
    FROM linked_active_versions lav
    JOIN public.tournament_round_team_handicap_versions hv
      ON hv.id = lav.team_hcp_version_id
     AND hv.status = 'active'
     AND hv.is_stale = false
     AND hv.method <> 'WHS_SCRAMBLE'
    JOIN public.tournament_round_team_handicap_members m
      ON m.team_handicap_version_id = hv.id
     AND m.tee_id IS NULL
    JOIN public.tournament_handicap_snapshots hs
      ON hs.freeze_id = lav.freeze_id
     AND hs.tournament_id = lav.tournament_id
     AND hs.tournament_registration_id = m.tournament_registration_id
     AND hs.player_id = m.player_id
     AND hs.tee_id IS NOT NULL
)
UPDATE public.tournament_round_team_handicap_members m
SET tee_id = rc.tee_id
FROM repair_candidates rc
WHERE rc.member_id = m.id
  AND rc.rn = 1
  AND m.tee_id IS NULL;

COMMIT;
