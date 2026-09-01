-- ============================================================================
-- MIGRACIÓN 204 FASE 3B
-- A-Go-Go — vigencia/obsolescencia automática del HCP competitivo de equipo
-- Proyecto: Tee Central / GOLF IN FULL
--
-- OBJETIVO
-- - Detectar automáticamente cuándo la versión activa del HCP de equipo ya no
--   representa la composición o Handicap Index actuales.
-- - NO bloquear cambios operativos.
-- - Exponer estado MISSING / STALE / CURRENT para UI y siguientes motores.
-- - Permitir recalcular todos los equipos pendientes/obsoletos de una ronda.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Marcas de vigencia sobre la versión activa
-- ----------------------------------------------------------------------------

ALTER TABLE public.tournament_round_team_handicap_versions
    ADD COLUMN IF NOT EXISTS is_stale boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS stale_reason text NULL,
    ADD COLUMN IF NOT EXISTS stale_at timestamptz NULL;

CREATE INDEX IF NOT EXISTS idx_round_team_hcp_stale
    ON public.tournament_round_team_handicap_versions(
        tournament_round_id,
        tournament_team_id,
        is_stale
    )
    WHERE status='active';

COMMENT ON COLUMN public.tournament_round_team_handicap_versions.is_stale IS
'Indica que la versión activa ya no representa la composición/HCP/configuración vigente y debe recalcularse antes de usarse competitivamente.';

