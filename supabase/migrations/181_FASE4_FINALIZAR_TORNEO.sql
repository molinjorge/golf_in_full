-- ============================================================================
-- 181_FASE4_FINALIZAR_TORNEO.sql
-- TEE CENTRAL
--
-- OBJETIVOS
-- 1) Formalizar la transición manual:
--      en_curso -> finalizado
-- 2) Hacerla agnóstica a modalidad/formato:
--      NO inspecciona Stroke/Stableford/equipos/Shotgun/tee time.
--      Sólo exige cierre formal de TODAS las rondas activas.
-- 3) Persistir un sello auditable e inmutable de finalización del torneo.
-- 4) Exponer preview server-side para que UI sepa exactamente qué falta.
--
-- DEPENDENCIA:
-- - Migración 181 Fase 3:
--   public.tournament_round_competitive_closures
--
-- NO IMPLEMENTA:
-- - reapertura de torneo finalizado
-- - cambio automático por fecha
-- - cálculo específico por modalidad
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. TABLA DE FINALIZACIÓN FORMAL DEL TORNEO
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.tournament_competitive_finalizations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id),

    status text NOT NULL
        DEFAULT 'FINAL'
        CHECK (status = 'FINAL'),

    finalization_snapshot jsonb NOT NULL,

    finalized_at timestamptz NOT NULL DEFAULT now(),
    finalized_by_admin_user_id uuid NOT NULL
        REFERENCES public.admin_users(id),

    notes text,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_tournament_competitive_finalization
        UNIQUE (tournament_id)
);

-- ============================================================================
-- 02. RLS / PRIVILEGIOS DE LA TABLA
-- ============================================================================
ALTER TABLE public.tournament_competitive_finalizations
ENABLE ROW LEVEL SECURITY;

REVOKE ALL
ON TABLE public.tournament_competitive_finalizations
FROM PUBLIC, anon, authenticated;

GRANT ALL
ON TABLE public.tournament_competitive_finalizations
TO service_role;

-- ============================================================================
-- 03. INMUTABILIDAD DEL SELLO
-- ============================================================================
CREATE OR REPLACE FUNCTION public.impedir_mutacion_finalizacion_torneo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION
        'La finalización competitiva del torneo es histórica e inmutable.'
        USING ERRCODE = '55000',
              HINT =
                  'Un torneo FINALIZADO no se reabre por actualización directa. Cualquier excepción futura deberá diseñarse como una operación extraordinaria y auditada.';
END;
$function$;

DROP TRIGGER IF EXISTS
trg_impedir_mutacion_finalizacion_torneo
ON public.tournament_competitive_finalizations;

CREATE TRIGGER trg_impedir_mutacion_finalizacion_torneo
BEFORE UPDATE OR DELETE
ON public.tournament_competitive_finalizations
FOR EACH ROW
EXECUTE FUNCTION public.impedir_mutacion_finalizacion_torneo();

-- ============================================================================
-- 04. PREVIEW DE FINALIZACIÓN
--
-- Es deliberadamente genérico:
-- una ronda activa está lista si existe su cierre formal de Fase 3.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.previsualizar_finalizacion_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
    v_existing public.tournament_competitive_finalizations%ROWTYPE;
    v_total_rounds integer := 0;
    v_closed_rounds integer := 0;
    v_pending_rounds integer := 0;
    v_rounds jsonb := '[]'::jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(
            auth.uid(),
            p_tournament_id
        )
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden consultar la finalización del torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
      INTO v_existing
      FROM public.tournament_competitive_finalizations f
     WHERE f.tournament_id = p_tournament_id;

    SELECT
        count(*)::integer,
        count(*) FILTER (
            WHERE c.id IS NOT NULL
              AND c.competitive_status = 'FINAL'
        )::integer,
        count(*) FILTER (
            WHERE c.id IS NULL
               OR c.competitive_status <> 'FINAL'
        )::integer,
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'tournamentRoundId', tr.id,
                    'roundNumber', tr.numero_ronda,
                    'roundDate', tr.fecha,
                    'active', tr.activo,
                    'closed', c.id IS NOT NULL,
                    'competitiveStatus', c.competitive_status,
                    'closureId', c.id,
                    'closedAt', c.closed_at,
                    'closedByAdminUserId', c.closed_by_admin_user_id
                )
                ORDER BY tr.numero_ronda, tr.fecha, tr.id
            ),
            '[]'::jsonb
        )
      INTO
        v_total_rounds,
        v_closed_rounds,
        v_pending_rounds,
        v_rounds
      FROM public.tournament_rounds tr
      LEFT JOIN public.tournament_round_competitive_closures c
        ON c.tournament_round_id = tr.id
     WHERE tr.tournament_id = p_tournament_id
       AND tr.activo = true;

    RETURN jsonb_build_object(
        'schemaVersion', 1,
        'tournamentId', p_tournament_id,
        'tournamentName', v_t.nombre,
        'estatus', v_t.estatus::text,
        'alreadyFinalized',
            v_existing.id IS NOT NULL
            OR v_t.estatus = 'finalizado'::public.estatus_torneo,
        'readyToFinalize',
            (
                v_t.estatus = 'en_curso'::public.estatus_torneo
                AND v_total_rounds > 0
                AND v_pending_rounds = 0
            ),
        'summary', jsonb_build_object(
            'activeRounds', v_total_rounds,
            'closedRounds', v_closed_rounds,
            'pendingRounds', v_pending_rounds
        ),
        'rounds', v_rounds,
        'finalization',
            CASE
                WHEN v_existing.id IS NULL THEN NULL
                ELSE jsonb_build_object(
                    'id', v_existing.id,
                    'status', v_existing.status,
                    'finalizedAt', v_existing.finalized_at,
                    'finalizedByAdminUserId',
                        v_existing.finalized_by_admin_user_id,
                    'notes', v_existing.notes,
                    'snapshot', v_existing.finalization_snapshot
                )
            END
    );
