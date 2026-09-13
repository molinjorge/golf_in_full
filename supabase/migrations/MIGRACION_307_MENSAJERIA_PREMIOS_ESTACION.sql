-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 307
-- Mensajería bidireccional de Premios Especiales por estación
--
-- Alcance:
--   - Crea un hilo de mensajes append-only por estación.
--   - El responsable envía/consulta mensajes mediante el QR de su estación.
--   - El organizador/superadmin envía/consulta mensajes autenticado.
--   - Un mensaje puede referirse opcionalmente a un premio de esa estación.
--   - Conserva contexto de torneo, ronda, hoyo y estación.
--   - No permite editar ni borrar mensajes.
--
-- NO incluye todavía:
--   - notificaciones push/WhatsApp/email,
--   - estados leído/no leído,
--   - archivos adjuntos,
--   - adjudicación oficial del premio.
--
-- IMPORTANTE:
--   Ejecutar manualmente por el usuario en Supabase.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 01. TABLA DE MENSAJES
-- --------------------------------------------------------------------------

create table if not exists public.tournament_special_prize_messages (
    id uuid primary key default gen_random_uuid(),

    tournament_id uuid not null
        references public.tournaments(id)
        on update restrict
        on delete restrict,

    tournament_round_id uuid not null
        references public.tournament_rounds(id)
        on update restrict
        on delete restrict,

    station_id uuid not null
        references public.tournament_special_prize_stations(id)
        on update restrict
        on delete restrict,

    tournament_special_prize_id uuid
        references public.tournament_special_prizes(id)
        on update restrict
        on delete restrict,

    sender_type text not null,
    sender_admin_id uuid
        references public.admin_users(id)
        on update restrict
        on delete restrict,

    sender_name_snapshot text not null,
    mensaje text not null,

    sent_at timestamptz not null default now(),
    created_at timestamptz not null default now(),

    constraint tournament_special_prize_messages_sender_type_ck
        check (sender_type in ('RESPONSABLE', 'ORGANIZADOR')),

    constraint tournament_special_prize_messages_sender_admin_ck
        check (
            (sender_type = 'RESPONSABLE' and sender_admin_id is null)
            or
            (sender_type = 'ORGANIZADOR' and sender_admin_id is not null)
        ),

    constraint tournament_special_prize_messages_sender_name_ck
        check (char_length(btrim(sender_name_snapshot)) >= 2),

    constraint tournament_special_prize_messages_text_ck
        check (char_length(btrim(mensaje)) between 1 and 2000)
);

comment on table public.tournament_special_prize_messages is
'Mensajería operativa append-only entre responsable de estación y organizador para Premios Especiales.';

comment on column public.tournament_special_prize_messages.tournament_special_prize_id is
'Contexto opcional de un premio concreto; si se informa debe pertenecer a la misma estación.';

comment on column public.tournament_special_prize_messages.sender_type is
'RESPONSABLE cuando se envía por QR; ORGANIZADOR cuando se envía autenticado.';


-- --------------------------------------------------------------------------
-- 02. ÍNDICES
-- --------------------------------------------------------------------------

create index if not exists ix_tournament_special_prize_messages_station
on public.tournament_special_prize_messages (
    station_id,
    sent_at,
    id
);

create index if not exists ix_tournament_special_prize_messages_tournament
on public.tournament_special_prize_messages (
    tournament_id,
    tournament_round_id,
    sent_at
);

create index if not exists ix_tournament_special_prize_messages_prize
on public.tournament_special_prize_messages (
    tournament_special_prize_id,
    sent_at
)
where tournament_special_prize_id is not null;


-- --------------------------------------------------------------------------
-- 03. PROTECCIÓN APPEND-ONLY
-- --------------------------------------------------------------------------

create or replace function public.proteger_mensaje_premio_especial_307()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
    if tg_op in ('UPDATE', 'DELETE') then
        raise exception
            'Los mensajes de Premios Especiales son inmutables y no se pueden editar ni borrar.'
            using errcode = '55000';
    end if;

    new.sender_name_snapshot := btrim(new.sender_name_snapshot);
    new.mensaje := btrim(new.mensaje);

    return new;
end;
$function$;

revoke all on function public.proteger_mensaje_premio_especial_307()
from public, anon, authenticated;

drop trigger if exists trg_proteger_mensaje_premio_especial_307
on public.tournament_special_prize_messages;

create trigger trg_proteger_mensaje_premio_especial_307
before insert or update or delete
on public.tournament_special_prize_messages
for each row
execute function public.proteger_mensaje_premio_especial_307();


