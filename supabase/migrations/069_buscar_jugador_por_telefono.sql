-- =========================================================
-- MIGRACIÓN 069
-- Búsqueda acotada de jugador por teléfono — para que un
-- administrador (organizador incluido) pueda confirmar "¿esta
-- persona ya existe en el catálogo?" sin poder navegar el
-- catálogo completo (que sigue restringido desde la 058 para
-- tournament_organizer).
-- =========================================================

create or replace function buscar_jugador_por_telefono(
  p_telefono_pais   text,
  p_telefono_lada   text,
  p_telefono_numero text
)
returns table (id uuid, nombres text, apellidos text)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.nombres, p.apellidos
    from players p
   where p.telefono_pais = p_telefono_pais
     and p.telefono_lada = p_telefono_lada
     and p.telefono_numero = p_telefono_numero
     and p.activo = true
   limit 1;
$$;

comment on function buscar_jugador_por_telefono is 'Búsqueda acotada: solo confirma existencia + nombre de un jugador por teléfono exacto. No da acceso a navegar el catálogo completo — usado por organizadores para pre-reservas telefónicas.';

grant execute on function buscar_jugador_por_telefono(text, text, text) to authenticated;
