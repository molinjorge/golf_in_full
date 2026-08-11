-- ============================================================
-- 131_adaptacion_estructural_grupos_shotgun.sql
-- GOLF IN FULL
--
-- FASE 3A — ADAPTACIÓN ESTRUCTURAL DE GRUPOS SHOTGUN
--
-- Objetivo:
-- 1. Preparar tournament_groups para representar explícitamente
--    la posición A/B de un grupo Shotgun.
-- 2. Vincular los grupos Shotgun nuevos con el hoyo previamente
--    seleccionado/configurado por categoría en la Fase 2.
-- 3. Crear una relación Grupo <-> Equipos que permita que un
--    mismo grupo contenga uno o varios equipos completos.
-- 4. Preservar compatibilidad con grupos históricos.
--
-- IMPORTANTE:
-- Esta migración es ESTRUCTURAL.
--
-- NO sustituye todavía:
--   - validar_formato_salida_y_doble_hoyo()
--   - validar_team_id_segun_formato_torneo()
--   - validar_equipo_unico_por_ronda()
--   - validar_grupo_individual()
--
-- Esas validaciones serán adaptadas en la siguiente fase.
--
-- NO elimina:
--   tournament_groups.tournament_team_id
--   tournament_groups.hoyo_id
--   tournament_groups.hora_salida
--   tournament_groups.etiqueta
--
-- tournament_team_id queda temporalmente como LEGACY para
-- compatibilidad con datos/código existentes.
--
-- Modelo nuevo:
--
-- tournament_groups
--   |
--   +-- tournament_shotgun_category_hole_id
--   |
--   +-- posicion_salida ('A' / 'B')
--   |
--   +-- tournament_group_teams (0..N equipos)
--
-- Para grupos históricos:
--   tournament_shotgun_category_hole_id = NULL
--   posicion_salida = NULL
--
-- Para grupos Shotgun nuevos:
--   ambos campos deberán utilizarse.
--
-- ============================================================

begin;


-- ============================================================
-- 1. AGREGAR REFERENCIA A CONFIGURACIÓN SHOTGUN Y POSICIÓN A/B
-- ============================================================

alter table public.tournament_groups
    add column tournament_shotgun_category_hole_id uuid null;


alter table public.tournament_groups
    add constraint tournament_groups_shotgun_category_hole_fkey
    foreign key (tournament_shotgun_category_hole_id)
    references public.tournament_shotgun_category_holes(id)
    on delete restrict;


alter table public.tournament_groups
    add column posicion_salida text null;


alter table public.tournament_groups
    add constraint chk_tournament_groups_posicion_salida
    check (
        posicion_salida is null
        or posicion_salida in ('A', 'B')
    );


comment on column public.tournament_groups.tournament_shotgun_category_hole_id is
'Referencia al hoyo configurado para la categoría dentro del turno Shotgun. NULL identifica grupos históricos o grupos aún no migrados al nuevo modelo.';


comment on column public.tournament_groups.posicion_salida is
'Posición física de salida del grupo Shotgun dentro del hoyo configurado: A o B. NULL para grupos históricos/no migrados.';


comment on column public.tournament_groups.tournament_team_id is
'LEGACY TEMPORAL. Relación histórica de un grupo con un único equipo. El nuevo modelo usa tournament_group_teams para permitir uno o varios equipos por grupo. No eliminar hasta completar transición de aplicación y validaciones.';


-- ============================================================
-- 2. ÍNDICES PARA LOS NUEVOS CAMPOS
-- ============================================================

create index idx_tournament_groups_shotgun_category_hole
    on public.tournament_groups
       (tournament_shotgun_category_hole_id);


create index idx_tournament_groups_posicion_salida
    on public.tournament_groups
       (posicion_salida)
    where posicion_salida is not null;


-- Un hoyo configurado puede tener como máximo una posición A
-- y una posición B activa.
--
-- Los grupos históricos con FK NULL no participan en el índice.
create unique index uq_tournament_groups_shotgun_posicion_activa
    on public.tournament_groups
       (
           tournament_shotgun_category_hole_id,
           posicion_salida
       )
    where activo = true
      and tournament_shotgun_category_hole_id is not null
      and posicion_salida is not null;


-- ============================================================
-- 3. TABLA: tournament_group_teams
--
-- Permite uno o varios equipos completos dentro de un grupo.
-- ============================================================