-- --------------------------------------------------------------------------
-- 04. RLS / GRANTS
--     authenticated puede leer sólo mensajes de torneos que administra.
--     Toda inserción se realiza mediante RPC.
--     anon no tiene acceso directo a la tabla.
-- --------------------------------------------------------------------------

alter table public.tournament_special_prize_messages enable row level security;

drop policy if exists tournament_special_prize_messages_select
on public.tournament_special_prize_messages;

create policy tournament_special_prize_messages_select
on public.tournament_special_prize_messages
for select
to authenticated
using (
    public.is_superadmin(auth.uid())
    or public.is_tournament_organizer(auth.uid(), tournament_id)
);

revoke all on table public.tournament_special_prize_messages
from anon, authenticated;

grant select on table public.tournament_special_prize_messages
to authenticated;

grant select, insert on table public.tournament_special_prize_messages
to service_role;


-- --------------------------------------------------------------------------
-- 05. RESPONSABLE: ENVIAR MENSAJE POR QR
-- --------------------------------------------------------------------------

create or replace function public.enviar_mensaje_responsable_premios_qr_307(
    p_qr_token text,
    p_mensaje text,
    p_tournament_special_prize_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_token text;
    v_station_id uuid;
    v_tournament_id uuid;
    v_round_id uuid;
    v_responsable_nombre text;
    v_message_id uuid;
begin
    v_token := lower(btrim(coalesce(p_qr_token, '')));

    if v_token !~ '^[0-9a-f]{64}$' then
        raise exception 'Código QR inválido.'
            using errcode = '22023';
    end if;

    if nullif(btrim(coalesce(p_mensaje, '')), '') is null
       or char_length(btrim(p_mensaje)) > 2000
    then
        raise exception 'El mensaje debe contener entre 1 y 2000 caracteres.'
            using errcode = '22023';
    end if;

    select
        s.id,
        s.tournament_id,
        s.tournament_round_id,
        s.responsable_nombre
      into
        v_station_id,
        v_tournament_id,
        v_round_id,
        v_responsable_nombre
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

    if p_tournament_special_prize_id is not null
       and not exists (
            select 1
            from public.tournament_special_prizes sp
            where sp.id = p_tournament_special_prize_id
              and sp.station_id = v_station_id
              and sp.tournament_id = v_tournament_id
              and sp.tournament_round_id = v_round_id
       )
    then
        raise exception
            'El premio indicado no pertenece a esta estación.'
            using errcode = '23514';
    end if;

    insert into public.tournament_special_prize_messages (
        tournament_id,
        tournament_round_id,
        station_id,
        tournament_special_prize_id,
        sender_type,
        sender_admin_id,
        sender_name_snapshot,
        mensaje
    )
    values (
        v_tournament_id,
        v_round_id,
        v_station_id,
        p_tournament_special_prize_id,
        'RESPONSABLE',
        null,
        v_responsable_nombre,
        btrim(p_mensaje)
    )
    returning id into v_message_id;

    return jsonb_build_object(
        'ok', true,
        'messageId', v_message_id,
        'stationId', v_station_id,
        'senderType', 'RESPONSABLE'
    );
end;
$function$;

revoke all on function public.enviar_mensaje_responsable_premios_qr_307(text, text, uuid)
from public;

grant execute on function public.enviar_mensaje_responsable_premios_qr_307(text, text, uuid)
to anon, authenticated;


-- --------------------------------------------------------------------------
-- 06. RESPONSABLE: CONSULTAR HILO POR QR
-- --------------------------------------------------------------------------

create or replace function public.obtener_mensajes_estacion_premios_qr_307(
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
        'stationId', v_station_id,
        'messages', coalesce(
            jsonb_agg(
                jsonb_build_object(
                    'id', m.id,
                    'prizeId', m.tournament_special_prize_id,
                    'senderType', m.sender_type,
                    'senderName', m.sender_name_snapshot,
                    'message', m.mensaje,
                    'sentAt', m.sent_at
                )
                order by m.sent_at, m.id
            ) filter (where m.id is not null),
            '[]'::jsonb
        )
    )
      into v_result
      from public.tournament_special_prize_messages m
     where m.station_id = v_station_id;

    return v_result;
end;
$function$;

revoke all on function public.obtener_mensajes_estacion_premios_qr_307(text)
from public;

grant execute on function public.obtener_mensajes_estacion_premios_qr_307(text)
to anon, authenticated;


-- --------------------------------------------------------------------------
-- 07. ORGANIZADOR: ENVIAR MENSAJE A UNA ESTACIÓN
-- --------------------------------------------------------------------------

create or replace function public.enviar_mensaje_organizador_premios_307(
    p_station_id uuid,
    p_mensaje text,
    p_tournament_special_prize_id uuid default null
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
    v_round_id uuid;
    v_admin_name text;
    v_message_id uuid;
begin
    v_auth_uid := auth.uid();

    if v_auth_uid is null then
        raise exception 'No autenticado.'
            using errcode = '42501';
    end if;

    if nullif(btrim(coalesce(p_mensaje, '')), '') is null
       or char_length(btrim(p_mensaje)) > 2000
    then
        raise exception 'El mensaje debe contener entre 1 y 2000 caracteres.'
            using errcode = '22023';
    end if;

    select s.tournament_id, s.tournament_round_id
      into v_tournament_id, v_round_id
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
            'No tienes autorización para enviar mensajes a esta estación.'
            using errcode = '42501';
    end if;

    if p_tournament_special_prize_id is not null
       and not exists (
            select 1
            from public.tournament_special_prizes sp
            where sp.id = p_tournament_special_prize_id
              and sp.station_id = p_station_id
              and sp.tournament_id = v_tournament_id
              and sp.tournament_round_id = v_round_id
       )
    then
        raise exception
            'El premio indicado no pertenece a esta estación.'
            using errcode = '23514';
    end if;

    v_admin_id := public.current_admin_id();

    if v_admin_id is null then
        raise exception
            'No se encontró el perfil administrativo del usuario autenticado.'
            using errcode = '42501';
    end if;

    select concat_ws(' ', au.nombres, au.apellidos)
      into v_admin_name
      from public.admin_users au
     where au.id = v_admin_id;

    v_admin_name := nullif(btrim(coalesce(v_admin_name, '')), '');

    if v_admin_name is null then
        v_admin_name := 'Organizador';
    end if;

    insert into public.tournament_special_prize_messages (
        tournament_id,
        tournament_round_id,
        station_id,
        tournament_special_prize_id,
        sender_type,
        sender_admin_id,
        sender_name_snapshot,
        mensaje
    )
    values (
        v_tournament_id,
        v_round_id,
        p_station_id,
        p_tournament_special_prize_id,
        'ORGANIZADOR',
        v_admin_id,
        v_admin_name,
        btrim(p_mensaje)
    )
    returning id into v_message_id;

    return jsonb_build_object(
        'ok', true,
        'messageId', v_message_id,
        'stationId', p_station_id,
        'senderType', 'ORGANIZADOR'
    );
end;
$function$;

revoke all on function public.enviar_mensaje_organizador_premios_307(uuid, text, uuid)
from public, anon;

grant execute on function public.enviar_mensaje_organizador_premios_307(uuid, text, uuid)
to authenticated;


-- --------------------------------------------------------------------------
-- 08. ORGANIZADOR: CONSULTAR HILO DE UNA ESTACIÓN
-- --------------------------------------------------------------------------

create or replace function public.obtener_mensajes_estacion_premios_organizador_307(
    p_station_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_auth_uid uuid;
    v_tournament_id uuid;
    v_round_id uuid;
    v_hole_id uuid;
    v_station_label text;
    v_responsable_nombre text;
    v_result jsonb;
begin
    v_auth_uid := auth.uid();

    if v_auth_uid is null then
        raise exception 'No autenticado.'
            using errcode = '42501';
    end if;

    select
        s.tournament_id,
        s.tournament_round_id,
        s.hoyo_id,
        s.etiqueta,
        s.responsable_nombre
      into
        v_tournament_id,
        v_round_id,
        v_hole_id,
        v_station_label,
        v_responsable_nombre
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
            'No tienes autorización para consultar mensajes de esta estación.'
            using errcode = '42501';
    end if;

    select jsonb_build_object(
        'ok', true,
        'station', jsonb_build_object(
            'id', p_station_id,
            'tournamentId', v_tournament_id,
            'roundId', v_round_id,
            'holeId', v_hole_id,
            'label', v_station_label,
            'responsibleName', v_responsable_nombre
        ),
        'messages', coalesce(
            jsonb_agg(
                jsonb_build_object(
                    'id', m.id,
                    'prizeId', m.tournament_special_prize_id,
                    'senderType', m.sender_type,
                    'senderAdminId', m.sender_admin_id,
                    'senderName', m.sender_name_snapshot,
                    'message', m.mensaje,
                    'sentAt', m.sent_at
                )
                order by m.sent_at, m.id
            ) filter (where m.id is not null),
            '[]'::jsonb
        )
    )
      into v_result
      from public.tournament_special_prize_messages m
     where m.station_id = p_station_id;

    return v_result;
end;
$function$;

revoke all on function public.obtener_mensajes_estacion_premios_organizador_307(uuid)
from public, anon;

grant execute on function public.obtener_mensajes_estacion_premios_organizador_307(uuid)
to authenticated;

commit;
