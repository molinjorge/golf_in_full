-- ============================================================
-- 129_categorias_por_turno.sql
-- GOLF IN FULL
--
-- FASE 1 — PREPARACIÓN DE SALIDAS SHOTGUN
--
-- Objetivo:
-- Relacionar las categorías de un torneo con los turnos de cada
-- ronda.
--
-- Reglas:
-- 1. La relación es:
--      tournament_round_shift <-> tournament_category
-- 2. Una categoría solo puede estar asignada a UN turno activo
--    dentro de la misma ronda.
-- 3. La misma categoría sí puede estar asignada nuevamente en
--    otra ronda del mismo torneo.
-- 4. La categoría debe pertenecer al mismo torneo que el turno.
-- 5. Si la ronda tiene UN SOLO turno activo, todas las categorías
--    del torneo se asignan automáticamente a ese turno.
-- 6. Si hay varios turnos, la distribución es manual.
-- 7. Al asignar manualmente una categoría a un turno, se valida
--    que la cantidad actual de jugadores inscritos de las
--    categorías asignadas no exceda cupo_maximo del turno.
--
-- IMPORTANTE:
-- Esta migración NO modifica:
--   tournament_groups
--   tournament_group_players
--   tournaments.jugadores_por_grupo
--   tournament_groups.tournament_team_id
--   reglas A/B
--   regla actual de doble salida por par
--   tarjetas
-- ============================================================

begin;

-- ============================================================
-- 1. TABLA: tournament_round_shift_categories
-- ============================================================

