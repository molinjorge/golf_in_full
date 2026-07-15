-- =========================================================
-- MIGRACIÓN 009
-- Restringir clubs.telefono y clubs.email para que solo sean
-- visibles a usuarios autenticados (dentro de la app), no al
-- público general vía la API pública (rol anon).
--
-- RLS controla QUÉ FILAS se ven; esto controla QUÉ COLUMNAS
-- de esas filas se ven, por rol. Son mecanismos distintos y
-- se pueden combinar.
-- =========================================================

-- Le quitamos a "anon" el acceso general de SELECT sobre la tabla...
revoke select on clubs from anon;

-- ...y se lo regresamos, pero solo para las columnas que sí
-- queremos públicas (todo excepto telefono y email).
grant select (
  id,
  nombre,
  ciudad,
  estado,
  direccion,
  sitio_web,
  numero_hoyos,
  activo,
  created_by,
  created_at,
  updated_at
) on clubs to anon;

-- "authenticated" conserva acceso a la tabla completa (incluye
-- telefono y email). Ya lo tenía por los privilegios default de
-- Supabase; se deja explícito aquí por claridad documental.
grant select on clubs to authenticated;

-- Nota importante: si algún visitante sin sesión (anon) intenta
-- pedir explícitamente la columna telefono o email desde el
-- frontend, la consulta completa fallará con un error de permiso
-- (no devuelve null, rechaza la petición). El código del directorio
-- público debe pedir solo las columnas permitidas.
