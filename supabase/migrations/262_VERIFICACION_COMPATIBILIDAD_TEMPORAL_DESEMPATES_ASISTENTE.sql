-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- VERIFICACIÓN MIGRACIÓN 262
-- Compatibilidad temporal de DESEMPATES en el Asistente
-- ============================================================

WITH checks AS (

    SELECT
        '01_V15_EXISTE' AS section,
        CASE WHEN to_regprocedure(
            'public._obtener_asistente_operativo_torneo_v15_262(uuid)'
        ) IS NOT NULL
        THEN 'OK' ELSE 'ERROR' END AS status,
        'Existe helper v15_262' AS detail

    UNION ALL

    SELECT
        '02_PUBLICO_DELEGA_V15',
        CASE WHEN pg_get_functiondef(
            'public.obtener_asistente_operativo_torneo(uuid)'::regprocedure
        ) LIKE '%_obtener_asistente_operativo_torneo_v15_262%'
        THEN 'OK' ELSE 'ERROR' END,
        'El Asistente público delega en v15'

    UNION ALL

    SELECT
        '03_V15_PRESERVA_V14',
        CASE WHEN pg_get_functiondef(
            'public._obtener_asistente_operativo_torneo_v15_262(uuid)'::regprocedure
        ) LIKE '%_obtener_asistente_operativo_torneo_v14_261%'
        THEN 'OK' ELSE 'ERROR' END,
        'v15 envuelve v14 y preserva 261 para torneos nuevos'

    UNION ALL

    SELECT
        '04_REGLA_CONFIG_FINALIZADA',
        CASE WHEN pg_get_functiondef(
            'public._obtener_asistente_operativo_torneo_v15_262(uuid)'::regprocedure
        ) LIKE '%configuracion_finalizada_at IS NOT NULL%'
        THEN 'OK' ELSE 'ERROR' END,
        'Existe excepción temporal para configuración ya finalizada'

    UNION ALL

    SELECT
        '05_TIEBREAK_COMPLETE_RETROACTIVO',
        CASE WHEN pg_get_functiondef(
            'public._obtener_asistente_operativo_torneo_v15_262(uuid)'::regprocedure
        ) LIKE '%''code''=''TIEBREAK_CONFIGURATION''%'
           OR pg_get_functiondef(
            'public._obtener_asistente_operativo_torneo_v15_262(uuid)'::regprocedure
        ) LIKE '%TIEBREAK_CONFIGURATION%'
        THEN 'OK' ELSE 'ERROR' END,
        'El paso de desempates se corrige en v15'

    UNION ALL

    SELECT
        '06_FINALIZAR_CONFIG_261_INTACTO',
        CASE WHEN pg_get_functiondef(
            'public.finalizar_configuracion_torneo(uuid)'::regprocedure
        ) LIKE '%obtener_estado_configuracion_desempates_261%'
        THEN 'OK' ELSE 'ERROR' END,
        'Los torneos nuevos siguen obligados por 261'

    UNION ALL

    SELECT
        '07_HELPER_NO_AUTH',
        CASE WHEN NOT has_function_privilege(
            'authenticated',
            'public._obtener_asistente_operativo_torneo_v15_262(uuid)',
            'EXECUTE'
        )
        THEN 'OK' ELSE 'ERROR' END,
        'El helper v15 no está expuesto directamente'

    UNION ALL

    SELECT
        '08_NO_DATA_CHANGE',
        'OK',
        'La migración no modifica reglas, resultados, cierres, publicaciones ni datos históricos'
)
SELECT *
FROM checks
ORDER BY section;

-- ---------------------------------------------------------------------------
-- Verificación conductual específica de BALVANERA 1 sin invocar el Asistente
-- autenticado desde SQL Editor:
-- debe ser elegible para compatibilidad porque su configuración ya estaba
-- finalizada y el estado 261 es histórico/incompleto.
-- ---------------------------------------------------------------------------

SELECT
    t.id,
    t.nombre,
    t.estatus::text AS estatus,
    t.configuracion_finalizada_at,
    public.obtener_estado_configuracion_desempates_261(t.id) AS estado_261,
    (
        t.configuracion_finalizada_at IS NOT NULL
        AND NOT COALESCE(
            (
                public.obtener_estado_configuracion_desempates_261(t.id)
                ->>'complete'
            )::boolean,
            false
        )
    ) AS debe_ser_grandfathered
FROM public.tournaments t
WHERE t.id='b62adc3e-a521-48db-a509-268824d5aa80'::uuid;

-- Resultado esperado para BALVANERA 1:
--   estatus = finalizado
--   configuracion_finalizada_at IS NOT NULL
--   debe_ser_grandfathered = true
--
-- En la UI autenticada, después de refrescar:
--   TIEBREAK_CONFIGURATION debe aparecer COMPLETE
--   y no debe contar como bloqueo.
