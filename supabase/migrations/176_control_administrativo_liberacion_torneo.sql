-- ============================================================================
-- 176_control_administrativo_liberacion_torneo.sql
-- TEE CENTRAL / GOLF IN FULL
--
-- OBJETIVO
-- Formalizar el flujo:
--
--   PROVISIONADO
--      ↓ Organizador termina configuración
--   CONFIGURACIÓN FINALIZADA / NO PUBLICADO
--      ↓ Superadmin confirma pago de plataforma
--   PAGADO / NO LIBERADO
--      ↓ Superadmin libera
--   ACTIVO + PUBLICABLE
--
-- PRINCIPIOS
--   - estatus deportivo y estado comercial siguen separados.
--   - el Organizador puede declarar terminada/reabierta su configuración.
--   - sólo Superadmin confirma el pago de plataforma.
--   - sólo Superadmin libera el torneo.
--   - liberar exige configuración finalizada + pago confirmado.
--   - estado_servicio='activo' y tournaments.activo=true deben ser coherentes.
--
-- NO MODIFICA AUTOMÁTICAMENTE TORNEOS EXISTENTES.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. TRAZABILIDAD DE CONFIGURACIÓN EN tournaments
-- ============================================================================

ALTER TABLE public.tournaments
    ADD COLUMN IF NOT EXISTS configuracion_finalizada_at timestamptz,
    ADD COLUMN IF NOT EXISTS configuracion_finalizada_por uuid;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE connamespace = 'public'::regnamespace
          AND conrelid = 'public.tournaments'::regclass
          AND conname = 'tournaments_configuracion_finalizada_por_fkey'
    ) THEN
        ALTER TABLE public.tournaments
            ADD CONSTRAINT tournaments_configuracion_finalizada_por_fkey
            FOREIGN KEY (configuracion_finalizada_por)
            REFERENCES public.admin_users(id)
            ON DELETE RESTRICT;
    END IF;
END
$$;

ALTER TABLE public.tournaments
    DROP CONSTRAINT IF EXISTS tournaments_configuracion_finalizada_consistente;

ALTER TABLE public.tournaments
    ADD CONSTRAINT tournaments_configuracion_finalizada_consistente
    CHECK (
        (
            configuracion_finalizada_at IS NULL
            AND configuracion_finalizada_por IS NULL
        )
        OR
        (
            configuracion_finalizada_at IS NOT NULL
            AND configuracion_finalizada_por IS NOT NULL
        )
    );


-- ============================================================================
-- 02. TRAZABILIDAD COMERCIAL EN tournament_commercial_profiles
-- ============================================================================

ALTER TABLE public.tournament_commercial_profiles
    ADD COLUMN IF NOT EXISTS paid_by uuid,
    ADD COLUMN IF NOT EXISTS released_at timestamptz,
    ADD COLUMN IF NOT EXISTS released_by uuid;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE connamespace = 'public'::regnamespace
          AND conrelid = 'public.tournament_commercial_profiles'::regclass
          AND conname = 'tournament_commercial_profiles_paid_by_fkey'
    ) THEN
        ALTER TABLE public.tournament_commercial_profiles
            ADD CONSTRAINT tournament_commercial_profiles_paid_by_fkey
            FOREIGN KEY (paid_by)
            REFERENCES public.admin_users(id)
            ON DELETE RESTRICT;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE connamespace = 'public'::regnamespace
          AND conrelid = 'public.tournament_commercial_profiles'::regclass
          AND conname = 'tournament_commercial_profiles_released_by_fkey'
    ) THEN
        ALTER TABLE public.tournament_commercial_profiles
            ADD CONSTRAINT tournament_commercial_profiles_released_by_fkey
            FOREIGN KEY (released_by)
            REFERENCES public.admin_users(id)
            ON DELETE RESTRICT;
    END IF;
END
$$;

ALTER TABLE public.tournament_commercial_profiles
    DROP CONSTRAINT IF EXISTS tournament_commercial_profiles_pago_consistente;

-- Compatibilidad histórica:
-- paid_by se incorpora en esta migración, por lo que pagos anteriores pueden
-- tener paid=true sin paid_by. No inventamos quién confirmó esos pagos.
ALTER TABLE public.tournament_commercial_profiles
    ADD CONSTRAINT tournament_commercial_profiles_pago_consistente
    CHECK (
        (paid = false OR paid_at IS NOT NULL)
        AND (paid_by IS NULL OR paid = true)
    )
    NOT VALID;

