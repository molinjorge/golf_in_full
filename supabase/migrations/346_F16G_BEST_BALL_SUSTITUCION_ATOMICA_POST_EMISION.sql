-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 346
-- BEST BALL F16G — SUSTITUCION ATOMICA POST-FREEZE / PRE-INICIO
-- ============================================================================
-- OBJETIVO
--   Permitir una sustitución administrativa controlada de UN integrante
--   Best Ball después del Freeze, incluso si ya existen tarjetas emitidas,
--   sólo antes de iniciar las rondas Best Ball afectadas.
--
-- PRINCIPIOS
--   * NO abre la edición genérica de equipos post-Freeze.
--   * NO cambia el TEAM, grupo, hoyo ni salida Shotgun.
--   * NO crea HCP TEAM.
--   * El sustituto recibe snapshots individuales auditables para las rondas
--     Best Ball todavía PENDIENTES, usando las condiciones ya congeladas.
--   * Si una ronda Best Ball ya tiene tarjetas emitidas, la misma transacción
--     ejecuta la revisión 329; no existe una ventana con tarjeta desactualizada.
--   * score_card_id y folio se conservan.
--   * Cualquier error revierte TODA la sustitución.
--   * Stroke, Stableford y A-Go-Go permanecen fuera de alcance.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Bandera transaccional privada para la excepción Best Ball 346.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._best_ball_substitution_override_346()
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public','pg_temp'
AS $function$
  SELECT COALESCE(
    current_setting('app.best_ball_substitution_override_346', true),
    'false'
  ) = 'true';
$function$;

