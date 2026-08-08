-- 114_fix_visibilidad_jugadores_precargados.sql
--
-- Bug real detectado (candado circular): jugador_visible_para_organizador() solo hacía
-- visible a un jugador si YA tenía una inscripción o pre-reserva activa con ese
-- organizador — pero un jugador recién precargado (ej. cortesía de patrocinador, o
-- cualquier precarga manual como el caso de Noriega en pruebas) todavía no tiene
-- ninguna de las dos. El organizador que ACABA de crearlo no podía verlo en la pantalla
-- de catálogo hasta que alguien lo inscribiera primero — bloqueando el flujo básico.
--
-- Fix: se agrega players.created_by (quién precargó al jugador, resuelto a admin_users.id
-- automáticamente vía trigger, mismo patrón que ya usa confirmar_pago_prereserva() para
-- otros created_by del sistema) y se amplía jugador_visible_para_organizador() para
-- incluir "visible si el organizador fue quien lo creó".

-- 1. Nueva columna, resuelta automáticamente — el cliente nunca la manda directo,
--    evita suplantación.
alter table players
  add column created_by uuid references admin_users(id);

create or replace function set_created_by_players()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  new.created_by := (select id from admin_users where auth_user_id = auth.uid());
  return new;
end;
$$;

create trigger trg_set_created_by_players
  before insert on players
  for each row
  execute function set_created_by_players();

-- 2. Amplía la visibilidad: también visible si el organizador fue quien lo precargó.
create or replace function jugador_visible_para_organizador(p_player_id uuid, p_auth_uid uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1 from tournament_registrations tr
     where tr.player_id = p_player_id
       and tr.activo = true
       and is_tournament_organizer(p_auth_uid, tr.tournament_id)
  )
  or exists (
    select 1 from tournament_pre_reservations tp
     where tp.player_id = p_player_id
       and tp.activo = true
       and is_tournament_organizer(p_auth_uid, tp.tournament_id)
  )
  or exists (
    select 1 from players p
    join admin_users au on au.id = p.created_by
     where p.id = p_player_id
       and au.auth_user_id = p_auth_uid
  );
$function$;
