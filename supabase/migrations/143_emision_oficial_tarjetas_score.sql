-- ============================================================================
-- MIGRACIÓN 143
-- EMISIÓN OFICIAL DE TARJETAS DE SCORE POR RONDA VALIDADA
--
-- OBJETIVO
-- - Crear identidad propia para la tarjeta oficial de score.
-- - Emitir únicamente desde una versión VALIDADA de las salidas.
-- - Vincular cada tarjeta con la fotografía inmutable de validación (140).
-- - Crear folio de tarjeta y QR propios, separados de inscripción/acceso.
-- - Impedir reapertura normal de salidas después de emitir tarjetas oficiales.
--
-- ALCANCE INICIAL
-- - Motor soportado: stroke_individual_shotgun_v1.
-- - Una tarjeta por unidad "registration" de la validación activa.
-- - NO captura golpes/resultados.
-- - NO genera PDF.
-- - NO usa ni modifica tournament_registrations.qr_token.
-- - NO usa ni modifica tournament_registrations.folio como identidad de tarjeta.
-- - NO implementa todavía anulación/reposición de emisión.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. Dependencias.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    v_faltantes text;
BEGIN
    WITH requeridos(tipo, firma) AS (
        VALUES
            ('tabla', 'public.admin_users'),
            ('tabla', 'public.tournaments'),
            ('tabla', 'public.tournament_rounds'),
            ('tabla', 'public.tournament_round_start_validations'),
            ('tabla', 'public.tournament_round_start_validation_groups'),
            ('tabla', 'public.tournament_round_start_validation_units'),
            ('tabla', 'public.tournament_registrations'),
            ('tabla', 'public.tournament_teams'),
            ('tabla', 'public.players'),
            ('función', 'public.puede_administrar_congelamiento_torneo(uuid)'),
            ('función', 'public._bloquear_salida_ronda(uuid)'),
            ('función', 'public.obtener_estado_validacion_salidas_ronda(uuid)'),
            ('función', 'public.reabrir_salidas_ronda(uuid,text)')
    )
    SELECT string_agg(tipo || ': ' || firma, E'\n' ORDER BY tipo, firma)
      INTO v_faltantes
      FROM requeridos
     WHERE (tipo = 'tabla' AND to_regclass(firma) IS NULL)
        OR (tipo = 'función' AND to_regprocedure(firma) IS NULL);

    IF v_faltantes IS NOT NULL THEN
        RAISE EXCEPTION
            'No puede ejecutarse la Migración 143. Faltan dependencias:%',
            E'\n' || v_faltantes
            USING ERRCODE = '55000';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. Cabecera de emisión oficial.
--
-- Una emisión representa el acto administrativo de convertir una validación
-- de salidas en tarjetas oficiales. La validación sigue siendo la fuente
-- histórica de grupos/unidades.
-- ---------------------------------------------------------------------------

CREATE TABLE public.tournament_score_card_emissions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,

    validation_id uuid NOT NULL
        REFERENCES public.tournament_round_start_validations(id)
        ON DELETE RESTRICT,

    validation_version integer NOT NULL
        CHECK (validation_version > 0),

    status text NOT NULL DEFAULT 'issued'
        CHECK (status IN ('issued', 'voided')),

    card_count integer NOT NULL
        CHECK (card_count > 0),

    issued_at timestamptz NOT NULL DEFAULT now(),

    issued_by uuid NOT NULL
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,

    -- Reservados para una futura migración de anulación controlada.
    voided_at timestamptz,
    voided_by uuid
        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
    void_reason text,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_score_card_emissions_validation_uk
        UNIQUE (validation_id),

    CONSTRAINT tournament_score_card_emissions_void_consistency
        CHECK (
            (
                status = 'issued'
                AND voided_at IS NULL
                AND voided_by IS NULL
                AND void_reason IS NULL
            )
            OR
            (
                status = 'voided'
                AND voided_at IS NOT NULL
                AND voided_by IS NOT NULL
                AND length(btrim(void_reason)) >= 5
            )
        )
);

