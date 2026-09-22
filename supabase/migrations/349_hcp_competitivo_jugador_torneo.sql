-- MIGRACIÓN 349 — HCP COMPETITIVO DEL JUGADOR ESPECÍFICO PARA EL TORNEO
-- TEE CENTRAL / GOLF IN FULL
--
-- Objetivo:
-- Permitir que Organizador/Superadmin establezca, antes del Freeze, un HCP competitivo
-- exclusivo para una inscripción, sin modificar public.players.
--
-- Reglas clave:
-- 1) HCP efectivo = override del torneo si existe; en otro caso HCP verificado/declarado del perfil.
-- 2) Categoría y marca se protegen conjuntamente.
-- 3) Si la categoría actual sigue siendo elegible, se conserva categoría y marca.
-- 4) Si deja de ser elegible, la operación exige una categoría elegible explícita.
-- 5) Si se cambia categoría, se asigna la marca estándar activa correspondiente en el campo del torneo.
-- 6) Si no existe una marca válida, aborta toda la transacción.
-- 7) Después del Freeze no se permite cambiar el HCP competitivo.
-- 8) El Freeze conserva el override en tournament_handicap_snapshots mediante trigger BEFORE INSERT.
-- 9) Se registra auditoría específica del ajuste.
--
-- IMPORTANTE: ejecutar manualmente. ChatGPT no ejecuta esta migración.

BEGIN;

-- ---------------------------------------------------------------------------
-- 01. COLUMNAS EN LA INSCRIPCIÓN
-- ---------------------------------------------------------------------------

ALTER TABLE public.tournament_registrations
    ADD COLUMN IF NOT EXISTS handicap_torneo numeric,
    ADD COLUMN IF NOT EXISTS handicap_torneo_motivo text,
    ADD COLUMN IF NOT EXISTS handicap_torneo_ajustado_at timestamptz,
    ADD COLUMN IF NOT EXISTS handicap_torneo_ajustado_por uuid;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'tournament_registrations_handicap_torneo_rango_349_chk'
          AND conrelid = 'public.tournament_registrations'::regclass
    ) THEN
        ALTER TABLE public.tournament_registrations
            ADD CONSTRAINT tournament_registrations_handicap_torneo_rango_349_chk
            CHECK (handicap_torneo IS NULL OR handicap_torneo BETWEEN -10.0 AND 54.0);
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'tournament_registrations_handicap_torneo_admin_349_fkey'
          AND conrelid = 'public.tournament_registrations'::regclass
    ) THEN
        ALTER TABLE public.tournament_registrations
            ADD CONSTRAINT tournament_registrations_handicap_torneo_admin_349_fkey
            FOREIGN KEY (handicap_torneo_ajustado_por)
            REFERENCES public.admin_users(id)
            ON DELETE RESTRICT;
    END IF;
END $$;

COMMENT ON COLUMN public.tournament_registrations.handicap_torneo IS
'HCP competitivo específico de esta inscripción. NULL = usar HCP del perfil. No modifica public.players.';

COMMENT ON COLUMN public.tournament_registrations.handicap_torneo_motivo IS
'Motivo administrativo del override de HCP competitivo del torneo.';

-- ---------------------------------------------------------------------------
-- 02. AUDITORÍA ESPECÍFICA
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_registration_handicap_adjustments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    tournament_registration_id uuid NOT NULL REFERENCES public.tournament_registrations(id) ON DELETE RESTRICT,
    player_id uuid NOT NULL REFERENCES public.players(id) ON DELETE RESTRICT,

    handicap_perfil numeric,
    handicap_torneo_anterior numeric,
    handicap_torneo_nuevo numeric NOT NULL,

    tournament_category_id_anterior uuid REFERENCES public.tournament_categories(id) ON DELETE RESTRICT,
    tournament_category_id_nueva uuid REFERENCES public.tournament_categories(id) ON DELETE RESTRICT,
    marca_salida_id_anterior uuid REFERENCES public.marcas_salida(id) ON DELETE RESTRICT,
    marca_salida_id_nueva uuid REFERENCES public.marcas_salida(id) ON DELETE RESTRICT,

    motivo text NOT NULL,
    adjusted_by uuid NOT NULL REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    adjusted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_trha_349_registration
    ON public.tournament_registration_handicap_adjustments(tournament_registration_id, adjusted_at DESC);

ALTER TABLE public.tournament_registration_handicap_adjustments ENABLE ROW LEVEL SECURITY;

