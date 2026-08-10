-- 127_resolver_categoria_desde_cero.sql
--
-- Bug real detectado con datos reales (equipo "SUSHIITTO", patrocinador, torneo de
-- categorías normales — no franjas): un equipo SIN categoría asignada en absoluto
-- (tournament_teams.tournament_category_id = null) deja también la inscripción sin
-- categoría (tournament_registrations.tournament_category_id = null). La lógica de
-- reasignación existente (099/100) solo sabe "corregir" una categoría YA elegida —
-- compara el hándicap contra la categoría de partida y la cambia si no corresponde.
-- Pero si no hay ninguna categoría de partida (null), esa lógica nunca se activa
-- (sus queries dependen de tc.id = tournament_category_id, que sin valor no matchea
-- nada) — el jugador queda sin categoría y sin marca de salida, aunque sí tenga
-- hándicap declarado.
--
-- Nota: la pantalla de Lovable mostraba "UNICA" junto a estos jugadores, pero es solo
-- una etiqueta visual — ni el equipo ni la inscripción tienen esa categoría (ni
-- ninguna otra) realmente guardada; se confirmó con consulta directa a la base.
--
-- Fix: cuando no hay categoría de partida (tournament_category_id es null desde el
-- inicio), se busca DIRECTO la categoría que corresponde por hándicap/sexo entre
-- todas las del torneo — mismo criterio que ya usa la reasignación existente, solo
-- que sin necesitar una categoría previa de la cual partir. Aplica tanto a equipos
-- sin categoría como a cualquier individual sin categoría (mismo criterio para ambos).

create or replace function resolver_categoria_y_marca()
returns trigger
language plpgsql
as $$
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
  v_elegida_cubre            boolean;
  v_nombre_categoria_elegida text;
begin
  select t.campo_golf_id into v_campo_id from tournaments t where t.id = new.tournament_id;

  if new.tournament_team_id is not null and new.tournament_category_id is not null then
    select c.categoria_estandar_marca into v_categoria_estandar
      from tournament_categories tc
      join categories c on c.id = tc.category_id
     where tc.id = new.tournament_category_id;
  end if;

  -- Cubre: sin equipo (individual), equipo con categoría UNICA (color no fijo), y
  -- equipo SIN categoría en absoluto (v_categoria_estandar nunca se llegó a poblar
  -- en el bloque anterior porque tournament_category_id ya venía en null).
  if new.tournament_team_id is null or v_categoria_estandar is null then

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

    -- NUEVO: sin categoría de partida (equipo sin categoría, o individual sin
    -- categoría elegida) — busca directo por hándicap/sexo, sin nada que "corregir".
    elsif new.tournament_category_id is null then
      if v_handicap_jugador is null then
        raise exception 'No se puede asignar categoría: el jugador no tiene hándicap capturado.';
      end if;

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

      if v_categoria_correcta_id is null then
        raise exception 'El hándicap del jugador (%) no corresponde a ninguna categoría configurada en este torneo. Avisa al organizador antes de continuar.', v_handicap_jugador;
      end if;

      new.tournament_category_id := v_categoria_correcta_id;
      new.categoria_reasignada := true;

    elsif new.tournament_team_id is null then
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

        elsif v_categoria_correcta_id is null then
          select
            v_handicap_jugador >= coalesce(tc.handicap_minimo, c.handicap_minimo)
            and (
              coalesce(tc.handicap_maximo, c.handicap_maximo) is null
              or v_handicap_jugador <= coalesce(tc.handicap_maximo, c.handicap_maximo)
            ),
            c.nombre
          into v_elegida_cubre, v_nombre_categoria_elegida
            from tournament_categories tc
            join categories c on c.id = tc.category_id
           where tc.id = new.tournament_category_id;

          if not v_elegida_cubre then
            raise exception 'El hándicap del jugador (%) no corresponde a la categoría "%" ni a ninguna otra categoría configurada en este torneo — probablemente falta activar una categoría intermedia. Avisa al organizador antes de continuar.',
              v_handicap_jugador, v_nombre_categoria_elegida;
          end if;
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

        elsif v_categoria_correcta_id is null then
          select
            v_edad_jugador >= coalesce(c.edad_minima, 0)
            and (c.edad_maxima is null or v_edad_jugador <= c.edad_maxima),
            c.nombre
          into v_elegida_cubre, v_nombre_categoria_elegida
            from tournament_categories tc
            join categories c on c.id = tc.category_id
           where tc.id = new.tournament_category_id;

          if not v_elegida_cubre then
            raise exception 'La edad del jugador (%) no corresponde a la categoría "%" ni a ninguna otra categoría configurada en este torneo. Avisa al organizador antes de continuar.',
              v_edad_jugador, v_nombre_categoria_elegida;
          end if;
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
$$;
