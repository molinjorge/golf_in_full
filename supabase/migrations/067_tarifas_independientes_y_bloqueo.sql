-- =========================================================
-- MIGRACIÓN 067
-- 1) precio_socios vuelve a ser totalmente independiente de
--    tarifa_early_bird — solo debe ser menor que tarifa_individual.
-- 2) Una vez que un torneo tiene al menos una inscripción activa
--    (alguien ya pagó), sus tarifas (individual, early bird,
--    fecha límite early bird) quedan bloqueadas — no se pueden
--    modificar, para proteger a quien ya pagó una tarifa distinta.
-- =========================================================

create or replace function validar_precio_socios()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_tarifa_individual numeric(10,2);
begin
  if new.precio_socios is null then
    return new;
  end if;

  select t.tarifa_individual into v_tarifa_individual
    from tournaments t where t.id = new.tournament_id;

  if not found then
    raise exception 'No existe el torneo relacionado con la tarifa para socios.';
  end if;

  if v_tarifa_individual is null then
    raise exception 'Debes capturar primero la tarifa individual.';
  end if;

  if new.precio_socios >= v_tarifa_individual then
    raise exception 'La tarifa para socios debe ser menor que la tarifa individual.';
  end if;

  return new;
end;
$$;

comment on function validar_precio_socios is 'Valida que precio_socios sea menor que tarifa_individual. Independiente de tarifa_early_bird a propósito — son conceptos separados. Si precio_socios es null, no aplica validación.';

create or replace function bloquear_cambio_tarifas_con_inscritos()
returns trigger as $$
declare
  v_hay_inscritos boolean;
begin
  if new.tarifa_individual is distinct from old.tarifa_individual
     or new.tarifa_early_bird is distinct from old.tarifa_early_bird
     or new.fecha_limite_early_bird is distinct from old.fecha_limite_early_bird
  then
    select exists (
      select 1 from tournament_registrations
       where tournament_id = new.id and activo = true
    ) into v_hay_inscritos;

    if v_hay_inscritos then
      raise exception 'No se pueden modificar las tarifas de este torneo: ya existen inscripciones pagadas con la tarifa actual.';
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_bloquear_cambio_tarifas_con_inscritos
before update on tournaments
for each row execute function bloquear_cambio_tarifas_con_inscritos();

comment on function bloquear_cambio_tarifas_con_inscritos is 'Impide cambiar tarifa_individual, tarifa_early_bird o su fecha límite si el torneo ya tiene al menos una inscripción activa — protege a quien ya pagó con la tarifa vigente en ese momento.';
