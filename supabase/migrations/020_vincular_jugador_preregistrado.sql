-- =========================================================
-- MIGRACIÓN 020
-- Cuando alguien confirma su correo en auth.users, si ya existe
-- un perfil en "players" pre-registrado con ese mismo correo
-- (creado por un organizador, sin cuenta vinculada todavía),
-- se conecta automáticamente en vez de dejarlo huérfano.
--
-- La vinculación solo ocurre tras CONFIRMAR el correo, nunca al
-- solo declararlo — evita que alguien reclame el perfil de otra
-- persona usando un correo que no le pertenece realmente.
--
-- Si no existe ningún perfil pre-registrado con ese correo, esta
-- función no hace nada — la creación del perfil nuevo es
-- responsabilidad del flujo de autoregistro (Fase 3, aparte).
-- =========================================================

create or replace function vincular_jugador_preregistrado()
returns trigger as $$
declare
  v_player_id uuid;
begin
  select id into v_player_id
    from players
   where email = new.email
     and auth_user_id is null;

  if v_player_id is not null then
    update players
       set auth_user_id = new.id
     where id = v_player_id;
  end if;

  return new;
end;
$$ language plpgsql security definer set search_path = public;

comment on function vincular_jugador_preregistrado is 'Vincula un perfil de players pre-registrado (auth_user_id nulo) con la cuenta real del jugador, cuando confirma su correo. No crea perfiles nuevos.';

-- Caso 1: la cuenta se crea YA confirmada (ej. alta administrativa
-- directa, como hicimos con el superadmin/administradores).
create trigger trg_vincular_jugador_en_alta
after insert on auth.users
for each row
when (new.email_confirmed_at is not null)
execute function vincular_jugador_preregistrado();

-- Caso 2: la cuenta se crea sin confirmar y el correo se confirma
-- después (flujo normal de autoregistro con verificación por correo).
create trigger trg_vincular_jugador_en_confirmacion
after update of email_confirmed_at on auth.users
for each row
when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
execute function vincular_jugador_preregistrado();
