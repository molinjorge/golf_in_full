-- =========================================================
-- MIGRACIÓN 063
-- Bandera de INTENCIÓN de recibo deducible, separada de la
-- solicitud completa (payment_fiscal_receipts, que solo existe
-- una vez subido el PDF). Permite detectar a quien dijo "Sí"
-- pero nunca completó la carga de su constancia.
-- =========================================================

alter table payment_attempts
  add column solicito_recibo_deducible boolean not null default false;

comment on column payment_attempts.solicito_recibo_deducible is 'true en cuanto el jugador responde "Sí" a si quiere recibo deducible — independiente de si después sube o no la constancia. Compárese contra payment_fiscal_receipts (que solo existe una vez subido el PDF) para detectar solicitudes incompletas.';

create index idx_payment_attempts_recibo_pendiente
  on payment_attempts (id)
  where solicito_recibo_deducible = true;
