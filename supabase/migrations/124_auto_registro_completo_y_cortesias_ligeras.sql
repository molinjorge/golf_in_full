-- 124_auto_registro_completo_y_cortesias_ligeras.sql
--
-- Rediseño acordado tras varias rondas de reflexión sobre el flujo de registro:
--
--   A) Auto-registro DIRECTO (correo nuevo → código → jugador completa su perfil):
--      ahora exige todos los datos, salvo GHIN, club y número de membresía (opcionales,
--      solo aplican a socios). Esto NO afecta el flujo de precarga administrativa
--      (organizador crea jugador con datos mínimos, se completa después) — ese sigue
--      funcionando exactamente igual que hoy, sin tocarlo, porque phone_reservations
--      ya depende de él y funciona bien.
--
--   B) patrocinador_jugadores_cortesia deja de crear una fila en `players` de entrada
--      (dejaba de seguir el mismo patrón ya probado con phone_reservations, 070). Ahora:
--        - Si el correo YA existe en players → se vincula directo a ese player_id.
--        - Si NO existe → se guarda solo nombre+correo como intención (player_id null),
--          y se reconcilia automáticamente cuando esa persona se auto-registre.
--
--   C) El trigger de reconciliación se amplía para cubrir tanto INSERT (auto-registro
--      nuevo, todo en un solo paso: vincula + inscribe si aplica) como UPDATE (un
--      jugador precargado que completa su perfil después).

-- A) Obligatoriedad de datos SOLO para auto-registro directo (auth_user_id ya viene
--    puesto desde el INSERT, señal de que es el propio jugador registrándose, no una
--    precarga administrativa que llega con auth_user_id en NULL).
create or replace function validar_registro_completo_jugador()
returns trigger
language plpgsql
as $$
begin
  if new.auth_user_id is not null then
    if new.nombres is null or new.apellidos is null or new.sexo is null
       or new.fecha_nacimiento is null
       or new.telefono_pais is null or new.telefono_lada is null or new.telefono_numero is null
       or new.handicap_declarado is null then
      raise exception 'Debes completar todos los datos obligatorios de tu perfil (nombres, apellidos, sexo, fecha de nacimiento, teléfono y hándicap declarado). Solo el número GHIN, club y número de membresía son opcionales.';
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_validar_registro_completo_jugador
  before insert on players
  for each row
  execute function validar_registro_completo_jugador();

-- B) patrocinador_jugadores_cortesia: player_id pasa a ser opcional, se agregan
--    nombres/apellidos/correo para guardar la intención cuando el jugador aún no existe.
alter table patrocinador_jugadores_cortesia
  alter column player_id drop not null,
  add column nombres text,
  add column apellidos text,
  add column correo text;

-- Función que reemplaza el flujo anterior (ya no se inserta directo en players desde
-- Lovable) — decide sola si vincula directo o guarda la intención.
create or replace function vincular_jugador_cortesia(
  p_patrocinador_id uuid,
  p_nombres text,
  p_apellidos text,
  p_correo text,
  p_tournament_team_id uuid default null,
  p_tournament_category_id uuid default null
)
returns uuid
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

  -- ¿Ya existe un jugador con ese correo? Si sí, se vincula directo, sin intención.
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

  -- Si ya existía y su perfil ya estaba completo, inscribe de inmediato.
  if v_player_id is not null then
    if exists (
      select 1 from players
       where id = v_player_id
         and fecha_nacimiento is not null and telefono_pais is not null
    ) then
      perform inscribir_cortesia_patrocinador(v_cortesia_id);
    end if;
  end if;

  return v_cortesia_id;
end;
$$;

-- C) Trigger de reconciliación ampliado — cubre INSERT (auto-registro nuevo) y UPDATE
--    (precargado que completa su perfil después). Vincula intenciones pendientes por
--    correo, y si el perfil ya está completo, inscribe.
create or replace function reconciliar_y_auto_inscribir_cortesia()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_perfil_completo boolean;
  v_cortesia        record;
begin
  -- Vincula cualquier intención pendiente (player_id null) que coincida con este correo.
  if new.email is not null then
    update patrocinador_jugadores_cortesia
       set player_id = new.id
     where correo = new.email
       and player_id is null
       and activo = true;
  end if;

  v_perfil_completo := new.fecha_nacimiento is not null and new.telefono_pais is not null;

  if v_perfil_completo then
    for v_cortesia in
      select id from patrocinador_jugadores_cortesia
       where player_id = new.id
         and tournament_registration_id is null
         and activo = true
    loop
      perform inscribir_cortesia_patrocinador(v_cortesia.id);
    end loop;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_auto_inscribir_cortesia_al_completar_perfil on players;
drop function if exists auto_inscribir_cortesia_al_completar_perfil();

create trigger trg_reconciliar_y_auto_inscribir_cortesia
  after insert or update on players
  for each row
  execute function reconciliar_y_auto_inscribir_cortesia();
