-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 309
-- Catálogo global de Premios Especiales administrable por Superadmin
--
-- Objetivo:
--   1. Permitir al Superadmin mantener los premios estándar del sistema.
--   2. Incorporar parámetros operativos predeterminados al catálogo.
--   3. Mantener la propiedad y naturaleza de los premios protegidas.
--   4. Mantener los premios de sistema siempre activos y nunca eliminables.
--   5. Conservar el comportamiento actual de premios personalizados.
--
-- NO modifica:
--   - tournament_special_prizes (configuración por torneo)
--   - scoring / Stroke Play / Stableford / A-Go-Go
--   - freezes / snapshots deportivos / tarjetas / leaderboards
--
-- IMPORTANTE:
--   Ejecutar manualmente por el usuario en Supabase.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 01. DEFAULTS OPERATIVOS DEL CATÁLOGO
-- --------------------------------------------------------------------------

alter table public.tournament_special_prize_catalog
    add column if not exists default_tipo_referencia text,
    add column if not exists default_requiere_fairway boolean not null default false,
    add column if not exists default_requiere_green boolean not null default false,
    add column if not exists default_numero_golpe_evaluado integer;

alter table public.tournament_special_prize_catalog
    drop constraint if exists tournament_special_prize_catalog_default_golpe_ck;

alter table public.tournament_special_prize_catalog
    add constraint tournament_special_prize_catalog_default_golpe_ck
    check (
        default_numero_golpe_evaluado is null
        or default_numero_golpe_evaluado > 0
    );

comment on column public.tournament_special_prize_catalog.default_tipo_referencia is
'Referencia operativa sugerida al configurar el premio en un torneo. Ej.: BANDERA, LINEA_CENTRAL, ZONA_MARCADA.';

comment on column public.tournament_special_prize_catalog.default_requiere_fairway is
'Valor predeterminado sugerido para requiere_fairway al asociar el premio a un torneo.';

comment on column public.tournament_special_prize_catalog.default_requiere_green is
'Valor predeterminado sugerido para requiere_green al asociar el premio a un torneo.';

comment on column public.tournament_special_prize_catalog.default_numero_golpe_evaluado is
'Número de golpe sugerido al configurar el premio; NULL significa que no existe un golpe fijo predeterminado.';


-- --------------------------------------------------------------------------
-- 02. NORMALIZACIÓN Y PROTECCIÓN DEL CATÁLOGO
--     Reemplaza la función de la Migración 301.
--
--     Premio sistema:
--       - sólo Superadmin puede editarlo;
--       - no puede cambiar es_sistema;
--       - no puede tener organizador;
--       - no puede desactivarse;
--       - no puede eliminarse.
--
--     Premio personalizado:
--       - Superadmin o propietario pueden editarlo;
--       - no puede cambiar propietario ni naturaleza;
--       - puede desactivarse;
--       - no puede eliminarse.
-- --------------------------------------------------------------------------

create or replace function public.proteger_catalogo_premios_especiales_301()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_admin_id uuid;
    v_is_superadmin boolean;
