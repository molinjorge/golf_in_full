-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 233 — TORNEO CANCELADO = SÓLO LECTURA OPERATIVA
--
-- Objetivo:
-- Hacer que estatus='cancelado' sea un estado terminal operativo.
-- Un torneo cancelado conserva toda su información e historial, pero deja de
-- admitir cambios de configuración, inscripción, equipos, salidas, tarjetas
-- y captura competitiva.
--
-- Principios de seguridad:
-- 1) NO cambia activo ni estado_servicio.
-- 2) NO borra ni modifica snapshots, freezes, auditoría ni históricos.
-- 3) NO cambia reglas para planificado, inscripciones_abiertas,
--    inscripcion_cerrada, en_curso o finalizado.
-- 4) La cancelación misma sigue funcionando: el bloqueo comienza DESPUÉS de
--    que el torneo ya quedó cancelado.
-- 5) Se refuerzan guards comunes existentes y se añade defensa a nivel de
--    datos únicamente en tablas operativas/configurables seleccionadas.
-- 6) NO se bloquean tablas comerciales/pagos ni callbacks externos, para no
--    interferir con conciliaciones financieras posteriores a una cancelación.
--
-- IMPORTANTE:
-- Esta migración es backend. La UI debe después presentar el torneo cancelado
-- como sólo lectura y deshabilitar acciones visibles.

BEGIN;

-- ============================================================================
-- 1. Helper semántico común
-- ============================================================================

