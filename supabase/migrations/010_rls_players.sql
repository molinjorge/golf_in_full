-- =========================================================
-- MIGRACIÓN 010
-- Políticas de RLS para "players":
-- - Un jugador ve/edita solo su propio perfil.
-- - Cero visibilidad entre jugadores (decisión explícita).
-- - Cualquier administrador activo (no solo superadmin) puede
--   ver/editar perfiles, para poder hacer el trabajo de
--   verificación de hándicap.
-- - Un jugador no puede auto-verificarse su propio hándicap,
--   aunque tenga permiso de editar el resto de su perfil.
-- =========================================================

-- ---------------------------------------------------------
-- Helper: ¿es un administrador activo, sin importar el rol?
-- ---------------------------------------------------------

create or replace function is_active_admin(p_auth_uid uuid)
returns boolean language sql stable as $$
  select exists (
    select 1 from admin_users
     where auth_user_id = p_auth_uid
       and activo = true
  );
$$;

comment on function is_active_admin is 'true si el usuario autenticado tiene un registro activo en admin_users, sin importar qué rol tenga asignado.';

-- ---------------------------------------------------------
-- Trigger: bloquear auto-verificación de hándicap
-- ---------------------------------------------------------

create or replace function restrict_players_self_verification_edit()
returns trigger as $$
begin
  -- Solo aplica si quien edita es el dueño del perfil y NO es admin.
  if new.auth_user_id = auth.uid() and not is_active_admin(auth.uid()) then
    if new.handicap_verificado       is distinct from old.handicap_verificado
       or new.handicap_verificado_fecha is distinct from old.handicap_verificado_fecha
       or new.handicap_verificado_por   is distinct from old.handicap_verificado_por
       or new.handicap_estatus          is distinct from old.handicap_estatus then
      raise exception 'No puedes modificar tus propios campos de verificación de hándicap. Ese cambio lo debe hacer un administrador.';
    end if;
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_players_restrict_self_verification
before update on players
for each row execute function restrict_players_self_verification_edit();

-- ---------------------------------------------------------
-- RLS
-- ---------------------------------------------------------

alter table players enable row level security;

-- SELECT: el propio jugador, o cualquier administrador activo.
-- Explícitamente NO incluye a otros jugadores.
create policy players_select on players
  for select to authenticated
  using (
    auth_user_id = auth.uid()
    or is_active_admin(auth.uid())
  );

-- INSERT: auto-registro (el jugador crea su propio perfil), o
-- un administrador dando de alta a un jugador que aún no tiene
-- cuenta (auth_user_id queda null hasta que el jugador se registre).
create policy players_insert on players
  for insert to authenticated
  with check (
    auth_user_id = auth.uid()
    or is_active_admin(auth.uid())
  );

-- UPDATE: mismo criterio que SELECT. El trigger de arriba impide
-- que el propio jugador toque sus campos de verificación.
create policy players_update on players
  for update to authenticated
  using (
    auth_user_id = auth.uid()
    or is_active_admin(auth.uid())
  );

-- Sin política de DELETE, a propósito — mismo patrón que el resto
-- del esquema: nadie borra un jugador desde la app, ni siquiera él
-- mismo. (players todavía no tiene columnas de alta/baja tipo
-- "activo"/"fecha_baja" como admin_users; si en algún momento
-- quieres que un jugador pueda "desactivar" su cuenta, es una
-- migración aparte, análoga a la que ya usamos en admin_users.)
