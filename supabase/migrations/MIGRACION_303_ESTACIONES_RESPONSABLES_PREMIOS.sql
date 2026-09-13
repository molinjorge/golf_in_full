-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 303
-- Estaciones y responsables de Premios Especiales
--
-- Alcance deliberadamente corto:
--   - Crea estaciones operativas por torneo / ronda / hoyo.
--   - Cada estación tiene responsable operativo (no requiere cuenta).
--   - Una estación puede atender varios premios del mismo hoyo/ronda.
--   - Un mismo hoyo/ronda puede tener más de una estación si los responsables
--     o accesos operativos son distintos.
--   - Vincula cada premio configurado a una estación compatible.
--
-- NO incluye todavía:
--   - QR / tokens de acceso,
--   - captura de mediciones,
--   - testigos,
--   - reporte provisional en línea,
--   - mensajería,
--   - adjudicación final.
--
-- IMPORTANTE:
--   Ejecutar manualmente por el usuario en Supabase.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 01. ESTACIONES OPERATIVAS
-- --------------------------------------------------------------------------

create table if not exists public.tournament_special_prize_stations (
    id uuid primary key default gen_random_uuid(),

    tournament_id uuid not null
        references public.tournaments(id)
        on update restrict
        on delete restrict,

    tournament_round_id uuid not null
        references public.tournament_rounds(id)
        on update restrict
        on delete restrict,

    hoyo_id uuid not null
        references public.hoyos(id)
        on update restrict
        on delete restrict,

    -- Nombre operativo opcional cuando un mismo hoyo/ronda tenga más de
    -- una estación o cuando el organizador quiera identificarla fácilmente.
    etiqueta text,

    -- El responsable no necesita ser admin_user ni tener cuenta.
    responsable_nombre text not null,
    responsable_telefono text,
    responsable_email text,

    notas_operativas text,

    activo boolean not null default true,

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

    constraint tournament_special_prize_stations_responsable_ck
        check (nullif(btrim(responsable_nombre), '') is not null)
);

comment on table public.tournament_special_prize_stations is
'Estaciones operativas para Premios Especiales. Una estación pertenece a torneo/ronda/hoyo y puede atender varios premios.';

comment on column public.tournament_special_prize_stations.responsable_nombre is
'Persona responsable de medición/anotación en la estación. No requiere cuenta administrativa.';

comment on column public.tournament_special_prize_stations.etiqueta is
'Identificador operativo opcional cuando exista más de una estación en el mismo hoyo/ronda.';


-- --------------------------------------------------------------------------
-- 02. VÍNCULO PREMIO -> ESTACIÓN
-- --------------------------------------------------------------------------

alter table public.tournament_special_prizes
    add column if not exists station_id uuid;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'tournament_special_prizes_station_id_fkey'
          and conrelid = 'public.tournament_special_prizes'::regclass
    ) then
        alter table public.tournament_special_prizes
            add constraint tournament_special_prizes_station_id_fkey
            foreign key (station_id)
            references public.tournament_special_prize_stations(id)
            on update restrict
            on delete restrict;
    end if;
end $$;

comment on column public.tournament_special_prizes.station_id is
'Estación operativa responsable de este premio. Varios premios del mismo hoyo/ronda pueden compartir estación.';


-- --------------------------------------------------------------------------
-- 03. ÍNDICES
-- --------------------------------------------------------------------------

create index if not exists
    ix_tournament_special_prize_stations_tournament
on public.tournament_special_prize_stations (
    tournament_id,
    tournament_round_id,
    hoyo_id,
    activo
);

create index if not exists
    ix_tournament_special_prize_stations_responsable
on public.tournament_special_prize_stations (
    tournament_id,
    responsable_nombre
)
where activo = true;

create index if not exists
    ix_tournament_special_prizes_station
on public.tournament_special_prizes (
    station_id,
    activo
)
where station_id is not null;


