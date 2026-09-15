-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 316 - BEST BALL F2
-- Snapshot oficial de tarjeta TEAM e integrantes con HCP individual por ronda
--
-- ALCANCE:
--   * Crea infraestructura PROPIA de Best Ball.
--   * NO activa Best Ball en el registry.
--   * NO modifica Stroke Play, Stableford ni A-Go-Go/team_stroke.
--   * NO crea captura digital/fisica, conciliacion ni resultados.
--   * NO modifica el freeze: el core vigente ya genera HCP individual por ronda
--     para cualquier modalidad excepto equipo + team_stroke.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1. Snapshot cabecera de la tarjeta TEAM Best Ball
-- --------------------------------------------------------------------------
CREATE TABLE public.tournament_best_ball_scorecard_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    score_card_id uuid NOT NULL
        REFERENCES public.tournament_score_cards(id) ON DELETE RESTRICT,

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id) ON DELETE RESTRICT,

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id) ON DELETE RESTRICT,

    tournament_team_id uuid NOT NULL
        REFERENCES public.tournament_teams(id) ON DELETE RESTRICT,

    team_name text NOT NULL,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_best_ball_scorecard_snapshots_score_card_uk
        UNIQUE (score_card_id),

    CONSTRAINT tournament_best_ball_scorecard_snapshots_team_name_ck
        CHECK (length(btrim(team_name)) > 0)
);

CREATE INDEX tournament_best_ball_scorecard_snapshots_round_idx
    ON public.tournament_best_ball_scorecard_snapshots(tournament_round_id);

CREATE INDEX tournament_best_ball_scorecard_snapshots_team_idx
    ON public.tournament_best_ball_scorecard_snapshots(tournament_team_id);

-- --------------------------------------------------------------------------
-- 2. Integrantes congelados de la tarjeta Best Ball
--    Cada integrante apunta al HCP individual YA congelado para esa ronda.
-- --------------------------------------------------------------------------
CREATE TABLE public.tournament_best_ball_scorecard_members (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    best_ball_scorecard_snapshot_id uuid NOT NULL
        REFERENCES public.tournament_best_ball_scorecard_snapshots(id)
        ON DELETE RESTRICT,

    tournament_registration_id uuid NOT NULL
        REFERENCES public.tournament_registrations(id) ON DELETE RESTRICT,

    player_id uuid NOT NULL
        REFERENCES public.players(id) ON DELETE RESTRICT,

    round_handicap_snapshot_id uuid NOT NULL
        REFERENCES public.tournament_round_handicap_snapshots(id)
        ON DELETE RESTRICT,

    member_order smallint NOT NULL,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tournament_best_ball_scorecard_members_order_ck
        CHECK (member_order > 0),

    CONSTRAINT tournament_best_ball_scorecard_members_registration_uk
        UNIQUE (best_ball_scorecard_snapshot_id, tournament_registration_id),

    CONSTRAINT tournament_best_ball_scorecard_members_player_uk
        UNIQUE (best_ball_scorecard_snapshot_id, player_id),

    CONSTRAINT tournament_best_ball_scorecard_members_order_uk
        UNIQUE (best_ball_scorecard_snapshot_id, member_order)
);

CREATE INDEX tournament_best_ball_scorecard_members_rhs_idx
    ON public.tournament_best_ball_scorecard_members(round_handicap_snapshot_id);

CREATE INDEX tournament_best_ball_scorecard_members_player_idx
    ON public.tournament_best_ball_scorecard_members(player_id);

-- --------------------------------------------------------------------------
-- 3. Validador de cabecera
--    Impide asociar el snapshot Best Ball a una tarjeta que no sea TEAM,
--    que pertenezca a otro torneo/ronda/equipo o cuyo engine no sea best_ball.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._validar_snapshot_best_ball_316()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx record;
BEGIN
    SELECT
        sc.tournament_id,
        sc.tournament_round_id,
        sc.tournament_team_id,
        sc.unit_type,
        sc.status AS score_card_status,
        v.participation_type,
        v.scoring_engine,
        tt.tournament_id AS team_tournament_id,
        tt.activo AS team_active
      INTO v_ctx
      FROM public.tournament_score_cards sc
      JOIN public.tournament_round_start_validations v
        ON v.id = sc.validation_id
      JOIN public.tournament_teams tt
        ON tt.id = sc.tournament_team_id
     WHERE sc.id = NEW.score_card_id
     LIMIT 1;

    IF v_ctx.tournament_id IS NULL THEN
        RAISE EXCEPTION
            'La tarjeta indicada no existe o no tiene contexto TEAM valido.'
            USING ERRCODE = '23514';
    END IF;

    IF v_ctx.unit_type IS DISTINCT FROM 'team'
       OR v_ctx.tournament_team_id IS NULL
       OR v_ctx.score_card_status IS DISTINCT FROM 'issued'
       OR v_ctx.participation_type IS DISTINCT FROM 'equipo'
       OR v_ctx.scoring_engine IS DISTINCT FROM 'best_ball'
    THEN
        RAISE EXCEPTION
            'El snapshot Best Ball solo puede vincularse a una tarjeta TEAM emitida de engine best_ball.'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.tournament_id IS DISTINCT FROM v_ctx.tournament_id
       OR NEW.tournament_round_id IS DISTINCT FROM v_ctx.tournament_round_id
       OR NEW.tournament_team_id IS DISTINCT FROM v_ctx.tournament_team_id
       OR v_ctx.team_tournament_id IS DISTINCT FROM v_ctx.tournament_id
       OR NOT COALESCE(v_ctx.team_active, false)
    THEN
        RAISE EXCEPTION
            'El snapshot Best Ball no coincide con torneo, ronda o equipo de la tarjeta oficial.'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_validar_snapshot_best_ball_316
