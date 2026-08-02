-- =========================================================
-- MIGRACIÓN 087
-- club_id y numero_membresia solo los puede editar el propio
-- jugador (sobre su perfil) o el superadmin — ni club_admin ni
-- tournament_organizer pueden tocarlos, aunque sí puedan editar
-- el resto del perfil de un jugador. Son datos que declara el
-- propio jugador, no algo que un administrador deba certificar.
-- =========================================================

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

  if old.auth_user_id is not null
     and (new.telefono_pais, new.telefono_lada, new.telefono_numero)
         is distinct from (old.telefono_pais, old.telefono_lada, old.telefono_numero)
  then
    if not (auth.uid() = old.auth_user_id or is_superadmin(auth.uid())) then
      raise exception 'Una vez confirmada la cuenta, solo el propio jugador o un superadministrador pueden modificar el teléfono.';
    end if;
  end if;

  if (new.club_id is distinct from old.club_id
      or new.numero_membresia is distinct from old.numero_membresia)
  then
    if not (auth.uid() = old.auth_user_id or is_superadmin(auth.uid())) then
      raise exception 'Solo el propio jugador o un superadministrador pueden modificar el club de membresía y el número de membresía.';
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

comment on function restrict_players_self_verification_edit is 'Restringe: (1) autoverificación de hándicap y activo por el propio jugador; (2) teléfono, una vez confirmada la cuenta, solo dueño o superadmin; (3) club_id/numero_membresia, solo dueño o superadmin — ni club_admin ni organizador pueden tocarlos.';
