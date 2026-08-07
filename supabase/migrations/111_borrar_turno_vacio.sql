-- 111_borrar_turno_vacio.sql
--
-- Nueva capacidad: permitir borrar físicamente un tournament_round_shift (turno), pero
-- SOLO si: (1) ya está desactivado (activo = false), y (2) no tiene ningún
-- tournament_groups asociado (es decir, está "vacío" — no hay nada que perder).
--
-- Si tiene grupos armados, se rechaza el borrado y debe quedarse desactivado — se
-- preserva el patrón de baja lógica (activo/fecha_baja) usado en todo el resto del
-- proyecto para no perder historial. El borrado físico es la excepción, solo para
-- turnos que nunca llegaron a usarse.
--
-- Caso real que motivó esto: el organizador desactivó un turno de prueba vacío y
-- quería liberar su número (numero_turno) para que el siguiente turno creado no
-- dejara un hueco en la numeración visible.

create or replace function validar_borrado_turno_vacio()
returns trigger
language plpgsql
as $$
declare
  v_tiene_grupos integer;
begin
  if old.activo = true then
    raise exception 'Debes desactivar el turno antes de poder eliminarlo.';
  end if;

  select count(*) into v_tiene_grupos
    from tournament_groups
   where tournament_round_shift_id = old.id;

  if v_tiene_grupos > 0 then
    raise exception 'No se puede eliminar: este turno ya tiene grupos armados. Debe permanecer desactivado para conservar el historial.';
  end if;

  return old;
end;
$$;

create trigger trg_validar_borrado_turno_vacio
  before delete on tournament_round_shifts
  for each row
  execute function validar_borrado_turno_vacio();