REVOKE ALL ON FUNCTION public._best_ball_substitution_override_346() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._best_ball_substitution_override_346() FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2) Freeze: conservar todas las reglas existentes y agregar UNA excepción
--    estrecha para INSERT de la nueva inscripción Best Ball auditada.
-- ---------------------------------------------------------------------------
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
    v_allow_best_ball_insert boolean := false;
    v_participation_type text;
    v_scoring_engine text;
    v_tournament_status text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT EXISTS (
            SELECT 1 FROM public.tournament_condition_freezes f
            WHERE f.tournament_id = NEW.tournament_id
        ) INTO v_torneo_congelado;

        IF v_torneo_congelado AND NEW.activo = true THEN
            IF public._a_gogo_substitution_override_202() THEN
                SELECT tf.tipo_participacion::text, tf.scoring_engine::text
                  INTO v_participation_type, v_scoring_engine
                  FROM public.tournaments t
                  JOIN public.tournament_formats tf ON tf.id=t.tournament_format_id
                 WHERE t.id=NEW.tournament_id;

                v_allow_substitution_insert :=
                    v_participation_type='equipo'
                    AND v_scoring_engine='team_stroke'
                    AND NEW.substitution_source_registration_id IS NOT NULL;
            END IF;

            IF public._best_ball_substitution_override_346()
               AND public.puede_administrar_congelamiento_torneo(NEW.tournament_id)
            THEN
                SELECT tf.tipo_participacion::text, tf.scoring_engine::text
                  INTO v_participation_type, v_scoring_engine
                  FROM public.tournaments t
                  JOIN public.tournament_formats tf ON tf.id=t.tournament_format_id
                 WHERE t.id=NEW.tournament_id;

                v_allow_best_ball_insert :=
                    v_participation_type='equipo'
                    AND v_scoring_engine='best_ball'
                    AND NEW.substitution_source_registration_id IS NOT NULL;
            END IF;

            IF NOT (v_allow_substitution_insert OR v_allow_best_ball_insert) THEN
                RAISE EXCEPTION
                    'No se pueden agregar inscripciones activas: las condiciones y los participantes del torneo ya fueron congelados.'
                    USING ERRCODE='55000',
                          HINT='Los casos excepcionales posteriores al congelamiento requieren un procedimiento explícito y auditado.';
            END IF;
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.tournament_id IS DISTINCT FROM OLD.tournament_id
       AND (
            EXISTS (SELECT 1 FROM public.tournament_condition_freezes f WHERE f.tournament_id=OLD.tournament_id)
            OR EXISTS (SELECT 1 FROM public.tournament_condition_freezes f WHERE f.tournament_id=NEW.tournament_id)
       ) THEN
        RAISE EXCEPTION 'No se puede cambiar de torneo una inscripción vinculada con un torneo congelado.'
            USING ERRCODE='55000';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM public.tournament_condition_freezes f
        WHERE f.tournament_id=OLD.tournament_id
    ) INTO v_torneo_congelado;

    IF NOT v_torneo_congelado THEN RETURN NEW; END IF;

    IF public._a_gogo_composition_override_201() THEN
        SELECT tf.tipo_participacion::text, tf.scoring_engine::text
          INTO v_participation_type,v_scoring_engine
          FROM public.tournaments t
          JOIN public.tournament_formats tf ON tf.id=t.tournament_format_id
         WHERE t.id=OLD.tournament_id;
        v_allow_team_override := v_participation_type='equipo' AND v_scoring_engine='team_stroke';
    END IF;

    IF NEW.player_id IS DISTINCT FROM OLD.player_id THEN
        RAISE EXCEPTION 'No se puede cambiar el jugador: la inscripción pertenece a un torneo congelado.' USING ERRCODE='55000';
    END IF;

    IF NEW.tournament_category_id IS DISTINCT FROM OLD.tournament_category_id THEN
        RAISE EXCEPTION
          'No se puede cambiar la categoría: las condiciones y hándicaps del torneo ya fueron congelados.'
          USING ERRCODE='55000', HINT='La categoría competitiva válida es la guardada en el snapshot del torneo.';
    END IF;

    IF NEW.marca_salida_id IS DISTINCT FROM OLD.marca_salida_id THEN
        IF public._a_gogo_substitution_tee_override_271()
           AND OLD.substitution_source_registration_id IS NOT NULL
           AND NEW.substitution_source_registration_id IS NOT DISTINCT FROM OLD.substitution_source_registration_id
           AND NEW.player_id IS NOT DISTINCT FROM OLD.player_id
           AND NEW.tournament_team_id IS NOT DISTINCT FROM OLD.tournament_team_id
           AND NEW.activo IS NOT DISTINCT FROM OLD.activo
           AND public.puede_administrar_congelamiento_torneo(OLD.tournament_id)
        THEN
            SELECT tf.tipo_participacion::text,tf.scoring_engine::text,t.estatus::text
              INTO v_participation_type,v_scoring_engine,v_tournament_status
              FROM public.tournaments t
              JOIN public.tournament_formats tf ON tf.id=t.tournament_format_id
             WHERE t.id=OLD.tournament_id;
            v_allow_substitution_tee_update :=
                v_participation_type='equipo'
                AND v_scoring_engine='team_stroke'
                AND v_tournament_status NOT IN ('en_curso','finalizado','cancelado');
        END IF;

        IF NOT v_allow_substitution_tee_update THEN
            RAISE EXCEPTION
              'No se puede cambiar la marca de salida: las condiciones y hándicaps del torneo ya fueron congelados.'
              USING ERRCODE='55000', HINT='La marca efectiva válida es la guardada en los snapshots por ronda.';
        END IF;
    END IF;

    IF NEW.tournament_team_id IS DISTINCT FROM OLD.tournament_team_id
       AND NOT v_allow_team_override THEN
        RAISE EXCEPTION
          'No se puede cambiar el equipo: la composición competitiva del torneo ya fue congelada.'
          USING ERRCODE='55000', HINT='En A-Go-Go use el procedimiento administrativo auditado de cambio de equipo.';
    END IF;

    IF OLD.activo=false AND NEW.activo=true THEN
        SELECT EXISTS (
            SELECT 1 FROM public.tournament_handicap_snapshots hs
            WHERE hs.tournament_id=OLD.tournament_id
              AND hs.tournament_registration_id=OLD.id
        ) INTO v_pertenece_snapshot;
        IF NOT v_pertenece_snapshot THEN
            RAISE EXCEPTION
              'No se puede reactivar esta inscripción porque no formó parte de los participantes congelados.'
              USING ERRCODE='55000', HINT='Los casos excepcionales posteriores al congelamiento requieren un procedimiento explícito y auditado.';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3) Guard de baja/reactivación con salida validada.
