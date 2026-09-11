-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 295
-- Modo sólo lectura para torneos con vigencia comercial vencida
--
-- Objetivo:
--   Hacer efectivo en backend el vencimiento definido por la Migración 294.
--
-- Alcance:
--   - Reutiliza el mismo perímetro operativo protegido por la Migración 233.
--   - Los torneos LEGACY (sin platform_tournament_access) NO se bloquean.
--   - Los torneos con vigencia vigente siguen operando normalmente.
--   - Los torneos contratados cuya vigencia ya venció conservan consulta,
--     historial y resultados, pero no admiten INSERT/UPDATE/DELETE operativos.
--
-- No afecta:
--   - tablas comerciales,
--   - catálogo de tarifas,
--   - contrataciones/pagos,
--   - usuarios,
--   - catálogos generales de golf.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- Helper común: determina si un torneo contratado está vencido.
-- LEGACY => false.
-- --------------------------------------------------------------------------

create or replace function public.torneo_esta_vencido_295(
    p_tournament_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
    select exists (
        select 1
          from public.platform_tournament_access a
         where a.tournament_id = p_tournament_id
           and current_date > a.valid_through_date
    );
$function$;

revoke all on function public.torneo_esta_vencido_295(uuid)
from public, anon;

grant execute on function public.torneo_esta_vencido_295(uuid)
to authenticated, service_role;

-- --------------------------------------------------------------------------
-- Guarda genérica para tablas con tournament_id directo.
-- --------------------------------------------------------------------------

create or replace function public._bloquear_mutacion_torneo_vencido_295()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_tournament_id uuid;
begin
    if tg_op = 'DELETE' then
        v_tournament_id := old.tournament_id;
    else
        v_tournament_id := new.tournament_id;
    end if;

    if v_tournament_id is not null
       and public.torneo_esta_vencido_295(v_tournament_id)
    then
        raise exception
            'La vigencia de plataforma del torneo terminó y ahora es de sólo lectura.'
            using errcode = '55000',
                  detail = format(
                      'tabla=%s; tournament_id=%s',
                      tg_table_name,
                      v_tournament_id
                  ),
                  hint =
                    'El historial puede consultarse, pero no admite cambios operativos.';
    end if;

    if tg_op = 'DELETE' then
        return old;
    end if;

    return new;
end;
$function$;

-- --------------------------------------------------------------------------
-- Guarda para tablas que llegan al torneo mediante score_card_id.
-- --------------------------------------------------------------------------

create or replace function public._bloquear_mutacion_scorecard_torneo_vencido_295()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_score_card_id uuid;
    v_tournament_id uuid;
begin
    if tg_op = 'DELETE' then
        v_score_card_id := old.score_card_id;
    else
        v_score_card_id := new.score_card_id;
    end if;

    select sc.tournament_id
      into v_tournament_id
      from public.tournament_score_cards sc
     where sc.id = v_score_card_id;

    if v_tournament_id is not null
       and public.torneo_esta_vencido_295(v_tournament_id)
    then
        raise exception
            'La vigencia de plataforma del torneo terminó y la tarjeta es de sólo lectura.'
            using errcode = '55000',
                  detail = format(
                      'tabla=%s; score_card_id=%s; tournament_id=%s',
                      tg_table_name,
                      v_score_card_id,
                      v_tournament_id
                  ),
                  hint =
                    'La tarjeta puede consultarse, pero no admite cambios.';
    end if;

    if tg_op = 'DELETE' then
        return old;
    end if;

    return new;
end;
$function$;

-- --------------------------------------------------------------------------
-- Guarda para tournament_team_handicap_ranges mediante config_id.
-- --------------------------------------------------------------------------

create or replace function public._bloquear_mutacion_hcp_team_range_vencido_295()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_config_id uuid;
    v_tournament_id uuid;
begin
    if tg_op = 'DELETE' then
        v_config_id := old.config_id;
    else
        v_config_id := new.config_id;
    end if;

    select c.tournament_id
      into v_tournament_id
      from public.tournament_team_handicap_configs c
     where c.id = v_config_id;

    if v_tournament_id is not null
       and public.torneo_esta_vencido_295(v_tournament_id)
    then
        raise exception
            'La vigencia de plataforma del torneo terminó y no admite cambios en rangos HCP TEAM.'
            using errcode = '55000',
                  detail = format(
                      'config_id=%s; tournament_id=%s',
                      v_config_id,
                      v_tournament_id
                  );
    end if;

    if tg_op = 'DELETE' then
        return old;
    end if;

    return new;
end;
$function$;

-- --------------------------------------------------------------------------
-- Guarda para la propia fila de tournaments.
-- Usa OLD.id para impedir cualquier UPDATE/DELETE posterior al vencimiento.
-- INSERT nunca se bloquea aquí.
-- --------------------------------------------------------------------------

create or replace function public._bloquear_torneo_vencido_295()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
    if tg_op in ('UPDATE','DELETE')
       and public.torneo_esta_vencido_295(old.id)
    then
        raise exception
            'La vigencia de plataforma del torneo terminó y el torneo es de sólo lectura.'
            using errcode = '55000',
                  hint =
                    'El torneo y su historial permanecen disponibles para consulta.';
    end if;

    if tg_op = 'DELETE' then
        return old;
    end if;

    return new;
end;
$function$;

-- ============================================================================
-- Triggers: mismo perímetro operativo de la Migración 233
-- ============================================================================

-- Tablas con tournament_id directo
do $$
declare
    v_table text;
    v_tables text[] := array[
        'tournament_categories',
        'tournament_category_classifications',
        'tournament_registrations',
        'tournament_round_start_validations',
        'tournament_rounds',
        'tournament_score_card_emissions',
        'tournament_score_cards',
        'tournament_scorecard_capture_sessions',
        'tournament_scorecard_physical_receptions',
        'tournament_scorecard_reconciliations',
        'tournament_scorecard_round_outcomes',
        'tournament_stableford_special_rules',
        'tournament_team_handicap_configs',
        'tournament_team_roster_slots',
        'tournament_team_substitution_requests',
        'tournament_teams',
        'tournament_tiebreak_rules'
    ];
begin
    foreach v_table in array v_tables
    loop
        execute format(
            'drop trigger if exists trg_vencido_295 on public.%I',
            v_table
        );

        execute format(
            'create trigger trg_vencido_295
             before insert or update or delete on public.%I
             for each row
             execute function public._bloquear_mutacion_torneo_vencido_295()',
            v_table
        );
    end loop;
end $$;

-- Tablas ligadas por score_card_id
drop trigger if exists trg_vencido_295
on public.tournament_scorecard_hole_scores;

create trigger trg_vencido_295
before insert or update or delete
on public.tournament_scorecard_hole_scores
for each row
execute function public._bloquear_mutacion_scorecard_torneo_vencido_295();

drop trigger if exists trg_vencido_295
on public.tournament_scorecard_physical_hole_scores;

create trigger trg_vencido_295
before insert or update or delete
on public.tournament_scorecard_physical_hole_scores
for each row
execute function public._bloquear_mutacion_scorecard_torneo_vencido_295();

-- Rango HCP TEAM ligado por config_id
drop trigger if exists trg_vencido_295
on public.tournament_team_handicap_ranges;

create trigger trg_vencido_295
before insert or update or delete
on public.tournament_team_handicap_ranges
for each row
execute function public._bloquear_mutacion_hcp_team_range_vencido_295();

-- Fila principal del torneo
drop trigger if exists trg_vencido_295
on public.tournaments;

create trigger trg_vencido_295
before update or delete
on public.tournaments
for each row
execute function public._bloquear_torneo_vencido_295();

commit;
