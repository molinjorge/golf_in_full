-- ============================================================================
-- MIGRACIÓN 201 FASE 2A
-- A-Go-Go — reasignación controlada de jugadores entre equipos después del freeze
-- Proyecto: Tee Central / GOLF IN FULL
--
-- OBJETIVO
-- - Mantener intacto el freeze general del torneo.
-- - Permitir únicamente a administración autorizada mover una inscripción A-Go-Go
--   existente de un equipo a otro después del congelamiento.
-- - Registrar quién hizo el cambio, cuándo y por qué.
-- - No tocar todavía salidas ya validadas: eso queda para Fase 4.
-- - No sustituir todavía una persona por otra: eso queda para Fase 2B.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Bitácora explícita de cambios de composición A-Go-Go
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_team_composition_changes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    tournament_registration_id uuid NOT NULL
        REFERENCES public.tournament_registrations(id) ON DELETE RESTRICT,
    player_id uuid NOT NULL
        REFERENCES public.players(id) ON DELETE RESTRICT,

    change_type text NOT NULL
        CHECK (change_type IN (
            'team_reassignment',
            'player_substitution',
            'captain_change'
        )),

    old_team_id uuid NULL
        REFERENCES public.tournament_teams(id) ON DELETE RESTRICT,
    new_team_id uuid NULL
        REFERENCES public.tournament_teams(id) ON DELETE RESTRICT,

    reason text NOT NULL,
    changed_by_admin_id uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    changed_at timestamptz NOT NULL DEFAULT now(),

    freeze_id uuid NULL
        REFERENCES public.tournament_condition_freezes(id) ON DELETE RESTRICT,

    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_team_composition_changes_tournament
    ON public.tournament_team_composition_changes(tournament_id, changed_at DESC);

CREATE INDEX IF NOT EXISTS idx_team_composition_changes_registration
    ON public.tournament_team_composition_changes(tournament_registration_id);

CREATE INDEX IF NOT EXISTS idx_team_composition_changes_player
    ON public.tournament_team_composition_changes(player_id);

ALTER TABLE public.tournament_team_composition_changes ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_team_composition_changes
FROM anon, authenticated;

GRANT ALL ON TABLE public.tournament_team_composition_changes
TO service_role;

COMMENT ON TABLE public.tournament_team_composition_changes IS
'Bitácora explícita e inmutable de cambios excepcionales de composición A-Go-Go posteriores al freeze.';

-- ----------------------------------------------------------------------------
-- 2. Helper: determina si está activo el bypass controlado de composición
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._a_gogo_composition_override_201()
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
    SELECT current_setting(
        'app.a_gogo_composition_override',
        true
    ) = 'true';
$$;

REVOKE ALL ON FUNCTION public._a_gogo_composition_override_201()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public._a_gogo_composition_override_201()
TO service_role;

