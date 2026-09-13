-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 308
-- Adjudicación oficial de Premios Especiales
--
-- Alcance:
--   - Crea una cabecera versionada de adjudicación por premio.
--   - Crea posiciones oficiales asociadas a registros válidos capturados.
--   - Permite empates: varios jugadores pueden compartir la misma posición.
--   - NO convierte automáticamente el primer lugar provisional en ganador.
--   - La adjudicación requiere acción explícita del organizador/superadmin.
--   - Una adjudicación oficial puede ANULARSE con motivo; nunca se borra.
--   - Después de anularla puede emitirse una nueva versión oficial.
--   - Conserva snapshots de jugador, valor y unidad al momento de adjudicar.
--
-- NO incluye:
--   - frontend,
--   - publicación pública a jugadores,
--   - entrega física del premio,
--   - notificaciones.
--
-- IMPORTANTE:
--   Ejecutar manualmente por el usuario en Supabase.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 01. CABECERA VERSIONADA DE ADJUDICACIÓN
-- --------------------------------------------------------------------------

create table if not exists public.tournament_special_prize_adjudications (
    id uuid primary key default gen_random_uuid(),

    tournament_id uuid not null
        references public.tournaments(id)
        on update restrict
        on delete restrict,

    tournament_round_id uuid not null
        references public.tournament_rounds(id)
        on update restrict
        on delete restrict,

    tournament_special_prize_id uuid not null
        references public.tournament_special_prizes(id)
        on update restrict
        on delete restrict,

    version_no integer not null,
    status text not null default 'OFICIAL',

    observaciones text,

    adjudicated_by uuid not null
        references public.admin_users(id)
        on update restrict
        on delete restrict,
    adjudicated_at timestamptz not null default now(),

    annulled_by uuid
        references public.admin_users(id)
        on update restrict
        on delete restrict,
    annulled_at timestamptz,
    annul_reason text,

    created_at timestamptz not null default now(),

    constraint tournament_special_prize_adjudications_version_ck
        check (version_no > 0),

    constraint tournament_special_prize_adjudications_status_ck
        check (status in ('OFICIAL', 'ANULADA')),

    constraint tournament_special_prize_adjudications_annul_ck
        check (
            (
                status = 'OFICIAL'
                and annulled_by is null
                and annulled_at is null
                and annul_reason is null
            )
            or
            (
                status = 'ANULADA'
                and annulled_by is not null
                and annulled_at is not null
                and char_length(btrim(annul_reason)) >= 5
            )
        ),

    constraint tournament_special_prize_adjudications_version_uk
        unique (tournament_special_prize_id, version_no)
);

comment on table public.tournament_special_prize_adjudications is
'Versiones oficiales de adjudicación de un Premio Especial. No derivadas automáticamente del reporte provisional.';

create unique index if not exists uq_tournament_special_prize_adjudication_current
on public.tournament_special_prize_adjudications (tournament_special_prize_id)
where status = 'OFICIAL';

create index if not exists ix_tournament_special_prize_adjudications_tournament
on public.tournament_special_prize_adjudications (
    tournament_id,
    tournament_round_id,
    tournament_special_prize_id,
    version_no
);


-- --------------------------------------------------------------------------
-- 02. POSICIONES OFICIALES
--     La posición NO es unique: se permiten empates.
-- --------------------------------------------------------------------------

create table if not exists public.tournament_special_prize_awards (
    id uuid primary key default gen_random_uuid(),

    adjudication_id uuid not null
        references public.tournament_special_prize_adjudications(id)
        on update restrict
        on delete restrict,

    tournament_special_prize_id uuid not null
        references public.tournament_special_prizes(id)
        on update restrict
        on delete restrict,

    entry_id uuid not null
        references public.tournament_special_prize_entries(id)
        on update restrict
        on delete restrict,

    position integer not null,

    tournament_registration_id uuid not null
        references public.tournament_registrations(id)
        on update restrict
        on delete restrict,

    player_id uuid not null
        references public.players(id)
        on update restrict
        on delete restrict,

    player_name_snapshot text not null,
    value_snapshot numeric not null,
    unit_snapshot text,

    created_at timestamptz not null default now(),

    constraint tournament_special_prize_awards_position_ck
        check (position > 0),

    constraint tournament_special_prize_awards_player_name_ck
        check (char_length(btrim(player_name_snapshot)) >= 2),

    constraint tournament_special_prize_awards_entry_uk
        unique (adjudication_id, entry_id)
);

