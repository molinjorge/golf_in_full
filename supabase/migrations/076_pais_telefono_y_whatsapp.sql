-- =========================================================
-- MIGRACIÓN 076
-- 1) Código de país limitado a +52 (México) y +1 (EE.UU./Canadá)
--    — validado a nivel de base de datos, no solo en el frontend.
--    Aplica a players y phone_reservations (los dos lugares
--    donde se captura teléfono).
-- 2) Consentimiento de WhatsApp en players — para la futura
--    comunicación por ese canal.
-- =========================================================

DO $$
DECLARE
  v_invalidos integer;
BEGIN
  SELECT count(*) INTO v_invalidos
    FROM players
   WHERE telefono_pais IS NOT NULL AND telefono_pais NOT IN ('+52', '+1');

  IF v_invalidos > 0 THEN
    RAISE EXCEPTION 'Hay % jugador(es) con un código de país distinto a +52/+1. Corrígelos manualmente antes de correr esta migración.', v_invalidos;
  END IF;
END $$;

alter table players
  add constraint players_telefono_pais_valido
  check (telefono_pais is null or telefono_pais in ('+52', '+1'));

alter table phone_reservations
  add constraint phone_reservations_telefono_pais_valido
  check (telefono_pais in ('+52', '+1'));

alter table players
  add column acepta_whatsapp boolean not null default false;

comment on column players.acepta_whatsapp is 'Consentimiento explícito del jugador para recibir mensajes por WhatsApp.';