-- --------------------------------------------------------------------------
-- 04. VALIDACIÓN DE ESTACIÓN
-- --------------------------------------------------------------------------

create or replace function public.validar_estacion_premio_especial_303()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_admin_id uuid;
    v_round_tournament_id uuid;
    v_round_campo_id uuid;
    v_round_activo boolean;
    v_hole_campo_id uuid;
    v_tournament_activo boolean;
begin
    v_admin_id := public.current_admin_id();

    if tg_op = 'DELETE' then
        raise exception
            'Las estaciones de premios no se eliminan; deben desactivarse.'
            using errcode = '55000';
    end if;

    new.etiqueta := nullif(btrim(coalesce(new.etiqueta, '')), '');
    new.responsable_nombre := btrim(new.responsable_nombre);
    new.responsable_telefono := nullif(
        btrim(coalesce(new.responsable_telefono, '')),
        ''
    );
    new.responsable_email := nullif(
        lower(btrim(coalesce(new.responsable_email, ''))),
        ''
    );
    new.notas_operativas := nullif(
        btrim(coalesce(new.notas_operativas, '')),
        ''
    );

    select t.activo
      into v_tournament_activo
      from public.tournaments t
     where t.id = new.tournament_id;

    if not found then
        raise exception 'El torneo indicado no existe.'
            using errcode = '23503';
    end if;

    if coalesce(v_tournament_activo, false) = false then
        raise exception
            'No se puede crear o modificar una estación en un torneo inactivo.'
            using errcode = '55000';
    end if;

    select tr.tournament_id, tr.campo_golf_id, tr.activo
      into v_round_tournament_id, v_round_campo_id, v_round_activo
      from public.tournament_rounds tr
     where tr.id = new.tournament_round_id;

    if not found then
        raise exception 'La ronda indicada no existe.'
            using errcode = '23503';
    end if;

    if v_round_tournament_id is distinct from new.tournament_id then
        raise exception 'La ronda no pertenece al torneo indicado.'
            using errcode = '23514';
    end if;

    if coalesce(v_round_activo, false) = false then
        raise exception
            'No se puede crear o modificar una estación en una ronda inactiva.'
            using errcode = '55000';
    end if;

    select h.campo_golf_id
      into v_hole_campo_id
      from public.hoyos h
     where h.id = new.hoyo_id;

    if not found then
        raise exception 'El hoyo indicado no existe.'
            using errcode = '23503';
    end if;

    if v_hole_campo_id is distinct from v_round_campo_id then
        raise exception
            'El hoyo seleccionado no pertenece al campo de golf de la ronda.'
            using errcode = '23514';
    end if;

    if tg_op = 'INSERT' then
        if new.created_by is null and v_admin_id is not null then
            new.created_by := v_admin_id;
        end if;
        if new.updated_by is null and v_admin_id is not null then
            new.updated_by := v_admin_id;
        end if;
    elsif tg_op = 'UPDATE' then
        if new.created_by is distinct from old.created_by
           or new.created_at is distinct from old.created_at
        then
            raise exception
                'No se puede modificar la autoría original de la estación.'
                using errcode = '55000';
        end if;

        if v_admin_id is not null then
            new.updated_by := v_admin_id;
        end if;
    end if;

    return new;
end;
$function$;

revoke all on function public.validar_estacion_premio_especial_303()
from public, anon, authenticated;

drop trigger if exists trg_validar_estacion_premio_especial_303
on public.tournament_special_prize_stations;

create trigger trg_validar_estacion_premio_especial_303
before insert or update or delete
on public.tournament_special_prize_stations
for each row
execute function public.validar_estacion_premio_especial_303();


-- --------------------------------------------------------------------------
-- 05. VALIDAR COMPATIBILIDAD PREMIO <-> ESTACIÓN
-- --------------------------------------------------------------------------

create or replace function public.validar_asignacion_estacion_premio_303()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_station_tournament_id uuid;
    v_station_round_id uuid;
    v_station_hole_id uuid;
    v_station_activo boolean;
