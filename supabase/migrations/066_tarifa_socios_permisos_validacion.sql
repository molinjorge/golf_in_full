-- =========================================================
-- MIGRACIÓN 066
-- Tarifa para socios:
--   - se conserva en tournament_marketing_info.precio_socios
--   - editable por superadmin, tournament_organizer y club_admin
--   - debe ser menor que la tarifa individual
--   - debe ser igual a la tarifa Early Bid
--
-- NOTA DE VOCABULARIO:
-- Los nombres técnicos tarifa_early_bird y
-- fecha_limite_early_bird se conservan para no romper el
-- esquema. En la interfaz debe mostrarse "Early Bid".
-- =========================================================

-- ---------------------------------------------------------
-- 1. Permitir también al administrador del club escribir
--    tournament_marketing_info para torneos de su club.
-- ---------------------------------------------------------

drop policy if exists tournament_marketing_info_write
  on public.tournament_marketing_info;

create policy tournament_marketing_info_write
on public.tournament_marketing_info
for all
to authenticated
using (
  is_superadmin(auth.uid())
  or is_tournament_organizer(auth.uid(), tournament_id)
  or exists (
    select 1
      from public.tournaments t
     where t.id = tournament_id
       and is_club_admin(auth.uid(), t.club_id)
  )
)
with check (
  is_superadmin(auth.uid())
  or is_tournament_organizer(auth.uid(), tournament_id)
  or exists (
    select 1
      from public.tournaments t
     where t.id = tournament_id
       and is_club_admin(auth.uid(), t.club_id)
  )
);

comment on policy tournament_marketing_info_write
  on public.tournament_marketing_info is
  'Superadmin, organizador del torneo y administrador del club anfitrión pueden crear, editar o eliminar la información para el jugador.';

-- ---------------------------------------------------------
-- 2. Validación servidor de la Tarifa para socios.
-- ---------------------------------------------------------

create or replace function public.validar_precio_socios()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_tarifa_individual numeric(10,2);
  v_tarifa_early_bid  numeric(10,2);
begin
  -- La tarifa para socios es opcional.
  if new.precio_socios is null then
    return new;
  end if;

  select
    t.tarifa_individual,
    t.tarifa_early_bird
  into
    v_tarifa_individual,
    v_tarifa_early_bid
  from public.tournaments t
  where t.id = new.tournament_id;

  if not found then
    raise exception
      'No existe el torneo relacionado con la tarifa para socios.';
  end if;

  if v_tarifa_individual is null then
    raise exception
      'Debes capturar primero la tarifa individual.';
  end if;

  if new.precio_socios >= v_tarifa_individual then
    raise exception
      'La tarifa para socios debe ser menor que la tarifa individual.';
  end if;

  if v_tarifa_early_bid is null then
    raise exception
      'Para capturar la tarifa para socios debe existir una tarifa Early Bid.';
  end if;

  if new.precio_socios <> v_tarifa_early_bid then
    raise exception
      'La tarifa para socios debe ser igual a la tarifa Early Bid.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validar_precio_socios
  on public.tournament_marketing_info;

create trigger trg_validar_precio_socios
before insert or update of precio_socios
on public.tournament_marketing_info
for each row
execute function public.validar_precio_socios();

comment on function public.validar_precio_socios() is
  'Valida que precio_socios sea menor que tarifa_individual e igual a tarifa_early_bird. Si precio_socios es null, no aplica validación.';

comment on column public.tournament_marketing_info.precio_socios is
  'Tarifa opcional para socios del club. Debe ser menor que la tarifa individual e igual a la tarifa Early Bid del torneo.';