comment on table public.tournament_special_prize_awards is
'Posiciones oficiales de una adjudicación de Premio Especial. Varias filas pueden compartir position para representar empate.';

create index if not exists ix_tournament_special_prize_awards_position
on public.tournament_special_prize_awards (
    adjudication_id,
    position,
    id
);


-- --------------------------------------------------------------------------
-- 03. PROTECCIÓN: NO DELETE / POSICIONES INMUTABLES
-- --------------------------------------------------------------------------

create or replace function public.proteger_adjudicacion_premio_especial_308()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
    if tg_op = 'DELETE' then
        raise exception
            'Las adjudicaciones de Premios Especiales no se eliminan; deben anularse.'
            using errcode = '55000';
    end if;

    if tg_op = 'UPDATE' then
        if new.id is distinct from old.id
           or new.tournament_id is distinct from old.tournament_id
           or new.tournament_round_id is distinct from old.tournament_round_id
           or new.tournament_special_prize_id is distinct from old.tournament_special_prize_id
           or new.version_no is distinct from old.version_no
           or new.adjudicated_by is distinct from old.adjudicated_by
           or new.adjudicated_at is distinct from old.adjudicated_at
           or new.created_at is distinct from old.created_at
        then
            raise exception
                'No se puede cambiar la identidad de una adjudicación oficial.'
                using errcode = '55000';
        end if;

        if old.status = 'ANULADA' then
            raise exception
                'Una adjudicación anulada es inmutable.'
                using errcode = '55000';
        end if;

        if new.status <> 'ANULADA' then
            raise exception
                'Una adjudicación oficial sólo puede modificarse para anularla.'
                using errcode = '55000';
        end if;
    end if;

    return new;
end;
$function$;

revoke all on function public.proteger_adjudicacion_premio_especial_308()
from public, anon, authenticated;

drop trigger if exists trg_proteger_adjudicacion_premio_especial_308
on public.tournament_special_prize_adjudications;

create trigger trg_proteger_adjudicacion_premio_especial_308
before update or delete
on public.tournament_special_prize_adjudications
for each row
execute function public.proteger_adjudicacion_premio_especial_308();


create or replace function public.proteger_award_premio_especial_308()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
    if tg_op in ('UPDATE', 'DELETE') then
        raise exception
            'Las posiciones oficiales de Premios Especiales son inmutables.'
            using errcode = '55000';
    end if;
    return new;
end;
$function$;

revoke all on function public.proteger_award_premio_especial_308()
from public, anon, authenticated;

drop trigger if exists trg_proteger_award_premio_especial_308
on public.tournament_special_prize_awards;

create trigger trg_proteger_award_premio_especial_308
before update or delete
on public.tournament_special_prize_awards
for each row
execute function public.proteger_award_premio_especial_308();


-- --------------------------------------------------------------------------
-- 04. RLS / GRANTS
-- --------------------------------------------------------------------------

alter table public.tournament_special_prize_adjudications enable row level security;
alter table public.tournament_special_prize_awards enable row level security;

drop policy if exists tournament_special_prize_adjudications_select
on public.tournament_special_prize_adjudications;

create policy tournament_special_prize_adjudications_select
on public.tournament_special_prize_adjudications
for select
to authenticated
using (
    public.is_superadmin(auth.uid())
    or public.is_tournament_organizer(auth.uid(), tournament_id)
);


drop policy if exists tournament_special_prize_awards_select
on public.tournament_special_prize_awards;

create policy tournament_special_prize_awards_select
on public.tournament_special_prize_awards
for select
to authenticated
using (
    exists (
        select 1
        from public.tournament_special_prize_adjudications a
        where a.id = adjudication_id
          and (
              public.is_superadmin(auth.uid())
              or public.is_tournament_organizer(auth.uid(), a.tournament_id)
          )
    )
);