create table public.tournament_group_teams (
    id uuid primary key default gen_random_uuid(),

    tournament_group_id uuid not null
        references public.tournament_groups(id)
        on delete restrict,

    tournament_team_id uuid not null
        references public.tournament_teams(id)
        on delete restrict,

    orden_en_grupo smallint null,

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
    updated_at timestamptz not null default now(),

    constraint chk_tournament_group_teams_orden
        check (
            orden_en_grupo is null
            or orden_en_grupo >= 1
        )
);


comment on table public.tournament_group_teams is
'Equipos completos asignados a un grupo físico de salida. Permite que un mismo grupo contenga uno o varios equipos sin dividir sus integrantes.';


comment on column public.tournament_group_teams.orden_en_grupo is
'Orden opcional del equipo dentro del grupo físico. No representa posición A/B; A/B pertenece a tournament_groups.posicion_salida.';


-- ============================================================
-- 4. ÍNDICES DE tournament_group_teams
-- ============================================================

create index idx_tournament_group_teams_group
    on public.tournament_group_teams
       (tournament_group_id);


create index idx_tournament_group_teams_team
    on public.tournament_group_teams
       (tournament_team_id);


-- Evita duplicar el mismo equipo dentro del mismo grupo activo.
create unique index uq_tournament_group_team_activo
    on public.tournament_group_teams
       (tournament_group_id, tournament_team_id)
    where activo = true;


-- ============================================================
-- 5. TRIGGERS ESTÁNDAR DE AUDITORÍA / BAJA LÓGICA
-- ============================================================

create trigger trg_tournament_group_teams_updated_at
before update
on public.tournament_group_teams
for each row
execute function public.set_updated_at();


create trigger trg_track_estatus_tournament_group_teams
before update
on public.tournament_group_teams
for each row
execute function public.track_estatus_activo();


create trigger trg_audit_tournament_group_teams
after insert or update or delete
on public.tournament_group_teams
for each row
execute function public.log_audit();


-- ============================================================
-- 6. VALIDACIÓN ESTRUCTURAL BÁSICA DE tournament_group_teams
--
-- Esta función NO implementa todavía:
--   - máximo de equipos por grupo
--   - equipo único por ronda
--   - categoría correcta
--
-- Eso corresponde a la siguiente fase.
--
-- Aquí únicamente garantizamos coherencia TORNEO <-> EQUIPO.
-- ============================================================

create or replace function public.validar_group_team_mismo_torneo()
returns trigger
language plpgsql
as $$
declare
    v_tournament_group uuid;
    v_tournament_team  uuid;
begin

    if new.activo = false then
        return new;
    end if;


    select tr.tournament_id
    into v_tournament_group
    from public.tournament_groups g
    join public.tournament_round_shifts trs
      on trs.id = g.tournament_round_shift_id
    join public.tournament_rounds tr
      on tr.id = trs.tournament_round_id
    where g.id = new.tournament_group_id;


    if v_tournament_group is null then
        raise exception
            'El grupo indicado no existe o no está asociado correctamente a una ronda.';
    end if;


    select tt.tournament_id
    into v_tournament_team
    from public.tournament_teams tt
    where tt.id = new.tournament_team_id;


    if v_tournament_team is null then
        raise exception
            'El equipo indicado no existe.';
    end if;


    if v_tournament_group is distinct from v_tournament_team then
        raise exception
            'El equipo y el grupo pertenecen a torneos diferentes.';
    end if;


    return new;

end;
$$;


create trigger trg_validar_group_team_mismo_torneo
before insert or update
on public.tournament_group_teams
for each row
execute function public.validar_group_team_mismo_torneo();


-- ============================================================
-- 7. RLS — tournament_group_teams
-- ============================================================

alter table public.tournament_group_teams
enable row level security;


create policy tournament_group_teams_select
on public.tournament_group_teams
for select
to public
using (
    activo = true
    or public.is_superadmin(auth.uid())
);


