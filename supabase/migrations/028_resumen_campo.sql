-- =========================================================
-- MIGRACIÓN 028
-- Vistas de resumen para la tarjeta "Resumen del campo":
-- cantidad de hoyos por par, y yardaje total por marca de salida.
-- =========================================================

create view resumen_par_por_campo
with (security_invoker = true) as
select
  campo_golf_id,
  par,
  count(*) as cantidad_hoyos
from hoyos
group by campo_golf_id, par
order by campo_golf_id, par;

comment on view resumen_par_por_campo is 'Cuántos hoyos de cada par (3/4/5) tiene cada campo.';

create view resumen_yardaje_por_marca
with (security_invoker = true) as
select
  m.campo_golf_id,
  m.id as marca_salida_id,
  m.nombre,
  m.categoria_estandar,
  m.orden_visualizacion,
  m.color_hex,
  sum(dh.distancia_yardas) as yardaje_total,
  count(dh.id) as hoyos_con_distancia
from marcas_salida m
left join distancias_hoyo dh on dh.marca_salida_id = m.id
group by m.campo_golf_id, m.id, m.nombre, m.categoria_estandar, m.orden_visualizacion, m.color_hex
order by m.campo_golf_id, m.orden_visualizacion;

comment on view resumen_yardaje_por_marca is 'Yardaje total (suma de los 18 hoyos) por cada marca de salida, ya en el orden estándar. hoyos_con_distancia < numero_hoyos del campo indica captura incompleta.';

grant select on resumen_par_por_campo to anon, authenticated;
grant select on resumen_yardaje_por_marca to anon, authenticated;
