-- ============================================================================
-- MIGRACIÓN 206 FASE 4B
-- A-Go-Go — reacomodo Shotgun post-validación con nueva versión operativa
-- Proyecto: Tee Central / GOLF IN FULL
--
-- PRINCIPIOS
-- - NO edita la fotografía validada existente.
-- - NO relaja el trigger global de protección de salidas.
-- - Un movimiento post-validación:
--      1) marca la validación actual como histórica/reopened,
--      2) mueve SOLO el equipo afectado en las tablas operativas,
--      3) vuelve a validar en la MISMA transacción,
--      4) crea una nueva versión completa de validación,
--      5) audita old/new validation y old/new group.
-- - Si cualquier paso falla, TODA la operación revierte.
-- - Se bloquea si ya existen tarjetas oficiales emitidas.
-- - Sólo Shotgun + equipo + team_stroke.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Auditoría específica de reacomodos localizados post-validación
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_round_start_local_rearrangements (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,

    tournament_team_id uuid NOT NULL
        REFERENCES public.tournament_teams(id) ON DELETE RESTRICT,

    old_validation_id uuid NOT NULL
        REFERENCES public.tournament_round_start_validations(id)
        ON DELETE RESTRICT,

    new_validation_id uuid NOT NULL
        REFERENCES public.tournament_round_start_validations(id)
        ON DELETE RESTRICT,

    old_validation_version integer NOT NULL,
    new_validation_version integer NOT NULL,

    old_group_id uuid NULL
        REFERENCES public.tournament_groups(id) ON DELETE RESTRICT,

    new_group_id uuid NOT NULL
        REFERENCES public.tournament_groups(id) ON DELETE RESTRICT,

    reason text NOT NULL
        CHECK (length(btrim(reason)) >= 5),

    changed_by_admin_id uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,

    changed_at timestamptz NOT NULL DEFAULT now(),

    movement_result jsonb NOT NULL DEFAULT '{}'::jsonb,
    validation_result jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_start_local_rearrangements_round
    ON public.tournament_round_start_local_rearrangements(
        tournament_round_id,
        changed_at DESC
    );

CREATE INDEX IF NOT EXISTS idx_start_local_rearrangements_team
    ON public.tournament_round_start_local_rearrangements(
        tournament_team_id,
        changed_at DESC
    );

ALTER TABLE public.tournament_round_start_local_rearrangements
    ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_round_start_local_rearrangements
FROM anon, authenticated;

GRANT ALL ON TABLE public.tournament_round_start_local_rearrangements
TO service_role;

COMMENT ON TABLE public.tournament_round_start_local_rearrangements IS
'Auditoría de movimientos localizados de equipos A-Go-Go Shotgun posteriores a una validación. La validación anterior queda histórica y se genera una nueva versión en la misma transacción.';

-- ----------------------------------------------------------------------------
-- 2. RPC: mover equipo después de validar, sin flujo global de reapertura
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.mover_equipo_shotgun_post_validacion_a_gogo(
    p_config_id uuid,
    p_tournament_team_id uuid,
    p_destino_hole_id uuid,
    p_destino_posicion text,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_auth_uid uuid;
    v_admin_id uuid;

    v_tournament_id uuid;
    v_round_id uuid;
    v_category_id uuid;

    v_old_validation public.tournament_round_start_validations%ROWTYPE;
    v_new_validation public.tournament_round_start_validations%ROWTYPE;

    v_old_group_id uuid;
    v_old_group_label text;

    v_move jsonb;
    v_preview jsonb;
    v_validation_state jsonb;

    v_new_group_id uuid;
    v_audit_id uuid;
BEGIN
    v_auth_uid := auth.uid();

    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF length(btrim(COALESCE(p_reason,''))) < 5 THEN
        RAISE EXCEPTION
            'El motivo del reacomodo debe contener al menos 5 caracteres.'
            USING ERRCODE='22023';
    END IF;

    IF upper(btrim(COALESCE(p_destino_posicion,''))) NOT IN ('A','B') THEN
        RAISE EXCEPTION
            'La posición destino debe ser A o B.'
            USING ERRCODE='22023';
    END IF;

    -- Resolver configuración y confirmar motor A-Go-Go Shotgun.
    SELECT
        tr.tournament_id,
        tr.id,
        sc.tournament_category_id
      INTO
        v_tournament_id,
        v_round_id,
        v_category_id
      FROM public.tournament_shotgun_category_configs cfg
      JOIN public.tournament_round_shift_categories sc
        ON sc.id=cfg.tournament_round_shift_category_id
       AND sc.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id=sc.tournament_round_shift_id
       AND rs.activo
      JOIN public.tournament_rounds tr
        ON tr.id=rs.tournament_round_id
       AND tr.activo
      JOIN public.tournaments t
        ON t.id=tr.tournament_id
       AND t.activo
      JOIN public.tournament_formats tf
        ON tf.id=COALESCE(tr.tournament_format_id,t.tournament_format_id)
     WHERE cfg.id=p_config_id
       AND cfg.activo
       AND tr.formato_salida='shotgun'::public.formato_salida_ronda
       AND tf.tipo_participacion::text='equipo'
       AND tf.scoring_engine::text='team_stroke';

    IF v_round_id IS NULL THEN
        RAISE EXCEPTION
            'La configuración no corresponde a una ronda A-Go-Go Shotgun activa.';
    END IF;

    IF NOT public.can_manage_tournament_shotgun_config(
        v_auth_uid,
        p_config_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permisos para modificar esta configuración Shotgun.'
            USING ERRCODE='42501';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para administrar las salidas de este torneo.'
            USING ERRCODE='42501';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id=v_auth_uid
       AND au.activo
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene administrador activo asociado.'
            USING ERRCODE='42501';
    END IF;

    -- Serializar cualquier operación de salida de la ronda.
    PERFORM public._bloquear_salida_ronda(v_round_id);

    -- Salvaguarda futura: una vez emitida la tarjeta oficial, Fase 4B ya no
    -- puede cambiar la salida.
    IF public._ronda_tiene_tarjetas_emitidas(v_round_id) THEN
        RAISE EXCEPTION
            'La ronda ya tiene tarjetas oficiales emitidas. El reacomodo post-validación no está permitido.'
            USING ERRCODE='55000';
    END IF;

    -- Equipo activo y de la categoría de esta configuración.
    PERFORM 1
      FROM public.tournament_teams tt
     WHERE tt.id=p_tournament_team_id
       AND tt.tournament_id=v_tournament_id
       AND tt.tournament_category_id=v_category_id
       AND tt.activo;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El equipo no está activo o no pertenece a la categoría de esta configuración.';
    END IF;

    -- Debe existir una validación formal activa.
    SELECT *
      INTO v_old_validation
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_round_id=v_round_id
       AND v.status='validated'
     FOR UPDATE;

    IF v_old_validation.id IS NULL THEN
        RAISE EXCEPTION
            'La ronda no tiene una validación activa. Usa el movimiento Shotgun normal antes de validar.'
            USING ERRCODE='23514';
    END IF;

    IF v_old_validation.start_format IS DISTINCT FROM 'shotgun'
       OR v_old_validation.participation_type IS DISTINCT FROM 'equipo'
       OR v_old_validation.scoring_engine IS DISTINCT FROM 'team_stroke'
    THEN
        RAISE EXCEPTION
            'La validación activa no corresponde a A-Go-Go Shotgun por equipos.';
    END IF;

    -- Captura del grupo origen antes del cambio.
    SELECT g.id,g.etiqueta
      INTO v_old_group_id,v_old_group_label
      FROM public.tournament_group_teams gt
      JOIN public.tournament_groups g
        ON g.id=gt.tournament_group_id
       AND g.activo
      JOIN public.tournament_round_shifts rs
        ON rs.id=g.tournament_round_shift_id
       AND rs.tournament_round_id=v_round_id
       AND rs.activo
     WHERE gt.tournament_team_id=p_tournament_team_id
       AND gt.activo
     LIMIT 1;

    IF v_old_group_id IS NULL THEN
        RAISE EXCEPTION
            'El equipo no está actualmente asignado a un grupo activo de esta ronda.';
    END IF;

    -- ------------------------------------------------------------------------
    -- La operación es ATÓMICA:
    -- 1) La validación anterior se marca histórica mediante el mecanismo
    --    autorizado existente.
    -- 2) A partir de ese instante los triggers normales permiten modificar
    --    la fuente porque ya no existe una validación activa.
    -- 3) Si el movimiento o la nueva validación fallan, PostgreSQL revierte
    --    también este cambio de status.
    -- ------------------------------------------------------------------------

    PERFORM set_config(
        'app.reabrir_validacion_salida_ronda',
        'true',
        true
    );

    UPDATE public.tournament_round_start_validations
       SET status='reopened',
           reopened_at=now(),
           reopened_by=v_admin_id,
           reopen_reason=
               'Reacomodo localizado A-Go-Go: ' || btrim(p_reason)
     WHERE id=v_old_validation.id;

    -- Movimiento localizado reutilizando la infraestructura Shotgun existente.
    v_move := public.mover_unidad_shotgun(
        p_config_id,
        p_tournament_team_id,
        'equipo',
        p_destino_hole_id,
        upper(btrim(p_destino_posicion))
    );

    v_new_group_id :=
        NULLIF(v_move #>> '{destino,groupId}','')::uuid;

    IF v_new_group_id IS NULL THEN
        -- Si fue sinCambios, recuperar grupo retornado.
        v_new_group_id :=
            NULLIF(v_move->>'groupId','')::uuid;
    END IF;

    IF v_new_group_id IS NULL THEN
        RAISE EXCEPTION
            'El movimiento no devolvió un grupo destino válido.'
            USING ERRCODE='55000';
    END IF;

    -- Preview completo: garantiza que el pequeño cambio no dejó una ronda
    -- inconsistente.
    v_preview :=
        public.previsualizar_validacion_salidas_ronda(v_round_id);

    IF NOT COALESCE((v_preview->>'ready')::boolean,false) THEN
        RAISE EXCEPTION
            'El reacomodo dejaría las salidas en un estado no validable y fue revertido.'
            USING ERRCODE='23514',
                  DETAIL=(v_preview->'errors')::text;
    END IF;

    -- Nueva fotografía formal completa. Reutiliza la versión histórica común.
    v_validation_state :=
        public.validar_salidas_ronda(v_round_id);

    SELECT *
      INTO v_new_validation
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_round_id=v_round_id
       AND v.status='validated'
     ORDER BY v.version DESC
     LIMIT 1;

    IF v_new_validation.id IS NULL
       OR v_new_validation.id=v_old_validation.id
       OR v_new_validation.version<=v_old_validation.version
    THEN
        RAISE EXCEPTION
            'No fue posible generar una nueva versión formal de las salidas.'
            USING ERRCODE='55000';
    END IF;

    INSERT INTO public.tournament_round_start_local_rearrangements(
        tournament_id,
        tournament_round_id,
        tournament_team_id,
        old_validation_id,
        new_validation_id,
        old_validation_version,
        new_validation_version,
        old_group_id,
        new_group_id,
        reason,
        changed_by_admin_id,
        movement_result,
        validation_result
    )
    VALUES(
        v_tournament_id,
        v_round_id,
        p_tournament_team_id,
        v_old_validation.id,
        v_new_validation.id,
        v_old_validation.version,
        v_new_validation.version,
        v_old_group_id,
        v_new_group_id,
        btrim(p_reason),
        v_admin_id,
        v_move,
        v_validation_state
    )
    RETURNING id INTO v_audit_id;

    RETURN jsonb_build_object(
        'success',true,
        'auditId',v_audit_id,
        'tournamentId',v_tournament_id,
        'tournamentRoundId',v_round_id,
        'teamId',p_tournament_team_id,
        'reason',btrim(p_reason),
        'oldValidation',jsonb_build_object(
            'id',v_old_validation.id,
            'version',v_old_validation.version,
            'status','reopened'
        ),
        'newValidation',jsonb_build_object(
            'id',v_new_validation.id,
            'version',v_new_validation.version,
            'status',v_new_validation.status
        ),
        'movement',jsonb_build_object(
            'oldGroupId',v_old_group_id,
            'oldGroupLabel',v_old_group_label,
            'newGroupId',v_new_group_id,
            'detail',v_move
        ),
        'validation',v_validation_state
    );
END;
$$;

REVOKE ALL ON FUNCTION public.mover_equipo_shotgun_post_validacion_a_gogo(
    uuid,uuid,uuid,text,text
) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.mover_equipo_shotgun_post_validacion_a_gogo(
    uuid,uuid,uuid,text,text
) TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 3. Historial consumible por UI
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_reacomodos_post_validacion_a_gogo(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_tournament_id uuid;
BEGIN
    SELECT tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds
     WHERE id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar estos reacomodos.'
            USING ERRCODE='42501';
    END IF;

    RETURN COALESCE((
        SELECT jsonb_agg(
            jsonb_build_object(
                'id',r.id,
                'teamId',r.tournament_team_id,
                'teamName',tt.nombre_equipo,
                'oldValidationId',r.old_validation_id,
                'oldValidationVersion',r.old_validation_version,
                'newValidationId',r.new_validation_id,
                'newValidationVersion',r.new_validation_version,
                'oldGroupId',r.old_group_id,
                'newGroupId',r.new_group_id,
                'reason',r.reason,
                'changedByAdminId',r.changed_by_admin_id,
                'changedAt',r.changed_at
            )
            ORDER BY r.changed_at DESC,r.id
        )
        FROM public.tournament_round_start_local_rearrangements r
        JOIN public.tournament_teams tt
          ON tt.id=r.tournament_team_id
        WHERE r.tournament_round_id=p_tournament_round_id
    ),'[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_reacomodos_post_validacion_a_gogo(
    uuid
) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.obtener_reacomodos_post_validacion_a_gogo(
    uuid
) TO authenticated,service_role;

COMMIT;
