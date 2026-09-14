-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 313
-- Corrección de generación de token QR para estaciones de Premios Especiales
-- ============================================================================

begin;

create or replace function public.generar_o_rotar_qr_estacion_premios_304(
    p_station_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_auth_uid uuid;
    v_admin_id uuid;
    v_tournament_id uuid;
    v_station_active boolean;
    v_access_id uuid;
    v_token text;
    v_existing boolean := false;
begin
    v_auth_uid := auth.uid();

    if v_auth_uid is null then
        raise exception 'No autenticado.'
            using errcode = '42501';
    end if;

    v_admin_id := public.current_admin_id();

    select
        s.tournament_id,
        s.activo
      into
        v_tournament_id,
        v_station_active
      from public.tournament_special_prize_stations s
     where s.id = p_station_id
     for update;

    if not found then
        raise exception 'La estación indicada no existe.'
            using errcode = '23503';
    end if;

    if coalesce(v_station_active, false) = false then
        raise exception
            'No se puede generar acceso QR para una estación inactiva.'
            using errcode = '55000';
    end if;

    if not (
        public.is_superadmin(v_auth_uid)
        or public.is_tournament_organizer(v_auth_uid, v_tournament_id)
    ) then
        raise exception
            'No tienes autorización para administrar el QR de esta estación.'
            using errcode = '42501';
    end if;

    select true
      into v_existing
      from public.tournament_special_prize_station_access a
     where a.station_id = p_station_id
     limit 1;

    v_token := encode(extensions.gen_random_bytes(32), 'hex');

    if coalesce(v_existing, false) = false then
        insert into public.tournament_special_prize_station_access (
            station_id,
            qr_token,
            activo,
            generado_at,
            created_by,
            updated_by
        )
        values (
            p_station_id,
            v_token,
            true,
            now(),
            v_admin_id,
            v_admin_id
        )
        returning id into v_access_id;
    else
        update public.tournament_special_prize_station_access
           set qr_token = v_token,
               activo = true,
               rotado_at = now(),
               desactivado_at = null,
               updated_by = v_admin_id
         where station_id = p_station_id
        returning id into v_access_id;
    end if;

    return jsonb_build_object(
        'ok', true,
        'stationId', p_station_id,
        'accessId', v_access_id,
        'qrToken', v_token,
        'active', true
    );
end;
$function$;

commit;
