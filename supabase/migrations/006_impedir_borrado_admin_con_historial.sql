-- =========================================================
-- MIGRACIÓN 006
-- Garantizar que un admin_user con historial NUNCA pueda
-- borrarse físicamente — solo desactivarse. El borrado solo
-- debe ser posible para una alta hecha por error, sin rastro.
-- =========================================================

-- admin_role_assignments.admin_user_id estaba en CASCADE:
-- si se borrara el admin, se hubiera borrado su propio
-- historial de asignaciones. Lo pasamos a RESTRICT.

alter table admin_role_assignments
  drop constraint admin_role_assignments_admin_user_id_fkey;

alter table admin_role_assignments
  add constraint admin_role_assignments_admin_user_id_fkey
  foreign key (admin_user_id) references admin_users (id) on delete restrict;

-- players.handicap_verificado_por estaba en SET NULL:
-- si se borrara el admin que verificó un hándicap, se perdería
-- silenciosamente el dato de quién lo validó. Lo pasamos a RESTRICT.

alter table players
  drop constraint players_handicap_verificado_por_fk;

alter table players
  add constraint players_handicap_verificado_por_fk
  foreign key (handicap_verificado_por) references admin_users (id) on delete restrict;

-- admin_role_assignments.created_by ya bloqueaba el borrado por
-- default (NO ACTION); se deja explícito por claridad documental.

alter table admin_role_assignments
  drop constraint admin_role_assignments_created_by_fkey;

alter table admin_role_assignments
  add constraint admin_role_assignments_created_by_fkey
  foreign key (created_by) references admin_users (id) on delete restrict;

-- Con esto, intentar "DELETE FROM admin_users WHERE id = ..." falla
-- con un error de FK en cuanto ese administrador tenga cualquier
-- asignación (propia o creada por él) o haya verificado algún
-- hándicap. La única baja posible, en la práctica, es UPDATE activo = false.
