Migraciones de base de datos — Court Connect / Golf In Full
Este repositorio documenta el esquema de base de datos (Supabase/PostgreSQL) de la plataforma multi-club / multi-torneo de golf.
Proyecto de Supabase: `GOLFING_FULL`
Cómo se aplican: actualmente, cada migración se ejecuta manualmente en el SQL Editor de Supabase, en el orden numerado. Estos archivos son el registro histórico versionado de esos cambios — Supabase es siempre la fuente de la verdad del esquema en vivo; este repo es el historial y respaldo del SQL.
Orden de aplicación
Las migraciones deben correrse en este orden exacto — cada una depende de que la(s) anterior(es) ya se hayan ejecutado.
#	Archivo	Qué hace
001	`001_players_table.sql`	Tabla maestra `players` (jugadores): identificación, contacto, hándicap declarado/verificado.
002	`002_parametros_admin_users.sql`	Tabla `system_parameters` (parámetros configurables del sistema) y primera versión de `admin_users` (administradores/organizadores).
003	`003_roles_y_asignaciones.sql`	Rediseño de permisos: catálogo `roles` + tabla `admin_role_assignments` (quién tiene qué rol, en qué club o torneo). Funciones auxiliares `is_superadmin`, `is_club_admin`, `is_tournament_organizer`.
004	`004_limites_permisos_auditoria.sql`	Límite de asignaciones por rol (ej. 1 club por `club_admin`), quién puede otorgar cada rol, y tabla `audit_log` (auditoría genérica de altas/cambios).
005	`005_activacion_desactivacion.sql`	Activar/desactivar personas, roles y asignaciones sin borrarlas, con registro automático de quién y cuándo.
006	`006_impedir_borrado_admin_con_historial.sql`	Blindaje: impide borrar físicamente a un administrador que ya tiene historial (asignaciones, verificaciones de hándicap); solo permite desactivarlo.
007	`007_recrear_triggers_faltantes.sql`	Corrección: recrea los 11 triggers de `players`, `admin_users`, `roles` y `admin_role_assignments` que no llegaron a crearse en las migraciones 001-005 (las funciones ya existían, pero no estaban enganchadas). Idempotente — segura de correr aunque alguno ya exista.
008	`008_clubs_y_tournaments.sql`	Tablas `clubs` y `tournaments`, con auditoría/alta-baja reutilizando las funciones genéricas ya construidas. Activa las FK `club_id`/`tournament_id` pendientes en `admin_role_assignments`. RLS: lectura pública de activos, escritura restringida por rol.
009	`009_restringir_contacto_clubs.sql`	Restringe `clubs.telefono` y `clubs.email` a usuarios autenticados (privilegios de columna); visitantes sin sesión (`anon`) ya no pueden leer esas dos columnas vía la API pública.
010	`010_rls_players.sql`	Políticas de RLS de `players`: un jugador solo ve/edita su propio perfil (cero visibilidad entre jugadores); cualquier administrador activo puede ver/editar cualquier perfil. Trigger que impide que un jugador se auto-verifique su propio hándicap.
011	`011_grants_faltantes.sql`	Corrección: otorga los `GRANT` de tabla faltantes en `players`, `admin_users`, `roles`, `admin_role_assignments`, `system_parameters`, `audit_log`, `clubs` y `tournaments`. Sin estos, RLS nunca llegaba a evaluarse — Postgres rechazaba el acceso antes. No cambia ninguna política ni regla de negocio.
012	`012_fix_recursion_rls.sql`	Corrección crítica: `is_superadmin`, `is_club_admin`, `is_tournament_organizer` e `is_active_admin` pasan a `SECURITY DEFINER` con `search_path` fijo, para romper una recursión infinita — esas funciones consultan tablas cuyas propias políticas de RLS las vuelven a llamar, causando "stack depth limit exceeded" (visible como error 500 en la API) para cualquier usuario autenticado normal.
013	`013_geografia_paises_estados_ciudades.sql`	Catálogo geográfico normalizado: `countries` → `states` → `cities`, con huso horario (IANA) a nivel ciudad. Sembrado con México + EE.UU., 32 estados de México + 51 de EE.UU., y las ~27 ciudades donde ya identificamos clubes. `clubs.city_id` agregado; `clubs.ciudad`/`clubs.estado` (texto libre) quedan obsoletos pero sin eliminar todavía.
014	`014_eliminar_ciudad_estado_texto.sql`	Elimina definitivamente `clubs.ciudad` y `clubs.estado` (texto libre) — la ubicación ya vive solo en `clubs.city_id`.
015	`015_city_id_obligatorio.sql`	Hace `clubs.city_id` obligatorio (`NOT NULL`). Se detiene con un error claro si queda algún club sin ciudad asignada — hay que resolver esos primero.
016	`016_catalogo_husos_horarios.sql`	Catálogo curado `timezones` (etiqueta amigable + diferencia UTC), con FK real desde `cities.timezone`. Evita mostrar identificadores IANA crudos en el dropdown del frontend.
017	`017_modulos_y_licencias.sql`	Catálogo `modules` (primer módulo: Torneos) y tabla `club_module_licenses` para controlar contratación (anual o por torneo), vigencia, tarifa y pago por club. Incluye `club_has_active_module()` para que el frontend consulte fácilmente si un módulo está habilitado. Fase 1: solo estructura, sin frontend todavía.
018	`018_formato_juego_y_categorias.sql`	`tournaments` gana formato de juego (individual/equipo), modalidad según formato, tamaño de equipo (2-5), y duración en días calculada automáticamente. Catálogo `categories` + relación muchos-a-muchos `tournament_categories` (un torneo puede tener varias categorías).
019	`019_criterios_categorias.sql`	`categories` gana rango de edad y rango de hándicap, ambos opcionales e independientes — una categoría puede usar uno, otro, ambos, o ninguno.
020	`020_vincular_jugador_preregistrado.sql`	Cuando un jugador confirma su correo al crear su cuenta, se vincula automáticamente con su perfil pre-registrado en `players` (si un organizador ya lo había dado de alta con ese mismo correo) — solo tras confirmación, nunca antes, para evitar suplantación. No crea perfiles nuevos.
021	`021_estatus_activo_players.sql`	Agrega `activo`/`fecha_baja`/`dado_de_baja_por`/`motivo_baja` a `players`. Agrega el trigger de auditoría que a `players` le faltaba desde el inicio. Solo un administrador puede activar/desactivar a un jugador — el jugador no puede autoreactivarse si fue dado de baja.
022	`022_vincular_jugador_en_cada_login.sql`	Corrección: agrega un tercer trigger que reintenta la vinculación de perfil pre-registrado en CADA login exitoso (`last_sign_in_at`), no solo en el momento único de la primera confirmación de correo — cubre el caso de una cuenta ya confirmada de antes con un perfil pre-registrado más reciente.
023	`023_campos_golf.sql`	Nueva tabla `campos_golf`: `club_id` (un club puede operar varios campos), `nombre_oficial`, `numero_hoyos`, `timezone_id`, `latitud`/`longitud` (opcionales). `clubs` pierde `numero_hoyos`. Solo superadmin da de alta campos nuevos; club_admin puede editar los de su club.
024	`024_hoyos_y_marcas_salida.sql`	`marcas_salida` (tee marks con Course Rating/Slope), `hoyos` (par, hándicap de hoyo), `distancias_hoyo` (yardaje por hoyo según marca). Numeración simple 1..N — sin soporte de "nueves combinables" en campos de 27+ todavía. Lectura pública; escritura de superadmin o club_admin dueño del campo.
025	`025_rating_slope_por_genero.sql`	`marcas_salida.rating`/`slope` se separan en `rating_caballeros`/`slope_caballeros` y `rating_damas`/`slope_damas` — el estándar USGA/World Handicap System certifica estos números por separado para cada género, incluso desde la misma marca de salida.
026	`026_coordenadas_green.sql`	Habilita PostGIS. Tabla `green_coordenadas` (frente/centro/atrás por hoyo, tipo `geography(POINT, 4326)`), opcional, un hoyo = a lo más una fila. Permite cálculos de distancia nativos más adelante.
026A	`026A_helpers_coordenadas_green.sql`	Complemento a la 026 (corrida sin estos ayudantes): función `upsert_green_coordenadas()` (RPC que recibe lat/long normales, evita que el frontend maneje PostGIS directamente) y la vista `green_coordenadas_detalle` (lectura ya convertida a números).
027	`027_orden_marcas_salida.sql`	`marcas_salida.categoria_estandar` (Championship/Azul/Blanco/Dorado/Rojo/Otro, lista fija) — `orden_visualizacion` se calcula automáticamente a partir de esa categoría (columna `generated always as`), nunca se captura manualmente.
028	`028_resumen_campo.sql`	Vistas `resumen_par_por_campo` (hoyos agrupados por par) y `resumen_yardaje_por_marca` (yardaje total por marca, ya ordenado) — para la tarjeta "Resumen del campo" sin que el frontend tenga que calcular agregados.
Cómo agregar una migración nueva
Diseñar el cambio (esquema, RLS, triggers).
Correrlo en el SQL Editor de Supabase (proyecto `GOLFING_FULL`), confirmar que no haya errores.
Subir el archivo `.sql` a este repositorio, dentro de `supabase/migrations/`, con el siguiente número consecutivo (ej. `007_clubs_y_tournaments.sql`).
Agregar una fila a la tabla de este README.
Entidades pendientes (no construidas todavía)
`tournament_registrations`
Tabla de contactos por área de cada campo de golf (Pro Shop, Starter, Renta de Carritos, Taller, Servicio en Campo/Alimentos y Bebidas) — fase futura, aparte de `campos_golf`
Decidir si `tournaments.club_id` debe cambiar a `campo_golf_id` — ahora que un club puede tener varios campos, un torneo probablemente debería apuntar al campo específico donde se juega, no solo al club en general
Soporte de "nueves combinables" (A/B/C) para campos de 27+ hoyos — hoy `hoyos` asume numeración simple 1..N
Registro de jugadores por parte del organizador (Fase 2) y autoregistro del jugador (Fase 3) — la migración 020 ya deja lista la vinculación automática entre ambos flujos
Frontend de licencias de módulos (`club_module_licenses`) — la estructura ya existe (migración 017), falta la pantalla
Dashboard completo para el rol `club_admin` (login, layout, navegación) — hoy solo existe el de superadmin
Regla de RLS adicional en `players` para exponer nombre/hándicap de jugadores inscritos en un torneo específico, de cara al público (se agregará junto con `tournament_registrations`)
Agregar más ciudades a `cities` conforme se registren clubes en localidades nuevas (vía dashboard de superadmin)
Configurar SMTP personalizado en Supabase (Authentication → SMTP Settings) antes de lanzar con jugadores reales — el correo interno de Supabase tiene un límite de envíos muy bajo, solo sirve para pruebas
Comprar y verificar un dominio propio para Golf In Full, y verificarlo en Resend, antes de lanzar con jugadores reales — mientras tanto se usa el dominio de pruebas de Resend (`onboarding.resend.dev`), que solo envía a la cuenta propia, no a jugadores reales
