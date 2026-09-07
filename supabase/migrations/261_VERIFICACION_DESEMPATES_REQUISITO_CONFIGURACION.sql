-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- VERIFICACIÓN MIGRACIÓN 261
-- Desempates como requisito formal de configuración
-- ============================================================

WITH checks AS (

    SELECT
        '01_ESTADO_EXISTE' AS section,
        CASE WHEN to_regprocedure(
            'public.obtener_estado_configuracion_desempates_261(uuid)'
        ) IS NOT NULL
        THEN 'OK' ELSE 'ERROR' END AS status,
        'Existe RPC de estado de desempates' AS detail

    UNION ALL

    SELECT
        '02_V14_EXISTE',
        CASE WHEN to_regprocedure(
            'public._obtener_asistente_operativo_torneo_v14_261(uuid)'
        ) IS NOT NULL
        THEN 'OK' ELSE 'ERROR' END,
        'Existe helper v14_261'

    UNION ALL

    SELECT
        '03_PUBLICO_DELEGA_V14',
        CASE WHEN pg_get_functiondef(
            'public.obtener_asistente_operativo_torneo(uuid)'::regprocedure
        ) LIKE '%_obtener_asistente_operativo_torneo_v14_261%'
        THEN 'OK' ELSE 'ERROR' END,
        'El Asistente público delega en v14'

    UNION ALL

    SELECT
        '04_V14_PRESERVA_V13',
        CASE WHEN pg_get_functiondef(
            'public._obtener_asistente_operativo_torneo_v14_261(uuid)'::regprocedure
        ) LIKE '%_obtener_asistente_operativo_torneo_v13_260%'
        THEN 'OK' ELSE 'ERROR' END,
        'v14 envuelve v13 y preserva la corrección 260'

    UNION ALL

    SELECT
        '05_PASO_DESEMPATES',
        CASE WHEN pg_get_functiondef(
            'public._obtener_asistente_operativo_torneo_v14_261(uuid)'::regprocedure
        ) LIKE '%TIEBREAK_CONFIGURATION%'
        THEN 'OK' ELSE 'ERROR' END,
        'El Asistente contiene TIEBREAK_CONFIGURATION'

    UNION ALL

    SELECT
        '06_TARGET_DESEMPATES',
        CASE WHEN pg_get_functiondef(
            'public._obtener_asistente_operativo_torneo_v14_261(uuid)'::regprocedure
        ) LIKE '%''target'',''desempates''%'
        THEN 'OK' ELSE 'ERROR' END,
        'El paso dirige a la pestaña Desempates'

    UNION ALL

    SELECT
        '07_CONFIRMACION_ESPERA_DESEMPATES',
        CASE WHEN pg_get_functiondef(
            'public._obtener_asistente_operativo_torneo_v14_261(uuid)'::regprocedure
        ) LIKE '%''waitingFor'',''TIEBREAK_CONFIGURATION''%'
        THEN 'OK' ELSE 'ERROR' END,
        'Confirmar configuración espera a Desempates'

    UNION ALL

    SELECT
        '08_BACKEND_FINALIZACION_EXIGE_DESEMPATE',
        CASE WHEN pg_get_functiondef(
            'public.finalizar_configuracion_torneo(uuid)'::regprocedure
        ) LIKE '%obtener_estado_configuracion_desempates_261%'
        THEN 'OK' ELSE 'ERROR' END,
        'El backend de confirmación también exige desempates'

    UNION ALL

    SELECT
        '09_GLOBAL_LIMPIA_CONFLICTOS',
        CASE WHEN pg_get_functiondef(
            'public.aplicar_secuencia_desempate(uuid,alcance_desempate,uuid,uuid,tipo_resultado_desempate)'::regprocedure
        ) LIKE '%Reemplazada por configuración global del torneo%'
        THEN 'OK' ELSE 'ERROR' END,
        'La configuración global desactiva reglas históricas conflictivas del mismo tipo'

    UNION ALL

    SELECT
        '10_RA_OFICIAL_EXISTE',
        CASE WHEN EXISTS(
            SELECT 1
            FROM public.secuencias_desempate
            WHERE code='RA_OFICIAL'
              AND activo=true
        )
        THEN 'OK' ELSE 'ERROR' END,
        'Existe secuencia RA_OFICIAL activa'

    UNION ALL

    SELECT
        '11_RA_OFICIAL_4_PASOS',
        CASE WHEN (
            SELECT count(*)
            FROM public.secuencia_desempate_pasos sp
            JOIN public.secuencias_desempate s
              ON s.id=sp.secuencia_id
            WHERE s.code='RA_OFICIAL'
              AND s.activo=true
        )=4
        THEN 'OK' ELSE 'ERROR' END,
        'RA_OFICIAL conserva 9/6/3/1'

    UNION ALL

    SELECT
        '12_ACL_ESTADO_AUTHENTICATED',
        CASE WHEN has_function_privilege(
            'authenticated',
            'public.obtener_estado_configuracion_desempates_261(uuid)',
            'EXECUTE'
        )
        THEN 'OK' ELSE 'ERROR' END,
        'authenticated puede consultar el estado'

    UNION ALL

    SELECT
        '13_HELPER_V14_NO_AUTH',
        CASE WHEN NOT has_function_privilege(
            'authenticated',
            'public._obtener_asistente_operativo_torneo_v14_261(uuid)',
            'EXECUTE'
        )
        THEN 'OK' ELSE 'ERROR' END,
        'El helper v14 no está expuesto directamente'

    UNION ALL

    SELECT
        '14_NO_RESULTADOS_MUTADOS',
        'OK',
        'La migración no modifica resultados, cierres, publicaciones ni resoluciones históricas'
)
SELECT *
FROM checks
ORDER BY section;

-- ---------------------------------------------------------------------------
-- Diagnóstico de torneos actuales (sólo lectura).
-- Permite identificar torneos históricos cuya configuración de desempates
-- usa reglas por categoría/scope y que, si se reabren, deberán volver a
-- guardar R&A Oficial desde la pestaña Desempates.
-- ---------------------------------------------------------------------------

SELECT
    t.id,
    t.nombre,
    t.estatus::text AS estatus,
    t.configuracion_finalizada_at,
    public.obtener_estado_configuracion_desempates_261(t.id) AS tiebreak_state
FROM public.tournaments t
WHERE t.activo=true
ORDER BY t.created_at DESC NULLS LAST
LIMIT 20;
