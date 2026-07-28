-- =========================================================
-- MIGRACIÓN 043
-- 1) Teléfono pasa a ser obligatorio en players (se suma a
--    apellidos/nombres/correo, que ya lo eran).
-- 2) Teléfono único en toda la tabla (evita registros duplicados).
-- 3) Una vez que la cuenta ya fue confirmada (auth_user_id
--    asignado), solo el propio dueño o el superadmin pueden
--    modificar el teléfono — ningún otro tipo de administrador.
-- =========================================================

DO $$
DECLARE
  v_incompletos integer;
BEGIN
  SELECT count(*) INTO v_incompletos
    FROM players
   WHERE telefono_pais IS NULL OR telefono_lada IS NULL OR telefono_numero IS NULL;

  IF v_incompletos > 0 THEN
    RAISE EXCEPTION 'Hay % jugador(es) sin teléfono completo. Complétalos manualmente antes de correr esta migración.', v_incompletos;
  END IF;
END $$;

alter table players
  alter column telefono_pais set not null,
  alter column telefono_lada set not null,
  alter column telefono_numero set not null;

alter table players
  add constraint players_telefono_unico unique (telefono_pais, telefono_lada, telefono_numero);

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

  return new;
end;
$$ language plpgsql;

comment on function restrict_players_self_verification_edit is 'Restringe: (1) que el jugador se autoverifique hándicap o cambie su propio activo; (2) que alguien distinto al dueño o al superadmin edite el teléfono, una vez la cuenta ya está confirmada.';
