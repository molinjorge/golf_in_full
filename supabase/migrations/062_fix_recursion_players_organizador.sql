-- =========================================================
-- MIGRACIÓN 062
-- Corrige recursión infinita de RLS introducida en la 058:
-- players_select consulta tournament_registrations, y la
-- política de tournament_registrations consulta players — cada
-- una dispara a la otra sin parar (mismo patrón que la
-- migración 012 con is_superadmin). Se resuelve con una función
-- SECURITY DEFINER que hace la consulta cruzada sin re-evaluar
-- RLS por dentro.
-- =========================================================

create or replace function jugador_visible_para_organizador(p_player_id uuid, p_auth_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
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
  );
$$;

comment on function jugador_visible_para_organizador is 'true si el jugador tiene una inscripción o pre-reserva activa en algún torneo del organizador dado. SECURITY DEFINER para evitar recursión de RLS entre players y tournament_registrations/tournament_pre_reservations.';

grant execute on function jugador_visible_para_organizador(uuid, uuid) to authenticated;

drop policy if exists players_select on players;

create policy players_select on players
  for select to authenticated
  using (
    auth_user_id = auth.uid()
    or is_superadmin(auth.uid())
    or is_any_club_admin(auth.uid())
    or jugador_visible_para_organizador(id, auth.uid())
  );

drop policy if exists players_update on players;

create policy players_update on players
  for update to authenticated
  using (
    auth_user_id = auth.uid()
    or is_superadmin(auth.uid())
    or is_any_club_admin(auth.uid())
    or jugador_visible_para_organizador(id, auth.uid())
  );
