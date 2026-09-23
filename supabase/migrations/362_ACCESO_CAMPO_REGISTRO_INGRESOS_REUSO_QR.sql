BEGIN;

-- ============================================================
-- MIGRACIÓN 362
-- ACCESO AL CAMPO
-- Registro de ingresos y control de reutilización del QR
-- ============================================================

CREATE TABLE public.tournament_access_entries (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,
    assignment_id uuid NOT NULL
        REFERENCES public.tournament_access_point_assignments(id) ON DELETE RESTRICT,
    registration_id uuid NOT NULL
        REFERENCES public.tournament_registrations(id) ON DELETE RESTRICT,
    player_id uuid NOT NULL
        REFERENCES public.players(id) ON DELETE RESTRICT,

    access_date date NOT NULL,
    entered_at timestamptz NOT NULL DEFAULT now(),

    qr_uso_numero integer NOT NULL,
    qr_reutilizado boolean NOT NULL DEFAULT false,
    reutilizado_mismo_dia boolean NOT NULL DEFAULT false,

    identidad_confirmada boolean NOT NULL,
    advertencia_reutilizacion_confirmada boolean NOT NULL DEFAULT false,

    viene_acompanado boolean NOT NULL DEFAULT false,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_access_entries_qr_uso_362
        CHECK (qr_uso_numero >= 1),

    CONSTRAINT tournament_access_entries_identity_362
        CHECK (identidad_confirmada = true),

    CONSTRAINT tournament_access_entries_reuse_consistency_362
        CHECK (
            (qr_uso_numero = 1 AND qr_reutilizado = false AND reutilizado_mismo_dia = false
             AND advertencia_reutilizacion_confirmada = false)
            OR
            (qr_uso_numero > 1 AND qr_reutilizado = true)
        ),

    CONSTRAINT tournament_access_entries_same_day_warning_362
        CHECK (
            reutilizado_mismo_dia = false
            OR advertencia_reutilizacion_confirmada = true
        )
);

CREATE INDEX tournament_access_entries_registration_idx_362
ON public.tournament_access_entries (registration_id, entered_at DESC);

CREATE INDEX tournament_access_entries_tournament_date_idx_362
ON public.tournament_access_entries (tournament_id, access_date, entered_at DESC);

CREATE INDEX tournament_access_entries_assignment_date_idx_362
ON public.tournament_access_entries (assignment_id, access_date, entered_at DESC);

ALTER TABLE public.tournament_access_entries ENABLE ROW LEVEL SECURITY;

-- La página pública nunca lee/escribe directamente esta tabla.
REVOKE ALL ON TABLE public.tournament_access_entries
FROM PUBLIC, anon, authenticated;

-- Organizadores y Superadmin podrán consultar historial desde la futura UI.
CREATE POLICY tournament_access_entries_select_362
ON public.tournament_access_entries
FOR SELECT TO authenticated
USING (
    public.is_superadmin(auth.uid())
    OR public.is_tournament_organizer(auth.uid(), tournament_id)
);

GRANT SELECT ON TABLE public.tournament_access_entries TO authenticated;

