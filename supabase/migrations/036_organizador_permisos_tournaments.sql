-- =========================================================
-- MIGRACIÓN 036
-- Corrige dos políticas de "tournaments" que se quedaron sin
-- incluir a tournament_organizer, a diferencia de todas las
-- tablas relacionadas (rondas, turnos, categorías, cortes) que
-- ya lo tenían bien desde su creación.
-- =========================================================

drop policy if exists tournaments_select on tournaments;

create policy tournaments_select on tournaments
  for select to public
  using (
    activo = true
    or is_superadmin(auth.uid())
    or is_club_admin(auth.uid(), club_id)
    or is_tournament_organizer(auth.uid(), id)
  );

drop policy if exists tournaments_update on tournaments;

create policy tournaments_update on tournaments
  for update to authenticated
  using (
    is_superadmin(auth.uid())
    or is_club_admin(auth.uid(), club_id)
    or is_tournament_organizer(auth.uid(), id)
  );
