-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 378
-- Publicación de torneos para jugadores controlada exclusivamente por Superadmin
-- EJECUCIÓN: MANUAL EN SUPABASE PROD

BEGIN;

ALTER TABLE public.tournaments
  ADD COLUMN IF NOT EXISTS publicado_para_jugadores boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.tournaments.publicado_para_jugadores IS
'Control de publicación para jugadores. TRUE: visible/disponible según reglas normales. FALSE: no debe descubrirse ni admitir nuevas inscripciones desde la app de jugadores. Sólo Superadmin puede cambiarlo.';

CREATE OR REPLACE FUNCTION public.proteger_publicacion_torneo_378()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.publicado_para_jugadores IS DISTINCT FROM OLD.publicado_para_jugadores THEN
    -- service_role se reserva para procesos internos.
    IF COALESCE(auth.role(), '') = 'service_role' THEN
      RETURN NEW;
    END IF;

    IF auth.uid() IS NULL OR NOT public.is_superadmin(auth.uid()) THEN
      RAISE EXCEPTION 'Sólo Superadmin puede cambiar la publicación del torneo.';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_proteger_publicacion_torneo_378 ON public.tournaments;

CREATE TRIGGER trg_proteger_publicacion_torneo_378
BEFORE UPDATE OF publicado_para_jugadores
ON public.tournaments
FOR EACH ROW
EXECUTE FUNCTION public.proteger_publicacion_torneo_378();

CREATE OR REPLACE FUNCTION public.establecer_publicacion_torneo_378(
  p_tournament_id uuid,
  p_publicado boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_nombre text;
  v_anterior boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sesión autenticada requerida.';
  END IF;

  IF COALESCE(auth.role(), '') <> 'service_role'
     AND NOT public.is_superadmin(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Superadmin puede cambiar la publicación del torneo.';
  END IF;

  IF p_tournament_id IS NULL THEN
    RAISE EXCEPTION 'El torneo es obligatorio.';
  END IF;

  IF p_publicado IS NULL THEN
    RAISE EXCEPTION 'El estado de publicación es obligatorio.';
  END IF;

  SELECT t.nombre, t.publicado_para_jugadores
    INTO v_nombre, v_anterior
  FROM public.tournaments t
  WHERE t.id = p_tournament_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Torneo no encontrado.';
  END IF;

  IF v_anterior IS DISTINCT FROM p_publicado THEN
    UPDATE public.tournaments
       SET publicado_para_jugadores = p_publicado
     WHERE id = p_tournament_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'tournamentId', p_tournament_id,
    'tournamentName', v_nombre,
    'previousPublished', v_anterior,
    'published', p_publicado,
    'changed', v_anterior IS DISTINCT FROM p_publicado
  );
END;
$$;

REVOKE ALL ON FUNCTION public.establecer_publicacion_torneo_378(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.establecer_publicacion_torneo_378(uuid, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.establecer_publicacion_torneo_378(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.establecer_publicacion_torneo_378(uuid, boolean) TO service_role;

REVOKE ALL ON FUNCTION public.proteger_publicacion_torneo_378() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.proteger_publicacion_torneo_378() FROM anon;
REVOKE ALL ON FUNCTION public.proteger_publicacion_torneo_378() FROM authenticated;

COMMIT;
