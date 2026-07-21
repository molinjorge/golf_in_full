-- =========================================================
-- MIGRACIÓN 034
-- Agrega tournaments.campo_golf_id — el campo donde se juega el
-- torneo (fuente real para precargar las rondas, en vez de tener
-- que "adivinar" mirando la primera ronda ya capturada).
-- club_id se conserva: sigue siendo necesario para todas las
-- políticas de RLS ya construidas (rondas, turnos, categorías,
-- desempates) que verifican al club_admin por esa columna.
-- =========================================================

alter table tournaments
  add column campo_golf_id uuid references campos_golf (id) on delete restrict;

comment on column tournaments.campo_golf_id is 'Campo donde se juega el torneo. Debe pertenecer al club declarado en club_id (validado por trigger). Fuente para precargar tournament_rounds.campo_golf_id.';

create or replace function validar_campo_pertenece_al_club()
returns trigger as $$
declare
  v_club_del_campo uuid;
begin
  if new.campo_golf_id is not null then
    select club_id into v_club_del_campo from campos_golf where id = new.campo_golf_id;

    if v_club_del_campo is distinct from new.club_id then
      raise exception 'El campo de golf seleccionado no pertenece al club declarado para este torneo.';
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validar_campo_pertenece_al_club
before insert or update on tournaments
for each row execute function validar_campo_pertenece_al_club();

-- No se vuelve NOT NULL todavía: si ya existe algún torneo de
-- prueba sin campo asignado, esto evita que la migración falle.
-- Complétalo manualmente y luego, si quieres, lo hacemos obligatorio
-- con una migración aparte (mismo patrón que usamos con players.city_id).