begin
    if new.station_id is null then
        return new;
    end if;

    select
        s.tournament_id,
        s.tournament_round_id,
        s.hoyo_id,
        s.activo
      into
        v_station_tournament_id,
        v_station_round_id,
        v_station_hole_id,
        v_station_activo
      from public.tournament_special_prize_stations s
     where s.id = new.station_id;

    if not found then
        raise exception 'La estación indicada no existe.'
            using errcode = '23503';
    end if;

    if coalesce(v_station_activo, false) = false then
        raise exception
            'No se puede asignar un premio a una estación inactiva.'
            using errcode = '55000';
    end if;

    if v_station_tournament_id is distinct from new.tournament_id
       or v_station_round_id is distinct from new.tournament_round_id
       or v_station_hole_id is distinct from new.hoyo_id
    then
        raise exception
            'La estación debe pertenecer al mismo torneo, ronda y hoyo que el premio.'
            using errcode = '23514';
    end if;

    return new;
end;
$function$;

revoke all on function public.validar_asignacion_estacion_premio_303()
from public, anon, authenticated;

drop trigger if exists trg_validar_asignacion_estacion_premio_303
on public.tournament_special_prizes;

create trigger trg_validar_asignacion_estacion_premio_303
before insert or update of station_id, tournament_id, tournament_round_id, hoyo_id
on public.tournament_special_prizes
for each row
execute function public.validar_asignacion_estacion_premio_303();


-- --------------------------------------------------------------------------
-- 06. UPDATED_AT + AUDITORÍA DE ESTACIONES
-- --------------------------------------------------------------------------

drop trigger if exists trg_tournament_special_prize_stations_updated_at
on public.tournament_special_prize_stations;

create trigger trg_tournament_special_prize_stations_updated_at
before update
on public.tournament_special_prize_stations
for each row
execute function public.set_updated_at();

drop trigger if exists trg_audit_tournament_special_prize_stations
on public.tournament_special_prize_stations;

create trigger trg_audit_tournament_special_prize_stations
after insert or update or delete
on public.tournament_special_prize_stations
for each row
execute function public.log_audit();


-- --------------------------------------------------------------------------
-- 07. RLS
-- --------------------------------------------------------------------------

alter table public.tournament_special_prize_stations enable row level security;

drop policy if exists tournament_special_prize_stations_select
on public.tournament_special_prize_stations;

create policy tournament_special_prize_stations_select
on public.tournament_special_prize_stations
for select
to authenticated
using (
    public.is_superadmin(auth.uid())
    or public.is_tournament_organizer(auth.uid(), tournament_id)
);

drop policy if exists tournament_special_prize_stations_insert
on public.tournament_special_prize_stations;

create policy tournament_special_prize_stations_insert
on public.tournament_special_prize_stations
for insert
to authenticated
with check (
    public.is_superadmin(auth.uid())
    or public.is_tournament_organizer(auth.uid(), tournament_id)
);

drop policy if exists tournament_special_prize_stations_update
on public.tournament_special_prize_stations;

create policy tournament_special_prize_stations_update
on public.tournament_special_prize_stations
for update
to authenticated
using (
    public.is_superadmin(auth.uid())
    or public.is_tournament_organizer(auth.uid(), tournament_id)
)
with check (
    public.is_superadmin(auth.uid())
    or public.is_tournament_organizer(auth.uid(), tournament_id)
);

-- No existe política DELETE.


-- --------------------------------------------------------------------------
-- 08. GRANTS
-- --------------------------------------------------------------------------

revoke all on table public.tournament_special_prize_stations from anon;
revoke delete on table public.tournament_special_prize_stations from authenticated;

grant select, insert, update
on table public.tournament_special_prize_stations
to authenticated;

grant select, insert, update
on table public.tournament_special_prize_stations
to service_role;

commit;
