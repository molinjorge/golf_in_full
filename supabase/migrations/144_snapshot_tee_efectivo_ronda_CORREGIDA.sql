-- ============================================================================
-- MIGRACIÓN 144 — CORREGIDA
-- SNAPSHOT COMPLEMENTARIO DEL NOMBRE Y COLOR DEL TEE EFECTIVO DE RONDA
--
-- MOTIVO DE LA CORRECCIÓN
-- La primera versión intentaba hacer UPDATE sobre
-- tournament_round_handicap_snapshots para backfill.
-- Esa tabla está protegida por inmutabilidad y correctamente rechazó la operación
-- con SQLSTATE 55000.
--
-- SOLUCIÓN
-- NO se modifica ningún snapshot congelado existente.
-- Se crea una tabla complementaria append-only, 1:1 con
-- tournament_round_handicap_snapshots, que guarda:
--   - tee_id
--   - tee_name
--   - tee_color_hex
--
-- Para snapshots existentes se INSERTA una fila complementaria usando el catálogo
-- ACTUAL de marcas_salida.
-- Para snapshots futuros, un trigger AFTER INSERT crea automáticamente la fila
-- complementaria con nombre/color vigentes en el momento del snapshot.
--
-- IMPORTANTE
-- - NO modifica snapshots congelados.
-- - NO toca tournament_registrations.qr_token.
-- - NO toca tournament_score_cards.qr_token.
-- - NO cambia reglas de hándicap.
-- - NO modifica tarjetas ya emitidas.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Dependencias
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    v_faltantes text;
BEGIN
    WITH req(tipo, objeto) AS (
        VALUES
            ('tabla', 'public.tournament_round_handicap_snapshots'),
            ('tabla', 'public.marcas_salida')
    )
    SELECT string_agg(tipo || ': ' || objeto, E'\n' ORDER BY tipo, objeto)
      INTO v_faltantes
      FROM req
     WHERE tipo = 'tabla'
       AND to_regclass(objeto) IS NULL;

    IF v_faltantes IS NOT NULL THEN
        RAISE EXCEPTION
            'No puede ejecutarse la Migración 144. Faltan dependencias:%',
            E'\n' || v_faltantes
            USING ERRCODE = '55000';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Tabla complementaria 1:1 del tee efectivo congelado
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tournament_round_handicap_tee_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    round_handicap_snapshot_id uuid NOT NULL
        REFERENCES public.tournament_round_handicap_snapshots(id)
        ON DELETE RESTRICT,

    tee_id uuid NOT NULL
        REFERENCES public.marcas_salida(id)
        ON DELETE RESTRICT,

    tee_name text NOT NULL
        CHECK (length(btrim(tee_name)) > 0),

    tee_color_hex text
        CHECK (
            tee_color_hex IS NULL
            OR length(btrim(tee_color_hex)) > 0
        ),

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_round_handicap_tee_snapshot_uk
        UNIQUE (round_handicap_snapshot_id)
);

CREATE INDEX IF NOT EXISTS idx_round_handicap_tee_snapshots_tee
    ON public.tournament_round_handicap_tee_snapshots(tee_id);

COMMENT ON TABLE public.tournament_round_handicap_tee_snapshots IS
    'Snapshot complementario e inmutable del nombre/color del tee efectivo de una ronda. No modifica tournament_round_handicap_snapshots.';

COMMENT ON COLUMN public.tournament_round_handicap_tee_snapshots.round_handicap_snapshot_id IS
    'Snapshot de hándicap por ronda al que pertenece este tee efectivo congelado. Relación 1:1.';

COMMENT ON COLUMN public.tournament_round_handicap_tee_snapshots.tee_name IS
    'Nombre de la marca de salida vigente al momento de crear este snapshot complementario.';

COMMENT ON COLUMN public.tournament_round_handicap_tee_snapshots.tee_color_hex IS
    'Color hexadecimal de la marca de salida vigente al momento de crear este snapshot complementario.';

-- ---------------------------------------------------------------------------
-- 3. RLS: sin escritura directa de clientes.
-- La lectura frontend directa no es necesaria todavía; el payload oficial posterior
-- podrá exponerse mediante una RPC de lectura.
-- ---------------------------------------------------------------------------

