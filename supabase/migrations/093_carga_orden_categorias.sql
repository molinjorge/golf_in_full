-- =========================================================
-- MIGRACIÓN 093
-- Carga el orden de presentación confirmado: caballeros primero
-- (Scratch, Premier, AA, A, B, C, D, Senior 1, Senior 2, Abierta),
-- luego damas (Damas 1, Damas 2), y Única al final.
-- =========================================================

update categories set display_order = 1  where codigo = 'SCRATCH';
update categories set display_order = 2  where codigo = 'PREMIER';
update categories set display_order = 3  where codigo = 'AA';
update categories set display_order = 4  where codigo = 'A';
update categories set display_order = 5  where codigo = 'B';
update categories set display_order = 6  where codigo = 'C';
update categories set display_order = 7  where codigo = 'D';
update categories set display_order = 8  where codigo = 'SENIOR1';
update categories set display_order = 9  where codigo = 'SENIOR2';
update categories set display_order = 10 where codigo = 'ABIERTA';
update categories set display_order = 11 where codigo = 'DAMAS1';
update categories set display_order = 12 where codigo = 'DAMAS2';
update categories set display_order = 13 where codigo = 'UNICA';

-- Verificación: confirma que las 13 quedaron numeradas, en orden
select codigo, nombre, display_order
  from categories
 order by display_order;
