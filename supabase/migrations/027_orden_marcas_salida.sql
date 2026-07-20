-- =========================================================
-- MIGRACIÓN 027 (v2 — orden automático, no manual)
-- En vez de un número libre que cada admin captura a mano,
-- se elige una categoría estándar (de una lista fija y
-- universal), y el orden de despliegue se CALCULA SOLO a
-- partir de esa categoría. El estándar queda escrito una sola
-- vez en el sistema, nunca se vuelve a capturar por campo.
-- =========================================================

create type categoria_marca_salida as enum (
  'championship',   -- Negras / Tips — máxima distancia
  'azul',
  'blanco',
  'dorado',         -- Doradas / Amarillas
  'rojo',
  'otro'            -- para marcas no estándar (ej. "Verdes" de socios)
);

alter table marcas_salida
  add column categoria_estandar categoria_marca_salida not null default 'otro';

alter table marcas_salida
  add column orden_visualizacion integer generated always as (
    case categoria_estandar
      when 'championship' then 1
      when 'azul'         then 2
      when 'blanco'       then 3
      when 'dorado'       then 4
      when 'rojo'         then 5
      else 99
    end
  ) stored;

comment on column marcas_salida.categoria_estandar is 'Categoría universal de la marca (Championship/Azul/Blanco/Dorado/Rojo/Otro). El nombre visible (columna "nombre") puede variar por campo, pero esta categoría es fija y estandarizada.';
comment on column marcas_salida.orden_visualizacion is 'Calculado automáticamente a partir de categoria_estandar. No se captura manualmente — 1=Championship (más difícil) a 5=Rojo, 99=Otro (al final).';
