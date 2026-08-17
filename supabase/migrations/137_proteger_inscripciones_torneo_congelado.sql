BEGIN;

-- ============================================================================
-- MIGRACIÓN 137
-- Protege la composición competitiva de un torneo después de congelar sus
-- condiciones y hándicaps (Migración 136).
--
-- BLOQUEA:
--   - nuevas inscripciones activas;
--   - cambio de jugador;
--   - cambio de categoría;
--   - cambio de marca de salida;
--   - cambio de equipo;
--   - reactivación de una inscripción que no pertenece al snapshot.
--
-- PERMITE:
--   - retiro/baja lógica (activo true -> false);
--   - reactivación de un participante que sí quedó congelado;
--   - actualización de datos no competitivos de la inscripción;
--   - actualización del perfil/Handicap Index global del jugador, que no
--     modifica los snapshots ya congelados;
--   - configuración y aplicación posterior de cortes.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.proteger_inscripcion_torneo_congelado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_torneo_congelado boolean;
    v_pertenece_snapshot boolean;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT EXISTS (
            SELECT 1
            FROM public.tournament_condition_freezes f
            WHERE f.tournament_id = NEW.tournament_id
        )
        INTO v_torneo_congelado;

        IF v_torneo_congelado AND NEW.activo = true THEN
            RAISE EXCEPTION
                'No se pueden agregar inscripciones activas: las condiciones y los participantes del torneo ya fueron congelados.'
                USING ERRCODE = '55000',
                      HINT = 'Los casos excepcionales posteriores al congelamiento requieren un procedimiento explícito y auditado.';
        END IF;

        RETURN NEW;
    END IF;

    -- Impide mover una inscripción hacia o desde un torneo congelado.
    IF NEW.tournament_id IS DISTINCT FROM OLD.tournament_id
       AND (
            EXISTS (
                SELECT 1
                FROM public.tournament_condition_freezes f
                WHERE f.tournament_id = OLD.tournament_id
            )
            OR EXISTS (
                SELECT 1
                FROM public.tournament_condition_freezes f
                WHERE f.tournament_id = NEW.tournament_id
            )
       ) THEN
        RAISE EXCEPTION
            'No se puede cambiar de torneo una inscripción vinculada con un torneo congelado.'
            USING ERRCODE = '55000';
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = OLD.tournament_id
    )
    INTO v_torneo_congelado;

    IF NOT v_torneo_congelado THEN
        RETURN NEW;
    END IF;

    IF NEW.player_id IS DISTINCT FROM OLD.player_id THEN
        RAISE EXCEPTION
            'No se puede cambiar el jugador: la inscripción pertenece a un torneo congelado.'
            USING ERRCODE = '55000';
    END IF;

    IF NEW.tournament_category_id IS DISTINCT FROM OLD.tournament_category_id THEN
        RAISE EXCEPTION
            'No se puede cambiar la categoría: las condiciones y hándicaps del torneo ya fueron congelados.'
            USING ERRCODE = '55000',
                  HINT = 'La categoría competitiva válida es la guardada en el snapshot del torneo.';
    END IF;

    IF NEW.marca_salida_id IS DISTINCT FROM OLD.marca_salida_id THEN
        RAISE EXCEPTION
            'No se puede cambiar la marca de salida: las condiciones y hándicaps del torneo ya fueron congelados.'
            USING ERRCODE = '55000',
                  HINT = 'La marca efectiva válida es la guardada en los snapshots por ronda.';
    END IF;

    IF NEW.tournament_team_id IS DISTINCT FROM OLD.tournament_team_id THEN
        RAISE EXCEPTION
            'No se puede cambiar el equipo: la composición competitiva del torneo ya fue congelada.'
            USING ERRCODE = '55000';
    END IF;

    -- Una baja sigue permitida. Una reactivación sólo es válida si esa misma
    -- inscripción formó parte del snapshot original.
    IF OLD.activo = false AND NEW.activo = true THEN
        SELECT EXISTS (
            SELECT 1
            FROM public.tournament_handicap_snapshots hs
            WHERE hs.tournament_id = OLD.tournament_id
              AND hs.tournament_registration_id = OLD.id
        )
        INTO v_pertenece_snapshot;

        IF NOT v_pertenece_snapshot THEN
            RAISE EXCEPTION
                'No se puede reactivar esta inscripción porque no formó parte de los participantes congelados.'
                USING ERRCODE = '55000',
                      HINT = 'Los casos excepcionales posteriores al congelamiento requieren un procedimiento explícito y auditado.';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.proteger_inscripcion_torneo_congelado() IS
    'Impide modificar la identidad competitiva de inscripciones o agregar participantes activos después del congelamiento del torneo.';

DROP TRIGGER IF EXISTS trg_proteger_inscripcion_torneo_congelado
    ON public.tournament_registrations;

CREATE TRIGGER trg_proteger_inscripcion_torneo_congelado
BEFORE INSERT OR UPDATE ON public.tournament_registrations
FOR EACH ROW
EXECUTE FUNCTION public.proteger_inscripcion_torneo_congelado();

REVOKE ALL ON FUNCTION public.proteger_inscripcion_torneo_congelado()
    FROM PUBLIC;

COMMIT;
