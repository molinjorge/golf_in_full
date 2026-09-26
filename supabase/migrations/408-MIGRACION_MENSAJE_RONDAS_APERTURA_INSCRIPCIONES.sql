-- 408-MIGRACION_MENSAJE_RONDAS_APERTURA_INSCRIPCIONES.sql
-- TEE CENTRAL
--
-- OBJETIVO
-- Mejorar exclusivamente el mensaje al intentar abrir inscripciones cuando
-- faltan rondas o turnos por configurar.
--
-- NO modifica bloqueos, autorizaciones, reglas deportivas ni criterios de apertura.

BEGIN;

DO $do$
DECLARE
    v_def text;
    v_old text :=
      'RAISE EXCEPTION ''No se pueden abrir inscripciones: primero deben existir y estar activas todas las rondas declaradas. %'',' ||
      E'\r\n            jsonb_build_object(''declaredRounds'',v_ready->''declaredRounds'',''activeRounds'',v_ready->''activeRounds'',''missingRounds'',v_ready->''missingRounds'')::text' ||
      E'\r\n            USING ERRCODE=''23514'';';
    v_new text :=
      'RAISE EXCEPTION ''No se pueden abrir las inscripciones todavía. Debes configurar todas las rondas y sus turnos antes de abrir las inscripciones.''' ||
      E'\r\n            USING ERRCODE=''23514'';';
BEGIN
    SELECT pg_get_functiondef(p.oid)
      INTO v_def
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public'
       AND p.proname='abrir_inscripciones_torneo';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No existe abrir_inscripciones_torneo.';
    END IF;

    IF position(v_old in v_def)=0 THEN
        RAISE EXCEPTION 'No se encontró el bloque de mensaje esperado. No se aplicó ningún cambio.';
    END IF;

    v_def:=replace(v_def,v_old,v_new);
    EXECUTE v_def;
END
$do$;

COMMIT;
