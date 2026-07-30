-- =========================================================
-- MIGRACIÓN 065
-- Tarifa Early Bird: monto especial válido hasta una fecha
-- límite. El monto que se cobra SIEMPRE lo calcula el servidor
-- (no se confía en lo que mande el cliente) — evita que alguien
-- manipule el monto antes de enviarlo.
-- =========================================================

alter table tournaments
  add column tarifa_early_bird       numeric(10,2),
  add column fecha_limite_early_bird date;

comment on column tournaments.tarifa_early_bird is 'Tarifa especial de inscripción temprana. Válida hasta fecha_limite_early_bird (inclusive). Ambas columnas van juntas — o las dos con valor, o las dos vacías.';

alter table tournaments
  add constraint tournaments_early_bird_consistente
  check (
    (tarifa_early_bird is null and fecha_limite_early_bird is null)
    or (tarifa_early_bird is not null and fecha_limite_early_bird is not null)
  );

alter table tournaments
  add constraint tournaments_early_bird_valido
  check (tarifa_early_bird is null or tarifa_early_bird >= 0);

create or replace function tarifa_vigente_torneo(p_tournament_id uuid)
returns numeric
language sql
stable
as $$
  select case
    when t.tarifa_early_bird is not null
         and current_date <= t.fecha_limite_early_bird
    then t.tarifa_early_bird
    else t.tarifa_individual
  end
  from tournaments t
  where t.id = p_tournament_id;
$$;

comment on function tarifa_vigente_torneo is 'Tarifa aplicable HOY para un torneo: early bird si está definida y no ha vencido, si no la tarifa individual regular.';

grant execute on function tarifa_vigente_torneo(uuid) to authenticated, anon;

create or replace function calcular_monto_inscripcion_individual()
returns trigger as $$
begin
  if new.concepto = 'inscripcion_individual' then
    new.monto := tarifa_vigente_torneo(new.tournament_id);
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_calcular_monto_inscripcion_individual
before insert on payment_attempts
for each row execute function calcular_monto_inscripcion_individual();

comment on function calcular_monto_inscripcion_individual is 'Sobrescribe payment_attempts.monto con la tarifa vigente del servidor, para inscripción individual — el monto nunca se toma del cliente directamente.';
