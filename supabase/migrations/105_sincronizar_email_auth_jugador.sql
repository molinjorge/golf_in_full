-- 105_sincronizar_email_auth_jugador.sql
--
-- Hasta hoy, players.email (correo de contacto, catálogo) y auth.users.email (credencial
-- real de login) podían desincronizarse sin ningún aviso: vincular_jugador_preregistrado()
-- (migración previa) solo vincula auth_user_id la primera vez que coinciden, pero una vez
-- vinculado, editar players.email no propaga nada hacia auth.users. Caso real detectado:
-- Noriega (player_id 02743883-...), cuyo correo de contacto se editó a molinjorge@gmail.com
-- pero su credencial de login se quedó con el correo sintético original — quedó imposible
-- iniciar sesión con el correo que aparece en su perfil.
--
-- Regla de negocio confirmada antes de escribir el código:
--   1. El catálogo (players.email) es la fuente de la verdad para el jugador.
--   2. Al cambiar players.email, se debe propagar automáticamente a auth.users.email,
--      para que el jugador pueda volver a autenticarse (pedir su código de acceso) con
--      el correo nuevo.
--   3. Si el correo nuevo ya existe como cuenta de otro jugador, NO debe proceder ningún
--      cambio (ni siquiera el de players.email) — se rechaza con un mensaje claro.
--
-- Nota de alcance: esta sincronización actualiza auth.users.email directamente por SQL,
-- sin pasar por el flujo oficial de "cambio de correo" de Supabase Auth (que normalmente
-- pide confirmación por correo al nuevo email antes de aplicar el cambio). Es la solución
-- adecuada para la etapa actual de pruebas, donde el superadmin es quien edita el catálogo
-- directamente. Antes de operar con jugadores reales, evaluar migrar a un flujo con
-- confirmación real (vía Edge Function + Admin API de Supabase) — queda anotado como
-- pendiente en el README, no se construye en esta migración.

create or replace function sincronizar_email_auth_jugador()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_conflicto_id uuid;
begin
  -- Solo actúa si el correo realmente cambió.
  if old.email is not distinct from new.email then
    return new;
  end if;

  -- Si el jugador aún no tiene cuenta de auth vinculada (precargado sin registrar),
  -- no hay nada que sincronizar todavía — vincular_jugador_preregistrado() se
  -- encargará cuando se registre.
  if new.auth_user_id is null then
    return new;
  end if;

  -- ¿El correo nuevo ya pertenece a la cuenta de auth de otro jugador?
  select id into v_conflicto_id
    from auth.users
   where email = new.email
     and id is distinct from new.auth_user_id;

  if v_conflicto_id is not null then
    raise exception 'El correo "%" ya está en uso y pertenece a otro jugador. No se realizó ningún cambio.', new.email;
  end if;

  update auth.users
     set email = new.email
   where id = new.auth_user_id;

  return new;
end;
$$;

create trigger trg_sincronizar_email_auth_jugador
  before update on players
  for each row
  execute function sincronizar_email_auth_jugador();
