-- ============================================================================
-- MIGRACIÓN 207 FASE 4C
-- A-Go-Go — cambios de composición posteriores a validación
-- Proyecto: Tee Central / GOLF IN FULL
--
-- OBJETIVO
-- - Permitir:
--      A) reasignación de un jugador entre equipos después de validar salidas;
--      B) confirmación de sustitución de integrante después de validar salidas.
-- - Reutilizar SIN reemplazar las RPC 201/202.
-- - Mantener atómica la secuencia:
--      validación anterior -> histórica
--      cambio de composición
--      recálculo HCP equipo(s)
--      preview
--      nueva validación formal
-- - No editar snapshots históricos.
-- - No permitir cambios si ya existen tarjetas oficiales emitidas.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Auditoría de revalidaciones provocadas por composición
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_round_start_composition_revalidations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,

    source_type text NOT NULL
        CHECK (source_type IN ('team_reassignment','player_substitution')),

    source_id uuid NOT NULL,

    affected_team_ids uuid[] NOT NULL
        CHECK (cardinality(affected_team_ids) > 0),

    old_validation_id uuid NOT NULL
        REFERENCES public.tournament_round_start_validations(id)
        ON DELETE RESTRICT,

    new_validation_id uuid NOT NULL
        REFERENCES public.tournament_round_start_validations(id)
        ON DELETE RESTRICT,

    old_validation_version integer NOT NULL,
    new_validation_version integer NOT NULL,

    reason text NOT NULL
        CHECK (length(btrim(reason)) >= 5),

    authorized_admin_id uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,

    created_at timestamptz NOT NULL DEFAULT now(),

    handicap_recalculations jsonb NOT NULL DEFAULT '[]'::jsonb,
    validation_result jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_start_comp_revalidations_round
    ON public.tournament_round_start_composition_revalidations(
        tournament_round_id,
        created_at DESC
    );

CREATE INDEX IF NOT EXISTS idx_start_comp_revalidations_source
    ON public.tournament_round_start_composition_revalidations(
        source_type,
        source_id
    );

ALTER TABLE public.tournament_round_start_composition_revalidations
    ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_round_start_composition_revalidations
FROM anon, authenticated;

GRANT ALL ON TABLE public.tournament_round_start_composition_revalidations
TO service_role;