-- ----------------------------------------------------------------------------
-- 3. Ajustar freeze:
--    conserva TODO el bloqueo existente.
--    Solo deja pasar cambio de team_id cuando el bypass interno está activo
--    y el torneo es formato de equipo con motor team_stroke.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.proteger_inscripcion_torneo_congelado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_torneo_congelado boolean;
    v_pertenece_snapshot boolean;
    v_allow_team_override boolean := false;
    v_participation_type text;
    v_scoring_engine text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT EXISTS (
            SELECT 1
            FROM public.tournament_condition_freezes f
            WHERE f.tournament_id = NEW.tournament_id
        )
        INTO v_torneo_congelado;

        IF v_torneo_congelado AND NEW.activo = true THEN
            RAISE EXCEPTION
                'No se pueden agregar inscripciones activas: las condiciones y los participantes del torneo ya fueron congelados.'
                USING ERRCODE = '55000',
                      HINT = 'Los casos excepcionales posteriores al congelamiento requieren un procedimiento explícito y auditado.';
        END IF;

        RETURN NEW;
    END IF;

    IF NEW.tournament_id IS DISTINCT FROM OLD.tournament_id
       AND (
            EXISTS (
                SELECT 1
                FROM public.tournament_condition_freezes f
                WHERE f.tournament_id = OLD.tournament_id
            )
            OR EXISTS (
                SELECT 1
                FROM public.tournament_condition_freezes f
                WHERE f.tournament_id = NEW.tournament_id
            )
       ) THEN
        RAISE EXCEPTION
            'No se puede cambiar de torneo una inscripción vinculada con un torneo congelado.'
            USING ERRCODE = '55000';
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM public.tournament_condition_freezes f
        WHERE f.tournament_id = OLD.tournament_id
    )
    INTO v_torneo_congelado;

    IF NOT v_torneo_congelado THEN
        RETURN NEW;
    END IF;

    -- El bypass es deliberadamente estrecho: únicamente team_stroke.
    IF public._a_gogo_composition_override_201() THEN
        SELECT tf.tipo_participacion::text,
               tf.scoring_engine::text
          INTO v_participation_type,
               v_scoring_engine
          FROM public.tournaments t
          JOIN public.tournament_formats tf
            ON tf.id = t.tournament_format_id
         WHERE t.id = OLD.tournament_id;

        v_allow_team_override :=
            v_participation_type = 'equipo'
            AND v_scoring_engine = 'team_stroke';
    END IF;

    IF NEW.player_id IS DISTINCT FROM OLD.player_id THEN
        RAISE EXCEPTION
            'No se puede cambiar el jugador: la inscripción pertenece a un torneo congelado.'
            USING ERRCODE = '55000';
    END IF;

    IF NEW.tournament_category_id IS DISTINCT FROM OLD.tournament_category_id THEN
        RAISE EXCEPTION
            'No se puede cambiar la categoría: las condiciones y hándicaps del torneo ya fueron congelados.'
            USING ERRCODE = '55000',
                  HINT = 'La categoría competitiva válida es la guardada en el snapshot del torneo.';
    END IF;

    IF NEW.marca_salida_id IS DISTINCT FROM OLD.marca_salida_id THEN
        RAISE EXCEPTION
            'No se puede cambiar la marca de salida: las condiciones y hándicaps del torneo ya fueron congelados.'
            USING ERRCODE = '55000',
                  HINT = 'La marca efectiva válida es la guardada en los snapshots por ronda.';
    END IF;

    IF NEW.tournament_team_id IS DISTINCT FROM OLD.tournament_team_id
       AND NOT v_allow_team_override THEN
        RAISE EXCEPTION
            'No se puede cambiar el equipo: la composición competitiva del torneo ya fue congelada.'
            USING ERRCODE = '55000',
                  HINT = 'En A-Go-Go use el procedimiento administrativo auditado de cambio de equipo.';
    END IF;

    IF OLD.activo = false AND NEW.activo = true THEN
        SELECT EXISTS (
            SELECT 1
            FROM public.tournament_handicap_snapshots hs
            WHERE hs.tournament_id = OLD.tournament_id
              AND hs.tournament_registration_id = OLD.id
        )
        INTO v_pertenece_snapshot;

        IF NOT v_pertenece_snapshot THEN
            RAISE EXCEPTION
                'No se puede reactivar esta inscripción porque no formó parte de los participantes congelados.'
                USING ERRCODE = '55000',
                      HINT = 'Los casos excepcionales posteriores al congelamiento requieren un procedimiento explícito y auditado.';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. RPC administrativa: reasignar inscripción existente entre equipos A-Go-Go
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reasignar_inscripcion_equipo_a_gogo_post_freeze(
    p_tournament_registration_id uuid,
    p_new_team_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_reg public.tournament_registrations%ROWTYPE;
    v_old_team public.tournament_teams%ROWTYPE;
    v_new_team public.tournament_teams%ROWTYPE;
    v_tournament public.tournaments%ROWTYPE;
    v_admin_id uuid;
    v_freeze_id uuid;
    v_participation_type text;
    v_scoring_engine text;
    v_capacity integer;
    v_occupancy integer;
    v_slot_id uuid;
    v_result public.tournament_registrations%ROWTYPE;
    v_change_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    IF length(btrim(COALESCE(p_reason, ''))) < 5 THEN
        RAISE EXCEPTION
            'El motivo del cambio debe contener al menos 5 caracteres.'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
      INTO v_reg
      FROM public.tournament_registrations
     WHERE id = p_tournament_registration_id
     FOR UPDATE;

    IF v_reg.id IS NULL OR NOT v_reg.activo THEN
        RAISE EXCEPTION 'La inscripción no existe o está inactiva.';
    END IF;

    IF v_reg.tournament_team_id IS NULL THEN
        RAISE EXCEPTION
            'La inscripción no pertenece actualmente a un equipo.';
    END IF;

    IF v_reg.tournament_team_id = p_new_team_id THEN
        RAISE EXCEPTION 'La inscripción ya pertenece a ese equipo.';
    END IF;

    SELECT *
      INTO v_tournament
      FROM public.tournaments
     WHERE id = v_reg.tournament_id
       AND activo = true;

    IF v_tournament.id IS NULL THEN
        RAISE EXCEPTION 'El torneo no existe o está inactivo.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament.id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para cambiar la composición de equipos de este torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tf.tipo_participacion::text,
           tf.scoring_engine::text
      INTO v_participation_type,
           v_scoring_engine
      FROM public.tournament_formats tf
     WHERE tf.id = v_tournament.tournament_format_id;

    IF v_participation_type IS DISTINCT FROM 'equipo'
       OR v_scoring_engine IS DISTINCT FROM 'team_stroke' THEN
        RAISE EXCEPTION
            'Este procedimiento solo aplica a formatos A-Go-Go/team_stroke.';
    END IF;

    SELECT f.id
      INTO v_freeze_id
      FROM public.tournament_condition_freezes f
     WHERE f.tournament_id = v_tournament.id
     ORDER BY f.created_at DESC
     LIMIT 1;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION
            'El torneo todavía no está congelado; use el flujo normal de reasignación.';
    END IF;

    -- Fase 2A no toca salidas validadas.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_round_start_validations sv
          JOIN public.tournament_rounds r
            ON r.id = sv.tournament_round_id
         WHERE r.tournament_id = v_tournament.id
           AND sv.status = 'validated'
    ) THEN
        RAISE EXCEPTION
            'Existe al menos una ronda con salidas validadas. La reasignación posterior a la validación se habilitará en la Fase 4.'
            USING ERRCODE = '55000';
    END IF;

    SELECT *
      INTO v_old_team
      FROM public.tournament_teams
     WHERE id = v_reg.tournament_team_id
       AND tournament_id = v_tournament.id
       AND activo = true;

    SELECT *
      INTO v_new_team
      FROM public.tournament_teams
     WHERE id = p_new_team_id
       AND tournament_id = v_tournament.id
       AND activo = true;

    IF v_old_team.id IS NULL THEN
        RAISE EXCEPTION 'El equipo actual no existe o está inactivo.';
    END IF;

    IF v_new_team.id IS NULL THEN
        RAISE EXCEPTION
            'El equipo destino no existe, está inactivo o pertenece a otro torneo.';
    END IF;

    -- Por ahora no mover al capitán: cambiar capitán requiere flujo propio.
    IF v_old_team.captain_player_id = v_reg.player_id THEN
        RAISE EXCEPTION
            'El capitán no puede moverse con esta operación. El cambio de capitán se manejará mediante un flujo específico.';
    END IF;

    v_capacity := v_tournament.jugadores_por_equipo;

    IF v_capacity IS NULL OR v_capacity <= 0 THEN
        RAISE EXCEPTION
            'El torneo no tiene configurado jugadores_por_equipo.';
    END IF;

    -- Si ya existe un slot provisional/confirmado del mismo jugador en el equipo
    -- destino, ese slot representa la misma plaza y no debe contarse dos veces.
    SELECT rs.id
      INTO v_slot_id
      FROM public.tournament_team_roster_slots rs
     WHERE rs.tournament_id = v_tournament.id
       AND rs.tournament_team_id = p_new_team_id
       AND rs.player_id = v_reg.player_id
       AND rs.status IN ('pending_confirmation','confirmed')
     ORDER BY rs.created_at
     LIMIT 1;

    v_occupancy := public.ocupacion_actual_equipo(p_new_team_id);

    IF v_slot_id IS NOT NULL THEN
        v_occupancy := GREATEST(v_occupancy - 1, 0);
    END IF;

    IF v_occupancy >= v_capacity THEN
        RAISE EXCEPTION
            'El equipo destino ya está completo (% de % lugares).',
            v_occupancy, v_capacity;
    END IF;

    -- Serializar ambos equipos.
    PERFORM pg_advisory_xact_lock(
        LEAST(
            hashtextextended(v_old_team.id::text, 201),
            hashtextextended(v_new_team.id::text, 201)
        )
    );
    PERFORM pg_advisory_xact_lock(
        GREATEST(
            hashtextextended(v_old_team.id::text, 201),
            hashtextextended(v_new_team.id::text, 201)
        )
    );

    PERFORM set_config(
        'app.a_gogo_composition_override',
        'true',
        true
    );

    UPDATE public.tournament_registrations
       SET tournament_team_id = p_new_team_id
     WHERE id = v_reg.id
     RETURNING * INTO v_result;

    -- Si el registro provenía del roster 199/200, mantener ese vínculo coherente.
    UPDATE public.tournament_team_roster_slots
       SET tournament_team_id = p_new_team_id,
           updated_at = now()
     WHERE tournament_registration_id = v_reg.id
       AND status = 'converted';

    -- Si el equipo destino tenía una invitación del mismo jugador, consumirla
    -- y ligarla a la inscripción ya existente.
    IF v_slot_id IS NOT NULL THEN
        UPDATE public.tournament_team_roster_slots
           SET status = 'converted',
               tournament_registration_id = v_reg.id,
               confirmed_at = COALESCE(confirmed_at, now()),
               updated_at = now()
         WHERE id = v_slot_id;
    END IF;

    INSERT INTO public.tournament_team_composition_changes (
        tournament_id,
        tournament_registration_id,
        player_id,
        change_type,
        old_team_id,
        new_team_id,
        reason,
        changed_by_admin_id,
        freeze_id,
        metadata
    )
    VALUES (
        v_tournament.id,
        v_reg.id,
        v_reg.player_id,
        'team_reassignment',
        v_old_team.id,
        v_new_team.id,
        btrim(p_reason),
        v_admin_id,
        v_freeze_id,
        jsonb_build_object(
            'phase', '201_FASE2A',
            'postFreeze', true,
            'startValidationAffected', false
        )
    )
    RETURNING id INTO v_change_id;

    RETURN jsonb_build_object(
        'changeId', v_change_id,
        'tournamentId', v_tournament.id,
        'registrationId', v_result.id,
        'playerId', v_result.player_id,
        'oldTeamId', v_old_team.id,
        'newTeamId', v_new_team.id,
        'freezeId', v_freeze_id,
        'reason', btrim(p_reason),
        'changedAt', now()
    );