-- ------------------------------------------------------------
-- Validación enriquecida:
-- mantiene las validaciones de 361 y añade historial de uso.
-- NO registra ingreso.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validar_qr_jugador_acceso_361(
    p_access_token text,
    p_player_qr_token text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_access_token text;
    v_player_token text;
    v_assignment_id uuid;
    v_tournament_id uuid;
    v_access_point_id uuid;
    v_access_point_name text;
    v_responsible_name text;
    v_tournament_name text;
    v_tournament_start date;
    v_tournament_end date;
    v_course_timezone text;
    v_access_date date;
    v_registration_id uuid;
    v_player_id uuid;
    v_folio text;
    v_player_names text;
    v_player_surnames text;
    v_total_prior integer;
    v_today_prior integer;
    v_last_entry_at timestamptz;
    v_last_access_point text;
BEGIN
    v_access_token := lower(btrim(coalesce(p_access_token, '')));
    v_player_token := lower(btrim(coalesce(p_player_qr_token, '')));

    IF v_access_token !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'Código de acceso de puerta inválido.' USING errcode='22023';
    END IF;
    IF v_player_token !~ '^[0-9a-f]{32}$' THEN
        RAISE EXCEPTION 'Código QR de jugador inválido.' USING errcode='22023';
    END IF;

    SELECT a.id, a.tournament_id, a.access_point_id, ap.nombre,
           a.responsable_nombre, t.nombre, t.fecha_inicio, t.fecha_fin,
           cg.timezone_id
      INTO v_assignment_id, v_tournament_id, v_access_point_id,
           v_access_point_name, v_responsible_name, v_tournament_name,
           v_tournament_start, v_tournament_end, v_course_timezone
      FROM public.tournament_access_point_credentials c
      JOIN public.tournament_access_point_assignments a ON a.id=c.assignment_id
      JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
      JOIN public.tournaments t ON t.id=a.tournament_id
      JOIN public.campos_golf cg ON cg.id=t.campo_golf_id
     WHERE c.access_token=v_access_token
       AND c.activo=true
       AND a.habilitado=true
       AND ap.activo=true
       AND t.activo=true
       AND t.usar_control_acceso_qr=true
       AND t.estatus NOT IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo)
       AND public.acceso_campo_abierto_359(t.id)=true
     LIMIT 1;

    IF v_assignment_id IS NULL THEN
        RAISE EXCEPTION 'La puerta no está disponible o el acceso al campo aún no está abierto.'
            USING errcode='42501';
    END IF;

    IF nullif(btrim(coalesce(v_course_timezone,'')),'') IS NULL THEN
        RAISE EXCEPTION 'El campo del torneo no tiene zona horaria configurada.'
            USING errcode='55000';
    END IF;

    v_access_date := (now() AT TIME ZONE v_course_timezone)::date;

    SELECT r.id,r.player_id,r.folio,p.nombres,p.apellidos
      INTO v_registration_id,v_player_id,v_folio,v_player_names,v_player_surnames
      FROM public.tournament_registrations r
      JOIN public.players p ON p.id=r.player_id
     WHERE lower(btrim(r.qr_token))=v_player_token
       AND r.tournament_id=v_tournament_id
       AND r.activo=true
     LIMIT 1;

    IF v_registration_id IS NULL THEN
        RAISE EXCEPTION 'El QR no corresponde a una inscripción activa de este torneo.'
            USING errcode='42501';
    END IF;

    SELECT count(*)::integer,
           count(*) FILTER (WHERE e.access_date=v_access_date)::integer
      INTO v_total_prior,v_today_prior
      FROM public.tournament_access_entries e
     WHERE e.registration_id=v_registration_id;

    SELECT e.entered_at, ap.nombre
      INTO v_last_entry_at,v_last_access_point
      FROM public.tournament_access_entries e
      JOIN public.tournament_access_point_assignments a ON a.id=e.assignment_id
      JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
     WHERE e.registration_id=v_registration_id
     ORDER BY e.entered_at DESC
     LIMIT 1;

    RETURN jsonb_build_object(
        'ok',true,
        'valid',true,
        'tournament',jsonb_build_object(
            'id',v_tournament_id,'name',v_tournament_name,
            'startDate',v_tournament_start,'endDate',v_tournament_end,
            'courseTimezone',v_course_timezone
        ),
        'accessDate',v_access_date,
        'registration',jsonb_build_object('id',v_registration_id,'folio',v_folio),
        'player',jsonb_build_object(
            'id',v_player_id,'firstNames',v_player_names,'lastNames',v_player_surnames,
            'displayName',btrim(concat_ws(' ',v_player_names,v_player_surnames))
        ),
        'accessPoint',jsonb_build_object(
            'assignmentId',v_assignment_id,'id',v_access_point_id,
            'name',v_access_point_name,'responsibleName',v_responsible_name
        ),
        'accessHistory',jsonb_build_object(
            'priorEntries',v_total_prior,
            'priorEntriesToday',v_today_prior,
            'hasPriorEntries',v_total_prior>0,
            'hasPriorEntryToday',v_today_prior>0,
            'lastEntryAt',v_last_entry_at,
            'lastAccessPoint',v_last_access_point,
            'warningLevel',CASE WHEN v_today_prior>0 THEN 'STRONG'
                                WHEN v_total_prior>0 THEN 'INFO'
                                ELSE 'NONE' END,
            'warningMessage',CASE
                WHEN v_today_prior>0 THEN
                    'QR UTILIZADO ANTERIORMENTE HOY — IDENTIFIQUE A LA PERSONA BAJO SU RESPONSABILIDAD'
                WHEN v_total_prior>0 THEN
                    'Este QR tiene ingresos registrados en días anteriores del torneo.'
                ELSE NULL
            END
        ),
        'instructions',jsonb_build_object(
            'physicalIdRequired',true,
            'message','Solicite una identificación física y confirme que corresponde a la persona mostrada antes de registrar el ingreso.'
        )
    );
END;
$$;

