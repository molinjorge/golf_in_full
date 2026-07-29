-- =========================================================
-- MIGRACIÓN 053
-- Habilita pgcrypto — nunca se había creado explícitamente, y
-- es necesaria para gen_random_bytes(), usada en los valores
-- default de qr_token (tournament_registrations,
-- tournament_pre_reservations) y en las referencias de pago
-- simuladas.
-- =========================================================

create extension if not exists pgcrypto;
