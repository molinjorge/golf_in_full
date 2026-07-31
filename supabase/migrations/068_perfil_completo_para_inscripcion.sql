-- =========================================================
-- MIGRACIÓN 068
-- fecha_nacimiento y teléfono vuelven opcionales en players
-- (para permitir pre-registro incompleto por un organizador).
-- Se exigen completos únicamente al momento de INSCRIBIRSE a
-- un torneo (inscripción en línea o pre-reserva) — ahí es
-- donde de verdad deben estar obligatorios.
-- =========================================================

alter table players
  alter column fecha_nacimiento drop not null;

alter table players
  alter column telefono_pais drop not null,
  alter column telefono_lada drop not null,
  alter column telefono_numero drop not null;

alter table players
  add constraint players_telefono_consistente
  check (
    (telefono_pais is null and telefono_lada is null and telefono_numero is null)
    or (telefono_pais is not null and telefono_lada is not null and telefono_numero is not null)
  );

create or replace function validar_perfil_completo_para_inscripcion(p_player_id uuid)
returns void
language plpgsql
as $$
declare
  v_fecha_nacimiento date;
  v_telefono_pais    text;
begin
  select fecha_nacimiento, telefono_pais into v_fecha_nacimiento, v_telefono_pais
    from players where id = p_player_id;

  if v_fecha_nacimiento is null or v_telefono_pais is null then
    raise exception 'Debes completar tu fecha de nacimiento y teléfono en tu perfil antes de poder inscribirte.';
  end if;
end;
$$;

comment on function validar_perfil_completo_para_inscripcion is 'Exige fecha_nacimiento y teléfono completos antes de permitir una inscripción o pre-reserva. Estos campos son opcionales en players en general, pero obligatorios para inscribirse.';

create or replace function validar_perfil_completo_trigger()
returns trigger as $$
begin
  perform validar_perfil_completo_para_inscripcion(new.player_id);
  return new;
end;
$$ language plpgsql;

create trigger trg_validar_perfil_completo_registrations
before insert on tournament_registrations
for each row execute function validar_perfil_completo_trigger();

create trigger trg_validar_perfil_completo_prereservations
before insert on tournament_pre_reservations
for each row execute function validar_perfil_completo_trigger();