ALTER TABLE public.tournament_commercial_profiles
    DROP CONSTRAINT IF EXISTS tournament_commercial_profiles_liberacion_consistente;

ALTER TABLE public.tournament_commercial_profiles
    ADD CONSTRAINT tournament_commercial_profiles_liberacion_consistente
    CHECK (
        (
            released_at IS NULL
            AND released_by IS NULL
        )
        OR
        (
            released_at IS NOT NULL
            AND released_by IS NOT NULL
        )
    );


-- ============================================================================
-- 03. HELPER DE VALIDACIÓN DE CONFIGURACIÓN MÍNIMA
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

    SELECT count(*)
      INTO v_total_categorias
      FROM public.tournament_categories
     WHERE tournament_id = p_tournament_id;

    IF v_t.club_id IS NULL THEN
        v_errores := v_errores || jsonb_build_array('Falta asignar club.');
    END IF;

    IF v_t.campo_golf_id IS NULL THEN
        v_errores := v_errores || jsonb_build_array('Falta asignar campo de golf.');
    END IF;

    IF v_t.tournament_format_id IS NULL THEN
        v_errores := v_errores || jsonb_build_array('Falta asignar modalidad/formato del torneo.');
    END IF;

    IF v_t.cupo_maximo IS NULL OR v_t.cupo_maximo <= 0 THEN
        v_errores := v_errores || jsonb_build_array('El cupo máximo debe ser mayor que cero.');
    END IF;

    IF v_t.numero_rondas IS NULL OR v_t.numero_rondas <= 0 THEN
        v_errores := v_errores || jsonb_build_array('El número de rondas debe ser mayor que cero.');
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
        v_errores := v_errores || jsonb_build_array('El torneo no tiene categorías configuradas.');
    END IF;

    RETURN QUERY
    SELECT
        jsonb_array_length(v_errores) = 0,
        v_errores;
END;
$function$;

REVOKE ALL
ON FUNCTION public.validar_configuracion_minima_torneo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.validar_configuracion_minima_torneo(uuid)
TO authenticated, service_role;


-- ============================================================================
-- 04. PROTECCIÓN DE CAMPOS DE FINALIZACIÓN
--     Impide que la UI los actualice directamente.
--     La modificación normal debe pasar por las RPC.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.proteger_finalizacion_configuracion_torneo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_permitido text;
BEGIN
    IF NEW.configuracion_finalizada_at
           IS NOT DISTINCT FROM OLD.configuracion_finalizada_at
       AND NEW.configuracion_finalizada_por
           IS NOT DISTINCT FROM OLD.configuracion_finalizada_por
    THEN
        RETURN NEW;
    END IF;

    v_permitido :=
        current_setting(
            'app.permitir_finalizacion_configuracion_torneo',
            true
        );

    IF current_user = 'postgres'
       OR auth.role() = 'service_role'
       OR COALESCE(v_permitido, '0') = '1'
    THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION
        'La finalización de configuración debe realizarse mediante la acción autorizada del sistema.'
        USING ERRCODE = '42501';
END;
$function$;

DROP TRIGGER IF EXISTS
    trg_proteger_finalizacion_configuracion_torneo
ON public.tournaments;

CREATE TRIGGER trg_proteger_finalizacion_configuracion_torneo
BEFORE UPDATE OF
    configuracion_finalizada_at,
    configuracion_finalizada_por
ON public.tournaments
FOR EACH ROW
EXECUTE FUNCTION public.proteger_finalizacion_configuracion_torneo();


-- ============================================================================
-- 05. RPC — ORGANIZADOR FINALIZA CONFIGURACIÓN
-- ============================================================================

