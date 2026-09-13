-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 305
-- Roster válido de ronda + captura móvil de Premios Especiales
--
-- Alcance:
--   - Expone por QR el roster de jugadores aplicable a la ronda.
--   - Prefiere la última validación de salidas vigente de la ronda.
--   - En modalidades por equipo expande los equipos validados a sus jugadores
--     activos; NO trata al equipo como ganador de un premio individual.
--   - Si todavía no existe una validación vigente, usa como fallback las
--     inscripciones activas del torneo para no convertir Premios Especiales
--     en un bloqueo del ciclo competitivo.
--   - Registra candidatos por jugador y premio.
--   - Captura valor/medición, unidad snapshot y testigo.
--   - Permite corrección e invalidación por QR con motivo obligatorio.
--   - Conserva historial inmutable de cada cambio; no borra registros.
--
-- NO incluye todavía:
--   - REPORTE PROVISIONAL EN LÍNEA del organizador,
--   - mensajería responsable <-> organizador,
--   - adjudicación oficial del ganador.
--
-- IMPORTANTE:
--   Ejecutar manualmente por el usuario en Supabase.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 01. REGISTROS/CANDIDATOS CAPTURADOS
-- --------------------------------------------------------------------------

create table if not exists public.tournament_special_prize_entries (
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

    tournament_special_prize_id uuid not null
        references public.tournament_special_prizes(id)
        on update restrict
        on delete restrict,

    tournament_registration_id uuid not null
        references public.tournament_registrations(id)
        on update restrict
        on delete restrict,

    player_id uuid not null
        references public.players(id)
        on update restrict
        on delete restrict,

    valor numeric not null,
    unidad_snapshot text,

    testigo_nombre text not null,
    testigo_confirmado boolean not null default true,

    estatus text not null default 'VALIDO',
    motivo_invalido text,

    capturado_via text not null default 'QR_ESTACION',
    capturado_at timestamptz not null default now(),

    -- Se usa para documentar la última mutación; el trigger de historial
    -- conserva la versión anterior junto con este motivo.
    motivo_ultima_correccion text,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint tournament_special_prize_entries_valor_ck
        check (valor >= 0),

    constraint tournament_special_prize_entries_testigo_ck
        check (
            nullif(btrim(testigo_nombre), '') is not null
            and testigo_confirmado = true
        ),

    constraint tournament_special_prize_entries_estatus_ck
        check (estatus in ('VALIDO', 'INVALIDO')),

    constraint tournament_special_prize_entries_invalido_ck
        check (
            (estatus = 'VALIDO' and motivo_invalido is null)
            or
            (
                estatus = 'INVALIDO'
                and nullif(btrim(motivo_invalido), '') is not null
            )
        ),

    constraint tournament_special_prize_entries_captura_ck
        check (capturado_via in ('QR_ESTACION', 'ORGANIZADOR'))
);

comment on table public.tournament_special_prize_entries is
'Candidatos capturados para Premios Especiales por jugador. Independientes del scoring y de la adjudicación oficial.';

comment on column public.tournament_special_prize_entries.valor is
'Valor numérico capturado según el tipo del premio; no modifica score deportivo.';

comment on column public.tournament_special_prize_entries.testigo_nombre is
'Nombre del testigo del registro de campo. La hoja física firmada sigue siendo evidencia operativa.';

comment on column public.tournament_special_prize_entries.estatus is
'VALIDO o INVALIDO. Los registros no se eliminan físicamente.';


-- Sólo un registro vigente/valido por jugador y premio.
create unique index if not exists
    uq_tournament_special_prize_entries_valid_player
on public.tournament_special_prize_entries (
    tournament_special_prize_id,
    tournament_registration_id
)
where estatus = 'VALIDO';

create index if not exists
    ix_tournament_special_prize_entries_station
on public.tournament_special_prize_entries (
    station_id,
    tournament_special_prize_id,
    estatus,
    capturado_at
);

create index if not exists
    ix_tournament_special_prize_entries_round
on public.tournament_special_prize_entries (
    tournament_round_id,
    tournament_special_prize_id,
    estatus
);


