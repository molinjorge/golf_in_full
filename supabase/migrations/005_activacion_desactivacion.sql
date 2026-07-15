-- =========================================================
-- MIGRACIÓN 005
-- Activar/desactivar personas, roles y asignaciones,
-- con registro automático de quién y cuándo lo hizo.
-- =========================================================

-- ---------------------------------------------------------
-- 1) COLUMNAS DE ESTATUS (altas/bajas) EN LAS 3 TABLAS
-- ---------------------------------------------------------
-- admin_users y roles ya tenían "activo"; se agregan los
-- campos de auditoría rápida de baja. admin_role_assignments
-- no tenía "activo" todavía: se agrega junto con lo demás.

alter table admin_users
  add column fecha_baja        timestamptz,
  add column dado_de_baja_por  uuid references admin_users (id) on delete set null,
  add column motivo_baja       text;

alter table roles
  add column fecha_baja        timestamptz,
  add column dado_de_baja_por  uuid references admin_users (id) on delete set null,
  add column motivo_baja       text;

alter table admin_role_assignments
  add column activo            boolean not null default true,
  add column fecha_baja        timestamptz,
  add column dado_de_baja_por  uuid references admin_users (id) on delete set null,
  add column motivo_baja       text;

comment on column admin_users.fecha_baja is 'Fecha/hora en que se desactivó. Null si está activo.';
comment on column admin_role_assignments.activo is 'false = rol revocado (pero se conserva la fila como historial, no se borra).';

-- ---------------------------------------------------------
-- 2) TRIGGER: registrar automáticamente alta/baja
-- ---------------------------------------------------------
-- Reutilizable en cualquier tabla que tenga columnas
-- activo / fecha_baja / dado_de_baja_por / motivo_baja.

create or replace function track_estatus_activo()
returns trigger as $$
begin
  if old.activo = true and new.activo = false then
    new.fecha_baja       := now();
    new.dado_de_baja_por := current_admin_id();
    -- motivo_baja se deja tal cual lo haya mandado la aplicación

  elsif old.activo = false and new.activo = true then
    -- Reactivación: se limpia el "rastro rápido" de la baja anterior.
    -- El detalle de esa baja sigue disponible en audit_log.
    new.fecha_baja       := null;
    new.dado_de_baja_por := null;
    new.motivo_baja      := null;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_track_estatus_admin_users
before update on admin_users
for each row execute function track_estatus_activo();

create trigger trg_track_estatus_roles
before update on roles
for each row execute function track_estatus_activo();

create trigger trg_track_estatus_role_assignments
before update on admin_role_assignments
for each row execute function track_estatus_activo();

-- Nota de uso: en la aplicación, "dar de baja" a alguien SIEMPRE debe
-- ser un UPDATE (activo = false), nunca un DELETE. El DELETE físico
-- rompe la trazabilidad de con quién compartió club/torneo en su momento.

-- ---------------------------------------------------------
-- 3) AJUSTAR REGLAS PARA QUE SOLO CUENTEN ASIGNACIONES ACTIVAS
-- ---------------------------------------------------------

-- 3a) Los índices únicos ahora solo aplican entre asignaciones activas,
--     así una asignación desactivada no bloquea una nueva.

drop index if exists uq_role_assignment_global;
drop index if exists uq_role_assignment_club;
drop index if exists uq_role_assignment_tournament;

create unique index uq_role_assignment_global
  on admin_role_assignments (admin_user_id, role_id)
  where club_id is null and tournament_id is null and activo = true;

create unique index uq_role_assignment_club
  on admin_role_assignments (admin_user_id, role_id, club_id)
  where club_id is not null and activo = true;

create unique index uq_role_assignment_tournament
  on admin_role_assignments (admin_user_id, role_id, tournament_id)
  where tournament_id is not null and activo = true;

-- 3b) El límite "máx. 1 club por club_admin" debe contar solo activas
--     (si no, alguien dado de baja de un club se quedaría bloqueado
--     para siempre y no podría administrar otro club después).

create or replace function validate_role_assignment_limits()
returns trigger as $$
declare
  v_max   integer;
  v_count integer;
begin
  select max_asignaciones_por_admin into v_max from roles where id = new.role_id;

  if v_max is not null and new.activo = true then
    select count(*) into v_count
      from admin_role_assignments
     where admin_user_id = new.admin_user_id
       and role_id = new.role_id
       and activo = true
       and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid);

    if v_count >= v_max then
      raise exception
        'Este administrador ya alcanzó el máximo de % asignación(es) activa(s) permitida(s) para este rol.', v_max;
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

-- 3c) Las funciones de permisos (is_club_admin, etc.) deben ignorar
--     asignaciones desactivadas: alguien dado de baja no debe seguir
--     teniendo acceso solo porque la fila sigue en la tabla.

create or replace function is_superadmin(p_auth_uid uuid)
returns boolean language sql stable as $$
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
returns boolean language sql stable as $$
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
returns boolean language sql stable as $$
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