CREATE OR REPLACE FUNCTION public.finalizar_configuracion_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_admin_id uuid;
    v_listo boolean;
    v_errores jsonb;
    v_estado public.estado_servicio_torneo;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(
            auth.uid(),
            p_tournament_id
        )
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden finalizar la configuración del torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT estado_servicio
      INTO v_estado
      FROM public.tournaments
     WHERE id = p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF v_estado <> 'provisionado'::public.estado_servicio_torneo THEN
        RAISE EXCEPTION
            'La configuración sólo puede finalizarse mientras el torneo está provisionado. Estado actual: %.',
            v_estado;
    END IF;

    SELECT v.listo, v.errores
      INTO v_listo, v_errores
      FROM public.validar_configuracion_minima_torneo(
          p_tournament_id
      ) v;

    IF NOT v_listo THEN
        RAISE EXCEPTION
            'La configuración del torneo todavía no está completa: %',
            v_errores::text
            USING ERRCODE = '23514';
    END IF;

    SELECT public.current_admin_id()
      INTO v_admin_id;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No se encontró el usuario administrativo autenticado.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM set_config(
        'app.permitir_finalizacion_configuracion_torneo',
        '1',
        true
    );

    UPDATE public.tournaments
       SET configuracion_finalizada_at = COALESCE(
               configuracion_finalizada_at,
               now()
           ),
           configuracion_finalizada_por = COALESCE(
               configuracion_finalizada_por,
               v_admin_id
           )
     WHERE id = p_tournament_id;

    RETURN jsonb_build_object(
        'ok', true,
        'tournamentId', p_tournament_id,
        'configuracionFinalizada', true,
        'configuracionFinalizadaAt',
            (
                SELECT configuracion_finalizada_at
                FROM public.tournaments
                WHERE id = p_tournament_id
            ),
        'estadoServicio', v_estado::text,
        'activo',
            (
                SELECT activo
                FROM public.tournaments
                WHERE id = p_tournament_id
            )
    );
END;
$function$;

REVOKE ALL
ON FUNCTION public.finalizar_configuracion_torneo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.finalizar_configuracion_torneo(uuid)
TO authenticated;


-- ============================================================================
-- 06. RPC — REABRIR CONFIGURACIÓN ANTES DE LIBERACIÓN
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reabrir_configuracion_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_estado public.estado_servicio_torneo;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(
            auth.uid(),
            p_tournament_id
        )
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden reabrir la configuración del torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT estado_servicio
      INTO v_estado
      FROM public.tournaments
     WHERE id = p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF v_estado <> 'provisionado'::public.estado_servicio_torneo THEN
        RAISE EXCEPTION
            'No se puede reabrir la configuración después de que el torneo fue liberado.'
            USING ERRCODE = '55000';
    END IF;

    PERFORM set_config(
        'app.permitir_finalizacion_configuracion_torneo',
        '1',
        true
    );

    UPDATE public.tournaments
       SET configuracion_finalizada_at = NULL,
           configuracion_finalizada_por = NULL
     WHERE id = p_tournament_id;

    RETURN jsonb_build_object(
        'ok', true,
        'tournamentId', p_tournament_id,
        'configuracionFinalizada', false
    );
END;
$function$;

REVOKE ALL
ON FUNCTION public.reabrir_configuracion_torneo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.reabrir_configuracion_torneo(uuid)
TO authenticated;


-- ============================================================================
-- 07. RPC — SUPERADMIN CONFIRMA PAGO DE PLATAFORMA
-- ============================================================================

