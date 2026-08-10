-- 125_busqueda_cortesia_y_retorno_ampliado.sql
--
-- Dos ajustes al flujo de "Agregar jugador cortesía", detectados al probar el caso real:
--
--   1. El formulario pedía nombre/apellido aunque el correo ya existiera en el catálogo
--      — riesgo de guardar un nombre distinto al ya registrado. Nueva función de
--      búsqueda acotada (solo nombre, no expone el catálogo completo) para que el
--      frontend prellene esos campos de solo lectura si encuentra coincidencia.
--
--   2. vincular_jugador_cortesia() solo regresaba el id del vínculo — el frontend no
--      tenía forma de saber si vinculó directo (player_id existente) o si guardó una
--      intención pendiente (correo nuevo). Esto importa porque, si es una intención
--      nueva, Lovable debe disparar la misma invitación por correo que ya usa para
--      phone_reservations (confirmado: ese envío vive en el frontend, no en un trigger
--      de base de datos — no se dispara solo, hay que llamarlo explícitamente).

-- 1. Búsqueda acotada por correo — solo nombre, no expone nada más del catálogo.
create or replace function buscar_jugador_por_correo(p_correo text)
returns table(player_id uuid, nombres text, apellidos text)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not is_active_admin(auth.uid()) then
    raise exception 'No tienes permiso para buscar en el catálogo.';
  end if;

  return query
    select p.id, p.nombres, p.apellidos
      from players p
     where p.email = p_correo;
end;
$$;

-- 2. vincular_jugador_cortesia() ahora regresa también si vinculó directo o no.
drop function if exists vincular_jugador_cortesia(uuid, text, text, text, uuid, uuid);

create or replace function vincular_jugador_cortesia(
  p_patrocinador_id uuid,
  p_nombres text,
  p_apellidos text,
  p_correo text,
  p_tournament_team_id uuid default null,
  p_tournament_category_id uuid default null
)
returns table(cortesia_id uuid, player_id uuid, vinculado_directo boolean)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tournament_id  uuid;
  v_club_id        uuid;
  v_player_id      uuid;
  v_cortesia_id    uuid;
begin
  select tournament_id into v_tournament_id
    from patrocinadores where id = p_patrocinador_id;

  if v_tournament_id is null then
    raise exception 'Patrocinador no encontrado.';
  end if;

  select club_id into v_club_id from tournaments where id = v_tournament_id;

  if not (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), v_tournament_id)
    or is_club_admin(auth.uid(), v_club_id)
  ) then
    raise exception 'No tienes permiso para vincular jugadores cortesía en este torneo.';
  end if;

  select id into v_player_id from players where email = p_correo;

  insert into patrocinador_jugadores_cortesia (
    patrocinador_id, nombres, apellidos, correo, player_id,
    tournament_team_id, tournament_category_id, created_by
  ) values (
    p_patrocinador_id, p_nombres, p_apellidos, p_correo, v_player_id,
    p_tournament_team_id, p_tournament_category_id,
    (select id from admin_users where auth_user_id = auth.uid())
  )
  returning id into v_cortesia_id;

  if v_player_id is not null then
    if exists (
      select 1 from players
       where id = v_player_id
         and fecha_nacimiento is not null and telefono_pais is not null
    ) then
      perform inscribir_cortesia_patrocinador(v_cortesia_id);
    end if;
  end if;

  return query select v_cortesia_id, v_player_id, (v_player_id is not null);
end;
$$;
