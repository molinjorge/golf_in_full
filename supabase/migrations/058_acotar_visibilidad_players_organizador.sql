-- =========================================================
-- MIGRACIÓN 058
-- El tournament_organizer ya podía pre-registrar jugadores
-- (INSERT, sin cambios) pero también podía VER a cualquier
-- jugador del sistema (is_active_admin no distingue rol). Se
-- acota: el organizador solo ve/edita jugadores que ya tengan
-- una inscripción o pre-reserva activa en alguno de SUS
-- torneos. superadmin y club_admin conservan visibilidad total.
-- =========================================================

create or replace function is_any_club_admin(p_auth_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from admin_role_assignments ara
    join roles r on r.id = ara.role_id
    join admin_users au on au.id = ara.admin_user_id
    where au.auth_user_id = p_auth_uid
      and au.activo = true
      and ara.activo = true
      and r.codigo = 'club_admin'
  );
$$;

comment on function is_any_club_admin is 'true si el usuario autenticado es club_admin de cualquier club (sin importar cuál).';

grant execute on function is_any_club_admin(uuid) to authenticated;

drop policy if exists players_select on players;

create policy players_select on players
  for select to authenticated
  using (
    auth_user_id = auth.uid()
    or is_superadmin(auth.uid())
    or is_any_club_admin(auth.uid())
    or exists (
      select 1 from tournament_registrations tr
       where tr.player_id = players.id
         and tr.activo = true
         and is_tournament_organizer(auth.uid(), tr.tournament_id)
    )
    or exists (
      select 1 from tournament_pre_reservations tp
       where tp.player_id = players.id
         and tp.activo = true
         and is_tournament_organizer(auth.uid(), tp.tournament_id)
    )
  );

drop policy if exists players_update on players;

create policy players_update on players
  for update to authenticated
  using (
    auth_user_id = auth.uid()
    or is_superadmin(auth.uid())
    or is_any_club_admin(auth.uid())
    or exists (
      select 1 from tournament_registrations tr
       where tr.player_id = players.id
         and tr.activo = true
         and is_tournament_organizer(auth.uid(), tr.tournament_id)
    )
    or exists (
      select 1 from tournament_pre_reservations tp
       where tp.player_id = players.id
         and tp.activo = true
         and is_tournament_organizer(auth.uid(), tp.tournament_id)
    )
  );

-- players_insert: SIN CAMBIOS a propósito — cualquier admin
-- activo (incluido tournament_organizer) sigue pudiendo
-- pre-registrar jugadores nuevos, sin restricción de "sus"
-- torneos (un jugador recién pre-registrado, por definición,
-- todavía no tiene ninguna inscripción).
