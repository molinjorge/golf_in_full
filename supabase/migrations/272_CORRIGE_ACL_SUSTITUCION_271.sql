-- ============================================================
-- MIGRACIÓN 272
-- Corrige ACL de funciones de sustitución administrativa 271
-- ============================================================
-- Objetivo:
--   Eliminar EXECUTE explícito del rol anon sobre las funciones
--   introducidas por la Migración 271.
--
-- No modifica lógica de sustitución ni datos competitivos.
-- ============================================================

BEGIN;

REVOKE EXECUTE ON FUNCTION
    public.sustituir_jugador_a_gogo_271(
        uuid,text,text,uuid,text,text,public.sexo_jugador,
        date,numeric,text,text,text
    )
FROM anon;

REVOKE EXECUTE ON FUNCTION
    public.obtener_candidato_sustitucion_a_gogo_271(uuid,text)
FROM anon;

REVOKE EXECUTE ON FUNCTION
    public._a_gogo_substitution_tee_override_271()
FROM anon;

-- Defensa adicional: PUBLIC tampoco debe heredar EXECUTE.
REVOKE EXECUTE ON FUNCTION
    public.sustituir_jugador_a_gogo_271(
        uuid,text,text,uuid,text,text,public.sexo_jugador,
        date,numeric,text,text,text
    )
FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION
    public.obtener_candidato_sustitucion_a_gogo_271(uuid,text)
FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION
    public._a_gogo_substitution_tee_override_271()
FROM PUBLIC;

-- Mantener únicamente los consumidores previstos.
GRANT EXECUTE ON FUNCTION
    public.sustituir_jugador_a_gogo_271(
        uuid,text,text,uuid,text,text,public.sexo_jugador,
        date,numeric,text,text,text
    )
TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION
    public.obtener_candidato_sustitucion_a_gogo_271(uuid,text)
TO authenticated, service_role;

COMMIT;
