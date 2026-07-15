# Migraciones de base de datos — Court Connect / Golf In Full

Este repositorio documenta el esquema de base de datos (Supabase/PostgreSQL) de la plataforma multi-club / multi-torneo de golf.

**Proyecto de Supabase:** `GOLFING_FULL`
**Cómo se aplican:** actualmente, cada migración se ejecuta manualmente en el **SQL Editor** de Supabase, en el orden numerado. Estos archivos son el registro histórico versionado de esos cambios — Supabase es siempre la fuente de la verdad del esquema en vivo; este repo es el historial y respaldo del SQL.

## Orden de aplicación

Las migraciones **deben correrse en este orden exacto** — cada una depende de que la(s) anterior(es) ya se hayan ejecutado.

| # | Archivo | Qué hace |
|---|---|---|
| 001 | `001_players_table.sql` | Tabla maestra `players` (jugadores): identificación, contacto, hándicap declarado/verificado. |
| 002 | `002_parametros_admin_users.sql` | Tabla `system_parameters` (parámetros configurables del sistema) y primera versión de `admin_users` (administradores/organizadores). |
| 003 | `003_roles_y_asignaciones.sql` | Rediseño de permisos: catálogo `roles` + tabla `admin_role_assignments` (quién tiene qué rol, en qué club o torneo). Funciones auxiliares `is_superadmin`, `is_club_admin`, `is_tournament_organizer`. |
| 004 | `004_limites_permisos_auditoria.sql` | Límite de asignaciones por rol (ej. 1 club por `club_admin`), quién puede otorgar cada rol, y tabla `audit_log` (auditoría genérica de altas/cambios). |
| 005 | `005_activacion_desactivacion.sql` | Activar/desactivar personas, roles y asignaciones sin borrarlas, con registro automático de quién y cuándo. |
| 006 | `006_impedir_borrado_admin_con_historial.sql` | Blindaje: impide borrar físicamente a un administrador que ya tiene historial (asignaciones, verificaciones de hándicap); solo permite desactivarlo. |
| 007 | `007_recrear_triggers_faltantes.sql` | Corrección: recrea los 11 triggers de `players`, `admin_users`, `roles` y `admin_role_assignments` que no llegaron a crearse en las migraciones 001-005 (las funciones ya existían, pero no estaban enganchadas). Idempotente — segura de correr aunque alguno ya exista. |

## Cómo agregar una migración nueva

## Cómo agregar una migración nueva

1. Diseñar el cambio (esquema, RLS, triggers).
2. Correrlo en el SQL Editor de Supabase (proyecto `GOLFING_FULL`), confirmar que no haya errores.
3. Subir el archivo `.sql` a este repositorio, dentro de `supabase/migrations/`, con el siguiente número consecutivo (ej. `007_clubs_y_tournaments.sql`).
4. Agregar una fila a la tabla de este README.

## Entidades pendientes (no construidas todavía)

- `clubs`
- `tournaments`
- `tournament_registrations`
- Políticas RLS de `players` (pendiente de definir reglas de acceso)