-- ----------------------------------------------------------------------------
-- 2. Helper interno:
--    toma validaciones YA marcadas reopened por el wrapper y genera nuevas
--    versiones después de recalcular HCP.
--
--    IMPORTANTE:
--    la sustitución es confirmada por un jugador. Para reutilizar los motores
--    203/205 sin otorgar permisos administrativos al jugador, el helper cambia
--    temporalmente request.jwt.claim.sub al auth_user_id del administrador que
--    autorizó la operación. El helper NO se concede a authenticated.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._revalidar_rondas_a_gogo_composicion_207(
    p_tournament_id uuid,
    p_old_validation_ids uuid[],
    p_affected_team_ids uuid[],
    p_admin_id uuid,
    p_reason text,
    p_source_type text,
    p_source_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_admin_auth_uid uuid;
    v_original_sub text;
    v_old_validation public.tournament_round_start_validations%ROWTYPE;
    v_new_validation public.tournament_round_start_validations%ROWTYPE;
    v_team_id uuid;
    v_hcp_result jsonb;
    v_hcp_results jsonb;
    v_preview jsonb;
    v_validation_result jsonb;
    v_round_results jsonb := '[]'::jsonb;
    v_audit_id uuid;
BEGIN
    IF p_source_type NOT IN ('team_reassignment','player_substitution') THEN
        RAISE EXCEPTION 'source_type no soportado.';
    END IF;

    IF length(btrim(COALESCE(p_reason,''))) < 5 THEN
        RAISE EXCEPTION 'El motivo debe contener al menos 5 caracteres.';
    END IF;

    IF COALESCE(cardinality(p_old_validation_ids),0)=0 THEN
        RETURN jsonb_build_object(
            'revalidatedRounds',0,
            'rounds','[]'::jsonb
        );
    END IF;

    IF COALESCE(cardinality(p_affected_team_ids),0)=0 THEN
        RAISE EXCEPTION 'Debe existir al menos un equipo afectado.';
    END IF;

    SELECT au.auth_user_id
      INTO v_admin_auth_uid
      FROM public.admin_users au
     WHERE au.id=p_admin_id
       AND au.activo=true;

    IF v_admin_auth_uid IS NULL THEN
        RAISE EXCEPTION
            'El administrador autorizado no existe o está inactivo.';
    END IF;

    v_original_sub := current_setting('request.jwt.claim.sub',true);

    -- Contexto administrativo exclusivamente dentro de esta transacción.
    PERFORM set_config(
        'request.jwt.claim.sub',
        v_admin_auth_uid::text,
        true
    );

    FOR v_old_validation IN
        SELECT v.*
        FROM public.tournament_round_start_validations v
        WHERE v.id=ANY(p_old_validation_ids)
        ORDER BY v.tournament_round_id,v.version
    LOOP
        IF v_old_validation.tournament_id IS DISTINCT FROM p_tournament_id THEN
            RAISE EXCEPTION
                'Una validación indicada pertenece a otro torneo.';
        END IF;

        IF v_old_validation.status IS DISTINCT FROM 'reopened' THEN
            RAISE EXCEPTION
                'La validación % no está en estado histórico/reopened.',
                v_old_validation.id;
        END IF;

        IF v_old_validation.start_format IS DISTINCT FROM 'shotgun'
           OR v_old_validation.participation_type IS DISTINCT FROM 'equipo'
           OR v_old_validation.scoring_engine IS DISTINCT FROM 'team_stroke'
        THEN
            RAISE EXCEPTION
                'La Fase 4C solo soporta validaciones A-Go-Go Shotgun por equipo.';
        END IF;

        PERFORM public._bloquear_salida_ronda(
            v_old_validation.tournament_round_id
        );

        IF public._ronda_tiene_tarjetas_emitidas(
            v_old_validation.tournament_round_id
        ) THEN
            RAISE EXCEPTION
                'La ronda % ya tiene tarjetas oficiales emitidas.',
                v_old_validation.tournament_round_id;
        END IF;

        v_hcp_results := '[]'::jsonb;

        FOREACH v_team_id IN ARRAY p_affected_team_ids
        LOOP
            -- Sólo equipos aún activos del torneo. Si un equipo quedó sin
            -- integrantes, el motor 203 fallará y revertirá toda la operación,
            -- evitando dejar una salida validada con un equipo sin HCP.
            IF EXISTS(
                SELECT 1
                FROM public.tournament_teams tt
                WHERE tt.id=v_team_id
                  AND tt.tournament_id=p_tournament_id
                  AND tt.activo=true
            ) THEN
                v_hcp_result :=
                    public.recalcular_handicap_equipo_a_gogo(
                        v_old_validation.tournament_round_id,
                        v_team_id
                    );

                v_hcp_results :=
                    v_hcp_results || jsonb_build_array(v_hcp_result);
            END IF;
        END LOOP;

        v_preview :=
            public.previsualizar_validacion_salidas_ronda(
                v_old_validation.tournament_round_id
            );

        IF NOT COALESCE((v_preview->>'ready')::boolean,false) THEN
            RAISE EXCEPTION
                'El cambio de composición dejaría la ronda % en estado no validable y fue revertido.',
                v_old_validation.tournament_round_id
                USING ERRCODE='23514',
                      DETAIL=(v_preview->'errors')::text;
        END IF;

        v_validation_result :=
            public.validar_salidas_ronda(
                v_old_validation.tournament_round_id
            );

        SELECT *
          INTO v_new_validation
          FROM public.tournament_round_start_validations v
         WHERE v.tournament_round_id=
               v_old_validation.tournament_round_id
           AND v.status='validated'
         ORDER BY v.version DESC
         LIMIT 1;

        IF v_new_validation.id IS NULL
           OR v_new_validation.id=v_old_validation.id
           OR v_new_validation.version<=v_old_validation.version
        THEN
            RAISE EXCEPTION
                'No se generó una nueva versión válida para la ronda %.',
                v_old_validation.tournament_round_id;
        END IF;

        INSERT INTO public.tournament_round_start_composition_revalidations(
            tournament_id,
            tournament_round_id,
            source_type,
            source_id,
            affected_team_ids,
            old_validation_id,
            new_validation_id,
            old_validation_version,
            new_validation_version,
            reason,
            authorized_admin_id,
            handicap_recalculations,
            validation_result
        )
        VALUES(
            p_tournament_id,
            v_old_validation.tournament_round_id,
            p_source_type,
            p_source_id,
            p_affected_team_ids,
            v_old_validation.id,
            v_new_validation.id,
            v_old_validation.version,
            v_new_validation.version,
            btrim(p_reason),
            p_admin_id,
            v_hcp_results,
            v_validation_result
        )
        RETURNING id INTO v_audit_id;

        v_round_results :=
            v_round_results || jsonb_build_array(
                jsonb_build_object(
                    'auditId',v_audit_id,
                    'tournamentRoundId',
                        v_old_validation.tournament_round_id,
                    'oldValidationId',v_old_validation.id,
                    'oldValidationVersion',v_old_validation.version,
                    'newValidationId',v_new_validation.id,
                    'newValidationVersion',v_new_validation.version,
                    'handicapRecalculations',v_hcp_results
                )
            );
    END LOOP;

    -- Restaurar identidad original antes de devolver control.
    PERFORM set_config(
        'request.jwt.claim.sub',
        COALESCE(v_original_sub,''),
        true
    );

    RETURN jsonb_build_object(
        'revalidatedRounds',jsonb_array_length(v_round_results),
        'rounds',v_round_results
    );
END;
$$;

REVOKE ALL ON FUNCTION public._revalidar_rondas_a_gogo_composicion_207(
    uuid,uuid[],uuid[],uuid,text,text,uuid
) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public._revalidar_rondas_a_gogo_composicion_207(
    uuid,uuid[],uuid[],uuid,text,text,uuid
) TO service_role;

-- ----------------------------------------------------------------------------
-- 3. Wrapper ADMIN:
--    reasignar una inscripción entre equipos después de validar.
--    Reutiliza íntegramente la RPC 201.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reasignar_inscripcion_equipo_a_gogo_post_validacion(
    p_tournament_registration_id uuid,
    p_new_team_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_reg public.tournament_registrations%ROWTYPE;
    v_old_team_id uuid;
    v_tournament_id uuid;
    v_admin_id uuid;
    v_old_validation_ids uuid[];
    v_base_result jsonb;
    v_revalidation jsonb;
    v_change_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF length(btrim(COALESCE(p_reason,''))) < 5 THEN
        RAISE EXCEPTION
            'El motivo debe contener al menos 5 caracteres.';
    END IF;

    SELECT *
      INTO v_reg
      FROM public.tournament_registrations
     WHERE id=p_tournament_registration_id
     FOR UPDATE;

    IF v_reg.id IS NULL OR NOT v_reg.activo THEN
        RAISE EXCEPTION 'La inscripción no existe o está inactiva.';
    END IF;

    v_tournament_id := v_reg.tournament_id;
    v_old_team_id := v_reg.tournament_team_id;

    IF v_old_team_id IS NULL THEN
        RAISE EXCEPTION 'La inscripción no pertenece a un equipo.';
    END IF;

    IF v_old_team_id=p_new_team_id THEN
        RAISE EXCEPTION 'La inscripción ya pertenece al equipo destino.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para cambiar la composición de equipos.'
            USING ERRCODE='42501';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id=auth.uid()
       AND au.activo
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No existe administrador activo asociado.';
    END IF;

    -- Si hubiera una validación activa de otra modalidad no debe ignorarse.
    IF EXISTS(
        SELECT 1
        FROM public.tournament_round_start_validations v
        WHERE v.tournament_id=v_tournament_id
          AND v.status='validated'
          AND (
              v.start_format IS DISTINCT FROM 'shotgun'
              OR v.participation_type IS DISTINCT FROM 'equipo'
              OR v.scoring_engine IS DISTINCT FROM 'team_stroke'
          )
    ) THEN
        RAISE EXCEPTION
            'Existe una ronda validada fuera del motor A-Go-Go Shotgun. Este flujo no puede modificarla.';
    END IF;

    SELECT COALESCE(array_agg(v.id ORDER BY v.tournament_round_id),ARRAY[]::uuid[])
      INTO v_old_validation_ids
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_id=v_tournament_id
       AND v.status='validated'
       AND v.start_format='shotgun'
       AND v.participation_type='equipo'
       AND v.scoring_engine='team_stroke';

    IF cardinality(v_old_validation_ids)=0 THEN
        RAISE EXCEPTION
            'No existen salidas validadas. Utiliza la reasignación post-freeze normal.';
    END IF;

    IF EXISTS(
        SELECT 1
        FROM public.tournament_score_card_emissions e
        JOIN public.tournament_round_start_validations v
          ON v.tournament_round_id=e.tournament_round_id
        WHERE v.id=ANY(v_old_validation_ids)
          AND e.status='issued'
    ) THEN
        RAISE EXCEPTION
            'Existe una ronda con tarjetas oficiales emitidas. La composición ya no puede modificarse.';
    END IF;

    -- Hacer históricas las versiones activas. Si cualquier paso posterior
    -- falla, esta misma transacción las restaura automáticamente.
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
               'Cambio composición A-Go-Go post-validación: ' ||
               btrim(p_reason)
     WHERE id=ANY(v_old_validation_ids);

    -- Reutilizar Fase 2A sin modificarla.
    v_base_result :=
        public.reasignar_inscripcion_equipo_a_gogo_post_freeze(
            p_tournament_registration_id,
            p_new_team_id,
            p_reason
        );

    v_change_id := NULLIF(v_base_result->>'changeId','')::uuid;

    IF v_change_id IS NULL THEN
        RAISE EXCEPTION
            'La reasignación no devolvió changeId.';
    END IF;

    v_revalidation :=
        public._revalidar_rondas_a_gogo_composicion_207(
            v_tournament_id,
            v_old_validation_ids,
            ARRAY[v_old_team_id,p_new_team_id]::uuid[],
            v_admin_id,
            p_reason,
            'team_reassignment',
            v_change_id
        );

    UPDATE public.tournament_team_composition_changes
       SET metadata=
           COALESCE(metadata,'{}'::jsonb) ||
           jsonb_build_object(
               'phase','207_FASE4C',
               'postValidation',true,
               'startValidationAffected',true,
               'startRevalidation',v_revalidation
           )
     WHERE id=v_change_id;

    RETURN v_base_result || jsonb_build_object(
        'postValidation',true,
        'startRevalidation',v_revalidation
    );
END;
$$;

REVOKE ALL ON FUNCTION public.reasignar_inscripcion_equipo_a_gogo_post_validacion(
    uuid,uuid,text
) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.reasignar_inscripcion_equipo_a_gogo_post_validacion(
    uuid,uuid,text
) TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 4. Wrapper JUGADOR:
--    confirmar sustitución después de validar.
--    Reutiliza íntegramente la RPC 202.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.confirmar_sustitucion_integrante_a_gogo_post_validacion(
    p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_request public.tournament_team_substitution_requests%ROWTYPE;
    v_admin_id uuid;
    v_old_validation_ids uuid[];
    v_base_result jsonb;
    v_revalidation jsonb;
    v_change_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT *
      INTO v_request
      FROM public.tournament_team_substitution_requests
     WHERE id=p_request_id
     FOR UPDATE;

    IF v_request.id IS NULL THEN
        RAISE EXCEPTION 'La solicitud de sustitución no existe.';
    END IF;

    IF v_request.status<>'pending_confirmation' THEN
        RAISE EXCEPTION
            'La sustitución ya no está pendiente de confirmación.';
    END IF;

    v_admin_id := v_request.requested_by_admin_id;

    IF NOT EXISTS(
        SELECT 1
        FROM public.admin_users au
        WHERE au.id=v_admin_id
          AND au.activo
    ) THEN
        RAISE EXCEPTION
            'El administrador que autorizó la sustitución ya no está activo.';
    END IF;

    IF EXISTS(
        SELECT 1
        FROM public.tournament_round_start_validations v
        WHERE v.tournament_id=v_request.tournament_id
          AND v.status='validated'
          AND (
              v.start_format IS DISTINCT FROM 'shotgun'
              OR v.participation_type IS DISTINCT FROM 'equipo'
              OR v.scoring_engine IS DISTINCT FROM 'team_stroke'
          )
    ) THEN
        RAISE EXCEPTION
            'Existe una ronda validada fuera del motor A-Go-Go Shotgun. Este flujo no puede modificarla.';
    END IF;

    SELECT COALESCE(array_agg(v.id ORDER BY v.tournament_round_id),ARRAY[]::uuid[])
      INTO v_old_validation_ids
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_id=v_request.tournament_id
       AND v.status='validated'
       AND v.start_format='shotgun'
       AND v.participation_type='equipo'
       AND v.scoring_engine='team_stroke';

    IF cardinality(v_old_validation_ids)=0 THEN
        RAISE EXCEPTION
            'No existen salidas validadas. Utiliza la confirmación de sustitución normal.';
    END IF;

    IF EXISTS(
        SELECT 1
        FROM public.tournament_score_card_emissions e
        JOIN public.tournament_round_start_validations v
          ON v.tournament_round_id=e.tournament_round_id
        WHERE v.id=ANY(v_old_validation_ids)
          AND e.status='issued'
    ) THEN
        RAISE EXCEPTION
            'Existe una ronda con tarjetas oficiales emitidas. La sustitución ya no puede aplicarse.';
    END IF;

    -- Históricas de forma atómica.
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
               'Sustitución A-Go-Go post-validación: ' ||
               btrim(v_request.reason)
     WHERE id=ANY(v_old_validation_ids);

    -- La función 202 conserva todas sus validaciones de identidad,
    -- disponibilidad, pago, roster e historial.
    v_base_result :=
        public.confirmar_sustitucion_integrante_a_gogo(
            p_request_id
        );

    v_change_id := NULLIF(v_base_result->>'changeId','')::uuid;

    IF v_change_id IS NULL THEN
        RAISE EXCEPTION
            'La sustitución no devolvió changeId.';
    END IF;

    v_revalidation :=
        public._revalidar_rondas_a_gogo_composicion_207(
            v_request.tournament_id,
            v_old_validation_ids,
            ARRAY[v_request.tournament_team_id]::uuid[],
            v_admin_id,
            v_request.reason,
            'player_substitution',
            v_change_id
        );

    UPDATE public.tournament_team_composition_changes
       SET metadata=
           COALESCE(metadata,'{}'::jsonb) ||
           jsonb_build_object(
               'phase','207_FASE4C',
               'postValidation',true,
               'startValidationAffected',true,
               'startRevalidation',v_revalidation
           )
     WHERE id=v_change_id;

    RETURN v_base_result || jsonb_build_object(
        'postValidation',true,
        'startRevalidation',v_revalidation
    );
END;
$$;

REVOKE ALL ON FUNCTION public.confirmar_sustitucion_integrante_a_gogo_post_validacion(
    uuid
) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.confirmar_sustitucion_integrante_a_gogo_post_validacion(
    uuid
) TO authenticated,service_role;

-- ----------------------------------------------------------------------------
-- 5. Consulta de historial para UI
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_revalidaciones_composicion_a_gogo(
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
            'No tienes permiso para consultar este historial.'
            USING ERRCODE='42501';
    END IF;

    RETURN COALESCE((
        SELECT jsonb_agg(
            jsonb_build_object(
                'id',r.id,
                'sourceType',r.source_type,
                'sourceId',r.source_id,
                'affectedTeamIds',to_jsonb(r.affected_team_ids),
                'oldValidationId',r.old_validation_id,
                'oldValidationVersion',r.old_validation_version,
                'newValidationId',r.new_validation_id,
                'newValidationVersion',r.new_validation_version,
                'reason',r.reason,
                'authorizedAdminId',r.authorized_admin_id,
                'createdAt',r.created_at
            )
            ORDER BY r.created_at DESC,r.id
        )
        FROM public.tournament_round_start_composition_revalidations r
        WHERE r.tournament_round_id=p_tournament_round_id
    ),'[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_revalidaciones_composicion_a_gogo(
    uuid
) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.obtener_revalidaciones_composicion_a_gogo(
    uuid
) TO authenticated,service_role;

COMMIT;
