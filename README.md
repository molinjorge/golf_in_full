# Migraciones de base de datos â€” Court Connect / Golf In Full

Este repositorio documenta el esquema de base de datos (Supabase/PostgreSQL) de la plataforma multi-club / multi-torneo de golf.

**Proyecto de Supabase:** `GOLFING_FULL`
**CÃ³mo se aplican:** actualmente, cada migraciÃ³n se ejecuta manualmente en el **SQL Editor** de Supabase, en el orden numerado. Estos archivos son el registro histÃ³rico versionado de esos cambios â€” Supabase es siempre la fuente de la verdad del esquema en vivo; este repo es el historial y respaldo del SQL.

## Orden de aplicaciÃ³n

Las migraciones **deben correrse en este orden exacto** â€” cada una depende de que la(s) anterior(es) ya se hayan ejecutado.

| # | Archivo | QuÃ© hace |
|---|---|---|
| 001 | `001_players_table.sql` | Tabla maestra `players` (jugadores): identificaciÃ³n, contacto, hÃ¡ndicap declarado/verificado. |
| 002 | `002_parametros_admin_users.sql` | Tabla `system_parameters` (parÃ¡metros configurables del sistema) y primera versiÃ³n de `admin_users` (administradores/organizadores). |
| 003 | `003_roles_y_asignaciones.sql` | RediseÃ±o de permisos: catÃ¡logo `roles` + tabla `admin_role_assignments` (quiÃ©n tiene quÃ© rol, en quÃ© club o torneo). Funciones auxiliares `is_superadmin`, `is_club_admin`, `is_tournament_organizer`. |
| 004 | `004_limites_permisos_auditoria.sql` | LÃ­mite de asignaciones por rol (ej. 1 club por `club_admin`), quiÃ©n puede otorgar cada rol, y tabla `audit_log` (auditorÃ­a genÃ©rica de altas/cambios). |
| 005 | `005_activacion_desactivacion.sql` | Activar/desactivar personas, roles y asignaciones sin borrarlas, con registro automÃ¡tico de quiÃ©n y cuÃ¡ndo. |
| 006 | `006_impedir_borrado_admin_con_historial.sql` | Blindaje: impide borrar fÃ­sicamente a un administrador que ya tiene historial (asignaciones, verificaciones de hÃ¡ndicap); solo permite desactivarlo. |
| 007 | `007_recrear_triggers_faltantes.sql` | CorrecciÃ³n: recrea los 11 triggers de `players`, `admin_users`, `roles` y `admin_role_assignments` que no llegaron a crearse en las migraciones 001-005 (las funciones ya existÃ­an, pero no estaban enganchadas). Idempotente â€” segura de correr aunque alguno ya exista. |
| 008 | `008_clubs_y_tournaments.sql` | Tablas `clubs` y `tournaments`, con auditorÃ­a/alta-baja reutilizando las funciones genÃ©ricas ya construidas. Activa las FK `club_id`/`tournament_id` pendientes en `admin_role_assignments`. RLS: lectura pÃºblica de activos, escritura restringida por rol. |
| 009 | `009_restringir_contacto_clubs.sql` | Restringe `clubs.telefono` y `clubs.email` a usuarios autenticados (privilegios de columna); visitantes sin sesiÃ³n (`anon`) ya no pueden leer esas dos columnas vÃ­a la API pÃºblica. |
| 010 | `010_rls_players.sql` | PolÃ­ticas de RLS de `players`: un jugador solo ve/edita su propio perfil (cero visibilidad entre jugadores); cualquier administrador activo puede ver/editar cualquier perfil. Trigger que impide que un jugador se auto-verifique su propio hÃ¡ndicap. |
| 011 | `011_grants_faltantes.sql` | CorrecciÃ³n: otorga los `GRANT` de tabla faltantes en `players`, `admin_users`, `roles`, `admin_role_assignments`, `system_parameters`, `audit_log`, `clubs` y `tournaments`. Sin estos, RLS nunca llegaba a evaluarse â€” Postgres rechazaba el acceso antes. No cambia ninguna polÃ­tica ni regla de negocio. |
| 012 | `012_fix_recursion_rls.sql` | CorrecciÃ³n crÃ­tica: `is_superadmin`, `is_club_admin`, `is_tournament_organizer` e `is_active_admin` pasan a `SECURITY DEFINER` con `search_path` fijo, para romper una recursiÃ³n infinita â€” esas funciones consultan tablas cuyas propias polÃ­ticas de RLS las vuelven a llamar, causando "stack depth limit exceeded" (visible como error 500 en la API) para cualquier usuario autenticado normal. |
| 013 | `013_geografia_paises_estados_ciudades.sql` | CatÃ¡logo geogrÃ¡fico normalizado: `countries` â†’ `states` â†’ `cities`, con huso horario (IANA) a nivel ciudad. Sembrado con MÃ©xico + EE.UU., 32 estados de MÃ©xico + 51 de EE.UU., y las ~27 ciudades donde ya identificamos clubes. `clubs.city_id` agregado; `clubs.ciudad`/`clubs.estado` (texto libre) quedan obsoletos pero sin eliminar todavÃ­a. |
| 014 | `014_eliminar_ciudad_estado_texto.sql` | Elimina definitivamente `clubs.ciudad` y `clubs.estado` (texto libre) â€” la ubicaciÃ³n ya vive solo en `clubs.city_id`. |
| 015 | `015_city_id_obligatorio.sql` | Hace `clubs.city_id` obligatorio (`NOT NULL`). Se detiene con un error claro si queda algÃºn club sin ciudad asignada â€” hay que resolver esos primero. |
| 016 | `016_catalogo_husos_horarios.sql` | CatÃ¡logo curado `timezones` (etiqueta amigable + diferencia UTC), con FK real desde `cities.timezone`. Evita mostrar identificadores IANA crudos en el dropdown del frontend. |
| 017 | `017_modulos_y_licencias.sql` | CatÃ¡logo `modules` (primer mÃ³dulo: Torneos) y tabla `club_module_licenses` para controlar contrataciÃ³n (anual o por torneo), vigencia, tarifa y pago por club. Incluye `club_has_active_module()` para que el frontend consulte fÃ¡cilmente si un mÃ³dulo estÃ¡ habilitado. Fase 1: solo estructura, sin frontend todavÃ­a. |
| 018 | `018_formato_juego_y_categorias.sql` | `tournaments` gana formato de juego (individual/equipo), modalidad segÃºn formato, tamaÃ±o de equipo (2-5), y duraciÃ³n en dÃ­as calculada automÃ¡ticamente. CatÃ¡logo `categories` + relaciÃ³n muchos-a-muchos `tournament_categories` (un torneo puede tener varias categorÃ­as). |
| 019 | `019_criterios_categorias.sql` | `categories` gana rango de edad y rango de hÃ¡ndicap, ambos opcionales e independientes â€” una categorÃ­a puede usar uno, otro, ambos, o ninguno. |
| 020 | `020_vincular_jugador_preregistrado.sql` | Cuando un jugador confirma su correo al crear su cuenta, se vincula automÃ¡ticamente con su perfil pre-registrado en `players` (si un organizador ya lo habÃ­a dado de alta con ese mismo correo) â€” solo tras confirmaciÃ³n, nunca antes, para evitar suplantaciÃ³n. No crea perfiles nuevos. |
| 021 | `021_estatus_activo_players.sql` | Agrega `activo`/`fecha_baja`/`dado_de_baja_por`/`motivo_baja` a `players`. Agrega el trigger de auditorÃ­a que a `players` le faltaba desde el inicio. Solo un administrador puede activar/desactivar a un jugador â€” el jugador no puede autoreactivarse si fue dado de baja. |
| 022 | `022_vincular_jugador_en_cada_login.sql` | CorrecciÃ³n: agrega un tercer trigger que reintenta la vinculaciÃ³n de perfil pre-registrado en CADA login exitoso (`last_sign_in_at`), no solo en el momento Ãºnico de la primera confirmaciÃ³n de correo â€” cubre el caso de una cuenta ya confirmada de antes con un perfil pre-registrado mÃ¡s reciente. |
| 023 | `023_campos_golf.sql` | Nueva tabla `campos_golf`: `club_id` (un club puede operar varios campos), `nombre_oficial`, `numero_hoyos`, `timezone_id`, `latitud`/`longitud` (opcionales). `clubs` pierde `numero_hoyos`. Solo superadmin da de alta campos nuevos; club_admin puede editar los de su club. |

