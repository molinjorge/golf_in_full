-- =========================================================
-- MIGRACIÓN 019
-- Agrega criterios de elegibilidad a categories: rango de edad
-- y rango de hándicap, ambos opcionales de forma independiente
-- (una categoría puede usar uno, el otro, ambos, o ninguno).
-- =========================================================

alter table categories
  add column edad_minima      integer,
  add column edad_maxima      integer,
  add column handicap_minimo  numeric(4,1),
  add column handicap_maximo  numeric(4,1);

alter table categories
  add constraint categories_edad_valida
  check (edad_minima is null or edad_maxima is null or edad_maxima >= edad_minima);

alter table categories
  add constraint categories_edad_no_negativa
  check (edad_minima is null or edad_minima >= 0);

alter table categories
  add constraint categories_handicap_valido
  check (handicap_minimo is null or handicap_maximo is null or handicap_maximo >= handicap_minimo);

alter table categories
  add constraint categories_handicap_rango_razonable
  check (
    (handicap_minimo is null or handicap_minimo between -10 and 54)
    and (handicap_maximo is null or handicap_maximo between -10 and 54)
  );

comment on column categories.edad_minima is 'Edad mínima requerida, si aplica. Null = sin restricción de edad.';
comment on column categories.edad_maxima is 'Edad máxima permitida, si aplica. Null = sin restricción de edad.';
comment on column categories.handicap_minimo is 'Índice de hándicap mínimo requerido, si aplica. Null = sin restricción de hándicap.';
comment on column categories.handicap_maximo is 'Índice de hándicap máximo permitido, si aplica. Null = sin restricción de hándicap.';
