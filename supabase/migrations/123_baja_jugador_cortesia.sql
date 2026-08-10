-- 123_baja_jugador_cortesia.sql
--
-- Hueco detectado: patrocinador_jugadores_cortesia (115) se creó sin el patrón de baja
-- lógica (activo/fecha_baja/etc.) que se usa consistentemente en el resto del proyecto
-- — se corrige aquí. Caso real que lo motivó: a veces el patrocinador da un nombre de
-- jugador que después no puede jugar, y hay que reemplazarlo por otra persona.
--
-- Dos escenarios distintos, confirmados con el usuario:
--   A) Error de captura (misma persona, nombre/correo mal escrito) — ya funciona hoy,
--      sin cambios necesarios: players_update (RLS) ya permite al organizador editar
--      un jugador que él mismo precargó, gracias al fix de visibilidad de la 114.
--   B) Reemplazo real (la persona cambió) — esto sí requería backend nuevo: dar de baja
--      el vínculo de cortesía, y si el jugador anterior YA se había inscrito
--      automáticamente (badge "Inscrito"), cancelar también esa inscripción para
--      liberar su lugar del cupo. Después, el organizador agrega al reemplazo con el
--      flujo normal de "Agregar jugador cortesía" (ya construido, sin cambios).

alter table patrocinador_jugadores_cortesia
  add column activo boolean not null default true,
  add column fecha_baja timestamptz,
  add column dado_de_baja_por uuid references admin_users(id),
  add column motivo_baja text;

create or replace function dar_de_baja_jugador_cortesia(p_cortesia_id uuid, p_motivo text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_cortesia        patrocinador_jugadores_cortesia;
  v_tournament_id   uuid;
  v_admin_id        uuid;
begin
  select * into v_cortesia from patrocinador_jugadores_cortesia where id = p_cortesia_id;

  if v_cortesia.id is null then
    raise exception 'Vínculo de cortesía no encontrado.';
  end if;

  if v_cortesia.activo = false then
    raise exception 'Este vínculo ya estaba dado de baja.';
  end if;

  select tournament_id into v_tournament_id
    from patrocinadores where id = v_cortesia.patrocinador_id;

  if not (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), v_tournament_id)
    or exists (select 1 from tournaments t where t.id = v_tournament_id and is_club_admin(auth.uid(), t.club_id))
  ) then
    raise exception 'No tienes permiso para dar de baja jugadores cortesía en este torneo.';
  end if;

  select id into v_admin_id from admin_users where auth_user_id = auth.uid();

  -- Si ya se había inscrito automáticamente, cancela también esa inscripción —
  -- libera su lugar del cupo total (104) y de categoría (103), automáticamente,
  -- porque esos triggers solo cuentan filas con activo = true.
  if v_cortesia.tournament_registration_id is not null then
    update tournament_registrations
       set activo = false,
           fecha_baja = now(),
           dado_de_baja_por = v_admin_id,
           motivo_baja = coalesce(p_motivo, 'Jugador cortesía dado de baja por el patrocinador/organizador')
     where id = v_cortesia.tournament_registration_id;
  end if;

  update patrocinador_jugadores_cortesia
     set activo = false,
         fecha_baja = now(),
         dado_de_baja_por = v_admin_id,
         motivo_baja = p_motivo
   where id = p_cortesia_id;
end;
$$;
