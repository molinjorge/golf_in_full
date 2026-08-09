-- 121_resumen_apoyo_por_tipo.sql
--
-- Vista calculada (mismo criterio de seguridad que 120: security_invoker = true
-- obligatorio) que agrupa patrocinador_tipos_apoyo por tipo de apoyo, dentro de cada
-- torneo — alimenta la gráfica de pay del "Panorama de patrocinios": tamaño de cada
-- rebanada = % del total_valorado sobre el total general del torneo (confirmado con
-- el usuario: por valor monetario, no por número de patrocinadores).

create or replace view resumen_apoyo_por_tipo_patrocinador
with (security_invoker = true)
as
select
  p.tournament_id,
  ta.id as tipo_apoyo_id,
  ta.nombre as tipo_apoyo_nombre,
  coalesce(sum(pta.monto), 0)::numeric as total_valorado,
  count(distinct pta.patrocinador_id) as num_patrocinadores
from patrocinador_tipos_apoyo pta
join patrocinadores p on p.id = pta.patrocinador_id
join tipos_apoyo_patrocinio ta on ta.id = pta.tipo_apoyo_id
group by p.tournament_id, ta.id, ta.nombre;

grant select on resumen_apoyo_por_tipo_patrocinador to authenticated;
grant all on resumen_apoyo_por_tipo_patrocinador to service_role;
