-- =========================================================
-- MIGRACIÓN 004
-- 1) Límite de asignaciones por rol (ej. club_admin: máx. 1)
-- 2) Quién puede otorgar cada rol (superadmin vs. responsable del ámbito)
-- 3) Auditoría genérica de altas/cambios en admin_users y roles
-- =========================================================

-- ---------------------------------------------------------
-- 1) LÍMITE DE ASIGNACIONES POR ADMINISTRADOR
-- ---------------------------------------------------------

alter table roles
  add column max_asignaciones_por_admin integer;  -- null = sin límite

comment on column roles.max_asignaciones_por_admin is
  'Máximo de asignaciones simultáneas de este rol que puede tener un mismo admin_user. Null = sin límite (ej. tournament_organizer puede tener varias).';

update roles set max_asignaciones_por_admin = 1 where codigo = 'club_admin';
-- superadmin y tournament_organizer quedan sin límite explícito por ahora

create or replace function validate_role_assignment_limits()
returns trigger as $$
declare
  v_max   integer;
  v_count integer;
begin
  select max_asignaciones_por_admin into v_max from roles where id = new.role_id;

  if v_max is not null then
    select count(*) into v_count
      from admin_role_assignments
     where admin_user_id = new.admin_user_id
       and role_id = new.role_id
       and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid);

    if v_count >= v_max then
      raise exception
        'Este administrador ya alcanzó el máximo de % asignación(es) permitida(s) para este rol.', v_max;
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validate_role_assignment_limits
before insert or update on admin_role_assignments
for each row execute function validate_role_assignment_limits();

-- ---------------------------------------------------------
-- 2) QUIÉN PUEDE OTORGAR CADA ROL
-- ---------------------------------------------------------

create type otorgante_rol as enum (
  'superadmin',          -- solo el superadministrador puede asignar este rol
  'responsable_ambito'    -- el club_admin (si ambito=club) o tournament_organizer
                            -- (si ambito=tournament) del club/torneo correspondiente
);

alter table roles
  add column otorgado_por otorgante_rol not null default 'superadmin';

comment on column roles.otorgado_por is
  'Quién tiene permiso de asignar este rol: superadmin siempre, o el responsable del club/torneo si es un rol interno.';

-- Los 3 roles administrativos actuales: solo el superadmin los otorga
-- (ya son 'superadmin' por el default, se deja explícito por claridad)
update roles set otorgado_por = 'superadmin'
 where codigo in ('superadmin', 'club_admin', 'tournament_organizer');

-- Ejemplo de cómo se vería un rol interno futuro (NO se inserta todavía,
-- se deja documentado para cuando lo necesiten):
-- insert into roles (codigo, nombre, descripcion, ambito, otorgado_por)
-- values ('scoring_encargado', 'Encargado de Scoring', 'Captura resultados de un torneo.', 'tournament', 'responsable_ambito');

-- Reemplazamos la política de escritura de admin_role_assignments para
-- reflejar esta regla: superadmin siempre puede; el responsable del
-- club/torneo puede, pero solo para roles marcados 'responsable_ambito'
-- y dentro de SU club/torneo.

drop policy if exists role_assignments_write on admin_role_assignments;

create policy role_assignments_write on admin_role_assignments
  for all to authenticated
  using (
    is_superadmin(auth.uid())
    or exists (
      select 1 from roles r
       where r.id = admin_role_assignments.role_id
         and r.otorgado_por = 'responsable_ambito'
         and (
           (r.ambito = 'club' and is_club_admin(auth.uid(), admin_role_assignments.club_id))
           or (r.ambito = 'tournament' and is_tournament_organizer(auth.uid(), admin_role_assignments.tournament_id))
         )
    )
  )
  with check (
    is_superadmin(auth.uid())
    or exists (
      select 1 from roles r
       where r.id = role_id
         and r.otorgado_por = 'responsable_ambito'
         and (
           (r.ambito = 'club' and is_club_admin(auth.uid(), club_id))
           or (r.ambito = 'tournament' and is_tournament_organizer(auth.uid(), tournament_id))
         )
    )
  );

-- ---------------------------------------------------------
-- 3) AUDITORÍA GENÉRICA DE ALTAS Y CAMBIOS
-- ---------------------------------------------------------

create table audit_log (
  id                 uuid        primary key default gen_random_uuid(),
  tabla              text        not null,                 -- ej. 'admin_users'
  registro_id        uuid        not null,                 -- id del registro afectado
  accion             text        not null check (accion in ('INSERT', 'UPDATE', 'DELETE')),
  realizado_por      uuid        references admin_users (id),  -- quién hizo el cambio
  datos_anteriores   jsonb,
  datos_nuevos       jsonb,
  created_at         timestamptz not null default now()
);

comment on table audit_log is 'Historial de altas, cambios y bajas en tablas sensibles (administradores, roles, asignaciones). Solo se escribe vía trigger.';

create index idx_audit_log_tabla_registro on audit_log (tabla, registro_id);
create index idx_audit_log_realizado_por on audit_log (realizado_por);

-- Resuelve el admin_users.id del usuario autenticado actual
create or replace function current_admin_id()
returns uuid language sql stable as $$
  select id from admin_users where auth_user_id = auth.uid();
$$;

-- Función de trigger genérica y reutilizable: se puede enganchar
-- a cualquier tabla futura (players, clubs, tournaments...) que
-- necesite el mismo historial de auditoría.
create or replace function log_audit()
returns trigger as $$
declare
  v_admin_id uuid := current_admin_id();
begin
  if (tg_op = 'INSERT') then
    insert into audit_log (tabla, registro_id, accion, realizado_por, datos_nuevos)
    values (tg_table_name, new.id, 'INSERT', v_admin_id, to_jsonb(new));
    return new;

  elsif (tg_op = 'UPDATE') then
    insert into audit_log (tabla, registro_id, accion, realizado_por, datos_anteriores, datos_nuevos)
    values (tg_table_name, new.id, 'UPDATE', v_admin_id, to_jsonb(old), to_jsonb(new));
    return new;

  elsif (tg_op = 'DELETE') then
    insert into audit_log (tabla, registro_id, accion, realizado_por, datos_anteriores)
    values (tg_table_name, old.id, 'DELETE', v_admin_id, to_jsonb(old));
    return old;
  end if;

  return null;
end;
$$ language plpgsql security definer;
-- security definer: para que el trigger pueda escribir en audit_log
-- aunque el usuario autenticado no tenga permiso directo de escritura ahí.

create trigger trg_audit_admin_users
after insert or update or delete on admin_users
for each row execute function log_audit();

create trigger trg_audit_role_assignments
after insert or update or delete on admin_role_assignments
for each row execute function log_audit();

create trigger trg_audit_roles
after insert or update or delete on roles
for each row execute function log_audit();

-- RLS de audit_log: nadie escribe directo (solo el trigger, vía
-- security definer); por ahora solo el superadmin puede leerlo.
alter table audit_log enable row level security;

create policy audit_log_select_superadmin on audit_log
  for select to authenticated
  using (is_superadmin(auth.uid()));

-- (Intencionalmente no se crean políticas de insert/update/delete:
-- por defecto RLS bloquea todo lo que no tiene política explícita,
-- así que solo el trigger -que corre como security definer- puede escribir.)
