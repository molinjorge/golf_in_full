-- 112_borrar_grupo_vacio.sql
--
-- Simétrico a la migración 111 (borrar turno vacío): permite borrar físicamente un
-- tournament_groups, pero SOLO si: (1) ya está desactivado (activo = false), y
-- (2) no tiene ningún jugador asignado en tournament_group_players.
--
-- Completa el flujo de limpieza de abajo hacia arriba que propuso el organizador:
-- vaciar el grupo (quitar jugadores) → desactivar el grupo → borrar el grupo (si quedó
-- vacío) → desactivar el turno (ya sin grupos activos) → borrar el turno (111, ya
-- exigía "sin ningún tournament_groups" — con este fix, borrar los grupos vacíos deja
-- el turno realmente vacío y sí puede borrarse, liberando su número para reutilizar).

create or replace function validar_borrado_grupo_vacio()
returns trigger
language plpgsql
as $$
declare
  v_tiene_jugadores integer;
begin
  if old.activo = true then
    raise exception 'Debes desactivar el grupo antes de poder eliminarlo.';
  end if;

  select count(*) into v_tiene_jugadores
    from tournament_group_players
   where tournament_group_id = old.id;

  if v_tiene_jugadores > 0 then
    raise exception 'No se puede eliminar: este grupo todavía tiene jugadores asignados. Quítalos primero.';
  end if;

  return old;
end;
$$;

create trigger trg_validar_borrado_grupo_vacio
  before delete on tournament_groups
  for each row
  execute function validar_borrado_grupo_vacio();