-- ----------------------------------------------------------------------------
-- 2. Helper central para invalidar versiones activas de un equipo
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._marcar_handicap_equipo_obsoleto_204(
    p_tournament_id uuid,
    p_tournament_team_id uuid,
    p_reason text,
    p_tournament_round_id uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_count integer;
BEGIN
    IF p_tournament_id IS NULL OR p_tournament_team_id IS NULL THEN
        RETURN 0;
    END IF;

    UPDATE public.tournament_round_team_handicap_versions v
       SET is_stale=true,
           stale_reason=COALESCE(NULLIF(btrim(p_reason),''),'SOURCE_CHANGED'),
           stale_at=COALESCE(v.stale_at,now())
     WHERE v.tournament_id=p_tournament_id
       AND v.tournament_team_id=p_tournament_team_id
       AND v.status='active'
       AND (
            p_tournament_round_id IS NULL
            OR v.tournament_round_id=p_tournament_round_id
       )
       AND NOT v.is_stale;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public._marcar_handicap_equipo_obsoleto_204(
    uuid,uuid,text,uuid
) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public._marcar_handicap_equipo_obsoleto_204(
    uuid,uuid,text,uuid
) TO service_role;

-- ----------------------------------------------------------------------------
-- 3. Trigger de composición:
--    INSERT/DELETE/UPDATE de inscripción activa, equipo o player.
--    Invalida equipo anterior y/o nuevo.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._invalidar_hcp_equipo_por_registro_204()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_old_relevant boolean := false;
    v_new_relevant boolean := false;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old_relevant :=
            COALESCE(OLD.activo,false)
            AND OLD.tournament_team_id IS NOT NULL;
    END IF;

    IF TG_OP <> 'DELETE' THEN
        v_new_relevant :=
            COALESCE(NEW.activo,false)
            AND NEW.tournament_team_id IS NOT NULL;
    END IF;

    IF TG_OP='INSERT' THEN
        IF v_new_relevant THEN
            PERFORM public._marcar_handicap_equipo_obsoleto_204(
                NEW.tournament_id,
                NEW.tournament_team_id,
                'TEAM_COMPOSITION_CHANGED',
                NULL
            );
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP='DELETE' THEN
        IF v_old_relevant THEN
            PERFORM public._marcar_handicap_equipo_obsoleto_204(
                OLD.tournament_id,
                OLD.tournament_team_id,
                'TEAM_COMPOSITION_CHANGED',
                NULL
            );
        END IF;
        RETURN OLD;
    END IF;

    IF OLD.player_id IS DISTINCT FROM NEW.player_id
       OR OLD.tournament_team_id IS DISTINCT FROM NEW.tournament_team_id
       OR OLD.activo IS DISTINCT FROM NEW.activo
    THEN
        IF v_old_relevant THEN
            PERFORM public._marcar_handicap_equipo_obsoleto_204(
                OLD.tournament_id,
                OLD.tournament_team_id,
                'TEAM_COMPOSITION_CHANGED',
                NULL
            );
        END IF;

        IF v_new_relevant THEN
            PERFORM public._marcar_handicap_equipo_obsoleto_204(
                NEW.tournament_id,
                NEW.tournament_team_id,
                'TEAM_COMPOSITION_CHANGED',
                NULL
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_invalidar_hcp_equipo_por_registro_204
ON public.tournament_registrations;

CREATE TRIGGER trg_invalidar_hcp_equipo_por_registro_204
AFTER INSERT OR DELETE OR UPDATE OF
    player_id,
    tournament_team_id,
    activo
ON public.tournament_registrations
FOR EACH ROW
EXECUTE FUNCTION public._invalidar_hcp_equipo_por_registro_204();

-- ----------------------------------------------------------------------------
-- 4. Trigger de Handicap Index del jugador:
--    si cambia declarado/verificado/estatus/fechas, invalida los equipos activos
--    donde ese jugador está inscrito.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._invalidar_hcp_equipo_por_player_204()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    r record;
BEGIN
    IF OLD.handicap_declarado IS NOT DISTINCT FROM NEW.handicap_declarado
       AND OLD.handicap_declarado_fecha IS NOT DISTINCT FROM NEW.handicap_declarado_fecha
       AND OLD.handicap_verificado IS NOT DISTINCT FROM NEW.handicap_verificado
       AND OLD.handicap_verificado_fecha IS NOT DISTINCT FROM NEW.handicap_verificado_fecha
       AND OLD.handicap_estatus IS NOT DISTINCT FROM NEW.handicap_estatus
    THEN
        RETURN NEW;
    END IF;

    FOR r IN
        SELECT DISTINCT
               tr.tournament_id,
               tr.tournament_team_id
        FROM public.tournament_registrations tr
        JOIN public.tournaments t
          ON t.id=tr.tournament_id
        JOIN public.tournament_formats tf
          ON tf.id=t.tournament_format_id
        WHERE tr.player_id=NEW.id
          AND tr.activo=true
          AND tr.tournament_team_id IS NOT NULL
          AND tf.tipo_participacion::text='equipo'
          AND tf.scoring_engine::text='team_stroke'
    LOOP
        PERFORM public._marcar_handicap_equipo_obsoleto_204(
            r.tournament_id,
            r.tournament_team_id,
            'PLAYER_HANDICAP_CHANGED',
            NULL
        );
    END LOOP;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_invalidar_hcp_equipo_por_player_204
ON public.players;

CREATE TRIGGER trg_invalidar_hcp_equipo_por_player_204
AFTER UPDATE OF
    handicap_declarado,
    handicap_declarado_fecha,
    handicap_verificado,
    handicap_verificado_fecha,
    handicap_estatus
ON public.players
FOR EACH ROW
EXECUTE FUNCTION public._invalidar_hcp_equipo_por_player_204();

-- ----------------------------------------------------------------------------
-- 5. Trigger de tee por ronda de un integrante:
--    importa especialmente para WHS_SCRAMBLE porque el Course Handicap cambia.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._invalidar_hcp_equipo_por_tee_ronda_204()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_registration_id uuid;
    v_round_id uuid;
    v_tournament_id uuid;
    v_team_id uuid;
BEGIN
    IF TG_OP='DELETE' THEN
        v_registration_id:=OLD.tournament_registration_id;
        v_round_id:=OLD.tournament_round_id;
        v_tournament_id:=OLD.tournament_id;
    ELSE
        v_registration_id:=NEW.tournament_registration_id;
        v_round_id:=NEW.tournament_round_id;
        v_tournament_id:=NEW.tournament_id;
    END IF;

    SELECT tr.tournament_team_id
      INTO v_team_id
      FROM public.tournament_registrations tr
     WHERE tr.id=v_registration_id
       AND tr.activo=true;

    IF v_team_id IS NOT NULL THEN
        PERFORM public._marcar_handicap_equipo_obsoleto_204(
            v_tournament_id,
            v_team_id,
            'ROUND_TEE_CHANGED',
            v_round_id
        );
    END IF;

    IF TG_OP='DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_invalidar_hcp_equipo_por_tee_ronda_204
ON public.tournament_round_registration_tees;

CREATE TRIGGER trg_invalidar_hcp_equipo_por_tee_ronda_204
AFTER INSERT OR DELETE OR UPDATE OF tee_id
ON public.tournament_round_registration_tees
FOR EACH ROW
EXECUTE FUNCTION public._invalidar_hcp_equipo_por_tee_ronda_204();

-- ----------------------------------------------------------------------------
-- 6. Cambio de configuración de HCP de equipo:
--    invalida todas las versiones activas del torneo.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._invalidar_hcp_equipo_por_config_204()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
BEGIN
    IF TG_OP='UPDATE'
       AND OLD.method IS NOT DISTINCT FROM NEW.method
       AND OLD.average_pct IS NOT DISTINCT FROM NEW.average_pct
       AND OLD.active IS NOT DISTINCT FROM NEW.active
    THEN
        RETURN NEW;
    END IF;

    UPDATE public.tournament_round_team_handicap_versions v
       SET is_stale=true,
           stale_reason='TEAM_HCP_CONFIG_CHANGED',
           stale_at=COALESCE(v.stale_at,now())
     WHERE v.tournament_id=
           CASE WHEN TG_OP='DELETE'
                THEN OLD.tournament_id
                ELSE NEW.tournament_id END
       AND v.status='active'
       AND NOT v.is_stale;

    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_invalidar_hcp_equipo_por_config_204
ON public.tournament_team_handicap_configs;

CREATE TRIGGER trg_invalidar_hcp_equipo_por_config_204
AFTER INSERT OR DELETE OR UPDATE OF
    method,
    average_pct,
    active
ON public.tournament_team_handicap_configs
FOR EACH ROW
EXECUTE FUNCTION public._invalidar_hcp_equipo_por_config_204();

-- Los rangos también son parte de la fórmula.
CREATE OR REPLACE FUNCTION public._invalidar_hcp_equipo_por_rango_204()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_config_id uuid;
    v_tournament_id uuid;
BEGIN
    v_config_id :=
        CASE WHEN TG_OP='DELETE' THEN OLD.config_id ELSE NEW.config_id END;

    SELECT c.tournament_id
      INTO v_tournament_id
      FROM public.tournament_team_handicap_configs c
     WHERE c.id=v_config_id;

    IF v_tournament_id IS NOT NULL THEN
        UPDATE public.tournament_round_team_handicap_versions v
           SET is_stale=true,
               stale_reason='TEAM_HCP_RANGE_CHANGED',
               stale_at=COALESCE(v.stale_at,now())
         WHERE v.tournament_id=v_tournament_id
           AND v.status='active'
           AND NOT v.is_stale;
    END IF;

    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_invalidar_hcp_equipo_por_rango_204
ON public.tournament_team_handicap_ranges;

CREATE TRIGGER trg_invalidar_hcp_equipo_por_rango_204
AFTER INSERT OR DELETE OR UPDATE
ON public.tournament_team_handicap_ranges
FOR EACH ROW
EXECUTE FUNCTION public._invalidar_hcp_equipo_por_rango_204();

-- ----------------------------------------------------------------------------
-- 7. Ajustar recalcular_handicap_equipo_a_gogo:
--    la nueva versión nace vigente.
--    Se conserva el motor 203; solo se reemplaza el INSERT de versión mediante
--    wrapper posterior. Como CREATE OR REPLACE completo sería frágil, usamos
--    trigger BEFORE INSERT para garantizar vigencia limpia.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._normalizar_vigencia_hcp_equipo_204()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status='active' THEN
        NEW.is_stale:=false;
        NEW.stale_reason:=NULL;
        NEW.stale_at:=NULL;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_normalizar_vigencia_hcp_equipo_204
ON public.tournament_round_team_handicap_versions;

CREATE TRIGGER trg_normalizar_vigencia_hcp_equipo_204
BEFORE INSERT
ON public.tournament_round_team_handicap_versions
FOR EACH ROW
EXECUTE FUNCTION public._normalizar_vigencia_hcp_equipo_204();

-- ----------------------------------------------------------------------------
-- 8. Estado consumible por UI / fases siguientes
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_estado_handicap_equipo_a_gogo(
    p_tournament_round_id uuid,
    p_tournament_team_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_round record;
    v_team record;
    v_config public.tournament_team_handicap_configs%ROWTYPE;
    v_version public.tournament_round_team_handicap_versions%ROWTYPE;
    v_current_count integer;
BEGIN
    SELECT tr.tournament_id,tr.numero_ronda
      INTO v_round
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id
       AND tr.activo=true;

    IF v_round.tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda no existe o está inactiva.';
    END IF;

    SELECT tt.id,tt.nombre_equipo
      INTO v_team
      FROM public.tournament_teams tt
     WHERE tt.id=p_tournament_team_id
       AND tt.tournament_id=v_round.tournament_id
       AND tt.activo=true;

    IF v_team.id IS NULL THEN
        RAISE EXCEPTION
            'El equipo no existe, está inactivo o pertenece a otro torneo.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_round.tournament_id
    ) THEN
        RAISE EXCEPTION 'No tienes permiso para consultar este estado.'
            USING ERRCODE='42501';
    END IF;

    SELECT * INTO v_config
    FROM public.tournament_team_handicap_configs
    WHERE tournament_id=v_round.tournament_id
      AND active=true;

    SELECT * INTO v_version
    FROM public.tournament_round_team_handicap_versions
    WHERE tournament_round_id=p_tournament_round_id
      AND tournament_team_id=p_tournament_team_id
      AND status='active'
    LIMIT 1;

    SELECT count(*)
      INTO v_current_count
      FROM public.tournament_registrations tr
     WHERE tr.tournament_id=v_round.tournament_id
       AND tr.tournament_team_id=p_tournament_team_id
       AND tr.activo=true;

    RETURN jsonb_build_object(
        'tournamentRoundId',p_tournament_round_id,
        'teamId',p_tournament_team_id,
        'teamName',v_team.nombre_equipo,
        'configured',v_config.id IS NOT NULL,
        'method',v_config.method,
        'state',
            CASE
                WHEN v_config.id IS NULL THEN 'MISSING_CONFIG'
                WHEN v_version.id IS NULL THEN 'MISSING'
                WHEN v_version.is_stale THEN 'STALE'
                ELSE 'CURRENT'
            END,
        'requiresRecalculation',
            v_config.id IS NOT NULL
            AND (
                v_version.id IS NULL
                OR v_version.is_stale
            ),
        'currentMemberCount',v_current_count,
        'version',
            CASE WHEN v_version.id IS NULL THEN NULL
                 ELSE jsonb_build_object(
                    'id',v_version.id,
                    'version',v_version.version,
                    'method',v_version.method,
                    'memberCount',v_version.member_count,
                    'teamHandicapUnrounded',
                        v_version.team_handicap_unrounded,
                    'teamPlayingHandicap',
                        v_version.team_playing_handicap,
                    'isStale',v_version.is_stale,
                    'staleReason',v_version.stale_reason,
                    'staleAt',v_version.stale_at,
                    'calculatedAt',v_version.calculated_at
                 )
            END
    );
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_estado_handicap_equipo_a_gogo(
    uuid,uuid
) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.obtener_estado_handicap_equipo_a_gogo(
    uuid,uuid
) TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 9. Recalcular todos los HCP faltantes/obsoletos de una ronda
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.recalcular_handicaps_equipos_a_gogo_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_tournament_id uuid;
    r record;
    v_result jsonb;
    v_results jsonb := '[]'::jsonb;
    v_count integer := 0;
BEGIN
    SELECT tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds
     WHERE id=p_tournament_round_id
       AND activo=true;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda no existe o está inactiva.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION 'No tienes permiso para recalcular esta ronda.'
            USING ERRCODE='42501';
    END IF;

    IF NOT EXISTS(
        SELECT 1
        FROM public.tournament_team_handicap_configs c
        WHERE c.tournament_id=v_tournament_id
          AND c.active=true
    ) THEN
        RAISE EXCEPTION
            'El torneo no tiene configuración activa de HCP de equipo.';
    END IF;

    FOR r IN
        SELECT tt.id AS team_id
        FROM public.tournament_teams tt
        WHERE tt.tournament_id=v_tournament_id
          AND tt.activo=true
          AND EXISTS(
              SELECT 1
              FROM public.tournament_registrations tr
              WHERE tr.tournament_id=v_tournament_id
                AND tr.tournament_team_id=tt.id
                AND tr.activo=true
          )
          AND (
              NOT EXISTS(
                  SELECT 1
                  FROM public.tournament_round_team_handicap_versions v
                  WHERE v.tournament_round_id=p_tournament_round_id
                    AND v.tournament_team_id=tt.id
                    AND v.status='active'
              )
              OR EXISTS(
                  SELECT 1
                  FROM public.tournament_round_team_handicap_versions v
                  WHERE v.tournament_round_id=p_tournament_round_id
                    AND v.tournament_team_id=tt.id
                    AND v.status='active'
                    AND v.is_stale
              )
          )
        ORDER BY tt.nombre_equipo,tt.id
    LOOP
        v_result:=public.recalcular_handicap_equipo_a_gogo(
            p_tournament_round_id,
            r.team_id
        );

        v_results:=v_results || jsonb_build_array(v_result);
        v_count:=v_count+1;
    END LOOP;

    RETURN jsonb_build_object(
        'tournamentRoundId',p_tournament_round_id,
        'recalculatedCount',v_count,
        'results',v_results
    );
END;
$$;

REVOKE ALL ON FUNCTION public.recalcular_handicaps_equipos_a_gogo_ronda(
    uuid
) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.recalcular_handicaps_equipos_a_gogo_ronda(
    uuid
) TO authenticated,service_role;

COMMIT;
