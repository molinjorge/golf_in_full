-- =========================================================
-- MIGRACIÓN 039 (v2 — simplificada)
-- Solo agrega el valor faltante al enum existente. El color del
-- badge se resuelve en el frontend (mapeo fijo texto -> color),
-- no requiere ninguna tabla nueva — el conjunto de estatus es
-- fijo y no debe poder alterarse desde una pantalla.
-- =========================================================

alter type estatus_torneo add value 'inscripcion_cerrada' after 'inscripciones_abiertas';
