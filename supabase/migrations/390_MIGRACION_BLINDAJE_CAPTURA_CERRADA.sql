-- MIGRACION 390
-- TEE CENTRAL / GOLF IN FULL
-- BLINDAJE DE BASE DE DATOS DESPUES DEL CIERRE FORMAL DE CAPTURA
--
-- OBJETIVO
-- Impedir en PostgreSQL cualquier mutación de captura física, digital,
-- conciliación u outcome cuando la última acción formal de la ronda sea CLOSED.
--
-- También expone una consulta mínima por score_card para que jugadores/marcadores
-- autorizados puedan conocer captureClosed sin recibir acceso administrativo.
--
-- NO modifica pagos, cierres de categoría, desempates, publicación ni cierre de ronda.
-- Ejecutar manualmente en Supabase PROD.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Helper interno: determina si una ronda tiene captura formalmente cerrada.
--    Sin evento 389 => OPEN, para compatibilidad histórica.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._captura_ronda_cerrada_390(
    p_tournament_round_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT COALESCE((
        SELECT e.action = 'CLOSED'
          FROM public.tournament_round_capture_events e
         WHERE e.tournament_round_id = p_tournament_round_id
         ORDER BY e.occurred_at DESC, e.id DESC
         LIMIT 1
    ), false);
$$;

REVOKE ALL ON FUNCTION public._captura_ronda_cerrada_390(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._captura_ronda_cerrada_390(uuid) FROM anon;
REVOKE ALL ON FUNCTION public._captura_ronda_cerrada_390(uuid) FROM authenticated;

-- ---------------------------------------------------------------------------
-- 2. Guard genérico para tablas de captura.
--    Todas las tablas protegidas poseen tournament_round_id.
--
--    El lock SHARE sobre tournament_rounds serializa las mutaciones con
--    cerrar_captura_ronda_389(), que toma FOR UPDATE sobre la misma ronda.
--    Así una acción enviada justo antes/durante el cierre no puede "colarse"
--    después del cierre formal.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._bloquear_mutacion_captura_cerrada_390()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_round_id uuid;
BEGIN
    v_round_id :=
        CASE
            WHEN TG_OP = 'DELETE' THEN OLD.tournament_round_id
            ELSE NEW.tournament_round_id
        END;

    IF v_round_id IS NULL THEN
        RAISE EXCEPTION
            'No fue posible determinar la ronda para validar el cierre de captura.'
            USING ERRCODE='55000';
    END IF;

    -- Barrera de concurrencia contra cerrar_captura_ronda_389().
    PERFORM 1
      FROM public.tournament_rounds r
     WHERE r.id = v_round_id
     FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ronda no encontrada.' USING ERRCODE='22023';
    END IF;

    IF public._captura_ronda_cerrada_390(v_round_id) THEN
        RAISE EXCEPTION
            'CAPTURA CERRADA: la captura de esta ronda fue cerrada formalmente. Reabra la captura antes de modificar scores, conciliación u outcomes.'
            USING ERRCODE='55000';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._bloquear_mutacion_captura_cerrada_390() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._bloquear_mutacion_captura_cerrada_390() FROM anon;
REVOKE ALL ON FUNCTION public._bloquear_mutacion_captura_cerrada_390() FROM authenticated;

-- ---------------------------------------------------------------------------
-- 3. Triggers duros sobre TODAS las tablas de estado mutable de captura.
--    Los eventos append-only asociados no requieren guard propio: si la mutación
--    principal falla, toda la transacción revierte. Los eventos por sí solos no
--    cambian el estado competitivo.
-- ---------------------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_captura_cerrada_390
ON public.tournament_scorecard_capture_sessions;
CREATE TRIGGER trg_captura_cerrada_390
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_scorecard_capture_sessions
FOR EACH ROW EXECUTE FUNCTION public._bloquear_mutacion_captura_cerrada_390();

DROP TRIGGER IF EXISTS trg_captura_cerrada_390
ON public.tournament_scorecard_hole_scores;
CREATE TRIGGER trg_captura_cerrada_390
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_scorecard_hole_scores
FOR EACH ROW EXECUTE FUNCTION public._bloquear_mutacion_captura_cerrada_390();

DROP TRIGGER IF EXISTS trg_captura_cerrada_390
ON public.tournament_best_ball_hole_scores;
CREATE TRIGGER trg_captura_cerrada_390
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_best_ball_hole_scores
FOR EACH ROW EXECUTE FUNCTION public._bloquear_mutacion_captura_cerrada_390();

DROP TRIGGER IF EXISTS trg_captura_cerrada_390
ON public.tournament_scorecard_physical_receptions;
CREATE TRIGGER trg_captura_cerrada_390
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_scorecard_physical_receptions
FOR EACH ROW EXECUTE FUNCTION public._bloquear_mutacion_captura_cerrada_390();

DROP TRIGGER IF EXISTS trg_captura_cerrada_390
ON public.tournament_scorecard_physical_hole_scores;
CREATE TRIGGER trg_captura_cerrada_390
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_scorecard_physical_hole_scores
FOR EACH ROW EXECUTE FUNCTION public._bloquear_mutacion_captura_cerrada_390();

DROP TRIGGER IF EXISTS trg_captura_cerrada_390
ON public.tournament_best_ball_physical_hole_scores;
CREATE TRIGGER trg_captura_cerrada_390
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_best_ball_physical_hole_scores
FOR EACH ROW EXECUTE FUNCTION public._bloquear_mutacion_captura_cerrada_390();

DROP TRIGGER IF EXISTS trg_captura_cerrada_390
ON public.tournament_scorecard_reconciliations;
CREATE TRIGGER trg_captura_cerrada_390
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_scorecard_reconciliations
FOR EACH ROW EXECUTE FUNCTION public._bloquear_mutacion_captura_cerrada_390();

DROP TRIGGER IF EXISTS trg_captura_cerrada_390
ON public.tournament_scorecard_hole_resolutions;
CREATE TRIGGER trg_captura_cerrada_390
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_scorecard_hole_resolutions
FOR EACH ROW EXECUTE FUNCTION public._bloquear_mutacion_captura_cerrada_390();

DROP TRIGGER IF EXISTS trg_captura_cerrada_390
ON public.tournament_best_ball_hole_resolutions;
CREATE TRIGGER trg_captura_cerrada_390
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_best_ball_hole_resolutions
FOR EACH ROW EXECUTE FUNCTION public._bloquear_mutacion_captura_cerrada_390();

DROP TRIGGER IF EXISTS trg_captura_cerrada_390
ON public.tournament_scorecard_round_outcomes;
CREATE TRIGGER trg_captura_cerrada_390
BEFORE INSERT OR UPDATE OR DELETE
ON public.tournament_scorecard_round_outcomes
FOR EACH ROW EXECUTE FUNCTION public._bloquear_mutacion_captura_cerrada_390();

-- ---------------------------------------------------------------------------
-- 4. Consulta mínima para jugador/marcador autorizado por score_card.
--    No expone resumen administrativo; sólo estado OPEN/CLOSED y fecha.
--    Reutiliza el control existente puede_ver_score_card_captura().
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_cierre_captura_score_card_390(
    p_score_card_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_auth uuid := auth.uid();
    v_round_id uuid;
    v_last_action text;
    v_last_at timestamptz;
BEGIN
    IF v_auth IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF NOT public.puede_ver_score_card_captura(p_score_card_id) THEN
        RAISE EXCEPTION 'No autorizado para consultar esta tarjeta.'
            USING ERRCODE='42501';
    END IF;

    SELECT sc.tournament_round_id
      INTO v_round_id
      FROM public.tournament_score_cards sc
     WHERE sc.id = p_score_card_id;

    IF v_round_id IS NULL THEN
        RAISE EXCEPTION 'Tarjeta no encontrada.' USING ERRCODE='22023';
    END IF;

    SELECT e.action, e.occurred_at
      INTO v_last_action, v_last_at
      FROM public.tournament_round_capture_events e
     WHERE e.tournament_round_id = v_round_id
     ORDER BY e.occurred_at DESC, e.id DESC
     LIMIT 1;

    RETURN jsonb_build_object(
        'schemaVersion', 390,
        'scoreCardId', p_score_card_id,
        'tournamentRoundId', v_round_id,
        'captureStatus',
            CASE WHEN v_last_action = 'CLOSED' THEN 'CLOSED' ELSE 'OPEN' END,
        'captureClosed', (v_last_action = 'CLOSED'),
        'closedAt',
            CASE WHEN v_last_action = 'CLOSED' THEN v_last_at ELSE NULL END
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_cierre_captura_score_card_390(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_cierre_captura_score_card_390(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_cierre_captura_score_card_390(uuid)
TO authenticated;

COMMIT;
