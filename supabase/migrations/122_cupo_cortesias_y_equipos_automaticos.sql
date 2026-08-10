-- 122_cupo_cortesias_y_equipos_automaticos.sql
--
-- Rediseño tras revisión completa del flujo (no solo respuesta a la última pregunta):
--
--   1. "Jugadores cortesía" (van a JUGAR golf: perfil, categoría, hándicap, cupo,
--      equipo) y "Comida de premiación" (solo invitados a la cena, sin jugar, sin
--      perfil de jugador) son conceptualmente distintos, aunque ambos "hablen de
--      personas" — no deben tratarse igual ni compartir el mismo mecanismo.
--   2. Ambos dejan de vivir como entradas del catálogo genérico de derechos
--      (derechos_patrocinador/categoria_patrocinador_derechos) — quedaban informativos
--      y sin relación real con el resto del sistema, y duplicaban el dato una vez que
--      viven como campos dedicados aquí. Se desactivan esas entradas si existen, para
--      no dejar doble contabilidad.
--   3. cupo_jugadores_cortesia vive en `patrocinadores` (no en categoría) porque es
--      editable por patrocinador específico.
--   4. invitados_comida_premiacion es solo un CONTADOR (sin nombres, confirmado) —
--      nunca toca `players` ni `tournament_registrations`.
--   5. Equipos automáticos (solo si el torneo es de formato equipo): se crean tantos
--      equipos como hagan falta para cubrir cupo_jugadores_cortesia, según el tamaño
--      de equipo del torneo (jugadores_por_equipo, 018) — ej. cupo 6 con equipos de 4
--      → 2 equipos ("Patrocinador X", "Patrocinador X - 2"). El organizador acomoda
--      manualmente a cada jugador cortesía en el equipo que corresponda al inscribirlo
--      (confirmado: no hay reparto automático de jugadores entre los equipos creados).

-- 1. Campos nuevos en patrocinadores.
alter table patrocinadores
  add column cupo_jugadores_cortesia integer not null default 0,
  add column invitados_comida_premiacion integer not null default 0;

-- 1b. Relación real entre equipo y patrocinador — evita tener que comparar nombres
--     (que fallaría si dos patrocinadores tienen nombres parecidos, ej. "ABC" y "ABC Corp").
alter table tournament_teams
  add column patrocinador_id uuid references patrocinadores(id);

-- 2. Desactivar (no borrar, preserva historial) las entradas del catálogo genérico
--    que ahora duplicarían estos campos dedicados, si es que ya existían.
update derechos_patrocinador
   set activo = false
 where nombre in ('Jugadores cortesía', 'Comida de premiación');

-- 3. Función: crea automáticamente los equipos necesarios para el cupo de cortesías,
--    solo si el torneo es de formato equipo. Se llama al crear/actualizar un
--    patrocinador con cupo_jugadores_cortesia > 0.
create or replace function crear_equipos_cortesia_patrocinador()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tipo_participacion  formato_juego_torneo;
  v_jugadores_por_equipo integer;
  v_equipos_necesarios   integer;
  v_equipos_existentes   integer;
  i                      integer;
  v_nombre_equipo        text;
begin
  if new.cupo_jugadores_cortesia <= 0 then
    return new;
  end if;

  select tf.tipo_participacion, t.jugadores_por_equipo
    into v_tipo_participacion, v_jugadores_por_equipo
    from tournaments t
    join tournament_formats tf on tf.id = t.tournament_format_id
   where t.id = new.tournament_id;

  if v_tipo_participacion is distinct from 'equipo' then
    return new;
  end if;

  v_equipos_necesarios := ceil(new.cupo_jugadores_cortesia::numeric / v_jugadores_por_equipo);

  select count(*) into v_equipos_existentes
    from tournament_teams
   where patrocinador_id = new.id
     and activo = true;

  for i in (v_equipos_existentes + 1)..v_equipos_necesarios loop
    v_nombre_equipo := case when i = 1 then new.nombre else new.nombre || ' - ' || i end;

    insert into tournament_teams (tournament_id, nombre_equipo, patrocinador_id)
    values (new.tournament_id, v_nombre_equipo, new.id);
  end loop;

  return new;
end;
$$;

create trigger trg_crear_equipos_cortesia_patrocinador
  after insert or update of cupo_jugadores_cortesia on patrocinadores
  for each row
  execute function crear_equipos_cortesia_patrocinador();
