-- 108_rls_grupos_y_salidas.sql
--
-- Faltante detectado por Lovable al construir la Fase 2 (pantalla "Armar grupos de
-- salida"): tournament_groups y tournament_group_players (migración 107) se crearon
-- sin políticas RLS, así que select/insert quedaban rechazados sin RLS habilitado o,
-- peor, completamente abiertos si RLS nunca se activó en la tabla.
--
-- Se replica el mismo criterio de acceso ya usado en tablas equivalentes:
--   - tournament_groups ~ mismo patrón que tournament_round_shifts (información de
--     horario/hoyo, poco sensible): visible públicamente si está activo, o para
--     superadmin; escritura solo para superadmin, organizador del torneo, o admin
--     del club dueño del torneo.
--   - tournament_group_players ~ mismo patrón que tournament_registrations (dato
--     más personal, quién juega con quién): el propio jugador puede ver sus propias
--     filas; superadmin/organizador/club_admin ven todo; escritura solo para roles
--     administrativos (el jugador no se auto-asigna a un grupo).

alter table tournament_groups enable row level security;
alter table tournament_group_players enable row level security;

-- tournament_groups: lectura pública si está activo (igual que los turnos).
create policy tournament_groups_select
  on tournament_groups
  for select
  using (activo = true or is_superadmin(auth.uid()));

-- tournament_groups: escritura (insert/update/delete) solo para roles administrativos
-- del torneo correspondiente, resuelto vía turno → ronda → torneo.
create policy tournament_groups_write
  on tournament_groups
  for all
  using (
    is_superadmin(auth.uid())
    or exists (
      select 1
        from tournament_round_shifts trs
        join tournament_rounds tr on tr.id = trs.tournament_round_id
        join tournaments t on t.id = tr.tournament_id
       where trs.id = tournament_groups.tournament_round_shift_id
         and (is_tournament_organizer(auth.uid(), t.id) or is_club_admin(auth.uid(), t.club_id))
    )
  )
  with check (
    is_superadmin(auth.uid())
    or exists (
      select 1
        from tournament_round_shifts trs
        join tournament_rounds tr on tr.id = trs.tournament_round_id
        join tournaments t on t.id = tr.tournament_id
       where trs.id = tournament_groups.tournament_round_shift_id
         and (is_tournament_organizer(auth.uid(), t.id) or is_club_admin(auth.uid(), t.club_id))
    )
  );

-- tournament_group_players: lectura — el propio jugador ve sus filas, o roles
-- administrativos ven todas, resuelto vía tournament_registrations → tournament_id.
create policy tournament_group_players_select
  on tournament_group_players
  for select
  using (
    is_superadmin(auth.uid())
    or exists (
      select 1
        from tournament_registrations reg
        join players p on p.id = reg.player_id
       where reg.id = tournament_group_players.tournament_registration_id
         and p.auth_user_id = auth.uid()
    )
    or exists (
      select 1
        from tournament_registrations reg
        join tournaments t on t.id = reg.tournament_id
       where reg.id = tournament_group_players.tournament_registration_id
         and (is_tournament_organizer(auth.uid(), t.id) or is_club_admin(auth.uid(), t.club_id))
    )
  );

-- tournament_group_players: escritura solo para roles administrativos — el jugador
-- no se auto-asigna a un grupo, lo arma el organizador.
create policy tournament_group_players_write
  on tournament_group_players
  for all
  using (
    is_superadmin(auth.uid())
    or exists (
      select 1
        from tournament_registrations reg
        join tournaments t on t.id = reg.tournament_id
       where reg.id = tournament_group_players.tournament_registration_id
         and (is_tournament_organizer(auth.uid(), t.id) or is_club_admin(auth.uid(), t.club_id))
    )
  )
  with check (
    is_superadmin(auth.uid())
    or exists (
      select 1
        from tournament_registrations reg
        join tournaments t on t.id = reg.tournament_id
       where reg.id = tournament_group_players.tournament_registration_id
         and (is_tournament_organizer(auth.uid(), t.id) or is_club_admin(auth.uid(), t.club_id))
    )
  );
