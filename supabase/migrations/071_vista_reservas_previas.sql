-- =========================================================
-- MIGRACIÓN 071
-- Vista unificada "Reservas previas del torneo": une
-- tournament_pre_reservations (jugador ya en catálogo) y
-- phone_reservations (jugador aún no en catálogo) — ambas
-- representan lo mismo desde la perspectiva del organizador:
-- alguien con compromiso de venir, todavía sin confirmar/pagar.
-- Requiere que ya exista phone_reservations (migración 070).
-- =========================================================

create view tournament_reservas_previas
with (security_invoker = true) as
select
  tp.id,
  tp.tournament_id,
  'catalogo'::text as origen,
  (p.nombres || ' ' || p.apellidos) as nombre,
  p.email as correo,
  (p.telefono_pais || ' ' || p.telefono_lada || ' ' || p.telefono_numero) as telefono,
  tp.tournament_category_id,
  tp.modalidad,
  tp.estatus::text as estatus,
  tp.monto,
  tp.fecha_limite_pago,
  tp.fecha_reserva,
  tp.activo
from tournament_pre_reservations tp
join players p on p.id = tp.player_id

union all

select
  pr.id,
  pr.tournament_id,
  'telefonica'::text as origen,
  pr.nombre_completo as nombre,
  pr.correo,
  (pr.telefono_pais || ' ' || pr.telefono_lada || ' ' || pr.telefono_numero) as telefono,
  pr.tournament_category_id,
  pr.modalidad,
  'pendiente_confirmacion_catalogo'::text as estatus,
  pr.monto,
  pr.fecha_limite_pago,
  pr.created_at as fecha_reserva,
  pr.activo
from phone_reservations pr;

comment on view tournament_reservas_previas is 'Unifica tournament_pre_reservations (ya en catálogo) y phone_reservations (aún no en catálogo) para la pantalla "Reservas previas del torneo" del organizador. origen distingue de dónde viene cada fila.';

grant select on tournament_reservas_previas to authenticated;
