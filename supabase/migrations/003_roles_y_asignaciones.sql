-- =========================================================
-- MIGRACIÓN 003
-- Rediseño de permisos: catálogo de roles + asignaciones
-- por alcance (global / club / torneo)
-- =========================================================

-- ---------------------------------------------------------
-- 0) Quitar las políticas RLS que dependen de admin_users.rol
--    (hay que quitarlas antes de poder borrar la columna)
-- ---------------------------------------------------------

drop policy if exists system_parameters_write on system_parameters;
drop policy if exists admin_users_select_self on admin_users;
drop policy if exists admin_users_manage_superadmin on admin_users;
drop policy if exists admin_users_update_superadmin on admin_users;

-- ---------------------------------------------------------
-- 1) Quitar el rol fijo de admin_users
-- ---------------------------------------------------------

alter table admin_users drop column rol;
drop type admin_rol;

comment on table admin_users is 'Administradores/organizadores de la plataforma. Sus roles y alcance viven en admin_role_assignments, no en esta tabla.';

-- ---------------------------------------------------------
-- 2) CATÁLOGO DE ROLES
-- ---------------------------------------------------------
-- "ambito" define en qué nivel aplica el rol. Roles nuevos
-- (por club o por torneo) se agregan aquí como filas, sin
-- tocar el esquema.

create type role_ambito as enum ('global', 'club', 'tournament');

create table roles (
  id            uuid        primary key default gen_random_uuid(),
  codigo        text        not null unique,   -- identificador estable, ej. 'superadmin'
  nombre        text        not null,          -- nombre visible en el dashboard
  descripcion   text,
  ambito        role_ambito not null,
  activo        boolean     not null default true,
  created_at    timestamptz not null default now()
);

comment on table roles is 'Catálogo de roles disponibles en la plataforma. Nuevos roles (por club o por torneo) se agregan aquí sin migrar esquema.';
comment on column roles.ambito is 'Nivel en el que aplica el rol: global (toda la plataforma), club (un club específico) o tournament (un torneo específico).';

insert into roles (codigo, nombre, descripcion, ambito) values
  ('superadmin', 'Superadministrador', 'Acceso total a la plataforma.', 'global'),
  ('club_admin', 'Administrador de Club', 'Administra un club específico y sus torneos. No ve otros clubes.', 'club'),
  ('tournament_organizer', 'Administrador de Torneo', 'Administra únicamente los torneos donde fue asignado. No ve otros torneos.', 'tournament');

-- ---------------------------------------------------------
-- 3) ASIGNACIONES DE ROL (quién tiene qué rol, y dónde)
-- ---------------------------------------------------------
-- club_id / tournament_id se dejan como uuid sin FK todavía:
-- se agregará "references clubs(id)" / "references tournaments(id)"
-- cuando esas tablas existan.

create table admin_role_assignments (
  id               uuid        primary key default gen_random_uuid(),
  admin_user_id    uuid        not null references admin_users (id) on delete cascade,
  role_id          uuid        not null references roles (id) on delete restrict,

  club_id          uuid,        -- obligatorio solo si roles.ambito = 'club'
  tournament_id    uuid,        -- obligatorio solo si roles.ambito = 'tournament'

  created_by       uuid references admin_users (id),  -- quién otorgó el rol (auditoría)
  created_at       timestamptz not null default now()
);

comment on table admin_role_assignments is 'Asigna un rol del catálogo a un administrador, con el alcance (club o torneo) correspondiente. Un administrador puede tener varias asignaciones.';

-- Trigger: obliga a que club_id/tournament_id coincidan con el
-- ambito del rol asignado (evita, por ejemplo, un club_admin sin club).

create or replace function validate_role_assignment_scope()
returns trigger as $$
declare
  v_ambito role_ambito;
begin
  select ambito into v_ambito from roles where id = new.role_id;

  if v_ambito = 'global' and (new.club_id is not null or new.tournament_id is not null) then
    raise exception 'Un rol de ámbito global no debe llevar club_id ni tournament_id.';
  elsif v_ambito = 'club' and (new.club_id is null or new.tournament_id is not null) then
    raise exception 'Un rol de ámbito club requiere club_id y no debe llevar tournament_id.';
  elsif v_ambito = 'tournament' and (new.tournament_id is null or new.club_id is not null) then
    raise exception 'Un rol de ámbito tournament requiere tournament_id y no debe llevar club_id.';
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validate_role_assignment_scope
before insert or update on admin_role_assignments
for each row execute function validate_role_assignment_scope();

