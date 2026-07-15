-- =========================================================
-- MIGRACIÓN 007
-- Recrea los 11 triggers que deberían existir desde las
-- migraciones 001-005, pero que no llegaron a crearse.
-- Las funciones ya existen (confirmado); esta migración solo
-- engancha los triggers a sus tablas. Es segura de correr aunque
-- alguno ya exista (usa DROP TRIGGER IF EXISTS antes de cada uno).
-- =========================================================

-- ---------------------------------------------------------
-- players
-- ---------------------------------------------------------

drop trigger if exists trg_players_updated_at on players;
create trigger trg_players_updated_at
before update on players
for each row execute function set_updated_at();

drop trigger if exists trg_players_validate_handicap on players;
create trigger trg_players_validate_handicap
before insert or update on players
for each row execute function validate_handicap_range();

-- ---------------------------------------------------------
-- admin_users
-- ---------------------------------------------------------

drop trigger if exists trg_admin_users_updated_at on admin_users;
create trigger trg_admin_users_updated_at
before update on admin_users
for each row execute function set_updated_at();

drop trigger if exists trg_track_estatus_admin_users on admin_users;
create trigger trg_track_estatus_admin_users
before update on admin_users
for each row execute function track_estatus_activo();

drop trigger if exists trg_audit_admin_users on admin_users;
create trigger trg_audit_admin_users
after insert or update or delete on admin_users
for each row execute function log_audit();

-- ---------------------------------------------------------
-- roles
-- ---------------------------------------------------------

drop trigger if exists trg_track_estatus_roles on roles;
create trigger trg_track_estatus_roles
before update on roles
for each row execute function track_estatus_activo();

drop trigger if exists trg_audit_roles on roles;
create trigger trg_audit_roles
after insert or update or delete on roles
for each row execute function log_audit();

-- ---------------------------------------------------------
-- admin_role_assignments
-- ---------------------------------------------------------

drop trigger if exists trg_validate_role_assignment_scope on admin_role_assignments;
create trigger trg_validate_role_assignment_scope
before insert or update on admin_role_assignments
for each row execute function validate_role_assignment_scope();

drop trigger if exists trg_validate_role_assignment_limits on admin_role_assignments;
create trigger trg_validate_role_assignment_limits
before insert or update on admin_role_assignments
for each row execute function validate_role_assignment_limits();

drop trigger if exists trg_track_estatus_role_assignments on admin_role_assignments;
create trigger trg_track_estatus_role_assignments
before update on admin_role_assignments
for each row execute function track_estatus_activo();

drop trigger if exists trg_audit_role_assignments on admin_role_assignments;
create trigger trg_audit_role_assignments
after insert or update or delete on admin_role_assignments
for each row execute function log_audit();

-- ---------------------------------------------------------
-- Verificación: debe devolver 11 filas.
-- Puedes correr esto después de la migración para confirmar.
-- ---------------------------------------------------------
-- select trigger_name, event_object_table, action_timing, event_manipulation
--   from information_schema.triggers
--  where trigger_schema = 'public'
--  order by event_object_table, trigger_name;
