-- MIGRACIÓN 269
-- Corrección controlada de HCP post-freeze antes de START_TOURNAMENT.
-- NO ejecutar automáticamente. Aplicar manualmente después de revisar.
--
-- Objetivo:
-- 1) Permitir a un administrador autorizado corregir el HCP declarado de un
--    jugador ya inscrito en A-Go-Go TEAM después del freeze y antes del inicio.
-- 2) Conservar el snapshot del freeze como evidencia histórica.
-- 3) Recalcular HCP TEAM de los equipos/rondas afectados.
-- 4) Si había salidas validadas, reabrir y revalidar de forma atómica.
-- 5) Si había tarjetas emitidas, revisar/versionar las tarjetas TEAM existentes
--    reutilizando la infraestructura 215 y conservar el mismo score_card_id.
-- 6) Devolver las tarjetas VISUALMENTE afectadas para reimpresión.
--
-- Alcance deliberado:
-- - Sólo A-Go-Go / equipo / team_stroke.
-- - Sólo torneos congelados y todavía NO iniciados.
-- - Corrige handicap_declarado. Si existe handicap_verificado, se rechaza la
--   operación para no sobreescribir silenciosamente una verificación formal.
-- - No modifica snapshots del freeze.
-- - No modifica resultados ni scores.
-- - No resuelve sustituciones de jugadores; ése es un flujo separado.

BEGIN;

CREATE TABLE IF NOT EXISTS public.tournament_handicap_corrections (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    player_id uuid NOT NULL
        REFERENCES public.players(id) ON DELETE RESTRICT,
    tournament_team_id uuid NOT NULL
        REFERENCES public.tournament_teams(id) ON DELETE RESTRICT,
    old_handicap_declared numeric,
    new_handicap_declared numeric NOT NULL,
    old_handicap_declared_date date,
    new_handicap_declared_date date NOT NULL,
    reason text NOT NULL,
    changed_by_admin_id uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    freeze_id uuid NOT NULL
        REFERENCES public.tournament_condition_freezes(id) ON DELETE RESTRICT,
    affected_rounds jsonb NOT NULL DEFAULT '[]'::jsonb,
    affected_score_card_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tournament_handicap_corrections_reason_chk
        CHECK (length(btrim(reason)) >= 5)
);

