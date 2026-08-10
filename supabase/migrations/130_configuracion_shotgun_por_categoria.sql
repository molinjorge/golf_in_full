-- ============================================================
-- 130_configuracion_shotgun_por_categoria.sql
-- GOLF IN FULL
--
-- FASE 2 — PREPARACIÓN DE SALIDAS SHOTGUN
--
-- Objetivo:
-- 1. Configurar el tamaño de grupo POR CATEGORÍA dentro de
--    cada turno.
-- 2. Registrar los hoyos que el organizador selecciona para
--    cada categoría.
-- 3. Permitir que el organizador decida, hoyo por hoyo, si
--    existe salida doble A/B.
--
-- IMPORTANTE:
-- Esta migración NO crea todavía grupos de salida.
-- Esta migración NO asigna jugadores ni equipos.
-- Esta migración NO modifica tournament_groups.
-- Esta migración NO modifica tournament_group_players.
-- Esta migración NO elimina todavía la regla Par 4/5 existente
-- en tournament_groups; ese cambio corresponde a una fase
-- posterior cuando adaptemos los grupos al nuevo modelo.
--
-- Modelo:
--
-- tournament_round_shift_categories
--          |
--          v
-- tournament_shotgun_category_configs
--          |
--          v
-- tournament_shotgun_category_holes
--
-- Un hoyo seleccionado aporta:
--   salida_doble = false -> 1 posición (A)
--   salida_doble = true  -> 2 posiciones (A y B)
--
-- Reglas principales:
-- - Solo aplica a rondas con formato_salida = shotgun.
-- - El tamaño del grupo se configura por categoría.
-- - En torneos individuales, la unidad es JUGADORES.
-- - En torneos por equipos, la unidad es EQUIPOS.
--   Esa unidad se deriva de tournament_formats.tipo_participacion
--   y NO se duplica en estas tablas.
-- - tamaño máximo >= tamaño normal.
-- - Un mismo hoyo no puede quedar asignado a dos categorías
--   diferentes dentro del mismo turno.
-- - El organizador decide si un hoyo tiene salida doble.
-- - No se impone ninguna restricción por PAR en esta capa.
-- ============================================================

begin;


-- ============================================================
-- 1. CONFIGURACIÓN SHOTGUN POR CATEGORÍA / TURNO
-- ============================================================

create table public.tournament_shotgun_category_configs (
    id uuid primary key default gen_random_uuid(),

    tournament_round_shift_category_id uuid not null
        references public.tournament_round_shift_categories(id)
        on delete restrict,

    tamano_grupo_normal integer not null,
    tamano_grupo_maximo integer not null,

    -- Minutos que separan B de A cuando un hoyo se configure
    -- con salida doble. El valor puede ser modificado por el
    -- organizador para esa categoría.
    intervalo_salida_b_minutos integer not null default 5,

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

    constraint chk_shotgun_tamano_grupo_normal
        check (tamano_grupo_normal >= 1),

    constraint chk_shotgun_tamano_grupo_maximo
        check (tamano_grupo_maximo >= tamano_grupo_normal),

    constraint chk_shotgun_intervalo_b
        check (intervalo_salida_b_minutos between 1 and 60)
);


comment on table public.tournament_shotgun_category_configs is
'Configuración operativa Shotgun de una categoría dentro de un turno. El tamaño del grupo se interpreta en jugadores para torneos individuales y en equipos para torneos por equipos.';


comment on column public.tournament_shotgun_category_configs.tamano_grupo_normal is
'Tamaño objetivo/normal del grupo. La unidad se deriva del tipo de participación del torneo: jugadores en individual, equipos en equipo.';


comment on column public.tournament_shotgun_category_configs.tamano_grupo_maximo is
'Tamaño excepcional máximo permitido para equilibrar la distribución de grupos. Debe ser igual o mayor al tamaño normal.';


comment on column public.tournament_shotgun_category_configs.intervalo_salida_b_minutos is
'Desfase en minutos de la posición B respecto de la hora base A del turno para esta categoría.';


create index idx_shotgun_category_configs_trsc
    on public.tournament_shotgun_category_configs
       (tournament_round_shift_category_id);


create unique index uq_shotgun_category_config_activa
    on public.tournament_shotgun_category_configs
       (tournament_round_shift_category_id)
    where activo = true;


-- ============================================================
-- 2. HOYOS SELECCIONADOS POR CATEGORÍA
-- ============================================================

