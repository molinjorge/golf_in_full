-- ============================================================================
-- 179_cupo_categoria_contacto_y_validacion_configuracion.sql
-- TEE CENTRAL / GOLF IN FULL
--
-- OBJETIVO
-- 1. Reforzar el control EXISTENTE de cupo por categoría.
-- 2. Incluir phone_reservations también como punto de bloqueo, no sólo como
--    fuente de conteo.
-- 3. Serializar altas por categoría para evitar sobrecupo por concurrencia.
-- 4. Cuando la categoría esté llena, devolver mensaje amigable con el
--    organizador activo más reciente que tenga teléfono; si no hay teléfono,
--    mostrar el nombre; si no hay organizador, usar mensaje genérico.
-- 5. Al finalizar la configuración de un torneo, exigir:
--      - todas las categorías con cupo_maximo > 0;
--      - suma de cupos de categorías = tournaments.cupo_maximo.
--
-- NO MODIFICA DATOS HISTÓRICOS.
-- NO DESCONGELA TORNEOS.
-- NO CAMBIA REGLAS DE HÁNDICAP / CATEGORÍA.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. HELPER DE CONTACTO DEL ORGANIZADOR
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_contacto_organizador_torneo(
    p_tournament_id uuid
)
RETURNS TABLE (
    nombre text,
    telefono text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT
        concat_ws(
            ' ',
            NULLIF(trim(au.nombres), ''),
            NULLIF(trim(au.apellidos), '')
        ) AS nombre,
        NULLIF(trim(au.telefono), '') AS telefono
    FROM public.admin_role_assignments ara
    JOIN public.roles r
      ON r.id = ara.role_id
    JOIN public.admin_users au
      ON au.id = ara.admin_user_id
    WHERE ara.tournament_id = p_tournament_id
      AND ara.activo = true
      AND au.activo = true
      AND r.codigo = 'tournament_organizer'
    ORDER BY
        CASE
            WHEN NULLIF(trim(au.telefono), '') IS NOT NULL
            THEN 0 ELSE 1
        END,
        ara.created_at DESC,
        ara.id DESC
    LIMIT 1;
$function$;

REVOKE ALL
ON FUNCTION public.obtener_contacto_organizador_torneo(uuid)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.obtener_contacto_organizador_torneo(uuid)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.obtener_contacto_organizador_torneo(uuid)
TO authenticated, service_role;


-- ============================================================================
-- 02. REFORZAR validar_cupo_categoria_cruzado()
--
-- DETALLES:
-- - conserva exclusión para formatos por equipo;
-- - bloquea la fila tournament_categories para serializar operaciones
--   concurrentes sobre una misma categoría;
-- - usa to_jsonb(NEW) para leer player_id de forma segura, ya que
--   phone_reservations NO tiene player_id;
-- - evita doble conteo de la phone_reservation original cuando un contacto
--   nuevo se convierte en player/pre-reserva por coincidencia de teléfono.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.validar_cupo_categoria_cruzado()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cupo_maximo integer;
    v_total integer;
    v_tipo_participacion public.formato_juego_torneo;
    v_categoria_nombre text;
    v_organizador_nombre text;
    v_organizador_telefono text;
    v_player_id uuid;
BEGIN
    IF NEW.tournament_category_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT tf.tipo_participacion
      INTO v_tipo_participacion
      FROM public.tournaments t
      JOIN public.tournament_formats tf
        ON tf.id = t.tournament_format_id
     WHERE t.id = NEW.tournament_id;

    IF v_tipo_participacion = 'equipo'::public.formato_juego_torneo THEN
        RETURN NEW;
    END IF;

    -- Serializa altas que compiten por el mismo cupo.
    SELECT
        tc.cupo_maximo,
        c.nombre
      INTO
        v_cupo_maximo,
        v_categoria_nombre
      FROM public.tournament_categories tc
      JOIN public.categories c
        ON c.id = tc.category_id
     WHERE tc.id = NEW.tournament_category_id
     FOR UPDATE OF tc;

    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    IF v_cupo_maximo IS NULL THEN
        RETURN NEW;
    END IF;

    -- phone_reservations no tiene player_id. Esta lectura es segura
    -- para los tres tipos de registro que ejecutan el trigger.
    BEGIN
        v_player_id :=
            NULLIF(
                to_jsonb(NEW) ->> 'player_id',
                ''
            )::uuid;
    EXCEPTION
        WHEN invalid_text_representation THEN
            v_player_id := NULL;
    END;

    SELECT
        (
            SELECT count(*)
            FROM public.tournament_registrations tr
            WHERE tr.tournament_category_id = NEW.tournament_category_id
              AND tr.activo = true
        )
        +
        (
            SELECT count(*)
            FROM public.tournament_pre_reservations pr
            WHERE pr.tournament_category_id = NEW.tournament_category_id
              AND pr.activo = true
              AND pr.tournament_registration_id IS NULL
              AND (
                    v_player_id IS NULL
                    OR pr.player_id IS DISTINCT FROM v_player_id
                  )
        )
        +
        (
            SELECT count(*)
            FROM public.phone_reservations ph
            WHERE ph.tournament_category_id = NEW.tournament_category_id
              AND ph.activo = true
              AND (
                    v_player_id IS NULL
                    OR NOT EXISTS (
                        SELECT 1
                        FROM public.players p
                        WHERE p.id = v_player_id
                          AND p.telefono_pais IS NOT DISTINCT FROM ph.telefono_pais
                          AND p.telefono_lada IS NOT DISTINCT FROM ph.telefono_lada
                          AND p.telefono_numero IS NOT DISTINCT FROM ph.telefono_numero
                    )
                  )
        )
      INTO v_total;

    IF v_total >= v_cupo_maximo THEN

        SELECT o.nombre, o.telefono
          INTO v_organizador_nombre, v_organizador_telefono
          FROM public.obtener_contacto_organizador_torneo(
              NEW.tournament_id
          ) o;

        IF NULLIF(trim(v_organizador_nombre), '') IS NOT NULL
           AND NULLIF(trim(v_organizador_telefono), '') IS NOT NULL
        THEN
            RAISE EXCEPTION
                'Lo siento, la categoría "%" está llena. Puedes comunicarte con % al %.',
                COALESCE(v_categoria_nombre, 'seleccionada'),
                v_organizador_nombre,
                v_organizador_telefono
                USING
                    ERRCODE = 'P0001',
                    DETAIL = 'CATEGORY_FULL',
                    HINT = format(
                        'Cupo máximo: %s; ocupación actual: %s.',
                        v_cupo_maximo,
                        v_total
                    );

        ELSIF NULLIF(trim(v_organizador_nombre), '') IS NOT NULL THEN
            RAISE EXCEPTION
                'Lo siento, la categoría "%" está llena. Puedes comunicarte con %.',
                COALESCE(v_categoria_nombre, 'seleccionada'),
                v_organizador_nombre
                USING
                    ERRCODE = 'P0001',
                    DETAIL = 'CATEGORY_FULL',
                    HINT = format(
                        'Cupo máximo: %s; ocupación actual: %s.',
                        v_cupo_maximo,
                        v_total
                    );

        ELSE
            RAISE EXCEPTION
                'Lo siento, la categoría "%" está llena. Comunícate con el organizador del torneo para solicitar información.',
                COALESCE(v_categoria_nombre, 'seleccionada')
                USING
                    ERRCODE = 'P0001',
                    DETAIL = 'CATEGORY_FULL',
                    HINT = format(
                        'Cupo máximo: %s; ocupación actual: %s.',
                        v_cupo_maximo,
                        v_total
                    );
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;


-- ============================================================================
-- 03. TRIGGER FALTANTE EN phone_reservations
--
-- La función ya contaba phone_reservations desde Migración 103, pero la tabla
-- no tenía el trigger de cupo individual. Esto permite que una reserva
-- telefónica nueva sea rechazada ANTES de sobrepasar la categoría.
-- ============================================================================

DROP TRIGGER IF EXISTS
    trg_validar_cupo_categoria_cruzado_phone
ON public.phone_reservations;

CREATE TRIGGER trg_validar_cupo_categoria_cruzado_phone
BEFORE INSERT ON public.phone_reservations
FOR EACH ROW
EXECUTE FUNCTION public.validar_cupo_categoria_cruzado();


-- ============================================================================
-- 04. VALIDACIÓN DE CONFIGURACIÓN MÍNIMA
--
-- Se conserva la lógica creada en Migración 176 y se agregan:
-- - categoría sin cupo / cupo <= 0;
-- - suma de cupos distinta al cupo máximo del torneo.
--
-- Sólo se evalúa al intentar finalizar configuración. No altera ni reabre
-- torneos históricos ya configurados/congelados.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.validar_configuracion_minima_torneo(
    p_tournament_id uuid
)
RETURNS TABLE (
    listo boolean,
    errores jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
    v_total_rondas integer;
    v_total_rondas_activas integer;
    v_total_categorias integer;
    v_categorias_sin_cupo integer;
    v_suma_cupos bigint;
    v_errores jsonb := '[]'::jsonb;
BEGIN
    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    SELECT
        count(*),
        count(*) FILTER (WHERE activo = true)
      INTO
        v_total_rondas,
        v_total_rondas_activas
      FROM public.tournament_rounds
     WHERE tournament_id = p_tournament_id;

    SELECT
        count(*),
        count(*) FILTER (
            WHERE cupo_maximo IS NULL
               OR cupo_maximo <= 0
        ),
        COALESCE(sum(cupo_maximo), 0)
      INTO
        v_total_categorias,
        v_categorias_sin_cupo,
        v_suma_cupos
      FROM public.tournament_categories
     WHERE tournament_id = p_tournament_id;

    IF v_t.club_id IS NULL THEN
        v_errores := v_errores
            || jsonb_build_array('Falta asignar club.');
    END IF;

    IF v_t.campo_golf_id IS NULL THEN
        v_errores := v_errores
            || jsonb_build_array('Falta asignar campo de golf.');
    END IF;

    IF v_t.tournament_format_id IS NULL THEN
        v_errores := v_errores
            || jsonb_build_array(
                'Falta asignar modalidad/formato del torneo.'
            );
    END IF;

    IF v_t.cupo_maximo IS NULL OR v_t.cupo_maximo <= 0 THEN
        v_errores := v_errores
            || jsonb_build_array(
                'El cupo máximo debe ser mayor que cero.'
            );
    END IF;

    IF v_t.numero_rondas IS NULL OR v_t.numero_rondas <= 0 THEN
        v_errores := v_errores
            || jsonb_build_array(
                'El número de rondas debe ser mayor que cero.'
            );
    END IF;

    IF v_total_rondas_activas <> v_t.numero_rondas THEN
        v_errores := v_errores || jsonb_build_array(
            format(
                'Debe haber % ronda(s) activa(s) configurada(s); actualmente hay %.',
                v_t.numero_rondas,
                v_total_rondas_activas
            )
        );
    END IF;

    IF v_total_categorias <= 0 THEN
        v_errores := v_errores
            || jsonb_build_array(
                'El torneo no tiene categorías configuradas.'
            );
    ELSE
        IF v_categorias_sin_cupo > 0 THEN
            v_errores := v_errores || jsonb_build_array(
                format(
                    'Todas las categorías deben tener un cupo máximo mayor que cero. Hay % categoría(s) sin cupo válido.',
                    v_categorias_sin_cupo
                )
            );
        END IF;

        IF v_t.cupo_maximo IS NOT NULL
           AND v_t.cupo_maximo > 0
           AND v_suma_cupos <> v_t.cupo_maximo
        THEN
            v_errores := v_errores || jsonb_build_array(
                format(
                    'La suma de los cupos de las categorías (%) debe ser igual al cupo máximo del torneo (%).',
                    v_suma_cupos,
                    v_t.cupo_maximo
                )
            );
        END IF;
    END IF;

    RETURN QUERY
    SELECT
        jsonb_array_length(v_errores) = 0,
        v_errores;
END;
$function$;

REVOKE ALL
ON FUNCTION public.validar_configuracion_minima_torneo(uuid)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.validar_configuracion_minima_torneo(uuid)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.validar_configuracion_minima_torneo(uuid)
TO authenticated, service_role;

COMMIT;