ALTER TABLE public.tournament_round_handicap_tee_snapshots
    ENABLE ROW LEVEL SECURITY;

REVOKE ALL
ON TABLE public.tournament_round_handicap_tee_snapshots
FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Inmutabilidad de la tabla complementaria
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._impedir_mutacion_round_handicap_tee_snapshot()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION
        'Los snapshots complementarios de tee son inmutables.'
        USING ERRCODE = '55000',
              HINT = 'No edite ni elimine snapshots históricos.';
END;
$$;

DROP TRIGGER IF EXISTS trg_impedir_mutacion_round_handicap_tee_snapshot
    ON public.tournament_round_handicap_tee_snapshots;

CREATE TRIGGER trg_impedir_mutacion_round_handicap_tee_snapshot
BEFORE UPDATE OR DELETE
ON public.tournament_round_handicap_tee_snapshots
FOR EACH ROW
EXECUTE FUNCTION public._impedir_mutacion_round_handicap_tee_snapshot();

-- ---------------------------------------------------------------------------
-- 5. Backfill histórico SIN UPDATE de snapshots congelados
--
-- Advertencia:
-- para snapshots existentes se usa el catálogo ACTUAL de marcas_salida.
-- Si nombre/color cambió antes de esta migración, ese valor anterior no puede
-- reconstruirse retrospectivamente.
-- ---------------------------------------------------------------------------

INSERT INTO public.tournament_round_handicap_tee_snapshots (
    round_handicap_snapshot_id,
    tee_id,
    tee_name,
    tee_color_hex
)
SELECT
    rhs.id,
    rhs.tee_id,
    ms.nombre,
    ms.color_hex
FROM public.tournament_round_handicap_snapshots rhs
JOIN public.marcas_salida ms
  ON ms.id = rhs.tee_id
WHERE rhs.tee_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM public.tournament_round_handicap_tee_snapshots ts
      WHERE ts.round_handicap_snapshot_id = rhs.id
  );

-- ---------------------------------------------------------------------------
-- 6. Trigger para snapshots FUTUROS
-- AFTER INSERT: no altera NEW ni hace UPDATE sobre el snapshot principal.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._crear_snapshot_tee_efectivo_ronda()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tee_name text;
    v_tee_color_hex text;
BEGIN
    IF NEW.tee_id IS NULL THEN
        RAISE EXCEPTION
            'No es posible congelar el tee efectivo de la ronda: tee_id es NULL.'
            USING ERRCODE = '23514';
    END IF;

    SELECT ms.nombre, ms.color_hex
      INTO v_tee_name, v_tee_color_hex
      FROM public.marcas_salida ms
     WHERE ms.id = NEW.tee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No es posible congelar el tee efectivo de la ronda: la marca no existe.'
            USING ERRCODE = '23503',
                  DETAIL = format('tee_id=%s', NEW.tee_id);
    END IF;

    INSERT INTO public.tournament_round_handicap_tee_snapshots (
        round_handicap_snapshot_id,
        tee_id,
        tee_name,
        tee_color_hex
    )
    VALUES (
        NEW.id,
        NEW.tee_id,
        v_tee_name,
        v_tee_color_hex
    );

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_crear_snapshot_tee_efectivo_ronda
    ON public.tournament_round_handicap_snapshots;

CREATE TRIGGER trg_crear_snapshot_tee_efectivo_ronda
AFTER INSERT
ON public.tournament_round_handicap_snapshots
FOR EACH ROW
EXECUTE FUNCTION public._crear_snapshot_tee_efectivo_ronda();

-- ---------------------------------------------------------------------------
-- 7. Cerrar ejecución directa de helpers
-- ---------------------------------------------------------------------------

REVOKE ALL
ON FUNCTION public._impedir_mutacion_round_handicap_tee_snapshot()
FROM PUBLIC, anon, authenticated;

REVOKE ALL
ON FUNCTION public._crear_snapshot_tee_efectivo_ronda()
FROM PUBLIC, anon, authenticated;

COMMIT;
