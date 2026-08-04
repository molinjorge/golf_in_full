-- =========================================================
-- MIGRACIÓN 096
-- 1) Candado real: cada franja nueva debe empezar EXACTAMENTE
--    donde terminó la anterior (encadenamiento estricto) — así
--    es imposible guardar un hueco o un traslape, no solo
--    advertirlo visualmente. El mensaje de error indica el valor
--    exacto que debió usarse.
-- 2) Función para heredar de un jalón las franjas desde las
--    categorías estándar de caballeros (que ya son contiguas,
--    sin huecos, con su marca correspondiente) — el organizador
--    parte de ahí y solo edita si quiere variaciones.
-- =========================================================

create or replace function validar_franja_handicap_continua()
returns trigger as $$
declare
  v_max_hasta          numeric(4,1);
  v_hay_franja_abierta boolean;
begin
  select max(handicap_hasta), bool_or(handicap_hasta is null)
    into v_max_hasta, v_hay_franja_abierta
    from tournament_franjas_handicap
   where tournament_id = new.tournament_id
     and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid);

  if v_hay_franja_abierta then
    raise exception 'Ya existe una franja sin tope superior ("y más") para este torneo — no se puede agregar otra después de esa. Bórrala o edítala primero.';
  end if;

  if v_max_hasta is not null and new.handicap_desde <> round(v_max_hasta + 0.1, 1) then
    raise exception 'Hueco o traslape detectado: la franja anterior termina en %, así que la siguiente debe empezar exactamente en % (no en %).',
      v_max_hasta, round(v_max_hasta + 0.1, 1), new.handicap_desde;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validar_franja_handicap_continua
before insert or update on tournament_franjas_handicap
for each row execute function validar_franja_handicap_continua();

comment on function validar_franja_handicap_continua is 'Impide huecos o traslapes entre franjas de un mismo torneo, exigiendo que cada franja nueva empiece exactamente donde terminó la anterior.';

create or replace function heredar_franjas_desde_categorias(p_tournament_id uuid)
returns void
security definer
set search_path = public
as $$
declare
  v_autorizado boolean;
  v_existentes integer;
begin
  v_autorizado := is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), p_tournament_id)
    or exists (select 1 from tournaments t where t.id = p_tournament_id and is_club_admin(auth.uid(), t.club_id));

  if not v_autorizado then
    raise exception 'No tienes permiso para configurar franjas de este torneo.';
  end if;

  select count(*) into v_existentes from tournament_franjas_handicap where tournament_id = p_tournament_id;
  if v_existentes > 0 then
    raise exception 'Este torneo ya tiene franjas configuradas — bórralas primero si quieres volver a heredar desde cero.';
  end if;

  insert into tournament_franjas_handicap (tournament_id, handicap_desde, handicap_hasta, categoria_estandar, created_by)
  select
    p_tournament_id,
    c.handicap_minimo,
    c.handicap_maximo,
    c.categoria_estandar_marca,
    (select id from admin_users where auth_user_id = auth.uid())
  from categories c
  where c.categoria_estandar_marca is not null
    and c.handicap_minimo is not null
    and c.codigo not like 'DAMAS%'
  order by c.handicap_minimo;
end;
$$ language plpgsql;

comment on function heredar_franjas_desde_categorias is 'Crea de un jalón las franjas de hándicap de un torneo de categoría única, copiando los rangos y marcas de las categorías estándar de caballeros (ya contiguas por diseño, excluye Damas). El organizador puede editar/agregar/borrar después.';

grant execute on function heredar_franjas_desde_categorias(uuid) to authenticated;