--    La excepción 346 sólo opera dentro de la sustitución auditada y para BB.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._proteger_estado_inscripcion_salida_validada()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_round_id uuid;
    v_is_best_ball_override boolean := false;
BEGIN
    IF NEW.activo IS NOT DISTINCT FROM OLD.activo THEN RETURN NEW; END IF;

    IF public._best_ball_substitution_override_346()
       AND public.puede_administrar_congelamiento_torneo(OLD.tournament_id)
    THEN
        SELECT EXISTS (
            SELECT 1
            FROM public.tournaments t
            JOIN public.tournament_formats tf ON tf.id=t.tournament_format_id
            WHERE t.id=OLD.tournament_id
              AND tf.tipo_participacion::text='equipo'
              AND tf.scoring_engine::text='best_ball'
        ) INTO v_is_best_ball_override;
    END IF;

    IF v_is_best_ball_override THEN RETURN NEW; END IF;

    FOR v_round_id IN
        SELECT DISTINCT rhs.tournament_round_id
        FROM public.tournament_round_handicap_snapshots rhs
        WHERE rhs.tournament_registration_id=OLD.id
        ORDER BY rhs.tournament_round_id
    LOOP
        PERFORM public._bloquear_salida_ronda(v_round_id);
        IF public._salida_ronda_esta_validada(v_round_id) THEN
            RAISE EXCEPTION
              'No puede retirarse ni reactivarse esta inscripción mientras tenga una salida de ronda validada.'
              USING ERRCODE='55000',
                    HINT='Reabra las salidas afectadas, realice la baja o reactivación y vuelva a validarlas.';
        END IF;
    END LOOP;
    RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4) Sustitución pública Best Ball.