BEFORE INSERT OR UPDATE
ON public.tournament_best_ball_scorecard_snapshots
FOR EACH ROW
EXECUTE FUNCTION public._validar_snapshot_best_ball_316();

-- --------------------------------------------------------------------------
-- 4. Validador de integrante
--    Garantiza simultaneamente:
--      * inscripcion activa del mismo torneo y equipo,
--      * player_id de esa inscripcion,
--      * HCP individual congelado de ESA ronda,
--      * mismo round_condition_snapshot de la validacion oficial.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._validar_miembro_snapshot_best_ball_316()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx record;
BEGIN
    SELECT
        ss.tournament_id,
        ss.tournament_round_id,
        ss.tournament_team_id,
        sc.validation_id,
        v.round_condition_snapshot_id,

        reg.tournament_id AS registration_tournament_id,
        reg.tournament_team_id AS registration_team_id,
        reg.player_id AS registration_player_id,
        reg.activo AS registration_active,

        p.activo AS player_active,

        rhs.tournament_id AS rhs_tournament_id,
        rhs.tournament_round_id AS rhs_round_id,
        rhs.round_condition_snapshot_id AS rhs_round_condition_snapshot_id,
        rhs.tournament_registration_id AS rhs_registration_id,
        rhs.player_id AS rhs_player_id
      INTO v_ctx
      FROM public.tournament_best_ball_scorecard_snapshots ss
      JOIN public.tournament_score_cards sc
        ON sc.id = ss.score_card_id
      JOIN public.tournament_round_start_validations v
        ON v.id = sc.validation_id
      JOIN public.tournament_registrations reg
        ON reg.id = NEW.tournament_registration_id
      JOIN public.players p
        ON p.id = NEW.player_id
      JOIN public.tournament_round_handicap_snapshots rhs
        ON rhs.id = NEW.round_handicap_snapshot_id
     WHERE ss.id = NEW.best_ball_scorecard_snapshot_id
     LIMIT 1;

    IF v_ctx.tournament_id IS NULL THEN
        RAISE EXCEPTION
            'No existe contexto Best Ball completo para el integrante.'
            USING ERRCODE = '23514';
    END IF;

    IF NOT COALESCE(v_ctx.registration_active, false)
       OR NOT COALESCE(v_ctx.player_active, false)
       OR v_ctx.registration_tournament_id IS DISTINCT FROM v_ctx.tournament_id
       OR v_ctx.registration_team_id IS DISTINCT FROM v_ctx.tournament_team_id
       OR v_ctx.registration_player_id IS DISTINCT FROM NEW.player_id
    THEN
        RAISE EXCEPTION
            'El integrante no corresponde a una inscripcion activa del equipo Best Ball.'
            USING ERRCODE = '23514';
    END IF;

    IF v_ctx.rhs_tournament_id IS DISTINCT FROM v_ctx.tournament_id
       OR v_ctx.rhs_round_id IS DISTINCT FROM v_ctx.tournament_round_id
       OR v_ctx.rhs_round_condition_snapshot_id IS DISTINCT FROM
          v_ctx.round_condition_snapshot_id
       OR v_ctx.rhs_registration_id IS DISTINCT FROM NEW.tournament_registration_id
       OR v_ctx.rhs_player_id IS DISTINCT FROM NEW.player_id
    THEN
        RAISE EXCEPTION
            'El HCP individual congelado no corresponde al jugador, inscripcion o ronda Best Ball.'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_validar_miembro_snapshot_best_ball_316
BEFORE INSERT OR UPDATE
ON public.tournament_best_ball_scorecard_members
FOR EACH ROW
EXECUTE FUNCTION public._validar_miembro_snapshot_best_ball_316();

-- --------------------------------------------------------------------------
-- 5. RLS cerrado: sin acceso directo anon/authenticated.
--    Las fases operativas posteriores expondran RPC SECURITY DEFINER controladas.
-- --------------------------------------------------------------------------
ALTER TABLE public.tournament_best_ball_scorecard_snapshots
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.tournament_best_ball_scorecard_members
    ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tournament_best_ball_scorecard_snapshots
    FROM anon, authenticated;
REVOKE ALL ON TABLE public.tournament_best_ball_scorecard_members
    FROM anon, authenticated;

GRANT ALL ON TABLE public.tournament_best_ball_scorecard_snapshots
    TO service_role;
GRANT ALL ON TABLE public.tournament_best_ball_scorecard_members
    TO service_role;

COMMIT;
