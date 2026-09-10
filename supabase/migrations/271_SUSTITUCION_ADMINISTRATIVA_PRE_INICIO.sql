-- ============================================================
-- MIGRACIÓN 271
-- Sustitución administrativa A-Go-Go antes de iniciar torneo
-- ============================================================
-- Objetivo:
--   Crear un contrato administrativo directo y auditable para
--   sustituir integrantes A-Go-Go después del freeze y SIEMPRE
--   antes de START_TOURNAMENT.
--
-- Reglas principales:
--   - Sólo A-Go-Go / equipo / team_stroke.
--   - Requiere freeze.
--   - Bloquea en_curso, finalizado y cancelado.
--   - No requiere login/confirmación del sustituto.
--   - No utiliza concepto de capitán.
--   - Reutiliza player por email o crea player mínimo en catálogo.
--   - Nueva inscripción con monto_pagado = 0 y cobertura heredada.
--   - Conserva cadena substitution_source_registration_id A -> B -> C.
--   - Marca de salida se captura explícitamente.
--   - Recalcula HCP TEAM.
--   - Si había salidas validadas: reabre y revalida.
--   - Si había tarjetas emitidas: revisa/versiona tarjetas con la
--     infraestructura existente de la Migración 215.
--   - Devuelve únicamente las tarjetas del equipo sustituido que
--     deben considerarse para reimpresión.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1. Helper transaccional: permite ajustar explícitamente la
--    marca de salida de una inscripción NUEVA de sustitución.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._a_gogo_substitution_tee_override_271()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $$
    SELECT COALESCE(
        current_setting(
            'app.a_gogo_substitution_tee_override_271',
            true
        ),
        ''
    ) = 'true';
$$;

REVOKE ALL ON FUNCTION public._a_gogo_substitution_tee_override_271()
FROM PUBLIC;

-- ------------------------------------------------------------
-- 2. Ajuste mínimo al guard de freeze:
--    conserva todas las protecciones existentes y sólo permite
--    cambiar marca de salida cuando:
--      * el override 271 está activo en la transacción;
--      * la fila es una inscripción creada por sustitución;
--      * el torneo es A-Go-Go/team_stroke;
--      * el torneo todavía NO inició;
--      * el usuario puede administrar el torneo.
-- ------------------------------------------------------------
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
    v_allow_substitution_insert boolean := false;
    v_allow_substitution_tee_update boolean := false;
    v_participation_type text;
    v_scoring_engine text;
    v_tournament_status text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT EXISTS (
            SELECT 1
            FROM public.tournament_condition_freezes f
            WHERE f.tournament_id = NEW.tournament_id
        )
        INTO v_torneo_congelado;

        IF v_torneo_congelado AND NEW.activo = true THEN

            IF public._a_gogo_substitution_override_202() THEN
                SELECT tf.tipo_participacion::text,
                       tf.scoring_engine::text
                  INTO v_participation_type,
                       v_scoring_engine
                  FROM public.tournaments t
                  JOIN public.tournament_formats tf
                    ON tf.id = t.tournament_format_id
                 WHERE t.id = NEW.tournament_id;

                v_allow_substitution_insert :=
                    v_participation_type = 'equipo'
                    AND v_scoring_engine = 'team_stroke'
                    AND NEW.substitution_source_registration_id IS NOT NULL;
            END IF;

            IF NOT v_allow_substitution_insert THEN
                RAISE EXCEPTION
                    'No se pueden agregar inscripciones activas: las condiciones y los participantes del torneo ya fueron congelados.'
                    USING ERRCODE = '55000',
                          HINT = 'Los casos excepcionales posteriores al congelamiento requieren un procedimiento explícito y auditado.';
            END IF;
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

        IF public._a_gogo_substitution_tee_override_271()
           AND OLD.substitution_source_registration_id IS NOT NULL
           AND NEW.substitution_source_registration_id
               IS NOT DISTINCT FROM OLD.substitution_source_registration_id
           AND NEW.player_id IS NOT DISTINCT FROM OLD.player_id
           AND NEW.tournament_team_id IS NOT DISTINCT FROM OLD.tournament_team_id
           AND NEW.activo IS NOT DISTINCT FROM OLD.activo
           AND public.puede_administrar_congelamiento_torneo(OLD.tournament_id)
        THEN
            SELECT tf.tipo_participacion::text,
                   tf.scoring_engine::text,
                   t.estatus::text
              INTO v_participation_type,
                   v_scoring_engine,
                   v_tournament_status
              FROM public.tournaments t
              JOIN public.tournament_formats tf
                ON tf.id = t.tournament_format_id
             WHERE t.id = OLD.tournament_id;

            v_allow_substitution_tee_update :=
                v_participation_type = 'equipo'
                AND v_scoring_engine = 'team_stroke'
                AND v_tournament_status NOT IN (
                    'en_curso',
                    'finalizado',
                    'cancelado'
                );
        END IF;

        IF NOT v_allow_substitution_tee_update THEN
            RAISE EXCEPTION
                'No se puede cambiar la marca de salida: las condiciones y hándicaps del torneo ya fueron congelados.'
                USING ERRCODE = '55000',
                      HINT = 'La marca efectiva válida es la guardada en los snapshots por ronda.';
        END IF;
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

