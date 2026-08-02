-- =========================================================
-- MIGRACIÓN 084
-- validar_categoria_pertenece_al_torneo() nunca contempló que
-- tournament_category_id pudiera venir NULL — ahora que sí puede
-- (phone_reservations y tournament_pre_reservations, desde la
-- 083), rechazaba por error cualquier reserva sin categoría,
-- incluyendo el caso legítimo de "sin equipo".
-- =========================================================

create or replace function validar_categoria_pertenece_al_torneo()
returns trigger as $$
declare
  v_tournament_de_categoria uuid;
begin
  if new.tournament_category_id is null then
    return new;
  end if;

  select tournament_id into v_tournament_de_categoria
    from tournament_categories where id = new.tournament_category_id;

  if v_tournament_de_categoria is distinct from new.tournament_id then
    raise exception 'La categoría elegida no pertenece a este torneo.';
  end if;

  return new;
end;
$$ language plpgsql;

comment on function validar_categoria_pertenece_al_torneo is 'Valida que la categoría enviada pertenezca al torneo. Si tournament_category_id es NULL, no valida nada (caso legítimo: sin equipo, sin categoría, o equipo sin categoría asignada).';
