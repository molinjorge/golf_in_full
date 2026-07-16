-- =========================================================
-- MIGRACIÓN 012
-- Corrige recursión infinita de RLS: is_superadmin(),
-- is_club_admin(), is_tournament_organizer() e is_active_admin()
-- consultan admin_users/roles/admin_role_assignments, pero esas
-- mismas tablas tienen políticas de RLS que llaman a estas
-- funciones -> ciclo infinito cuando se ejecuta como un rol
-- sujeto a RLS (authenticated), que Postgres corta con
-- "stack depth limit exceeded" (se ve como 500 en la API).
--
-- Fix: SECURITY DEFINER hace que la función corra con los
-- privilegios de quien la creó, evitando que sus consultas
-- internas vuelvan a evaluar RLS y así rompiendo el ciclo.
-- search_path fijo es buena práctica de seguridad obligatoria
-- al usar SECURITY DEFINER (evita ataques de search_path).
-- =========================================================

create or replace function is_superadmin(p_auth_uid uuid)
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
      and r.codigo = 'superadmin'
  );
$$;

create or replace function is_club_admin(p_auth_uid uuid, p_club_id uuid)
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
      and ara.club_id = p_club_id
  );
$$;

create or replace function is_tournament_organizer(p_auth_uid uuid, p_tournament_id uuid)
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
      and r.codigo = 'tournament_organizer'
      and ara.tournament_id = p_tournament_id
  );
$$;

create or replace function is_active_admin(p_auth_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from admin_users
     where auth_user_id = p_auth_uid
       and activo = true
  );
$$;

-- Asegurar que authenticated pueda seguir ejecutándolas
-- (EXECUTE normalmente se otorga a PUBLIC por default al crear
-- una función, pero se deja explícito por si este proyecto
-- tampoco lo tenía, igual que pasó con los GRANT de tabla).
grant execute on function is_superadmin(uuid) to authenticated;
grant execute on function is_club_admin(uuid, uuid) to authenticated;
grant execute on function is_tournament_organizer(uuid, uuid) to authenticated;
grant execute on function is_active_admin(uuid) to authenticated;
