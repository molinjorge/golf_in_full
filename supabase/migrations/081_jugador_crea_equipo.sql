-- =========================================================
-- MIGRACIÓN 081
-- Permite que cualquier jugador autenticado cree un equipo
-- nuevo (antes solo lo podían crear superadmin/organizador/
-- club_admin) — necesario para que, si su equipo no aparece en
-- la lista de equipos incompletos, pueda darlo de alta él mismo.
-- =========================================================

drop policy if exists tournament_teams_insert on tournament_teams;

create policy tournament_teams_insert on tournament_teams
  for insert to authenticated
  with check (true);

comment on policy tournament_teams_insert on tournament_teams is 'Cualquier usuario autenticado puede crear un equipo — incluye jugadores dando de alta su propio equipo, además de administradores. Crear un equipo vacío no otorga ningún acceso adicional por sí solo.';