END;
$$;

REVOKE ALL ON FUNCTION public.reasignar_inscripcion_equipo_a_gogo_post_freeze(
    uuid, uuid, text
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.reasignar_inscripcion_equipo_a_gogo_post_freeze(
    uuid, uuid, text
)
TO service_role;

-- Los administradores autenticados necesitan invocarla vía API.
GRANT EXECUTE ON FUNCTION public.reasignar_inscripcion_equipo_a_gogo_post_freeze(
    uuid, uuid, text
)
TO authenticated;

-- ----------------------------------------------------------------------------
-- 5. Consulta de historial de cambios de composición
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_historial_composicion_equipos_a_gogo(
    p_tournament_id uuid
)
RETURNS TABLE (
    id uuid,
    tournament_registration_id uuid,
    player_id uuid,
    player_name text,
    change_type text,
    old_team_id uuid,
    old_team_name text,
    new_team_id uuid,
    new_team_name text,
    reason text,
    changed_by_admin_id uuid,
    changed_at timestamptz,
    freeze_id uuid,
    metadata jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar este historial.'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT c.id,
           c.tournament_registration_id,
           c.player_id,
           concat_ws(' ', p.nombres, p.apellidos)::text,
           c.change_type,
           c.old_team_id,
           ot.nombre_equipo,
           c.new_team_id,
           nt.nombre_equipo,
           c.reason,
           c.changed_by_admin_id,
           c.changed_at,
           c.freeze_id,
           c.metadata
      FROM public.tournament_team_composition_changes c
      JOIN public.players p
        ON p.id = c.player_id
      LEFT JOIN public.tournament_teams ot
        ON ot.id = c.old_team_id
      LEFT JOIN public.tournament_teams nt
        ON nt.id = c.new_team_id
     WHERE c.tournament_id = p_tournament_id
     ORDER BY c.changed_at DESC, c.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_historial_composicion_equipos_a_gogo(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.obtener_historial_composicion_equipos_a_gogo(uuid)
TO authenticated, service_role;

COMMIT;
