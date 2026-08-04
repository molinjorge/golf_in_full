-- =========================================================
-- MIGRACIÓN 091
-- Asignación automática de marca de salida al inscribirse.
--
-- SIN EQUIPO, dos caminos:
-- A) Torneo con varias categorías: cada categoría trae su
--    "color" de marca fijo (categories.categoria_estandar_marca)
--    y un rango de hándicap (global, con override opcional por
--    torneo en tournament_categories). El jugador elige
--    categoría; si su hándicap no cae en el rango de la elegida,
--    se reasigna automáticamente a la correcta y se le informa
--    (sin bloquear).
-- B) Torneo de categoría única: se usa una tabla aparte de
--    franjas de hándicap, propia de ese torneo, que manda
--    directo a una marca — independiente de la categoría.
--
-- CON EQUIPO: la categoría ya se heredó del equipo (trigger
-- existente); aquí solo se resuelve la marca a partir de esa
-- categoría — sin validar/reasignar nada por hándicap individual.
--
-- En todos los casos, la marca real se busca en el campo
-- específico del torneo por su categoria_estandar.
-- =========================================================

alter table categories
  add column categoria_estandar_marca categoria_marca_salida;

comment on column categories.categoria_estandar_marca is 'Color de marca de salida que corresponde a esta categoría (ej. AA -> azul). Vacío para categorías que no deban asignar marca automáticamente.';

alter table tournament_categories
  add column handicap_minimo numeric(4,1),
  add column handicap_maximo numeric(4,1);

comment on column tournament_categories.handicap_minimo is 'Override del rango de hándicap de esta categoría, solo para este torneo. NULL = usa categories.handicap_minimo (global).';
comment on column tournament_categories.handicap_maximo is 'Override del rango de hándicap de esta categoría, solo para este torneo. NULL = usa categories.handicap_maximo (global), que a su vez NULL puede significar "sin tope" (categoría ABIERTA).';

create table tournament_franjas_handicap (
  id                 uuid                    primary key default gen_random_uuid(),
  tournament_id      uuid                    not null references tournaments (id) on delete restrict,
  handicap_desde     numeric(4,1)            not null,
  handicap_hasta     numeric(4,1),
  categoria_estandar categoria_marca_salida  not null,

  created_by         uuid                    references admin_users (id) on delete restrict,
  created_at         timestamptz             not null default now(),

  constraint tournament_franjas_handicap_rango_valido check (handicap_hasta is null or handicap_hasta >= handicap_desde)
);

comment on table tournament_franjas_handicap is 'Solo se usa en torneos de categoría única: franjas de hándicap -> color de marca, independiente de cualquier categoría.';

create index idx_tournament_franjas_handicap_tournament on tournament_franjas_handicap (tournament_id);

alter table tournament_franjas_handicap enable row level security;

create policy tournament_franjas_handicap_select on tournament_franjas_handicap
  for select to public using (true);

