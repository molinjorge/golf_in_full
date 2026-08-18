BEGIN;

-- ============================================================================
-- MIGRACIÓN 138
-- 1. Mantiene las rondas activas en secuencia continua 1..N.
-- 2. Reutiliza/reactiva la ronda inactiva que ocupa el siguiente número.
-- 3. Bloquea rondas y condiciones deportivas específicas del torneo después
--    del congelamiento creado por la Migración 136.
--
-- NO BLOQUEA:
-- - tournament_cut_rules;
-- - grupos, turnos y preparación de salidas de rondas existentes;
-- - perfiles de jugadores;
-- - catálogos globales de categorías, campos, hoyos o marcas de salida.
-- ============================================================================

-- Detiene la migración si ya existen rondas ACTIVAS con huecos o con números
-- superiores al total declarado. No corrige datos silenciosamente.
DO $$
DECLARE
    v_inconsistencias text;
BEGIN
    WITH active_rounds AS (
        SELECT
            tr.tournament_id,
            t.nombre AS tournament_name,
            t.numero_rondas AS declared_rounds,
            tr.numero_ronda,
            row_number() OVER (
                PARTITION BY tr.tournament_id
                ORDER BY tr.numero_ronda
            )::integer AS expected_round
        FROM public.tournament_rounds tr
        JOIN public.tournaments t ON t.id = tr.tournament_id
        WHERE tr.activo = true
    )
    SELECT string_agg(
               format(
                   '%s (%s): ronda activa %s, se esperaba %s, declaradas %s',
                   tournament_name,
                   tournament_id,
                   numero_ronda,
                   expected_round,
                   declared_rounds
               ),
               E'\n'
               ORDER BY tournament_name, numero_ronda
           )
      INTO v_inconsistencias
      FROM active_rounds
     WHERE numero_ronda <> expected_round
        OR numero_ronda > declared_rounds;

    IF v_inconsistencias IS NOT NULL THEN
        RAISE EXCEPTION
            'Existen rondas activas fuera de secuencia. La Migración 138 no realizó cambios: %',
            v_inconsistencias
            USING ERRCODE = '23514',
                  HINT = 'Corrige o desactiva las rondas señaladas y vuelve a ejecutar la migración completa.';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Reemplaza la validación histórica, que sólo contaba rondas activas y por eso
-- permitía crear la ronda 3 cuando la ronda 2 existía inactiva.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.validar_limite_rondas()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tournament_id uuid;
    v_declared_rounds integer;
    v_first_missing integer;
    v_has_dependencies boolean;
