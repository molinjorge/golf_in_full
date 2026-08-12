-- =====================================================================
-- MIGRACIÓN 134 — INTEGRIDAD DE CATEGORÍAS EN EQUIPOS
-- GOLF IN FULL
--
-- OBJETIVOS
-- 1) Corregir equipos e integrantes con categoría NULL cuando el torneo
--    tiene exactamente una categoría.
-- 2) Evitar que nuevos equipos definitivos queden sin categoría cuando
--    el torneo tiene categorías.
-- 3) Corregir la causa raíz de equipos automáticos de cortesía:
--      - 0 categorías: NULL permitido.
--      - 1 categoría: asignación automática.
--      - >1 categorías: NO crear equipos automáticamente; quedan pendientes
--        para materialización manual desde la UI con categoría explícita.
-- 4) Proteger en servidor el cupo máximo de equipos de cortesía.
--
-- IMPORTANTE
-- - La categoría deportiva SIEMPRE es tournament_categories.id.
-- - patrocinadores.categoria_patrocinador_id es categoría COMERCIAL y
--   no participa en esta lógica.
-- - NO se agrega patrocinadores.tournament_category_id.
-- - NO toca Shotgun.
-- =====================================================================

begin;

-- =====================================================================
-- 0. GUARDAS PREVIAS
-- =====================================================================

do $$
declare
  v_invalid_team_category integer;
begin
  select count(*)
    into v_invalid_team_category
  from public.tournament_teams tt
  left join public.tournament_categories tc
    on tc.id = tt.tournament_category_id
  where tt.tournament_category_id is not null
    and (
      tc.id is null
      or tc.tournament_id is distinct from tt.tournament_id
    );

  if v_invalid_team_category > 0 then
    raise exception
      'Migración 134 abortada: existen % equipos cuya categoría no pertenece a su torneo.',
      v_invalid_team_category;
  end if;
end;
$$;

-- =====================================================================
-- 1. PROTECCIÓN DEFENSIVA DE CATEGORÍA EN tournament_teams
-- =====================================================================

create or replace function public.resolver_categoria_unica_equipo()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
declare
  v_num_categorias integer;
  v_categoria_id uuid;
begin
  if new.tournament_category_id is not null then
    return new;
  end if;

  select count(*), min(tc.id)
    into v_num_categorias, v_categoria_id
  from public.tournament_categories tc
  where tc.tournament_id = new.tournament_id;

  if v_num_categorias = 0 then
    return new;
  end if;

  if v_num_categorias = 1 then
    new.tournament_category_id := v_categoria_id;
    return new;
  end if;

  raise exception
    'El torneo tiene múltiples categorías. Debes seleccionar la categoría del equipo.';
end;
$function$;

drop trigger if exists trg_resolver_categoria_unica_equipo
on public.tournament_teams;

create trigger trg_resolver_categoria_unica_equipo
before insert or update
on public.tournament_teams
for each row
execute function public.resolver_categoria_unica_equipo();

-- =====================================================================
-- 2. PROTECCIÓN SERVER-SIDE DEL CUPO DE EQUIPOS DE CORTESÍA
-- =====================================================================

create or replace function public.validar_cupo_equipos_cortesia()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
declare
  v_patrocinador_tournament_id uuid;
  v_cupo_jugadores integer;
  v_jugadores_por_equipo integer;
  v_equipos_permitidos integer;
  v_equipos_activos integer;