END;
$function$;

-- ============================================================================
-- 05. FINALIZAR TORNEO
--
-- Acción manual.
-- Precondiciones:
-- - estatus = en_curso
-- - al menos una ronda activa
-- - TODAS las rondas activas tienen cierre formal FINAL de Fase 3
--
-- La RPC NO conoce modalidad ni formato de salida.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.finalizar_torneo(
    p_tournament_id uuid,
    p_notas text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t public.tournaments%ROWTYPE;
    v_admin_id uuid;
    v_preview jsonb;
    v_existing_id uuid;
    v_finalization_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(
            auth.uid(),
            p_tournament_id
        )
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden finalizar el torneo.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_t
      FROM public.tournaments
     WHERE id = p_tournament_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El torneo indicado no existe.'
            USING ERRCODE = '22023';
    END IF;

    SELECT f.id
      INTO v_existing_id
      FROM public.tournament_competitive_finalizations f
     WHERE f.tournament_id = p_tournament_id;

    -- Idempotencia.
    IF v_t.estatus = 'finalizado'::public.estatus_torneo
       AND v_existing_id IS NOT NULL
    THEN
        RETURN public.previsualizar_finalizacion_torneo(
            p_tournament_id
        );
    END IF;

    -- Defensa ante datos históricos inconsistentes.
    IF v_t.estatus = 'finalizado'::public.estatus_torneo
       AND v_existing_id IS NULL
    THEN
        RAISE EXCEPTION
            'El torneo figura FINALIZADO pero no existe su sello formal de finalización.'
            USING ERRCODE = '55000',
                  HINT =
                      'No reconstruyas el sello manualmente. Diagnostica el dato histórico antes de continuar.';
    END IF;

    IF v_t.estatus <> 'en_curso'::public.estatus_torneo THEN
        RAISE EXCEPTION
            'El torneo sólo puede finalizarse desde EN CURSO. Estado actual: %.',
            v_t.estatus
            USING ERRCODE = '23514';
    END IF;

    v_preview :=
        public.previsualizar_finalizacion_torneo(
            p_tournament_id
        );

    IF NOT COALESCE(
        (v_preview->>'readyToFinalize')::boolean,
        false
    ) THEN
        RAISE EXCEPTION
            'El torneo todavía no puede finalizarse.'
            USING ERRCODE = '23514',
                  DETAIL = v_preview::text,
                  HINT =
                      'Todas las rondas activas deben estar cerradas competitivamente antes de finalizar el torneo.';
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
            'No se encontró el usuario administrativo autenticado.'
            USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.tournament_competitive_finalizations (
        tournament_id,
        status,
        finalization_snapshot,
        finalized_by_admin_user_id,
        notes
    )
    VALUES (
        p_tournament_id,
        'FINAL',
        v_preview,
        v_admin_id,
        NULLIF(btrim(COALESCE(p_notas, '')), '')
    )
    RETURNING id INTO v_finalization_id;

    PERFORM set_config(
        'app.permitir_cambio_estatus_torneo',
        '1',
        true
    );

    UPDATE public.tournaments
       SET estatus = 'finalizado'::public.estatus_torneo
     WHERE id = p_tournament_id;

    RETURN public.previsualizar_finalizacion_torneo(
        p_tournament_id
    );
END;
$function$;

-- ============================================================================
-- 06. PRIVILEGIOS
-- ============================================================================
REVOKE ALL
ON FUNCTION public.previsualizar_finalizacion_torneo(uuid)
FROM PUBLIC, anon;

REVOKE ALL
ON FUNCTION public.finalizar_torneo(uuid, text)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.previsualizar_finalizacion_torneo(uuid)
TO authenticated, service_role;

GRANT EXECUTE
ON FUNCTION public.finalizar_torneo(uuid, text)
TO authenticated, service_role;

COMMIT;
