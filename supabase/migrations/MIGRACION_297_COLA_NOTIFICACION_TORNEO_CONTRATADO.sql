-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 297
-- Cola/auditoría de notificación administrativa por torneo contratado
--
-- Objetivo:
--   Registrar de forma durable e idempotente la notificación administrativa
--   cuando una contratación pagada crea correctamente un torneo.
--
-- Principios:
--   - El envío real de correo NO forma parte de la transacción de pago.
--   - Un fallo externo de correo nunca debe revertir un pago ni la creación.
--   - Se usa platform_commercial_settings.notification_email.
--   - Si aún no hay correo configurado, el evento queda
--     PENDIENTE_CONFIGURACION.
--   - Una contratación genera como máximo un evento TORNEO_CONTRATADO.
-- ============================================================================

begin;

create table public.platform_commercial_notifications (
    id uuid primary key default gen_random_uuid(),

    event_type text not null,
    contract_id uuid not null
        references public.platform_tournament_contracts(id),
    tournament_id uuid not null
        references public.tournaments(id),

    recipient_email text null,

    notification_status text not null,
    subject_snapshot text not null,
    payload jsonb not null default '{}'::jsonb,

    created_at timestamptz not null default now(),
    ready_at timestamptz null,
    sent_at timestamptz null,
    failed_at timestamptz null,
    error_detail text null,
    updated_at timestamptz not null default now(),

    constraint platform_commercial_notifications_event_ck
        check (event_type in ('TORNEO_CONTRATADO')),

    constraint platform_commercial_notifications_status_ck
        check (
            notification_status in (
                'PENDIENTE_CONFIGURACION',
                'PENDIENTE_ENVIO',
                'ENVIADA',
                'ERROR'
            )
        ),

    constraint platform_commercial_notifications_email_ck
        check (
            recipient_email is null
            or (
                position('@' in recipient_email) > 1
                and length(btrim(recipient_email)) >= 5
            )
        ),

    constraint platform_commercial_notifications_contract_event_uq
        unique (contract_id, event_type)
);

create index platform_commercial_notifications_status_idx
    on public.platform_commercial_notifications(
        notification_status,
        created_at
    );

create index platform_commercial_notifications_tournament_idx
    on public.platform_commercial_notifications(tournament_id);

create trigger trg_platform_commercial_notifications_updated_at
before update on public.platform_commercial_notifications
for each row
execute function public.set_updated_at();

alter table public.platform_commercial_notifications enable row level security;

create policy platform_commercial_notifications_select_superadmin
on public.platform_commercial_notifications
for select
to authenticated
using (public.is_superadmin(auth.uid()));

create policy platform_commercial_notifications_write_superadmin
on public.platform_commercial_notifications
for all
to authenticated
using (public.is_superadmin(auth.uid()))
with check (public.is_superadmin(auth.uid()));

revoke all on table public.platform_commercial_notifications from anon;
revoke insert, update, delete on table public.platform_commercial_notifications
from authenticated;
grant select on table public.platform_commercial_notifications to authenticated;
grant all on table public.platform_commercial_notifications to service_role;

-- --------------------------------------------------------------------------
-- Registrar notificación al quedar una contratación PAGADA con torneo.
-- Se ejecuta después del UPDATE definitivo realizado por la Migración 292.
-- --------------------------------------------------------------------------

create or replace function public._registrar_notificacion_torneo_contratado_297()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_notification_email text;
    v_status text;
    v_subject text;