## CÃ³mo agregar una migraciÃ³n nueva

1. DiseÃ±ar el cambio (esquema, RLS, triggers).
2. Correrlo en el SQL Editor de Supabase (proyecto `GOLFING_FULL`), confirmar que no haya errores.
3. Subir el archivo `.sql` a este repositorio, dentro de `supabase/migrations/`, con el siguiente nÃºmero consecutivo (ej. `007_clubs_y_tournaments.sql`).
4. Agregar una fila a la tabla de este README.

## Entidades pendientes (no construidas todavÃ­a)

- `tournament_registrations`
- Tabla de contactos por Ã¡rea de cada campo de golf (Pro Shop, Starter, Renta de Carritos, Taller, Servicio en Campo/Alimentos y Bebidas) â€” fase futura, aparte de `campos_golf`
- Decidir si `tournaments.club_id` debe cambiar a `campo_golf_id` â€” ahora que un club puede tener varios campos, un torneo probablemente deberÃ­a apuntar al campo especÃ­fico donde se juega, no solo al club en general
- Marcas de salida y datos hoyo por hoyo de cada campo de golf
- Registro de jugadores por parte del organizador (Fase 2) y autoregistro del jugador (Fase 3) â€” la migraciÃ³n 020 ya deja lista la vinculaciÃ³n automÃ¡tica entre ambos flujos
- Frontend de licencias de mÃ³dulos (`club_module_licenses`) â€” la estructura ya existe (migraciÃ³n 017), falta la pantalla
- Dashboard completo para el rol `club_admin` (login, layout, navegaciÃ³n) â€” hoy solo existe el de superadmin
- Regla de RLS adicional en `players` para exponer nombre/hÃ¡ndicap de jugadores inscritos en un torneo especÃ­fico, de cara al pÃºblico (se agregarÃ¡ junto con `tournament_registrations`)
- Agregar mÃ¡s ciudades a `cities` conforme se registren clubes en localidades nuevas (vÃ­a dashboard de superadmin)
- Configurar SMTP personalizado en Supabase (Authentication â†’ SMTP Settings) antes de lanzar con jugadores reales â€” el correo interno de Supabase tiene un lÃ­mite de envÃ­os muy bajo, solo sirve para pruebas
- Comprar y verificar un dominio propio para Golf In Full, y verificarlo en Resend, antes de lanzar con jugadores reales â€” mientras tanto se usa el dominio de pruebas de Resend (`onboarding.resend.dev`), que solo envÃ­a a la cuenta propia, no a jugadores reales

