-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 302
-- Premios especiales configurados por torneo / ronda / hoyo
--
-- Alcance deliberadamente corto:
--   - Asocia un premio del catálogo con un torneo, una ronda y un hoyo.
--   - Guarda la configuración operativa específica de esa instancia.
--   - Congela (snapshot) tipo de valor y criterio de comparación del catálogo.
--   - Mantiene total independencia del scoring y ciclo competitivo.
--
-- NO incluye todavía:
--   - responsables / estaciones,
--   - QR,
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
-- 01. TABLA DE PREMIOS CONFIGURADOS PARA EL TORNEO
-- --------------------------------------------------------------------------

create table if not exists public.tournament_special_prizes (
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

    catalog_prize_id uuid not null
        references public.tournament_special_prize_catalog(id)
        on update restrict
        on delete restrict,

    -- Snapshots para que una edición futura de un premio personalizado del
    -- catálogo no cambie silenciosamente la semántica de un torneo existente.
    nombre_snapshot text not null,
    tipo_valor_snapshot text not null,
    criterio_comparacion_snapshot text not null,

    -- Unidad que se usará en esta instancia concreta.
    unidad_captura text,

    -- Reglas operativas estructuradas. No afectan scoring.
    tipo_referencia text,
    requiere_fairway boolean not null default false,
    requiere_green boolean not null default false,
    numero_golpe_evaluado integer,

    -- Información propia de esta edición del torneo.
    descripcion_operativa text,
    patrocinador text,
    premio_ofrecido text,

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

    constraint tournament_special_prizes_nombre_snapshot_ck
        check (nullif(btrim(nombre_snapshot), '') is not null),

    constraint tournament_special_prizes_tipo_valor_ck
        check (tipo_valor_snapshot in ('DISTANCIA', 'GOLPES', 'NUMERO')),

    constraint tournament_special_prizes_criterio_ck
        check (
            criterio_comparacion_snapshot in (
                'MENOR_ES_MEJOR',
                'MAYOR_ES_MEJOR',
                'SOLO_REGISTRO'
            )
        ),

    constraint tournament_special_prizes_referencia_ck
        check (
            tipo_referencia is null
            or tipo_referencia in (
                'BANDERA',
                'LINEA_CENTRAL',
                'ZONA_MARCADA',
                'TEE',
                'OTRA'
            )
        ),

    constraint tournament_special_prizes_golpe_ck
        check (
            numero_golpe_evaluado is null
            or numero_golpe_evaluado between 1 and 20
        )
);

comment on table public.tournament_special_prizes is
'Premios especiales configurados para una ronda y hoyo específicos. Independientes del scoring, freezes y ciclo competitivo.';

comment on column public.tournament_special_prizes.nombre_snapshot is
'Nombre del premio al momento de configurarlo en el torneo.';

comment on column public.tournament_special_prizes.tipo_valor_snapshot is
'Snapshot del tipo de valor del catálogo: DISTANCIA, GOLPES o NUMERO.';

comment on column public.tournament_special_prizes.criterio_comparacion_snapshot is
'Snapshot del criterio de comparación del catálogo.';

comment on column public.tournament_special_prizes.unidad_captura is
'Unidad operativa que se utilizará posteriormente al registrar resultados de este premio.';

comment on column public.tournament_special_prizes.tipo_referencia is
'Referencia física de medición: BANDERA, LINEA_CENTRAL, ZONA_MARCADA, TEE u OTRA.';

comment on column public.tournament_special_prizes.requiere_fairway is
'Regla operativa del premio: la bola debe quedar en fairway para ser válida. No afecta scoring.';

comment on column public.tournament_special_prizes.requiere_green is
'Regla operativa del premio: la bola debe quedar en green para ser válida. No afecta scoring.';

comment on column public.tournament_special_prizes.numero_golpe_evaluado is
'Golpe específico evaluado cuando aplique, por ejemplo el segundo golpe para Mejor Approach.';


-- --------------------------------------------------------------------------
-- 02. ÍNDICES
-- --------------------------------------------------------------------------

-- Evita configurar dos veces el mismo premio del catálogo en el mismo
-- hoyo/ronda mientras ambas instancias estén activas.
create unique index if not exists
    uq_tournament_special_prizes_active
on public.tournament_special_prizes (
    tournament_round_id,
    hoyo_id,
    catalog_prize_id
)
where activo = true;

create index if not exists
    ix_tournament_special_prizes_tournament
on public.tournament_special_prizes (
    tournament_id,
    activo,
    tournament_round_id,
    hoyo_id
);

create index if not exists
    ix_tournament_special_prizes_round_hole
on public.tournament_special_prizes (
    tournament_round_id,
    hoyo_id,
    activo
);


-- --------------------------------------------------------------------------
-- 03. VALIDACIÓN / SNAPSHOT / PROTECCIÓN
-- --------------------------------------------------------------------------

create or replace function public.validar_premio_especial_torneo_302()
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

    v_catalog_nombre text;
    v_catalog_tipo text;
    v_catalog_criterio text;
    v_catalog_unidad text;
    v_catalog_es_sistema boolean;
    v_catalog_organizador_id uuid;
    v_catalog_activo boolean;
