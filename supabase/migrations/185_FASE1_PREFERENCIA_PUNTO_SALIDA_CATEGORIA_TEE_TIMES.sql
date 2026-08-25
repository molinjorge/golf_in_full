-- ============================================================================
-- MIGRACION 185 FASE 1
-- PREFERENCIA DE PUNTO DE SALIDA POR CATEGORIA EN TEE TIMES
-- TEE CENTRAL
--
-- DEFINICION FUNCIONAL
-- El organizador define por cuál punto/hoyo de inicio sale cada categoría.
-- Una categoría puede configurarse para:
--   LANE_1 = punto de salida 1
--   LANE_2 = punto de salida 2
--   BOTH   = cualquiera de los dos puntos disponibles
--
-- La preferencia es el criterio por defecto para construir la propuesta de
-- grupos. NO es una restricción absoluta: el operador puede mover manualmente
-- un grupo concreto al otro punto antes de materializar las salidas.
--
-- Esta fase sólo crea el contrato persistente. La aplicación de esta preferencia
-- en CONFIGURAR TEE TIMES / PREPARAR SALIDAS corresponde a la fase frontend.
--
-- Compatibilidad:
-- Las configuraciones existentes se inicializan como BOTH para conservar el
-- comportamiento previo de distribución flexible y no alterar torneos ya creados.
-- ============================================================================

BEGIN;

ALTER TABLE public.tournament_tee_time_category_configs
    ADD COLUMN IF NOT EXISTS preferred_start_lane text;

UPDATE public.tournament_tee_time_category_configs
SET preferred_start_lane = 'BOTH'
WHERE preferred_start_lane IS NULL;

ALTER TABLE public.tournament_tee_time_category_configs
    ALTER COLUMN preferred_start_lane SET DEFAULT 'BOTH';

ALTER TABLE public.tournament_tee_time_category_configs
    ALTER COLUMN preferred_start_lane SET NOT NULL;

ALTER TABLE public.tournament_tee_time_category_configs
    DROP CONSTRAINT IF EXISTS tournament_tee_time_category_configs_preferred_start_lane_check;

ALTER TABLE public.tournament_tee_time_category_configs
    ADD CONSTRAINT tournament_tee_time_category_configs_preferred_start_lane_check
    CHECK (preferred_start_lane IN ('LANE_1', 'LANE_2', 'BOTH'));

COMMENT ON COLUMN public.tournament_tee_time_category_configs.preferred_start_lane IS
'Preferencia de punto de salida de la categoría en Tee Times. LANE_1=punto de salida 1; LANE_2=punto de salida 2; BOTH=cualquiera. Es una preferencia por defecto y no impide que un grupo concreto sea cambiado manualmente de punto antes de materializar.';

COMMIT;