-- ------------------------------------------------------------
-- Registrar ingreso.
-- Vuelve a validar todo en servidor y calcula el número de uso.
-- Para reuso el mismo día exige confirmación expresa de advertencia.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_ingreso_acceso_362(
    p_access_token text,
    p_player_qr_token text,
    p_identidad_confirmada boolean,
    p_advertencia_reutilizacion_confirmada boolean DEFAULT false,
    p_viene_acompanado boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_access_token text;
    v_player_token text;
    v_assignment_id uuid;
    v_tournament_id uuid;
    v_registration_id uuid;
    v_player_id uuid;
    v_course_timezone text;
    v_access_date date;
    v_prior_count integer;
    v_today_prior integer;
    v_use_number integer;
    v_entry_id uuid;
    v_entered_at timestamptz;
BEGIN
    IF p_identidad_confirmada IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Debe confirmar la identidad física del jugador antes de registrar el ingreso.'
            USING errcode='22023';
    END IF;

    v_access_token := lower(btrim(coalesce(p_access_token,'')));
    v_player_token := lower(btrim(coalesce(p_player_qr_token,'')));

    IF v_access_token !~ '^[0-9a-f]{64}$'
       OR v_player_token !~ '^[0-9a-f]{32}$' THEN
        RAISE EXCEPTION 'Código de acceso o QR de jugador inválido.'
            USING errcode='22023';
    END IF;

    SELECT a.id,a.tournament_id,cg.timezone_id
      INTO v_assignment_id,v_tournament_id,v_course_timezone
      FROM public.tournament_access_point_credentials c
      JOIN public.tournament_access_point_assignments a ON a.id=c.assignment_id
      JOIN public.tournament_access_points ap ON ap.id=a.access_point_id
      JOIN public.tournaments t ON t.id=a.tournament_id
      JOIN public.campos_golf cg ON cg.id=t.campo_golf_id
     WHERE c.access_token=v_access_token
       AND c.activo=true
       AND a.habilitado=true
       AND ap.activo=true
       AND t.activo=true
       AND t.usar_control_acceso_qr=true
       AND t.estatus NOT IN ('finalizado'::public.estatus_torneo,'cancelado'::public.estatus_torneo)
       AND public.acceso_campo_abierto_359(t.id)=true
     LIMIT 1;

    IF v_assignment_id IS NULL THEN
        RAISE EXCEPTION 'La puerta no está disponible o el acceso al campo aún no está abierto.'
            USING errcode='42501';
    END IF;

    v_access_date := (now() AT TIME ZONE v_course_timezone)::date;

    SELECT r.id,r.player_id
      INTO v_registration_id,v_player_id
      FROM public.tournament_registrations r
     WHERE lower(btrim(r.qr_token))=v_player_token
       AND r.tournament_id=v_tournament_id
       AND r.activo=true
     LIMIT 1
     FOR UPDATE;

    IF v_registration_id IS NULL THEN
        RAISE EXCEPTION 'El QR no corresponde a una inscripción activa de este torneo.'
            USING errcode='42501';
    END IF;

    -- El bloqueo de la fila de inscripción serializa ingresos concurrentes
    -- del mismo QR para numerar correctamente cada uso.
    SELECT count(*)::integer,
           count(*) FILTER (WHERE access_date=v_access_date)::integer
      INTO v_prior_count,v_today_prior
      FROM public.tournament_access_entries
     WHERE registration_id=v_registration_id;

    IF v_today_prior>0
       AND p_advertencia_reutilizacion_confirmada IS DISTINCT FROM true THEN
        RAISE EXCEPTION
            'QR UTILIZADO ANTERIORMENTE HOY — IDENTIFIQUE A LA PERSONA BAJO SU RESPONSABILIDAD y confirme la advertencia para continuar.'
            USING errcode='22023';
    END IF;

    v_use_number := v_prior_count+1;

    INSERT INTO public.tournament_access_entries (
        tournament_id,assignment_id,registration_id,player_id,
        access_date,entered_at,qr_uso_numero,qr_reutilizado,
        reutilizado_mismo_dia,identidad_confirmada,
        advertencia_reutilizacion_confirmada,viene_acompanado
    )
    VALUES (
        v_tournament_id,v_assignment_id,v_registration_id,v_player_id,
        v_access_date,now(),v_use_number,(v_prior_count>0),
        (v_today_prior>0),true,
        CASE WHEN v_today_prior>0 THEN true ELSE false END,
        coalesce(p_viene_acompanado,false)
    )
    RETURNING id,entered_at INTO v_entry_id,v_entered_at;

    RETURN jsonb_build_object(
        'ok',true,
        'entryId',v_entry_id,
        'accessDate',v_access_date,
        'enteredAt',v_entered_at,
        'qrUseNumber',v_use_number,
        'qrReused',v_prior_count>0,
        'reusedSameDay',v_today_prior>0,
        'accompanied',coalesce(p_viene_acompanado,false)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_ingreso_acceso_362(text,text,boolean,boolean,boolean)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_ingreso_acceso_362(text,text,boolean,boolean,boolean)
TO anon,authenticated;

-- 361 conserva sus permisos.
REVOKE ALL ON FUNCTION public.validar_qr_jugador_acceso_361(text,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.validar_qr_jugador_acceso_361(text,text)
TO anon,authenticated;

COMMIT;