CREATE OR REPLACE FUNCTION public.confirmar_pago_plataforma_torneo(
    p_tournament_id uuid,
    p_payment_reference text DEFAULT NULL,
    p_payment_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_admin_id uuid;
    v_profile_id uuid;
    v_fee numeric;
    v_currency text;
BEGIN
    IF auth.uid() IS NULL
       OR NOT public.is_superadmin(auth.uid())
    THEN
        RAISE EXCEPTION
            'Sólo el Superadmin puede confirmar el pago de la plataforma.'
            USING ERRCODE = '42501';
    END IF;

    SELECT public.current_admin_id()
      INTO v_admin_id;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No se encontró el usuario administrativo del Superadmin.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        id,
        platform_fee,
        currency
      INTO
        v_profile_id,
        v_fee,
        v_currency
      FROM public.tournament_commercial_profiles
     WHERE tournament_id = p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El torneo no tiene perfil comercial.'
            USING ERRCODE = '22023';
    END IF;

    UPDATE public.tournament_commercial_profiles
       SET paid = true,
           paid_at = CASE
               WHEN paid = true AND paid_at IS NOT NULL
                   THEN paid_at
               ELSE now()
           END,
           paid_by = COALESCE(paid_by, v_admin_id),
           payment_reference =
               COALESCE(
                   NULLIF(trim(p_payment_reference), ''),
                   payment_reference
               ),
           payment_notes =
               COALESCE(
                   NULLIF(trim(p_payment_notes), ''),
                   payment_notes
               )
     WHERE id = v_profile_id;

    RETURN jsonb_build_object(
        'ok', true,
        'tournamentId', p_tournament_id,
        'platformFee', v_fee,
        'currency', v_currency,
        'paid', true,
        'paidAt',
            (
                SELECT paid_at
                FROM public.tournament_commercial_profiles
                WHERE id = v_profile_id
            )
    );
END;
$function$;

REVOKE ALL
ON FUNCTION public.confirmar_pago_plataforma_torneo(uuid, text, text)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.confirmar_pago_plataforma_torneo(uuid, text, text)
TO authenticated;


-- ============================================================================
-- 08. ENDURECER COHERENCIA estado_servicio / activo
--     Y EXIGIR CONFIGURACIÓN + PAGO PARA ACTIVAR
-- ============================================================================

CREATE OR REPLACE FUNCTION public.proteger_estado_servicio_torneo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_role text;
    v_paid boolean;
    v_configurada boolean;
BEGIN
    -- Coherencia estructural permanente.
    IF NEW.activo = true
       AND NEW.estado_servicio
           IS DISTINCT FROM 'activo'::public.estado_servicio_torneo
    THEN
        RAISE EXCEPTION
            'Un torneo activo debe tener estado_servicio = activo.'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.estado_servicio =
           'activo'::public.estado_servicio_torneo
       AND NEW.activo IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION
            'Un torneo con estado_servicio = activo debe tener activo = true.'
            USING ERRCODE = '23514';
    END IF;

    -- Si no cambia estado_servicio, sólo queda validada la coherencia.
    IF NEW.estado_servicio
           IS NOT DISTINCT FROM OLD.estado_servicio
    THEN
        RETURN NEW;
    END IF;

    v_role := auth.role();

    IF NOT (
        current_user = 'postgres'
        OR v_role = 'service_role'
        OR public.is_superadmin(auth.uid())
    ) THEN
        RAISE EXCEPTION
            'Sólo el Superadmin puede cambiar el estado de servicio del torneo.'
            USING ERRCODE = '42501';
    END IF;

    -- Transición a ACTIVO:
    -- sólo si configuración finalizada y pago confirmado.
    IF NEW.estado_servicio =
           'activo'::public.estado_servicio_torneo
       AND OLD.estado_servicio
           IS DISTINCT FROM 'activo'::public.estado_servicio_torneo
    THEN
        v_configurada :=
            NEW.configuracion_finalizada_at IS NOT NULL
            AND NEW.configuracion_finalizada_por IS NOT NULL;

        SELECT tcp.paid
          INTO v_paid
          FROM public.tournament_commercial_profiles tcp
         WHERE tcp.tournament_id = NEW.id;

        IF NOT COALESCE(v_configurada, false) THEN
            RAISE EXCEPTION
                'No se puede liberar el torneo: el organizador aún no ha finalizado la configuración.'
                USING ERRCODE = '23514';
        END IF;

        IF NOT COALESCE(v_paid, false) THEN
            RAISE EXCEPTION
                'No se puede liberar el torneo: la cuota de plataforma aún no está confirmada como pagada.'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS
    trg_proteger_estado_servicio_torneo
ON public.tournaments;

CREATE TRIGGER trg_proteger_estado_servicio_torneo
BEFORE UPDATE OF
    estado_servicio,
    activo
ON public.tournaments
FOR EACH ROW
EXECUTE FUNCTION public.proteger_estado_servicio_torneo();


-- ============================================================================
-- 09. RPC — SUPERADMIN LIBERA TORNEO
-- ============================================================================

CREATE OR REPLACE FUNCTION public.liberar_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_admin_id uuid;
    v_t public.tournaments%ROWTYPE;
    v_profile public.tournament_commercial_profiles%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL
       OR NOT public.is_superadmin(auth.uid())
    THEN
        RAISE EXCEPTION
            'Sólo el Superadmin puede liberar el torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT public.current_admin_id()
      INTO v_admin_id;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No se encontró el usuario administrativo del Superadmin.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
      INTO v_profile
      FROM public.tournament_commercial_profiles
     WHERE tournament_id = p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El torneo no tiene perfil comercial.'
            USING ERRCODE = '22023';
    END IF;

    IF v_t.configuracion_finalizada_at IS NULL
       OR v_t.configuracion_finalizada_por IS NULL
    THEN
        RAISE EXCEPTION
            'No se puede liberar el torneo: el organizador aún no ha finalizado la configuración.'
            USING ERRCODE = '23514';
    END IF;

    IF v_profile.paid IS DISTINCT FROM true THEN
        RAISE EXCEPTION
            'No se puede liberar el torneo: la cuota de plataforma aún no está confirmada como pagada.'
            USING ERRCODE = '23514';
    END IF;

    IF v_t.estado_servicio =
           'activo'::public.estado_servicio_torneo
       AND v_t.activo = true
    THEN
        RETURN jsonb_build_object(
            'ok', true,
            'tournamentId', p_tournament_id,
            'alreadyReleased', true,
            'estadoServicio', 'activo',
            'activo', true
        );
    END IF;

    IF v_t.estado_servicio
       <> 'provisionado'::public.estado_servicio_torneo
    THEN
        RAISE EXCEPTION
            'Sólo puede liberarse un torneo provisionado. Estado actual: %.',
            v_t.estado_servicio
            USING ERRCODE = '23514';
    END IF;

    UPDATE public.tournaments
       SET estado_servicio =
               'activo'::public.estado_servicio_torneo,
           activo = true
     WHERE id = p_tournament_id;

    UPDATE public.tournament_commercial_profiles
       SET released_at = COALESCE(released_at, now()),
           released_by = COALESCE(released_by, v_admin_id)
     WHERE tournament_id = p_tournament_id;

    RETURN jsonb_build_object(
        'ok', true,
        'tournamentId', p_tournament_id,
        'alreadyReleased', false,
        'estadoServicio', 'activo',
        'activo', true,
        'releasedAt',
            (
                SELECT released_at
                FROM public.tournament_commercial_profiles
                WHERE tournament_id = p_tournament_id
            )
    );
END;
$function$;

REVOKE ALL
ON FUNCTION public.liberar_torneo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.liberar_torneo(uuid)
TO authenticated;


-- ============================================================================
-- 10. RPC — DATOS PARA FUTURA PESTAÑA ADMINISTRATIVA
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_control_administrativo_torneos()
RETURNS TABLE (
    tournament_id uuid,
    tournament_name text,
    fecha_inicio date,
    fecha_fin date,
    estatus_deportivo text,
    estado_servicio text,
    activo boolean,

    configuracion_finalizada boolean,
    configuracion_finalizada_at timestamptz,
    configuracion_finalizada_por uuid,

    platform_fee numeric,
    currency text,
    paid boolean,
    paid_at timestamptz,
    paid_by uuid,
    payment_reference text,
    payment_notes text,

    released boolean,
    released_at timestamptz,
    released_by uuid,

    listo_para_liberar boolean,
    visible_publicamente boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL
       OR NOT public.is_superadmin(auth.uid())
    THEN
        RAISE EXCEPTION
            'Sólo el Superadmin puede consultar el control administrativo de torneos.'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT
        t.id,
        t.nombre,
        t.fecha_inicio,
        t.fecha_fin,
        t.estatus::text,
        t.estado_servicio::text,
        t.activo,

        (
            t.configuracion_finalizada_at IS NOT NULL
            AND t.configuracion_finalizada_por IS NOT NULL
        ),
        t.configuracion_finalizada_at,
        t.configuracion_finalizada_por,

        tcp.platform_fee,
        tcp.currency,
        tcp.paid,
        tcp.paid_at,
        tcp.paid_by,
        tcp.payment_reference,
        tcp.payment_notes,

        (
            tcp.released_at IS NOT NULL
            AND tcp.released_by IS NOT NULL
        ),
        tcp.released_at,
        tcp.released_by,

        (
            t.configuracion_finalizada_at IS NOT NULL
            AND tcp.paid = true
            AND t.estado_servicio =
                'provisionado'::public.estado_servicio_torneo
            AND t.activo = false
        ),

        (
            t.estado_servicio =
                'activo'::public.estado_servicio_torneo
            AND t.activo = true
            AND t.estatus =
                'inscripciones_abiertas'::public.estatus_torneo
        )

    FROM public.tournaments t
    LEFT JOIN public.tournament_commercial_profiles tcp
      ON tcp.tournament_id = t.id
    ORDER BY
        CASE
            WHEN t.estado_servicio =
                 'provisionado'::public.estado_servicio_torneo
            THEN 0
            ELSE 1
        END,
        t.fecha_inicio,
        t.nombre;
END;
$function$;

REVOKE ALL
ON FUNCTION public.obtener_control_administrativo_torneos()
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.obtener_control_administrativo_torneos()
TO authenticated;

COMMIT;
