-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 294
-- Vigencia explícita de acceso operativo por torneo contratado
--
-- Objetivo:
--   Separar la vigencia comercial/operativa de:
--     - tournaments.fecha_fin (fecha deportiva),
--     - tournaments.activo,
--     - estado_servicio.
--
-- Regla inicial:
--   - El acceso de escritura comienza el día en que la contratación queda PAGADA.
--   - Permanece vigente hasta la fecha final contratada, inclusive.
--   - A partir del día siguiente, el torneo deberá operar en modo sólo lectura.
--
-- Compatibilidad:
--   - Los torneos históricos que no provienen del nuevo flujo de contratación
--     NO se consideran vencidos por ausencia de este registro.
--   - La siguiente migración aplicará los bloqueos de escritura reutilizando
--     el patrón de la Migración 233.
-- ============================================================================

begin;

create table if not exists public.platform_tournament_access (
    id uuid primary key default gen_random_uuid(),

    contract_id uuid not null
        references public.platform_tournament_contracts(id),

    tournament_id uuid not null
        references public.tournaments(id),

    valid_from_date date not null,
    valid_through_date date not null,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint platform_tournament_access_dates_ck
        check (valid_through_date >= valid_from_date),

    constraint platform_tournament_access_contract_uq
        unique (contract_id),

    constraint platform_tournament_access_tournament_uq
        unique (tournament_id)
);

create trigger trg_platform_tournament_access_updated_at
before update on public.platform_tournament_access
for each row
execute function public.set_updated_at();

alter table public.platform_tournament_access enable row level security;

create policy platform_tournament_access_select_own_or_superadmin
on public.platform_tournament_access
for select
to authenticated
using (
    public.is_superadmin(auth.uid())
    or exists (
        select 1
          from public.platform_tournament_contracts c
          join public.admin_users au
            on au.id = c.organizer_admin_user_id
         where c.id = platform_tournament_access.contract_id
           and au.auth_user_id = auth.uid()
           and au.activo = true
    )
);

create policy platform_tournament_access_write_superadmin
on public.platform_tournament_access
for all
to authenticated
using (public.is_superadmin(auth.uid()))
with check (public.is_superadmin(auth.uid()));

revoke all on table public.platform_tournament_access from anon;
revoke insert, update, delete on table public.platform_tournament_access from authenticated;
grant select on table public.platform_tournament_access to authenticated;
grant all on table public.platform_tournament_access to service_role;

-- --------------------------------------------------------------------------
-- Registro automático de vigencia cuando la contratación queda PAGADA
-- y ya tiene tournament_id.
-- No modifica la Migración 292: se engancha al estado definitivo del contrato.
-- --------------------------------------------------------------------------

create or replace function public._crear_vigencia_torneo_pagado_294()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
    if new.contract_status = 'PAGADO'
       and new.tournament_id is not null
       and (
            tg_op = 'INSERT'
            or old.contract_status is distinct from new.contract_status
            or old.tournament_id is distinct from new.tournament_id
       )
    then
        if new.proposed_end_date < current_date then
            raise exception
                'La contratación pagada no puede crear una vigencia ya vencida. Fecha fin propuesta: %.',
                new.proposed_end_date
                using errcode = '23514';
        end if;

        insert into public.platform_tournament_access (
            contract_id,
            tournament_id,
            valid_from_date,
            valid_through_date
        )
        values (
            new.id,
            new.tournament_id,
            current_date,
            new.proposed_end_date
        )
        on conflict (contract_id) do nothing;
    end if;

    return new;
end;
$function$;

drop trigger if exists trg_crear_vigencia_torneo_pagado_294
on public.platform_tournament_contracts;

create trigger trg_crear_vigencia_torneo_pagado_294
after insert or update of contract_status, tournament_id
on public.platform_tournament_contracts
for each row
execute function public._crear_vigencia_torneo_pagado_294();

-- --------------------------------------------------------------------------
-- Helper consultable por backend/frontend.
--
-- LEGACY      = torneo sin contratación del nuevo flujo; no se bloquea.
-- VIGENTE     = acceso operativo vigente.
-- VENCIDO     = terminó la vigencia comercial.
-- NO_INICIADO = reservado para una vigencia futura explícita.
-- --------------------------------------------------------------------------

create or replace function public.obtener_estado_vigencia_torneo_294(
    p_tournament_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
    v_tournament_exists boolean;
    v_access public.platform_tournament_access%rowtype;
    v_status text;
    v_write_allowed boolean;
begin
    select exists (
        select 1
          from public.tournaments t
         where t.id = p_tournament_id
    )
    into v_tournament_exists;

    if not v_tournament_exists then
        raise exception 'El torneo indicado no existe.'
            using errcode = '22023';
    end if;

    select *
      into v_access
      from public.platform_tournament_access a
     where a.tournament_id = p_tournament_id;

    if not found then
        return jsonb_build_object(
            'tournamentId', p_tournament_id,
            'status', 'LEGACY',
            'writeAllowed', true,
            'readOnly', false,
            'validFromDate', null,
            'validThroughDate', null
        );
    end if;

    if current_date < v_access.valid_from_date then
        v_status := 'NO_INICIADO';
        v_write_allowed := false;
    elsif current_date <= v_access.valid_through_date then
        v_status := 'VIGENTE';
        v_write_allowed := true;
    else
        v_status := 'VENCIDO';
        v_write_allowed := false;
    end if;

    return jsonb_build_object(
        'tournamentId', p_tournament_id,
        'status', v_status,
        'writeAllowed', v_write_allowed,
        'readOnly', not v_write_allowed,
        'validFromDate', v_access.valid_from_date,
        'validThroughDate', v_access.valid_through_date
    );
end;
$function$;

revoke all on function public.obtener_estado_vigencia_torneo_294(uuid)
from public, anon;

grant execute on function public.obtener_estado_vigencia_torneo_294(uuid)
to authenticated, service_role;

-- --------------------------------------------------------------------------
-- Helper booleano para la siguiente fase de guardas de escritura.
-- Los torneos legacy permanecen habilitados.
-- --------------------------------------------------------------------------

create or replace function public.torneo_tiene_escritura_vigente_294(
    p_tournament_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
    select coalesce(
        (
            select current_date between a.valid_from_date and a.valid_through_date
              from public.platform_tournament_access a
             where a.tournament_id = p_tournament_id
        ),
        true
    );
$function$;

revoke all on function public.torneo_tiene_escritura_vigente_294(uuid)
from public, anon;

grant execute on function public.torneo_tiene_escritura_vigente_294(uuid)
to authenticated, service_role;

-- --------------------------------------------------------------------------
-- Backfill seguro por si existiera alguna contratación PAGADA ya finalizada.
-- En el estado actual esperado son 0, pero deja la migración robusta.
-- --------------------------------------------------------------------------

insert into public.platform_tournament_access (
    contract_id,
    tournament_id,
    valid_from_date,
    valid_through_date
)
select
    c.id,
    c.tournament_id,
    least(current_date, c.proposed_end_date),
    c.proposed_end_date
from public.platform_tournament_contracts c
where c.contract_status = 'PAGADO'
  and c.tournament_id is not null
  and not exists (
      select 1
        from public.platform_tournament_access a
       where a.contract_id = c.id
          or a.tournament_id = c.tournament_id
  );

commit;