create policy tournament_group_teams_write
on public.tournament_group_teams
for all
to authenticated
using (
    public.is_superadmin(auth.uid())

    or exists (
        select 1
        from public.tournament_groups g
        join public.tournament_round_shifts trs
          on trs.id = g.tournament_round_shift_id
        join public.tournament_rounds tr
          on tr.id = trs.tournament_round_id
        join public.tournaments t
          on t.id = tr.tournament_id
        where g.id =
              tournament_group_teams.tournament_group_id
          and (
              public.is_tournament_organizer(
                  auth.uid(),
                  t.id
              )
              or public.is_club_admin(
                  auth.uid(),
                  t.club_id
              )
          )
    )
)
with check (
    public.is_superadmin(auth.uid())

    or exists (
        select 1
        from public.tournament_groups g
        join public.tournament_round_shifts trs
          on trs.id = g.tournament_round_shift_id
        join public.tournament_rounds tr
          on tr.id = trs.tournament_round_id
        join public.tournaments t
          on t.id = tr.tournament_id
        where g.id =
              tournament_group_teams.tournament_group_id
          and (
              public.is_tournament_organizer(
                  auth.uid(),
                  t.id
              )
              or public.is_club_admin(
                  auth.uid(),
                  t.club_id
              )
          )
    )
);


grant select
on public.tournament_group_teams
to anon;


grant select, insert, update, delete
on public.tournament_group_teams
to authenticated;


-- ============================================================
-- 8. BACKFILL DE EQUIPOS HISTÓRICOS
--
-- Todo tournament_groups.tournament_team_id existente se replica
-- en tournament_group_teams.
--
-- NO se elimina ni se pone NULL el campo legacy.
--
-- El objetivo es tener ambos modelos coexistiendo durante la
-- transición.
-- ============================================================

insert into public.tournament_group_teams (
    tournament_group_id,
    tournament_team_id,
    orden_en_grupo
)
select
    g.id,
    g.tournament_team_id,
    1
from public.tournament_groups g
where g.tournament_team_id is not null
  and not exists (
      select 1
      from public.tournament_group_teams gt
      where gt.tournament_group_id = g.id
        and gt.tournament_team_id = g.tournament_team_id
        and gt.activo = true
  );


-- ============================================================
-- 9. VALIDACIÓN DE CONSISTENCIA PARA GRUPOS SHOTGUN NUEVOS
--
-- En esta migración NO hacemos los campos NOT NULL porque los
-- grupos históricos no tienen referencia a la configuración 130.
--
-- Sin embargo, si se captura uno de los dos datos nuevos,
-- exigimos que ambos estén presentes.
-- ============================================================

alter table public.tournament_groups
    add constraint chk_tournament_groups_shotgun_campos_pareados
    check (
        (
            tournament_shotgun_category_hole_id is null
            and posicion_salida is null
        )
        or
        (
            tournament_shotgun_category_hole_id is not null
            and posicion_salida is not null
        )
    );


-- ============================================================
-- 10. VALIDACIÓN ESTRUCTURAL DEL VÍNCULO SHOTGUN
--
-- Solo valida coherencia:
--   grupo.turno = configuración.turno
--   grupo.hoyo  = configuración.hoyo
--
-- Todavía NO valida:
--   - si B está habilitado
--   - hora A/B
--   - categoría de integrantes/equipos
--
-- Eso se implementará en la siguiente fase.
-- ============================================================

create or replace function public.validar_vinculo_grupo_shotgun()
returns trigger
language plpgsql
as $$
declare
    v_shift_config uuid;
    v_hoyo_config  uuid;
begin

    -- Grupo histórico/no migrado.
    if new.tournament_shotgun_category_hole_id is null then
        return new;
    end if;


    select
        sc.tournament_round_shift_id,
        sh.hoyo_id
    into
        v_shift_config,
        v_hoyo_config
    from public.tournament_shotgun_category_holes sh
    join public.tournament_shotgun_category_configs cfg
      on cfg.id =
         sh.tournament_shotgun_category_config_id
    join public.tournament_round_shift_categories sc
      on sc.id =
         cfg.tournament_round_shift_category_id
    where sh.id =
          new.tournament_shotgun_category_hole_id;


    if not found then
        raise exception
            'El hoyo Shotgun configurado indicado no existe.';
    end if;


    if new.tournament_round_shift_id
       is distinct from v_shift_config then

        raise exception
            'El grupo y el hoyo Shotgun configurado pertenecen a turnos diferentes.';
    end if;


    if new.hoyo_id
       is distinct from v_hoyo_config then

        raise exception
            'El hoyo del grupo no coincide con el hoyo seleccionado en la configuración Shotgun.';
    end if;


    return new;

end;
$$;


create trigger trg_validar_vinculo_grupo_shotgun
before insert or update
on public.tournament_groups
for each row
execute function public.validar_vinculo_grupo_shotgun();


commit;