create table public.tournament_shotgun_category_holes (
    id uuid primary key default gen_random_uuid(),

    tournament_shotgun_category_config_id uuid not null
        references public.tournament_shotgun_category_configs(id)
        on delete restrict,

    hoyo_id uuid not null
        references public.hoyos(id)
        on delete restrict,

    -- false = solo posición A
    -- true  = posiciones A y B
    salida_doble boolean not null default false,

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


comment on table public.tournament_shotgun_category_holes is
'Hoyos seleccionados por el organizador para una categoría específica dentro de un turno Shotgun. salida_doble=false aporta A; salida_doble=true aporta A y B.';


comment on column public.tournament_shotgun_category_holes.salida_doble is
'Decisión del organizador. False: una posición A. True: dos posiciones A/B. No depende del par del hoyo.';


create index idx_shotgun_category_holes_config
    on public.tournament_shotgun_category_holes
       (tournament_shotgun_category_config_id);


create index idx_shotgun_category_holes_hoyo
    on public.tournament_shotgun_category_holes
       (hoyo_id);


create unique index uq_shotgun_config_hoyo_activo
    on public.tournament_shotgun_category_holes
       (tournament_shotgun_category_config_id, hoyo_id)
    where activo = true;


-- ============================================================
-- 3. TRIGGERS ESTÁNDAR:
-- UPDATED_AT / BAJA LÓGICA / AUDITORÍA
-- ============================================================

create trigger trg_shotgun_category_configs_updated_at
before update
on public.tournament_shotgun_category_configs
for each row
execute function public.set_updated_at();


create trigger trg_track_estatus_shotgun_category_configs
before update
on public.tournament_shotgun_category_configs
for each row
execute function public.track_estatus_activo();


create trigger trg_audit_shotgun_category_configs
after insert or update or delete
on public.tournament_shotgun_category_configs
for each row
execute function public.log_audit();


create trigger trg_shotgun_category_holes_updated_at
before update
on public.tournament_shotgun_category_holes
for each row
execute function public.set_updated_at();


create trigger trg_track_estatus_shotgun_category_holes
before update
on public.tournament_shotgun_category_holes
for each row
execute function public.track_estatus_activo();


create trigger trg_audit_shotgun_category_holes
after insert or update or delete
on public.tournament_shotgun_category_holes
for each row
execute function public.log_audit();


-- ============================================================
-- 4. VALIDAR CONFIGURACIÓN SHOTGUN POR CATEGORÍA
-- ============================================================

create or replace function public.validar_config_shotgun_categoria()
returns trigger
language plpgsql
as $$
declare
    v_sc_activo       boolean;
    v_shift_activo    boolean;
    v_round_activo    boolean;
    v_formato_salida  formato_salida_ronda;
begin

    -- Una fila inactiva queda únicamente como historial.
    if new.activo = false then
        return new;
    end if;


    select
        sc.activo,
        trs.activo,
        tr.activo,
        tr.formato_salida
    into
        v_sc_activo,
        v_shift_activo,
        v_round_activo,
        v_formato_salida
    from public.tournament_round_shift_categories sc
    join public.tournament_round_shifts trs
      on trs.id = sc.tournament_round_shift_id
    join public.tournament_rounds tr
      on tr.id = trs.tournament_round_id
    where sc.id = new.tournament_round_shift_category_id;


    if not found then
        raise exception
            'La relación categoría-turno indicada no existe.';
    end if;


    if v_sc_activo = false then
        raise exception
            'No se puede configurar Shotgun para una categoría que no está activa en el turno.';
    end if;


    if v_shift_activo = false then
        raise exception
            'No se puede configurar Shotgun para un turno desactivado.';
    end if;


    if v_round_activo = false then
        raise exception
            'No se puede configurar Shotgun para una ronda desactivada.';
    end if;


    if v_formato_salida is distinct from 'shotgun'::formato_salida_ronda then
        raise exception
            'Esta configuración solo aplica a rondas con formato de salida shotgun.';
    end if;


    return new;

end;
$$;


create trigger trg_validar_config_shotgun_categoria
before insert or update
on public.tournament_shotgun_category_configs
for each row
execute function public.validar_config_shotgun_categoria();


-- ============================================================
-- 5. VALIDAR HOYO SELECCIONADO PARA CATEGORÍA SHOTGUN
--
-- Comprueba:
-- - configuración activa
-- - relación categoría-turno activa
-- - turno/ronda activos
-- - ronda Shotgun
-- - hoyo pertenece al campo de la ronda
-- - el mismo hoyo NO está asignado a otra categoría del turno
-- ============================================================

create or replace function public.validar_hoyo_shotgun_categoria()
returns trigger
language plpgsql
as $$
declare
    v_config_activo       boolean;
    v_sc_activo           boolean;
    v_shift_id            uuid;
    v_shift_activo        boolean;
    v_round_id            uuid;
    v_round_activo        boolean;
    v_formato_salida      formato_salida_ronda;
    v_campo_ronda         uuid;
    v_campo_hoyo          uuid;
    v_conflictos          integer;
begin

    -- Una fila inactiva queda únicamente como historial.
    if new.activo = false then
        return new;
    end if;


    select
        cfg.activo,
        sc.activo,
        trs.id,
        trs.activo,
        tr.id,
        tr.activo,
        tr.formato_salida,
        tr.campo_golf_id
    into
        v_config_activo,
        v_sc_activo,
        v_shift_id,
        v_shift_activo,
        v_round_id,
        v_round_activo,
        v_formato_salida,
        v_campo_ronda
    from public.tournament_shotgun_category_configs cfg
    join public.tournament_round_shift_categories sc
      on sc.id = cfg.tournament_round_shift_category_id
    join public.tournament_round_shifts trs
      on trs.id = sc.tournament_round_shift_id
    join public.tournament_rounds tr
      on tr.id = trs.tournament_round_id
    where cfg.id = new.tournament_shotgun_category_config_id;


    if not found then
        raise exception
            'La configuración Shotgun indicada no existe.';
    end if;


    if v_config_activo = false then
        raise exception
            'No se pueden seleccionar hoyos para una configuración Shotgun desactivada.';
    end if;


    if v_sc_activo = false then
        raise exception
            'La categoría ya no está activa en este turno.';
    end if;


    if v_shift_activo = false then
        raise exception
            'El turno está desactivado.';
    end if;


    if v_round_activo = false then
        raise exception
            'La ronda está desactivada.';
    end if;


    if v_formato_salida is distinct from 'shotgun'::formato_salida_ronda then
        raise exception
            'La selección de hoyos por categoría solo aplica a rondas Shotgun.';
    end if;


    select h.campo_golf_id
    into v_campo_hoyo
    from public.hoyos h
    where h.id = new.hoyo_id;


    if v_campo_hoyo is null then
        raise exception
            'El hoyo seleccionado no existe.';
    end if;


    if v_campo_hoyo is distinct from v_campo_ronda then
        raise exception
            'El hoyo seleccionado no pertenece al campo de golf de esta ronda.';
    end if;


    -- --------------------------------------------------------
    -- El mismo hoyo físico queda reservado para una sola
    -- categoría dentro del turno.
    --
    -- Si esa categoría marca salida_doble=true, A y B siguen
    -- perteneciendo a la MISMA categoría.
    -- --------------------------------------------------------

    select count(*)
    into v_conflictos
    from public.tournament_shotgun_category_holes sh
    join public.tournament_shotgun_category_configs cfg
      on cfg.id = sh.tournament_shotgun_category_config_id
    join public.tournament_round_shift_categories sc
      on sc.id = cfg.tournament_round_shift_category_id
    where sc.tournament_round_shift_id = v_shift_id
      and sh.hoyo_id = new.hoyo_id
      and sh.activo = true
      and cfg.activo = true
      and sh.id is distinct from new.id
      and cfg.id is distinct from new.tournament_shotgun_category_config_id;


    if v_conflictos > 0 then
        raise exception
            'Este hoyo ya está asignado a otra categoría dentro del mismo turno.';
    end if;


    return new;

end;
$$;


create trigger trg_validar_hoyo_shotgun_categoria
before insert or update
on public.tournament_shotgun_category_holes
for each row
execute function public.validar_hoyo_shotgun_categoria();


-- ============================================================
-- 6. RLS
-- ============================================================

alter table public.tournament_shotgun_category_configs
enable row level security;


alter table public.tournament_shotgun_category_holes
enable row level security;


-- ------------------------------------------------------------
-- CONFIGURACIÓN POR CATEGORÍA — SELECT
-- ------------------------------------------------------------

create policy tournament_shotgun_category_configs_select
on public.tournament_shotgun_category_configs
for select
to public
using (
    public.is_superadmin(auth.uid())
    or (
        activo = true
        and exists (
            select 1
            from public.tournament_round_shift_categories sc
            join public.tournament_round_shifts trs
              on trs.id = sc.tournament_round_shift_id
            join public.tournament_rounds tr
              on tr.id = trs.tournament_round_id
            where sc.id =
                  tournament_shotgun_category_configs.tournament_round_shift_category_id
              and sc.activo = true
              and trs.activo = true
              and tr.activo = true
        )
    )
);


-- ------------------------------------------------------------
-- CONFIGURACIÓN POR CATEGORÍA — WRITE
-- ------------------------------------------------------------

create policy tournament_shotgun_category_configs_write
on public.tournament_shotgun_category_configs
for all
to authenticated
using (
    public.is_superadmin(auth.uid())

    or exists (
        select 1
        from public.tournament_round_shift_categories sc
        join public.tournament_round_shifts trs
          on trs.id = sc.tournament_round_shift_id
        join public.tournament_rounds tr
          on tr.id = trs.tournament_round_id
        join public.tournaments t
          on t.id = tr.tournament_id
        where sc.id =
              tournament_shotgun_category_configs.tournament_round_shift_category_id
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
        from public.tournament_round_shift_categories sc
        join public.tournament_round_shifts trs
          on trs.id = sc.tournament_round_shift_id
        join public.tournament_rounds tr
          on tr.id = trs.tournament_round_id
        join public.tournaments t
          on t.id = tr.tournament_id
        where sc.id =
              tournament_shotgun_category_configs.tournament_round_shift_category_id
          and (
              public.is_tournament_organizer(auth.uid(), t.id)
              or public.is_club_admin(auth.uid(), t.club_id)
          )
    )
);


-- ------------------------------------------------------------
-- HOYOS POR CATEGORÍA — SELECT
-- ------------------------------------------------------------

create policy tournament_shotgun_category_holes_select
on public.tournament_shotgun_category_holes
for select
to public
using (
    public.is_superadmin(auth.uid())
    or (
        activo = true
        and exists (
            select 1
            from public.tournament_shotgun_category_configs cfg
            join public.tournament_round_shift_categories sc
              on sc.id = cfg.tournament_round_shift_category_id
            join public.tournament_round_shifts trs
              on trs.id = sc.tournament_round_shift_id
            join public.tournament_rounds tr
              on tr.id = trs.tournament_round_id
            where cfg.id =
                  tournament_shotgun_category_holes.tournament_shotgun_category_config_id
              and cfg.activo = true
              and sc.activo = true
              and trs.activo = true
              and tr.activo = true
        )
    )
);


-- ------------------------------------------------------------
-- HOYOS POR CATEGORÍA — WRITE
-- ------------------------------------------------------------

create policy tournament_shotgun_category_holes_write
on public.tournament_shotgun_category_holes
for all
to authenticated
using (
    public.is_superadmin(auth.uid())

    or exists (
        select 1
        from public.tournament_shotgun_category_configs cfg
        join public.tournament_round_shift_categories sc
          on sc.id = cfg.tournament_round_shift_category_id
        join public.tournament_round_shifts trs
          on trs.id = sc.tournament_round_shift_id
        join public.tournament_rounds tr
          on tr.id = trs.tournament_round_id
        join public.tournaments t
          on t.id = tr.tournament_id
        where cfg.id =
              tournament_shotgun_category_holes.tournament_shotgun_category_config_id
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
        from public.tournament_shotgun_category_configs cfg
        join public.tournament_round_shift_categories sc
          on sc.id = cfg.tournament_round_shift_category_id
        join public.tournament_round_shifts trs
          on trs.id = sc.tournament_round_shift_id
        join public.tournament_rounds tr
          on tr.id = trs.tournament_round_id
        join public.tournaments t
          on t.id = tr.tournament_id
        where cfg.id =
              tournament_shotgun_category_holes.tournament_shotgun_category_config_id
          and (
              public.is_tournament_organizer(auth.uid(), t.id)
              or public.is_club_admin(auth.uid(), t.club_id)
          )
    )
);


-- ============================================================
-- 7. GRANTS
-- ============================================================

grant select
on public.tournament_shotgun_category_configs
to anon;


grant select, insert, update, delete
on public.tournament_shotgun_category_configs
to authenticated;


grant select
on public.tournament_shotgun_category_holes
to anon;


grant select, insert, update, delete
on public.tournament_shotgun_category_holes
to authenticated;


commit;
