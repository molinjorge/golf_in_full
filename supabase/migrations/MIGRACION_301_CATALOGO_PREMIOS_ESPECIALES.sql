-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 301
-- Catálogo transversal de Premios Especiales del Torneo
--
-- Alcance:
--   - Crea únicamente el catálogo reutilizable de premios.
--   - Premios estándar protegidos del sistema.
--   - Premios personalizados propiedad de un organizador.
--   - Define tipo de valor, criterio de comparación y unidad sugerida.
--   - NO vincula premios todavía con torneos, rondas, hoyos, jugadores,
--     equipos, tarjetas, scoring, freezes ni ciclo competitivo.
--
-- IMPORTANTE:
--   Esta migración debe ser ejecutada manualmente por el usuario en Supabase.
-- ============================================================================

begin;

create table if not exists public.tournament_special_prize_catalog (
    id uuid primary key default gen_random_uuid(),
    nombre text not null,
    descripcion text,
    tipo_valor text not null,
    criterio_comparacion text not null,
    unidad_sugerida text,
    es_sistema boolean not null default false,
    organizador_id uuid references public.admin_users(id) on update restrict on delete restrict,
    activo boolean not null default true,
    created_by uuid references public.admin_users(id) on update restrict on delete restrict,
    updated_by uuid references public.admin_users(id) on update restrict on delete restrict,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint tournament_special_prize_catalog_nombre_ck
        check (nullif(btrim(nombre), '') is not null),

    constraint tournament_special_prize_catalog_tipo_valor_ck
        check (tipo_valor in ('DISTANCIA', 'GOLPES', 'NUMERO')),

    constraint tournament_special_prize_catalog_criterio_ck
        check (
            criterio_comparacion in (
                'MENOR_ES_MEJOR',
                'MAYOR_ES_MEJOR',
                'SOLO_REGISTRO'
            )
        ),

    constraint tournament_special_prize_catalog_propiedad_ck
        check (
            (es_sistema = true and organizador_id is null)
            or
            (es_sistema = false and organizador_id is not null)
        )
);

comment on table public.tournament_special_prize_catalog is
'Catálogo transversal de Premios Especiales del Torneo. Independiente de scoring y del ciclo competitivo.';

comment on column public.tournament_special_prize_catalog.tipo_valor is
'Naturaleza del valor que se capturará: DISTANCIA, GOLPES o NUMERO.';

comment on column public.tournament_special_prize_catalog.criterio_comparacion is
'Criterio de orden provisional: MENOR_ES_MEJOR, MAYOR_ES_MEJOR o SOLO_REGISTRO.';

comment on column public.tournament_special_prize_catalog.unidad_sugerida is
'Unidad sugerida del catálogo. La instancia del premio en un torneo podrá definir posteriormente su unidad operativa.';

comment on column public.tournament_special_prize_catalog.es_sistema is
'TRUE para premios estándar protegidos de Tee Central. Estos registros no pueden editarse, desactivarse ni eliminarse.';

comment on column public.tournament_special_prize_catalog.organizador_id is
'Propietario del premio personalizado. NULL exclusivamente para premios estándar del sistema.';

create unique index if not exists uq_tournament_special_prize_catalog_system_name
on public.tournament_special_prize_catalog (lower(btrim(nombre)))
where es_sistema = true;

create unique index if not exists uq_tournament_special_prize_catalog_organizer_name
on public.tournament_special_prize_catalog (
    organizador_id,
    lower(btrim(nombre))
)
where es_sistema = false;

create index if not exists ix_tournament_special_prize_catalog_organizer_active
on public.tournament_special_prize_catalog (
    organizador_id,
    activo,
    nombre
)
where es_sistema = false;

create index if not exists ix_tournament_special_prize_catalog_system_active
on public.tournament_special_prize_catalog (
    activo,
    nombre
)
where es_sistema = true;

create or replace function public.proteger_catalogo_premios_especiales_301()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_admin_id uuid;
begin
    v_admin_id := public.current_admin_id();

    if tg_op = 'INSERT' then
        new.nombre := btrim(new.nombre);
        new.descripcion := nullif(btrim(coalesce(new.descripcion, '')), '');
        new.unidad_sugerida := nullif(
            upper(btrim(coalesce(new.unidad_sugerida, ''))),
            ''
        );

        if new.created_by is null and v_admin_id is not null then
            new.created_by := v_admin_id;
        end if;

        if new.updated_by is null and v_admin_id is not null then
            new.updated_by := v_admin_id;
        end if;

        if new.es_sistema = false then
            if new.organizador_id is null then
                raise exception
                    'Un premio personalizado debe pertenecer a un organizador.'
                    using errcode = '23514';
            end if;

            if not exists (
                select 1
                from public.admin_users au
                where au.id = new.organizador_id
                  and au.activo = true
            ) then
                raise exception
                    'El organizador propietario del premio no existe o está inactivo.'
                    using errcode = '23503';
            end if;
        end if;

        return new;
    end if;

    if tg_op = 'UPDATE' then
        if old.es_sistema = true then
            raise exception
                'Los premios estándar del sistema no pueden editarse ni desactivarse.'
                using errcode = '55000';
        end if;

        if new.es_sistema is distinct from old.es_sistema then
            raise exception
                'No se puede cambiar la propiedad sistema/personalizado de un premio.'
                using errcode = '55000';
        end if;

        if new.organizador_id is distinct from old.organizador_id then
            raise exception
                'No se puede transferir un premio personalizado a otro organizador.'
                using errcode = '55000';
        end if;

        if new.created_by is distinct from old.created_by
           or new.created_at is distinct from old.created_at
        then
            raise exception
                'No se puede modificar la autoría original del premio.'
                using errcode = '55000';
        end if;

        new.nombre := btrim(new.nombre);
        new.descripcion := nullif(btrim(coalesce(new.descripcion, '')), '');
        new.unidad_sugerida := nullif(
            upper(btrim(coalesce(new.unidad_sugerida, ''))),
            ''
        );

        if v_admin_id is not null then
            new.updated_by := v_admin_id;
        end if;

        return new;
    end if;

    if tg_op = 'DELETE' then
        raise exception
            'Los premios del catálogo no se eliminan; los premios personalizados sólo pueden desactivarse.'
            using errcode = '55000';
    end if;

    return null;
