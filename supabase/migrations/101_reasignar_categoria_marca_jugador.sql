-- =========================================================
-- MIGRACIÓN 101
-- Dos funciones para que el organizador ajuste manualmente una
-- inscripción ya existente:
-- 1) reasignar_categoria_jugador() — cambia la categoría; la
--    marca de salida se recalcula sola, según la nueva categoría.
-- 2) reasignar_marca_salida_jugador() — cambia SOLO la marca,
--    sin tocar la categoría (para casos especiales).
-- =========================================================

create or replace function reasignar_categoria_jugador(
  p_tournament_registration_id uuid,
  p_nueva_categoria_id         uuid
)
returns tournament_registrations
security definer
set search_path = public
as $$
declare
  v_registro   tournament_registrations;
  v_autorizado boolean;
  v_campo_id   uuid;
  v_categoria_estandar categoria_marca_salida;
  v_resultado  tournament_registrations;
begin
  select * into v_registro from tournament_registrations where id = p_tournament_registration_id;

  if v_registro.id is null then
    raise exception 'No existe esa inscripción.';
  end if;

  v_autorizado := is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), v_registro.tournament_id)
    or exists (select 1 from tournaments t where t.id = v_registro.tournament_id and is_club_admin(auth.uid(), t.club_id));

  if not v_autorizado then
    raise exception 'No tienes permiso para reasignar categoría en este torneo.';
  end if;

  if not exists (
    select 1 from tournament_categories
     where id = p_nueva_categoria_id and tournament_id = v_registro.tournament_id
  ) then
    raise exception 'Esa categoría no pertenece a este torneo.';
  end if;

  select t.campo_golf_id into v_campo_id from tournaments t where t.id = v_registro.tournament_id;

  select c.categoria_estandar_marca into v_categoria_estandar
    from tournament_categories tc
    join categories c on c.id = tc.category_id
   where tc.id = p_nueva_categoria_id;

  update tournament_registrations
     set tournament_category_id = p_nueva_categoria_id,
         categoria_reasignada   = false,
         marca_salida_id = (
           select id from marcas_salida
            where campo_golf_id = v_campo_id
              and categoria_estandar = v_categoria_estandar
              and activo = true
            limit 1
         )
   where id = p_tournament_registration_id
  returning * into v_resultado;

  return v_resultado;
end;
$$ language plpgsql;

comment on function reasignar_categoria_jugador is 'Permite al organizador/superadmin/club_admin cambiar manualmente la categoría de un jugador ya inscrito — recalcula automáticamente la marca de salida según la nueva categoría.';

grant execute on function reasignar_categoria_jugador(uuid, uuid) to authenticated;

create or replace function reasignar_marca_salida_jugador(
  p_tournament_registration_id uuid,
  p_nueva_marca_salida_id      uuid
)
returns tournament_registrations
security definer
set search_path = public
as $$
declare
  v_registro        tournament_registrations;
  v_autorizado      boolean;
  v_campo_id_marca  uuid;
  v_campo_id_torneo uuid;
  v_resultado       tournament_registrations;
begin
  select * into v_registro from tournament_registrations where id = p_tournament_registration_id;

  if v_registro.id is null then
    raise exception 'No existe esa inscripción.';
  end if;

  v_autorizado := is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), v_registro.tournament_id)
    or exists (select 1 from tournaments t where t.id = v_registro.tournament_id and is_club_admin(auth.uid(), t.club_id));

  if not v_autorizado then
    raise exception 'No tienes permiso para reasignar marca de salida en este torneo.';
  end if;

  select campo_golf_id into v_campo_id_marca from marcas_salida where id = p_nueva_marca_salida_id;
  select campo_golf_id into v_campo_id_torneo from tournaments where id = v_registro.tournament_id;

  if v_campo_id_marca is distinct from v_campo_id_torneo then
    raise exception 'Esa marca de salida no pertenece al campo de este torneo.';
  end if;

  update tournament_registrations
     set marca_salida_id = p_nueva_marca_salida_id
   where id = p_tournament_registration_id
  returning * into v_resultado;

  return v_resultado;
end;
$$ language plpgsql;

comment on function reasignar_marca_salida_jugador is 'Permite al organizador/superadmin/club_admin cambiar manualmente SOLO la marca de salida de un jugador ya inscrito, sin tocar su categoría — para casos especiales fuera de la regla automática.';

grant execute on function reasignar_marca_salida_jugador(uuid, uuid) to authenticated;
