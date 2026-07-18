-- =========================================================
-- MIGRACIÓN 025
-- El Course Rating y el Slope Rating se certifican por separado
-- para caballeros y damas, incluso desde la misma marca de salida
-- (estándar USGA/World Handicap System). Se reemplazan las
-- columnas únicas "rating"/"slope" por versiones separadas.
-- =========================================================

alter table marcas_salida rename column rating to rating_caballeros;
alter table marcas_salida rename column slope to slope_caballeros;

alter table marcas_salida
  add column rating_damas numeric(4,1),
  add column slope_damas  integer;

alter table marcas_salida
  add constraint marcas_salida_slope_damas_valido
  check (slope_damas is null or slope_damas between 55 and 155);

comment on column marcas_salida.rating_caballeros is 'Course Rating oficial para caballeros, desde esta marca de salida.';
comment on column marcas_salida.slope_caballeros is 'Slope Rating oficial para caballeros, desde esta marca de salida.';
comment on column marcas_salida.rating_damas is 'Course Rating oficial para damas, desde esta marca de salida.';
comment on column marcas_salida.slope_damas is 'Slope Rating oficial para damas, desde esta marca de salida.';