BEGIN
    v_tournament_id := CASE WHEN TG_OP = 'DELETE'
                            THEN OLD.tournament_id
                            ELSE NEW.tournament_id END;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No se pueden crear, modificar, reactivar, desactivar ni eliminar rondas después de congelar el torneo.'
            USING ERRCODE = '55000';
    END IF;

    SELECT t.numero_rondas
      INTO v_declared_rounds
      FROM public.tournaments t
     WHERE t.id = v_tournament_id;

    IF v_declared_rounds IS NULL THEN
        RAISE EXCEPTION 'El torneo de la ronda no existe.' USING ERRCODE = '23503';
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.numero_ronda > v_declared_rounds THEN
            RAISE EXCEPTION
                'La ronda % excede las % ronda(s) declaradas para el torneo.',
                NEW.numero_ronda, v_declared_rounds
                USING ERRCODE = '23514';
        END IF;

        IF NEW.activo = true THEN
            SELECT gs
              INTO v_first_missing
              FROM generate_series(1, v_declared_rounds) AS gs
             WHERE NOT EXISTS (
                 SELECT 1
                 FROM public.tournament_rounds tr
                 WHERE tr.tournament_id = NEW.tournament_id
                   AND tr.numero_ronda = gs
                   AND tr.activo = true
             )
             ORDER BY gs
             LIMIT 1;

            IF v_first_missing IS NULL THEN
                RAISE EXCEPTION
                    'Todas las % ronda(s) declaradas ya están activas.',
                    v_declared_rounds
                    USING ERRCODE = '23514';
            END IF;

            IF NEW.numero_ronda <> v_first_missing THEN
                RAISE EXCEPTION
                    'La siguiente ronda activa debe ser la número %, no la número %.',
                    v_first_missing, NEW.numero_ronda
                    USING ERRCODE = '23514',
                          HINT = 'Utiliza crear_o_reactivar_siguiente_ronda para recuperar una ronda inactiva existente.';
            END IF;

            IF EXISTS (
                SELECT 1
                FROM public.tournament_rounds tr
                WHERE tr.tournament_id = NEW.tournament_id
                  AND tr.numero_ronda = NEW.numero_ronda
                  AND tr.activo = false
            ) THEN
                RAISE EXCEPTION
                    'La ronda % ya existe desactivada y debe reactivarse; no debe crearse una ronda nueva.',
                    NEW.numero_ronda
                    USING ERRCODE = '23505',
                          HINT = 'Utiliza crear_o_reactivar_siguiente_ronda.';
            END IF;
        END IF;

        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF NEW.tournament_id IS DISTINCT FROM OLD.tournament_id THEN
            RAISE EXCEPTION 'Una ronda existente no puede trasladarse a otro torneo.'
                USING ERRCODE = '55000';
        END IF;

        IF NEW.numero_ronda IS DISTINCT FROM OLD.numero_ronda THEN
            RAISE EXCEPTION
                'El número de una ronda existente no puede cambiarse; debe conservar su identidad histórica.'
                USING ERRCODE = '55000';
        END IF;

        IF NEW.fecha IS DISTINCT FROM OLD.fecha
           OR NEW.campo_golf_id IS DISTINCT FROM OLD.campo_golf_id
           OR NEW.formato_salida IS DISTINCT FROM OLD.formato_salida THEN
            SELECT EXISTS (
                SELECT 1
                FROM public.tournament_round_shifts rs
                WHERE rs.tournament_round_id = OLD.id
            )
            INTO v_has_dependencies;

            IF v_has_dependencies THEN
                RAISE EXCEPTION
                    'La ronda % tiene turnos o salidas relacionados; no se pueden cambiar su fecha, campo ni formato de salida.',
                    OLD.numero_ronda
                    USING ERRCODE = '23514';
            END IF;
        END IF;

        IF OLD.activo = false AND NEW.activo = true THEN
            SELECT gs
              INTO v_first_missing
              FROM generate_series(1, v_declared_rounds) AS gs
             WHERE NOT EXISTS (
                 SELECT 1
                 FROM public.tournament_rounds tr
                 WHERE tr.tournament_id = OLD.tournament_id
                   AND tr.numero_ronda = gs
                   AND tr.activo = true
             )
             ORDER BY gs
             LIMIT 1;

            IF v_first_missing IS NULL OR OLD.numero_ronda <> v_first_missing THEN
                RAISE EXCEPTION
                    'La ronda que debe reactivarse primero es la número %, no la número %.',
                    COALESCE(v_first_missing::text, 'ninguna'), OLD.numero_ronda
                    USING ERRCODE = '23514';
            END IF;
        END IF;

        IF OLD.activo = true AND NEW.activo = false
           AND EXISTS (
               SELECT 1
               FROM public.tournament_rounds later_round
               WHERE later_round.tournament_id = OLD.tournament_id
                 AND later_round.activo = true
                 AND later_round.numero_ronda > OLD.numero_ronda
           ) THEN
            RAISE EXCEPTION
                'No se puede desactivar la ronda % mientras existan rondas posteriores activas.',
                OLD.numero_ronda
                USING ERRCODE = '23514',
                      HINT = 'Desactiva primero las rondas posteriores, en orden descendente.';
        END IF;

        RETURN NEW;
    END IF;

    IF OLD.activo = true
       AND EXISTS (
           SELECT 1
           FROM public.tournament_rounds later_round
           WHERE later_round.tournament_id = OLD.tournament_id
             AND later_round.activo = true
             AND later_round.numero_ronda > OLD.numero_ronda
       ) THEN
        RAISE EXCEPTION
            'No se puede eliminar la ronda % mientras existan rondas posteriores activas.',
            OLD.numero_ronda
            USING ERRCODE = '23514';
    END IF;

    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_validar_limite_rondas
    ON public.tournament_rounds;

CREATE TRIGGER trg_validar_limite_rondas
BEFORE INSERT OR UPDATE OR DELETE ON public.tournament_rounds
FOR EACH ROW
EXECUTE FUNCTION public.validar_limite_rondas();

