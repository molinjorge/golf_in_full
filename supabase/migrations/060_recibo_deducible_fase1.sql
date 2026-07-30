-- =========================================================
-- MIGRACIÓN 060
-- Recibo deducible — FASE 1: solicitud + carga de la Constancia
-- de Situación Fiscal. Ligado a payment_attempts (pago genérico),
-- no a tournament_registrations, para que sirva para cualquier
-- concepto de pago futuro (equipos, carritos, etc.).
--
-- FASE 2 (pendiente, no es parte de esta migración): generación
-- real de la factura fiscal — típicamente requiere integrarse
-- con un PAC (Proveedor Autorizado de Certificación del SAT).
--
-- Patrón: si el jugador dice "No", simplemente no se crea
-- ninguna fila aquí — la ausencia de fila = no se solicitó.
-- =========================================================

create table payment_fiscal_receipts (
  id                              uuid            primary key default gen_random_uuid(),
  payment_attempt_id              uuid            not null unique references payment_attempts (id) on delete restrict,

  constancia_situacion_fiscal_url text            not null,
  fecha_solicitud                 timestamptz     not null default now(),

  factura_url                     text,
  enviado                         boolean         not null default false,
  fecha_envio                     timestamptz,
  enviado_por                     uuid            references admin_users (id) on delete restrict,

  created_at                      timestamptz     not null default now(),
  updated_at                      timestamptz     not null default now()
);

comment on table payment_fiscal_receipts is 'Solicitud de recibo deducible, ligada al pago (no a la inscripción específica) — reutilizable para cualquier concepto de pago. Fase 1: solicitud + carga de constancia fiscal. Fase 2 (pendiente): generación/envío real de factura.';
comment on column payment_fiscal_receipts.constancia_situacion_fiscal_url is 'Ruta del PDF en Supabase Storage (bucket privado) — no se guarda el archivo en la base de datos, solo la referencia.';

create trigger trg_payment_fiscal_receipts_updated_at
before update on payment_fiscal_receipts
for each row execute function set_updated_at();

create trigger trg_audit_payment_fiscal_receipts
after insert or update or delete on payment_fiscal_receipts
for each row execute function log_audit();

create index idx_payment_fiscal_receipts_attempt on payment_fiscal_receipts (payment_attempt_id);
create index idx_payment_fiscal_receipts_pendientes on payment_fiscal_receipts (fecha_solicitud) where enviado = false;

alter table payment_fiscal_receipts enable row level security;

create policy payment_fiscal_receipts_select on payment_fiscal_receipts
  for select to authenticated
  using (
    exists (
      select 1 from payment_attempts pa
       where pa.id = payment_attempt_id
         and (
           pa.player_id in (select id from players where auth_user_id = auth.uid())
           or is_superadmin(auth.uid())
           or (pa.tournament_id is not null and is_tournament_organizer(auth.uid(), pa.tournament_id))
           or (pa.tournament_id is not null and exists (select 1 from tournaments t where t.id = pa.tournament_id and is_club_admin(auth.uid(), t.club_id)))
         )
    )
  );

create policy payment_fiscal_receipts_insert on payment_fiscal_receipts
  for insert to authenticated
  with check (
    exists (
      select 1 from payment_attempts pa
       where pa.id = payment_attempt_id
         and pa.player_id in (select id from players where auth_user_id = auth.uid())
         and pa.resultado = true
    )
  );

create policy payment_fiscal_receipts_update on payment_fiscal_receipts
  for update to authenticated
  using (is_superadmin(auth.uid()));

grant select, insert on payment_fiscal_receipts to authenticated;
grant update on payment_fiscal_receipts to authenticated;