CREATE INDEX IF NOT EXISTS idx_tournament_handicap_corrections_tournament
    ON public.tournament_handicap_corrections(tournament_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_tournament_handicap_corrections_player
    ON public.tournament_handicap_corrections(player_id, created_at DESC);

ALTER TABLE public.tournament_handicap_corrections ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_handicap_corrections FROM PUBLIC;
REVOKE ALL ON TABLE public.tournament_handicap_corrections FROM anon;
REVOKE ALL ON TABLE public.tournament_handicap_corrections FROM authenticated;
GRANT SELECT ON TABLE public.tournament_handicap_corrections TO service_role;
GRANT ALL ON TABLE public.tournament_handicap_corrections TO postgres;


CREATE OR REPLACE FUNCTION public.corregir_handicap_jugador_torneo_a_gogo_269(
    p_tournament_id uuid,
    p_player_id uuid,
    p_new_handicap numeric,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament public.tournaments%ROWTYPE;
    v_player public.players%ROWTYPE;
    v_reg public.tournament_registrations%ROWTYPE;
    v_team public.tournament_teams%ROWTYPE;
    v_admin_id uuid;
    v_freeze_id uuid;
    v_participation_type text;
    v_scoring_engine text;
    v_old_hcp numeric;
    v_old_hcp_date date;
    v_correction_id uuid;
    v_round record;
    v_old_validation public.tournament_round_start_validations%ROWTYPE;
    v_hcp_result jsonb;
    v_preview jsonb;
    v_validation_result jsonb;
    v_card_revision jsonb;
    v_rounds jsonb := '[]'::jsonb;
    v_affected_card_ids uuid[] := ARRAY[]::uuid[];
    v_card_id uuid;
    v_cards_were_issued boolean;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF length(btrim(COALESCE(p_reason,''))) < 5 THEN
        RAISE EXCEPTION
            'El motivo de la corrección debe contener al menos 5 caracteres.';
    END IF;

    SELECT *
      INTO v_tournament
      FROM public.tournaments
     WHERE id=p_tournament_id
       AND activo=true
     FOR UPDATE;

    IF v_tournament.id IS NULL THEN
        RAISE EXCEPTION 'El torneo no existe o está inactivo.';
    END IF;

    IF v_tournament.estatus IN (
        'en_curso'::public.estatus_torneo,
        'finalizado'::public.estatus_torneo
    ) THEN
        RAISE EXCEPTION
            'El torneo ya inició. El HCP competitivo ya no puede modificarse.'
            USING ERRCODE='55000';
    END IF;

    IF v_tournament.estatus='cancelado'::public.estatus_torneo THEN
        RAISE EXCEPTION
            'El torneo está cancelado y no admite correcciones competitivas.'
            USING ERRCODE='55000';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para corregir el HCP en este torneo.'
            USING ERRCODE='42501';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id=auth.uid()
       AND au.activo=true
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No existe administrador activo asociado al usuario autenticado.'
            USING ERRCODE='42501';
    END IF;

    SELECT tf.tipo_participacion::text,
           tf.scoring_engine::text
      INTO v_participation_type,
           v_scoring_engine
      FROM public.tournament_formats tf
     WHERE tf.id=v_tournament.tournament_format_id;

    IF v_participation_type IS DISTINCT FROM 'equipo'
       OR v_scoring_engine IS DISTINCT FROM 'team_stroke'
    THEN
        RAISE EXCEPTION
            'Esta corrección 269 sólo aplica a A-Go-Go TEAM/team_stroke.';
    END IF;

    SELECT f.id
      INTO v_freeze_id
      FROM public.tournament_condition_freezes f
     WHERE f.tournament_id=p_tournament_id
     ORDER BY f.frozen_at DESC
     LIMIT 1;

    IF v_freeze_id IS NULL THEN
        RAISE EXCEPTION
            'El torneo todavía no está congelado; utiliza la edición normal de HCP.';
    END IF;

    SELECT *
      INTO v_reg
      FROM public.tournament_registrations tr
     WHERE tr.tournament_id=p_tournament_id
       AND tr.player_id=p_player_id
       AND tr.activo=true
     FOR UPDATE;

    IF v_reg.id IS NULL THEN
        RAISE EXCEPTION
            'El jugador no tiene una inscripción activa en este torneo.';
    END IF;

    IF v_reg.tournament_team_id IS NULL THEN
        RAISE EXCEPTION
            'El jugador no pertenece a un equipo; no existe HCP TEAM que recalcular.';
    END IF;

    SELECT *
      INTO v_team
      FROM public.tournament_teams tt
     WHERE tt.id=v_reg.tournament_team_id
       AND tt.tournament_id=p_tournament_id
       AND tt.activo=true;

    IF v_team.id IS NULL THEN
        RAISE EXCEPTION 'El equipo del jugador no existe o está inactivo.';
    END IF;

    SELECT *
      INTO v_player
      FROM public.players p
     WHERE p.id=p_player_id
       AND p.activo=true
     FOR UPDATE;

    IF v_player.id IS NULL THEN
        RAISE EXCEPTION 'El jugador no existe o está inactivo.';
    END IF;

    IF v_player.handicap_verificado IS NOT NULL THEN
        RAISE EXCEPTION
            'El jugador tiene HCP verificado. La corrección 269 no lo sobreescribe automáticamente.'
            USING ERRCODE='55000';
    END IF;

    -- Serializa correcciones simultáneas del mismo jugador/torneo.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            p_tournament_id::text || ':hcp269:' || p_player_id::text,
            269
        )
    );

    v_old_hcp := v_player.handicap_declarado;
    v_old_hcp_date := v_player.handicap_declarado_fecha;

    IF v_old_hcp IS NOT DISTINCT FROM p_new_handicap THEN
        RAISE EXCEPTION
            'El nuevo HCP es igual al HCP declarado actual.';
    END IF;

    -- La validación global de rango sigue a cargo de trg_players_validate_handicap.
    UPDATE public.players
       SET handicap_declarado=p_new_handicap,
           handicap_declarado_fecha=current_date
     WHERE id=p_player_id;

    -- El trigger 204 marca automáticamente STALE el HCP TEAM vigente.
    INSERT INTO public.tournament_handicap_corrections(
        tournament_id,
        player_id,
        tournament_team_id,
        old_handicap_declared,
        new_handicap_declared,
        old_handicap_declared_date,
        new_handicap_declared_date,
        reason,
        changed_by_admin_id,
        freeze_id
    )
    VALUES(
        p_tournament_id,
        p_player_id,
        v_team.id,
        v_old_hcp,
        p_new_handicap,
        v_old_hcp_date,
        current_date,
        btrim(p_reason),
        v_admin_id,
        v_freeze_id
    )
    RETURNING id INTO v_correction_id;

    FOR v_round IN
        SELECT r.id, r.numero_ronda
          FROM public.tournament_rounds r
         WHERE r.tournament_id=p_tournament_id
           AND r.activo=true
         ORDER BY r.numero_ronda,r.fecha,r.id
    LOOP
        v_old_validation := NULL;
        v_validation_result := NULL;
        v_card_revision := NULL;
        v_cards_were_issued := false;

        SELECT *
          INTO v_old_validation
          FROM public.tournament_round_start_validations sv
         WHERE sv.tournament_round_id=v_round.id
           AND sv.status='validated'
         ORDER BY sv.version DESC
         LIMIT 1;

        IF v_old_validation.id IS NOT NULL THEN
            IF v_old_validation.start_format IS DISTINCT FROM 'shotgun'
               OR v_old_validation.participation_type IS DISTINCT FROM 'equipo'
               OR v_old_validation.scoring_engine IS DISTINCT FROM 'team_stroke'
            THEN
                RAISE EXCEPTION
                    'La ronda % tiene una validación fuera de A-Go-Go Shotgun TEAM.',
                    v_round.numero_ronda;
            END IF;

            IF public._ronda_esta_cerrada_competitivamente(v_round.id) THEN
                RAISE EXCEPTION
                    'La ronda % ya está cerrada competitivamente.',
                    v_round.numero_ronda
                    USING ERRCODE='55000';
            END IF;

            v_cards_were_issued :=
                public._ronda_tiene_tarjetas_emitidas(v_round.id);

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
                       'Corrección HCP post-freeze 269: ' || btrim(p_reason)
             WHERE id=v_old_validation.id;
        END IF;

        -- Recalcula SIEMPRE la ronda/equipo afectado desde HCP y roster actuales.
        v_hcp_result :=
            public.recalcular_handicap_equipo_a_gogo(
                v_round.id,
                v_team.id
            );

        IF v_old_validation.id IS NOT NULL THEN
            v_preview :=
                public.previsualizar_validacion_salidas_ronda(v_round.id);

            IF NOT COALESCE((v_preview->>'ready')::boolean,false) THEN
                RAISE EXCEPTION
                    'La corrección de HCP dejaría la ronda % no validable y fue revertida.',
                    v_round.numero_ronda
                    USING ERRCODE='23514',
                          DETAIL=(v_preview->'errors')::text;
            END IF;

            v_validation_result :=
                public.validar_salidas_ronda(v_round.id);

            IF v_cards_were_issued THEN
                -- Reutiliza la infraestructura 215. Conserva score_card_id y
                -- versiona snapshots/revisiones. El origen ya soportado es
                -- team_handicap_refresh.
                v_card_revision :=
                    public._revisar_tarjetas_team_ronda_post_emision_215(
                        v_round.id,
                        v_admin_id,
                        'team_handicap_refresh',
                        v_correction_id,
                        p_reason
                    );

                -- Para impresión sólo reportamos la tarjeta del equipo cuyo
                -- HCP cambió, aunque la revisión técnica repunte la emisión.
                SELECT sc.id
                  INTO v_card_id
                  FROM public.tournament_score_cards sc
                 WHERE sc.tournament_round_id=v_round.id
                   AND sc.tournament_team_id=v_team.id
                   AND sc.status='issued'
                   AND sc.unit_type='team'
                 ORDER BY sc.card_number,sc.id
                 LIMIT 1;

                IF v_card_id IS NOT NULL
                   AND NOT (v_card_id=ANY(v_affected_card_ids))
                THEN
                    v_affected_card_ids :=
                        array_append(v_affected_card_ids,v_card_id);
                END IF;
            END IF;
        END IF;

        v_rounds :=
            v_rounds || jsonb_build_array(
                jsonb_build_object(
                    'tournamentRoundId',v_round.id,
                    'roundNumber',v_round.numero_ronda,
                    'oldValidationId',v_old_validation.id,
                    'hadValidatedStarts',v_old_validation.id IS NOT NULL,
                    'hadIssuedCards',v_cards_were_issued,
                    'teamHandicap',v_hcp_result,
                    'validation',v_validation_result,
                    'cardRevision',v_card_revision
                )
            );
    END LOOP;

    UPDATE public.tournament_handicap_corrections
       SET affected_rounds=v_rounds,
           affected_score_card_ids=v_affected_card_ids
     WHERE id=v_correction_id;

    RETURN jsonb_build_object(
        'correctionId',v_correction_id,
        'tournamentId',p_tournament_id,
        'playerId',p_player_id,
        'teamId',v_team.id,
        'oldHandicap',v_old_hcp,
        'newHandicap',p_new_handicap,
        'rounds',v_rounds,
        'scoreCardsToReprint',to_jsonb(v_affected_card_ids),
        'freezeSnapshotPreserved',true,
        'tournamentStarted',false
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.corregir_handicap_jugador_torneo_a_gogo_269(
    uuid,uuid,numeric,text
) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.corregir_handicap_jugador_torneo_a_gogo_269(
    uuid,uuid,numeric,text
) FROM anon;

GRANT EXECUTE ON FUNCTION public.corregir_handicap_jugador_torneo_a_gogo_269(
    uuid,uuid,numeric,text
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.corregir_handicap_jugador_torneo_a_gogo_269(
    uuid,uuid,numeric,text
) TO service_role;

COMMIT;