-- ------------------------------------------------------------
-- 3. Consulta segura para el frontend:
--    localiza al candidato por email sin abrir SELECT directo.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_candidato_sustitucion_a_gogo_271(
    p_tournament_id uuid,
    p_email text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_email public.citext;
    v_player public.players%ROWTYPE;
    v_t public.tournaments%ROWTYPE;
    v_format record;
    v_available jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    v_email := NULLIF(lower(btrim(COALESCE(p_email,''))), '')::public.citext;

    IF v_email IS NULL THEN
        RAISE EXCEPTION 'Debes indicar el correo del sustituto.'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id
       AND activo = true;

    IF v_t.id IS NULL THEN
        RAISE EXCEPTION 'El torneo no existe o está inactivo.';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para administrar sustituciones de este torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tf.tipo_participacion::text AS tipo_participacion,
           tf.scoring_engine::text AS scoring_engine
      INTO v_format
      FROM public.tournament_formats tf
     WHERE tf.id = v_t.tournament_format_id;

    IF v_format.tipo_participacion IS DISTINCT FROM 'equipo'
       OR v_format.scoring_engine IS DISTINCT FROM 'team_stroke'
    THEN
        RAISE EXCEPTION
            'Este procedimiento sólo aplica a A-Go-Go/team_stroke.';
    END IF;

    IF v_t.estatus::text IN ('en_curso','finalizado','cancelado') THEN
        RAISE EXCEPTION
            'El torneo ya inició o terminó y no admite sustituciones.'
            USING ERRCODE = '55000';
    END IF;

    SELECT *
      INTO v_player
      FROM public.players p
     WHERE p.email = v_email
     LIMIT 1;

    -- Disponibilidad a nivel torneo. El team_id se deja NULL porque aún
    -- no necesitamos asumir el equipo en esta consulta de identidad.
    v_available :=
        public._validar_disponibilidad_integrante_199(
            p_tournament_id,
            NULL,
            v_email
        );

    RETURN jsonb_build_object(
        'email', v_email::text,
        'playerExists', v_player.id IS NOT NULL,
        'playerId', v_player.id,
        'active', CASE WHEN v_player.id IS NULL THEN NULL ELSE v_player.activo END,
        'name', CASE
                    WHEN v_player.id IS NULL THEN NULL
                    ELSE btrim(concat_ws(' ',v_player.nombres,v_player.apellidos))
                END,
        'nombres', v_player.nombres,
        'apellidos', v_player.apellidos,
        'sexo', CASE WHEN v_player.id IS NULL THEN NULL ELSE v_player.sexo::text END,
        'fechaNacimiento', v_player.fecha_nacimiento,
        'handicapDeclarado', v_player.handicap_declarado,
        'handicapVerificado', v_player.handicap_verificado,
        'telefonoPais', v_player.telefono_pais,
        'telefonoLada', v_player.telefono_lada,
        'telefonoNumero', v_player.telefono_numero,
        'availability', v_available,
        'requiresCatalogCreation', v_player.id IS NULL
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_candidato_sustitucion_a_gogo_271(uuid,text)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_candidato_sustitucion_a_gogo_271(uuid,text)
TO authenticated, service_role;

-- ------------------------------------------------------------
-- 4. RPC principal 271.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sustituir_jugador_a_gogo_271(
    p_outgoing_registration_id uuid,
    p_incoming_email text,
    p_reason text,
    p_marca_salida_id uuid,
    p_nombres text DEFAULT NULL,
    p_apellidos text DEFAULT NULL,
    p_sexo public.sexo_jugador DEFAULT NULL,
    p_fecha_nacimiento date DEFAULT NULL,
    p_handicap_declarado numeric DEFAULT NULL,
    p_telefono_pais text DEFAULT NULL,
    p_telefono_lada text DEFAULT NULL,
    p_telefono_numero text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old_reg public.tournament_registrations%ROWTYPE;
    v_new_reg public.tournament_registrations%ROWTYPE;
    v_t public.tournaments%ROWTYPE;
    v_team public.tournament_teams%ROWTYPE;
    v_player public.players%ROWTYPE;
    v_email public.citext;
    v_admin_id uuid;
    v_freeze_id uuid;
    v_format record;
    v_validation jsonb;
    v_request_id uuid;
    v_change_id uuid;
    v_old_slot_id uuid;
    v_new_slot_id uuid;
    v_created_player boolean := false;
    v_hcp_result jsonb;
    v_hcp_results jsonb := '[]'::jsonb;
    v_round record;
    v_old_validation_ids uuid[] := ARRAY[]::uuid[];
    v_old_validation record;
    v_validation_result jsonb;
    v_preview jsonb;
    v_revision_result jsonb;
    v_round_results jsonb := '[]'::jsonb;
    v_has_issued_cards boolean := false;
    v_score_cards_to_reprint uuid[] := ARRAY[]::uuid[];
BEGIN
    -- --------------------------------------------------------
    -- Seguridad y entrada.
    -- --------------------------------------------------------
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF length(btrim(COALESCE(p_reason,''))) < 5 THEN
        RAISE EXCEPTION
            'El motivo de la sustitución debe contener al menos 5 caracteres.'
            USING ERRCODE = '22023';
    END IF;

    v_email :=
        NULLIF(lower(btrim(COALESCE(p_incoming_email,''))), '')::public.citext;

    IF v_email IS NULL THEN
        RAISE EXCEPTION 'Debes indicar el correo del sustituto.'
            USING ERRCODE = '22023';
    END IF;

    IF p_marca_salida_id IS NULL THEN
        RAISE EXCEPTION 'Debes indicar la marca de salida del sustituto.'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
      INTO v_old_reg
      FROM public.tournament_registrations
     WHERE id = p_outgoing_registration_id
     FOR UPDATE;

    IF v_old_reg.id IS NULL OR NOT v_old_reg.activo THEN
        RAISE EXCEPTION
            'La inscripción saliente no existe o ya está inactiva.';
    END IF;

    IF v_old_reg.tournament_team_id IS NULL THEN
        RAISE EXCEPTION
            'La inscripción saliente no pertenece a un equipo.';
    END IF;

    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = v_old_reg.tournament_id
       AND activo = true
     FOR UPDATE;

    IF v_t.id IS NULL THEN
        RAISE EXCEPTION 'El torneo no existe o está inactivo.';
    END IF;

    -- START_TOURNAMENT es la frontera definitiva.
    IF v_t.estatus::text IN ('en_curso','finalizado','cancelado') THEN
        RAISE EXCEPTION
            'El torneo ya inició o terminó. La composición competitiva ya no puede modificarse.'
            USING ERRCODE = '55000';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_t.id) THEN
        RAISE EXCEPTION
            'No tienes permiso para sustituir integrantes de este torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo = true
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tf.tipo_participacion::text AS tipo_participacion,
           tf.scoring_engine::text AS scoring_engine
      INTO v_format
      FROM public.tournament_formats tf
     WHERE tf.id = v_t.tournament_format_id;

    IF v_format.tipo_participacion IS DISTINCT FROM 'equipo'
       OR v_format.scoring_engine IS DISTINCT FROM 'team_stroke'
    THEN
        RAISE EXCEPTION
            'Este procedimiento sólo aplica a A-Go-Go/team_stroke.';
    END IF;

    SELECT f.id
      INTO v_freeze_id
      FROM public.tournament_condition_freezes f
     WHERE f.tournament_id = v_t.id
     ORDER BY f.frozen_at DESC
     LIMIT 1;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION
            'El torneo todavía no está congelado; utiliza el flujo normal de composición.'
            USING ERRCODE = '55000';
    END IF;

    SELECT *
      INTO v_team
      FROM public.tournament_teams tt
     WHERE tt.id = v_old_reg.tournament_team_id
       AND tt.tournament_id = v_t.id
       AND tt.activo = true
     FOR UPDATE;

    IF v_team.id IS NULL THEN
        RAISE EXCEPTION 'El equipo ya no está activo.';
    END IF;

    -- Marca explícita válida para el campo principal del torneo.
    IF NOT EXISTS (
        SELECT 1
        FROM public.marcas_salida ms
        WHERE ms.id = p_marca_salida_id
          AND ms.campo_golf_id = v_t.campo_golf_id
          AND ms.activo = true
    ) THEN
        RAISE EXCEPTION
            'La marca de salida seleccionada no está activa o no pertenece al campo del torneo.'
            USING ERRCODE = '23514';
    END IF;

    -- Serializar sustitución + identidad por email.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(v_old_reg.id::text,271)
    );
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            v_t.id::text || ':sub271:' || lower(v_email::text),
            271
        )
    );
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'player-email:' || lower(v_email::text),
            271
        )
    );

    -- --------------------------------------------------------
    -- Identidad: reutilizar catálogo o crear player mínimo.
    -- --------------------------------------------------------
    SELECT *
      INTO v_player
      FROM public.players p
     WHERE p.email = v_email
     LIMIT 1
     FOR UPDATE;

    IF v_player.id IS NOT NULL THEN
        IF NOT v_player.activo THEN
            RAISE EXCEPTION
                'El correo corresponde a un jugador inactivo en el catálogo. Reactívalo antes de usarlo como sustituto.'
                USING ERRCODE = '55000';
        END IF;
    ELSE
        IF NULLIF(btrim(COALESCE(p_nombres,'')), '') IS NULL
           OR NULLIF(btrim(COALESCE(p_apellidos,'')), '') IS NULL
           OR p_sexo IS NULL
           OR p_fecha_nacimiento IS NULL
           OR p_handicap_declarado IS NULL
           OR NULLIF(btrim(COALESCE(p_telefono_pais,'')), '') IS NULL
           OR NULLIF(btrim(COALESCE(p_telefono_lada,'')), '') IS NULL
           OR NULLIF(btrim(COALESCE(p_telefono_numero,'')), '') IS NULL
        THEN
            RAISE EXCEPTION
                'El jugador no existe en catálogo. Debes capturar nombres, apellidos, sexo, fecha de nacimiento, HCP y teléfono completo.'
                USING ERRCODE = '22023';
        END IF;

        IF p_fecha_nacimiento >= CURRENT_DATE THEN
            RAISE EXCEPTION
                'La fecha de nacimiento debe ser anterior a la fecha actual.'
                USING ERRCODE = '23514';
        END IF;

        IF EXISTS (
            SELECT 1
            FROM public.players p
            WHERE p.telefono_pais = btrim(p_telefono_pais)
              AND p.telefono_lada = btrim(p_telefono_lada)
              AND p.telefono_numero = btrim(p_telefono_numero)
        ) THEN
            RAISE EXCEPTION
                'El teléfono indicado ya está asociado a otro jugador del catálogo.'
                USING ERRCODE = '23505';
        END IF;

        INSERT INTO public.players(
            email,
            nombres,
            apellidos,
            sexo,
            fecha_nacimiento,
            handicap_declarado,
            handicap_declarado_fecha,
            telefono_pais,
            telefono_lada,
            telefono_numero,
            created_by,
            activo
        )
        VALUES(
            v_email,
            btrim(p_nombres),
            btrim(p_apellidos),
            p_sexo,
            p_fecha_nacimiento,
            p_handicap_declarado,
            CURRENT_DATE,
            btrim(p_telefono_pais),
            btrim(p_telefono_lada),
            btrim(p_telefono_numero),
            v_admin_id,
            true
        )
        RETURNING * INTO v_player;

        v_created_player := true;
    END IF;

    -- El sustituto existente también debe tener perfil utilizable por
    -- el contrato actual de inscripción.
    PERFORM public.validar_perfil_completo_para_inscripcion(v_player.id);

    -- Disponibilidad real dentro del torneo/equipo.
    v_validation :=
        public._validar_disponibilidad_integrante_199(
            v_t.id,
            v_team.id,
            v_email
        );

    IF NOT COALESCE((v_validation->>'available')::boolean,false) THEN
        RAISE EXCEPTION '%', v_validation->>'message'
            USING ERRCODE = '23505',
                  DETAIL = COALESCE(
                      v_validation->>'code',
                      'MEMBER_NOT_AVAILABLE'
                  );
    END IF;

    -- No permitir sustituirse por sí mismo.
    IF v_player.id = v_old_reg.player_id THEN
        RAISE EXCEPTION
            'El jugador sustituto es el mismo jugador que se intenta dar de baja.'
            USING ERRCODE = '22023';
    END IF;

    -- --------------------------------------------------------
    -- Detectar estado operativo ANTES de mutar.
    -- --------------------------------------------------------
    SELECT COALESCE(
               array_agg(v.id ORDER BY v.tournament_round_id),
               ARRAY[]::uuid[]
           )
      INTO v_old_validation_ids
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_id = v_t.id
       AND v.status = 'validated'
       AND v.start_format = 'shotgun'
       AND v.participation_type = 'equipo'
       AND v.scoring_engine = 'team_stroke';

    IF EXISTS (
        SELECT 1
        FROM public.tournament_round_start_validations v
        WHERE v.tournament_id = v_t.id
          AND v.status = 'validated'
          AND (
               v.start_format IS DISTINCT FROM 'shotgun'
               OR v.participation_type IS DISTINCT FROM 'equipo'
               OR v.scoring_engine IS DISTINCT FROM 'team_stroke'
          )
    ) THEN
        RAISE EXCEPTION
            'Existe una validación activa fuera del motor A-Go-Go Shotgun. La sustitución fue bloqueada.'
            USING ERRCODE = '55000';
    END IF;

    v_has_issued_cards := EXISTS (
        SELECT 1
        FROM public.tournament_score_card_emissions e
        WHERE e.tournament_id = v_t.id
          AND e.status = 'issued'
    );

    IF v_has_issued_cards
       AND cardinality(v_old_validation_ids) = 0
    THEN
        RAISE EXCEPTION
            'Existen tarjetas emitidas pero no una validación A-Go-Go activa. La sustitución fue bloqueada para no dejar evidencia competitiva inconsistente.'
            USING ERRCODE = '55000';
    END IF;

    IF v_has_issued_cards THEN
        -- El guard de reapertura por tarjetas emitidas exige ambos.
        PERFORM set_config(
            'app.revisar_tarjeta_team_post_emision',
            'true',
            true
        );
    END IF;

    IF cardinality(v_old_validation_ids) > 0 THEN
        PERFORM set_config(
            'app.reabrir_validacion_salida_ronda',
            'true',
            true
        );

        UPDATE public.tournament_round_start_validations
           SET status = 'reopened',
               reopened_at = now(),
               reopened_by = v_admin_id,
               reopen_reason =
                   'Sustitución administrativa 271: ' || btrim(p_reason)
         WHERE id = ANY(v_old_validation_ids);
    END IF;

    -- --------------------------------------------------------
    -- Solicitud/auditoría de sustitución, ya confirmada por admin.
    -- --------------------------------------------------------
    INSERT INTO public.tournament_team_substitution_requests(
        tournament_id,
        tournament_team_id,
        outgoing_registration_id,
        outgoing_player_id,
        incoming_name,
        incoming_email,
        incoming_player_id,
        status,
        reason,
        payment_coverage_id,
        requested_by_admin_id,
        confirmed_at
    )
    VALUES(
        v_t.id,
        v_team.id,
        v_old_reg.id,
        v_old_reg.player_id,
        btrim(concat_ws(' ',v_player.nombres,v_player.apellidos)),
        v_email,
        v_player.id,
        'confirmed',
        btrim(p_reason),
        v_old_reg.team_payment_coverage_id,
        v_admin_id,
        now()
    )
    RETURNING id INTO v_request_id;

    -- --------------------------------------------------------
    -- Sustitución registral: A sale, B entra.
    -- --------------------------------------------------------
    UPDATE public.tournament_registrations
       SET activo = false,
           fecha_baja = now(),
           dado_de_baja_por = v_admin_id,
           motivo_baja =
               'Sustitución A-Go-Go administrativa 271. Solicitud ' ||
               v_request_id::text
     WHERE id = v_old_reg.id;

    SELECT rs.id
      INTO v_old_slot_id
      FROM public.tournament_team_roster_slots rs
     WHERE rs.tournament_registration_id = v_old_reg.id
     ORDER BY rs.created_at
     LIMIT 1;

    IF v_old_slot_id IS NOT NULL THEN
        UPDATE public.tournament_team_roster_slots
           SET status = 'cancelled',
               cancelled_at = now(),
               updated_at = now()
         WHERE id = v_old_slot_id;
    END IF;

    -- Permitir INSERT activo post-freeze sólo para sustitución auditada.
    PERFORM set_config(
        'app.a_gogo_substitution_override',
        'true',
        true
    );

    PERFORM set_config(
        'app.saltar_validacion_cupo_equipo',
        'true',
        true
    );

    INSERT INTO public.tournament_registrations(
        tournament_id,
        player_id,
        tournament_category_id,
        tournament_team_id,
        monto_pagado,
        fecha_pago,
        medio_pago,
        referencia_pago,
        team_payment_coverage_id,
        substitution_source_registration_id,
        created_by
    )
    VALUES(
        v_t.id,
        v_player.id,
        v_team.tournament_category_id,
        v_team.id,
        0,
        now(),
        v_old_reg.medio_pago,
        'SUST-271-' || v_request_id::text,
        v_old_reg.team_payment_coverage_id,
        v_old_reg.id,
        v_admin_id
    )
    RETURNING * INTO v_new_reg;

    -- El resolver existente puede proponer una marca automática.
    -- La 271 fija explícitamente la marca seleccionada por el admin.
    IF v_new_reg.marca_salida_id IS DISTINCT FROM p_marca_salida_id THEN
        PERFORM set_config(
            'app.a_gogo_substitution_tee_override_271',
            'true',
            true
        );

        UPDATE public.tournament_registrations
           SET marca_salida_id = p_marca_salida_id
         WHERE id = v_new_reg.id
         RETURNING * INTO v_new_reg;
    END IF;

    INSERT INTO public.tournament_team_roster_slots(
        tournament_id,
        tournament_team_id,
        role,
        nombre_completo,
        email,
        player_id,
        status,
        tournament_registration_id,
        invited_by_player_id,
        confirmed_at,
        payment_coverage_id,
        economically_covered_at
    )
    VALUES(
        v_t.id,
        v_team.id,
        'member',
        btrim(concat_ws(' ',v_player.nombres,v_player.apellidos)),
        v_email,
        v_player.id,
        'converted',
        v_new_reg.id,
        NULL,
        now(),
        v_old_reg.team_payment_coverage_id,
        CASE
            WHEN v_old_reg.team_payment_coverage_id IS NOT NULL
            THEN now()
            ELSE NULL
        END
    )
    RETURNING id INTO v_new_slot_id;

    UPDATE public.tournament_team_substitution_requests
       SET incoming_registration_id = v_new_reg.id,
           updated_at = now()
     WHERE id = v_request_id;

    INSERT INTO public.tournament_team_composition_changes(
        tournament_id,
        tournament_registration_id,
        player_id,
        replacement_player_id,
        change_type,
        old_team_id,
        new_team_id,
        reason,
        changed_by_admin_id,
        freeze_id,
        metadata
    )
    VALUES(
        v_t.id,
        v_old_reg.id,
        v_old_reg.player_id,
        v_player.id,
        'player_substitution',
        v_team.id,
        v_team.id,
        btrim(p_reason),
        v_admin_id,
        v_freeze_id,
        jsonb_build_object(
            'phase','271_ADMIN_PRE_START',
            'requestId',v_request_id,
            'postFreeze',true,
            'playerCreatedInCatalog',v_created_player,
            'incomingRegistrationId',v_new_reg.id,
            'oldRosterSlotId',v_old_slot_id,
            'newRosterSlotId',v_new_slot_id,
            'additionalCharge',0,
            'teamPaymentCoverageId',v_old_reg.team_payment_coverage_id,
            'selectedTeeId',p_marca_salida_id,
            'startTournamentBoundary',true
        )
    )
    RETURNING id INTO v_change_id;

    -- --------------------------------------------------------
    -- Rondas SIN validación activa: HCP TEAM debe quedar CURRENT.
    -- --------------------------------------------------------
    FOR v_round IN
        SELECT r.id
        FROM public.tournament_rounds r
        WHERE r.tournament_id = v_t.id
          AND r.activo = true
          AND NOT EXISTS (
              SELECT 1
              FROM public.tournament_round_start_validations ov
              WHERE ov.id = ANY(v_old_validation_ids)
                AND ov.tournament_round_id = r.id
          )
        ORDER BY r.numero_ronda,r.fecha,r.id
    LOOP
        v_hcp_result :=
            public.recalcular_handicap_equipo_a_gogo(
                v_round.id,
                v_team.id
            );

        v_hcp_results :=
            v_hcp_results || jsonb_build_array(
                jsonb_build_object(
                    'tournamentRoundId',v_round.id,
                    'handicap',v_hcp_result
                )
            );
    END LOOP;

    -- --------------------------------------------------------
    -- Rondas previamente validadas.
    -- --------------------------------------------------------
    IF cardinality(v_old_validation_ids) > 0 THEN

        IF NOT v_has_issued_cards THEN
            -- Reutiliza el helper común 207: HCP + preview + validación + audit.
            v_validation_result :=
                public._revalidar_rondas_a_gogo_composicion_207(
                    v_t.id,
                    v_old_validation_ids,
                    ARRAY[v_team.id]::uuid[],
                    v_admin_id,
                    p_reason,
                    'player_substitution',
                    v_change_id
                );

            v_round_results :=
                COALESCE(v_validation_result->'rounds','[]'::jsonb);

        ELSE
            -- Post-emisión: revalidar y revisar tarjetas con 215.
            FOR v_old_validation IN
                SELECT *
                FROM public.tournament_round_start_validations v
                WHERE v.id = ANY(v_old_validation_ids)
                ORDER BY v.tournament_round_id
            LOOP
                v_hcp_result :=
                    public.recalcular_handicap_equipo_a_gogo(
                        v_old_validation.tournament_round_id,
                        v_team.id
                    );

                v_preview :=
                    public.previsualizar_validacion_salidas_ronda(
                        v_old_validation.tournament_round_id
                    );

                IF NOT COALESCE((v_preview->>'ready')::boolean,false) THEN
                    RAISE EXCEPTION
                        'La sustitución dejaría la ronda no validable y fue revertida.'
                        USING ERRCODE = '23514',
                              DETAIL = (v_preview->'errors')::text;
                END IF;

                v_validation_result :=
                    public.validar_salidas_ronda(
                        v_old_validation.tournament_round_id
                    );

                v_revision_result :=
                    public._revisar_tarjetas_team_ronda_post_emision_215(
                        v_old_validation.tournament_round_id,
                        v_admin_id,
                        'player_substitution',
                        v_change_id,
                        p_reason
                    );

                v_round_results :=
                    v_round_results || jsonb_build_array(
                        jsonb_build_object(
                            'tournamentRoundId',
                                v_old_validation.tournament_round_id,
                            'oldValidationId',
                                v_old_validation.id,
                            'oldValidationVersion',
                                v_old_validation.version,
                            'handicap',
                                v_hcp_result,
                            'validation',
                                v_validation_result,
                            'cardRevision',
                                v_revision_result
                        )
                    );
            END LOOP;
        END IF;
    END IF;

    -- Tarjetas que realmente corresponden al TEAM modificado.
    IF v_has_issued_cards THEN
        SELECT COALESCE(array_agg(sc.id ORDER BY sc.id),ARRAY[]::uuid[])
          INTO v_score_cards_to_reprint
          FROM public.tournament_score_cards sc
          JOIN public.tournament_score_card_emissions e
            ON e.id = sc.emission_id
         WHERE sc.tournament_id = v_t.id
           AND sc.tournament_team_id = v_team.id
           AND sc.unit_type = 'team'
           AND sc.status = 'issued'
           AND e.status = 'issued';
    END IF;

    UPDATE public.tournament_team_composition_changes
       SET metadata =
           COALESCE(metadata,'{}'::jsonb) ||
           jsonb_build_object(
               'validatedRoundsAffected',
                   cardinality(v_old_validation_ids),
               'cardsWereIssued',
                   v_has_issued_cards,
               'roundRevisions',
                   v_round_results,
               'nonValidatedRoundHandicaps',
                   v_hcp_results,
               'scoreCardsToReprint',
                   to_jsonb(v_score_cards_to_reprint)
           )
     WHERE id = v_change_id;

    RETURN jsonb_build_object(
        'status','completed',
        'tournamentId',v_t.id,
        'teamId',v_team.id,
        'requestId',v_request_id,
        'changeId',v_change_id,
        'outgoingRegistrationId',v_old_reg.id,
        'outgoingPlayerId',v_old_reg.player_id,
        'incomingRegistrationId',v_new_reg.id,
        'incomingPlayerId',v_player.id,
        'playerCreatedInCatalog',v_created_player,
        'incomingTeeId',v_new_reg.marca_salida_id,
        'additionalCharge',0,
        'teamPaymentCoverageId',v_old_reg.team_payment_coverage_id,
        'validatedRoundsAffected',cardinality(v_old_validation_ids),
        'cardsWereIssued',v_has_issued_cards,
        'roundRevisions',v_round_results,
        'nonValidatedRoundHandicaps',v_hcp_results,
        'scoreCardsToReprint',to_jsonb(v_score_cards_to_reprint)
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.sustituir_jugador_a_gogo_271(
    uuid,text,text,uuid,text,text,public.sexo_jugador,date,numeric,text,text,text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.sustituir_jugador_a_gogo_271(
    uuid,text,text,uuid,text,text,public.sexo_jugador,date,numeric,text,text,text
) TO authenticated, service_role;

COMMIT;
