-- =========================================================
-- MIGRACIÓN 021
-- Agrega estatus activo/inactivo a players (mismo patrón que
-- el resto del esquema), agrega el trigger de auditoría que
-- players nunca tuvo, y bloquea que un jugador se autoactive/
-- desactive (solo un administrador puede hacerlo).
-- =========================================================

alter table players
  add column activo             boolean     not null default true,
  add column fecha_baja         timestamptz,
  add column dado_de_baja_por   uuid        references admin_users (id) on delete restrict,
  add column motivo_baja        text;

comment on column players.activo is 'Solo un administrador puede cambiarlo (ver trigger restrict_players_self_verification_edit) — un jugador no puede reactivarse a sí mismo si fue dado de baja por un admin.';

-- Registrar automáticamente quién/cuándo da de baja o reactiva
create trigger trg_track_estatus_players
before update on players
for each row execute function track_estatus_activo();

-- Auditoría: players nunca tuvo este trigger, se agrega ahora
-- (gap encontrado al hacer este cambio, no reportado antes).
create trigger trg_audit_players
after insert or update or delete on players
for each row execute function log_audit();

-- Ampliar el trigger existente para bloquear también la
-- auto-modificación de "activo" por parte del propio jugador.
create or replace function restrict_players_self_verification_edit()
returns trigger as $$
begin
  if new.auth_user_id = auth.uid() and not is_active_admin(auth.uid()) then
    if new.handicap_verificado       is distinct from old.handicap_verificado
       or new.handicap_verificado_fecha is distinct from old.handicap_verificado_fecha
       or new.handicap_verificado_por   is distinct from old.handicap_verificado_por
       or new.handicap_estatus          is distinct from old.handicap_estatus then
      raise exception 'No puedes modificar tus propios campos de verificación de hándicap. Ese cambio lo debe hacer un administrador.';
    end if;

    if new.activo is distinct from old.activo then
      raise exception 'No puedes activar o desactivar tu propia cuenta. Ese cambio lo debe hacer un administrador.';
    end if;
  end if;

  return new;
end;
$$ language plpgsql;
