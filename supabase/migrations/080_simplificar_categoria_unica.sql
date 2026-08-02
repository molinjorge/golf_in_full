-- =========================================================
-- MIGRACIÓN 080
-- Simplifica validar_categoria_registro_equipo(): se elimina el
-- caso especial de "torneo sin categorías = categoría única".
-- En su lugar, un torneo de categoría única simplemente asigna
-- la categoría real "ÚNICA" (ya existe en el catálogo) como su
-- única categoría — el mecanismo normal de categorías, sin
-- ninguna rama especial que mantener.
-- =========================================================

create or replace function validar_categoria_registro_equipo()
returns trigger as $$
declare
  v_categoria_equipo      uuid;
  v_tournament_del_equipo uuid;
begin
  if new.tournament_team_id is not null then
    select tournament_category_id, tournament_id
      into v_categoria_equipo, v_tournament_del_equipo
      from tournament_teams where id = new.tournament_team_id;

    if v_tournament_del_equipo is distinct from new.tournament_id then
      raise exception 'El equipo seleccionado no pertenece a este torneo.';
    end if;

    new.tournament_category_id := v_categoria_equipo;
  else
    if new.tournament_category_id is null then
      raise exception 'Debes elegir una categoría cuando te inscribes sin equipo.';
    end if;

    if not exists (
      select 1 from tournament_categories
       where id = new.tournament_category_id
         and tournament_id = new.tournament_id
    ) then
      raise exception 'La categoría elegida no pertenece a este torneo.';
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

comment on function validar_categoria_registro_equipo is 'Si hay equipo, hereda su categoría (puede ser NULL si el equipo mismo no tiene categoría). Si no hay equipo, la categoría es siempre obligatoria y debe pertenecer al torneo — un torneo de "categoría única" simplemente asigna la categoría real ÚNICA del catálogo, sin ningún caso especial.';