begin
    v_admin_id := public.current_admin_id();
    v_is_superadmin := coalesce(public.is_superadmin(auth.uid()), false);

    if tg_op = 'DELETE' then
        raise exception
            'Los premios del catálogo no se eliminan.'
            using errcode = '55000';
    end if;

    -- Normalización común.
    new.nombre := btrim(new.nombre);
    new.descripcion := nullif(btrim(coalesce(new.descripcion, '')), '');
    new.unidad_sugerida := nullif(
        upper(btrim(coalesce(new.unidad_sugerida, ''))),
        ''
    );
    new.default_tipo_referencia := nullif(
        upper(btrim(coalesce(new.default_tipo_referencia, ''))),
        ''
    );

    if new.default_numero_golpe_evaluado is not null
       and new.default_numero_golpe_evaluado <= 0
    then
        raise exception
            'El golpe evaluado predeterminado debe ser mayor que cero.'
            using errcode = '23514';
    end if;

    if tg_op = 'INSERT' then
        if new.es_sistema = true then
            if not v_is_superadmin then
                raise exception
                    'Sólo el Superadmin puede crear premios estándar del sistema.'
                    using errcode = '42501';
            end if;

            if new.organizador_id is not null then
                raise exception
                    'Un premio de sistema no puede pertenecer a un organizador.'
                    using errcode = '23514';
            end if;

            new.activo := true;
        else
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

            if not v_is_superadmin
               and new.organizador_id is distinct from v_admin_id
            then
                raise exception
                    'No puedes crear un premio personalizado para otro organizador.'
                    using errcode = '42501';
            end if;
        end if;

        if new.created_by is null and v_admin_id is not null then
            new.created_by := v_admin_id;
        end if;

        if new.updated_by is null and v_admin_id is not null then
            new.updated_by := v_admin_id;
        end if;

        return new;
    end if;

    if tg_op = 'UPDATE' then
        if new.es_sistema is distinct from old.es_sistema then
            raise exception
                'No se puede cambiar la naturaleza sistema/personalizado de un premio.'
                using errcode = '55000';
        end if;

        if new.organizador_id is distinct from old.organizador_id then
            raise exception
                'No se puede transferir la propiedad de un premio.'
                using errcode = '55000';
        end if;

        if new.created_by is distinct from old.created_by
           or new.created_at is distinct from old.created_at
        then
            raise exception
                'No se puede modificar la autoría original del premio.'
                using errcode = '55000';
        end if;

        if old.es_sistema = true then
            if not v_is_superadmin then
                raise exception
                    'Sólo el Superadmin puede editar premios estándar del sistema.'
                    using errcode = '42501';
            end if;

            if new.organizador_id is not null then
                raise exception
                    'Un premio de sistema no puede pertenecer a un organizador.'
                    using errcode = '23514';
            end if;

            if new.activo is distinct from true then
                raise exception
                    'Los premios estándar del sistema deben permanecer activos.'
                    using errcode = '55000';
            end if;
        else
            if not v_is_superadmin
               and old.organizador_id is distinct from v_admin_id
            then
                raise exception
                    'No puedes editar un premio personalizado perteneciente a otro organizador.'
                    using errcode = '42501';
            end if;
        end if;

        if v_admin_id is not null then
            new.updated_by := v_admin_id;
        end if;

        return new;
    end if;

    return null;
end;
$function$;

revoke all on function public.proteger_catalogo_premios_especiales_301()
from public, anon, authenticated;


-- --------------------------------------------------------------------------
-- 03. RLS: SUPERADMIN PUEDE ACTUALIZAR PREMIOS DE SISTEMA
-- --------------------------------------------------------------------------

drop policy if exists tournament_special_prize_catalog_update
on public.tournament_special_prize_catalog;

create policy tournament_special_prize_catalog_update
on public.tournament_special_prize_catalog
for update
to authenticated
using (
    public.is_superadmin(auth.uid())
    or (
        es_sistema = false
        and organizador_id = public.current_admin_id()
    )
)
with check (
    public.is_superadmin(auth.uid())
    or (
        es_sistema = false
        and organizador_id = public.current_admin_id()
    )
);


-- --------------------------------------------------------------------------
-- 04. DEFAULTS DE LOS CINCO PREMIOS ESTÁNDAR
--
-- IMPORTANTE:
-- El SQL Editor de Supabase ejecuta sin auth.uid() de un usuario de la app.
-- El trigger protege correctamente los premios de sistema para uso normal,
-- pero bloquearía estas actualizaciones internas de la propia migración.
-- Por eso se deshabilita ÚNICAMENTE el trigger de catálogo durante este seed
-- y se habilita nuevamente dentro de la misma transacción.
-- --------------------------------------------------------------------------

alter table public.tournament_special_prize_catalog
    disable trigger trg_proteger_catalogo_premios_especiales_301;

update public.tournament_special_prize_catalog
set
    default_tipo_referencia = 'LINEA_CENTRAL',
    default_requiere_fairway = true,
    default_requiere_green = false,
    default_numero_golpe_evaluado = null
where es_sistema = true
  and nombre = 'Drive de Precisión';

update public.tournament_special_prize_catalog
set
    default_tipo_referencia = null,
    default_requiere_fairway = true,
    default_requiere_green = false,
    default_numero_golpe_evaluado = null
where es_sistema = true
  and nombre = 'Drive más largo';

update public.tournament_special_prize_catalog
set
    default_tipo_referencia = null,
    default_requiere_fairway = false,
    default_requiere_green = false,
    default_numero_golpe_evaluado = null
where es_sistema = true
  and nombre = 'Hole In One';

update public.tournament_special_prize_catalog
set
    default_tipo_referencia = 'BANDERA',
    default_requiere_fairway = false,
    default_requiere_green = true,
    default_numero_golpe_evaluado = null
where es_sistema = true
  and nombre = 'Mejor Approach';

update public.tournament_special_prize_catalog
set
    default_tipo_referencia = 'BANDERA',
    default_requiere_fairway = false,
    default_requiere_green = true,
    default_numero_golpe_evaluado = 1
where es_sistema = true
  and nombre = 'OYES / Closest to the Pin';

alter table public.tournament_special_prize_catalog
    enable trigger trg_proteger_catalogo_premios_especiales_301;

commit;