-- ---------------------------------------------------------------------------
-- RPC atómica utilizada por Lovable para crear la siguiente ronda o reactivar
-- la fila inactiva que ya ocupa ese número.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.crear_o_reactivar_siguiente_ronda(
    p_tournament_id uuid,
    p_fecha date,
    p_campo_golf_id uuid,
    p_tournament_format_id uuid DEFAULT NULL,
    p_handicap_allowance_pct numeric DEFAULT NULL,
    p_formato_salida public.formato_salida_ronda DEFAULT NULL
)
RETURNS public.tournament_rounds
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_declared_rounds integer;
    v_next_round integer;
    v_existing public.tournament_rounds%ROWTYPE;
    v_result public.tournament_rounds%ROWTYPE;
    v_admin_id uuid;
    v_has_dependencies boolean;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para administrar las rondas de este torneo.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(p_tournament_id::text, 138));

    SELECT t.numero_rondas
      INTO v_declared_rounds
      FROM public.tournaments t
     WHERE t.id = p_tournament_id
     FOR UPDATE;

    IF v_declared_rounds IS NULL THEN
        RAISE EXCEPTION 'El torneo no existe.' USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No se pueden crear ni reactivar rondas después de congelar el torneo.'
            USING ERRCODE = '55000';
    END IF;

    IF p_handicap_allowance_pct IS NOT NULL
       AND (p_handicap_allowance_pct < 0 OR p_handicap_allowance_pct > 100) THEN
        RAISE EXCEPTION 'Handicap Allowance fuera del rango 0..100.'
            USING ERRCODE = '22023';
    END IF;

    SELECT gs
      INTO v_next_round
      FROM generate_series(1, v_declared_rounds) AS gs
     WHERE NOT EXISTS (
         SELECT 1
         FROM public.tournament_rounds tr
         WHERE tr.tournament_id = p_tournament_id
           AND tr.numero_ronda = gs
           AND tr.activo = true
     )
     ORDER BY gs
     LIMIT 1;

    IF v_next_round IS NULL THEN
        RAISE EXCEPTION
            'Todas las % ronda(s) declaradas ya están activas.',
            v_declared_rounds
            USING ERRCODE = '23514';
    END IF;

    SELECT *
      INTO v_existing
      FROM public.tournament_rounds tr
     WHERE tr.tournament_id = p_tournament_id
       AND tr.numero_ronda = v_next_round
     FOR UPDATE;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo = true
     ORDER BY au.id
     LIMIT 1;

    IF v_existing.id IS NOT NULL THEN
        SELECT EXISTS (
            SELECT 1
            FROM public.tournament_round_shifts rs
            WHERE rs.tournament_round_id = v_existing.id
        )
        INTO v_has_dependencies;

        IF v_has_dependencies
           AND (
                p_fecha IS DISTINCT FROM v_existing.fecha
                OR p_campo_golf_id IS DISTINCT FROM v_existing.campo_golf_id
                OR p_formato_salida IS DISTINCT FROM v_existing.formato_salida
           ) THEN
            RAISE EXCEPTION
                'La ronda % tiene turnos o salidas relacionados; debe reactivarse conservando fecha, campo y formato de salida.',
                v_next_round
                USING ERRCODE = '23514',
                      HINT = 'Abre los datos existentes de la ronda inactiva y no cambies sus condiciones físicas.';
        END IF;

        UPDATE public.tournament_rounds
           SET fecha = p_fecha,
               campo_golf_id = p_campo_golf_id,
               tournament_format_id = p_tournament_format_id,
               handicap_allowance_pct = p_handicap_allowance_pct,
               formato_salida = p_formato_salida,
               activo = true,
               fecha_baja = NULL,
               dado_de_baja_por = NULL,
               motivo_baja = NULL
         WHERE id = v_existing.id
         RETURNING * INTO v_result;
    ELSE
        INSERT INTO public.tournament_rounds (
            tournament_id,
            numero_ronda,
            fecha,
            tournament_format_id,
            campo_golf_id,
            handicap_allowance_pct,
            formato_salida,
            activo,
            created_by
        )
        VALUES (
            p_tournament_id,
            v_next_round,
            p_fecha,
            p_tournament_format_id,
            p_campo_golf_id,
            p_handicap_allowance_pct,
            p_formato_salida,
            true,
            v_admin_id
        )
        RETURNING * INTO v_result;
    END IF;

    RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.crear_o_reactivar_siguiente_ronda(
    uuid, date, uuid, uuid, numeric, public.formato_salida_ronda
) IS
    'Crea la primera ronda activa faltante o reactiva la fila inactiva con ese número, sin generar huecos.';