begin
    v_admin_id := public.current_admin_id();

    if tg_op = 'DELETE' then
        raise exception
            'Los premios configurados no se eliminan; deben desactivarse.'
            using errcode = '55000';
    end if;

    -- Normalización de textos operativos.
    new.unidad_captura := nullif(
        upper(btrim(coalesce(new.unidad_captura, ''))),
        ''
    );
    new.tipo_referencia := nullif(
        upper(btrim(coalesce(new.tipo_referencia, ''))),
        ''
    );
    new.descripcion_operativa := nullif(
        btrim(coalesce(new.descripcion_operativa, '')),
        ''
    );
    new.patrocinador := nullif(
        btrim(coalesce(new.patrocinador, '')),
        ''
    );
    new.premio_ofrecido := nullif(
        btrim(coalesce(new.premio_ofrecido, '')),
        ''
    );

    -- Torneo válido y activo.
    select t.activo
      into v_tournament_activo
      from public.tournaments t
     where t.id = new.tournament_id;

    if not found then
        raise exception 'El torneo indicado no existe.'
            using errcode = '23503';
    end if;

    if coalesce(v_tournament_activo, false) = false then
        raise exception 'No se puede configurar un premio en un torneo inactivo.'
            using errcode = '55000';
    end if;

    -- La ronda debe pertenecer al torneo seleccionado.
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
        raise exception 'No se puede configurar un premio en una ronda inactiva.'
            using errcode = '55000';
    end if;

    -- El hoyo debe pertenecer al campo de golf de la ronda.
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

    -- Catálogo válido y visible para quien configura.
    select
        c.nombre,
        c.tipo_valor,
        c.criterio_comparacion,
        c.unidad_sugerida,
        c.es_sistema,
        c.organizador_id,
        c.activo
      into
        v_catalog_nombre,
        v_catalog_tipo,
        v_catalog_criterio,
        v_catalog_unidad,
        v_catalog_es_sistema,
        v_catalog_organizador_id,
        v_catalog_activo
      from public.tournament_special_prize_catalog c
     where c.id = new.catalog_prize_id;

    if not found then
        raise exception 'El premio del catálogo indicado no existe.'
            using errcode = '23503';
    end if;

    if coalesce(v_catalog_activo, false) = false then
        raise exception 'No se puede asociar un premio inactivo del catálogo.'
            using errcode = '55000';
    end if;

    if public.is_superadmin(auth.uid()) = false
       and v_catalog_es_sistema = false
       and v_catalog_organizador_id is distinct from v_admin_id
    then
        raise exception
            'No puedes utilizar un premio personalizado perteneciente a otro organizador.'
            using errcode = '42501';
    end if;

    -- El snapshot siempre se deriva del catálogo; no se acepta desde frontend.
    new.nombre_snapshot := v_catalog_nombre;
    new.tipo_valor_snapshot := v_catalog_tipo;
    new.criterio_comparacion_snapshot := v_catalog_criterio;

    if new.unidad_captura is null then
        new.unidad_captura := v_catalog_unidad;
    end if;

    if tg_op = 'INSERT' then
        if new.created_by is null and v_admin_id is not null then
            new.created_by := v_admin_id;
        end if;

        if new.updated_by is null and v_admin_id is not null then
            new.updated_by := v_admin_id;
        end if;
    elsif tg_op = 'UPDATE' then
        -- Se conserva la autoría original.
        if new.created_by is distinct from old.created_by
           or new.created_at is distinct from old.created_at
        then
            raise exception
                'No se puede modificar la autoría original del premio configurado.'
                using errcode = '55000';
        end if;

        if v_admin_id is not null then
            new.updated_by := v_admin_id;
        end if;
    end if;

    return new;
end;
$function$;

revoke all on function public.validar_premio_especial_torneo_302()
from public, anon, authenticated;


drop trigger if exists
    trg_validar_premio_especial_torneo_302
on public.tournament_special_prizes;

create trigger trg_validar_premio_especial_torneo_302
before insert or update or delete
on public.tournament_special_prizes
for each row
execute function public.validar_premio_especial_torneo_302();


drop trigger if exists
    trg_tournament_special_prizes_updated_at
on public.tournament_special_prizes;

create trigger trg_tournament_special_prizes_updated_at
before update
on public.tournament_special_prizes
for each row
execute function public.set_updated_at();


drop trigger if exists
    trg_audit_tournament_special_prizes
on public.tournament_special_prizes;

create trigger trg_audit_tournament_special_prizes
after insert or update or delete
on public.tournament_special_prizes
for each row
execute function public.log_audit();


-- --------------------------------------------------------------------------
-- 04. RLS
-- --------------------------------------------------------------------------

alter table public.tournament_special_prizes enable row level security;

drop policy if exists tournament_special_prizes_select
on public.tournament_special_prizes;

create policy tournament_special_prizes_select
on public.tournament_special_prizes
for select
to authenticated
using (
    public.is_superadmin(auth.uid())
    or public.is_tournament_organizer(auth.uid(), tournament_id)
);


drop policy if exists tournament_special_prizes_insert
on public.tournament_special_prizes;

create policy tournament_special_prizes_insert
on public.tournament_special_prizes
for insert
to authenticated
with check (
    public.is_superadmin(auth.uid())
    or public.is_tournament_organizer(auth.uid(), tournament_id)
);


drop policy if exists tournament_special_prizes_update
on public.tournament_special_prizes;

create policy tournament_special_prizes_update
on public.tournament_special_prizes
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
-- 05. GRANTS
-- --------------------------------------------------------------------------

revoke all on table public.tournament_special_prizes from anon;
revoke delete on table public.tournament_special_prizes from authenticated;

grant select, insert, update
on table public.tournament_special_prizes
to authenticated;

grant select, insert, update
on table public.tournament_special_prizes
to service_role;

commit;
