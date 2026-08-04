-- =========================================================
-- MIGRACIÓN 095
-- Extiende resolver_categoria_y_marca(): categorías definidas
-- por RANGO DE EDAD (ej. Senior 1/2) también se validan/reasignan,
-- simétrico a como ya funciona con hándicap. La edad se calcula
-- a la fecha de inicio del torneo.
--
-- ADVERTENCIA: usé los nombres de columna edad_minima/edad_maxima
-- por convención gramatical (igual que ya existe handicap_minimo/
-- handicap_maximo) — VERIFICA que esos sean los nombres reales en
-- tu tabla categories antes de correr esta migración. Si son
-- distintos, dímelo y te la corrijo antes de que la corras.
-- =========================================================

create or replace function resolver_categoria_y_marca()
returns trigger as $$
declare
  v_handicap_jugador         numeric(4,1);
  v_edad_jugador              integer;
  v_campo_id                 uuid;
  v_hay_franjas              boolean;
  v_categoria_correcta_id    uuid;
  v_categoria_estandar       categoria_marca_salida;
  v_elegida_tiene_rango_hi   boolean;
  v_elegida_tiene_rango_edad boolean;
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

    select date_part('year', age(t.fecha_inicio, p.fecha_nacimiento))::integer
      into v_edad_jugador
      from players p, tournaments t
     where p.id = new.player_id and t.id = new.tournament_id;

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
      ), (
        c.edad_minima is not null or c.edad_maxima is not null
      )
      into v_elegida_tiene_rango_hi, v_elegida_tiene_rango_edad
        from tournament_categories tc
        join categories c on c.id = tc.category_id
       where tc.id = new.tournament_category_id;

      if v_elegida_tiene_rango_hi and v_handicap_jugador is not null then
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

      elsif v_elegida_tiene_rango_edad and v_edad_jugador is not null then
        select tc.id, c.categoria_estandar_marca
          into v_categoria_correcta_id, v_categoria_estandar
          from tournament_categories tc
          join categories c on c.id = tc.category_id
         where tc.tournament_id = new.tournament_id
           and (c.edad_minima is not null or c.edad_maxima is not null)
           and v_edad_jugador >= coalesce(c.edad_minima, 0)
           and (c.edad_maxima is null or v_edad_jugador <= c.edad_maxima)
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

comment on function resolver_categoria_y_marca is 'Asigna marca_salida_id automáticamente. Valida/reasigna por hándicap (categorías con rango de hándicap) o por edad (categorías con rango de edad, ej. Senior). Categorías sin ningún rango se aceptan tal cual. Con equipo, solo resuelve la marca desde la categoría heredada.';
