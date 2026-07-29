-- =========================================================
-- MIGRACIÓN 055
-- Folio legible para humanos (INS-0001, INS-0002...), consecutivo
-- POR TORNEO — separado del qr_token, que se queda como llave
-- secreta del acceso (no debe cambiar, no está pensado para leerse).
-- =========================================================

alter table tournament_registrations add column folio text;

create or replace function generar_folio_inscripcion()
returns trigger as $$
declare
  v_consecutivo integer;
begin
  perform 1 from tournaments where id = new.tournament_id for update;

  select count(*) + 1 into v_consecutivo
    from tournament_registrations
   where tournament_id = new.tournament_id;

  new.folio := 'INS-' || lpad(v_consecutivo::text, 4, '0');

  return new;
end;
$$ language plpgsql;

create trigger trg_generar_folio_inscripcion
before insert on tournament_registrations
for each row execute function generar_folio_inscripcion();

alter table tournament_registrations
  add constraint tournament_registrations_folio_unico unique (tournament_id, folio);

comment on column tournament_registrations.folio is 'Folio legible, consecutivo por torneo (ej. INS-0001). Se genera automáticamente, no se captura a mano. Distinto de qr_token, que es la llave secreta del acceso.';