end;
$function$;

revoke all on function public.proteger_catalogo_premios_especiales_301()
from public, anon, authenticated;

drop trigger if exists trg_proteger_catalogo_premios_especiales_301
on public.tournament_special_prize_catalog;

create trigger trg_proteger_catalogo_premios_especiales_301
before insert or update or delete
on public.tournament_special_prize_catalog
for each row
execute function public.proteger_catalogo_premios_especiales_301();

drop trigger if exists trg_tournament_special_prize_catalog_updated_at
on public.tournament_special_prize_catalog;

create trigger trg_tournament_special_prize_catalog_updated_at
before update
on public.tournament_special_prize_catalog
for each row
execute function public.set_updated_at();

drop trigger if exists trg_audit_tournament_special_prize_catalog
on public.tournament_special_prize_catalog;

create trigger trg_audit_tournament_special_prize_catalog
after insert or update or delete
on public.tournament_special_prize_catalog
for each row
execute function public.log_audit();

alter table public.tournament_special_prize_catalog enable row level security;

drop policy if exists tournament_special_prize_catalog_select
on public.tournament_special_prize_catalog;

create policy tournament_special_prize_catalog_select
on public.tournament_special_prize_catalog
for select
to authenticated
using (
    public.is_superadmin(auth.uid())
    or es_sistema = true
    or organizador_id = public.current_admin_id()
);

drop policy if exists tournament_special_prize_catalog_insert
on public.tournament_special_prize_catalog;

create policy tournament_special_prize_catalog_insert
on public.tournament_special_prize_catalog
for insert
to authenticated
with check (
    public.is_superadmin(auth.uid())
    or (
        es_sistema = false
        and organizador_id = public.current_admin_id()
        and exists (
            select 1
            from public.admin_users au
            where au.id = public.current_admin_id()
              and au.auth_user_id = auth.uid()
              and au.activo = true
        )
    )
);

drop policy if exists tournament_special_prize_catalog_update
on public.tournament_special_prize_catalog;

create policy tournament_special_prize_catalog_update
on public.tournament_special_prize_catalog
for update
to authenticated
using (
    es_sistema = false
    and (
        public.is_superadmin(auth.uid())
        or organizador_id = public.current_admin_id()
    )
)
with check (
    es_sistema = false
    and (
        public.is_superadmin(auth.uid())
        or organizador_id = public.current_admin_id()
    )
);

revoke all on table public.tournament_special_prize_catalog from anon;
revoke delete on table public.tournament_special_prize_catalog from authenticated;

grant select, insert, update
on table public.tournament_special_prize_catalog
to authenticated;

grant select, insert, update
on table public.tournament_special_prize_catalog
to service_role;

insert into public.tournament_special_prize_catalog (
    nombre,
    descripcion,
    tipo_valor,
    criterio_comparacion,
    unidad_sugerida,
    es_sistema,
    organizador_id,
    activo
)
values
(
    'Drive de Precisión',
    'Premio al golpe de salida que quede más cerca de la línea o referencia de precisión definida para el hoyo. Las condiciones concretas de validez se definirán al configurar el premio en el torneo.',
    'DISTANCIA',
    'MENOR_ES_MEJOR',
    'CENTIMETROS',
    true,
    null,
    true
),
(
    'Drive más largo',
    'Premio al golpe de salida que alcance la mayor distancia válida en el hoyo designado. Las condiciones concretas de validez se definirán al configurar el premio en el torneo.',
    'DISTANCIA',
    'MAYOR_ES_MEJOR',
    'METROS',
    true,
    null,
    true
),
(
    'Hole In One',
    'Premio por embocar la bola en un solo golpe desde el tee del hoyo designado. Este premio es independiente de cualquier regla de scoring Stableford.',
    'GOLPES',
    'MENOR_ES_MEJOR',
    'GOLPES',
    true,
    null,
    true
),
(
    'Mejor Approach',
    'Premio al golpe de aproximación definido por el organizador que deje la bola más cerca de la bandera en el hoyo designado.',
    'DISTANCIA',
    'MENOR_ES_MEJOR',
    'CENTIMETROS',
    true,
    null,
    true
),
(
    'OYES / Closest to the Pin',
    'Premio al golpe de salida que deje la bola más cerca de la bandera en el hoyo designado.',
    'DISTANCIA',
    'MENOR_ES_MEJOR',
    'CENTIMETROS',
    true,
    null,
    true
)
on conflict do nothing;

commit;
