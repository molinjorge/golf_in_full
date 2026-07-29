-- =========================================================
-- MIGRACIÓN 044
-- Agrega una validación explícita de teléfono duplicado, con
-- mensaje claro para el usuario, en vez de depender del error
-- técnico genérico de la restricción UNIQUE (que sigue existiendo
-- como respaldo, por si esta validación se saltara por algún
-- camino que no pase por el trigger).
-- =========================================================

create or replace function validar_telefono_unico()
returns trigger as $$
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

create trigger trg_validar_telefono_unico
before insert or update on players
for each row execute function validar_telefono_unico();

comment on function validar_telefono_unico is 'Da un mensaje claro cuando el teléfono ya pertenece a otro jugador, en vez del error genérico de la restricción UNIQUE (que se conserva como respaldo).';