begin
    if new.contract_status = 'PAGADO'
       and new.tournament_id is not null
       and (
            old.contract_status is distinct from new.contract_status
            or old.tournament_id is distinct from new.tournament_id
       )
    then
        select nullif(lower(btrim(s.notification_email)), '')
          into v_notification_email
          from public.platform_commercial_settings s
         where s.id = 1;

        if v_notification_email is null then
            v_status := 'PENDIENTE_CONFIGURACION';
        else
            v_status := 'PENDIENTE_ENVIO';
        end if;

        v_subject :=
            'TEE CENTRAL - Nuevo torneo contratado: '
            || new.proposed_tournament_name;

        insert into public.platform_commercial_notifications (
            event_type,
            contract_id,
            tournament_id,
            recipient_email,
            notification_status,
            subject_snapshot,
            payload,
            ready_at
        )
        values (
            'TORNEO_CONTRATADO',
            new.id,
            new.tournament_id,
            v_notification_email,
            v_status,
            v_subject,
            jsonb_build_object(
                'contractId', new.id,
                'tournamentId', new.tournament_id,
                'tournamentName', new.proposed_tournament_name,
                'startDate', new.proposed_start_date,
                'endDate', new.proposed_end_date,
                'organizerAdminUserId', new.organizer_admin_user_id,
                'organizerEmail', new.organizer_email,
                'tariffCode', new.tariff_code_snapshot,
                'tariffType', new.tariff_type_snapshot,
                'subtotal', new.subtotal,
                'vatRate', new.vat_rate,
                'vatAmount', new.vat_amount,
                'totalAmount', new.total_amount,
                'currency', new.currency,
                'paidContractStatus', new.contract_status,
                'registeredAt', now()
            ),
            case
                when v_notification_email is not null then now()
                else null
            end
        )
        on conflict (contract_id, event_type) do nothing;
    end if;

    return new;
end;
$function$;

drop trigger if exists trg_registrar_notificacion_torneo_contratado_297
on public.platform_tournament_contracts;

create trigger trg_registrar_notificacion_torneo_contratado_297
after update of contract_status, tournament_id
on public.platform_tournament_contracts
for each row
execute function public._registrar_notificacion_torneo_contratado_297();

-- --------------------------------------------------------------------------
-- Cuando se configure por primera vez el correo administrativo, preparar
-- eventos que habían quedado pendientes de configuración.
-- No envía correo: sólo los deja disponibles para el futuro worker.
-- --------------------------------------------------------------------------

create or replace function public._activar_notificaciones_pendientes_297()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_email text;
begin
    v_email := nullif(lower(btrim(new.notification_email)), '');

    if v_email is not null
       and old.notification_email is distinct from new.notification_email
    then
        update public.platform_commercial_notifications
           set recipient_email = v_email,
               notification_status = 'PENDIENTE_ENVIO',
               ready_at = coalesce(ready_at, now()),
               error_detail = null
         where notification_status = 'PENDIENTE_CONFIGURACION';
    end if;

    return new;
end;
$function$;

drop trigger if exists trg_activar_notificaciones_pendientes_297
on public.platform_commercial_settings;

create trigger trg_activar_notificaciones_pendientes_297
after update of notification_email
on public.platform_commercial_settings
for each row
execute function public._activar_notificaciones_pendientes_297();

-- --------------------------------------------------------------------------
-- Backfill idempotente por si ya existiera una contratación pagada con torneo.
-- --------------------------------------------------------------------------

insert into public.platform_commercial_notifications (
    event_type,
    contract_id,
    tournament_id,
    recipient_email,
    notification_status,
    subject_snapshot,
    payload,
    ready_at
)
select
    'TORNEO_CONTRATADO',
    c.id,
    c.tournament_id,
    nullif(lower(btrim(s.notification_email)), ''),
    case
        when nullif(lower(btrim(s.notification_email)), '') is null
            then 'PENDIENTE_CONFIGURACION'
        else 'PENDIENTE_ENVIO'
    end,
    'TEE CENTRAL - Nuevo torneo contratado: ' || c.proposed_tournament_name,
    jsonb_build_object(
        'contractId', c.id,
        'tournamentId', c.tournament_id,
        'tournamentName', c.proposed_tournament_name,
        'startDate', c.proposed_start_date,
        'endDate', c.proposed_end_date,
        'organizerAdminUserId', c.organizer_admin_user_id,
        'organizerEmail', c.organizer_email,
        'tariffCode', c.tariff_code_snapshot,
        'tariffType', c.tariff_type_snapshot,
        'subtotal', c.subtotal,
        'vatRate', c.vat_rate,
        'vatAmount', c.vat_amount,
        'totalAmount', c.total_amount,
        'currency', c.currency,
        'paidContractStatus', c.contract_status,
        'registeredAt', now()
    ),
    case
        when nullif(lower(btrim(s.notification_email)), '') is not null
            then now()
        else null
    end
from public.platform_tournament_contracts c
cross join public.platform_commercial_settings s
where s.id = 1
  and c.contract_status = 'PAGADO'
  and c.tournament_id is not null
on conflict (contract_id, event_type) do nothing;

commit;
