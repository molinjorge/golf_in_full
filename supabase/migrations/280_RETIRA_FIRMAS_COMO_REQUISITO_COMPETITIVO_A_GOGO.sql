-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 280 - CORREGIDA
-- A-Go-Go: firmas NO son requisito competitivo.
--
-- IMPORTANTE:
-- - La primera versión de 280 abortó antes de aplicar cambios.
-- - Esta versión conserva los campos históricos/informativos de firma.
-- - Elimina ÚNICAMENTE su uso como STOP/gating competitivo.
-- - No modifica datos existentes.
-- ============================================================

DO $m280$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
BEGIN
  -- ----------------------------------------------------------
  -- 1. Resultado oficial de una tarjeta A-Go-Go
  -- Conservamos teamSignaturePresent/markerSignaturePresent
  -- en el JSON informativo, pero retiramos el IF que bloquea.
  -- ----------------------------------------------------------
  SELECT p.oid
    INTO v_oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public'
     AND p.proname='obtener_resultado_a_gogo_oficial_tarjeta'
     AND p.oid::regprocedure::text=
         'obtener_resultado_a_gogo_oficial_tarjeta(uuid)';

  IF v_oid IS NULL THEN
    RAISE EXCEPTION
      '280: no existe obtener_resultado_a_gogo_oficial_tarjeta(uuid)';
  END IF;

  v_def:=pg_get_functiondef(v_oid);

  IF position(
       'La tarjeta física A-Go-Go requiere firma del equipo y del marcador contrario.'
       in v_def
     )=0 THEN
    RAISE EXCEPTION
      '280: no se encontró el STOP esperado de firmas en resultado oficial; no se aplicó ningún cambio';
  END IF;

  v_new:=regexp_replace(
    v_def,
    E'\\s*-- Contrato operativo acordado para A-Go-Go:\\s*-- una firma del equipo y una firma de equipo contrario/marcador\\.\\s*IF NOT v_reception\\.player_signature_present\\s*OR NOT v_reception\\.marker_signature_present\\s*THEN\\s*RAISE EXCEPTION\\s*''La tarjeta física A-Go-Go requiere firma del equipo y del marcador contrario\\.''\\s*USING ERRCODE=''55000'',\\s*DETAIL=format\\(\\s*''team_signature=%s; marker_signature=%s'',\\s*v_reception\\.player_signature_present,\\s*v_reception\\.marker_signature_present\\s*\\);\\s*END IF;',
    E'\n    -- 280: las firmas se conservan como información histórica,\n    -- pero NO son requisito competitivo ni pueden bloquear resultados.\n',
    'ns'
  );

  IF v_new=v_def
     OR position(
          'La tarjeta física A-Go-Go requiere firma del equipo y del marcador contrario.'
          in v_new
        )>0 THEN
    RAISE EXCEPTION
      '280: no fue posible retirar de forma segura el STOP de firmas en resultado oficial';
  END IF;

  -- Deben permanecer como campos informativos.
  IF position('teamSignaturePresent' in v_new)=0
     OR position('markerSignaturePresent' in v_new)=0 THEN
    RAISE EXCEPTION
      '280: la corrección intentó retirar campos históricos informativos; operación cancelada';
  END IF;

  EXECUTE v_new;

  -- ----------------------------------------------------------
  -- 2. Resultados oficiales de ronda
  -- Aquí sí retiramos firmas del cálculo candidate_ready y
  -- SIGNATURES_MISSING. No es necesario que aparezcan en salida.
  -- ----------------------------------------------------------
  SELECT p.oid
    INTO v_oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public'
     AND p.proname='obtener_resultados_a_gogo_oficiales_ronda'
     AND p.oid::regprocedure::text=
         'obtener_resultados_a_gogo_oficiales_ronda(uuid)';

  IF v_oid IS NULL THEN
    RAISE EXCEPTION
      '280: no existe obtener_resultados_a_gogo_oficiales_ronda(uuid)';
  END IF;

  v_def:=pg_get_functiondef(v_oid);
  v_new:=v_def;

  -- Retirar firmas del candidate_ready.
  v_new:=regexp_replace(
    v_new,
    E'\\s*AND COALESCE\\(c\\.player_signature_present,false\\)',
    '',
    'g'
  );
  v_new:=regexp_replace(
    v_new,
    E'\\s*AND COALESCE\\(c\\.marker_signature_present,false\\)',
    '',
    'g'
  );
  v_new:=regexp_replace(
    v_new,
    E'\\s*AND c\\.player_signature_present',
    '',
    'g'
  );
  v_new:=regexp_replace(
    v_new,
    E'\\s*AND c\\.marker_signature_present',
    '',
    'g'
  );

  -- Retirar el estado SIGNATURES_MISSING completo.
  v_new:=regexp_replace(
    v_new,
    E'\\s*WHEN NOT COALESCE\\(p\\.player_signature_present,false\\).*?THEN ''SIGNATURES_MISSING''',
    '',
    'ns'
  );

  IF v_new=v_def
     OR position('SIGNATURES_MISSING' in v_new)>0 THEN
    RAISE EXCEPTION
      '280: no fue posible retirar de forma segura el gating de firmas en resultados de ronda';
  END IF;

  EXECUTE v_new;

  -- ----------------------------------------------------------
  -- 3. Leaderboard base A-Go-Go
  -- Retirar firmas de official_candidate y SIGNATURES_MISSING.
  -- ----------------------------------------------------------
  SELECT p.oid
    INTO v_oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public'
     AND p.proname='_obtener_leaderboard_a_gogo_ronda_pre212'
     AND p.oid::regprocedure::text=
         '_obtener_leaderboard_a_gogo_ronda_pre212(uuid)';

  IF v_oid IS NULL THEN
    RAISE EXCEPTION
      '280: no existe _obtener_leaderboard_a_gogo_ronda_pre212(uuid)';
  END IF;

  v_def:=pg_get_functiondef(v_oid);
  v_new:=v_def;

  v_new:=regexp_replace(
    v_new,
    E'\\s*AND COALESCE\\(c\\.player_signature_present,false\\)',
    '',
    'g'
  );
  v_new:=regexp_replace(
    v_new,
    E'\\s*AND COALESCE\\(c\\.marker_signature_present,false\\)',
    '',
    'g'
  );
  v_new:=regexp_replace(
    v_new,
    E'\\s*AND c\\.player_signature_present',
    '',
    'g'
  );
  v_new:=regexp_replace(
    v_new,
    E'\\s*AND c\\.marker_signature_present',
    '',
    'g'
  );

  v_new:=regexp_replace(
    v_new,
    E'\\s*WHEN NOT COALESCE\\(o\\.player_signature_present,false\\).*?THEN ''SIGNATURES_MISSING''',
    '',
    'ns'
  );

  IF v_new=v_def
     OR position('SIGNATURES_MISSING' in v_new)>0 THEN
    RAISE EXCEPTION
      '280: no fue posible retirar de forma segura el gating de firmas en leaderboard A-Go-Go';
  END IF;

  EXECUTE v_new;
END
$m280$;

COMMENT ON FUNCTION public.obtener_resultado_a_gogo_oficial_tarjeta(uuid)
IS '280: resultado oficial A-Go-Go; firmas conservadas como información histórica pero nunca como requisito competitivo.';

COMMENT ON FUNCTION public.obtener_resultados_a_gogo_oficiales_ronda(uuid)
IS '280: resultados oficiales A-Go-Go sin firmas como STOP competitivo.';

COMMENT ON FUNCTION public._obtener_leaderboard_a_gogo_ronda_pre212(uuid)
IS '280: leaderboard base A-Go-Go sin firmas como STOP competitivo.';

REVOKE ALL ON FUNCTION public.obtener_resultado_a_gogo_oficial_tarjeta(uuid)
FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.obtener_resultados_a_gogo_oficiales_ronda(uuid)
FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._obtener_leaderboard_a_gogo_ronda_pre212(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.obtener_resultado_a_gogo_oficial_tarjeta(uuid)
TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.obtener_resultados_a_gogo_oficiales_ronda(uuid)
TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public._obtener_leaderboard_a_gogo_ronda_pre212(uuid)
TO authenticated, service_role;
