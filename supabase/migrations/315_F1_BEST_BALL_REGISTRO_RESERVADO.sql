BEGIN;

DO $$
DECLARE
    v_existing public.tournament_start_engine_registry%ROWTYPE;
BEGIN
    SELECT *
      INTO v_existing
      FROM public.tournament_start_engine_registry
     WHERE start_format::text = 'shotgun'
       AND participation_type = 'equipo'
       AND scoring_engine = 'best_ball';

    IF v_existing.id IS NULL THEN
        INSERT INTO public.tournament_start_engine_registry (
            start_format,
            participation_type,
            scoring_engine,
            preparation_engine,
            validation_engine,
            contract_version,
            activo,
            supports_scorecard_emission,
            scorecard_unit_type,
            scorecard_emission_engine,
            supports_start_validation,
            start_validation_handler
        )
        VALUES (
            'shotgun'::public.formato_salida_ronda,
            'equipo',
            'best_ball',
            'shotgun_team_v1',
            'best_ball_team_shotgun_v1',
            2,
            false,
            false,
            NULL,
            NULL,
            false,
            NULL
        );
    ELSE
        IF v_existing.preparation_engine IS DISTINCT FROM 'shotgun_team_v1'
           OR v_existing.validation_engine IS DISTINCT FROM 'best_ball_team_shotgun_v1'
           OR v_existing.contract_version IS DISTINCT FROM 2
           OR v_existing.activo IS DISTINCT FROM false
           OR v_existing.supports_scorecard_emission IS DISTINCT FROM false
           OR v_existing.scorecard_unit_type IS NOT NULL
           OR v_existing.scorecard_emission_engine IS NOT NULL
           OR v_existing.supports_start_validation IS DISTINCT FROM false
           OR v_existing.start_validation_handler IS NOT NULL
        THEN
            RAISE EXCEPTION
                'Ya existe un registro Best Ball Shotgun/equipo con un contrato distinto. No se modifica automáticamente.'
                USING ERRCODE = '23514',
                      DETAIL = to_jsonb(v_existing)::text;
        END IF;
    END IF;
END;
$$;

COMMIT;