-- ---------------------------------------------------------------------------
-- Condiciones específicas del torneo que no pueden cambiar tras congelarlo.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.proteger_condiciones_torneo_congelado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_max_active_round integer;
BEGIN
    IF NEW.numero_rondas IS DISTINCT FROM OLD.numero_rondas THEN
        SELECT max(tr.numero_ronda)
          INTO v_max_active_round
          FROM public.tournament_rounds tr
         WHERE tr.tournament_id = OLD.id
           AND tr.activo = true;

        IF NEW.numero_rondas < COALESCE(v_max_active_round, 0) THEN
            RAISE EXCEPTION
                'El torneo no puede reducirse a % ronda(s) porque existe la ronda activa %.',
                NEW.numero_rondas, v_max_active_round
                USING ERRCODE = '23514';
        END IF;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = OLD.id
    ) THEN
        RETURN NEW;
    END IF;

    IF NEW.numero_rondas IS DISTINCT FROM OLD.numero_rondas
       OR NEW.tournament_format_id IS DISTINCT FROM OLD.tournament_format_id
       OR NEW.campo_golf_id IS DISTINCT FROM OLD.campo_golf_id
       OR NEW.fecha_inicio IS DISTINCT FROM OLD.fecha_inicio
       OR NEW.fecha_fin IS DISTINCT FROM OLD.fecha_fin
       OR NEW.jugadores_por_equipo IS DISTINCT FROM OLD.jugadores_por_equipo
       OR NEW.jugadores_por_grupo IS DISTINCT FROM OLD.jugadores_por_grupo
       OR NEW.edad_senior_categoria_unica IS DISTINCT FROM OLD.edad_senior_categoria_unica THEN
        RAISE EXCEPTION
            'No se pueden cambiar las condiciones deportivas del torneo después de congelarlo.'
            USING ERRCODE = '55000';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_proteger_condiciones_torneo_congelado
    ON public.tournaments;

CREATE TRIGGER trg_proteger_condiciones_torneo_congelado
BEFORE UPDATE ON public.tournaments
FOR EACH ROW
EXECUTE FUNCTION public.proteger_condiciones_torneo_congelado();

CREATE OR REPLACE FUNCTION public.proteger_configuracion_especifica_torneo_congelado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_old_tournament_id uuid;
    v_new_tournament_id uuid;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old_tournament_id := OLD.tournament_id;
    END IF;

    IF TG_OP <> 'DELETE' THEN
        v_new_tournament_id := NEW.tournament_id;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = v_old_tournament_id
           OR f.tournament_id = v_new_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No se puede modificar esta configuración porque las condiciones del torneo ya fueron congeladas.'
            USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_proteger_tournament_categories_congelado
    ON public.tournament_categories;
CREATE TRIGGER trg_proteger_tournament_categories_congelado
BEFORE INSERT OR UPDATE OR DELETE ON public.tournament_categories
FOR EACH ROW
EXECUTE FUNCTION public.proteger_configuracion_especifica_torneo_congelado();

DROP TRIGGER IF EXISTS trg_proteger_tournament_franjas_handicap_congelado
    ON public.tournament_franjas_handicap;
CREATE TRIGGER trg_proteger_tournament_franjas_handicap_congelado
BEFORE INSERT OR UPDATE OR DELETE ON public.tournament_franjas_handicap
FOR EACH ROW
EXECUTE FUNCTION public.proteger_configuracion_especifica_torneo_congelado();

DROP TRIGGER IF EXISTS trg_proteger_tournament_tee_overrides_congelado
    ON public.tournament_tee_overrides;
CREATE TRIGGER trg_proteger_tournament_tee_overrides_congelado
BEFORE INSERT OR UPDATE OR DELETE ON public.tournament_tee_overrides
FOR EACH ROW
EXECUTE FUNCTION public.proteger_configuracion_especifica_torneo_congelado();

DROP TRIGGER IF EXISTS trg_proteger_tournament_tiebreak_rules_congelado
    ON public.tournament_tiebreak_rules;
CREATE TRIGGER trg_proteger_tournament_tiebreak_rules_congelado
BEFORE INSERT OR UPDATE OR DELETE ON public.tournament_tiebreak_rules
FOR EACH ROW
EXECUTE FUNCTION public.proteger_configuracion_especifica_torneo_congelado();

REVOKE ALL ON FUNCTION public.validar_limite_rondas() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.crear_o_reactivar_siguiente_ronda(
    uuid, date, uuid, uuid, numeric, public.formato_salida_ronda
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.proteger_condiciones_torneo_congelado() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.proteger_configuracion_especifica_torneo_congelado() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.crear_o_reactivar_siguiente_ronda(
    uuid, date, uuid, uuid, numeric, public.formato_salida_ronda
) TO authenticated;

COMMIT;
