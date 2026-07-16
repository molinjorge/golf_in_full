-- =========================================================
-- MIGRACIÓN 011
-- Otorga los GRANTs de tabla faltantes. RLS no reemplaza al
-- sistema de privilegios de Postgres: para que una política
-- de RLS llegue a evaluarse, el rol (anon/authenticated) debe
-- tener primero el GRANT correspondiente sobre la tabla. Sin
-- el GRANT, Postgres rechaza el acceso antes de llegar a RLS.
--
-- Esta migración NO cambia ninguna política ni ninguna regla
-- de negocio — solo restablece el acceso de base que debía
-- existir desde que se crearon las tablas, para que las
-- políticas que ya diseñamos puedan hacer su trabajo.
-- =========================================================

-- players: select propio/admin, insert propio/admin, update propio/admin (sin delete)
grant select, insert, update on players to authenticated;

-- admin_users: select propio/superadmin, insert solo superadmin, update solo superadmin (sin delete)
grant select, insert, update on admin_users to authenticated;

-- roles: select abierto a authenticated, resto solo superadmin (roles_write es "for all")
grant select, insert, update, delete on roles to authenticated;

-- admin_role_assignments: select propio/superadmin/responsable_ambito,
-- escritura superadmin/responsable_ambito (role_assignments_write es "for all")
grant select, insert, update, delete on admin_role_assignments to authenticated;

-- system_parameters: select abierto a authenticated, escritura solo superadmin (write es "for all")
grant select, insert, update, delete on system_parameters to authenticated;

-- audit_log: solo lectura (superadmin, vía política). Las escrituras
-- ocurren exclusivamente por el trigger log_audit(), que es
-- SECURITY DEFINER y no depende de este GRANT. No se concede
-- insert/update/delete a authenticated a propósito.
grant select on audit_log to authenticated;

-- clubs: faltaba insert/update para authenticated (el select ya
-- se resolvió en la migración 009, con su restricción de columnas
-- para anon, que aquí NO se toca).
grant insert, update on clubs to authenticated;

-- tournaments: nunca se otorgó el GRANT de select a anon, así que
-- el directorio público de torneos probablemente tampoco funcionaba.
grant select on tournaments to anon;
grant select, insert, update on tournaments to authenticated;

-- ---------------------------------------------------------
-- Verificación sugerida después de correr esto:
-- select grantee, table_name, privilege_type
--   from information_schema.role_table_grants
--  where table_schema = 'public'
--  order by table_name, grantee, privilege_type;
-- ---------------------------------------------------------