CREATE OR REPLACE FUNCTION public.torneo_esta_cancelado_233(
    p_tournament_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT EXISTS (
        SELECT 1
        FROM public.tournaments t
        WHERE t.id = p_tournament_id
          AND t.estatus = 'cancelado'::public.estatus_torneo
    );
$function$;

COMMENT ON FUNCTION public.torneo_esta_cancelado_233(uuid) IS
'Devuelve true únicamente cuando el torneo existe y estatus=cancelado. Helper interno de Migración 233.';

REVOKE ALL ON FUNCTION public.torneo_esta_cancelado_233(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.torneo_esta_cancelado_233(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.torneo_esta_cancelado_233(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.torneo_esta_cancelado_233(uuid) TO service_role;

-- ============================================================================
-- 2. Guard administrativo común
--    Mantiene exactamente los permisos previos para cualquier torneo que NO
--    esté cancelado. En cancelado devuelve false para todos.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.puede_administrar_congelamiento_torneo(
    p_tournament_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
    SELECT auth.uid() IS NOT NULL
       AND EXISTS (
            SELECT 1
            FROM public.tournaments t
            WHERE t.id = p_tournament_id
              AND t.estatus IS DISTINCT FROM
                  'cancelado'::public.estatus_torneo
              AND (
                    public.is_superadmin(auth.uid())
                    OR public.is_tournament_organizer(
                        auth.uid(),
                        p_tournament_id
                    )
                    OR public.is_club_admin(
                        auth.uid(),
                        t.club_id
                    )
              )
       );
$function$;

-- ============================================================================
-- 3. Guard común de roster/equipos
--    Conserva la lógica previa (Superadmin / organizador / club admin /
--    capitán), pero devuelve false si el torneo está cancelado.
-- ============================================================================

CREATE OR REPLACE FUNCTION public._puede_administrar_roster_equipo_199(
    p_team_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_captain_player_id uuid;
    v_current_player_id uuid;
    v_club_id uuid;
    v_estatus public.estatus_torneo;
BEGIN
    SELECT
        tt.tournament_id,
        tt.captain_player_id,
        t.club_id,
        t.estatus
      INTO
        v_tournament_id,
        v_captain_player_id,
        v_club_id,
        v_estatus
      FROM public.tournament_teams tt
      JOIN public.tournaments t
        ON t.id = tt.tournament_id
     WHERE tt.id = p_team_id
       AND tt.activo = true;

    IF v_tournament_id IS NULL THEN
        RETURN false;
    END IF;

    IF v_estatus =
       'cancelado'::public.estatus_torneo
    THEN
        RETURN false;
    END IF;

    IF public.is_superadmin(auth.uid())
       OR public.is_tournament_organizer(
            auth.uid(),
            v_tournament_id
       )
       OR public.is_club_admin(
            auth.uid(),
            v_club_id
       )
    THEN
        RETURN true;
    END IF;

    v_current_player_id :=
        public._current_player_id_199();

    RETURN v_current_player_id IS NOT NULL
       AND v_current_player_id =
           v_captain_player_id;
END;
$function$;

-- ============================================================================
-- 4. Inmutabilidad del registro raíz una vez cancelado
--
-- La transición HACIA cancelado se permite porque OLD.estatus todavía no es
-- cancelado. Cualquier UPDATE/DELETE posterior queda bloqueado.
-- ============================================================================

CREATE OR REPLACE FUNCTION public._bloquear_torneo_ya_cancelado_233()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF OLD.estatus =
       'cancelado'::public.estatus_torneo
    THEN
        RAISE EXCEPTION
            'El torneo está CANCELADO y es de sólo lectura.'
            USING ERRCODE = '55000',
                  HINT =
                    'La cancelación conserva el historial pero bloquea cambios posteriores.';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS
    trg_bloquear_torneo_ya_cancelado_233
ON public.tournaments;

CREATE TRIGGER
    trg_bloquear_torneo_ya_cancelado_233
BEFORE UPDATE OR DELETE
ON public.tournaments
FOR EACH ROW
EXECUTE FUNCTION
    public._bloquear_torneo_ya_cancelado_233();

-- ============================================================================
-- 5. Guard genérico para tablas operativas que contienen tournament_id
--
-- NO se aplica a snapshots, freezes, auditoría, históricos ni tablas
-- financieras/comerciales.
-- ============================================================================

CREATE OR REPLACE FUNCTION public._bloquear_mutacion_torneo_cancelado_233()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_tournament_id := OLD.tournament_id;
    ELSE
        v_tournament_id := NEW.tournament_id;
    END IF;

    IF v_tournament_id IS NOT NULL
       AND public.torneo_esta_cancelado_233(
            v_tournament_id
       )
    THEN
        RAISE EXCEPTION
            'El torneo está CANCELADO y no admite cambios operativos.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'tabla=%s; tournament_id=%s',
                      TG_TABLE_NAME,
                      v_tournament_id
                  ),
                  HINT =
                    'Consulta el torneo en modo sólo lectura.';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$function$;

-- Configuración / inscripción / equipos
DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_categories;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_categories
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_category_classifications;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_category_classifications
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_registrations;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_registrations
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_teams;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_teams
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_team_roster_slots;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_team_roster_slots
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_team_substitution_requests;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_team_substitution_requests
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_team_handicap_configs;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_team_handicap_configs
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_stableford_special_rules;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_stableford_special_rules
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_tiebreak_rules;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_tiebreak_rules
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_rounds;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_rounds
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

-- Salidas / tarjetas / captura competitiva
DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_round_start_validations;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_round_start_validations
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_score_card_emissions;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_score_card_emissions
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_score_cards;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_score_cards
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_scorecard_capture_sessions;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_scorecard_capture_sessions
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_scorecard_physical_receptions;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_scorecard_physical_receptions
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_scorecard_reconciliations;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_scorecard_reconciliations
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_scorecard_round_outcomes;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_scorecard_round_outcomes
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_torneo_cancelado_233();

-- ============================================================================
-- 6. Tablas competitivas hijas sin tournament_id directo
-- ============================================================================

CREATE OR REPLACE FUNCTION public._bloquear_mutacion_scorecard_cancelado_233()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_score_card_id uuid;
    v_tournament_id uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_score_card_id := OLD.score_card_id;
    ELSE
        v_score_card_id := NEW.score_card_id;
    END IF;

    SELECT sc.tournament_id
      INTO v_tournament_id
      FROM public.tournament_score_cards sc
     WHERE sc.id = v_score_card_id;

    IF v_tournament_id IS NOT NULL
       AND public.torneo_esta_cancelado_233(
            v_tournament_id
       )
    THEN
        RAISE EXCEPTION
            'El torneo está CANCELADO y la tarjeta es de sólo lectura.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'tabla=%s; score_card_id=%s; tournament_id=%s',
                      TG_TABLE_NAME,
                      v_score_card_id,
                      v_tournament_id
                  );
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_scorecard_hole_scores;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_scorecard_hole_scores
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_scorecard_cancelado_233();

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_scorecard_physical_hole_scores;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_scorecard_physical_hole_scores
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_scorecard_cancelado_233();

-- Rangos HCP TEAM: resuelve el torneo a través de config_id.
CREATE OR REPLACE FUNCTION public._bloquear_mutacion_hcp_team_range_cancelado_233()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_config_id uuid;
    v_tournament_id uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_config_id := OLD.config_id;
    ELSE
        v_config_id := NEW.config_id;
    END IF;

    SELECT c.tournament_id
      INTO v_tournament_id
      FROM public.tournament_team_handicap_configs c
     WHERE c.id = v_config_id;

    IF v_tournament_id IS NOT NULL
       AND public.torneo_esta_cancelado_233(
            v_tournament_id
       )
    THEN
        RAISE EXCEPTION
            'El torneo está CANCELADO y no admite cambios en rangos HCP TEAM.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'config_id=%s; tournament_id=%s',
                      v_config_id,
                      v_tournament_id
                  );
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_cancelado_233
ON public.tournament_team_handicap_ranges;
CREATE TRIGGER trg_cancelado_233
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_team_handicap_ranges
FOR EACH ROW
EXECUTE FUNCTION public._bloquear_mutacion_hcp_team_range_cancelado_233();

-- Las funciones de trigger no requieren exposición directa.
REVOKE ALL ON FUNCTION public._bloquear_torneo_ya_cancelado_233() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._bloquear_mutacion_torneo_cancelado_233() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._bloquear_mutacion_scorecard_cancelado_233() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._bloquear_mutacion_hcp_team_range_cancelado_233() FROM PUBLIC;

COMMIT;
