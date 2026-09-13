-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 304
-- Acceso QR seguro por estación de Premios Especiales
--
-- Alcance:
--   - Crea un acceso QR independiente por estación.
--   - NO reutiliza qr_token de inscripciones ni tarjetas.
--   - El token es un bearer token aleatorio de 32 bytes (64 hex).
--   - El responsable NO necesita iniciar sesión.
--   - El acceso público por token expone sólo contexto operativo mínimo:
--       torneo, ronda, hoyo, estación y premios activos asignados.
--   - El organizador/superadmin puede generar/rotar y desactivar el acceso.
--
-- NO incluye todavía:
--   - lista completa de participantes,
--   - captura de mediciones/valores,
--   - testigos,
--   - correcciones,
--   - REPORTE PROVISIONAL EN LÍNEA,
--   - mensajería,
--   - adjudicación final.
--
-- IMPORTANTE:
--   Ejecutar manualmente por el usuario en Supabase.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 01. TABLA DE ACCESO QR POR ESTACIÓN
-- --------------------------------------------------------------------------

create table if not exists public.tournament_special_prize_station_access (
    id uuid primary key default gen_random_uuid(),

    station_id uuid not null unique
        references public.tournament_special_prize_stations(id)
        on update restrict
        on delete restrict,

    qr_token text not null unique
        default encode(gen_random_bytes(32), 'hex'),

    activo boolean not null default true,

    generado_at timestamptz not null default now(),
    rotado_at timestamptz,
    desactivado_at timestamptz,

    created_by uuid
        references public.admin_users(id)
        on update restrict
        on delete restrict,

    updated_by uuid
        references public.admin_users(id)
        on update restrict
        on delete restrict,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint tournament_special_prize_station_access_qr_ck
        check (qr_token ~ '^[0-9a-f]{64}$')
);

comment on table public.tournament_special_prize_station_access is
'Acceso QR independiente para estaciones de Premios Especiales. El token funciona como credencial bearer y no se reutiliza desde inscripciones o tarjetas.';

comment on column public.tournament_special_prize_station_access.qr_token is
'Token aleatorio de 32 bytes codificado en hexadecimal. Debe tratarse como credencial de acceso.';

comment on column public.tournament_special_prize_station_access.activo is
'Permite invalidar el QR sin eliminar la estación ni su historial.';


-- --------------------------------------------------------------------------
-- 02. ÍNDICES
-- --------------------------------------------------------------------------

create index if not exists
    ix_tournament_special_prize_station_access_active
on public.tournament_special_prize_station_access (
    station_id,
    activo
);


-- --------------------------------------------------------------------------
-- 03. UPDATED_AT
--     Deliberadamente NO se conecta log_audit() a esta tabla porque el
--     audit_log serializa filas completas y no queremos copiar qr_token.
-- --------------------------------------------------------------------------

drop trigger if exists
    trg_tournament_special_prize_station_access_updated_at
on public.tournament_special_prize_station_access;

create trigger trg_tournament_special_prize_station_access_updated_at
before update
on public.tournament_special_prize_station_access
for each row
execute function public.set_updated_at();


-- --------------------------------------------------------------------------
-- 04. RLS
--     Los organizadores pueden LEER el token de sus propias estaciones
--     para renderizar el QR. Las mutaciones se hacen sólo por RPC.
-- --------------------------------------------------------------------------

alter table public.tournament_special_prize_station_access
enable row level security;

drop policy if exists
    tournament_special_prize_station_access_select
on public.tournament_special_prize_station_access;

create policy tournament_special_prize_station_access_select
on public.tournament_special_prize_station_access
for select
to authenticated
using (
    exists (
        select 1
        from public.tournament_special_prize_stations s
        where s.id = station_id
          and (
              public.is_superadmin(auth.uid())
              or public.is_tournament_organizer(auth.uid(), s.tournament_id)
          )
    )
);

-- No INSERT/UPDATE/DELETE directo para authenticated.


-- --------------------------------------------------------------------------
-- 05. GRANTS DE TABLA
-- --------------------------------------------------------------------------

revoke all
on table public.tournament_special_prize_station_access
from anon, authenticated;

grant select
on table public.tournament_special_prize_station_access
to authenticated;

grant select, insert, update
on table public.tournament_special_prize_station_access
to service_role;


-- --------------------------------------------------------------------------
-- 06. GENERAR O ROTAR QR
-- --------------------------------------------------------------------------

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

    v_token := encode(gen_random_bytes(32), 'hex');

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

revoke all on function public.generar_o_rotar_qr_estacion_premios_304(uuid)
from public, anon;

grant execute on function public.generar_o_rotar_qr_estacion_premios_304(uuid)
to authenticated;


