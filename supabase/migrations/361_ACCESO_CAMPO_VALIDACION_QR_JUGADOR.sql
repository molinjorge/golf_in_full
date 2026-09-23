BEGIN;

-- ============================================================
-- MIGRACIÓN 361
-- ACCESO AL CAMPO
-- Validación del QR existente del jugador
-- ============================================================

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
BEGIN
    v_access_token := lower(btrim(coalesce(p_access_token, '')));
    v_player_token := lower(btrim(coalesce(p_player_qr_token, '')));

    IF v_access_token !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'Código de acceso de puerta inválido.'
            USING errcode='22023';
    END IF;

    -- El QR histórico de inscripción usa 16 bytes = 32 hex.
    IF v_player_token !~ '^[0-9a-f]{32}$' THEN
        RAISE EXCEPTION 'Código QR de jugador inválido.'
            USING errcode='22023';
    END IF;

    -- Resolver la puerta y exigir que esté completamente operativa.
    SELECT
        a.id,
        a.tournament_id,
        a.access_point_id,
        ap.nombre,
        a.responsable_nombre,
        t.nombre,
        t.fecha_inicio,
        t.fecha_fin,
        cg.timezone_id
    INTO
        v_assignment_id,
        v_tournament_id,
        v_access_point_id,
        v_access_point_name,
        v_responsible_name,
        v_tournament_name,
        v_tournament_start,
        v_tournament_end,
        v_course_timezone
    FROM public.tournament_access_point_credentials c
    JOIN public.tournament_access_point_assignments a
      ON a.id=c.assignment_id
    JOIN public.tournament_access_points ap
      ON ap.id=a.access_point_id
    JOIN public.tournaments t
      ON t.id=a.tournament_id
    JOIN public.campos_golf cg
      ON cg.id=t.campo_golf_id
    WHERE c.access_token=v_access_token
      AND c.activo=true
      AND a.habilitado=true
      AND ap.activo=true
      AND t.activo=true
      AND t.usar_control_acceso_qr=true
      AND t.estatus NOT IN (
          'finalizado'::public.estatus_torneo,
          'cancelado'::public.estatus_torneo
      )
      AND public.acceso_campo_abierto_359(t.id)=true
    LIMIT 1;

    IF v_assignment_id IS NULL THEN
        RAISE EXCEPTION
            'La puerta no está disponible o el acceso al campo aún no está abierto.'
            USING errcode='42501';
    END IF;

    IF nullif(btrim(coalesce(v_course_timezone, '')), '') IS NULL THEN
        RAISE EXCEPTION
            'El campo del torneo no tiene zona horaria configurada.'
            USING errcode='55000';
    END IF;

    -- La fecha operativa se calcula en la zona horaria real del campo,
    -- no con la zona de la sesión ni con UTC.
    v_access_date := (now() AT TIME ZONE v_course_timezone)::date;

    -- El QR del jugador sólo es válido si corresponde a una inscripción
    -- activa del MISMO torneo de la puerta.
    SELECT
        r.id,
        r.player_id,
        r.folio,
        p.nombres,
        p.apellidos
    INTO
        v_registration_id,
        v_player_id,
        v_folio,
        v_player_names,
        v_player_surnames
    FROM public.tournament_registrations r
    JOIN public.players p ON p.id=r.player_id
    WHERE lower(btrim(r.qr_token))=v_player_token
      AND r.tournament_id=v_tournament_id
      AND r.activo=true
    LIMIT 1;

    IF v_registration_id IS NULL THEN
        RAISE EXCEPTION
            'El QR no corresponde a una inscripción activa de este torneo.'
            USING errcode='42501';
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'valid', true,
        'tournament', jsonb_build_object(
            'id', v_tournament_id,
            'name', v_tournament_name,
            'startDate', v_tournament_start,
            'endDate', v_tournament_end,
            'courseTimezone', v_course_timezone
        ),
        'accessDate', v_access_date,
        'registration', jsonb_build_object(
            'id', v_registration_id,
            'folio', v_folio
        ),
        'player', jsonb_build_object(
            'id', v_player_id,
            'firstNames', v_player_names,
            'lastNames', v_player_surnames,
            'displayName', btrim(concat_ws(' ', v_player_names, v_player_surnames))
        ),
        'accessPoint', jsonb_build_object(
            'assignmentId', v_assignment_id,
            'id', v_access_point_id,
            'name', v_access_point_name,
            'responsibleName', v_responsible_name
        ),
        'instructions', jsonb_build_object(
            'physicalIdRequired', true,
            'message', 'Solicite una identificación física y confirme que corresponde a la persona mostrada antes de registrar el ingreso.'
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.validar_qr_jugador_acceso_361(text,text)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.validar_qr_jugador_acceso_361(text,text)
TO anon, authenticated;

COMMIT;
