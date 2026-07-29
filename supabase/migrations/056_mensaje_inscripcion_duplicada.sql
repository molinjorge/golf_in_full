-- =========================================================
-- MIGRACIÓN 056
-- Mensaje claro cuando un jugador ya tiene una inscripción
-- activa en el torneo, en vez del error técnico genérico de la
-- restricción UNIQUE (que se conserva como respaldo). Mismo
-- patrón que validar_telefono_unico().
-- =========================================================

create or replace function validar_inscripcion_no_duplicada()
returns trigger
security definer
set search_path = public
as $$
declare
  v_existe boolean;
begin
  select exists (
    select 1 from tournament_registrations
     where tournament_id = new.tournament_id
       and player_id = new.player_id
       and activo = true
       and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid)
  ) into v_existe;

  if v_existe then
    raise exception 'Ya tienes una inscripción activa en este torneo.';
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validar_inscripcion_no_duplicada
before insert on tournament_registrations
for each row execute function validar_inscripcion_no_duplicada();

comment on function validar_inscripcion_no_duplicada is 'Da un mensaje claro cuando el jugador ya está inscrito activamente en el torneo, en vez del error genérico de la restricción UNIQUE (que se conserva como respaldo).';
