-- =========================================================
-- MIGRACIÓN 099
-- Corrección de bug real: la reasignación automática por
-- hándicap/edad no filtraba por género — si el rango numérico de
-- una categoría de damas también cubría el hándicap de un
-- hombre, podía reasignarlo ahí por error (caso real: Juan Llosa,
-- hándicap 1.3, terminó con marca de damas).
--
-- Se agrega categories.genero (M/F/NULL="cualquiera") como dato
-- explícito, y se usa para filtrar las búsquedas de reasignación.
-- =========================================================

alter table categories
  add column genero text check (genero in ('M', 'F'));

comment on column categories.genero is 'Restricción de género de la categoría: M, F, o NULL (abierta a cualquiera, ej. ÚNICA/ABIERTA). Se usa para que la reasignación automática por hándicap/edad nunca cruce entre categorías de distinto género.';

update categories set genero = 'F' where codigo in ('DAMAS1', 'DAMAS2');
update categories set genero = 'M' where codigo in ('SCRATCH', 'PREMIER', 'AA', 'A', 'B', 'C', 'D', 'SENIOR1', 'SENIOR2');
-- ABIERTA y ÚNICA quedan en NULL (abiertas a cualquiera) a propósito.

create or replace function resolver_categoria_y_marca()
returns trigger as $$
declare
  v_handicap_jugador         numeric(4,1);
  v_edad_jugador              integer;
  v_sexo_jugador              text;
  v_edad_senior               integer;
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
    select coalesce(p.handicap_verificado, p.handicap_declarado), p.sexo
      into v_handicap_jugador, v_sexo_jugador
      from players p where p.id = new.player_id;

    select date_part('year', age(t.fecha_inicio, p.fecha_nacimiento))::integer
      into v_edad_jugador
      from players p, tournaments t
     where p.id = new.player_id and t.id = new.tournament_id;

    select exists (
      select 1 from tournament_franjas_handicap where tournament_id = new.tournament_id
    ) into v_hay_franjas;

    if v_hay_franjas then
      if v_sexo_jugador = 'F' then
        v_categoria_estandar := 'rojo';
      else
        select coalesce(
          (select t.edad_senior_categoria_unica from tournaments t where t.id = new.tournament_id),
          (select min(c.edad_minima)::integer from categories c where c.codigo like 'SENIOR%')
        ) into v_edad_senior;

        if v_edad_senior is not null and v_edad_jugador is not null and v_edad_jugador >= v_edad_senior then
          v_categoria_estandar := 'dorado';
        else
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
        end if;
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
           and (c.genero is null or c.genero = v_sexo_jugador)
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
           and (c.genero is null or c.genero = v_sexo_jugador)
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

comment on function resolver_categoria_y_marca is 'Asigna marca_salida_id automáticamente, respetando el género de la categoría en toda reasignación por hándicap o edad. Categoría única: mujeres siempre Rojas; caballeros senior siempre Doradas; caballeros no-senior por franja. Con equipo, hereda del equipo.';