-- --------------------------------------------------------------------------
-- 02. HISTORIAL INMUTABLE DE CAMBIOS
-- --------------------------------------------------------------------------

create table if not exists public.tournament_special_prize_entry_history (
    id uuid primary key default gen_random_uuid(),

    entry_id uuid not null
        references public.tournament_special_prize_entries(id)
        on update restrict
        on delete restrict,

    version_no integer not null,

    valor_anterior numeric not null,
    unidad_snapshot_anterior text,

    testigo_nombre_anterior text not null,
    testigo_confirmado_anterior boolean not null,

    estatus_anterior text not null,
    motivo_invalido_anterior text,

    motivo_cambio text not null,
    cambiado_via text not null,

    changed_at timestamptz not null default now(),

    constraint tournament_special_prize_entry_history_version_ck
        check (version_no > 0),

    constraint tournament_special_prize_entry_history_motivo_ck
        check (char_length(btrim(motivo_cambio)) >= 5),

    constraint tournament_special_prize_entry_history_via_ck
        check (cambiado_via in ('QR_ESTACION', 'ORGANIZADOR')),

    constraint tournament_special_prize_entry_history_entry_version_uk
        unique (entry_id, version_no)
);

comment on table public.tournament_special_prize_entry_history is
'Historial append-only de correcciones e invalidaciones de registros de Premios Especiales.';


-- --------------------------------------------------------------------------
-- 03. PROTECCIÓN E HISTORIAL AUTOMÁTICO
-- --------------------------------------------------------------------------

create or replace function public.proteger_registro_premio_especial_305()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_next_version integer;
begin
    if tg_op = 'DELETE' then
        raise exception
            'Los registros de Premios Especiales no se eliminan; deben invalidarse.'
            using errcode = '55000';
    end if;

    if tg_op = 'INSERT' then
        new.testigo_nombre := btrim(new.testigo_nombre);
        new.unidad_snapshot := nullif(
            upper(btrim(coalesce(new.unidad_snapshot, ''))),
            ''
        );
        new.motivo_invalido := null;
        new.motivo_ultima_correccion := null;
        return new;
    end if;

    -- UPDATE: exige motivo y archiva SIEMPRE la versión anterior.
    if nullif(btrim(coalesce(new.motivo_ultima_correccion, '')), '') is null
       or char_length(btrim(new.motivo_ultima_correccion)) < 5
    then
        raise exception
            'Toda corrección o invalidación requiere un motivo de al menos 5 caracteres.'
            using errcode = '23514';
    end if;

    if new.tournament_id is distinct from old.tournament_id
       or new.tournament_round_id is distinct from old.tournament_round_id
       or new.station_id is distinct from old.station_id
       or new.tournament_special_prize_id is distinct from old.tournament_special_prize_id
       or new.tournament_registration_id is distinct from old.tournament_registration_id
       or new.player_id is distinct from old.player_id
       or new.created_at is distinct from old.created_at
       or new.capturado_at is distinct from old.capturado_at
    then
        raise exception
            'No se puede cambiar la identidad/origen de un registro capturado.'
            using errcode = '55000';
    end if;

    select coalesce(max(h.version_no), 0) + 1
      into v_next_version
      from public.tournament_special_prize_entry_history h
     where h.entry_id = old.id;

    insert into public.tournament_special_prize_entry_history (
        entry_id,
        version_no,
        valor_anterior,
        unidad_snapshot_anterior,
        testigo_nombre_anterior,
        testigo_confirmado_anterior,
        estatus_anterior,
        motivo_invalido_anterior,
        motivo_cambio,
        cambiado_via
    )
    values (
        old.id,
        v_next_version,
        old.valor,
        old.unidad_snapshot,
        old.testigo_nombre,
        old.testigo_confirmado,
        old.estatus,
        old.motivo_invalido,
        btrim(new.motivo_ultima_correccion),
        new.capturado_via
    );

    new.testigo_nombre := btrim(new.testigo_nombre);
    new.unidad_snapshot := nullif(
        upper(btrim(coalesce(new.unidad_snapshot, ''))),
        ''
    );
    new.motivo_invalido := nullif(
        btrim(coalesce(new.motivo_invalido, '')),
        ''
    );

    return new;