CREATE UNIQUE INDEX tournament_score_card_emissions_one_active_round_uk
    ON public.tournament_score_card_emissions(tournament_round_id)
    WHERE status = 'issued';

CREATE INDEX idx_score_card_emissions_tournament_round
    ON public.tournament_score_card_emissions(
        tournament_id,
        tournament_round_id,
        validation_version
    );

-- ---------------------------------------------------------------------------
-- 2. Tarjetas oficiales.
--
-- IMPORTANTE:
-- - qr_token es EXCLUSIVO de la tarjeta de score.
-- - NO tiene relación funcional con tournament_registrations.qr_token,
--   cuyo objetivo futuro es control de acceso al club.
-- - card_folio es el folio de TARJETA, no el folio de inscripción.
-- ---------------------------------------------------------------------------

CREATE TABLE public.tournament_score_cards (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    emission_id uuid NOT NULL
        REFERENCES public.tournament_score_card_emissions(id)
        ON DELETE RESTRICT,

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,

    validation_id uuid NOT NULL
        REFERENCES public.tournament_round_start_validations(id)
        ON DELETE RESTRICT,

    validation_version integer NOT NULL
        CHECK (validation_version > 0),

    validation_group_id uuid NOT NULL
        REFERENCES public.tournament_round_start_validation_groups(id)
        ON DELETE RESTRICT,

    validation_unit_id uuid NOT NULL
        REFERENCES public.tournament_round_start_validation_units(id)
        ON DELETE RESTRICT,

    unit_type text NOT NULL
        CHECK (unit_type IN ('registration', 'team')),

    tournament_registration_id uuid
        REFERENCES public.tournament_registrations(id)
        ON DELETE RESTRICT,

    tournament_team_id uuid
        REFERENCES public.tournament_teams(id)
        ON DELETE RESTRICT,

    player_id uuid
        REFERENCES public.players(id)
        ON DELETE RESTRICT,

    tournament_category_id uuid NOT NULL,

    card_number integer NOT NULL
        CHECK (card_number > 0),

    card_folio text NOT NULL
        CHECK (length(btrim(card_folio)) >= 6),

    qr_token text NOT NULL
        DEFAULT encode(gen_random_bytes(32), 'hex')
        CHECK (length(qr_token) >= 32),

    status text NOT NULL DEFAULT 'issued'
        CHECK (status IN ('issued', 'voided')),

    issued_at timestamptz NOT NULL DEFAULT now(),

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_score_cards_unit_consistency
        CHECK (
            (
                unit_type = 'registration'
                AND tournament_registration_id IS NOT NULL
                AND tournament_team_id IS NULL
                AND player_id IS NOT NULL
            )
            OR
            (
                unit_type = 'team'
                AND tournament_registration_id IS NULL
                AND tournament_team_id IS NOT NULL
                AND player_id IS NULL
            )
        ),

    CONSTRAINT tournament_score_cards_emission_unit_uk
        UNIQUE (emission_id, validation_unit_id),

    CONSTRAINT tournament_score_cards_emission_number_uk
        UNIQUE (emission_id, card_number),

    CONSTRAINT tournament_score_cards_tournament_folio_uk
        UNIQUE (tournament_id, card_folio),

    CONSTRAINT tournament_score_cards_qr_token_uk
        UNIQUE (qr_token)
);

CREATE INDEX idx_score_cards_round
    ON public.tournament_score_cards(
        tournament_round_id,
        validation_version,
        card_number
    );

CREATE INDEX idx_score_cards_registration
    ON public.tournament_score_cards(
        tournament_registration_id,
        tournament_round_id
    )
    WHERE unit_type = 'registration';

CREATE INDEX idx_score_cards_team
    ON public.tournament_score_cards(
        tournament_team_id,
        tournament_round_id
    )
    WHERE unit_type = 'team';

