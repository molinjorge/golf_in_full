-- 436-MIGRACION_ACTIVACION_TARDIA_TARJETA_DIGITAL_Y_QR_STABLEFORD_TEAM.sql
-- TEE CENTRAL / GOLF IN FULL
-- Objetivos:
-- 1) Permitir activar TARJETA DIGITAL (NO -> SI) aun con tarjetas ya emitidas,
--    siempre que el torneo todavia NO haya iniciado.
-- 2) Mantener bloqueado SI -> NO despues de la primera emision oficial.
-- 3) Hacer que el wrapper QR publico 426 adjunte digitalOperation tambien para
--    STABLEFORD_EQUIPO, reutilizando el core Stableford individual ya adaptado en 435C.
--
-- No anula ni reemite tarjetas, no rota qr_token, no modifica salidas, handicaps,
-- resultados ni motores deportivos.

BEGIN;

-- -----------------------------------------------------------------------------
-- A. Regla post-emision de TARJETA DIGITAL
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._proteger_tarjeta_digital_post_emision_422()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- Sin cambio: no hay nada que proteger.
    IF NEW.usar_tarjeta_digital
       IS NOT DISTINCT FROM OLD.usar_tarjeta_digital
    THEN
        RETURN NEW;
    END IF;

    -- Antes de la primera emision se conserva el comportamiento historico:
    -- el valor puede cambiar normalmente, sujeto a RLS/permisos del torneo.
    IF NOT EXISTS (
        SELECT 1
          FROM public.tournament_score_card_emissions e
         WHERE e.tournament_id = OLD.id
           AND e.status = 'issued'
    )
    THEN
        RETURN NEW;
    END IF;

    -- 436: si ya hubo emision, se permite EXCLUSIVAMENTE NO -> SI mientras
    -- el torneo siga en inscripcion_cerrada, es decir, antes de INICIAR TORNEO.
    -- Los qr_token ya emitidos se conservan y simplemente quedan habilitados
    -- por el interruptor maestro usar_tarjeta_digital.
    IF COALESCE(OLD.usar_tarjeta_digital, false) = false
       AND NEW.usar_tarjeta_digital = true
       AND OLD.estatus = 'inscripcion_cerrada'::public.estatus_torneo
    THEN
        RETURN NEW;
    END IF;

    -- Una vez emitidas las tarjetas no se permite apagar la captura digital,
    -- ni alterar esta configuracion despues de iniciado el torneo.
    RAISE EXCEPTION
        'No se puede cambiar esta configuración de TARJETA DIGITAL en el estado actual del torneo.'
        USING ERRCODE = '55000',
              HINT =
                'Después de emitir tarjetas sólo se permite activar TARJETA DIGITAL de NO a SÍ antes de iniciar el torneo. Una vez activada o iniciado el torneo, la configuración queda bloqueada.';
END;
$function$;

COMMENT ON FUNCTION public._proteger_tarjeta_digital_post_emision_422() IS
'436: protege TARJETA DIGITAL post-emisión. Permite únicamente NO->SI antes de iniciar torneo; mantiene bloqueado SI->NO y cualquier cambio posterior al inicio.';

-- -----------------------------------------------------------------------------
-- B. Wrapper QR Stableford: individual + STABLEFORD_EQUIPO
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_tarjeta_publica_qr_426(
    p_qr_token text,
    p_control_token text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_payload jsonb;
  v_card record;
  v_operation jsonb;
BEGIN
  v_payload := public.obtener_tarjeta_publica_qr_425(p_qr_token,p_control_token);

  IF COALESCE(v_payload->>'captureState','') IN ('invalid','digital_disabled','not_initialized') THEN
    RETURN v_payload;
  END IF;

  SELECT
      sc.id,
      sc.unit_type,
      v.scoring_engine,
      v.participation_type,
      rcs.format_code
    INTO v_card
    FROM public.tournament_score_cards sc
    JOIN public.tournament_round_start_validations v
      ON v.id=sc.validation_id
    LEFT JOIN public.tournament_round_condition_snapshots rcs
      ON rcs.id=v.round_condition_snapshot_id
   WHERE lower(sc.qr_token)=lower(p_qr_token)
     AND sc.status='issued'
   LIMIT 1;

  IF v_card.id IS NULL THEN
    RETURN jsonb_build_object('captureState','invalid');
  END IF;

  -- Stableford conserva tarjeta individual por jugador en ambas modalidades.
  -- Para STABLEFORD_EQUIPO la tarjeta sigue siendo registration y el resultado
  -- TEAM se calcula aparte; aqui solo exponemos la operacion individual.
  IF v_card.scoring_engine='stableford'
     AND v_card.unit_type='registration'
     AND (
       v_card.participation_type='individual'
       OR (
         v_card.participation_type='equipo'
         AND v_card.format_code='STABLEFORD_EQUIPO'
       )
     )
  THEN
    v_operation := public._obtener_operacion_stableford_tarjeta_core_426(
      v_card.id,
      false
    );

    v_payload := v_payload || jsonb_build_object(
      'digitalOperation',v_operation
    );
  END IF;

  RETURN v_payload;
END;
$function$;

COMMENT ON FUNCTION public.obtener_tarjeta_publica_qr_426(text,text) IS
'436: wrapper QR público Stableford para tarjetas registration individuales, incluyendo STABLEFORD_EQUIPO sin crear tarjeta ni QR de equipo.';

COMMIT;