create table public.tournament_round_shift_categories (
    id uuid primary key default gen_random_uuid(),

    tournament_round_shift_id uuid not null
        references public.tournament_round_shifts(id)
        on delete cascade,

    tournament_category_id uuid not null
        references public.tournament_categories(id)
        on delete cascade,

    activo boolean not null default true,

    fecha_baja timestamptz,
    dado_de_baja_por uuid
        references public.admin_users(id)
        on delete restrict,

    motivo_baja text,

    created_by uuid
        references public.admin_users(id)
        on delete restrict,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

comment on table public.tournament_round_shift_categories is
'Categorías asignadas a cada turno de una ronda. Define qué categorías participan en cada turno antes de preparar las salidas Shotgun.';

comment on column public.tournament_round_shift_categories.tournament_round_shift_id is
'Turno de la ronda al que se asigna la categoría.';

comment on column public.tournament_round_shift_categories.tournament_category_id is
'Categoría específica habilitada para el torneo, no el catálogo global de categorías.';

-- ============================================================
-- 2. ÍNDICES
-- ============================================================

create index idx_trsc_shift
    on public.tournament_round_shift_categories
       (tournament_round_shift_id);

create index idx_trsc_category
    on public.tournament_round_shift_categories
       (tournament_category_id);

-- Permite historial: una relación desactivada puede volver a
-- crearse posteriormente.
create unique index uq_trsc_shift_category_activa
    on public.tournament_round_shift_categories
       (tournament_round_shift_id, tournament_category_id)
    where activo = true;

-- ============================================================
-- 3. updated_at / baja lógica / auditoría
-- ============================================================

create trigger trg_trsc_updated_at
before update
on public.tournament_round_shift_categories
for each row
execute function public.set_updated_at();

create trigger trg_track_estatus_trsc
before update
on public.tournament_round_shift_categories
for each row
execute function public.track_estatus_activo();

create trigger trg_audit_trsc
after insert or update or delete
on public.tournament_round_shift_categories
for each row
execute function public.log_audit();

-- ============================================================
-- 4. VALIDACIÓN CENTRAL
-- ============================================================

create or replace function public.validar_categoria_asignada_a_turno()
returns trigger
language plpgsql
as $$
declare
    v_round_id             uuid;
    v_tournament_id        uuid;
    v_categoria_torneo_id  uuid;
    v_turno_activo         boolean;
    v_cupo_turno           integer;
    v_conflictos           integer;
    v_jugadores_turno      integer;
    v_saltar_cupo          text;
begin
    -- Una fila desactivada conserva únicamente historial.
    if new.activo = false then
        return new;
    end if;

    -- Resolver turno -> ronda -> torneo.
    select
        trs.tournament_round_id,
        tr.tournament_id,
        trs.activo,
        trs.cupo_maximo
    into
        v_round_id,
        v_tournament_id,
        v_turno_activo,
        v_cupo_turno
    from public.tournament_round_shifts trs
    join public.tournament_rounds tr
      on tr.id = trs.tournament_round_id
    where trs.id = new.tournament_round_shift_id;

    if v_round_id is null then
        raise exception 'El turno indicado no existe.';
    end if;

    if v_turno_activo = false then
        raise exception 'No se puede asignar una categoría a un turno desactivado.';
    end if;

    -- La categoría debe pertenecer al mismo torneo.
    select tc.tournament_id
    into v_categoria_torneo_id
    from public.tournament_categories tc
    where tc.id = new.tournament_category_id;

    if v_categoria_torneo_id is null then
        raise exception 'La categoría indicada no existe en tournament_categories.';
    end if;

    if v_categoria_torneo_id is distinct from v_tournament_id then
        raise exception 'La categoría seleccionada no pertenece al torneo de este turno.';
    end if;

    -- Una categoría solo puede estar en un turno activo de la
    -- misma ronda.
    select count(*)
    into v_conflictos
    from public.tournament_round_shift_categories sc
    join public.tournament_round_shifts trs
      on trs.id = sc.tournament_round_shift_id
    where trs.tournament_round_id = v_round_id
      and sc.tournament_category_id = new.tournament_category_id
      and sc.activo = true
      and sc.id is distinct from new.id;

    if v_conflictos > 0 then
        raise exception 'Esta categoría ya está asignada a otro turno de la misma ronda.';
    end if;

    -- Validación de cupo en asignación manual.
    v_saltar_cupo := current_setting(
        'app.saltar_validacion_cupo_categorias_turno',
        true
    );

    if coalesce(v_saltar_cupo, '0') <> '1' then
        select count(*)
        into v_jugadores_turno
        from public.tournament_registrations reg
        where reg.activo = true
          and reg.tournament_category_id in (
              select sc.tournament_category_id
              from public.tournament_round_shift_categories sc
              where sc.tournament_round_shift_id = new.tournament_round_shift_id
                and sc.activo = true
                and sc.id is distinct from new.id

              union

              select new.tournament_category_id
          );

        if v_jugadores_turno > v_cupo_turno then
            raise exception
                'Las categorías asignadas a este turno representan % jugadores inscritos y exceden el cupo máximo del turno (%).',
                v_jugadores_turno,
                v_cupo_turno;
        end if;
    end if;

    return new;
end;
$$;

create trigger trg_validar_categoria_asignada_a_turno
before insert or update
on public.tournament_round_shift_categories
for each row
execute function public.validar_categoria_asignada_a_turno();

-- ============================================================
-- 5. SINCRONIZAR CATEGORÍAS CUANDO HAY UN SOLO TURNO
-- ============================================================

create or replace function public.sincronizar_categorias_turno_unico(
    p_tournament_round_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_shift_id       uuid;
    v_tournament_id  uuid;
    v_num_turnos     integer;
begin
    -- Contar turnos activos.
    select count(*)
    into v_num_turnos
    from public.tournament_round_shifts
    where tournament_round_id = p_tournament_round_id
      and activo = true;

    if v_num_turnos <> 1 then
        return;
    end if;

    -- Obtener el único turno activo.
    select id
    into v_shift_id
    from public.tournament_round_shifts
    where tournament_round_id = p_tournament_round_id
      and activo = true
    limit 1;

    -- Resolver torneo de la ronda.
    select tournament_id
    into v_tournament_id
    from public.tournament_rounds
    where id = p_tournament_round_id;

    if v_tournament_id is null then
        return;
    end if;

    -- En turno único no hay alternativa de distribución.
    perform set_config(
        'app.saltar_validacion_cupo_categorias_turno',
        '1',
        true
    );

    -- Si anteriormente había varios turnos y ahora solo queda uno,
    -- desactivar asignaciones de otros turnos de la misma ronda.
    update public.tournament_round_shift_categories sc
       set activo = false,
           motivo_baja = coalesce(
               sc.motivo_baja,
               'Reasignación automática: la ronda quedó con un solo turno activo.'
           )
      from public.tournament_round_shifts trs
     where trs.id = sc.tournament_round_shift_id
       and trs.tournament_round_id = p_tournament_round_id
       and sc.tournament_round_shift_id <> v_shift_id
       and sc.activo = true;

    -- Crear asignaciones faltantes para todas las categorías del torneo.
    insert into public.tournament_round_shift_categories (
        tournament_round_shift_id,
        tournament_category_id
    )
    select
        v_shift_id,
        tc.id
    from public.tournament_categories tc
    where tc.tournament_id = v_tournament_id
      and not exists (
          select 1
          from public.tournament_round_shift_categories sc
          where sc.tournament_round_shift_id = v_shift_id
            and sc.tournament_category_id = tc.id
            and sc.activo = true
      );
end;
$$;

revoke all
on function public.sincronizar_categorias_turno_unico(uuid)
from public, anon, authenticated;

-- ============================================================
-- 6. TRIGGER SOBRE TURNOS
-- ============================================================

create or replace function public.trg_sync_categorias_turno_unico()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if tg_op = 'INSERT' then
        perform public.sincronizar_categorias_turno_unico(
            new.tournament_round_id
        );
        return new;
    end if;

    perform public.sincronizar_categorias_turno_unico(
        new.tournament_round_id
    );

    if old.tournament_round_id is distinct from new.tournament_round_id then
        perform public.sincronizar_categorias_turno_unico(
            old.tournament_round_id
        );
    end if;

    return new;
end;
$$;

create trigger trg_sync_categorias_turno_unico
after insert or update of activo, tournament_round_id
on public.tournament_round_shifts
for each row
execute function public.trg_sync_categorias_turno_unico();

revoke all
on function public.trg_sync_categorias_turno_unico()
from public, anon, authenticated;

-- ============================================================
-- 7. TRIGGER SOBRE NUEVAS CATEGORÍAS DEL TORNEO
-- ============================================================

create or replace function public.trg_sync_nueva_categoria_turno_unico()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    r record;
begin
    for r in
        select tr.id
        from public.tournament_rounds tr
        where tr.tournament_id = new.tournament_id
          and tr.activo = true
    loop
        perform public.sincronizar_categorias_turno_unico(r.id);
    end loop;

    return new;
end;
$$;

create trigger trg_sync_nueva_categoria_turno_unico
after insert
on public.tournament_categories
for each row
execute function public.trg_sync_nueva_categoria_turno_unico();

revoke all
on function public.trg_sync_nueva_categoria_turno_unico()
from public, anon, authenticated;

-- ============================================================
-- 8. RLS
-- ============================================================

alter table public.tournament_round_shift_categories
    enable row level security;

create policy tournament_round_shift_categories_select
on public.tournament_round_shift_categories
for select
to public
using (
    activo = true
    or public.is_superadmin(auth.uid())
);

create policy tournament_round_shift_categories_write
on public.tournament_round_shift_categories
for all
to authenticated
using (
    public.is_superadmin(auth.uid())
    or exists (
        select 1
        from public.tournament_round_shifts trs
        join public.tournament_rounds tr
          on tr.id = trs.tournament_round_id
        join public.tournaments t
          on t.id = tr.tournament_id
        where trs.id = tournament_round_shift_categories.tournament_round_shift_id
          and (
              public.is_tournament_organizer(auth.uid(), t.id)
              or public.is_club_admin(auth.uid(), t.club_id)
          )
    )
)
with check (
    public.is_superadmin(auth.uid())
    or exists (
        select 1
        from public.tournament_round_shifts trs
        join public.tournament_rounds tr
          on tr.id = trs.tournament_round_id
        join public.tournaments t
          on t.id = tr.tournament_id
        where trs.id = tournament_round_shift_categories.tournament_round_shift_id
          and (
              public.is_tournament_organizer(auth.uid(), t.id)
              or public.is_club_admin(auth.uid(), t.club_id)
          )
    )
);

-- ============================================================
-- 9. GRANTS
-- ============================================================

grant select
on public.tournament_round_shift_categories
to anon;

grant select, insert, update, delete
on public.tournament_round_shift_categories
to authenticated;

-- ============================================================
-- 10. BACKFILL
-- ============================================================

do $$
declare
    r record;
begin
    for r in
        select tr.id
        from public.tournament_rounds tr
        where tr.activo = true
    loop
        perform public.sincronizar_categorias_turno_unico(r.id);
    end loop;
end;
$$;

commit;