-- La tabla se opera por RPC SECURITY DEFINER; no se abren escrituras directas al cliente.
REVOKE ALL ON TABLE public.tournament_registration_handicap_adjustments FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 03. HCP EFECTIVO DE UNA INSCRIPCIÓN
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._handicap_efectivo_inscripcion_349(
    p_tournament_registration_id uuid
)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT COALESCE(
        tr.handicap_torneo,
        p.handicap_verificado,
        p.handicap_declarado
    )
    FROM public.tournament_registrations tr
    JOIN public.players p ON p.id = tr.player_id
    WHERE tr.id = p_tournament_registration_id;
$$;

REVOKE ALL ON FUNCTION public._handicap_efectivo_inscripcion_349(uuid) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 04. CATEGORÍAS ELEGIBLES:
--     MISMA REGLA HISTÓRICA, PERO USA HCP TORNEO CUANDO YA EXISTE INSCRIPCIÓN.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._categorias_elegibles_jugador(
    p_tournament_id uuid,
    p_player_id uuid
)
RETURNS TABLE(
    tournament_category_id uuid,
    category_id uuid,
    codigo text,
    nombre text,
    genero text,
    handicap_minimo numeric,
    handicap_maximo numeric,
    edad_minima integer,
    edad_maxima integer,
    categoria_estandar_marca categoria_marca_salida,
    display_order integer,
    tipo_elegibilidad text,
    es_categoria_natural boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_auth_user_id uuid;
    v_player_auth_user_id uuid;
    v_handicap numeric;
    v_sexo text;
    v_edad integer;
    v_fecha_inicio date;
    v_role text;
BEGIN
    v_auth_user_id := auth.uid();
    v_role := auth.role();

    SELECT
        p.auth_user_id,
        COALESCE(
            (
                SELECT tr.handicap_torneo
                FROM public.tournament_registrations tr
                WHERE tr.tournament_id = p_tournament_id
                  AND tr.player_id = p_player_id
                  AND tr.activo = true
                ORDER BY tr.created_at DESC, tr.id
                LIMIT 1
            ),
            p.handicap_verificado,
            p.handicap_declarado
        ),
        p.sexo::text,
        t.fecha_inicio
    INTO
        v_player_auth_user_id,
        v_handicap,
        v_sexo,
        v_fecha_inicio
    FROM public.players p
    CROSS JOIN public.tournaments t
    WHERE p.id = p_player_id
      AND t.id = p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el jugador o el torneo indicado.'
            USING ERRCODE = '22023';
    END IF;

    IF v_role IS NOT NULL
       AND v_role <> 'service_role'
       AND (
            v_auth_user_id IS NULL
            OR v_player_auth_user_id IS DISTINCT FROM v_auth_user_id
       )
       AND NOT COALESCE(public.is_active_admin(v_auth_user_id), false)
    THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar las categorías elegibles de este jugador.'
            USING ERRCODE = '42501';
    END IF;

    SELECT date_part('year', age(v_fecha_inicio, p.fecha_nacimiento))::integer
      INTO v_edad
      FROM public.players p
     WHERE p.id = p_player_id;

    RETURN QUERY
    WITH categorias AS (
        SELECT
            tc.id AS tournament_category_id,
            c.id AS category_id,
            c.codigo,
            c.nombre,
            c.genero,
            COALESCE(tc.handicap_minimo, c.handicap_minimo) AS hcp_min,
            COALESCE(tc.handicap_maximo, c.handicap_maximo) AS hcp_max,
            c.edad_minima,
            c.edad_maxima,
            c.categoria_estandar_marca,
            c.display_order,
            (
                COALESCE(tc.handicap_minimo, c.handicap_minimo) IS NOT NULL
                OR COALESCE(tc.handicap_maximo, c.handicap_maximo) IS NOT NULL
            ) AS tiene_rango_hcp,
            (
                c.edad_minima IS NOT NULL
                OR c.edad_maxima IS NOT NULL
            ) AS tiene_rango_edad
        FROM public.tournament_categories tc
        JOIN public.categories c ON c.id = tc.category_id
        WHERE tc.tournament_id = p_tournament_id
          AND (c.genero IS NULL OR c.genero = v_sexo)
    ),
    categoria_natural AS (
        SELECT c.tournament_category_id, c.hcp_min, c.hcp_max
        FROM categorias c
        WHERE c.tiene_rango_hcp
          AND v_handicap IS NOT NULL
          AND (c.hcp_min IS NULL OR v_handicap >= c.hcp_min)
          AND (c.hcp_max IS NULL OR v_handicap <= c.hcp_max)
        ORDER BY
            CASE WHEN c.genero = v_sexo THEN 0 ELSE 1 END,
            COALESCE(c.hcp_min, -9999::numeric),
            COALESCE(c.hcp_max, 9999::numeric),
            c.display_order NULLS LAST,
            c.nombre
        LIMIT 1
    )
    SELECT
        c.tournament_category_id,
        c.category_id,
        c.codigo,
        c.nombre,
        c.genero,
        c.hcp_min,
        c.hcp_max,
        c.edad_minima,
        c.edad_maxima,
        c.categoria_estandar_marca,
        c.display_order,
        CASE
            WHEN c.tiene_rango_hcp
                 AND c.tournament_category_id = n.tournament_category_id
                THEN 'NATURAL'
            WHEN c.tiene_rango_hcp THEN 'SUPERIOR'
            WHEN c.tiene_rango_edad THEN 'EDAD'
            ELSE 'ABIERTA'
        END,
        (c.tournament_category_id = n.tournament_category_id)
    FROM categorias c
    LEFT JOIN categoria_natural n ON true
    WHERE
        (
            c.tiene_rango_hcp
            AND n.tournament_category_id IS NOT NULL
            AND COALESCE(c.hcp_min, -9999::numeric)
                <= COALESCE(n.hcp_min, -9999::numeric)
        )
        OR
        (
            NOT c.tiene_rango_hcp
            AND c.tiene_rango_edad
            AND v_edad IS NOT NULL
            AND (c.edad_minima IS NULL OR v_edad >= c.edad_minima)
            AND (c.edad_maxima IS NULL OR v_edad <= c.edad_maxima)
        )
        OR
        (
            NOT c.tiene_rango_hcp
            AND NOT c.tiene_rango_edad
        )
    ORDER BY
        c.display_order NULLS LAST,
        CASE
            WHEN c.tiene_rango_hcp THEN 0
            WHEN c.tiene_rango_edad THEN 1
            ELSE 2
        END,
        COALESCE(c.hcp_min, -9999::numeric),
        c.nombre;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 05. BLOQUEO EXPLÍCITO POST-FREEZE DEL HCP TORNEO
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._proteger_handicap_torneo_post_freeze_349()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF (
        NEW.handicap_torneo IS DISTINCT FROM OLD.handicap_torneo
        OR NEW.handicap_torneo_motivo IS DISTINCT FROM OLD.handicap_torneo_motivo
        OR NEW.handicap_torneo_ajustado_at IS DISTINCT FROM OLD.handicap_torneo_ajustado_at
        OR NEW.handicap_torneo_ajustado_por IS DISTINCT FROM OLD.handicap_torneo_ajustado_por
    )
    AND EXISTS (
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = OLD.tournament_id
    )
    THEN
        RAISE EXCEPTION
            'No se puede modificar el HCP competitivo del torneo después del Freeze.'
            USING ERRCODE = '55000',
                  HINT = 'El HCP competitivo válido ya forma parte de la evidencia congelada.';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_proteger_handicap_torneo_post_freeze_349
ON public.tournament_registrations;

CREATE TRIGGER trg_proteger_handicap_torneo_post_freeze_349
BEFORE UPDATE OF handicap_torneo, handicap_torneo_motivo,
                 handicap_torneo_ajustado_at, handicap_torneo_ajustado_por
ON public.tournament_registrations
FOR EACH ROW
EXECUTE FUNCTION public._proteger_handicap_torneo_post_freeze_349();

-- ---------------------------------------------------------------------------
-- 06. RPC ADMINISTRATIVO ATÓMICO
--     p_nueva_categoria_id:
--       NULL = conservar categoría actual si sigue siendo elegible.
--       valor = usar esa categoría, pero sólo si es elegible.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.ajustar_handicap_torneo_jugador_349(
    p_tournament_registration_id uuid,
    p_handicap_torneo numeric,
    p_motivo text,
    p_nueva_categoria_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_reg public.tournament_registrations%ROWTYPE;
    v_admin_id uuid;
    v_handicap_perfil numeric;
    v_categoria_destino uuid;
    v_categoria_estandar categoria_marca_salida;
    v_marca_destino uuid;
    v_campo_id uuid;
    v_categoria_actual_elegible boolean;
    v_categoria_destino_elegible boolean;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_reg
      FROM public.tournament_registrations
     WHERE id = p_tournament_registration_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe esa inscripción.' USING ERRCODE='22023';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(), v_reg.tournament_id)
        OR EXISTS (
            SELECT 1
            FROM public.tournaments t
            WHERE t.id = v_reg.tournament_id
              AND public.is_club_admin(auth.uid(), t.club_id)
        )
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para ajustar el HCP competitivo de este torneo.'
            USING ERRCODE='42501';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = v_reg.tournament_id
    ) THEN
        RAISE EXCEPTION
            'No se puede modificar el HCP competitivo después del Freeze.'
            USING ERRCODE='55000';
    END IF;

    IF NOT v_reg.activo THEN
        RAISE EXCEPTION 'La inscripción no está activa.' USING ERRCODE='22023';
    END IF;

    IF p_handicap_torneo IS NULL OR p_handicap_torneo < -10.0 OR p_handicap_torneo > 54.0 THEN
        RAISE EXCEPTION
            'El HCP torneo debe estar entre -10.0 y 54.0.'
            USING ERRCODE='22023';
    END IF;

    IF NULLIF(btrim(p_motivo), '') IS NULL THEN
        RAISE EXCEPTION
            'Debe indicar el motivo del ajuste de HCP.'
            USING ERRCODE='22023';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo = true
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No se encontró un administrador activo asociado al usuario.'
            USING ERRCODE='42501';
    END IF;

    SELECT COALESCE(p.handicap_verificado, p.handicap_declarado)
      INTO v_handicap_perfil
      FROM public.players p
     WHERE p.id = v_reg.player_id;

    SELECT t.campo_golf_id
      INTO v_campo_id
      FROM public.tournaments t
     WHERE t.id = v_reg.tournament_id;

    -- Primero se coloca el override dentro de ESTA transacción.
    -- Si cualquier validación posterior falla, PostgreSQL revierte todo.
    UPDATE public.tournament_registrations
       SET handicap_torneo = p_handicap_torneo,
           handicap_torneo_motivo = btrim(p_motivo),
           handicap_torneo_ajustado_at = now(),
           handicap_torneo_ajustado_por = v_admin_id
     WHERE id = v_reg.id;

    SELECT EXISTS (
        SELECT 1
        FROM public._categorias_elegibles_jugador(v_reg.tournament_id, v_reg.player_id) e
        WHERE e.tournament_category_id = v_reg.tournament_category_id
    )
    INTO v_categoria_actual_elegible;

    IF p_nueva_categoria_id IS NULL THEN
        IF NOT v_categoria_actual_elegible THEN
            RAISE EXCEPTION
                'El nuevo HCP hace que la categoría actual deje de ser elegible. Seleccione una categoría elegible.'
                USING ERRCODE='22023',
                      HINT='Consulte las categorías elegibles con el nuevo HCP y vuelva a ejecutar indicando p_nueva_categoria_id.';
        END IF;

        -- La categoría sigue siendo válida: no tocamos categoría ni marca.
        v_categoria_destino := v_reg.tournament_category_id;
        v_marca_destino := v_reg.marca_salida_id;
    ELSE
        SELECT EXISTS (
            SELECT 1
            FROM public._categorias_elegibles_jugador(v_reg.tournament_id, v_reg.player_id) e
            WHERE e.tournament_category_id = p_nueva_categoria_id
        )
        INTO v_categoria_destino_elegible;

        IF NOT v_categoria_destino_elegible THEN
            RAISE EXCEPTION
                'La categoría seleccionada no es elegible para el HCP competitivo indicado.'
                USING ERRCODE='22023';
        END IF;

        v_categoria_destino := p_nueva_categoria_id;

        SELECT c.categoria_estandar_marca
          INTO v_categoria_estandar
          FROM public.tournament_categories tc
          JOIN public.categories c ON c.id = tc.category_id
         WHERE tc.id = v_categoria_destino
           AND tc.tournament_id = v_reg.tournament_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'La categoría seleccionada no pertenece al torneo.'
                USING ERRCODE='22023';
        END IF;

        IF v_categoria_estandar IS NULL THEN
            RAISE EXCEPTION
                'La categoría seleccionada no tiene una marca estándar configurada.'
                USING ERRCODE='22023';
        END IF;

        SELECT ms.id
          INTO v_marca_destino
          FROM public.marcas_salida ms
         WHERE ms.campo_golf_id = v_campo_id
           AND ms.categoria_estandar = v_categoria_estandar
           AND ms.activo = true
         ORDER BY ms.id
         LIMIT 1;

        IF v_marca_destino IS NULL THEN
            RAISE EXCEPTION
                'No existe una marca de salida activa correspondiente a la categoría seleccionada en el campo del torneo.'
                USING ERRCODE='22023';
        END IF;

        UPDATE public.tournament_registrations
           SET tournament_category_id = v_categoria_destino,
               marca_salida_id = v_marca_destino,
               categoria_reasignada = false
         WHERE id = v_reg.id;
    END IF;

    INSERT INTO public.tournament_registration_handicap_adjustments (
        tournament_id,
        tournament_registration_id,
        player_id,
        handicap_perfil,
        handicap_torneo_anterior,
        handicap_torneo_nuevo,
        tournament_category_id_anterior,
        tournament_category_id_nueva,
        marca_salida_id_anterior,
        marca_salida_id_nueva,
        motivo,
        adjusted_by
    )
    VALUES (
        v_reg.tournament_id,
        v_reg.id,
        v_reg.player_id,
        v_handicap_perfil,
        v_reg.handicap_torneo,
        p_handicap_torneo,
        v_reg.tournament_category_id,
        v_categoria_destino,
        v_reg.marca_salida_id,
        v_marca_destino,
        btrim(p_motivo),
        v_admin_id
    );

    RETURN jsonb_build_object(
        'ok', true,
        'tournamentRegistrationId', v_reg.id,
        'playerId', v_reg.player_id,
        'handicapPerfil', v_handicap_perfil,
        'handicapTorneo', p_handicap_torneo,
        'categoriaAnteriorId', v_reg.tournament_category_id,
        'categoriaNuevaId', v_categoria_destino,
        'marcaAnteriorId', v_reg.marca_salida_id,
        'marcaNuevaId', v_marca_destino,
        'categoriaConservada', v_categoria_destino IS NOT DISTINCT FROM v_reg.tournament_category_id
    );
END;
$$;

REVOKE ALL ON FUNCTION public.ajustar_handicap_torneo_jugador_349(uuid,numeric,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ajustar_handicap_torneo_jugador_349(uuid,numeric,text,uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 07. FREEZE:
--     NO SE REESCRIBE EL MOTOR. Un BEFORE INSERT sustituye la evidencia base
--     por el HCP torneo cuando existe. Los cálculos posteriores ya consumen
--     tournament_handicap_snapshots.handicap_index.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._aplicar_handicap_torneo_snapshot_349()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_hcp_torneo numeric;
BEGIN
    SELECT tr.handicap_torneo
      INTO v_hcp_torneo
      FROM public.tournament_registrations tr
     WHERE tr.id = NEW.tournament_registration_id
       AND tr.tournament_id = NEW.tournament_id
       AND tr.player_id = NEW.player_id
       AND tr.activo = true;

    IF v_hcp_torneo IS NOT NULL THEN
        NEW.handicap_index := v_hcp_torneo;
        NEW.handicap_source := 'tournament_override';
        NEW.handicap_source_date := CURRENT_DATE;
        NEW.handicap_status := 'tournament_override';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_aplicar_handicap_torneo_snapshot_349
ON public.tournament_handicap_snapshots;

CREATE TRIGGER trg_aplicar_handicap_torneo_snapshot_349
BEFORE INSERT ON public.tournament_handicap_snapshots
FOR EACH ROW
EXECUTE FUNCTION public._aplicar_handicap_torneo_snapshot_349();

-- ---------------------------------------------------------------------------
-- 08. PERMISOS DE LECTURA DE AUDITORÍA POR RPC (sin escritura directa)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_historial_handicap_torneo_349(
    p_tournament_registration_id uuid
)
RETURNS SETOF public.tournament_registration_handicap_adjustments
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tournament_id uuid;
BEGIN
    SELECT tr.tournament_id
      INTO v_tournament_id
      FROM public.tournament_registrations tr
     WHERE tr.id = p_tournament_registration_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'No existe esa inscripción.' USING ERRCODE='22023';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(), v_tournament_id)
        OR EXISTS (
            SELECT 1
            FROM public.tournaments t
            WHERE t.id = v_tournament_id
              AND public.is_club_admin(auth.uid(), t.club_id)
        )
    ) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar este historial.'
            USING ERRCODE='42501';
    END IF;

    RETURN QUERY
    SELECT h.*
    FROM public.tournament_registration_handicap_adjustments h
    WHERE h.tournament_registration_id = p_tournament_registration_id
    ORDER BY h.adjusted_at DESC, h.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_historial_handicap_torneo_349(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_historial_handicap_torneo_349(uuid) TO authenticated;

COMMIT;