-- ---------------------------------------------------------------------------
-- 3. RLS: lectura administrativa; sin escritura directa desde cliente.
-- ---------------------------------------------------------------------------

ALTER TABLE public.tournament_score_card_emissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_score_cards ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tournament_score_card_emissions_select
    ON public.tournament_score_card_emissions;
CREATE POLICY tournament_score_card_emissions_select
ON public.tournament_score_card_emissions
FOR SELECT TO authenticated
USING (
    public.puede_administrar_congelamiento_torneo(tournament_id)
);

DROP POLICY IF EXISTS tournament_score_cards_select
    ON public.tournament_score_cards;
CREATE POLICY tournament_score_cards_select
ON public.tournament_score_cards
FOR SELECT TO authenticated
USING (
    public.puede_administrar_congelamiento_torneo(tournament_id)
);

REVOKE ALL ON TABLE public.tournament_score_card_emissions
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.tournament_score_cards
    FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE public.tournament_score_card_emissions
    TO authenticated;
GRANT SELECT ON TABLE public.tournament_score_cards
    TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Helper interno: ¿la ronda tiene emisión oficial activa?
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._ronda_tiene_tarjetas_emitidas(
    p_tournament_round_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.tournament_score_card_emissions e
        WHERE e.tournament_round_id = p_tournament_round_id
          AND e.status = 'issued'
    );
$$;

-- ---------------------------------------------------------------------------
-- 5. Inmutabilidad de emisión/tarjetas.
--
-- La anulación/reposición se implementará más adelante con una RPC específica.
-- Hasta entonces no se permite UPDATE/DELETE de estos registros históricos.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._impedir_mutacion_emision_tarjeta_score()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION
        'Las emisiones y tarjetas oficiales son históricas y no pueden modificarse directamente.'
        USING ERRCODE = '55000',
              HINT = 'La anulación o reposición deberá realizarse mediante una operación administrativa auditada.';
END;
$$;

DROP TRIGGER IF EXISTS trg_impedir_mutacion_score_card_emissions
    ON public.tournament_score_card_emissions;
CREATE TRIGGER trg_impedir_mutacion_score_card_emissions
BEFORE UPDATE OR DELETE ON public.tournament_score_card_emissions
FOR EACH ROW
EXECUTE FUNCTION public._impedir_mutacion_emision_tarjeta_score();

DROP TRIGGER IF EXISTS trg_impedir_mutacion_score_cards
    ON public.tournament_score_cards;
CREATE TRIGGER trg_impedir_mutacion_score_cards
BEFORE UPDATE OR DELETE ON public.tournament_score_cards
FOR EACH ROW
EXECUTE FUNCTION public._impedir_mutacion_emision_tarjeta_score();

-- ---------------------------------------------------------------------------
-- 6. Defensa adicional: una validación con tarjetas emitidas no puede pasar
--    de validated -> reopened.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._impedir_reapertura_con_tarjetas_emitidas()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF OLD.status = 'validated'
       AND NEW.status = 'reopened'
       AND public._ronda_tiene_tarjetas_emitidas(OLD.tournament_round_id)
    THEN
        RAISE EXCEPTION
            'Las tarjetas oficiales de esta ronda ya fueron emitidas y las salidas no pueden reabrirse.'
            USING ERRCODE = '55000',
                  HINT = 'Primero deberá anularse formalmente la emisión de tarjetas mediante el flujo administrativo correspondiente.';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_impedir_reapertura_con_tarjetas_emitidas
    ON public.tournament_round_start_validations;
CREATE TRIGGER trg_impedir_reapertura_con_tarjetas_emitidas
BEFORE UPDATE ON public.tournament_round_start_validations
FOR EACH ROW
EXECUTE FUNCTION public._impedir_reapertura_con_tarjetas_emitidas();