-- --------------------------------------------------------------------------
-- 07. DESACTIVAR QR
-- --------------------------------------------------------------------------

create or replace function public.desactivar_qr_estacion_premios_304(
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
begin
    v_auth_uid := auth.uid();

    if v_auth_uid is null then
        raise exception 'No autenticado.'
            using errcode = '42501';
    end if;

    v_admin_id := public.current_admin_id();

    select s.tournament_id
      into v_tournament_id
      from public.tournament_special_prize_stations s
     where s.id = p_station_id;

    if not found then
        raise exception 'La estación indicada no existe.'
            using errcode = '23503';
    end if;

    if not (
        public.is_superadmin(v_auth_uid)
        or public.is_tournament_organizer(v_auth_uid, v_tournament_id)
    ) then
        raise exception
            'No tienes autorización para administrar el QR de esta estación.'
            using errcode = '42501';
    end if;

    update public.tournament_special_prize_station_access
       set activo = false,
           desactivado_at = now(),
           updated_by = v_admin_id
     where station_id = p_station_id;

    if not found then
        raise exception
            'La estación no tiene un acceso QR generado.'
            using errcode = 'P0002';
    end if;

    return jsonb_build_object(
        'ok', true,
        'stationId', p_station_id,
        'active', false
    );
end;
$function$;

revoke all on function public.desactivar_qr_estacion_premios_304(uuid)
from public, anon;

grant execute on function public.desactivar_qr_estacion_premios_304(uuid)
to authenticated;


-- --------------------------------------------------------------------------
-- 08. ACCESO PÚBLICO POR QR
--     Sólo contexto operativo mínimo. No devuelve qr_token ni información
--     privada adicional del organizador.
-- --------------------------------------------------------------------------

create or replace function public.obtener_estacion_premios_por_qr_304(
    p_qr_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_token text;
    v_station_id uuid;
    v_result jsonb;
begin
    v_token := lower(btrim(coalesce(p_qr_token, '')));

    if v_token !~ '^[0-9a-f]{64}$' then
        raise exception 'Código QR inválido.'
            using errcode = '22023';
    end if;

    select s.id
      into v_station_id
      from public.tournament_special_prize_station_access a
      join public.tournament_special_prize_stations s
        on s.id = a.station_id
      join public.tournaments t
        on t.id = s.tournament_id
      join public.tournament_rounds tr
        on tr.id = s.tournament_round_id
     where a.qr_token = v_token
       and a.activo = true
       and s.activo = true
       and t.activo = true
       and tr.activo = true
     limit 1;

    if v_station_id is null then
        raise exception
            'El acceso QR no existe, está desactivado o ya no es válido.'
            using errcode = '42501';
    end if;

    select jsonb_build_object(
        'ok', true,
        'station', jsonb_build_object(
            'id', s.id,
            'label', s.etiqueta,
            'responsibleName', s.responsable_nombre,
            'operationalNotes', s.notas_operativas
        ),
        'tournament', jsonb_build_object(
            'id', t.id,
            'name', t.nombre,
            'startDate', t.fecha_inicio,
            'endDate', t.fecha_fin
        ),
        'round', jsonb_build_object(
            'id', tr.id,
            'number', tr.numero_ronda,
            'date', tr.fecha
        ),
        'hole', jsonb_build_object(
            'id', h.id,
            'number', h.numero_hoyo,
            'par', h.par
        ),
        'prizes', coalesce(
            (
                select jsonb_agg(
                    jsonb_build_object(
                        'id', p.id,
                        'name', p.nombre_snapshot,
                        'valueType', p.tipo_valor_snapshot,
                        'comparison', p.criterio_comparacion_snapshot,
                        'captureUnit', p.unidad_captura,
                        'referenceType', p.tipo_referencia,
                        'requiresFairway', p.requiere_fairway,
                        'requiresGreen', p.requiere_green,
                        'evaluatedStroke', p.numero_golpe_evaluado,
                        'operationalDescription', p.descripcion_operativa,
                        'sponsor', p.patrocinador,
                        'prizeOffered', p.premio_ofrecido
                    )
                    order by p.nombre_snapshot
                )
                from public.tournament_special_prizes p
                where p.station_id = s.id
                  and p.activo = true
            ),
            '[]'::jsonb
        )
    )
      into v_result
      from public.tournament_special_prize_stations s
      join public.tournaments t
        on t.id = s.tournament_id
      join public.tournament_rounds tr
        on tr.id = s.tournament_round_id
      join public.hoyos h
        on h.id = s.hoyo_id
     where s.id = v_station_id;

    return v_result;
end;
$function$;

revoke all on function public.obtener_estacion_premios_por_qr_304(text)
from public;

grant execute on function public.obtener_estacion_premios_por_qr_304(text)
to anon, authenticated;


commit;
