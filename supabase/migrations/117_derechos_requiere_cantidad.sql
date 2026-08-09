-- 117_derechos_requiere_cantidad.sql
--
-- Bug de diseño detectado por el usuario: derechos_patrocinador (115) no tenía forma de
-- declarar si un derecho es cuantificable (ej. "Jugadores cortesía", "Comida de
-- premiación") o simple sí/no (ej. "Imagen en campo") — sin este dato, el frontend
-- tendría que hardcodear por NOMBRE cuáles derechos muestran el campo de cantidad,
-- rompiéndose cada vez que alguien agregue un derecho cuantificable nuevo al catálogo.
--
-- Fix: el catálogo mismo declara su propio comportamiento — al crear un derecho, el
-- admin marca si requiere cantidad. El frontend solo pregunta ese campo, sin conocer
-- nombres específicos.

alter table derechos_patrocinador
  add column requiere_cantidad boolean not null default false;
