-- =========================================================
-- MIGRACIÓN 035
-- Agrega el patrón estándar de alta/baja a tournament_cut_rules,
-- que se quedó fuera por descuido en la migración 032.
-- =========================================================

alter table tournament_cut_rules
  add column activo             boolean     not null default true,
  add column fecha_baja         timestamptz,
  add column dado_de_baja_por   uuid        references admin_users (id) on delete restrict,
  add column motivo_baja        text,
  add column updated_at         timestamptz not null default now();

create trigger trg_tournament_cut_rules_updated_at
before update on tournament_cut_rules
for each row execute function set_updated_at();

create trigger trg_track_estatus_tournament_cut_rules
before update on tournament_cut_rules
for each row execute function track_estatus_activo();

create trigger trg_audit_tournament_cut_rules
after insert or update or delete on tournament_cut_rules
for each row execute function log_audit();

-- Actualizar la política de lectura para que respete activo,
-- igual que el resto de las tablas del proyecto (antes era
-- pública sin distinción, porque no existía la columna).
drop policy if exists tournament_cut_rules_select on tournament_cut_rules;

create policy tournament_cut_rules_select on tournament_cut_rules
  for select to public
  using (
    activo = true
    or is_superadmin(auth.uid())
    or exists (
      select 1 from tournament_rounds tr
      join tournaments t on t.id = tr.tournament_id
      where tr.id = despues_de_ronda_id
        and (is_tournament_organizer(auth.uid(), t.id) or is_club_admin(auth.uid(), t.club_id))
    )
  );
