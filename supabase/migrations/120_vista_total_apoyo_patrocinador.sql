-- 120_vista_total_apoyo_patrocinador.sql
--
-- Vista calculada (no columna guardada, a propósito): el total de apoyo valorado de
-- un patrocinador es la suma de patrocinador_tipos_apoyo.monto. Se calcula al vuelo
-- en cada consulta, nunca puede desincronizarse — mismo criterio que ya aplicamos
-- varias veces esta sesión al preferir cálculo sobre datos duplicados.

-- IMPORTANTE: security_invoker = true es OBLIGATORIO aquí. Sin esto, una vista en
-- Postgres corre con los permisos de quien la CREÓ (probablemente con privilegios
-- elevados), no de quien la consulta — lo que saltaría RLS por completo y expondría
-- todos los patrocinadores de todos los torneos a cualquier usuario autenticado.
create view patrocinadores_con_total
with (security_invoker = true)
as
select
  p.*,
  coalesce(sum(pta.monto), 0) as total_apoyo_valorado
from patrocinadores p
left join patrocinador_tipos_apoyo pta on pta.patrocinador_id = p.id
group by p.id;
