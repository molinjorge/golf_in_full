-- =========================================================
-- MIGRACIÓN 045
-- validar_telefono_unico() corría con los permisos de quien
-- se registra — como un jugador normal solo puede VER su propia
-- fila (RLS), su búsqueda de duplicados nunca alcanzaba a ver
-- el teléfono de otro jugador ya existente, y dejaba pasar el
-- INSERT hasta que la restricción UNIQUE (que sí ve todo, sin
-- filtro de RLS) lo tronaba con el error técnico genérico.
-- Mismo patrón que is_superadmin(): SECURITY DEFINER.
-- =========================================================

create or replace function validar_telefono_unico()
returns trigger
security definer
set search_path = public
as $$
declare
  v_existe boolean;
begin
  select exists (
    select 1 from players
     where telefono_pais = new.telefono_pais
       and telefono_lada = new.telefono_lada
       and telefono_numero = new.telefono_numero
       and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid)
  ) into v_existe;

  if v_existe then
    raise exception 'El número de teléfono indicado está registrado por otro jugador.';
  end if;

  return new;
end;
$$ language plpgsql;