-- Evita asignar el mismo rol dos veces al mismo administrador
-- en el mismo alcance (global / mismo club / mismo torneo).
create unique index uq_role_assignment_global
  on admin_role_assignments (admin_user_id, role_id)
  where club_id is null and tournament_id is null;

create unique index uq_role_assignment_club
  on admin_role_assignments (admin_user_id, role_id, club_id)
  where club_id is not null;

create unique index uq_role_assignment_tournament
  on admin_role_assignments (admin_user_id, role_id, tournament_id)
  where tournament_id is not null;

create index idx_role_assignments_admin on admin_role_assignments (admin_user_id);
create index idx_role_assignments_club on admin_role_assignments (club_id);
create index idx_role_assignments_tournament on admin_role_assignments (tournament_id);

-- ---------------------------------------------------------
-- 4) FUNCIONES AUXILIARES PARA RLS
-- ---------------------------------------------------------
-- Se reutilizarán en las políticas de clubs, tournaments,
-- tournament_registrations, etc. cuando se construyan.

create or replace function is_superadmin(p_auth_uid uuid)
returns boolean language sql stable as $$
  select exists (
    select 1
    from admin_role_assignments ara
    join roles r on r.id = ara.role_id
    join admin_users au on au.id = ara.admin_user_id
    where au.auth_user_id = p_auth_uid
      and au.activo = true
      and r.codigo = 'superadmin'
  );
$$;

create or replace function is_club_admin(p_auth_uid uuid, p_club_id uuid)
returns boolean language sql stable as $$
  select exists (
    select 1
    from admin_role_assignments ara
    join roles r on r.id = ara.role_id
    join admin_users au on au.id = ara.admin_user_id
    where au.auth_user_id = p_auth_uid
      and au.activo = true
      and r.codigo = 'club_admin'
      and ara.club_id = p_club_id
  );
$$;

create or replace function is_tournament_organizer(p_auth_uid uuid, p_tournament_id uuid)
returns boolean language sql stable as $$
  select exists (
    select 1
    from admin_role_assignments ara
    join roles r on r.id = ara.role_id
    join admin_users au on au.id = ara.admin_user_id
    where au.auth_user_id = p_auth_uid
      and au.activo = true
      and r.codigo = 'tournament_organizer'
      and ara.tournament_id = p_tournament_id
  );
$$;

comment on function is_superadmin is 'true si el usuario autenticado tiene rol superadmin (alcance global).';
comment on function is_club_admin is 'true si el usuario autenticado es club_admin del club indicado (y solo de ese club).';
comment on function is_tournament_organizer is 'true si el usuario autenticado es organizador del torneo indicado (y solo de ese torneo).';

-- ---------------------------------------------------------
-- 5) RE-CREAR RLS con el nuevo modelo de roles
-- ---------------------------------------------------------

alter table roles enable row level security;
alter table admin_role_assignments enable row level security;

-- roles: lectura abierta a autenticados, escritura solo superadmin
create policy roles_select on roles
  for select to authenticated using (true);

create policy roles_write on roles
  for all to authenticated
  using (is_superadmin(auth.uid()))
  with check (is_superadmin(auth.uid()));

-- admin_role_assignments: un admin ve sus propias asignaciones;
-- el superadmin ve y gestiona todas.
create policy role_assignments_select on admin_role_assignments
  for select to authenticated
  using (
    is_superadmin(auth.uid())
    or admin_user_id = (select id from admin_users where auth_user_id = auth.uid())
  );

create policy role_assignments_write on admin_role_assignments
  for all to authenticated
  using (is_superadmin(auth.uid()))
  with check (is_superadmin(auth.uid()));

-- system_parameters: solo superadmin escribe (igual que antes, ahora vía función)
create policy system_parameters_write on system_parameters
  for all to authenticated
  using (is_superadmin(auth.uid()))
  with check (is_superadmin(auth.uid()));

-- admin_users: cada quien ve su propio registro; superadmin ve todo
create policy admin_users_select_self on admin_users
  for select to authenticated
  using (
    auth_user_id = auth.uid()
    or is_superadmin(auth.uid())
  );

create policy admin_users_manage_superadmin on admin_users
  for insert to authenticated
  with check (is_superadmin(auth.uid()));

create policy admin_users_update_superadmin on admin_users
  for update to authenticated
  using (is_superadmin(auth.uid()));