end;
$function$;

revoke all on function public.proteger_registro_premio_especial_305()
from public, anon, authenticated;

drop trigger if exists trg_proteger_registro_premio_especial_305
on public.tournament_special_prize_entries;

create trigger trg_proteger_registro_premio_especial_305
before insert or update or delete
on public.tournament_special_prize_entries
for each row
execute function public.proteger_registro_premio_especial_305();


drop trigger if exists trg_tournament_special_prize_entries_updated_at
on public.tournament_special_prize_entries;

create trigger trg_tournament_special_prize_entries_updated_at
before update
on public.tournament_special_prize_entries
for each row
execute function public.set_updated_at();


-- --------------------------------------------------------------------------
-- 04. RLS / GRANTS
--     Las mutaciones operativas se hacen sólo por RPC.
-- --------------------------------------------------------------------------

alter table public.tournament_special_prize_entries enable row level security;
alter table public.tournament_special_prize_entry_history enable row level security;

drop policy if exists tournament_special_prize_entries_select
on public.tournament_special_prize_entries;

create policy tournament_special_prize_entries_select
on public.tournament_special_prize_entries
for select
to authenticated
using (
    public.is_superadmin(auth.uid())
    or public.is_tournament_organizer(auth.uid(), tournament_id)
);

drop policy if exists tournament_special_prize_entry_history_select
on public.tournament_special_prize_entry_history;

create policy tournament_special_prize_entry_history_select
on public.tournament_special_prize_entry_history
for select
to authenticated
using (
    exists (
        select 1
        from public.tournament_special_prize_entries e
        where e.id = entry_id
          and (
              public.is_superadmin(auth.uid())
              or public.is_tournament_organizer(auth.uid(), e.tournament_id)
          )
    )
);

revoke all on table public.tournament_special_prize_entries
from anon, authenticated;

revoke all on table public.tournament_special_prize_entry_history
from anon, authenticated;

grant select on table public.tournament_special_prize_entries
to authenticated;

grant select on table public.tournament_special_prize_entry_history
to authenticated;

grant select, insert, update on table public.tournament_special_prize_entries
to service_role;

grant select, insert on table public.tournament_special_prize_entry_history
to service_role;


-- --------------------------------------------------------------------------
-- 05. ROSTER DE LA RONDA POR QR
--
-- Fuente primaria:
--   última start_validation con status='validated'.
--
-- Individual:
--   tournament_registration_id/player_id directamente desde unidades.
--
-- Equipo:
--   expande los tournament_team_id validados hacia inscripciones activas.
--
-- Fallback:
--   si no hay validación vigente, inscripciones activas del torneo.
--
-- Importante:
--   NUNCA filtra por el hoyo de salida. El hoyo de la estación es el hoyo
--   donde se disputa el premio, no el universo de elegibilidad.
-- --------------------------------------------------------------------------

