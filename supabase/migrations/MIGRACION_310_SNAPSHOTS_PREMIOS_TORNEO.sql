-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 310
-- Preservación correcta de snapshots en premios especiales del torneo
-- ============================================================================

begin;

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

    new.unidad_captura := nullif(upper(btrim(coalesce(new.unidad_captura, ''))), '');
    new.tipo_referencia := nullif(upper(btrim(coalesce(new.tipo_referencia, ''))), '');
    new.descripcion_operativa := nullif(btrim(coalesce(new.descripcion_operativa, '')), '');
    new.patrocinador := nullif(btrim(coalesce(new.patrocinador, '')), '');
    new.premio_ofrecido := nullif(btrim(coalesce(new.premio_ofrecido, '')), '');

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

        if coalesce(public.is_superadmin(auth.uid()), false) = false
           and v_catalog_es_sistema = false
           and v_catalog_organizador_id is distinct from v_admin_id
        then
            raise exception
                'No puedes utilizar un premio personalizado perteneciente a otro organizador.'
                using errcode = '42501';
        end if;

        new.nombre_snapshot := v_catalog_nombre;
        new.tipo_valor_snapshot := v_catalog_tipo;
        new.criterio_comparacion_snapshot := v_catalog_criterio;

        if new.unidad_captura is null then
            new.unidad_captura := v_catalog_unidad;
        end if;

        if new.created_by is null and v_admin_id is not null then
            new.created_by := v_admin_id;
        end if;

        if new.updated_by is null and v_admin_id is not null then
            new.updated_by := v_admin_id;
        end if;

    elsif tg_op = 'UPDATE' then
        if new.tournament_id is distinct from old.tournament_id
           or new.tournament_round_id is distinct from old.tournament_round_id
           or new.hoyo_id is distinct from old.hoyo_id
           or new.catalog_prize_id is distinct from old.catalog_prize_id
        then
            raise exception
                'No se puede cambiar torneo, ronda, hoyo o premio base de una configuración existente.'
                using errcode = '55000';
        end if;

        if new.nombre_snapshot is distinct from old.nombre_snapshot
           or new.tipo_valor_snapshot is distinct from old.tipo_valor_snapshot
           or new.criterio_comparacion_snapshot is distinct from old.criterio_comparacion_snapshot
        then
            raise exception
                'Los snapshots del premio configurado son inmutables.'
                using errcode = '55000';
        end if;

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

commit;
