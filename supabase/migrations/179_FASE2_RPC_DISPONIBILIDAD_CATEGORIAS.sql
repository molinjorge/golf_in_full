-- ============================================================================
-- 179_FASE2_RPC_DISPONIBILIDAD_CATEGORIAS.sql
-- TEE CENTRAL
--
-- OBJETIVO
-- Agregar una RPC de solo lectura para consultar disponibilidad por categoría
-- sin recalcular la lógica en frontend.
--
-- DEVUELVE:
-- - cupo máximo
-- - inscripciones activas
-- - pre-reservas activas no convertidas
-- - reservas telefónicas activas
-- - ocupados
-- - disponibles
-- - llena
--
-- NO MODIFICA:
-- - triggers
-- - reglas de bloqueo
-- - datos históricos
-- - configuración de torneos
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_cupos_categorias_torneo(
    p_tournament_id uuid
)
RETURNS TABLE (
    tournament_category_id uuid,
    category_id uuid,
    codigo text,
    nombre text,
    cupo_maximo integer,
    inscripciones_activas bigint,
    prereservas_activas bigint,
    reservas_telefonicas_activas bigint,
    ocupados bigint,
    disponibles bigint,
    llena boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
WITH ocupacion AS (
    SELECT
        tc.id AS tournament_category_id,
        tc.category_id,
        c.codigo,
        c.nombre,
        tc.cupo_maximo,

        (
            SELECT count(*)
            FROM public.tournament_registrations tr
            WHERE tr.tournament_category_id = tc.id
              AND tr.activo = true
        ) AS inscripciones_activas,

        (
            SELECT count(*)
            FROM public.tournament_pre_reservations pr
            WHERE pr.tournament_category_id = tc.id
              AND pr.activo = true
              AND pr.tournament_registration_id IS NULL
        ) AS prereservas_activas,

        (
            SELECT count(*)
            FROM public.phone_reservations ph
            WHERE ph.tournament_category_id = tc.id
              AND ph.activo = true
        ) AS reservas_telefonicas_activas

    FROM public.tournament_categories tc
    JOIN public.categories c
      ON c.id = tc.category_id
    WHERE tc.tournament_id = p_tournament_id
)
SELECT
    o.tournament_category_id,
    o.category_id,
    o.codigo,
    o.nombre,
    o.cupo_maximo,
    o.inscripciones_activas,
    o.prereservas_activas,
    o.reservas_telefonicas_activas,

    (
        o.inscripciones_activas
        + o.prereservas_activas
        + o.reservas_telefonicas_activas
    ) AS ocupados,

    CASE
        WHEN o.cupo_maximo IS NULL THEN NULL
        ELSE GREATEST(
            o.cupo_maximo::bigint
            - (
                o.inscripciones_activas
                + o.prereservas_activas
                + o.reservas_telefonicas_activas
              ),
            0
        )
    END AS disponibles,

    CASE
        WHEN o.cupo_maximo IS NULL THEN false
        ELSE (
            o.inscripciones_activas
            + o.prereservas_activas
            + o.reservas_telefonicas_activas
        ) >= o.cupo_maximo
    END AS llena

FROM ocupacion o
ORDER BY
    o.codigo NULLS LAST,
    o.nombre;
$function$;

REVOKE ALL
ON FUNCTION public.obtener_cupos_categorias_torneo(uuid)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.obtener_cupos_categorias_torneo(uuid)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.obtener_cupos_categorias_torneo(uuid)
TO authenticated, service_role;

COMMIT;