-- ---------------------------------------------------------------------------
-- 7. Estado ligero de emisión para frontend.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_estado_emision_tarjetas_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tournament_id uuid;
    v_active record;
    v_history_count integer := 0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tr.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds tr
     WHERE tr.id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar la emisión de tarjetas de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        e.id,
        e.validation_id,
        e.validation_version,
        e.card_count,
        e.issued_at,
        e.issued_by,
        COALESCE(
            NULLIF(
                concat_ws(
                    ' ',
                    NULLIF(to_jsonb(au)->>'nombres', ''),
                    NULLIF(to_jsonb(au)->>'apellidos', '')
                ),
                ''
            ),
            NULLIF(to_jsonb(au)->>'nombre', ''),
            NULLIF(to_jsonb(au)->>'name', ''),
            NULLIF(to_jsonb(au)->>'email', ''),
            e.issued_by::text
        ) AS issued_by_name
      INTO v_active
      FROM public.tournament_score_card_emissions e
      LEFT JOIN public.admin_users au
        ON au.id = e.issued_by
     WHERE e.tournament_round_id = p_tournament_round_id
       AND e.status = 'issued'
     LIMIT 1;

    SELECT count(*)
      INTO v_history_count
      FROM public.tournament_score_card_emissions e
     WHERE e.tournament_round_id = p_tournament_round_id;

    RETURN jsonb_build_object(
        'tournamentRoundId', p_tournament_round_id,
        'issued', v_active.id IS NOT NULL,
        'active',
            CASE
                WHEN v_active.id IS NULL THEN NULL
                ELSE jsonb_build_object(
                    'id', v_active.id,
                    'validationId', v_active.validation_id,
                    'validationVersion', v_active.validation_version,
                    'cardCount', v_active.card_count,
                    'issuedAt', v_active.issued_at,
                    'issuedBy', jsonb_build_object(
                        'adminUserId', v_active.issued_by,
                        'displayName', v_active.issued_by_name
                    )
                )
            END,
        'historyCount', v_history_count
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- 8. Emisión idempotente de tarjetas oficiales.
--
-- La fuente es la validación ACTIVA, no tournament_groups vivo.
-- Primera versión: Stroke Play individual + Shotgun.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.emitir_tarjetas_score_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tournament_id uuid;
    v_round_number integer;
    v_admin_id uuid;
    v_validation record;
    v_emission_id uuid;
    v_inserted integer := 0;
    v_units integer := 0;
    v_bad_units integer := 0;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT tr.tournament_id, tr.numero_ronda
      INTO v_tournament_id, v_round_number
      FROM public.tournament_rounds tr
     WHERE tr.id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(v_tournament_id) THEN
        RAISE EXCEPTION
            'No tienes permiso para emitir tarjetas oficiales de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(p_tournament_round_id);

    -- Idempotencia: si ya existe emisión activa, no duplica tarjetas.
    IF public._ronda_tiene_tarjetas_emitidas(p_tournament_round_id) THEN
        RETURN public.obtener_estado_emision_tarjetas_ronda(
            p_tournament_round_id
        );
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

    SELECT
        v.id,
        v.version,
        v.validator_engine,
        v.start_format,
        v.participation_type,
        v.scoring_engine,
        v.unit_count
      INTO v_validation
      FROM public.tournament_round_start_validations v
     WHERE v.tournament_round_id = p_tournament_round_id
       AND v.status = 'validated'
     FOR UPDATE;

    IF v_validation.id IS NULL THEN
        RAISE EXCEPTION
            'Las salidas de la ronda deben estar validadas antes de emitir tarjetas oficiales.'
            USING ERRCODE = '23514',
                  HINT = 'Revise y valide primero las salidas de la ronda.';
    END IF;

    IF v_validation.validator_engine <> 'stroke_individual_shotgun_v1'
       OR v_validation.start_format <> 'shotgun'
       OR v_validation.participation_type <> 'individual'
       OR v_validation.scoring_engine <> 'stroke'
    THEN
        RAISE EXCEPTION
            'La versión actual de emisión sólo soporta Stroke Play individual con salida Shotgun.'
            USING ERRCODE = '0A000',
                  DETAIL = format(
                      'validator_engine=%s; start_format=%s; participation_type=%s; scoring_engine=%s',
                      v_validation.validator_engine,
                      v_validation.start_format,
                      v_validation.participation_type,
                      v_validation.scoring_engine
                  );
    END IF;

    SELECT count(*),
           count(*) FILTER (
               WHERE u.unit_type <> 'registration'
                  OR u.tournament_registration_id IS NULL
                  OR u.player_id IS NULL
           )
      INTO v_units, v_bad_units
      FROM public.tournament_round_start_validation_units u
     WHERE u.validation_id = v_validation.id;

    IF v_units = 0 OR v_units <> v_validation.unit_count THEN
        RAISE EXCEPTION
            'La fotografía validada no contiene el número esperado de participantes.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'unidades_snapshot=%s; unidades_validacion=%s',
                      v_units,
                      v_validation.unit_count
                  );
    END IF;

    IF v_bad_units > 0 THEN
        RAISE EXCEPTION
            'La validación contiene unidades no soportadas por el emisor individual.'
            USING ERRCODE = '0A000',
                  DETAIL = format('unidades_no_soportadas=%s', v_bad_units);
    END IF;

    INSERT INTO public.tournament_score_card_emissions (
        tournament_id,
        tournament_round_id,
        validation_id,
        validation_version,
        status,
        card_count,
        issued_by
    )
    VALUES (
        v_tournament_id,
        p_tournament_round_id,
        v_validation.id,
        v_validation.version,
        'issued',
        v_validation.unit_count,
        v_admin_id
    )
    RETURNING id INTO v_emission_id;

    WITH ordered_units AS (
        SELECT
            u.id AS validation_unit_id,
            u.validation_group_id,
            u.unit_type,
            u.tournament_registration_id,
            u.tournament_team_id,
            u.player_id,
            u.tournament_category_id,
            row_number() OVER (
                ORDER BY
                    g.shift_number,
                    g.hole_number,
                    g.start_position,
                    u.order_in_group,
                    u.id
            )::integer AS card_number
        FROM public.tournament_round_start_validation_units u
        JOIN public.tournament_round_start_validation_groups g
          ON g.id = u.validation_group_id
         AND g.validation_id = u.validation_id
        WHERE u.validation_id = v_validation.id
    )
    INSERT INTO public.tournament_score_cards (
        emission_id,
        tournament_id,
        tournament_round_id,
        validation_id,
        validation_version,
        validation_group_id,
        validation_unit_id,
        unit_type,
        tournament_registration_id,
        tournament_team_id,
        player_id,
        tournament_category_id,
        card_number,
        card_folio,
        status
    )
    SELECT
        v_emission_id,
        v_tournament_id,
        p_tournament_round_id,
        v_validation.id,
        v_validation.version,
        ou.validation_group_id,
        ou.validation_unit_id,
        ou.unit_type,
        ou.tournament_registration_id,
        ou.tournament_team_id,
        ou.player_id,
        ou.tournament_category_id,
        ou.card_number,
        'R'
            || lpad(v_round_number::text, 2, '0')
            || '-V'
            || lpad(v_validation.version::text, 2, '0')
            || '-'
            || lpad(ou.card_number::text, 4, '0'),
        'issued'
    FROM ordered_units ou
    ORDER BY ou.card_number;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    IF v_inserted <> v_validation.unit_count THEN
        RAISE EXCEPTION
            'La emisión de tarjetas quedó incompleta y fue revertida automáticamente.'
            USING ERRCODE = '55000',
                  DETAIL = format(
                      'tarjetas_insertadas=%s; tarjetas_esperadas=%s',
                      v_inserted,
                      v_validation.unit_count
                  );
    END IF;

    RETURN public.obtener_estado_emision_tarjetas_ronda(
        p_tournament_round_id
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- 9. Reapertura: añade guard explícito además del trigger defensivo.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reabrir_salidas_ronda(
    p_tournament_round_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tournament_id uuid;
    v_admin_id uuid;
    v_validation_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    IF length(btrim(COALESCE(p_reason, ''))) < 5 THEN
        RAISE EXCEPTION
            'El motivo de reapertura debe contener al menos 5 caracteres.'
            USING ERRCODE = '22023';
    END IF;

    SELECT tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds
     WHERE id = p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para reabrir las salidas de esta ronda.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(p_tournament_round_id);

    IF public._ronda_tiene_tarjetas_emitidas(p_tournament_round_id) THEN
        RAISE EXCEPTION
            'Las tarjetas oficiales de esta ronda ya fueron emitidas y las salidas no pueden reabrirse.'
            USING ERRCODE = '55000',
                  HINT = 'Primero deberá anularse formalmente la emisión de tarjetas mediante el flujo administrativo correspondiente.';
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

    SELECT id
      INTO v_validation_id
      FROM public.tournament_round_start_validations
     WHERE tournament_round_id = p_tournament_round_id
       AND status = 'validated'
     FOR UPDATE;

    IF v_validation_id IS NULL THEN
        RETURN public.obtener_estado_validacion_salidas_ronda(
            p_tournament_round_id
        );
    END IF;

    PERFORM set_config(
        'app.reabrir_validacion_salida_ronda',
        'true',
        true
    );

    UPDATE public.tournament_round_start_validations
       SET status = 'reopened',
           reopened_at = now(),
           reopened_by = v_admin_id,
           reopen_reason = btrim(p_reason)
     WHERE id = v_validation_id;

    RETURN public.obtener_estado_validacion_salidas_ronda(
        p_tournament_round_id
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- 10. Privilegios de funciones.
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public._ronda_tiene_tarjetas_emitidas(uuid)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._impedir_mutacion_emision_tarjeta_score()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._impedir_reapertura_con_tarjetas_emitidas()
    FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.obtener_estado_emision_tarjetas_ronda(uuid)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.emitir_tarjetas_score_ronda(uuid)
    FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.obtener_estado_emision_tarjetas_ronda(uuid)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.emitir_tarjetas_score_ronda(uuid)
    TO authenticated;

-- reabrir_salidas_ronda conserva su superficie autorizada.
REVOKE ALL ON FUNCTION public.reabrir_salidas_ronda(uuid, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reabrir_salidas_ronda(uuid, text)
    TO authenticated;

-- ---------------------------------------------------------------------------
-- 11. Comentarios operativos.
-- ---------------------------------------------------------------------------

COMMENT ON TABLE public.tournament_score_card_emissions IS
    'Cabecera auditable de emisión oficial de tarjetas de score, ligada a una versión validada de salidas.';

COMMENT ON TABLE public.tournament_score_cards IS
    'Tarjetas oficiales de score. Su QR y folio son propios de la tarjeta y no sustituyen el QR/folio de inscripción.';

COMMENT ON COLUMN public.tournament_score_cards.qr_token IS
    'Token QR exclusivo de la tarjeta oficial de score. No es el QR de acceso almacenado en tournament_registrations.qr_token.';

COMMENT ON COLUMN public.tournament_score_cards.card_folio IS
    'Folio propio de la tarjeta oficial. No es el folio de inscripción.';

COMMENT ON FUNCTION public.emitir_tarjetas_score_ronda(uuid) IS
    'Emite idempotentemente tarjetas oficiales desde la validación activa de una ronda. Primera versión: Stroke Play individual + Shotgun.';

COMMENT ON FUNCTION public.obtener_estado_emision_tarjetas_ronda(uuid) IS
    'Devuelve el estado ligero de emisión oficial de tarjetas de una ronda para frontend.';

COMMENT ON FUNCTION public._ronda_tiene_tarjetas_emitidas(uuid) IS
    'Helper interno para impedir reapertura normal de salidas después de una emisión oficial activa.';

COMMIT;
