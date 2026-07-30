-- =========================================================
-- MIGRACIÓN 064
-- Solo los torneos de beneficencia pueden emitir recibos
-- deducibles. Se mueve la info del beneficiario desde
-- tournament_marketing_info (contenido de venta) hacia
-- tournaments (regla de negocio real), y se valida a nivel de
-- base de datos que no se pueda pedir recibo en un torneo que
-- no sea de beneficencia.
-- =========================================================

alter table tournaments
  add column es_beneficencia         boolean not null default false,
  add column institucion_beneficiaria text,
  add column concepto_recibo         text;

comment on column tournaments.es_beneficencia is 'Solo los torneos marcados como beneficencia pueden emitir recibos deducibles (validado por trigger).';
comment on column tournaments.institucion_beneficiaria is 'Nombre de la institución beneficiaria. Obligatorio si es_beneficencia = true.';
comment on column tournaments.concepto_recibo is 'Concepto que aparecerá en el recibo/factura emitida. Obligatorio si es_beneficencia = true.';

create or replace function validar_datos_beneficencia()
returns trigger as $$
begin
  if new.es_beneficencia then
    if new.institucion_beneficiaria is null or trim(new.institucion_beneficiaria) = '' then
      raise exception 'Debes especificar el nombre de la institución beneficiaria.';
    end if;
    if new.concepto_recibo is null or trim(new.concepto_recibo) = '' then
      raise exception 'Debes especificar el concepto para el recibo.';
    end if;
  else
    new.institucion_beneficiaria := null;
    new.concepto_recibo := null;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validar_datos_beneficencia
before insert or update on tournaments
for each row execute function validar_datos_beneficencia();

update tournaments t
   set es_beneficencia = true,
       institucion_beneficiaria = tmi.beneficiario_nombre,
       concepto_recibo = coalesce(tmi.beneficiario_descripcion, 'Donativo — ' || tmi.beneficiario_nombre)
  from tournament_marketing_info tmi
 where tmi.tournament_id = t.id
   and tmi.beneficiario_nombre is not null
   and trim(tmi.beneficiario_nombre) <> '';

alter table tournament_marketing_info
  drop column beneficiario_nombre,
  drop column beneficiario_descripcion;

create or replace function validar_recibo_solo_beneficencia()
returns trigger as $$
declare
  v_es_beneficencia boolean;
begin
  if new.solicito_recibo_deducible = true then
    select es_beneficencia into v_es_beneficencia
      from tournaments where id = new.tournament_id;

    if v_es_beneficencia is not true then
      raise exception 'Solo los torneos de beneficencia pueden emitir recibo deducible.';
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validar_recibo_solo_beneficencia
before insert or update on payment_attempts
for each row execute function validar_recibo_solo_beneficencia();

create or replace function validar_fiscal_receipt_solo_beneficencia()
returns trigger as $$
declare
  v_es_beneficencia boolean;
begin
  select t.es_beneficencia into v_es_beneficencia
    from payment_attempts pa
    join tournaments t on t.id = pa.tournament_id
   where pa.id = new.payment_attempt_id;

  if v_es_beneficencia is not true then
    raise exception 'Solo los torneos de beneficencia pueden emitir recibo deducible.';
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validar_fiscal_receipt_solo_beneficencia
before insert on payment_fiscal_receipts
for each row execute function validar_fiscal_receipt_solo_beneficencia();
