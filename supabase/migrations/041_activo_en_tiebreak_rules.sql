-- =========================================================
-- MIGRACIÓN 041
-- Agrega el patrón estándar de alta/baja a
-- tournament_tiebreak_rules, igual que se hizo con
-- tournament_cut_rules en la migración 035.
-- =========================================================

alter table tournament_tiebreak_rules
  add column activo             boolean     not null default true,
  add column fecha_baja         timestamptz,
  add column dado_de_baja_por   uuid        references admin_users (id) on delete restrict,
  add column motivo_baja        text,
  add column updated_at         timestamptz not null default now();

create trigger trg_tournament_tiebreak_rules_updated_at
before update on tournament_tiebreak_rules
for each row execute function set_updated_at();

create trigger trg_track_estatus_tournament_tiebreak_rules
before update on tournament_tiebreak_rules
for each row execute function track_estatus_activo();

create trigger trg_audit_tournament_tiebreak_rules
after insert or update or delete on tournament_tiebreak_rules
for each row execute function log_audit();

drop policy if exists tournament_tiebreak_rules_select on tournament_tiebreak_rules;

create policy tournament_tiebreak_rules_select on tournament_tiebreak_rules
  for select to public
  using (
    activo = true
    or is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

-- La restricción única original (tournament_id, alcance, orden)
-- ahora estorbaría: si se desactiva un paso en vez de borrarlo,
-- su "orden" seguiría ocupado para siempre. Se reemplaza por un
-- índice único parcial que solo cuenta las filas activas.
alter table tournament_tiebreak_rules drop constraint if exists tournament_tiebreak_rules_unico;

create unique index tournament_tiebreak_rules_unico_activo
  on tournament_tiebreak_rules (tournament_id, alcance, orden)
  where activo = true;