begin
  if new.patrocinador_id is null or coalesce(new.activo, true) = false then
    return new;
  end if;

  select p.tournament_id,
         p.cupo_jugadores_cortesia
    into v_patrocinador_tournament_id,
         v_cupo_jugadores
  from public.patrocinadores p
  where p.id = new.patrocinador_id;

  if not found then
    raise exception 'El patrocinador indicado no existe.';
  end if;

  if v_patrocinador_tournament_id is distinct from new.tournament_id then
    raise exception
      'El patrocinador no pertenece al mismo torneo que el equipo.';
  end if;

  select t.jugadores_por_equipo
    into v_jugadores_por_equipo
  from public.tournaments t
  where t.id = new.tournament_id;

  if v_jugadores_por_equipo is null or v_jugadores_por_equipo <= 0 then
    raise exception
      'El torneo por equipos no tiene un tamaño de equipo válido.';
  end if;

  v_equipos_permitidos :=
    ceil(coalesce(v_cupo_jugadores, 0)::numeric / v_jugadores_por_equipo)::integer;

  if v_equipos_permitidos <= 0 then
    raise exception
      'El patrocinador no tiene cupo disponible para crear equipos de cortesía.';
  end if;

  select count(*)
    into v_equipos_activos
  from public.tournament_teams tt
  where tt.patrocinador_id = new.patrocinador_id
    and tt.tournament_id = new.tournament_id
    and tt.activo = true
    and (
      tg_op = 'INSERT'
      or tt.id <> new.id
    );

  if v_equipos_activos >= v_equipos_permitidos then
    raise exception
      'Se alcanzó el cupo máximo de equipos de cortesía para este patrocinador (% equipos).',
      v_equipos_permitidos;
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_validar_cupo_equipos_cortesia
on public.tournament_teams;

create trigger trg_validar_cupo_equipos_cortesia
before insert or update of patrocinador_id, tournament_id, activo
on public.tournament_teams
for each row
execute function public.validar_cupo_equipos_cortesia();

-- =====================================================================
-- 3. CAUSA RAÍZ: crear_equipos_cortesia_patrocinador()
-- =====================================================================

create or replace function public.crear_equipos_cortesia_patrocinador()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_tipo_participacion   formato_juego_torneo;
  v_jugadores_por_equipo integer;
  v_equipos_necesarios   integer;
  v_equipos_existentes   integer;
  v_num_categorias       integer;
  v_categoria_id         uuid;
  v_nombre_equipo        text;
  i                       integer;
begin
  if coalesce(new.cupo_jugadores_cortesia, 0) <= 0 then
    return new;
  end if;

  select tf.tipo_participacion,
         t.jugadores_por_equipo
    into v_tipo_participacion,
         v_jugadores_por_equipo
  from public.tournaments t
  join public.tournament_formats tf
    on tf.id = t.tournament_format_id
  where t.id = new.tournament_id;

  if not found then
    raise exception 'El torneo del patrocinador no existe.';
  end if;

  if v_tipo_participacion is distinct from 'equipo' then
    return new;
  end if;

  if v_jugadores_por_equipo is null or v_jugadores_por_equipo <= 0 then
    raise exception
      'El torneo por equipos no tiene un tamaño de equipo válido.';
  end if;

  select count(*), min(tc.id)
    into v_num_categorias, v_categoria_id
  from public.tournament_categories tc
  where tc.tournament_id = new.tournament_id;

  if v_num_categorias > 1 then
    raise notice
      'Patrocinador %: torneo multicategoría. Los equipos de cortesía quedan pendientes de materializar desde la UI.',
      new.id;
    return new;
  end if;

  if v_num_categorias = 0 then
    v_categoria_id := null;
  end if;

  v_equipos_necesarios :=
    ceil(new.cupo_jugadores_cortesia::numeric / v_jugadores_por_equipo)::integer;

  select count(*)
    into v_equipos_existentes
  from public.tournament_teams tt
  where tt.patrocinador_id = new.id
    and tt.tournament_id = new.tournament_id
    and tt.activo = true;

  if v_equipos_existentes >= v_equipos_necesarios then
    return new;
  end if;

  for i in (v_equipos_existentes + 1)..v_equipos_necesarios loop
    v_nombre_equipo :=
      case
        when i = 1 then new.nombre
        else new.nombre || ' - ' || i::text
      end;

    insert into public.tournament_teams (
      tournament_id,
      nombre_equipo,
      patrocinador_id,
      tournament_category_id
    )
    values (
      new.tournament_id,
      v_nombre_equipo,
      new.id,
      v_categoria_id
    );
  end loop;

  return new;