create policy tournament_franjas_handicap_write on tournament_franjas_handicap
  for all to authenticated
  using (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  )
  with check (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

grant select on tournament_franjas_handicap to anon;
grant select, insert, update, delete on tournament_franjas_handicap to authenticated;

alter table tournament_registrations
  add column marca_salida_id uuid references marcas_salida (id) on delete restrict,
  add column categoria_reasignada boolean not null default false;

comment on column tournament_registrations.marca_salida_id is 'Marca de salida asignada automáticamente (propia, o heredada del equipo). Puede corregirse manualmente después.';
comment on column tournament_registrations.categoria_reasignada is 'true si el jugador eligió una categoría pero su hándicap lo ubicó en otra distinta — solo aplica a inscripciones sin equipo, en torneos con varias categorías.';

create or replace function resolver_categoria_y_marca()
returns trigger as $$
declare
  v_handicap_jugador        numeric(4,1);
  v_campo_id                uuid;
  v_hay_franjas             boolean;
  v_categoria_correcta_id   uuid;
  v_categoria_estandar      categoria_marca_salida;
begin
  select t.campo_golf_id into v_campo_id from tournaments t where t.id = new.tournament_id;

  if new.tournament_team_id is not null then
    -- CON EQUIPO: la categoría ya se heredó del equipo (otro
    -- trigger). Aquí solo se resuelve la marca a partir de esa
    -- categoría, sin validar hándicap individual.
    if new.tournament_category_id is not null then
      select c.categoria_estandar_marca into v_categoria_estandar
        from tournament_categories tc
        join categories c on c.id = tc.category_id
       where tc.id = new.tournament_category_id;
    end if;

  else
    -- SIN EQUIPO
    select coalesce(p.handicap_verificado, p.handicap_declarado)
      into v_handicap_jugador
      from players p where p.id = new.player_id;

    select exists (
      select 1 from tournament_franjas_handicap where tournament_id = new.tournament_id
    ) into v_hay_franjas;

    if v_hay_franjas then
      -- Camino B: categoría única, resuelve directo por franja
      if v_handicap_jugador is null then
        raise exception 'No se puede asignar marca de salida: el jugador no tiene hándicap capturado.';
      end if;

      select categoria_estandar into v_categoria_estandar
        from tournament_franjas_handicap
       where tournament_id = new.tournament_id
         and handicap_desde <= v_handicap_jugador
         and (handicap_hasta is null or v_handicap_jugador <= handicap_hasta)
       limit 1;

      if v_categoria_estandar is null then
        raise exception 'El hándicap del jugador (%) no cae en ninguna franja definida para este torneo.', v_handicap_jugador;
      end if;

    else
      -- Camino A: torneo con varias categorías
      if v_handicap_jugador is not null then
        select tc.id, c.categoria_estandar_marca
          into v_categoria_correcta_id, v_categoria_estandar
          from tournament_categories tc
          join categories c on c.id = tc.category_id
         where tc.tournament_id = new.tournament_id
           and v_handicap_jugador >= coalesce(tc.handicap_minimo, c.handicap_minimo)
           and (
             coalesce(tc.handicap_maximo, c.handicap_maximo) is null
             or v_handicap_jugador <= coalesce(tc.handicap_maximo, c.handicap_maximo)
           )
         limit 1;

        if v_categoria_correcta_id is not null and v_categoria_correcta_id is distinct from new.tournament_category_id then
          new.tournament_category_id := v_categoria_correcta_id;
          new.categoria_reasignada := true;
        end if;
      end if;

      select c.categoria_estandar_marca into v_categoria_estandar
        from tournament_categories tc
        join categories c on c.id = tc.category_id
       where tc.id = new.tournament_category_id;
    end if;
  end if;

  if v_categoria_estandar is not null then
    select id into new.marca_salida_id
      from marcas_salida
     where campo_golf_id = v_campo_id
       and categoria_estandar = v_categoria_estandar
       and activo = true
     limit 1;

    if new.marca_salida_id is null then
      raise exception 'El campo de este torneo no tiene una marca de salida configurada para la categoría "%". Complétala en el catálogo de campos antes de continuar.', v_categoria_estandar;
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

-- Nombre con prefijo "trg_z_" a propósito: Postgres dispara los
-- triggers BEFORE INSERT en orden alfabético, y este depende de
-- que tournament_category_id ya esté resuelto (por herencia del
-- equipo, o por la validación de "sin equipo") antes de correr —
-- necesita ir después de trg_validar_categoria_registro_equipo.
create trigger trg_z_resolver_categoria_y_marca
before insert on tournament_registrations
for each row execute function resolver_categoria_y_marca();

comment on function resolver_categoria_y_marca is 'Asigna marca_salida_id automáticamente. Sin equipo: valida/reasigna categoría por hándicap (o usa franjas si el torneo es de categoría única). Con equipo: solo resuelve la marca desde la categoría ya heredada del equipo.';