--    Alcance deliberadamente estrecho: el jugador sustituto YA debe existir
--    en players. La creación de perfiles permanece en los flujos existentes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sustituir_jugador_best_ball_346(
    p_outgoing_registration_id uuid,
    p_incoming_player_id uuid,
    p_reason text,
    p_marca_salida_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_old_reg public.tournament_registrations%ROWTYPE;
    v_new_reg public.tournament_registrations%ROWTYPE;
    v_team public.tournament_teams%ROWTYPE;
    v_player public.players%ROWTYPE;
    v_freeze_id uuid;
    v_admin_id uuid;
    v_hs_id uuid;
    v_old_slot_id uuid;
    v_new_slot_id uuid;
    v_request_id uuid;
    v_change_id uuid;
    v_validation jsonb;
    v_round record;
    v_rcs public.tournament_round_condition_snapshots%ROWTYPE;
    v_ms public.marcas_salida%ROWTYPE;
    v_tto public.tournament_tee_overrides%ROWTYPE;
    v_course_rating numeric;
    v_slope integer;
    v_rating_source text;
    v_ch_unrounded numeric;
    v_course_hcp integer;
    v_playing_hcp integer;
    v_revision jsonb;
    v_revisions jsonb := '[]'::jsonb;
    v_pending_rounds integer:=0;
    v_issued_rounds integer:=0;
    v_snapshot_rounds integer:=0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_reason IS NULL OR length(btrim(p_reason))<10 THEN
        RAISE EXCEPTION 'El motivo de sustitución debe tener al menos 10 caracteres.' USING ERRCODE='22023';
    END IF;

    IF p_incoming_player_id IS NULL OR p_marca_salida_id IS NULL THEN
        RAISE EXCEPTION 'Debes indicar jugador sustituto y marca de salida.' USING ERRCODE='22023';
    END IF;

    SELECT * INTO v_old_reg
    FROM public.tournament_registrations
    WHERE id=p_outgoing_registration_id
    FOR UPDATE;

    IF v_old_reg.id IS NULL OR NOT v_old_reg.activo THEN
        RAISE EXCEPTION 'La inscripción saliente no existe o ya no está activa.' USING ERRCODE='22023';
    END IF;

    IF v_old_reg.tournament_team_id IS NULL THEN
        RAISE EXCEPTION 'La inscripción saliente no pertenece a un equipo.' USING ERRCODE='23514';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_old_reg.tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para sustituir integrantes Best Ball.' USING ERRCODE='42501';
    END IF;

    v_admin_id:=public._scorecard_current_admin_id();
    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No existe administrador activo asociado.' USING ERRCODE='42501';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(v_old_reg.tournament_id::text,346));

    SELECT * INTO v_team
    FROM public.tournament_teams
    WHERE id=v_old_reg.tournament_team_id
      AND tournament_id=v_old_reg.tournament_id
      AND activo=true
    FOR UPDATE;

    IF v_team.id IS NULL THEN
        RAISE EXCEPTION 'El equipo Best Ball ya no está activo.' USING ERRCODE='23514';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.tournaments t
        JOIN public.tournament_formats tf ON tf.id=t.tournament_format_id
        WHERE t.id=v_old_reg.tournament_id
          AND tf.tipo_participacion::text='equipo'
          AND tf.scoring_engine::text='best_ball'
    ) THEN
        RAISE EXCEPTION 'La sustitución 346 sólo aplica a torneos Best Ball por equipos.' USING ERRCODE='23514';
    END IF;

    SELECT id INTO v_freeze_id
    FROM public.tournament_condition_freezes
    WHERE tournament_id=v_old_reg.tournament_id
    ORDER BY frozen_at DESC,id DESC
    LIMIT 1;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION 'La sustitución 346 requiere que el torneo ya esté congelado.' USING ERRCODE='55000';
    END IF;

    SELECT * INTO v_player
    FROM public.players
    WHERE id=p_incoming_player_id AND activo=true
    FOR SHARE;

    IF v_player.id IS NULL THEN
        RAISE EXCEPTION 'El jugador sustituto no existe o está inactivo.' USING ERRCODE='22023';
    END IF;

    IF v_player.id=v_old_reg.player_id THEN
        RAISE EXCEPTION 'El jugador sustituto es el mismo jugador saliente.' USING ERRCODE='22023';
    END IF;

    PERFORM public.validar_perfil_completo_para_inscripcion(v_player.id);

    v_validation:=public._validar_disponibilidad_integrante_199(
        v_old_reg.tournament_id,
        v_team.id,
        v_player.email
    );
    IF NOT COALESCE((v_validation->>'available')::boolean,false) THEN
        RAISE EXCEPTION '%',COALESCE(v_validation->>'message','El jugador sustituto no está disponible para este equipo.')
          USING ERRCODE='23505',DETAIL=COALESCE(v_validation->>'code','MEMBER_NOT_AVAILABLE');
    END IF;

    SELECT * INTO v_ms
    FROM public.marcas_salida
    WHERE id=p_marca_salida_id AND activo=true;
    IF v_ms.id IS NULL THEN
        RAISE EXCEPTION 'La marca de salida indicada no existe o está inactiva.' USING ERRCODE='22023';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.tournaments t
        WHERE t.id=v_old_reg.tournament_id
          AND t.campo_golf_id IS DISTINCT FROM v_ms.campo_golf_id
    ) THEN
        RAISE EXCEPTION 'La marca de salida no pertenece al campo del torneo.' USING ERRCODE='23514';
    END IF;

    -- Ninguna ronda Best Ball puede estar EN JUEGO. Las FINALIZADAS quedan
    -- históricas y no se modifican; las PENDIENTES reciben el nuevo snapshot.
    IF EXISTS (
        SELECT 1
        FROM public.tournament_rounds r
        JOIN public.tournaments t ON t.id=r.tournament_id
        JOIN public.tournament_formats tf ON tf.id=COALESCE(r.tournament_format_id,t.tournament_format_id)
        WHERE r.tournament_id=v_old_reg.tournament_id
          AND r.activo=true
          AND tf.scoring_engine::text='best_ball'
          AND (public.obtener_estado_operativo_ronda_314(r.id)->>'status')='EN_JUEGO'
    ) THEN
        RAISE EXCEPTION 'No puede sustituirse un integrante Best Ball mientras exista una ronda Best Ball EN JUEGO.' USING ERRCODE='55000';
    END IF;

    SELECT count(*) INTO v_pending_rounds
    FROM public.tournament_rounds r
    JOIN public.tournaments t ON t.id=r.tournament_id
    JOIN public.tournament_formats tf ON tf.id=COALESCE(r.tournament_format_id,t.tournament_format_id)
    WHERE r.tournament_id=v_old_reg.tournament_id
      AND r.activo=true
      AND tf.scoring_engine::text='best_ball'
      AND (public.obtener_estado_operativo_ronda_314(r.id)->>'status')='PENDIENTE';

    IF v_pending_rounds=0 THEN
        RAISE EXCEPTION 'No existen rondas Best Ball PENDIENTES donde aplicar la sustitución.' USING ERRCODE='55000';
    END IF;

    -- Si alguna ronda emitida pendiente ya tiene evidencia, 329 la bloquearía;
    -- se valida antes de mutar para producir un error temprano y claro.
    FOR v_round IN
        SELECT r.id
        FROM public.tournament_rounds r
        JOIN public.tournaments t ON t.id=r.tournament_id
        JOIN public.tournament_formats tf ON tf.id=COALESCE(r.tournament_format_id,t.tournament_format_id)
        WHERE r.tournament_id=v_old_reg.tournament_id
          AND r.activo=true
          AND tf.scoring_engine::text='best_ball'
          AND (public.obtener_estado_operativo_ronda_314(r.id)->>'status')='PENDIENTE'
          AND EXISTS (
              SELECT 1 FROM public.tournament_score_card_emissions e
              WHERE e.tournament_round_id=r.id AND e.status='issued' AND e.voided_at IS NULL
          )
        ORDER BY r.numero_ronda,r.id
    LOOP
        IF EXISTS (
            SELECT 1
            FROM public.tournament_best_ball_hole_scores hs
            JOIN public.tournament_score_cards sc ON sc.id=hs.score_card_id
            JOIN public.tournament_score_card_emissions e ON e.id=sc.emission_id
            WHERE e.tournament_round_id=v_round.id
              AND e.status='issued'
              AND (
                hs.status IS DISTINCT FROM 'pending'
                OR hs.result_type IS DISTINCT FROM 'PENDING'
                OR hs.gross_score IS NOT NULL
                OR hs.entered_by_player_id IS NOT NULL
                OR hs.entered_at IS NOT NULL
              )
        ) OR EXISTS (
            SELECT 1 FROM public.tournament_scorecard_physical_receptions pr
            JOIN public.tournament_score_cards sc ON sc.id=pr.score_card_id
            JOIN public.tournament_score_card_emissions e ON e.id=sc.emission_id
            WHERE e.tournament_round_id=v_round.id AND e.status='issued'
        ) OR EXISTS (
            SELECT 1 FROM public.tournament_scorecard_reconciliations rc
            JOIN public.tournament_score_cards sc ON sc.id=rc.score_card_id
            JOIN public.tournament_score_card_emissions e ON e.id=sc.emission_id
            WHERE e.tournament_round_id=v_round.id AND e.status='issued'
        ) THEN
            RAISE EXCEPTION 'La sustitución fue bloqueada porque una ronda Best Ball pendiente ya tiene evidencia deportiva.' USING ERRCODE='55000';
        END IF;
    END LOOP;

    -- Habilitar exclusivamente esta transacción para baja/alta post-Freeze.
    PERFORM set_config('app.best_ball_substitution_override_346','true',true);
    PERFORM set_config('app.saltar_validacion_cupo_equipo','true',true);

    -- Auditoría de solicitud confirmada.
    INSERT INTO public.tournament_team_substitution_requests(
        tournament_id,tournament_team_id,outgoing_registration_id,outgoing_player_id,
        incoming_name,incoming_email,incoming_player_id,status,reason,payment_coverage_id,
        requested_by_admin_id,confirmed_at
    ) VALUES (
        v_old_reg.tournament_id,v_team.id,v_old_reg.id,v_old_reg.player_id,
        btrim(concat_ws(' ',v_player.nombres,v_player.apellidos)),v_player.email,v_player.id,
        'confirmed',btrim(p_reason),v_old_reg.team_payment_coverage_id,v_admin_id,now()
    ) RETURNING id INTO v_request_id;

    UPDATE public.tournament_registrations
       SET activo=false,
           fecha_baja=now(),
           dado_de_baja_por=v_admin_id,
           motivo_baja='Sustitución Best Ball administrativa 346. Solicitud '||v_request_id::text
     WHERE id=v_old_reg.id;

    SELECT rs.id INTO v_old_slot_id
    FROM public.tournament_team_roster_slots rs
    WHERE rs.tournament_registration_id=v_old_reg.id
    ORDER BY rs.created_at
    LIMIT 1;

    IF v_old_slot_id IS NOT NULL THEN
        UPDATE public.tournament_team_roster_slots
           SET status='cancelled',cancelled_at=now(),updated_at=now()
         WHERE id=v_old_slot_id;
    END IF;

    INSERT INTO public.tournament_registrations(
        tournament_id,player_id,tournament_category_id,tournament_team_id,
        marca_salida_id,monto_pagado,fecha_pago,medio_pago,referencia_pago,
        team_payment_coverage_id,substitution_source_registration_id,created_by,estado_pago
    ) VALUES (
        v_old_reg.tournament_id,v_player.id,v_team.tournament_category_id,v_team.id,
        p_marca_salida_id,0,now(),v_old_reg.medio_pago,
        'SUST-BB-346-'||v_request_id::text,
        v_old_reg.team_payment_coverage_id,v_old_reg.id,v_admin_id,v_old_reg.estado_pago
    ) RETURNING * INTO v_new_reg;

    -- El resolver de inscripción puede aplicar reglas existentes; para 346 la
    -- marca seleccionada por el admin debe coincidir con la efectiva final.
    IF v_new_reg.marca_salida_id IS DISTINCT FROM p_marca_salida_id THEN
        RAISE EXCEPTION 'La marca de salida efectiva del sustituto no coincide con la seleccionada. La sustitución fue revertida.' USING ERRCODE='23514';
    END IF;

    INSERT INTO public.tournament_team_roster_slots(
        tournament_id,tournament_team_id,role,nombre_completo,email,player_id,status,
        tournament_registration_id,invited_by_player_id,confirmed_at,payment_coverage_id,
        economically_covered_at
    ) VALUES (
        v_old_reg.tournament_id,v_team.id,'member',
        btrim(concat_ws(' ',v_player.nombres,v_player.apellidos)),v_player.email,v_player.id,
        'converted',v_new_reg.id,NULL,now(),v_old_reg.team_payment_coverage_id,
        CASE WHEN v_old_reg.team_payment_coverage_id IS NOT NULL THEN now() ELSE NULL END
    ) RETURNING id INTO v_new_slot_id;

    UPDATE public.tournament_team_substitution_requests
       SET incoming_registration_id=v_new_reg.id,updated_at=now()
     WHERE id=v_request_id;

    -- Snapshot base individual excepcional, ligado al mismo Freeze.
    IF COALESCE(v_player.handicap_verificado,v_player.handicap_declarado) IS NULL THEN
        RAISE EXCEPTION 'El jugador sustituto no tiene Handicap Index disponible.' USING ERRCODE='23514';
    END IF;

    INSERT INTO public.tournament_handicap_snapshots(
        freeze_id,tournament_id,tournament_registration_id,player_id,tournament_category_id,tee_id,
        registration_folio,player_name,category_name,tee_name,player_sex,
        handicap_index,handicap_source,handicap_source_date,handicap_status,
        player_updated_at_source,registration_updated_at_source
    )
    VALUES (
        v_freeze_id,v_old_reg.tournament_id,v_new_reg.id,v_player.id,
        v_new_reg.tournament_category_id,v_new_reg.marca_salida_id,v_new_reg.folio,
        btrim(concat_ws(' ',v_player.nombres,v_player.apellidos)),
        (SELECT c.nombre
           FROM public.tournament_categories tc
           JOIN public.categories c ON c.id=tc.category_id
          WHERE tc.id=v_new_reg.tournament_category_id),
        v_ms.nombre,v_player.sexo::text,
        COALESCE(v_player.handicap_verificado,v_player.handicap_declarado),
        CASE WHEN v_player.handicap_verificado IS NOT NULL THEN 'verified' ELSE 'declared' END,
        CASE WHEN v_player.handicap_verificado IS NOT NULL THEN v_player.handicap_verificado_fecha ELSE v_player.handicap_declarado_fecha END,
        v_player.handicap_estatus::text,v_player.updated_at,v_new_reg.updated_at
    )
    RETURNING id INTO v_hs_id;

    IF v_hs_id IS NULL THEN
        RAISE EXCEPTION 'No pudo construirse el snapshot base del sustituto Best Ball.' USING ERRCODE='55000';
    END IF;

    -- Snapshots individuales sólo para rondas Best Ball todavía PENDIENTES.
    FOR v_round IN
        SELECT r.id,r.numero_ronda
        FROM public.tournament_rounds r
        JOIN public.tournaments t ON t.id=r.tournament_id
        JOIN public.tournament_formats tf ON tf.id=COALESCE(r.tournament_format_id,t.tournament_format_id)
        WHERE r.tournament_id=v_old_reg.tournament_id
          AND r.activo=true
          AND tf.scoring_engine::text='best_ball'
          AND (public.obtener_estado_operativo_ronda_314(r.id)->>'status')='PENDIENTE'
        ORDER BY r.numero_ronda,r.id
    LOOP
        SELECT * INTO v_rcs
        FROM public.tournament_round_condition_snapshots
        WHERE freeze_id=v_freeze_id AND tournament_round_id=v_round.id;

        IF v_rcs.id IS NULL OR v_rcs.handicap_allowance_pct IS NULL THEN
            RAISE EXCEPTION 'La ronda Best Ball % no tiene condiciones/HCP congelados válidos.',v_round.numero_ronda USING ERRCODE='55000';
        END IF;

        SELECT * INTO v_tto
        FROM public.tournament_tee_overrides
        WHERE tournament_id=v_old_reg.tournament_id AND marca_salida_id=p_marca_salida_id;

        IF v_player.sexo::text='F' THEN
            v_course_rating:=COALESCE(v_tto.rating_damas,v_ms.rating_damas);
            v_slope:=COALESCE(v_tto.slope_damas,v_ms.slope_damas);
            v_rating_source:=CASE WHEN v_tto.rating_damas IS NOT NULL OR v_tto.slope_damas IS NOT NULL THEN 'tournament_override' ELSE 'tee' END;
        ELSE
            v_course_rating:=COALESCE(v_tto.rating_caballeros,v_ms.rating_caballeros);
            v_slope:=COALESCE(v_tto.slope_caballeros,v_ms.slope_caballeros);
            v_rating_source:=CASE WHEN v_tto.rating_caballeros IS NOT NULL OR v_tto.slope_caballeros IS NOT NULL THEN 'tournament_override' ELSE 'tee' END;
        END IF;

        IF v_course_rating IS NULL OR v_slope IS NULL THEN
            RAISE EXCEPTION 'La marca seleccionada no tiene Course Rating/Slope válido para el jugador sustituto.' USING ERRCODE='23514';
        END IF;

        v_ch_unrounded:=public.calcular_course_handicap_sin_redondear(
            COALESCE(v_player.handicap_verificado,v_player.handicap_declarado),
            v_slope,v_course_rating,v_rcs.course_par
        );
        v_course_hcp:=public.redondear_handicap_whs(v_ch_unrounded);
        v_playing_hcp:=public.calcular_playing_handicap(v_ch_unrounded,v_rcs.handicap_allowance_pct);

        INSERT INTO public.tournament_round_handicap_snapshots(
            freeze_id,tournament_id,round_condition_snapshot_id,handicap_snapshot_id,
            tournament_round_id,tournament_registration_id,player_id,tee_id,
            course_rating,slope_rating,rating_source,course_par,handicap_allowance_pct,
            course_handicap_unrounded,course_handicap,playing_handicap
        ) VALUES (
            v_freeze_id,v_old_reg.tournament_id,v_rcs.id,v_hs_id,
            v_round.id,v_new_reg.id,v_player.id,p_marca_salida_id,
            v_course_rating,v_slope,v_rating_source,v_rcs.course_par,v_rcs.handicap_allowance_pct,
            v_ch_unrounded,v_course_hcp,v_playing_hcp
        );
        v_snapshot_rounds:=v_snapshot_rounds+1;
    END LOOP;

    INSERT INTO public.tournament_team_composition_changes(
        tournament_id,tournament_registration_id,player_id,replacement_player_id,
        change_type,old_team_id,new_team_id,reason,changed_by_admin_id,freeze_id,metadata
    ) VALUES (
        v_old_reg.tournament_id,v_old_reg.id,v_old_reg.player_id,v_player.id,
        'player_substitution',v_team.id,v_team.id,btrim(p_reason),v_admin_id,v_freeze_id,
        jsonb_build_object(
            'phase','346_BEST_BALL_POST_FREEZE_PRE_START',
            'requestId',v_request_id,
            'incomingRegistrationId',v_new_reg.id,
            'oldRosterSlotId',v_old_slot_id,
            'newRosterSlotId',v_new_slot_id,
            'selectedTeeId',p_marca_salida_id,
            'pendingBestBallRounds',v_pending_rounds,
            'roundHandicapSnapshotsCreated',v_snapshot_rounds,
            'atomicCardReview',true
        )
    ) RETURNING id INTO v_change_id;

    -- Si ya hay tarjetas emitidas, 329 las sincroniza dentro de ESTA MISMA
    -- transacción. Si falla, también se revierten inscripción y snapshots.
    FOR v_round IN
        SELECT r.id,r.numero_ronda
        FROM public.tournament_rounds r
        JOIN public.tournaments t ON t.id=r.tournament_id
        JOIN public.tournament_formats tf ON tf.id=COALESCE(r.tournament_format_id,t.tournament_format_id)
        WHERE r.tournament_id=v_old_reg.tournament_id
          AND r.activo=true
          AND tf.scoring_engine::text='best_ball'
          AND (public.obtener_estado_operativo_ronda_314(r.id)->>'status')='PENDIENTE'
          AND EXISTS (
              SELECT 1 FROM public.tournament_score_card_emissions e
              WHERE e.tournament_round_id=r.id AND e.status='issued' AND e.voided_at IS NULL
          )
        ORDER BY r.numero_ronda,r.id
    LOOP
        v_revision:=public.revisar_tarjetas_best_ball_post_emision_329(v_round.id,btrim(p_reason));
        v_revisions:=v_revisions || jsonb_build_array(
            jsonb_build_object('roundId',v_round.id,'roundNumber',v_round.numero_ronda,'review',v_revision)
        );
        v_issued_rounds:=v_issued_rounds+1;
    END LOOP;

    UPDATE public.tournament_team_composition_changes
       SET metadata=metadata || jsonb_build_object(
           'issuedBestBallRoundsReviewed',v_issued_rounds,
           'cardReviews',v_revisions
       )
     WHERE id=v_change_id;

    RETURN jsonb_build_object(
        'status','completed',
        'engine','best_ball',
        'tournamentId',v_old_reg.tournament_id,
        'teamId',v_team.id,
        'requestId',v_request_id,
        'changeId',v_change_id,
        'outgoingRegistrationId',v_old_reg.id,
        'outgoingPlayerId',v_old_reg.player_id,
        'incomingRegistrationId',v_new_reg.id,
        'incomingPlayerId',v_player.id,
        'incomingTeeId',p_marca_salida_id,
        'pendingRoundsUpdated',v_snapshot_rounds,
        'issuedRoundsReviewed',v_issued_rounds,
        'cardReviews',v_revisions,
        'sameTeamId',true,
        'cardsRemainIssued',true,
        'requiresReprint',v_issued_rounds>0
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.sustituir_jugador_best_ball_346(uuid,uuid,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sustituir_jugador_best_ball_346(uuid,uuid,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sustituir_jugador_best_ball_346(uuid,uuid,text,uuid) TO service_role;

COMMENT ON FUNCTION public.sustituir_jugador_best_ball_346(uuid,uuid,text,uuid) IS
'Best Ball 346: sustitución administrativa atómica post-Freeze/pre-inicio. Conserva TEAM y tarjetas; crea snapshots individuales del sustituto y revisa tarjetas emitidas mediante 329.';

COMMIT;