revoke all on table public.tournament_special_prize_adjudications
from anon, authenticated;
revoke all on table public.tournament_special_prize_awards
from anon, authenticated;

grant select on table public.tournament_special_prize_adjudications
to authenticated;
grant select on table public.tournament_special_prize_awards
to authenticated;

grant select, insert, update on table public.tournament_special_prize_adjudications
to service_role;
grant select, insert on table public.tournament_special_prize_awards
to service_role;


-- --------------------------------------------------------------------------
-- 05. RPC: ADJUDICAR OFICIALMENTE
--
-- p_awards JSON esperado:
-- [
--   {"entryId":"uuid", "position":1},
--   {"entryId":"uuid", "position":1},   -- empate permitido
--   {"entryId":"uuid", "position":3}
-- ]
--
-- No se exige que coincida con el orden provisional.
-- --------------------------------------------------------------------------

create or replace function public.adjudicar_premio_especial_308(
    p_tournament_special_prize_id uuid,
    p_awards jsonb,
    p_observaciones text default null
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
    v_prize_active boolean;
    v_version integer;
    v_adjudication_id uuid;
    v_count integer;
    v_item jsonb;
    v_entry_id uuid;
    v_position integer;
    v_entry_prize_id uuid;
    v_registration_id uuid;
    v_player_id uuid;
    v_value numeric;
    v_unit text;
    v_entry_status text;
    v_player_name text;
begin
    v_auth_uid := auth.uid();

    if v_auth_uid is null then
        raise exception 'No autenticado.' using errcode = '42501';
    end if;

    select sp.tournament_id, sp.tournament_round_id, sp.activo
      into v_tournament_id, v_round_id, v_prize_active
      from public.tournament_special_prizes sp
     where sp.id = p_tournament_special_prize_id;

    if not found then
        raise exception 'El premio indicado no existe.' using errcode = '23503';
    end if;

    if coalesce(v_prize_active, false) = false then
        raise exception 'El premio indicado está inactivo.' using errcode = '23514';
    end if;

    if not (
        public.is_superadmin(v_auth_uid)
        or public.is_tournament_organizer(v_auth_uid, v_tournament_id)
    ) then
        raise exception
            'No tienes autorización para adjudicar este premio.'
            using errcode = '42501';
    end if;

    if exists (
        select 1
        from public.tournament_special_prize_adjudications a
        where a.tournament_special_prize_id = p_tournament_special_prize_id
          and a.status = 'OFICIAL'
    ) then
        raise exception
            'Este premio ya tiene una adjudicación oficial vigente. Debe anularse antes de crear una nueva.'
            using errcode = '55000';
    end if;

    if p_awards is null
       or jsonb_typeof(p_awards) <> 'array'
       or jsonb_array_length(p_awards) = 0
    then
        raise exception
            'Debe proporcionar al menos una posición oficial.'
            using errcode = '22023';
    end if;

    -- Validación de estructura, duplicados y posiciones.
    select count(*)
      into v_count
      from jsonb_array_elements(p_awards) x
     where nullif(x->>'entryId','') is null
        or nullif(x->>'position','') is null
        or (x->>'position') !~ '^[0-9]+$'
        or (x->>'position')::integer <= 0;

    if v_count > 0 then
        raise exception
            'Cada posición debe contener entryId válido y position entero mayor que cero.'
            using errcode = '22023';
    end if;

    if exists (
        select 1
        from (
            select x->>'entryId' entry_id, count(*) qty
            from jsonb_array_elements(p_awards) x
            group by x->>'entryId'
            having count(*) > 1
        ) d
    ) then
        raise exception
            'Un mismo registro no puede adjudicarse más de una vez en la misma versión.'
            using errcode = '23505';
    end if;

    -- Toda adjudicación debe incluir al menos posición 1.
    if not exists (
        select 1
        from jsonb_array_elements(p_awards) x
        where (x->>'position')::integer = 1
    ) then
        raise exception
            'La adjudicación oficial debe contener al menos una posición 1.'
            using errcode = '23514';
    end if;

    -- Valida que todos los registros sean candidatos VALIDOS del mismo premio.
    for v_item in
        select value from jsonb_array_elements(p_awards)
    loop
        begin
            v_entry_id := (v_item->>'entryId')::uuid;
        exception when others then
            raise exception 'entryId inválido en la adjudicación.' using errcode = '22023';
        end;

        v_position := (v_item->>'position')::integer;

        select
            e.tournament_special_prize_id,
            e.tournament_registration_id,
            e.player_id,
            e.valor,
            e.unidad_snapshot,
            e.estatus,
            concat_ws(' ', p.nombres, p.apellidos)
          into
            v_entry_prize_id,
            v_registration_id,
            v_player_id,
            v_value,
            v_unit,
            v_entry_status,
            v_player_name
          from public.tournament_special_prize_entries e
          join public.players p on p.id = e.player_id
         where e.id = v_entry_id;

        if not found
           or v_entry_prize_id is distinct from p_tournament_special_prize_id
           or v_entry_status <> 'VALIDO'
        then
            raise exception
                'Todos los adjudicados deben ser registros VALIDOS del mismo premio.'
                using errcode = '23514';
        end if;
    end loop;

    v_admin_id := public.current_admin_id();
    if v_admin_id is null then
        raise exception
            'No se encontró el perfil administrativo del usuario autenticado.'
            using errcode = '42501';
    end if;

    select coalesce(max(a.version_no), 0) + 1
      into v_version
      from public.tournament_special_prize_adjudications a
     where a.tournament_special_prize_id = p_tournament_special_prize_id;

    insert into public.tournament_special_prize_adjudications (
        tournament_id,
        tournament_round_id,
        tournament_special_prize_id,
        version_no,
        status,
        observaciones,
        adjudicated_by
    )
    values (
        v_tournament_id,
        v_round_id,
        p_tournament_special_prize_id,
        v_version,
        'OFICIAL',
        nullif(btrim(coalesce(p_observaciones,'')),''),
        v_admin_id
    )
    returning id into v_adjudication_id;

    for v_item in
        select value from jsonb_array_elements(p_awards)
    loop
        v_entry_id := (v_item->>'entryId')::uuid;
        v_position := (v_item->>'position')::integer;

        select
            e.tournament_registration_id,
            e.player_id,
            e.valor,
            e.unidad_snapshot,
            concat_ws(' ', p.nombres, p.apellidos)
          into
            v_registration_id,
            v_player_id,
            v_value,
            v_unit,
            v_player_name
          from public.tournament_special_prize_entries e
          join public.players p on p.id = e.player_id
         where e.id = v_entry_id;

        insert into public.tournament_special_prize_awards (
            adjudication_id,
            tournament_special_prize_id,
            entry_id,
            position,
            tournament_registration_id,
            player_id,
            player_name_snapshot,
            value_snapshot,
            unit_snapshot
        )
        values (
            v_adjudication_id,
            p_tournament_special_prize_id,
            v_entry_id,
            v_position,
            v_registration_id,
            v_player_id,
            btrim(v_player_name),
            v_value,
            v_unit
        );
    end loop;

    return jsonb_build_object(
        'ok', true,
        'adjudicationId', v_adjudication_id,
        'prizeId', p_tournament_special_prize_id,
        'version', v_version,
        'status', 'OFICIAL',
        'awardCount', jsonb_array_length(p_awards)
    );
end;
$function$;

revoke all on function public.adjudicar_premio_especial_308(uuid, jsonb, text)
from public, anon;

grant execute on function public.adjudicar_premio_especial_308(uuid, jsonb, text)
to authenticated;


-- --------------------------------------------------------------------------
-- 06. RPC: ANULAR ADJUDICACIÓN OFICIAL
-- --------------------------------------------------------------------------

create or replace function public.anular_adjudicacion_premio_especial_308(
    p_adjudication_id uuid,
    p_motivo text
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
    v_status text;
begin
    v_auth_uid := auth.uid();

    if v_auth_uid is null then
        raise exception 'No autenticado.' using errcode = '42501';
    end if;

    if nullif(btrim(coalesce(p_motivo,'')), '') is null
       or char_length(btrim(p_motivo)) < 5
    then
        raise exception
            'La anulación requiere un motivo de al menos 5 caracteres.'
            using errcode = '23514';
    end if;

    select a.tournament_id, a.status
      into v_tournament_id, v_status
      from public.tournament_special_prize_adjudications a
     where a.id = p_adjudication_id
     for update;

    if not found then
        raise exception 'La adjudicación indicada no existe.' using errcode = '23503';
    end if;

    if v_status <> 'OFICIAL' then
        raise exception 'La adjudicación ya no está vigente.' using errcode = '55000';
    end if;

    if not (
        public.is_superadmin(v_auth_uid)
        or public.is_tournament_organizer(v_auth_uid, v_tournament_id)
    ) then
        raise exception
            'No tienes autorización para anular esta adjudicación.'
            using errcode = '42501';
    end if;

    v_admin_id := public.current_admin_id();
    if v_admin_id is null then
        raise exception
            'No se encontró el perfil administrativo del usuario autenticado.'
            using errcode = '42501';
    end if;

    update public.tournament_special_prize_adjudications
       set status = 'ANULADA',
           annulled_by = v_admin_id,
           annulled_at = now(),
           annul_reason = btrim(p_motivo)
     where id = p_adjudication_id;

    return jsonb_build_object(
        'ok', true,
        'adjudicationId', p_adjudication_id,
        'status', 'ANULADA',
        'reason', btrim(p_motivo)
    );
end;
$function$;

revoke all on function public.anular_adjudicacion_premio_especial_308(uuid, text)
from public, anon;

grant execute on function public.anular_adjudicacion_premio_especial_308(uuid, text)
to authenticated;


-- --------------------------------------------------------------------------
-- 07. RPC: CONSULTAR HISTORIAL DE ADJUDICACIONES DE UN PREMIO
-- --------------------------------------------------------------------------

create or replace function public.obtener_adjudicaciones_premio_especial_308(
    p_tournament_special_prize_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_auth_uid uuid;
    v_tournament_id uuid;
    v_result jsonb;
begin
    v_auth_uid := auth.uid();

    if v_auth_uid is null then
        raise exception 'No autenticado.' using errcode = '42501';
    end if;

    select sp.tournament_id
      into v_tournament_id
      from public.tournament_special_prizes sp
     where sp.id = p_tournament_special_prize_id;

    if not found then
        raise exception 'El premio indicado no existe.' using errcode = '23503';
    end if;

    if not (
        public.is_superadmin(v_auth_uid)
        or public.is_tournament_organizer(v_auth_uid, v_tournament_id)
    ) then
        raise exception
            'No tienes autorización para consultar adjudicaciones de este premio.'
            using errcode = '42501';
    end if;

    select jsonb_build_object(
        'ok', true,
        'prizeId', p_tournament_special_prize_id,
        'adjudications', coalesce(
            jsonb_agg(
                jsonb_build_object(
                    'id', a.id,
                    'version', a.version_no,
                    'status', a.status,
                    'observations', a.observaciones,
                    'adjudicatedBy', a.adjudicated_by,
                    'adjudicatedAt', a.adjudicated_at,
                    'annulledBy', a.annulled_by,
                    'annulledAt', a.annulled_at,
                    'annulReason', a.annul_reason,
                    'awards', coalesce(
                        (
                            select jsonb_agg(
                                jsonb_build_object(
                                    'awardId', w.id,
                                    'position', w.position,
                                    'entryId', w.entry_id,
                                    'registrationId', w.tournament_registration_id,
                                    'playerId', w.player_id,
                                    'playerName', w.player_name_snapshot,
                                    'value', w.value_snapshot,
                                    'unit', w.unit_snapshot
                                )
                                order by w.position, w.player_name_snapshot, w.id
                            )
                            from public.tournament_special_prize_awards w
                            where w.adjudication_id = a.id
                        ),
                        '[]'::jsonb
                    )
                )
                order by a.version_no desc
            ),
            '[]'::jsonb
        )
    )
      into v_result
      from public.tournament_special_prize_adjudications a
     where a.tournament_special_prize_id = p_tournament_special_prize_id;

    return v_result;
end;
$function$;

revoke all on function public.obtener_adjudicaciones_premio_especial_308(uuid)
from public, anon;

grant execute on function public.obtener_adjudicaciones_premio_especial_308(uuid)
to authenticated;

commit;