create or replace function public.obtener_roster_estacion_premios_por_qr_305(
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
    v_tournament_id uuid;
    v_round_id uuid;
    v_validation_id uuid;
    v_source text;
    v_players jsonb;
begin
    v_token := lower(btrim(coalesce(p_qr_token, '')));

    if v_token !~ '^[0-9a-f]{64}$' then
        raise exception 'Código QR inválido.'
            using errcode = '22023';
    end if;

    select
        s.id,
        s.tournament_id,
        s.tournament_round_id
      into
        v_station_id,
        v_tournament_id,
        v_round_id
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

    select v.id
      into v_validation_id
      from public.tournament_round_start_validations v
     where v.tournament_round_id = v_round_id
       and v.status = 'validated'
     order by v.version desc
     limit 1;

    if v_validation_id is not null then
        v_source := 'VALIDATED_ROUND_START';

        with validated_registration_ids as (
            -- Unidades individuales validadas.
            select u.tournament_registration_id as registration_id
            from public.tournament_round_start_validation_units u
            where u.validation_id = v_validation_id
              and u.unit_type = 'registration'
              and u.tournament_registration_id is not null

            union

            -- Equipos validados expandidos a sus jugadores activos.
            select r.id
            from public.tournament_round_start_validation_units u
            join public.tournament_registrations r
              on r.tournament_team_id = u.tournament_team_id
             and r.tournament_id = v_tournament_id
             and r.activo = true
            join public.players p0
              on p0.id = r.player_id
             and p0.activo = true
            where u.validation_id = v_validation_id
              and u.unit_type = 'team'
              and u.tournament_team_id is not null
        )
        select coalesce(
            jsonb_agg(
                jsonb_build_object(
                    'registrationId', r.id,
                    'playerId', p.id,
                    'firstNames', p.nombres,
                    'lastNames', p.apellidos,
                    'email', p.email,
                    'teamId', r.tournament_team_id,
                    'teamName', tt.nombre_equipo
                )
                order by p.apellidos, p.nombres
            ),
            '[]'::jsonb
        )
          into v_players
          from validated_registration_ids vr
          join public.tournament_registrations r
            on r.id = vr.registration_id
           and r.tournament_id = v_tournament_id
           and r.activo = true
          join public.players p
            on p.id = r.player_id
           and p.activo = true
          left join public.tournament_teams tt
            on tt.id = r.tournament_team_id
           and tt.activo = true;

    else
        v_source := 'ACTIVE_REGISTRATIONS_FALLBACK';

        select coalesce(
            jsonb_agg(
                jsonb_build_object(
                    'registrationId', r.id,
                    'playerId', p.id,
                    'firstNames', p.nombres,
                    'lastNames', p.apellidos,
                    'email', p.email,
                    'teamId', r.tournament_team_id,
                    'teamName', tt.nombre_equipo
                )
                order by p.apellidos, p.nombres
            ),
            '[]'::jsonb
        )
          into v_players
          from public.tournament_registrations r
          join public.players p
            on p.id = r.player_id
           and p.activo = true
          left join public.tournament_teams tt
            on tt.id = r.tournament_team_id
           and tt.activo = true
         where r.tournament_id = v_tournament_id
           and r.activo = true;
    end if;

    return jsonb_build_object(
        'ok', true,
        'stationId', v_station_id,
        'tournamentId', v_tournament_id,
        'roundId', v_round_id,
        'rosterSource', v_source,
        'startValidationId', v_validation_id,
        'players', v_players
    );
end;
$function$;

revoke all on function public.obtener_roster_estacion_premios_por_qr_305(text)
from public;

grant execute on function public.obtener_roster_estacion_premios_por_qr_305(text)
to anon, authenticated;


-- --------------------------------------------------------------------------
-- 06. CAPTURAR CANDIDATO POR QR
-- --------------------------------------------------------------------------

create or replace function public.registrar_resultado_premio_qr_305(
    p_qr_token text,
    p_tournament_special_prize_id uuid,
    p_tournament_registration_id uuid,
    p_valor numeric,
    p_testigo_nombre text,
    p_testigo_confirmado boolean
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
    v_prize_station_id uuid;
    v_prize_tournament_id uuid;
    v_prize_round_id uuid;
    v_prize_unit text;
    v_prize_active boolean;
    v_registration_tournament_id uuid;
    v_player_id uuid;
    v_registration_active boolean;
    v_entry_id uuid;
    v_roster jsonb;
    v_in_roster boolean;
begin
    v_token := lower(btrim(coalesce(p_qr_token, '')));

    if v_token !~ '^[0-9a-f]{64}$' then
        raise exception 'Código QR inválido.'
            using errcode = '22023';
    end if;

    if p_valor is null or p_valor < 0 then
        raise exception 'El valor capturado debe ser mayor o igual a cero.'
            using errcode = '22023';
    end if;

    if nullif(btrim(coalesce(p_testigo_nombre, '')), '') is null
       or coalesce(p_testigo_confirmado, false) = false
    then
        raise exception
            'Debe registrarse un testigo y confirmar expresamente su validación.'
            using errcode = '23514';
    end if;

    select
        s.id,
        s.tournament_id,
        s.tournament_round_id
      into
        v_station_id,
        v_tournament_id,
        v_round_id
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

    select
        p.station_id,
        p.tournament_id,
        p.tournament_round_id,
        p.unidad_captura,
        p.activo
      into
        v_prize_station_id,
        v_prize_tournament_id,
        v_prize_round_id,
        v_prize_unit,
        v_prize_active
      from public.tournament_special_prizes p
     where p.id = p_tournament_special_prize_id;

    if not found
       or coalesce(v_prize_active, false) = false
       or v_prize_station_id is distinct from v_station_id
       or v_prize_tournament_id is distinct from v_tournament_id
       or v_prize_round_id is distinct from v_round_id
    then
        raise exception
            'El premio no pertenece a esta estación o no está activo.'
            using errcode = '42501';
    end if;

    select
        r.tournament_id,
        r.player_id,
        r.activo
      into
        v_registration_tournament_id,
        v_player_id,
        v_registration_active
      from public.tournament_registrations r
     where r.id = p_tournament_registration_id;

    if not found
       or coalesce(v_registration_active, false) = false
       or v_registration_tournament_id is distinct from v_tournament_id
    then
        raise exception
            'La inscripción del jugador no es válida para este torneo.'
            using errcode = '23514';
    end if;

    -- Se valida contra la misma lógica del roster expuesto al responsable.
    v_roster := public.obtener_roster_estacion_premios_por_qr_305(v_token);

    select exists (
        select 1
        from jsonb_array_elements(v_roster -> 'players') j
        where (j ->> 'registrationId')::uuid = p_tournament_registration_id
    )
    into v_in_roster;

    if not coalesce(v_in_roster, false) then
        raise exception
            'El jugador no pertenece al roster válido de esta ronda.'
            using errcode = '23514';
    end if;

    insert into public.tournament_special_prize_entries (
        tournament_id,
        tournament_round_id,
        station_id,
        tournament_special_prize_id,
        tournament_registration_id,
        player_id,
        valor,
        unidad_snapshot,
        testigo_nombre,
        testigo_confirmado,
        estatus,
        capturado_via
    )
    values (
        v_tournament_id,
        v_round_id,
        v_station_id,
        p_tournament_special_prize_id,
        p_tournament_registration_id,
        v_player_id,
        p_valor,
        v_prize_unit,
        btrim(p_testigo_nombre),
        true,
        'VALIDO',
        'QR_ESTACION'
    )
    returning id into v_entry_id;

    return jsonb_build_object(
        'ok', true,
        'entryId', v_entry_id,
        'stationId', v_station_id,
        'prizeId', p_tournament_special_prize_id,
        'registrationId', p_tournament_registration_id,
        'playerId', v_player_id,
        'value', p_valor,
        'unit', v_prize_unit,
        'status', 'VALIDO'
    );
end;
$function$;

revoke all on function public.registrar_resultado_premio_qr_305(
    text, uuid, uuid, numeric, text, boolean
)
from public;

grant execute on function public.registrar_resultado_premio_qr_305(
    text, uuid, uuid, numeric, text, boolean
)
to anon, authenticated;


-- --------------------------------------------------------------------------
-- 07. CORREGIR REGISTRO POR QR
-- --------------------------------------------------------------------------

create or replace function public.corregir_resultado_premio_qr_305(
    p_qr_token text,
    p_entry_id uuid,
    p_nuevo_valor numeric,
    p_testigo_nombre text,
    p_testigo_confirmado boolean,
    p_motivo text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_token text;
    v_station_id uuid;
    v_entry_station_id uuid;
begin
    v_token := lower(btrim(coalesce(p_qr_token, '')));

    if v_token !~ '^[0-9a-f]{64}$' then
        raise exception 'Código QR inválido.'
            using errcode = '22023';
    end if;

    if p_nuevo_valor is null or p_nuevo_valor < 0 then
        raise exception 'El nuevo valor debe ser mayor o igual a cero.'
            using errcode = '22023';
    end if;

    if nullif(btrim(coalesce(p_testigo_nombre, '')), '') is null
       or coalesce(p_testigo_confirmado, false) = false
    then
        raise exception
            'Debe registrarse un testigo y confirmar expresamente su validación.'
            using errcode = '23514';
    end if;

    if nullif(btrim(coalesce(p_motivo, '')), '') is null
       or char_length(btrim(p_motivo)) < 5
    then
        raise exception
            'La corrección requiere un motivo de al menos 5 caracteres.'
            using errcode = '23514';
    end if;

    select s.id
      into v_station_id
      from public.tournament_special_prize_station_access a
      join public.tournament_special_prize_stations s
        on s.id = a.station_id
     where a.qr_token = v_token
       and a.activo = true
       and s.activo = true
     limit 1;

    if v_station_id is null then
        raise exception
            'El acceso QR no existe, está desactivado o ya no es válido.'
            using errcode = '42501';
    end if;

    select e.station_id
      into v_entry_station_id
      from public.tournament_special_prize_entries e
     where e.id = p_entry_id
     for update;

    if not found or v_entry_station_id is distinct from v_station_id then
        raise exception
            'El registro no pertenece a esta estación.'
            using errcode = '42501';
    end if;

    update public.tournament_special_prize_entries
       set valor = p_nuevo_valor,
           testigo_nombre = btrim(p_testigo_nombre),
           testigo_confirmado = true,
           estatus = 'VALIDO',
           motivo_invalido = null,
           motivo_ultima_correccion = btrim(p_motivo),
           capturado_via = 'QR_ESTACION'
     where id = p_entry_id;

    return jsonb_build_object(
        'ok', true,
        'entryId', p_entry_id,
        'value', p_nuevo_valor,
        'status', 'VALIDO'
    );
end;
$function$;

revoke all on function public.corregir_resultado_premio_qr_305(
    text, uuid, numeric, text, boolean, text
)
from public;

grant execute on function public.corregir_resultado_premio_qr_305(
    text, uuid, numeric, text, boolean, text
)
to anon, authenticated;


-- --------------------------------------------------------------------------
-- 08. INVALIDAR REGISTRO POR QR
-- --------------------------------------------------------------------------

create or replace function public.invalidar_resultado_premio_qr_305(
    p_qr_token text,
    p_entry_id uuid,
    p_motivo text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_token text;
    v_station_id uuid;
    v_entry_station_id uuid;
begin
    v_token := lower(btrim(coalesce(p_qr_token, '')));

    if v_token !~ '^[0-9a-f]{64}$' then
        raise exception 'Código QR inválido.'
            using errcode = '22023';
    end if;

    if nullif(btrim(coalesce(p_motivo, '')), '') is null
       or char_length(btrim(p_motivo)) < 5
    then
        raise exception
            'La invalidación requiere un motivo de al menos 5 caracteres.'
            using errcode = '23514';
    end if;

    select s.id
      into v_station_id
      from public.tournament_special_prize_station_access a
      join public.tournament_special_prize_stations s
        on s.id = a.station_id
     where a.qr_token = v_token
       and a.activo = true
       and s.activo = true
     limit 1;

    if v_station_id is null then
        raise exception
            'El acceso QR no existe, está desactivado o ya no es válido.'
            using errcode = '42501';
    end if;

    select e.station_id
      into v_entry_station_id
      from public.tournament_special_prize_entries e
     where e.id = p_entry_id
     for update;

    if not found or v_entry_station_id is distinct from v_station_id then
        raise exception
            'El registro no pertenece a esta estación.'
            using errcode = '42501';
    end if;

    update public.tournament_special_prize_entries
       set estatus = 'INVALIDO',
           motivo_invalido = btrim(p_motivo),
           motivo_ultima_correccion = btrim(p_motivo),
           capturado_via = 'QR_ESTACION'
     where id = p_entry_id;

    return jsonb_build_object(
        'ok', true,
        'entryId', p_entry_id,
        'status', 'INVALIDO',
        'reason', btrim(p_motivo)
    );
end;
$function$;

revoke all on function public.invalidar_resultado_premio_qr_305(
    text, uuid, text
)
from public;

grant execute on function public.invalidar_resultado_premio_qr_305(
    text, uuid, text
)
to anon, authenticated;


commit;
