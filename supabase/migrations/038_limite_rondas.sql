-- =========================================================
-- MIGRACIÓN 038
-- Impide crear más filas en tournament_rounds que las
-- declaradas en tournaments.numero_rondas. Solo cuenta rondas
-- activas — una ronda desactivada libera espacio para otra.
-- =========================================================

create or replace function validar_limite_rondas()
returns trigger as $$
declare
  v_numero_rondas integer;
  v_count_actual  integer;
begin
  select numero_rondas into v_numero_rondas from tournaments where id = new.tournament_id;

  select count(*) into v_count_actual
    from tournament_rounds
   where tournament_id = new.tournament_id
     and activo = true;

  if v_count_actual >= v_numero_rondas then
    raise exception
      'Este torneo tiene declaradas % ronda(s) (tournaments.numero_rondas), y ya existen % activa(s). Aumenta el número de rondas del torneo antes de agregar otra.',
      v_numero_rondas, v_count_actual;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validar_limite_rondas
before insert on tournament_rounds
for each row execute function validar_limite_rondas();

comment on function validar_limite_rondas is 'Bloquea el INSERT de una ronda nueva si ya se alcanzó tournaments.numero_rondas. No aplica a UPDATE — solo al agregar una ronda adicional.';
