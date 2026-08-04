-- =========================================================
-- MIGRACIÓN 094
-- Corrección: categorías sin rango de hándicap definido (ej.
-- Senior 1/2, que se deciden por edad, no por hándicap) se
-- estaban reasignando incorrectamente — la función buscaba "en
-- qué categoría cae su hándicap" y, como estas categorías nunca
-- tienen rango, jamás podían encontrarse a sí mismas.
--
-- Corrección: si la categoría ELEGIDA por el jugador no tiene
-- ningún rango de hándicap (ni global ni por torneo), se acepta
-- tal cual, sin validar/reasignar — solo se resuelve su marca.
-- La reasignación automática solo aplica entre categorías que sí
-- tienen rango definido.
-- =========================================================

create or replace function resolver_categoria_y_marca()
returns trigger as $$
declare
  v_handicap_jugador        numeric(4,1);
  v_campo_id                uuid;
  v_hay_franjas             boolean;
  v_categoria_correcta_id   uuid;
  v_categoria_estandar      categoria_marca_salida;
  v_elegida_tiene_rango     boolean;
begin
  select t.campo_golf_id into v_campo_id from tournaments t where t.id = new.tournament_id;

  if new.tournament_team_id is not null then
    if new.tournament_category_id is not null then
      select c.categoria_estandar_marca into v_categoria_estandar
        from tournament_categories tc
        join categories c on c.id = tc.category_id
       where tc.id = new.tournament_category_id;
    end if;

  else
    select coalesce(p.handicap_verificado, p.handicap_declarado)
      into v_handicap_jugador
      from players p where p.id = new.player_id;

    select exists (
      select 1 from tournament_franjas_handicap where tournament_id = new.tournament_id
    ) into v_hay_franjas;

    if v_hay_franjas then
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
      select (
        coalesce(tc.handicap_minimo, c.handicap_minimo) is not null
        or coalesce(tc.handicap_maximo, c.handicap_maximo) is not null
      ) into v_elegida_tiene_rango
        from tournament_categories tc
        join categories c on c.id = tc.category_id
       where tc.id = new.tournament_category_id;

      if v_elegida_tiene_rango and v_handicap_jugador is not null then
        select tc.id, c.categoria_estandar_marca
          into v_categoria_correcta_id, v_categoria_estandar
          from tournament_categories tc
          join categories c on c.id = tc.category_id
         where tc.tournament_id = new.tournament_id
           and (coalesce(tc.handicap_minimo, c.handicap_minimo) is not null
                or coalesce(tc.handicap_maximo, c.handicap_maximo) is not null)
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

comment on function resolver_categoria_y_marca is 'Asigna marca_salida_id automáticamente. Categorías sin rango de hándicap (ej. Senior, por edad) se aceptan tal cual sin validar/reasignar. Entre categorías CON rango, valida/reasigna por hándicap. Con equipo, solo resuelve la marca desde la categoría heredada.';
