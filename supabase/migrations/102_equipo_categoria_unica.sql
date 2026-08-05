-- 102_equipo_categoria_unica.sql
--
-- Corrección de bug real: en torneos de categoría única, un jugador inscrito CON EQUIPO
-- se quedaba sin marca_salida_id (sin error visible) porque la función solo intentaba
-- heredar categoria_estandar_marca de la categoría del equipo — y la categoría "UNICA"
-- nunca tiene ese campo poblado (el color se resuelve dinámicamente por sexo/edad/hándicap
-- del jugador, no por catálogo estático).
--
-- Caso real detectado: Juan Llosa (inscripción 3611e518-5fe5-4a12-9d3f-abbc219242e9),
-- hombre senior (1956), equipo con tournament_category_id apuntando a la categoría "UNICA".
--
-- Alcance del fix (confirmado antes de escribir el código):
--   1. Si la categoría resuelta del equipo es "UNICA" (categoria_estandar_marca is null),
--      el trigger cae al mismo bloque de sexo/edad/franjas que ya usa la rama individual.
--   2. Por ahora esto aplica SOLO a la categoría "UNICA" (por código, no por NULL genérico) —
--      si en el futuro aparece otra categoría de catálogo sin color fijo, se revisará aparte.
--   3. Equipo con categoría normal (con categoria_estandar_marca poblado, ej. hándicap
--      combinado) sigue heredando del equipo exactamente como hoy — sin cambios.
--   4. La reasignación automática de categoría (bloque de tournament_categories) se queda
--      exclusiva para inscripciones individuales — nunca toca tournament_category_id de un equipo.

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
  v_categoria_equipo_codigo  text;
  v_elegida_tiene_rango_hi   boolean;
  v_elegida_tiene_rango_edad boolean;
  v_elegida_cubre            boolean;
  v_nombre_categoria_elegida text;
begin
  select t.campo_golf_id into v_campo_id from tournaments t where t.id = new.tournament_id;

  -- Si hay equipo y trae categoría, se intenta resolver el color desde ahí (como siempre).
  -- Para categorías normales (con color fijo) esto ya deja todo listo y no se toca nada más.
  if new.tournament_team_id is not null and new.tournament_category_id is not null then
    select c.categoria_estandar_marca, c.codigo
      into v_categoria_estandar, v_categoria_equipo_codigo
      from tournament_categories tc
      join categories c on c.id = tc.category_id
     where tc.id = new.tournament_category_id;
  end if;

  -- Se resuelve por jugador individual cuando:
  --   a) no hay equipo (comportamiento original, sin cambios), o
  --   b) hay equipo pero su categoría es "UNICA" (sin color fijo propio) — caso nuevo.
  if new.tournament_team_id is null or v_categoria_equipo_codigo = 'UNICA' then

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

    elsif new.tournament_team_id is null then
      -- Reasignación automática de categoría — SOLO para inscripciones individuales.
      -- Un equipo con categoría "UNICA" no tiene tournament_category_id de jugador
      -- que reasignar aquí; su color ya se resolvió arriba por sexo/edad/franjas.
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