end;
$function$;

-- =====================================================================
-- 4. BACKFILL GENÉRICO
-- =====================================================================

update public.tournament_teams tt
set tournament_category_id = tc.id
from public.tournament_categories tc
where tt.tournament_category_id is null
  and tc.tournament_id = tt.tournament_id
  and (
    select count(*)
    from public.tournament_categories tc2
    where tc2.tournament_id = tt.tournament_id
  ) = 1;

update public.tournament_registrations tr
set tournament_category_id = tt.tournament_category_id
from public.tournament_teams tt
where tt.id = tr.tournament_team_id
  and tr.activo = true
  and tt.tournament_category_id is not null
  and tr.tournament_category_id is distinct from tt.tournament_category_id;

update public.patrocinador_jugadores_cortesia pjc
set tournament_category_id = tt.tournament_category_id
from public.tournament_teams tt
where tt.id = pjc.tournament_team_id
  and pjc.activo = true
  and pjc.tournament_registration_id is null
  and tt.tournament_category_id is not null
  and pjc.tournament_category_id is distinct from tt.tournament_category_id;

update public.patrocinador_jugadores_cortesia pjc
set tournament_category_id = tc.id
from public.patrocinadores p
join public.tournament_categories tc
  on tc.tournament_id = p.tournament_id
where p.id = pjc.patrocinador_id
  and pjc.activo = true
  and pjc.tournament_registration_id is null
  and pjc.tournament_team_id is null
  and pjc.tournament_category_id is null
  and (
    select count(*)
    from public.tournament_categories tc2
    where tc2.tournament_id = p.tournament_id
  ) = 1;

-- =====================================================================
-- 5. VERIFICACIÓN DURA DENTRO DE LA TRANSACCIÓN
-- =====================================================================

do $$
declare
  v_equipos_single_null integer;
  v_reg_divergentes integer;
  v_cortesias_single_null integer;
  v_categorias_invalidas integer;
begin
  select count(*)
    into v_equipos_single_null
  from public.tournament_teams tt
  where tt.tournament_category_id is null
    and (
      select count(*)
      from public.tournament_categories tc
      where tc.tournament_id = tt.tournament_id
    ) = 1;

  select count(*)
    into v_reg_divergentes
  from public.tournament_registrations tr
  join public.tournament_teams tt
    on tt.id = tr.tournament_team_id
  where tr.activo = true
    and tt.tournament_category_id is not null
    and tr.tournament_category_id is distinct from tt.tournament_category_id;

  select count(*)
    into v_cortesias_single_null
  from public.patrocinador_jugadores_cortesia pjc
  join public.patrocinadores p
    on p.id = pjc.patrocinador_id
  where pjc.activo = true
    and pjc.tournament_registration_id is null
    and pjc.tournament_category_id is null
    and (
      select count(*)
      from public.tournament_categories tc
      where tc.tournament_id = p.tournament_id
    ) = 1;

  select count(*)
    into v_categorias_invalidas
  from public.tournament_teams tt
  left join public.tournament_categories tc
    on tc.id = tt.tournament_category_id
  where tt.tournament_category_id is not null
    and (
      tc.id is null
      or tc.tournament_id is distinct from tt.tournament_id
    );

  if v_equipos_single_null > 0
     or v_reg_divergentes > 0
     or v_cortesias_single_null > 0
     or v_categorias_invalidas > 0
  then
    raise exception
      'Migración 134 incompleta. equipos_single_null=%, registros_divergentes=%, cortesias_single_null=%, categorias_invalidas=%',
      v_equipos_single_null,
      v_reg_divergentes,
      v_cortesias_single_null,
      v_categorias_invalidas;
  end if;
end;
$$;

commit;
