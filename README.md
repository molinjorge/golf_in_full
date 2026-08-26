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
| 008 | `008_clubs_y_tournaments.sql` | Tablas `clubs` y `tournaments`, con auditoría/alta-baja reutilizando las funciones genéricas ya construidas. Activa las FK `club_id`/`tournament_id` pendientes en `admin_role_assignments`. RLS: lectura pública de activos, escritura restringida por rol. |
| 009 | `009_restringir_contacto_clubs.sql` | Restringe `clubs.telefono` y `clubs.email` a usuarios autenticados (privilegios de columna); visitantes sin sesión (`anon`) ya no pueden leer esas dos columnas vía la API pública. |
| 010 | `010_rls_players.sql` | Políticas de RLS de `players`: un jugador solo ve/edita su propio perfil (cero visibilidad entre jugadores); cualquier administrador activo puede ver/editar cualquier perfil. Trigger que impide que un jugador se auto-verifique su propio hándicap. |
| 011 | `011_grants_faltantes.sql` | Corrección: otorga los `GRANT` de tabla faltantes en `players`, `admin_users`, `roles`, `admin_role_assignments`, `system_parameters`, `audit_log`, `clubs` y `tournaments`. Sin estos, RLS nunca llegaba a evaluarse — Postgres rechazaba el acceso antes. No cambia ninguna política ni regla de negocio. |
| 012 | `012_fix_recursion_rls.sql` | Corrección crítica: `is_superadmin`, `is_club_admin`, `is_tournament_organizer` e `is_active_admin` pasan a `SECURITY DEFINER` con `search_path` fijo, para romper una recursión infinita — esas funciones consultan tablas cuyas propias políticas de RLS las vuelven a llamar, causando "stack depth limit exceeded" (visible como error 500 en la API) para cualquier usuario autenticado normal. |
| 013 | `013_geografia_paises_estados_ciudades.sql` | Catálogo geográfico normalizado: `countries` → `states` → `cities`, con huso horario (IANA) a nivel ciudad. Sembrado con México + EE.UU., 32 estados de México + 51 de EE.UU., y las ~27 ciudades donde ya identificamos clubes. `clubs.city_id` agregado; `clubs.ciudad`/`clubs.estado` (texto libre) quedan obsoletos pero sin eliminar todavía. |
| 014 | `014_eliminar_ciudad_estado_texto.sql` | Elimina definitivamente `clubs.ciudad` y `clubs.estado` (texto libre) — la ubicación ya vive solo en `clubs.city_id`. |
| 015 | `015_city_id_obligatorio.sql` | Hace `clubs.city_id` obligatorio (`NOT NULL`). Se detiene con un error claro si queda algún club sin ciudad asignada — hay que resolver esos primero. |
| 016 | `016_catalogo_husos_horarios.sql` | Catálogo curado `timezones` (etiqueta amigable + diferencia UTC), con FK real desde `cities.timezone`. Evita mostrar identificadores IANA crudos en el dropdown del frontend. |
| 017 | `017_modulos_y_licencias.sql` | Catálogo `modules` (primer módulo: Torneos) y tabla `club_module_licenses` para controlar contratación (anual o por torneo), vigencia, tarifa y pago por club. Incluye `club_has_active_module()` para que el frontend consulte fácilmente si un módulo está habilitado. Fase 1: solo estructura, sin frontend todavía. |
| 018 | `018_formato_juego_y_categorias.sql` | `tournaments` gana formato de juego (individual/equipo), modalidad según formato, tamaño de equipo (2-5), y duración en días calculada automáticamente. Catálogo `categories` + relación muchos-a-muchos `tournament_categories` (un torneo puede tener varias categorías). |
| 019 | `019_criterios_categorias.sql` | `categories` gana rango de edad y rango de hándicap, ambos opcionales e independientes — una categoría puede usar uno, otro, ambos, o ninguno. |
| 020 | `020_vincular_jugador_preregistrado.sql` | Cuando un jugador confirma su correo al crear su cuenta, se vincula automáticamente con su perfil pre-registrado en `players` (si un organizador ya lo había dado de alta con ese mismo correo) — solo tras confirmación, nunca antes, para evitar suplantación. No crea perfiles nuevos. |
| 021 | `021_estatus_activo_players.sql` | Agrega `activo`/`fecha_baja`/`dado_de_baja_por`/`motivo_baja` a `players`. Agrega el trigger de auditoría que a `players` le faltaba desde el inicio. Solo un administrador puede activar/desactivar a un jugador — el jugador no puede autoreactivarse si fue dado de baja. |
| 022 | `022_vincular_jugador_en_cada_login.sql` | Corrección: agrega un tercer trigger que reintenta la vinculación de perfil pre-registrado en CADA login exitoso (`last_sign_in_at`), no solo en el momento único de la primera confirmación de correo — cubre el caso de una cuenta ya confirmada de antes con un perfil pre-registrado más reciente. |
| 023 | `023_campos_golf.sql` | Nueva tabla `campos_golf`: `club_id` (un club puede operar varios campos), `nombre_oficial`, `numero_hoyos`, `timezone_id`, `latitud`/`longitud` (opcionales). `clubs` pierde `numero_hoyos`. Solo superadmin da de alta campos nuevos; club_admin puede editar los de su club. |
| 024 | `024_hoyos_y_marcas_salida.sql` | `marcas_salida` (tee marks con Course Rating/Slope), `hoyos` (par, hándicap de hoyo), `distancias_hoyo` (yardaje por hoyo según marca). Numeración simple 1..N — sin soporte de "nueves combinables" en campos de 27+ todavía. Lectura pública; escritura de superadmin o club_admin dueño del campo. |
| 025 | `025_rating_slope_por_genero.sql` | `marcas_salida.rating`/`slope` se separan en `rating_caballeros`/`slope_caballeros` y `rating_damas`/`slope_damas` — el estándar USGA/World Handicap System certifica estos números por separado para cada género, incluso desde la misma marca de salida. |
| 026 | `026_coordenadas_green.sql` | Habilita PostGIS. Tabla `green_coordenadas` (frente/centro/atrás por hoyo, tipo `geography(POINT, 4326)`), opcional, un hoyo = a lo más una fila. Permite cálculos de distancia nativos más adelante. |
| 026A | `026A_helpers_coordenadas_green.sql` | Complemento a la 026 (corrida sin estos ayudantes): función `upsert_green_coordenadas()` (RPC que recibe lat/long normales, evita que el frontend maneje PostGIS directamente) y la vista `green_coordenadas_detalle` (lectura ya convertida a números). |
| 027 | `027_orden_marcas_salida.sql` | `marcas_salida.categoria_estandar` (Championship/Azul/Blanco/Dorado/Rojo/Otro, lista fija) — `orden_visualizacion` se calcula automáticamente a partir de esa categoría (columna `generated always as`), nunca se captura manualmente. |
| 028 | `028_resumen_campo.sql` | Vistas `resumen_par_por_campo` (hoyos agrupados por par) y `resumen_yardaje_por_marca` (yardaje total por marca, ya ordenado) — para la tarjeta "Resumen del campo" sin que el frontend tenga que calcular agregados. |
| 029 | `029_tournament_formats.sql` | Catálogo `tournament_formats` (code, name, tipo_participacion, scoring_engine, descripción, orden). `tipo_participacion` reutiliza el enum `formato_juego_torneo` ya existente — renombrado desde `category` para no confundirlo con la tabla `categories` (divisiones de jugadores). Solo estructura — los "motores" de puntuación se definirán en una fase posterior. |
| 030 | `030_migrar_tournaments_a_formats.sql` | Limpia torneos de prueba (y lo que dependía de ellos: categorías asignadas, licencia ligada, asignación de Pedro Pérez como organizador). Siembra `tournament_formats` con las 5 modalidades que ya existían. Migra `tournaments` para usar `tournament_format_id` (FK) en vez de los enums `formato_juego`/`modalidad_individual`/`modalidad_equipo`, que se eliminan. |
| 031 | `031_reglas_desempate_handicap_marcas.sql` | Catálogo `tiebreak_methods` + `tournament_tiebreak_rules` (secuencia encadenable de desempate, con alcance distinto para primer lugar vs. resto). `tournament_formats.handicap_allowance_default` (95% Stroke Play/Stableford individual, 85% Best Ball). `tournament_tee_overrides` (rating/slope de marca de salida, excepción opcional por torneo). |
| 032 | `032_rondas_y_cortes.sql` | `tournament_rounds`: cada torneo pasa a tener 1+ rondas (fecha, campo). La modalidad (`tournament_format_id`) y el % de hándicap son opcionales por ronda — si no se especifican, se heredan del torneo (vista `tournament_rounds_efectivo` resuelve el valor real, aplicando la herencia). `tournament_cut_rules`: reglas de corte por posición o por score, siempre por categoría, ligadas a después de qué ronda ocurren. |
| 033 | `033_turnos_y_cupo_categoria.sql` | `tournament_round_shifts`: turnos dentro de una ronda (máx. 3 por día), cada uno con su hora de salida y cupo máximo definido por el comité — mezclan categorías, no son un turno por categoría. `tournament_categories.cupo_maximo`: límite de inscripciones por categoría, definido por el comité. |
| 034 | `034_campo_golf_en_tournaments.sql` | `tournaments.campo_golf_id` — el campo donde se juega el torneo, validado (trigger) para que pertenezca al `club_id` declarado. Es la fuente real para precargar el campo al crear rondas nuevas. `club_id` se conserva (lo siguen usando todas las políticas de RLS de rondas/turnos/categorías/desempates). |
| 035 | `035_activo_en_cut_rules.sql` | Agrega el patrón estándar de alta/baja (`activo`, `fecha_baja`, `dado_de_baja_por`, `motivo_baja`, `updated_at` + triggers) a `tournament_cut_rules`, que se había quedado sin él desde la migración 032. Actualiza su política de lectura para respetar `activo`. |
| 036 | `036_organizador_permisos_tournaments.sql` | Corrige `tournaments_select`/`tournaments_update` para incluir a `is_tournament_organizer()` — ya estaba bien en todas las tablas relacionadas (rondas, turnos, categorías, cortes) desde su creación, pero se quedó fuera en `tournaments` mismo. |
| 037 | `037_numero_rondas_planeadas.sql` | `tournaments.numero_rondas` — declarado al crear el torneo, default 1. El frontend debe usarlo para generar automáticamente esa cantidad de filas en `tournament_rounds`. No se sincroniza a la fuerza después — las rondas reales mandan una vez que existen. |
| 038 | `038_limite_rondas.sql` | Trigger que bloquea crear una ronda nueva si ya se alcanzó `tournaments.numero_rondas` (contando solo rondas activas) — hay que subir el número de rondas del torneo antes de poder agregar una más. |
| 039 | `039_catalogo_estatus_torneo.sql` | Agrega el valor `inscripcion_cerrada` al enum `estatus_torneo` (que faltaba). El color del badge se resuelve en el frontend (mapeo fijo, no requiere tabla) — el conjunto de estatus es fijo a propósito, para que la automatización futura no dependa de datos que alguien pueda alterar desde una pantalla. |
| 040 | `040_orden_tiebreak_methods.sql` | `tiebreak_methods.display_order` — Muerte Súbita primero, luego tarjeta de menor a mayor tramo (último hoyo → 3 → 6 → 9 → 18), Sorteo al final. |
| 041 | `041_activo_en_tiebreak_rules.sql` | Agrega el patrón estándar de alta/baja a `tournament_tiebreak_rules` (igual que la 035 hizo con `tournament_cut_rules`). Cambia la restricción única de `(tournament_id, alcance, orden)` a un índice único parcial que solo cuenta filas activas — para que desactivar un paso libere esa posición. |
| 042 | `042_tarifas_torneo.sql` | `tournaments.tarifa_individual` (siempre aplica) y `tarifa_equipo_completo` (solo si la modalidad es de equipo, validado por trigger), más `moneda`. |
| 043 | `043_telefono_obligatorio_unico_restringido.sql` | `players.telefono_*` pasa a obligatorio y único (evita registros duplicados). Una vez confirmada la cuenta (`auth_user_id` asignado), solo el propio jugador o el superadmin pueden editar el teléfono — ningún otro tipo de administrador. |
| 044 | `044_mensaje_telefono_duplicado.sql` | Trigger que da un mensaje claro ("El número de teléfono indicado está registrado por otro jugador.") en vez del error técnico genérico de la restricción UNIQUE de la migración 043. |
| 045 | `045_fix_security_definer_telefono.sql` | Corrección: `validar_telefono_unico()` pasa a `SECURITY DEFINER` — corría con los permisos del jugador que se registra, y como RLS solo le permite ver su propia fila, nunca detectaba el duplicado de otro jugador (mismo patrón de bug que la recursión de `is_superadmin()` en la migración 012). |
| 046 | `046_info_venta_torneo.sql` | `tournament_marketing_info`: contenido de venta del torneo (qué incluye, premios, kit de bienvenida, alimentos/bebidas/carrito/caddie con detalle, beneficiario, precio socios, contacto). Lectura pública; escritura exclusiva de superadmin y del `tournament_organizer` de ese torneo (`club_admin` no puede editar aquí, a diferencia del resto de tablas de torneo). |
| 047 | `047_ventana_acceso_torneo.sql` | `tournaments.acceso_fecha_hora_inicio`/`acceso_fecha_hora_fin` — ventana de tiempo compartida por todas las inscripciones, contra la que se validará cada QR de acceso al club/campo. Base para el sistema de QR, que se completa cuando exista `tournament_registrations`. |
| 048 | `048_tournament_registrations.sql` | `tournament_registrations`: inscripción individual — solo existe con pago confirmado (sin estatus "pendiente"), incluye `qr_token` único para el acceso. Valida cupo por categoría y que la categoría pertenezca al torneo. Solo el proceso de pago (server-side) o superadmin pueden crear la fila. `tournament_registration_attempts`: registro de intentos para el correo de abandono. |
| 049 | `049_pre_reservas_torneo.sql` | `tournament_pre_reservations`: jugadores que apartan lugar por transferencia (a confirmar) o pago el día del evento — tabla separada de `tournament_registrations` por tener un ciclo de vida distinto (sí tiene estatus pendiente/pagado/cancelado/no-show). El cupo por categoría ahora se valida cruzado entre ambas tablas. Vista `tournament_participantes` unifica los dos canales para roster. |
| 050 | `050_confirmar_pago_prereserva.sql` | Agrega "efectivo" al catálogo de medios de pago. Función `confirmar_pago_prereserva()`: confirma el pago de una pre-reserva, crea la inscripción real enlazada en `tournament_registrations`, sin borrar el historial de la pre-reserva original. Ajusta el cupo cruzado para no contar dos veces una pre-reserva ya convertida. |
| 051 | `051_separar_medio_pago_torneo.sql` | Corrección: crea `medio_pago_torneo`, catálogo propio para pagos de inscripción de jugador, separado de `medio_pago_licencia` (que es para pagos de licencia de club — dominio distinto). Corrige `tournament_registrations.medio_pago` y la función `confirmar_pago_prereserva()` para usar el catálogo correcto. |
| 052 | `052_simulador_pago_temporal.sql` | Reemplaza `tournament_registration_attempts` por `payment_attempts` — intento de pago **genérico** (campo `concepto`: inscripción individual/equipo, renta de carrito, pago el día del evento, etc.), reutilizable en cualquier flujo de pago futuro. RPC `procesar_resultado_pago()` crea lo correspondiente según el concepto (hoy solo implementa `inscripcion_individual`). `simular_resultado_pago()` es un alias **TEMPORAL** para pruebas. ⚠️ Debe eliminarse antes de operar con dinero real. |
| 053 | `053_habilitar_pgcrypto.sql` | Habilita la extensión `pgcrypto` — nunca se había creado explícitamente; es necesaria para `gen_random_bytes()`, usada en `qr_token` (`tournament_registrations`, `tournament_pre_reservations`) y en las referencias de pago simuladas. |
| 054 | `054_fix_esquema_pgcrypto.sql` | Corrección: Supabase instala `pgcrypto` en el esquema `extensions`, no en `public` — nuestras funciones `SECURITY DEFINER` (que fijan `search_path=public` por seguridad) no la encontraban. Se califica explícitamente `extensions.gen_random_bytes()` en los defaults de `qr_token` y en `procesar_resultado_pago()`, en vez de ampliar el `search_path`. |
| 055 | `055_folio_legible_inscripcion.sql` | `tournament_registrations.folio` — consecutivo legible por torneo (INS-0001, INS-0002...), generado automáticamente. Separado de `qr_token`, que se queda como llave secreta del acceso, no pensada para leerse. |
| 056 | `056_mensaje_inscripcion_duplicada.sql` | Trigger que da un mensaje claro ("Ya tienes una inscripción activa en este torneo.") en vez del error técnico genérico de la restricción UNIQUE de `tournament_registrations`. Mismo patrón que la validación de teléfono duplicado. |
| 057 | `057_bandera_correo_confirmacion.sql` | `tournament_registrations.correo_confirmacion_enviado` — evita reenviar el correo de confirmación de inscripción por accidente. |
| 058 | `058_acotar_visibilidad_players_organizador.sql` | Acota `players_select`/`players_update` para `tournament_organizer`: solo ve/edita jugadores con inscripción o pre-reserva activa en SUS torneos, no el catálogo completo. `superadmin` y `club_admin` conservan visibilidad total (nueva función `is_any_club_admin()`). `players_insert` no cambia — cualquier admin activo sigue pudiendo pre-registrar jugadores nuevos. |
| 059 | `059_hora_escopetazo.sql` | `tournament_marketing_info.hora_escopetazo` — hora de salida en escopetazo, opcional. |
| 060 | `060_recibo_deducible_fase1.sql` | `payment_fiscal_receipts` — Fase 1 de recibo deducible: solicitud + referencia al PDF de la Constancia de Situación Fiscal, ligada a `payment_attempts` (pago genérico, no a la inscripción específica). Fase 2 (generación/envío real de factura vía PAC) queda pendiente. |
| 061 | `061_bucket_constancias_fiscales.sql` | Bucket privado de Supabase Storage `constancias-fiscales`, con permisos: cada jugador solo sube/ve dentro de su propia carpeta (`player_id`); superadmin y club_admin ven todo; `tournament_organizer` ve únicamente las constancias ligadas a pagos de SUS propios torneos (consulta `payment_fiscal_receipts`). |
| 062 | `062_fix_recursion_players_organizador.sql` | Corrección crítica: la 058 introdujo recursión infinita de RLS entre `players` y `tournament_registrations`/`tournament_pre_reservations` (cada política consultaba a la otra). Se resuelve con la función `SECURITY DEFINER` `jugador_visible_para_organizador()`, mismo patrón que la migración 012. |
| 063 | `063_bandera_intencion_recibo.sql` | `payment_attempts.solicito_recibo_deducible` — marca la intención en cuanto el jugador dice "Sí", independiente de si sube la constancia después. Permite detectar solicitudes de recibo incompletas (dijo que sí pero nunca subió el PDF). |
| 064 | `064_torneos_beneficencia.sql` | `tournaments.es_beneficencia`/`institucion_beneficiaria`/`concepto_recibo` — mueve el dato del beneficiario desde `tournament_marketing_info` (que pierde esas 2 columnas) hacia `tournaments`, ya que ahora controla una regla real: **solo torneos de beneficencia pueden solicitar recibo deducible**, validado por trigger tanto en `payment_attempts` como en `payment_fiscal_receipts`. |
| 065 | `065_tarifa_early_bird.sql` | `tournaments.tarifa_early_bird`/`fecha_limite_early_bird`. Función `tarifa_vigente_torneo()` calcula la tarifa aplicable hoy. El monto de `payment_attempts` para inscripción individual ahora lo calcula siempre el servidor (trigger), nunca se confía en lo que mande el cliente — cierra un hueco de seguridad real. |
| 066 | `066_tarifa_socios_permisos_validacion.sql` | Agrega a `club_admin` como editor de `tournament_marketing_info` (confirmado: intencional). `precio_socios` inicialmente exigía igualdad con `tarifa_early_bird` — corregido en la 067. |
| 067 | `067_tarifas_independientes_y_bloqueo.sql` | `precio_socios` vuelve a ser independiente de `tarifa_early_bird` — solo debe ser menor que `tarifa_individual`. Nuevo: una vez que un torneo tiene al menos una inscripción activa, sus tarifas (`tarifa_individual`, `tarifa_early_bird`, `fecha_limite_early_bird`) quedan bloqueadas — no se pueden modificar, protegiendo a quien ya pagó. |
| 068 | `068_perfil_completo_para_inscripcion.sql` | `players.fecha_nacimiento` y `telefono_*` vuelven opcionales (para permitir pre-registro incompleto por un organizador). Se exigen completos únicamente al momento de inscribirse (`tournament_registrations`/`tournament_pre_reservations`), vía `validar_perfil_completo_para_inscripcion()`. |
| 069 | `069_buscar_jugador_por_telefono.sql` | Función `buscar_jugador_por_telefono()` — búsqueda acotada (solo confirma existencia + nombre) para que un organizador maneje reservas telefónicas sin poder navegar el catálogo completo. Habilita el flujo: llamada → buscar por teléfono → si existe, crear `tournament_pre_reservations` directo (cuenta contra cupo); si no existe, pre-registrar primero. |
| 070 | `070_reservas_previas_telefonicas.sql` | `phone_reservations`: reserva telefónica para alguien que aún NO está en el catálogo (nombre + **correo obligatorio** + teléfono + compromiso, sin `player_id`). El correo permite enviar una invitación real a registrarse — **ya construido y funcionando** (confirmado agosto 2026, el correo de invitación llega correctamente a jugadores reales, tanto en precarga directa de `players` como en este flujo de reservas telefónicas). Se reconcilia automáticamente por teléfono (trigger en `players`): al autoregistrarse, se crea la `tournament_pre_reservations` real y se cancela la reserva telefónica. |
| 071 | `071_vista_reservas_previas.sql` | Vista `tournament_reservas_previas` — unifica `tournament_pre_reservations` y `phone_reservations` en una sola consulta, para la pantalla "Reservas previas del torneo" del organizador. Requiere que ya exista `phone_reservations` (070). |
| 072 | `072_perfil_completo_solo_inscripcion_real.sql` | Corrección: la exigencia de perfil completo (migración 068) se quita de `tournament_pre_reservations` — solo debe aplicar a `tournament_registrations` (inscripción real, pagada). Una pre-reserva es un compromiso provisional y puede convivir con un perfil incompleto hasta confirmar el pago. |
| 073 | `073_fecha_limite_pago_validada.sql` | `fecha_limite_pago` pasa de `timestamptz` a `date` (sin hora) en `tournament_pre_reservations` y `phone_reservations`. Se valida que no sea posterior a `tournaments.fecha_inicio`, y se autocompleta con esa misma fecha cuando la modalidad es "pago el día del evento" — ya no se captura a mano en ese caso. |
| 074 | `074_bandera_correo_prereserva.sql` | `tournament_pre_reservations.correo_confirmacion_enviado` — evita reenviar el correo de confirmación de pre-reserva por accidente. |
| 075 | `075_jugador_paga_prereserva.sql` | Nuevo concepto `confirmar_pre_reserva` en `procesar_resultado_pago()` — permite que el propio jugador pague en línea (tarjeta) una pre-reserva pendiente, sin depender de que un administrador la confirme manualmente. Valida que la pre-reserva le pertenezca y siga pendiente. |
| 076 | `076_pais_telefono_y_whatsapp.sql` | Código de país limitado a `+52`/`+1` a nivel de base de datos (`players`, `phone_reservations`). `players.acepta_whatsapp` — consentimiento explícito para comunicación futura por ese canal. |
| 077 | `077_secuencias_desempate.sql` | Catálogo `secuencias_desempate` (plantillas con nombre: "R&A Oficial" y "Mexicano por Hándicap") + `secuencia_desempate_pasos`. Agrega el método faltante `HOYO_POR_HOYO_HANDICAP` a `tiebreak_methods`. Función `aplicar_secuencia_desempate()` — aplica una plantilla completa a un torneo/alcance de un clic, reutilizando `tournament_tiebreak_rules` (031) por debajo. |
| 078 | `078_desempate_por_categoria.sql` | `tournament_tiebreak_rules` gana `tournament_category_id` (permite secuencia distinta por categoría — Playoff para Campeonato, Countback neto para hándicap, etc. — NULL aplica como default general) y `tipo_resultado` (gross/neto). `aplicar_secuencia_desempate()` actualizado para aceptar ambos parámetros. |
| 079 | `079_equipos_fase1.sql` | **Inscripción por equipos, Fase 1.** Tabla `tournament_teams` (categoría opcional — soporta torneos de equipos sin categorías). `tournament_registrations` gana `tournament_team_id`; `tournament_category_id` pasa a opcional y se hereda automáticamente del equipo. Cupo por categoría deja de aplicar en torneos de equipos. Función `reasignar_jugador_a_equipo()` para que el organizador mueva jugadores libremente entre equipos. Vista `tournament_equipos_incompletos`. |
| 080 | `080_simplificar_categoria_unica.sql` | Simplificación: se elimina el caso especial de "torneo sin categorías = categoría única" de la 079. Un torneo de categoría única simplemente asigna la categoría real "ÚNICA" (ya existente en el catálogo) — reutiliza el mecanismo normal de categorías sin ninguna rama especial. La categoría vuelve a ser siempre obligatoria al inscribirse sin equipo. |
| 081 | `081_jugador_crea_equipo.sql` | Permite que cualquier jugador autenticado cree un equipo (antes solo administradores) — necesario para la Fase 2: si el jugador no encuentra su equipo en la lista, puede darlo de alta él mismo. |
| 082 | `082_logos_torneo.sql` | `tournaments.logo_url`. Bucket público `logos-torneos` (a diferencia de constancias fiscales, este sí es público). Solo superadmin/organizador/club_admin del club sede pueden subir el logo de su torneo. |
| 083 | `083_equipos_en_prereservas.sql` | Corrección: el soporte de equipos (079) nunca se propagó a `phone_reservations` ni `tournament_pre_reservations` — ambas ganan `tournament_team_id` (categoría ahora opcional en ambas). Se actualiza la reconciliación automática, `confirmar_pago_prereserva()`, y `procesar_resultado_pago()` para propagar el equipo de extremo a extremo, desde la llamada telefónica hasta la inscripción final. |
| 084 | `084_fix_categoria_nula_permitida.sql` | Corrección: `validar_categoria_pertenece_al_torneo()` rechazaba por error cualquier reserva con categoría vacía (incluido el caso legítimo "sin equipo") — nunca se actualizó para permitir `NULL` después de que la 083 volviera la categoría opcional. |
| 085 | `085_categoria_obligatoria_sin_equipo_temprano.sql` | Adelanta la regla "sin equipo → categoría obligatoria" al momento de crear la pre-reserva (`phone_reservations`, `tournament_pre_reservations`), en vez de descubrirlo hasta el pago. Corrige un error de diseño propio: "sin equipo" nunca debió saltarse la pregunta de categoría — solo se salta cuando SÍ hay equipo (se hereda de ahí). |
| 086 | `086_membresia_club_jugador.sql` | `players.club_id` (referencia a `clubs`, opcional) y `players.numero_membresia` (opcional) — captura de membresía de club. Estructura solamente; la lógica de aplicar tarifa de socios en el pago queda para una fase futura. |
| 087 | `087_restringir_edicion_membresia.sql` | `club_id`/`numero_membresia` solo los puede editar el propio jugador o el superadmin — ni `club_admin` ni `tournament_organizer` pueden tocarlos, aunque sí editen el resto del perfil. Son datos que declara el propio jugador. |
| 088 | `088_tarifa_socios_real.sql` | `tarifa_vigente_torneo()` ahora recibe también `p_player_id` — aplica tarifa de socios si el jugador pertenece al club dueño del campo, tiene `numero_membresia` capturado (control anti-fraude), y el torneo la ofrece. Si no, sigue la lógica previa (Early Bird > individual). El monto de inscripción individual ya considera al jugador, no solo el torneo. |
| 089 | `089_cupo_equipo_en_reservas.sql` | Cupo de equipo ahora se valida desde `phone_reservations`/`tournament_pre_reservations` (no solo hasta `tournament_registrations`), vía función compartida `ocupacion_actual_equipo()` que suma las tres fuentes sin doble conteo. Usa una bandera de sesión (`app.saltar_validacion_cupo_equipo`) para no contar dos veces durante la conversión controlada de pre-reserva a inscripción real. |
| 090 | `090_fecha_limite_obligatoria_transferencia.sql` | Corrección: `ajustar_fecha_limite_pago()` ahora exige `fecha_limite_pago` cuando `modalidad = 'transferencia'` — antes solo se autocompletaba para "pago el día del evento", pero nunca se exigió para transferencia, permitiendo reservas sin fecha límite. |
| 091 | `091_asignacion_marca_salida.sql` | Asignación automática de marca de salida al inscribirse. `categories.categoria_estandar_marca` (color fijo por categoría). `tournament_categories.handicap_minimo`/`handicap_maximo` (override por torneo). `tournament_franjas_handicap` (para torneos de categoría única, resuelve directo por hándicap sin pasar por categoría). `tournament_registrations` gana `marca_salida_id` y `categoria_reasignada`. Con equipo, la marca se hereda de la categoría del equipo sin validar hándicap individual. |
| 092 | `092_orden_categorias.sql` | `categories.display_order` — columna para el orden de presentación estándar (sin datos todavía). |
| 093 | `093_carga_orden_categorias.sql` | Carga el orden confirmado: Scratch, Premier, AA, A, B, C, D, Senior 1, Senior 2, Abierta (caballeros) → Damas 1, Damas 2 → Única. Debe respetarse en todas las pantallas: catálogo, selectores de inscripción/pre-reserva, configuración de torneo. |
| 094 | `094_exentar_categorias_sin_rango.sql` | Corrección: categorías sin rango de hándicap definido (ej. Senior 1/2, decididas por edad) se estaban reasignando incorrectamente en `resolver_categoria_y_marca()`. Ahora se aceptan tal cual, sin validar — la reasignación automática solo aplica entre categorías que sí tienen rango de hándicap. |
| 095 | `095_validar_por_edad.sql` | Extiende `resolver_categoria_y_marca()` para validar/reasignar también por rango de EDAD (categorías tipo Senior), simétrico a como ya funciona con hándicap — usa `fecha_nacimiento` del jugador (ya garantizada no-nula) contra la fecha de inicio del torneo. |
| 096 | `096_franjas_continuas_y_herencia.sql` | Candado real contra huecos/traslapes en `tournament_franjas_handicap` — cada franja nueva debe empezar exactamente donde terminó la anterior, error explícito si no. Función `heredar_franjas_desde_categorias()` — crea de un jalón las franjas de un torneo copiando los rangos/marca de las categorías estándar de caballeros (excluye Damas). |
| 097 | `097_damas_rojas_categoria_unica.sql` | En torneos de categoría única, las damas siempre salen de Rojas (regla fija, no pasan por las franjas de hándicap — esas son solo para caballeros). |
| 098 | `098_seniors_doradas_categoria_unica.sql` | En categoría única: caballeros de edad senior siempre salen de Doradas (gana sobre franjas de hándicap), mujeres siguen ganando sobre todo (siempre Rojas, incluso si son senior). `tournaments.edad_senior_categoria_unica` — override opcional del corte de edad, por torneo (default: el `edad_minima` más bajo entre categorías Senior del catálogo global). |
| 099 | `099_fix_genero_categoria.sql` | Corrección de bug real: la reasignación automática por hándicap/edad no filtraba por género, permitiendo que un hombre con hándicap bajo fuera reasignado por error a una categoría de damas si los rangos numéricos coincidían (caso real detectado: Juan Llosa). Se agrega `categories.genero` (M/F/NULL) explícito, usado ahora para filtrar toda reasignación. |
| 100 | `100_validar_categoria_elegida_tambien.sql` | Corrección de bug real: si el hándicap/edad del jugador caía en un hueco de configuración (una categoría intermedia sin activar en el torneo), la función se quedaba con la categoría elegida sin validar que realmente lo cubriera — dejando pasar asignaciones incorrectas en silencio. Ahora, si ni la elegida ni ninguna otra la cubren, rechaza con mensaje claro en vez de aceptar. |
| 101 | `101_reasignar_categoria_marca_jugador.sql` | Funciones `reasignar_categoria_jugador()` (cambia categoría, recalcula marca sola) y `reasignar_marca_salida_jugador()` (cambia solo la marca, sin tocar categoría) — para que el organizador ajuste manualmente una inscripción ya existente (ej. mover a alguien a Senior por reglamento del torneo, aunque su hándicap indicara otra categoría). |
| 102 | `102_equipo_categoria_unica.sql` | Corrección de bug real: en torneos de categoría única, un jugador inscrito CON EQUIPO se quedaba sin `marca_salida_id` (sin error visible) porque `resolver_categoria_y_marca()` solo intentaba heredar `categoria_estandar_marca` de la categoría del equipo — y la categoría "UNICA" nunca tiene ese campo poblado (el color se resuelve dinámicamente por sexo/edad/hándicap del jugador, no por catálogo estático). Caso real detectado: Juan Llosa, hombre senior, equipo con categoría "UNICA". Ahora, si la categoría del equipo es "UNICA", el trigger resuelve por el jugador individual (sexo/edad/franjas), igual que en inscripciones sin equipo. Equipos con categoría normal (con color fijo, ej. hándicap combinado) siguen heredando del equipo sin cambios. |
| 103 | `103_incluir_phone_reservations_cupo_categoria.sql` | Corrección de bug real: `validar_cupo_categoria_cruzado()` (individual por categoría) no contaba las reservas telefónicas (`phone_reservations`) al validar el cupo máximo de una categoría, a diferencia de `ocupacion_actual_equipo()` (equipos), que sí las suma — pese a que `phone_reservations.tournament_category_id` existe desde la migración 070 y sí puede haber reservas telefónicas ligadas a una categoría individual. La omisión dejaba pasar inscripciones por encima del cupo real. Detectado durante la prueba 4 (cupos), agosto 2026, comparando el código real de ambas funciones antes de construir el modal de disponibilidad para el organizador. |
| 104 | `104_cupo_total_torneo.sql` | Nueva regla de negocio: `tournaments.cupo_maximo` pasa a ser obligatorio (`NOT NULL`) y se valida por primera vez — hoy la columna existía pero ningún trigger la usaba; solo había techo por categoría (089/103) o por equipo, nada impedía que la suma de categorías rebasara el cupo físico real acordado con el director del campo. Función `validar_cupo_total_torneo()`, enganchada en `tournament_registrations` y `tournament_pre_reservations`: suma inscripciones confirmadas + pre-reservas activas, sin filtrar por categoría ni forma de pago. `phone_reservations` no cuenta para el total (personas aún no vinculadas al catálogo de jugadores) — solo cuentan al convertirse en pre-reserva o inscripción real. El cupo siempre se mide en número de jugadores, no de equipos. |
| 105 | `105_sincronizar_email_auth_jugador.sql` | Corrección de bug real: `players.email` (correo de contacto, catálogo) y `auth.users.email` (credencial real de login) podían desincronizarse sin aviso — `vincular_jugador_preregistrado()` solo vincula `auth_user_id` la primera vez que ambos correos coinciden, pero editar `players.email` después no propagaba nada hacia `auth.users`. Caso real detectado: Noriega, cuyo correo de contacto se editó pero su credencial de login se quedó con el valor sintético original, dejándolo sin poder iniciar sesión con el correo que aparecía en su perfil. Ahora, trigger `BEFORE UPDATE` en `players` sincroniza automáticamente `auth.users.email` cuando cambia `players.email` (fuente de la verdad); si el correo nuevo ya pertenece a otra cuenta, rechaza el cambio completo (ni siquiera actualiza `players.email`) con mensaje claro. Actualiza `auth.users` directo por SQL, sin el flujo oficial de confirmación de Supabase Auth — adecuado para la etapa de pruebas actual, no para producción con jugadores reales (ver pendientes). |
| 106 | `106_corregir_doble_conteo_cupo_total.sql` | Corrección de bug real: al confirmar el pago de una inscripción, tanto `validar_cupo_total_torneo()` (104) como `validar_cupo_categoria_cruzado()` (089/103) contaban la propia pre-reserva del jugador que se está inscribiendo como una persona aparte de su propia inscripción — porque `tournament_pre_reservations.tournament_registration_id` se vincula DESPUÉS del insert en `tournament_registrations`, no antes. Una misma persona contaba doble justo en el momento de conversión pre-reserva → inscripción, bloqueando el último lugar disponible del cupo aunque sí hubiera espacio real. Caso real detectado: torneo de prueba con `cupo_maximo = 20`, 19 inscripciones + la pre-reserva del jugador #20 (Noriega) sumaban 20, y el sistema rechazó su propia conversión a inscripción. Fix: ambas funciones excluyen, del conteo de pre-reservas, la del propio jugador que se está insertando (`new.player_id`). El bug en `validar_cupo_categoria_cruzado` era latente (no se había manifestado porque ninguna categoría de prueba tenía `cupo_maximo` configurado) y se corrigió proactivamente por compartir el mismo patrón. |
| 107 | `107_grupos_y_salidas.sql` | Nuevo módulo: grupos de salida por ronda (quién juega junto, hora y hoyo de salida), paso siguiente después de inscripciones/cupos según el proceso oficial del R&A Committee Procedures. `tournaments.jugadores_por_grupo` (individual, default 4, configurable por torneo — igual que `jugadores_por_equipo`). `tournament_rounds.formato_salida` (`tee_times`/`shotgun`, por ronda). `tournament_groups`: hora + hoyo de salida; en modo equipo lleva `tournament_team_id` obligatorio (el grupo siempre es el equipo completo, sin mezclar); en modo individual usa `tournament_group_players` para los jugadores. Validaciones: el hoyo debe pertenecer al campo de la ronda; doble salida en un mismo hoyo solo si es par 4 o 5 (nunca par 3, por el cuello de botella físico); un equipo o jugador no puede repetirse en dos grupos de la misma ronda (sí puede cambiar de grupo entre rondas distintas); tamaño máximo de grupo respeta `jugadores_por_grupo`. Fase 1: solo armado manual — la sugerencia automática de grupos queda pendiente. **Validado por completo con datos reales (agosto 2026):** en formato `tee_times` (torneo individual) — grupo válido de 4, rechazo por exceder máximo, doble salida permitida en par 5, doble salida rechazada en par 3, rechazo por hoyo de otro campo; en formato `shotgun` (torneo de equipos, "LOS MALETAS") — grupo válido con `tournament_team_id`, rechazo sin `tournament_team_id`, rechazo por equipo duplicado en la misma ronda, y confirmado que un par 3 sí funciona como primer grupo de un hoyo (la restricción de par 4/5 solo aplica al SEGUNDO grupo). Los 7 triggers del módulo quedaron confirmados. Pendiente real: toda la pantalla de organizador (Lovable) para este módulo — hoy solo existe el backend. |
| 108 | `108_rls_grupos_y_salidas.sql` | Corrección de bug real detectado por Lovable al construir la Fase 2 (pantalla "Armar grupos de salida"): `tournament_groups` y `tournament_group_players` (107) se crearon sin políticas RLS, dejando select/insert rechazados o completamente abiertos según el estado de RLS en la tabla. Se replicó el mismo criterio ya usado en tablas equivalentes: `tournament_groups` sigue el patrón de `tournament_round_shifts` (lectura pública si `activo`, escritura solo para superadmin/organizador/club_admin del torneo); `tournament_group_players` sigue el patrón de `tournament_registrations` (el propio jugador ve sus filas vía `players.auth_user_id`, escritura solo para roles administrativos — el jugador no se auto-asigna a un grupo). |
| 109 | `109_pago_transferencia_prereserva.sql` | Nuevo flujo: el organizador registra el pago de una pre-reserva por transferencia (recibida por correo/WhatsApp fuera de la plataforma), adjuntando el comprobante — no se puede confirmar el pago sin comprobante adjunto. Hallazgo previo a esto: `tournament_registrations_insert` (RLS) solo permite `is_superadmin`, ni organizador ni club_admin pueden insertar directo — en vez de abrir esa política, se crean 2 funciones `SECURITY DEFINER` que validan el rol de quien llama. Bucket privado `comprobantes-transferencia` (convención de path obligatoria: `{tournament_id}/{pre_reserva_id}/{archivo}`, de la que dependen las políticas de Storage). Tabla `comprobantes_transferencia`: permite varios intentos por pre-reserva. **⚠️ Corregida por la migración 110** — ver esa fila para el detalle: esta versión original duplicó lógica que ya existía en `confirmar_pago_prereserva()` (050) y causó un bug real (no actualizaba `estatus` de la pre-reserva). Pendiente futuro anotado: extracción automática del monto por IA/OCR desde el comprobante (viable según pruebas con documentos reales de BBVA, pero es una Edge Function nueva — se deja como mejora, no bloqueante, ya que la comparación de monto es solo informativa). |
| 110 | `110_fix_confirmar_pago_transferencia.sql` | Corrección de bug real y de diseño en la 109: `confirmar_pago_transferencia_prereserva()` duplicó la lógica de crear la inscripción en vez de reutilizar `confirmar_pago_prereserva()` (050), que ya existía y lo hacía correctamente — incluyendo actualizar `tournament_pre_reservations.estatus` a `'pagado'`, algo que la versión original nunca hacía (solo vinculaba `tournament_registration_id`), causando que la pantalla de "Reservas previas" siguiera mostrando "Pendiente de pago" pese a que el pago ya estaba procesado. Fix: ahora llama a `confirmar_pago_prereserva()` en vez de reinsertar — hereda automáticamente la actualización de estatus, resolución de `admin_id` vía `admin_users`, y la bandera de sesión que evita el conflicto de cupo de equipo ya conocido. También cambia `tarifa_esperada`: en vez de recalcular `tarifa_vigente_torneo()` al momento del pago, usa `tournament_pre_reservations.monto` — el precio ya fijado desde que se creó la pre-reserva (evita falsas alertas de "diferencia" si la tarifa early bird cambió entre la pre-reserva y el pago). `subido_por`/`confirmado_por` ahora resuelven `admin_users.id`, no el UUID crudo de `auth.uid()` — consistente con el resto del sistema. Requirió una corrección de datos manual, aparte de la migración, para el caso real que quedó a medias con la versión anterior (pre-reserva de Lucrecia Chea). |
| 111 | `111_borrar_turno_vacio.sql` | Nueva capacidad: permite borrar físicamente un `tournament_round_shift` (turno) SOLO si ya está desactivado y no tiene ningún `tournament_groups` asociado (vacío, nada que perder) — si tiene grupos armados, se rechaza y debe permanecer desactivado, preservando el patrón de baja lógica usado en todo el resto del proyecto. Motivado por un caso real: el organizador desactivó un turno de prueba vacío y quería liberar su `numero_turno` para no dejar huecos en la numeración visible al crear el siguiente. De paso se aclaró una confusión real de conceptos: `tournaments.cupo_maximo` (techo total del torneo, validado por 104) y `tournament_round_shifts.cupo_maximo` (cupo de ese turno específico) son campos independientes sin relación automática entre sí — cambiar uno no actualiza el otro, por diseño. |
| 112 | `112_borrar_grupo_vacio.sql` | Simétrico a la 111: permite borrar físicamente un `tournament_groups` SOLO si ya está desactivado y no tiene ningún jugador en `tournament_group_players` (torneos individuales). En torneos de equipo, un grupo nunca tiene filas ahí (los jugadores vienen implícitos por `tournament_team_id`), así que el candado siempre se cumple con solo desactivar. Completa el flujo de limpieza de abajo hacia arriba: vaciar grupo → desactivar grupo → borrar grupo → desactivar turno (ya sin grupos activos) → borrar turno (111) — liberando la numeración de turno para reutilizar sin perder historial de grupos que sí tuvieron jugadores reales. |
| 113 | `113_validar_cupo_turnos_no_exceda_torneo.sql` | Corrección de bug real: no existía validación de que la suma de `tournament_round_shifts.cupo_maximo` (turnos) de una misma ronda no excediera `tournaments.cupo_maximo` (techo total del torneo, 104) — caso real: torneo con cupo 50, turno 1 con cupo 20 + turno 2 creado con cupo 40 sumaban 60, y el sistema lo dejó pasar sin aviso. Ahora, al crear/editar un turno, se valida que la suma de cupos de todos los turnos ACTIVOS de esa ronda (incluyendo el que se guarda) no exceda el cupo del torneo — si el turno se está desactivando, no se cuenta su propio cupo en la suma (para no bloquear la desactivación). |
| 114 | `114_fix_visibilidad_jugadores_precargados.sql` | Corrección de bug real (candado circular) detectado durante el análisis del módulo de patrocinadores: `jugador_visible_para_organizador()` solo hacía visible a un jugador si YA tenía inscripción o pre-reserva activa con ese organizador — un jugador recién precargado (cortesía de patrocinador, o cualquier precarga manual como el caso de prueba de Noriega) no tenía ninguna todavía, así que el organizador que ACABA de crearlo no podía verlo en la pantalla de catálogo hasta que alguien lo inscribiera primero. Fix: nueva columna `players.created_by` (resuelta automáticamente a `admin_users.id` vía trigger, el cliente nunca la manda directo — evita suplantación), y `jugador_visible_para_organizador()` ahora también considera visible a un jugador si el organizador fue quien lo precargó. |
| 115 | `115_patrocinadores.sql` | Nuevo módulo completo: patrocinadores para torneos de beneficencia (solo `tournaments.es_beneficencia = true`). Catálogos globales y compartidos `tipos_apoyo_patrocinio` y `derechos_patrocinador` (crecen con el uso de cualquier organizador — mayoría sí/no por existencia de la fila, algunos con `cantidad`, ej. jugadores cortesía, comida de premiación; es solo ayuda de memoria, no bloquea nada). `categorias_patrocinador` por torneo (no todos ofrecen lo mismo), con tipos de apoyo (M:N, un patrocinador puede dar dinero Y premios) y derechos asignados. Tabla `patrocinadores` (datos de contacto, recibo deducible propio — separado del sistema de recibo deducible de jugadores, 060/061). `patrocinador_jugadores_cortesia`: el organizador precarga al jugador en `players` (patrón Noriega) y lo vincula al patrocinador en el mismo paso — sin inscribirlo todavía. `tournament_registrations` gana `origen_inscripcion` (enum nuevo, NO se tocó `medio_pago` para no arriesgar que un valor de cortesía se filtre al selector de pago de la PWA del jugador) y `patrocinador_id`. Inscripción **automática**: en cuanto el perfil del jugador queda completo (mismo criterio que `validar_perfil_completo_para_inscripcion`), un trigger inscribe solo, sin pasar por pago, reutilizando el `INSERT` normal (pasa por todos los triggers existentes de categoría/marca/cupo — jugadores cortesía sí cuentan hacia `cupo_maximo`, confirmado con el organizador). RLS completo en las 7 tablas nuevas, incluido desde el inicio esta vez (lección aprendida de 107/108). |
| 116 | `116_bucket_constancias_fiscales_patrocinadores.sql` | Bucket de Storage privado `constancias-fiscales-patrocinadores` para `patrocinadores.constancia_fiscal_storage_path` (115) — separado del bucket de jugadores (`constancias-fiscales`, 061) porque el criterio de acceso es distinto: solo roles administrativos del torneo, nunca el propio patrocinador (no tiene cuenta en la plataforma). Convención de ruta obligatoria: `{tournament_id}/{patrocinador_id}/{archivo}`, misma lógica que `comprobantes-transferencia` (109). |
| 117 | `117_derechos_requiere_cantidad.sql` | Corrección de bug de diseño detectado por el usuario: `derechos_patrocinador` (115) no tenía forma de declarar si un derecho es cuantificable (ej. "Jugadores cortesía") o simple sí/no (ej. "Imagen en campo") — sin este dato, el frontend tendría que hardcodear por NOMBRE cuáles derechos muestran el campo de cantidad, rompiéndose cada vez que se agregue un derecho cuantificable nuevo al catálogo. Nueva columna `requiere_cantidad boolean default false` — el catálogo mismo declara su comportamiento, el frontend solo lo consulta. |
| 118 | `118_restringir_edicion_catalogos_patrocinio.sql` | Ajuste de permisos: en `tipos_apoyo_patrocinio` y `derechos_patrocinador` (115), cualquier admin activo sigue pudiendo AGREGAR entradas nuevas (así crecen los catálogos compartidos), pero EDITAR una entrada ya existente queda restringido solo a superadmin — para tener control sobre cambios que podrían impactar a otros organizadores, ya que son catálogos compartidos. Reemplaza la política `for all` original de la 115 por políticas separadas de insert/update/delete. |
| 119 | `119_patrocinador_tipos_apoyo_real.sql` | Hueco detectado antes de construir la Fase 4 de Lovable: `categoria_patrocinador_tipos_apoyo` (115) es solo el "menú" descriptivo de lo que una categoría típicamente ofrece — pero cada patrocinador real da una combinación propia y cuantificada, distinta de otros de la misma categoría (ej. "Sushiitto": $100,000 en dinero + $15,000 en comida en campo, sin usar sus 4 jugadores cortesía). Nueva tabla `patrocinador_tipos_apoyo` (`patrocinador_id`, `tipo_apoyo_id`, `monto`, `descripcion`) — el monto se captura en la moneda del torneo (`tournaments.moneda`, ya existente), sin duplicar ese campo. Coexiste con la tabla de categoría (una es el menú de referencia, la otra el registro real). |
| 120 | `120_vista_total_apoyo_patrocinador.sql` | Vista `patrocinadores_con_total` — suma calculada (no columna guardada) de `patrocinador_tipos_apoyo.monto` por patrocinador, para no arriesgar datos duplicados que se desincronicen (patrón repetido varias veces en esta sesión: preferir cálculo sobre duplicación). Corrección propia importante durante la escritura: `security_invoker = true` es obligatorio en la definición de la vista — sin esto, una vista de Postgres corre con los permisos de quien la creó, no de quien la consulta, lo que se habría saltado RLS por completo y expuesto todos los patrocinadores de todos los torneos. Requiere PostgreSQL 15+. |
| 121 | `121_resumen_apoyo_por_tipo.sql` | Vista `resumen_apoyo_por_tipo_patrocinador` — agrupa `patrocinador_tipos_apoyo` por tipo de apoyo dentro de cada torneo (`total_valorado`, `num_patrocinadores`), para alimentar la gráfica de pay del "Panorama de patrocinios": tamaño de cada rebanada por valor monetario, no por número de patrocinadores (confirmado con el usuario). Mismo patrón de seguridad que 120 (`security_invoker = true`). |
| 122 | `122_cupo_cortesias_y_equipos_automaticos.sql` | Rediseño tras revisión completa del flujo (no solo la última pregunta puntual): "Jugadores cortesía" (van a jugar golf: perfil, categoría, hándicap, cupo, equipo) y "Comida de premiación" (solo invitados a la cena, sin jugar, sin perfil de jugador) son conceptualmente distintos aunque ambos "hablen de personas" — dejan de ser entradas del catálogo genérico de derechos (se desactivan esas entradas si existían, para no duplicar el dato) y se vuelven campos dedicados en `patrocinadores`: `cupo_jugadores_cortesia` (editable, real) e `invitados_comida_premiacion` (solo contador para catering, nunca toca `players` ni `tournament_registrations`). Trigger nuevo: si el torneo es de formato equipo y el cupo es mayor a 0, crea automáticamente tantos equipos como hagan falta (`CEIL(cupo / jugadores_por_equipo)`), nombrados con el nombre del patrocinador — el organizador acomoda manualmente a cada jugador cortesía en el equipo que corresponda al inscribirlo, sin reparto automático. Corrección propia durante la escritura: se agregó `tournament_teams.patrocinador_id` (relación real) en vez de comparar nombres con `LIKE`, que habría fallado con patrocinadores de nombres parecidos entre sí. |
| 123 | `123_baja_jugador_cortesia.sql` | Hueco detectado: `patrocinador_jugadores_cortesia` (115) se creó sin el patrón de baja lógica usado en todo el resto del proyecto. Caso real: el patrocinador da un nombre de jugador que después no puede jugar y hay que reemplazarlo. Se agregan `activo`/`fecha_baja`/`dado_de_baja_por`/`motivo_baja`, y la función `dar_de_baja_jugador_cortesia()`: si el jugador YA se había inscrito automáticamente (badge "Inscrito"), también cancela esa inscripción (`tournament_registrations.activo = false`), liberando su lugar del cupo total y de categoría automáticamente (esos triggers solo cuentan filas activas). Dos escenarios distinguidos: error de captura (misma persona, dato mal escrito) → ya funciona hoy vía `players_update` gracias al fix de visibilidad de la 114, sin cambios necesarios; reemplazo real (persona distinta) → usa esta baja + el flujo normal de "Agregar jugador cortesía" para el reemplazo. |
| 124 | `124_auto_registro_completo_y_cortesias_ligeras.sql` | Rediseño mayor tras una reflexión completa sobre el flujo de registro de jugadores (no solo un ajuste puntual). **Nota de corrección:** originalmente se sospechó que el auto-registro estaba bloqueado por `shouldCreateUser: false` en el frontend — Lovable confirmó que ya estaba en `true`, esa hipótesis fue incorrecta. La causa real de por qué un correo específico de prueba nunca recibía el código quedó sin resolver tras un diagnóstico exhaustivo (se descartaron: rate limits, triggers en `auth.users`/`auth.identities`, errores de Postgres, Auth Hooks, Attack Protection, SMTP, URL del proyecto, payload) — se resolvió probando con un alias `+` de Gmail, y no bloquea el uso real de la plataforma; queda anotado como curiosidad pendiente, no como bug activo. **A)** Nuevo trigger `validar_registro_completo_jugador()`: exige todos los datos salvo GHIN/club/número de membresía (opcionales, solo aplican a socios) — pero SOLO cuando `auth_user_id` ya viene puesto desde el `INSERT` (señal de auto-registro real); la precarga administrativa (que llega con `auth_user_id` en `NULL`, como usa `phone_reservations`) sigue funcionando exactamente igual, sin tocarse. **B)** `patrocinador_jugadores_cortesia` migra al mismo patrón ya probado con `phone_reservations` (070): deja de crear una fila en `players` de entrada — si el correo ya existe se vincula directo, si no, guarda solo nombre+correo como intención (`player_id` ahora nullable). Nueva función `vincular_jugador_cortesia()` reemplaza el flujo anterior. **C)** Trigger de reconciliación ampliado (`reconciliar_y_auto_inscribir_cortesia`, reemplaza al de la 115) — cubre tanto `INSERT` (auto-registro nuevo, vincula + inscribe en un solo paso) como `UPDATE` (precargado que completa su perfil después). **Validado con caso real** (agosto 2026): auto-registro completo confirmado funcionando de punta a punta. |
| 125 | `125_busqueda_cortesia_y_retorno_ampliado.sql` | Dos ajustes detectados al probar `vincular_jugador_cortesia()` con un caso real: (1) el formulario pedía nombre/apellido aunque el correo ya existiera en el catálogo, con riesgo de guardar un nombre distinto al ya registrado — nueva función `buscar_jugador_por_correo()`, acotada (solo nombre, no expone el catálogo completo), para prellenar de solo lectura si hay coincidencia. (2) `vincular_jugador_cortesia()` no le decía al frontend si vinculó directo o creó una intención pendiente — cambia su tipo de retorno a una fila (`cortesia_id`, `player_id`, `vinculado_directo`). Esto importa porque el envío de invitación por correo **vive en el frontend, no en un trigger de base de datos** (confirmado revisando los triggers de `phone_reservations`: ninguno llama a Resend ni a una Edge Function) — Lovable debe disparar explícitamente esa misma invitación cuando `vinculado_directo = false`. |
| 126 | `126_precaptura_propia_para_registro.sql` | Mejora detectada al probar el flujo completo: cuando alguien con una intención de cortesía pendiente (nombres/apellidos capturados por el organizador) completa su propio registro en la PWA, el formulario no mostraba esos datos ya capturados. Nueva función `obtener_precaptura_propia()` — el jugador autenticado consulta SUS propios datos precapturados, resuelto internamente por su correo real de `auth.users` (nunca por un parámetro manipulable, para no exponer datos de otra persona). Los campos quedan editables en el formulario, solo como valor inicial sugerido. |
| 127 | `127_resolver_categoria_desde_cero.sql` | Bug real confirmado con datos reales (equipo "SUSHIITTO", torneo de categorías normales — no franjas): un equipo SIN categoría asignada en absoluto deja también la inscripción sin categoría. La lógica de reasignación existente (099/100) solo sabe "corregir" una categoría YA elegida — sin categoría de partida, nunca se activa (sus queries dependen de comparar contra `tournament_category_id`, que sin valor no matchea nada), dejando al jugador sin categoría ni marca de salida pese a tener hándicap declarado. Nota aparte: la pantalla de Lovable mostraba "UNICA" junto a estos jugadores, pero es solo una etiqueta visual del frontend — ni el equipo ni la inscripción tenían esa categoría (ni ninguna otra) realmente guardada, confirmado por consulta directa. Fix: nueva rama en `resolver_categoria_y_marca()` — cuando no hay categoría de partida, busca DIRECTO la que corresponde por hándicap/sexo entre todas las del torneo, sin necesitar una previa que "corregir". Aplica igual a equipos sin categoría y a individuales sin categoría elegida. Incluye corrección de datos puntual para los dos jugadores reales que ya habían quedado sin marca. |
| 128 | `128_asignar_categoria_al_resolver_franjas.sql` | Ajuste visual: se descubrió que el torneo real usado en las pruebas (b39d4e83) SÍ tiene franjas configuradas (contrario a lo asumido en la 127) — la resolución correcta ya pasaba por la rama de franjas, no por la nueva rama de categorías de la 127. Al resolver por franjas, la inscripción se quedaba sin `tournament_category_id` (funciona bien, la marca no depende de tener categoría en ese modelo, pero se ve inconsistente en la pantalla "Jugadores inscritos" frente a otros jugadores que sí muestran "UNICA"). Fix: al resolver por franjas, también se asigna la categoría del torneo (asume categoría única — una sola fila en `tournament_categories`) para consistencia visual, sin afectar la lógica de marca ya resuelta. Incluye corrección de datos puntual. |

| 129 | `129_categorias_por_turno.sql` | **Fase 1 de preparación de salidas Shotgun.** Nueva relación `tournament_round_shift_categories` entre turnos de una ronda y las categorías específicas del torneo (`tournament_categories`). Una categoría activa solo puede pertenecer a un turno de la misma ronda, aunque puede asignarse nuevamente en otras rondas. Si la ronda tiene un único turno activo, todas las categorías del torneo se asignan automáticamente; con varios turnos, la distribución queda manual. La asignación valida que la categoría corresponda al mismo torneo y, en configuración manual, que los jugadores inscritos de las categorías asignadas no excedan `tournament_round_shifts.cupo_maximo`. Incluye RLS, auditoría, baja lógica, sincronización automática al crear/reactivar turnos y backfill para rondas activas existentes. **No modifica todavía** `tournament_groups`, tamaño de grupos, equipos por grupo, reglas A/B ni generación de tarjetas. |
| 130 | `130_configuracion_shotgun_por_categoria.sql` | **Fase 2 de preparación de salidas Shotgun.** Crea `tournament_shotgun_category_configs` para definir por categoría y turno el tamaño normal del grupo, el máximo excepcional y el desfase en minutos de la salida B; la unidad se deriva de `tournament_formats.tipo_participacion` (jugadores en individual, equipos en torneo por equipos). Crea `tournament_shotgun_category_holes` para que el organizador seleccione los hoyos de salida de cada categoría y decida hoyo por hoyo si existe salida doble A/B. Un mismo hoyo queda reservado a una sola categoría dentro del turno y debe pertenecer al campo de la ronda. Solo se permite configurar rondas `shotgun`. Incluye RLS, auditoría, baja lógica y validaciones. **No modifica todavía** `tournament_groups`, no asigna jugadores/equipos y no elimina aún la validación histórica de doble salida por Par 4/5 en grupos. |
| 131 | `131_adaptacion_estructural_grupos_shotgun.sql` | **Fase 3A del motor Shotgun.** Adapta `tournament_groups` sin destruir su estructura histórica: agrega `tournament_shotgun_category_hole_id` y `posicion_salida` (`A`/`B`), con unicidad de posición activa por hoyo Shotgun configurado. Crea `tournament_group_teams` para permitir uno o varios equipos completos dentro del mismo grupo físico, manteniendo `tournament_groups.tournament_team_id` temporalmente como campo LEGACY. Hace backfill de equipos históricos hacia la nueva tabla y agrega validaciones estructurales de coherencia torneo/turno/hoyo. **No modifica todavía** las validaciones de doble salida por PAR, máximo de integrantes, equipo único por ronda ni la exigencia histórica de un único team_id en `tournament_groups`; esas reglas se adaptarán en la siguiente fase. |
| 132 | `132_adaptar_reglas_grupos_shotgun.sql` | **Fase 3B del motor Shotgun.** Adapta las validaciones de `tournament_groups`, `tournament_group_players` y `tournament_group_teams` al modelo de posiciones A/B y equipos completos introducido en 131. Elimina la dependencia histórica del PAR para permitir salida doble según la configuración Shotgun, valida coherencia de grupo/turno/hoyo/categoría y aplica reglas distintas para participación individual y por equipos. |
| 133 | `133_optimizar_rls_shotgun_holes.sql` | Optimiza las políticas RLS de `tournament_shotgun_category_holes` mediante helpers `SECURITY DEFINER` (`can_view_tournament_shotgun_config` / `can_manage_tournament_shotgun_config`) para eliminar la expansión costosa de RLS que provocaba lentitud y `statement timeout` al modificar `salida_doble`. |
| 134 | `134_integridad_categorias_equipos.sql` | Refuerza la integridad de categorías deportivas en torneos por equipos: corrige `NULL` cuando la categoría es inequívoca, exige categoría explícita en multicategoría, mantiene separada la categoría comercial del patrocinador y protege server-side el cupo de equipos de cortesía. |
| 135 | `135_persistencia_autosave_salidas_shotgun.sql` | Implementa persistencia/autosave de la conformación Shotgun: materialización inicial, movimientos incrementales de jugadores/equipos sin redistribuir terceros, creación/reactivación de grupo destino, baja lógica de grupo vacío, bandeja de no asignados, advisory locks e `hora_salida` calculada con timezone real del campo. |
| 136 | `136_congelar_condiciones_y_handicaps.sql` | **Fase 1 del motor de resultados.** Congela condiciones deportivas y hándicaps del torneo mediante snapshots inmutables por ronda/jugador; calcula Course Handicap y Playing Handicap, soporta tee por inscripción/ronda, genera preview de errores/advertencias y expone estado ligero para UI. No crea todavía tarjetas ni resultados. |
| 137 | `MIGRACION-136-preview-tarjetas-score-shotgun-individual.sql` | Incorpora la RPC `obtener_preview_tarjetas_score_shotgun_individual(uuid)` para construir el preview de tarjetas de score de Stroke Play individual + Shotgun a partir de la conformación persistida. El archivo histórico conservó el nombre `MIGRACION-136...`; en la secuencia documental corresponde al bloque posterior al congelamiento. Es preview: no emite tarjeta oficial, folio definitivo ni QR. |
| 138 | `138_secuencia_y_reactivacion_rondas.sql` | Endurece la secuencia obligatoria de rondas `1..N` y agrega `crear_o_reactivar_siguiente_ronda()`: impide exceder `tournaments.numero_rondas`, saltar números o crear una ronda posterior mientras la inmediata exista inactiva; permite reactivar la siguiente ronda cuando corresponde y respeta el congelamiento deportivo. |
| 139 | `139_visibilidad_rondas_inactivas.sql` | Ajusta RLS de `tournament_rounds` para que visitantes sólo vean rondas activas y administradores autorizados puedan consultar también rondas inactivas para reactivarlas. Reutiliza `puede_administrar_congelamiento_torneo()` y revoca ejecución a `anon`/`PUBLIC` sobre el helper administrativo. |
| 140 | `140_validacion_y_cierre_salidas_ronda.sql` | Implementa validación, versionado y cierre de salidas por ronda. Crea fotografías inmutables de grupos/unidades, RPC de preview/estado/validación/reapertura, hash de contenido, auditoría y bloqueos server-side sobre la conformación mientras exista una validación activa. Primer motor: Stroke Play individual + Shotgun. No genera tarjetas oficiales, folios, QR ni PDF emitido. |
| 141 | `141_corregir_validador_categorias_vacias_y_utf8.sql` | Hotfix del validador de 140: `categoria_turno_sin_configuracion` sólo exige configuración Shotgun a categorías con participantes elegibles congelados; las categorías sin inscripciones dejan de bloquear la validación. Corrige además textos con mojibake UTF-8 en las RPC de revisión/validación. Verificación funcional: 11 categorías activas, 3 con elegibles, 8 vacías ignorables y 0 elegibles sin configuración bloqueante. |
| 142 | `142_historial_validacion_reapertura_salidas.sql` | Agrega `public.obtener_historial_validacion_salidas_ronda(uuid)`, RPC de solo lectura para consultar el historial auditable y versionado de validaciones y reaperturas por ronda: versión, estado, quién/cuándo validó, quién/cuándo reabrió, motivo, motor, hash y conteos. No modifica la lógica de validación/reapertura ni genera tarjetas, folios, QR o PDF. |
| 143 | `143_emision_oficial_tarjetas_score.sql` | Crea la infraestructura de **emisión oficial de tarjetas de score** a partir de una versión validada de las salidas: cabecera `tournament_score_card_emissions`, tarjetas `tournament_score_cards`, folio y QR propios de tarjeta, RPC idempotente `emitir_tarjetas_score_ronda(uuid)`, estado ligero de emisión y bloqueo de reapertura normal después de emitir. El QR existente en `tournament_registrations.qr_token` queda intacto y reservado para el futuro módulo de control de acceso. Primera versión: Stroke Play individual + Shotgun. No captura golpes ni genera PDF. |
| 144 | `144_snapshot_tee_efectivo_ronda_CORREGIDA.sql` | Completa la fotografía histórica del tee efectivo sin modificar snapshots inmutables. Crea `tournament_round_handicap_tee_snapshots`, tabla complementaria 1:1 con nombre/color del tee, backfill por INSERT para snapshots existentes y trigger `AFTER INSERT` para snapshots futuros. La primera versión de 144 fue descartada porque intentaba UPDATE sobre snapshots congelados y fue correctamente rechazada por la protección `55000`. No toca QR/folio de inscripción ni de tarjeta. |
| 145 | `145_payload_oficial_tarjetas_score_snapshots.sql` | Agrega `obtener_payload_tarjetas_score_oficiales_ronda(uuid)`, RPC de solo lectura para reconstruir el payload oficial de una ronda emitida exclusivamente desde emisión + validación + snapshots históricos de hándicap, tee (144), condiciones y hoyos. Usa `tournament_score_cards.card_folio` y `tournament_score_cards.qr_token`; no depende de `tournament_groups` vivos, `distancias_hoyo`, `marcas_salida` ni del QR/folio de inscripción. No genera PDF. |
| 146 | `146_nucleo_captura_scores_pwa.sql` | Crea el núcleo transaccional de captura de **GROSS por hoyo** para PWA: sesiones por tarjeta, asignación circular de marcador basada en `order_in_group` congelado, scores por hoyo con `play_sequence` Shotgun, confirmación/disputa por el dueño y bitácora inmutable. El QR de tarjeta sólo localiza; la autorización se resuelve con `auth.uid() → players.auth_user_id`. No calcula NETO, leaderboard, cortes ni cierre físico. |
| 147 | `147_lectura_pwa_detalle_captura_score.sql` | Agrega `obtener_detalle_captura_tarjeta_score(uuid)` para abrir de forma segura una tarjeta por `score_card_id` y devolver marcador vigente, salida, estado de captura, hoyos en `play_sequence`, PAR/SI, GROSS/status y permisos derivados. Amplía `obtener_mi_panel_scores_ronda(uuid)` con `markerDisplayName`. No expone QR ni habilita escritura. |

## Migraciones 132–141 — continuidad recuperada

> **Nota de recuperación documental (18-ago-2026):** este README conserva íntegro el contenido histórico 001–131 del archivo maestro recuperado y reincorpora la continuidad 132–141 a partir de los SQL, verificadores y README de fase disponibles. El objetivo es restablecer un único README acumulativo como fuente documental del repositorio.

### Migración 132 — Reglas de grupos Shotgun

- Adapta las reglas de integridad al modelo estructural creado en 131.
- Las posiciones Shotgun son `A` / `B`; la salida doble depende de la configuración del hoyo, no del PAR.
- Se validan las relaciones entre ronda, turno, categoría, configuración, hoyo y grupo.
- `tournament_group_players` continúa representando unidades individuales y `tournament_group_teams` permite equipos completos.
- Verificador asociado: `SUPABASE-VERIFICAR-REGLAS-GRUPOS-SHOTGUN.sql`.

### Migración 133 — Optimización RLS de hoyos Shotgun

- Corrige la latencia/timeout observada al actualizar `tournament_shotgun_category_holes.salida_doble`.
- Crea helpers `SECURITY DEFINER` para lectura/administración de configuración Shotgun.
- Sustituye la expansión recursiva/costosa de RLS por comprobaciones encapsuladas.
- No modifica la lógica deportiva ni los datos de conformación.

### Migración 134 — Integridad de categorías en equipos

- La categoría deportiva es `tournament_categories.id`; no se mezcla con `categoria_patrocinador_id`.
- Regla 0/1/>1 categorías: `NULL` permitido sin categorías, autoasignación con una categoría y selección explícita en multicategoría.
- Corrige equipos/inscripciones/cortesías históricas cuando la categoría es inequívoca.
- Protege server-side el cupo máximo de equipos de cortesía.

### Migración 135 — Persistencia/autosave Shotgun

- Materializa una sola vez la propuesta inicial.
- Cada movimiento posterior se persiste de forma incremental y transaccional.
- Mover una unidad no redistribuye terceros.
- Puede crear/reactivar el grupo destino y dar de baja lógica al origen vacío.
- Incluye salida a bandeja de pendientes y locks por configuración.
- Persistir no equivale a validar/cerrar.

### Migración 136 — Congelamiento de condiciones y hándicaps

- Crea `tournament_condition_freezes` y snapshots normalizados por ronda/jugador.
- Congela formato, campo, hoyos, tees, Handicap Index y hándicaps calculados.
- Usa hándicap verificado cuando existe; de lo contrario puede usar declarado con advertencia.
- Los snapshots son inmutables.
- Los cortes quedan fuera del congelamiento para poder aplicarse después de cada ronda.

### Migración 137 — Preview de tarjetas

- La RPC `obtener_preview_tarjetas_score_shotgun_individual(uuid)` alimenta el preview/PDF existente.
- Es una representación previa de la conformación; no es emisión oficial.
- No genera identidad definitiva de tarjeta, folio oficial ni QR.
- Se conserva documentado el nombre histórico del SQL `MIGRACION-136-preview-tarjetas-score-shotgun-individual.sql`, aunque este bloque quedó ubicado después del congelamiento en la secuencia efectiva de trabajo.

### Migración 138 — Secuencia y reactivación de rondas

- Mantiene secuencia obligatoria `1..N`.
- No permite exceder `tournaments.numero_rondas`.
- No permite saltar una ronda inactiva para crear una posterior.
- `crear_o_reactivar_siguiente_ronda()` reutiliza una ronda inactiva cuando corresponde.
- Fue verificada con `14 verificaciones; 0 error(es)`.

### Migración 139 — Visibilidad de rondas inactivas

- Rondas activas: lectura pública.
- Rondas inactivas: sólo administradores autenticados autorizados.
- Permite que Lovable detecte una ronda inactiva que debe reactivarse.
- Conserva la policy de escritura y las reglas de secuencia/congelamiento.

### Migración 140 — Validación, versionado y cierre de salidas

- La validación pertenece a la ronda completa.
- Crea `tournament_round_start_validations`, `tournament_round_start_validation_groups` y `tournament_round_start_validation_units`.
- RPC públicas: `previsualizar_validacion_salidas_ronda`, `validar_salidas_ronda`, `obtener_estado_validacion_salidas_ronda` y `reabrir_salidas_ronda`.
- Una versión validada congela la fotografía de la salida y bloquea modificaciones server-side hasta reapertura.
- La reapertura conserva la versión anterior y exige motivo.
- Verificación: `31 verificaciones; 0 error(es)`.
- No crea tarjetas oficiales, folios, QR ni PDF emitido.

### Migración 141 — Hotfix del validador

- Corrige `categoria_turno_sin_configuracion`: sólo una categoría con participantes elegibles congelados requiere configuración Shotgun activa.
- Categorías vacías pueden permanecer asignadas al turno sin bloquear el cierre.
- Corrige mojibake UTF-8 en los mensajes de las RPC.
- Diagnóstico funcional posterior:
  - 11 categorías activas;
  - 3 con participantes elegibles;
  - 8 sin participantes elegibles;
  - 8 vacías sin configuración correctamente ignorables;
  - 0 categorías con elegibles sin configuración bloqueante.
- `configuracion_sin_hoyos` permanece como validación independiente para configuraciones activas existentes.

### Migración 142 — Historial auditable de validaciones y reaperturas

- Agrega la RPC de solo lectura `public.obtener_historial_validacion_salidas_ronda(uuid)`.
- La consulta exige sesión autenticada y permiso administrativo mediante `puede_administrar_congelamiento_torneo(tournament_id)`.
- `authenticated` puede ejecutar la RPC; `anon` y `PUBLIC` no.
- Devuelve por versión:
  - `version`;
  - `status`;
  - `validatedAt`;
  - `validatedBy` (`adminUserId`, `displayName`);
  - `reopenedAt`;
  - `reopenedBy` (`adminUserId`, `displayName`);
  - `reopenReason`;
  - `validatorEngine`;
  - `startFormat`;
  - `participationType`;
  - `scoringEngine`;
  - `contentHash`;
  - conteos de configuraciones, grupos y unidades.
- La migración no cambia `reabrir_salidas_ronda`; únicamente hace consultable la auditoría que el backend ya registra.
- No modifica snapshots, historial existente, triggers de cierre, RLS de tablas, tarjetas, folios, QR ni PDF.
- Después de verificarla, Lovable podrá integrar una bitácora humana de validaciones/reaperturas sin recibir UUID/JSON como presentación principal.
- La emisión oficial de tarjetas/folios/QR queda desplazada a la Migración 143.

### Estado al cierre de la 141

- El frontend de validación de salidas (Fases 1–6) permite consultar estado, revisar, aceptar advertencias, validar/cerrar, bloquear edición y reabrir con motivo.
- La auditoría de reapertura ya se guarda en backend (`reopen_reason`, `reopened_by`, `reopened_at`), aunque hasta la 141 todavía no existe una RPC específica para mostrar el historial completo.
- La emisión oficial de tarjetas/folios/QR sigue pendiente y debe ocurrir únicamente después de una salida validada.

### Migración 143 — Emisión oficial de tarjetas de score

- Crea `tournament_score_card_emissions` como cabecera auditable del acto de emisión.
- Crea `tournament_score_cards` con una tarjeta oficial por unidad validada.
- La emisión nace exclusivamente de:
  - `tournament_round_start_validations`;
  - `tournament_round_start_validation_groups`;
  - `tournament_round_start_validation_units`.
- No utiliza `tournament_groups` / `tournament_group_players` vivos para crear la tarjeta oficial.
- Primera versión habilitada: `stroke_individual_shotgun_v1`.
- La RPC `emitir_tarjetas_score_ronda(uuid)`:
  - exige sesión y permiso administrativo;
  - serializa por ronda con el mismo advisory lock de salidas;
  - exige una validación activa;
  - es idempotente si ya existe emisión activa;
  - verifica cantidad/tipo de unidades;
  - crea una emisión y una tarjeta por participante;
  - revierte toda la transacción si el número emitido no coincide con la validación.
- La RPC `obtener_estado_emision_tarjetas_ronda(uuid)` devuelve un estado ligero para frontend.
- Cada tarjeta tiene:
  - `card_number`;
  - `card_folio`;
  - `qr_token`;
  - vínculo a emisión, validación, grupo validado y unidad validada.
- El folio de tarjeta es independiente del folio de inscripción.
- **El QR de tarjeta es totalmente independiente del QR existente en `tournament_registrations.qr_token`.**
  - `tournament_registrations.qr_token` se conserva intacto para el futuro módulo de control de acceso a clubes/campos.
  - La Migración 143 no lo lee, no lo reemplaza y no lo actualiza.
- Mientras exista una emisión oficial activa:
  - `reabrir_salidas_ronda(uuid,text)` rechaza la reapertura;
  - un trigger adicional protege también una transición directa `validated -> reopened`.
- La anulación/reposición de una emisión oficial todavía NO está implementada. Las columnas `voided_*` quedan reservadas para una migración futura.
- Las tablas tienen RLS:
  - `authenticated` puede leer si administra el torneo;
  - `anon` no tiene acceso;
  - no existe escritura directa de cliente;
  - toda emisión pasa por RPC.
- Las emisiones y tarjetas son inmutables en esta fase.
- No captura resultados/golpes.
- No genera ni guarda PDF.
- No inicia la ronda deportivamente.

### Migración 144 — Snapshot complementario del tee efectivo

- La primera propuesta de 144 intentaba actualizar `tournament_round_handicap_snapshots` para rellenar nombre/color del tee.
- Esa operación fue correctamente bloqueada por la protección de inmutabilidad (`SQLSTATE 55000`).
- La versión corregida NO modifica snapshots existentes.
- Crea `tournament_round_handicap_tee_snapshots`, relación 1:1 con `tournament_round_handicap_snapshots`.
- Guarda de forma inmutable:
  - `tee_id`;
  - `tee_name`;
  - `tee_color_hex`.
- Para snapshots existentes, el backfill se realiza mediante INSERT en la tabla complementaria usando el catálogo actual de `marcas_salida`.
- Limitación histórica: si nombre/color cambió antes de aplicar 144, ese valor previo no puede reconstruirse retrospectivamente.
- Para snapshots futuros, `trg_crear_snapshot_tee_efectivo_ronda` crea automáticamente el complemento mediante AFTER INSERT, sin alterar la fila congelada principal.
- La tabla complementaria también es inmutable.
- No toca `tournament_registrations.qr_token` ni `tournament_score_cards.qr_token`.
- No cambia reglas de hándicap, Course Handicap, Playing Handicap, rating, slope ni yardas.

### Migración 145 — Payload oficial de tarjetas desde snapshots

- Agrega la RPC `public.obtener_payload_tarjetas_score_oficiales_ronda(uuid)`.
- La RPC es de sólo lectura, `SECURITY DEFINER`, exige sesión autenticada y permiso administrativo del torneo.
- Sólo trabaja cuando existe una emisión oficial activa de la ronda.
- La fuente de verdad es:
  - `tournament_score_card_emissions`;
  - `tournament_score_cards`;
  - `tournament_round_start_validations`;
  - `tournament_round_start_validation_groups`;
  - `tournament_round_start_validation_units`;
  - `tournament_handicap_snapshots`;
  - `tournament_round_handicap_snapshots`;
  - `tournament_round_handicap_tee_snapshots` (144);
  - `tournament_round_condition_snapshots`;
  - `tournament_round_hole_snapshots`.
- Reconstruye por tarjeta:
  - folio oficial;
  - QR oficial;
  - jugador congelado;
  - categoría congelada;
  - Handicap Index/origen/estatus;
  - Course Handicap y Playing Handicap;
  - tee efectivo con nombre/color congelados;
  - hoyo, posición A/B, turno, hora y orden;
  - compañeros del grupo validado;
  - PAR, Stroke Index y yardas históricas por tee;
  - totales OUT/IN/TOTAL.
- El payload NO usa `tournament_groups` ni `tournament_group_players` vivos.
- El payload NO usa `marcas_salida` ni `distancias_hoyo` vivas.
- El QR se toma de `tournament_score_cards.qr_token`, nunca de `tournament_registrations.qr_token`.
- El folio principal es `tournament_score_cards.card_folio`, no el folio de inscripción.
- Nombre/logo del torneo permanecen como datos institucionales vivos.
- La RPC valida que el número de tarjetas coincida con la emisión y que cada tarjeta tenga vínculos completos a snapshots históricos.
- No genera PDF ni modifica emisión, tarjetas o snapshots.

### Migración 146 — Núcleo de captura de scores para PWA

- Crea `tournament_scorecard_capture_sessions`, una sesión operativa 1:1 por tarjeta oficial.
- Crea `tournament_scorecard_marker_assignments`, historial de quién marca la tarjeta de quién.
- Crea `tournament_scorecard_hole_scores`, una fila por tarjeta + hoyo congelado, con `hole_number`, `play_sequence`, `gross_score`, estados `pending / entered / confirmed / disputed`, marcador utilizado y confirmación/disputa del dueño.
- Crea `tournament_scorecard_events`, bitácora inmutable de captura, corrección, confirmación, disputa y cambio administrativo de marcador.
- Se captura únicamente **GROSS**. El NETO y resultados derivados no se almacenan en esta migración.
- `inicializar_captura_scores_ronda(uuid)` exige emisión oficial activa, crea sesiones/hoyos de forma idempotente, calcula el orden real Shotgun y genera el marcador circular desde `order_in_group` congelado.
- Regla circular: A marca B; B marca C; C marca D; D marca A.
- Grupos de un solo jugador quedan sin marcador automático; nunca se autoasigna al propio jugador.
- `asignar_marcador_tarjeta_score(...)` permite cambio administrativo explícito y auditado desde una secuencia futura.
- `registrar_score_hoyo(...)` sólo permite escribir al marcador vigente y bloquea expresamente la auto-captura.
- `confirmar_score_hoyo(uuid)` y `disputar_score_hoyo(uuid,integer,text)` sólo pueden ejecutarse por el dueño de la tarjeta.
- `abrir_captura_tarjeta_score(text)` usa exclusivamente `tournament_score_cards.qr_token` como localizador; no usa el QR de inscripción y no lo considera permiso de escritura.
- `obtener_mi_panel_scores_ronda(uuid)` entrega a la futura PWA la tarjeta propia y las tarjetas que el usuario marca, sin exponer QR.
- RLS: lectura sólo para dueño, marcador vigente o administrador autorizado; no existe escritura directa de cliente.
- Las tarjetas oficiales de la 143 permanecen inmutables.
- No incluye UI PWA, notificaciones, reconciliación de tarjeta física, NETO, leaderboard, cortes, desempates ni cierre oficial de resultados.

### Migración 147 — Lectura PWA del detalle de captura

- Agrega `obtener_detalle_captura_tarjeta_score(uuid)`.
- La RPC recibe `score_card_id`, no QR.
- Requiere sesión autenticada y valida acceso con el contrato de la Migración 146:
  - dueño de la tarjeta;
  - marcador vigente;
  - administrador autorizado.
- Devuelve:
  - folio y nombre del jugador;
  - grupo, orden, hoyo inicial, A/B, turno y hora;
  - nombre del marcador vigente;
  - estado/progreso de captura;
  - hoyos ordenados por `play_sequence`;
  - PAR y Stroke Index congelados;
  - `grossScore` y estado actual;
  - `canCapture`, `canConfirm` y `canDispute` derivados server-side.
- No devuelve ni consulta `qr_token`.
- No usa el QR/folio de inscripción.
- Amplía `obtener_mi_panel_scores_ronda(uuid)` para que `myCard` incluya `markerDisplayName`.
- `scoreCardId` se conserva en `myCard` y `cardsIMark` para navegación interna de la PWA.
- La migración es exclusivamente de lectura; no añade escrituras ni modifica el motor de captura GROSS.
- No implementa UI, notificaciones, NETO, leaderboard, cortes ni reconciliación física.

| 148 | `148_mis_rondas_score.sql` | Agrega `obtener_mis_rondas_score()`, RPC segura de solo lectura para que el jugador autenticado pueda descubrir sus rondas de scoring sin QR ni `roundId` externo. Deriva identidad con `auth.uid() → players.auth_user_id`, incluye rondas donde posee tarjeta emitida o es marcador activo, y devuelve metadatos mínimos de torneo/ronda y estado de inicialización. No amplía RLS de `tournament_score_cards` ni modifica captura. |
| 149 | `149_captura_fisica_tarjetas_score.sql` | Agrega la recepción y captura física de tarjetas oficiales sin sobreescribir la captura digital. Crea recepción 1:1 por tarjeta, scores físicos por hoyo y bitácora física append-only. Permite tarjeta física completa, parcial o sin captura digital en PWA; ese caso se considera válido y se denomina `SIN CAPTURA DIGITAL`. No implementa todavía conciliación, score oficial, NETO, leaderboard ni cortes. |
| 150 | `150_listado_captura_fisica_ronda.sql` | Elimina el patrón N+1 del listado administrativo de captura física. Agrega `obtener_tarjetas_captura_fisica_ronda(uuid)`, RPC `SECURITY DEFINER` de solo lectura que devuelve en una sola llamada las tarjetas emitidas de la ronda con jugador/unidad, categoría, marcador vigente, estado físico, firmas, recepción y progreso físico. No expone scores por hoyo, mantiene captura ciega, no usa QR y no implementa conciliación. |
| 151 | `151_lectura_conciliacion_scorecard.sql` | Agrega `obtener_conciliacion_tarjeta_score(uuid)`, RPC administrativa de solo lectura que, únicamente después de `CAPTURED`, consolida por hoyo el GROSS digital vigente, la inconformidad activa/histórica del jugador y el GROSS físico. Clasifica comparación (`COINCIDE`, `DIFERENCIA`, `SIN_CAPTURA_DIGITAL`, `PENDIENTE_CAPTURA_FISICA`) e inconformidad (`NONE`, `ACTIVE`, `HISTORICAL_PENDING`, `HISTORICAL_RESOLVED`) y deriva `needsReview`. No crea score oficial ni resoluciones. |
| 152 | `152_resolucion_conciliacion_scorecard.sql` | Agrega la capa auditable de resolución de conciliación sin sobreescribir DIGITAL, FÍSICO ni reclamos. Crea cabecera por tarjeta, resoluciones sólo para hoyos que requieren revisión y bitácora append-only. Fuentes: `DIGITAL`, `PHYSICAL`, `PLAYER_CLAIM`, `MANUAL`; MANUAL exige motivo. No crea todavía `official_gross_score`. |
| 153 | `153_score_oficial_consolidado_tarjeta.sql` | Agrega `obtener_score_oficial_tarjeta(uuid)`, RPC administrativa de solo lectura que construye el score oficial por hoyo únicamente después de captura física `CAPTURED` y conciliación `COMPLETED`. Los hoyos resueltos usan `resolved_gross_score`; los hoyos sin conflicto usan el valor físico inmutable, clasificando origen como `MATCHED` o `PHYSICAL_ONLY`. Devuelve `officialGrossScore`, `officialSource` y total GROSS oficial, sin sobrescribir evidencias ni materializar todavía una columna oficial. |
| 154 | `154_motor_neto_oficial_tarjeta.sql` | Construye el motor NETO oficial por tarjeta sin depender de categoría: consume el GROSS oficial de la 153, usa exclusivamente `playing_handicap` congelado y distribuye golpes por `stroke_index`. Calcula siempre GROSS y NETO por hoyo y totales, incluyendo plus handicaps. No materializa NETO ni implementa leaderboard/premiación. |
| 155 | `155_resultados_oficiales_masivos_ronda.sql` | Agrega `obtener_resultados_oficiales_ronda(uuid)`, fuente administrativa masiva y set-based por ronda. Devuelve en una sola llamada estado operativo, jugador/categoría/tee, snapshots de hándicap, GROSS oficial, NETO oficial y detalle por hoyo para tarjetas `OFFICIAL_READY`; las pendientes conservan estado e issues sin presentar totales como oficiales. No implementa posiciones, leaderboard ni premiación. |
| 156 | `156_estados_competitivos_terminales_ronda.sql` | Modela estados competitivos terminales sin reutilizar `score_cards.status`: `OFFICIAL` continúa derivado; excepciones de ronda `WD`, `DNF`, `DQ`, `DNS`, `NO_CARD` se registran y auditan. `DNF` conserva parciales. `MC/QUALIFIED` se modela aparte como estado de corte del torneo. Agrega validación de cierre de resultados: toda tarjeta debe ser `OFFICIAL_READY` o tener excepción terminal. No calcula todavía corte ni leaderboard. |
| 157 | `157_fix_cierre_resultados_null_outcome.sql` | Corrige `validar_cierre_resultados_ronda(uuid)`: una tarjeta sin outcome excepcional (`NULL`) se trata explícitamente como no resuelta cuando tampoco está `OFFICIAL_READY`. Evita el falso positivo `unresolvedCards=0 / readyToCloseResults=true` detectado en prueba real. No modifica datos ni tablas. |
| 158 | `158_leaderboard_ronda_gross_neto.sql` | Agrega `obtener_leaderboard_ronda(uuid)`: leaderboard derivado por ronda y categoría, siempre con clasificación GROSS y NETO. Sólo `OFFICIAL_READY` recibe posición; WD/DNF/DQ/DNS/NO_CARD permanecen visibles sin rank. Mientras haya tarjetas sin resolver el estado es `PROVISIONAL`; con ronda resuelta y empates pasa a `READY_FOR_TIEBREAK`; sin empates a `READY_FOR_PUBLICATION`. Detecta empates pero no aplica todavía desempates, cortes ni premiación. |
| 159 | `159_fix_tipo_holes_motor_neto_masivo.sql` | Corrige error 42883 detectado en la UI real: `count(*)` promovía `expected_holes` a `bigint` dentro de `obtener_resultados_oficiales_ronda(uuid)`, pero `calcular_golpes_handicap_hoyo` recibe `integer`. Se agrega cast explícito `r.expected_holes::integer`. No modifica datos, lógica GROSS/NETO ni leaderboard. |
| 160 | `160_motor_desempates_ronda.sql` | Agrega motor de desempates de sólo lectura: helpers puros para calcular claves por método y evaluar secuencias, más `obtener_desempates_ronda(uuid)`. Resuelve configuración efectiva por categoría/tipo/alcance con precedencia `CATEGORY_SCOPE → CATEGORY_ALL → TOURNAMENT_SCOPE → TOURNAMENT_ALL`; soporta countback 9/6/3/1, tarjeta completa y hoyo por hoyo por Stroke Index. Métodos manuales o empate persistente quedan pendientes; no materializa ni modifica leaderboard. |
| 161 | `161_persistencia_resolucion_manual_desempates.sql` | Agrega persistencia auditable de desempates manuales: cabecera, orden final de participantes y bitácora append-only; RPCs para consultar, resolver y anular. `MANUAL_PENDING` usa forzosamente el método manual configurado; `TIE_PERSISTS_AFTER_RULES` permite override administrativo con motivo obligatorio. No modifica scores, motor 160, leaderboard, premiación ni cortes. |
| 162 | `162_estado_cierre_competitivo_ronda.sql` | Agrega `obtener_estado_cierre_competitivo_ronda(uuid)`, integra cierre de tarjetas/outcomes, motor de desempates 160 y resoluciones manuales 161, y formaliza `PROVISIONAL`, `TIEBREAKS_PENDING` y `FINAL`. `FINAL` exige resultados completos y cero desempates pendientes. No materializa cierre, no modifica leaderboard y no implementa publicación, cortes ni premiación. |
| 163 | `163_provisionamiento_torneos_base.sql` | Base de provisionamiento comercial sin duplicar `tournaments`: agrega `estado_servicio` (`provisionado`, `activo`, `pausado`, `archivado`, `cancelado`), mantiene separado el estatus deportivo, permite `club_id`, `cupo_maximo` y `tournament_format_id` NULL durante provisionamiento, restringe la creación a Superadmin y protege cambios del estado de servicio. |
| 164 | `164_perfil_comercial_contratante_torneo.sql` | Agrega perfil comercial/fiscal 1:1 por torneo (`tournament_commercial_profiles`): contratante independiente del organizador, monto de plataforma, pagado/no pagado, datos de pago y ruta de Constancia Fiscal. Crea bucket privado `tournament-contract-fiscal-documents`. Lectura/escritura comercial y documentos restringidos a Superadmin. |
| 165 | `165_invitaciones_organizador_torneo.sql` | Agrega invitaciones para organizadores aún no registrados, sin crear usuarios falsos ni guardar contraseñas. Los organizadores existentes continúan usando `admin_role_assignments`. La invitación sólo reserva nombre/email/teléfono y no concede permisos hasta que exista un `admin_user` real y se materialice su asignación. |
| 166 | `166_rpc_provisionar_torneo.sql` | Agrega `provisionar_torneo(...)`, RPC transaccional exclusiva de Superadmin: crea torneo `provisionado` con `activo=false`, perfil comercial y, según el email, asignación directa a un organizador existente o invitación `pending`. No crea usuarios ni contraseñas. |
| 167 | `167_aceptacion_invitacion_organizador.sql` | Agrega `aceptar_invitacion_organizador_torneo(uuid,text,text)`: un usuario ya autenticado y con email verificado puede aceptar una invitación `pending` sólo si su email coincide. Crea/vincula `admin_users`, materializa `tournament_organizer` y marca la invitación `accepted`. No crea usuarios Auth ni contraseñas. |
| 168 | `168_trazabilidad_envio_invitacion_organizador.sql` | Agrega trazabilidad de envío a `tournament_organizer_invitations`: `last_sent_at`, `sent_count` y `last_sent_by`. No envía correos; prepara el control para el envío manual por Superadmin vía Resend. |
| 169 | `169_generalizacion_invitaciones_administrativas.sql` | Generaliza las invitaciones administrativas en `admin_user_invitations`, agrega rol/ámbito y unifica asignación, invitación y aceptación para `club_admin` y `tournament_organizer`. Adapta `provisionar_torneo` y conserva la RPC 167 como wrapper. |
| 170 | `170_V2_datos_estructurados_invitacion_admin.sql` | Agrega `nombres` y `apellidos` estructurados a `admin_user_invitations` y una aceptación simplificada que toma esos datos de la invitación. Conserva temporalmente firmas anteriores para una transición segura del frontend. |
| 171 | `171_provisionamiento_torneo_organizador_estructurado.sql` | Agrega una nueva firma de `provisionar_torneo` con nombres/apellidos separados y la conecta al motor administrativo estructurado de la 170. Conserva temporalmente la firma anterior para una transición segura del frontend. |
| 172 | `172_FASE1_conciliacion_desde_snapshots.sql` | Fase 1: `obtener_conciliacion_tarjeta_score` usa los snapshots de la ronda como universo de hoyos; la evidencia digital pasa a ser opcional y la física sigue siendo obligatoria. |
| 173 | `173_FASE2_finalizacion_resolucion_desde_snapshots.sql` | Fase 2: finalización y resolución usan snapshots como universo; físico incompleto bloquea, mientras físico sin digital no requiere resolución. |
| 174 | `174_FASE3_resultados_oficiales_desde_snapshots.sql` | Fase 3: resultados oficiales usan snapshots para hoyos esperados; físico es obligatorio y digital opcional, habilitando tarjetas 100% físicas sin crear sesiones digitales ficticias. |
| 175 | `175_categorias_elegibles_inscripcion.sql` | Centraliza la elegibilidad de categorías en inscripción individual: permite la categoría natural por hándicap y categorías superiores (menor hándicap), respeta género y categorías por edad como Senior, conserva categorías abiertas y overrides del torneo. Agrega `obtener_mis_categorias_elegibles_inscripcion(uuid)` para el frontend y actualiza `resolver_categoria_y_marca()` para respetar selecciones superiores válidas y rechazar categorías inferiores o incompatibles. No modifica equipos, franjas de categoría única ni inscripciones históricas. Verificación: 14/14 OK. |
| 176 | `176_control_administrativo_liberacion_torneo.sql` | Formaliza el cierre de configuración por el organizador y el control comercial previo a publicación. Agrega trazabilidad de configuración en `tournaments`, trazabilidad de pago/liberación en `tournament_commercial_profiles`, RPCs para finalizar/reabrir configuración, confirmar pago y liberar el torneo, además de `obtener_control_administrativo_torneos()` para la futura pestaña administrativa del Superadmin. La liberación exige configuración finalizada + pago confirmado y deja `estado_servicio=activo` con `activo=true`. Verificación: pendiente de ejecutar. |
| 177 | `177_telefono_permanente_admin_users.sql` | Incorpora `admin_users.telefono` como dato permanente del perfil administrativo. Recupera teléfonos históricos desde invitaciones aceptadas, actualiza `aceptar_invitacion_admin(uuid)` para copiar `admin_user_invitations.phone` al perfil y adapta ambas firmas de `asignar_o_invitar_admin(...)` para conservar/actualizar el teléfono de administradores existentes. No crea una tabla específica de organizadores: perfil en `admin_users`, roles y alcances en `admin_role_assignments`. |
| 178 | `178_categorias_elegibles_reserva_telefonica.sql` | Agrega `obtener_categorias_elegibles_jugador_inscripcion(uuid,uuid)` para que Superadmin u Organizador consulten las categorías elegibles de un jugador seleccionado en flujos administrativos como Reserva telefónica. Reutiliza `_categorias_elegibles_jugador(...)`, conserva las reglas de hándicap, género, edad, categoría natural y superiores, y devuelve rangos efectivos de hándicap. |
| 178 Fase 2 | `178_FASE2_FIX_CATEGORIA_ESTANDAR_MARCA_TEXT.sql` | Corrige la RPC administrativa de categorías elegibles: mantiene `categoria_estandar_marca` como `text` y castea explícitamente el enum `categoria_marca_salida` devuelto por `_categorias_elegibles_jugador(...)`. No cambia reglas de elegibilidad ni permisos. |
| 179 | `179_cupo_categoria_contacto_y_validacion_configuracion.sql` | Refuerza el cupo por categoría reutilizando `validar_cupo_categoria_cruzado()`: serializa altas por categoría, agrega el trigger faltante en `phone_reservations` y mantiene el conteo cruzado de inscripciones, pre-reservas y reservas telefónicas. Cuando el cupo está lleno devuelve `CATEGORY_FULL` con mensaje amigable y contacto del organizador. Agrega `obtener_cupos_categorias_torneo(uuid)` para consultar cupo, ocupados, disponibles y estado `llena` sin recalcular en frontend. Además, `validar_configuracion_minima_torneo()` exige cupo > 0 en todas las categorías y que su suma coincida con `tournaments.cupo_maximo`. |
| 179 Fase 2 | `179_FASE2_RPC_DISPONIBILIDAD_CATEGORIAS.sql` | Agrega `obtener_cupos_categorias_torneo(uuid)` como fuente única de consulta de cupo por categoría. Devuelve cupo máximo, inscripciones activas, pre-reservas activas no convertidas, reservas telefónicas activas, ocupados, disponibles y estado `llena`. No modifica triggers ni reglas de bloqueo de la Migración 179. |
| 180 | `180_bloquear_validacion_salidas_con_inscripciones_abiertas.sql` | Corrige `previsualizar_validacion_salidas_ronda(uuid)` para que un torneo con estatus distinto de `inscripcion_cerrada` o `en_curso` produzca un error bloqueante en vez de una advertencia. `REVISAR SALIDAS` sigue permitido como diagnóstico; `VALIDAR Y CERRAR SALIDAS` queda bloqueado hasta cerrar inscripciones. No modifica grupos, snapshots, tarjetas ni otras reglas del validador. |
| 181 Fase 1 | `181_FASE1_CICLO_VIDA_TORNEO_E_INICIALIZACION_CAPTURA.sql` | Formaliza RPCs para abrir, cerrar y reabrir inscripciones; la reapertura queda prohibida después del freeze. Agrega `iniciar_torneo(uuid)` para la transición manual `inscripcion_cerrada → en_curso`, exigiendo que la primera ronda tenga freeze, salidas validadas, tarjetas oficiales y captura digital inicializada. Además, `emitir_tarjetas_score_ronda(uuid)` inicializa la captura digital en la misma transacción, incluso para emisiones históricas ya existentes. `planificado` se conserva como enum y la UI debe mostrarlo como `EN PLANIFICACIÓN`. La finalización formal del torneo queda deliberadamente pendiente hasta definir el cierre oficial de la última ronda. |
| 181 Fase 2 | `181_FASE2_PROTEGER_ESTATUS_Y_CANCELAR_TORNEO.sql` | Protege `tournaments.estatus` contra UPDATE directos mediante `trg_proteger_cambio_estatus_torneo`; las RPCs abrir/cerrar/reabrir/iniciar reciben permiso interno transaccional para efectuar sus transiciones. Agrega `cancelar_torneo(uuid,text)` como transición manual controlada desde planificación, inscripciones abiertas/cerradas o en curso; exige motivo de al menos 10 caracteres y no permite cancelar un torneo finalizado. `finalizar_torneo()` continúa pendiente hasta formalizar el cierre oficial de la última ronda. |
| 181 Fase 3 | `181_FASE3_CIERRE_FORMAL_RONDA.sql` | Formaliza el cierre competitivo por ronda mediante `tournament_round_competitive_closures` y `cerrar_ronda_competitiva(uuid,text)`. Sólo permite cerrar cuando `obtener_estado_cierre_competitivo_ronda(uuid)` devuelve `competitiveStatus=FINAL`; funciona sin empates porque `pendingGroups=0` permite llegar directamente a FINAL, y con empates exige que todos estén resueltos. Persiste una fotografía JSON auditable e inmutable y bloquea cambios posteriores en tarjetas, captura digital/física, conciliación, outcomes y resoluciones manuales de desempate. `finalizar_torneo()` queda para Fase 4 y deberá exigir que todas las rondas activas tengan cierre formal. |
| 181 Fase 4 | `181_FASE4_FINALIZAR_TORNEO.sql` | Completa la máquina de estados deportiva con `finalizar_torneo(uuid,text)` y `previsualizar_finalizacion_torneo(uuid)`. La transición manual `en_curso → finalizado` sólo se permite cuando existe al menos una ronda activa y todas las rondas activas tienen cierre formal `FINAL` de la Fase 3. Crea `tournament_competitive_finalizations` como sello auditable, único e inmutable con snapshot de las rondas al momento de finalizar. La lógica es agnóstica a modalidad y formato de salida: no contiene reglas de Stroke, Stableford, equipos, Shotgun ni tee time; los motores específicos deben resolver cada ronda antes de llegar aquí. |
| 182 Fase 1 | `182_FASE1_CONTRATO_COMUN_MOTOR_SALIDAS.sql` | Inicia la refactorización del motor de salidas sin cambiar el flujo Shotgun existente. Crea `tournament_start_engine_registry`, registra el motor vigente `shotgun_v1 / stroke_individual_shotgun_v1`, agrega el contrato común versionado y generaliza futuros grupos validados con `source_format_slot_id` y `source_format_metadata`; `start_position` deja de ser obligatorio estructuralmente. **No hace backfill ni UPDATE sobre validaciones históricas**, porque su detalle es inmutable por `_impedir_mutacion_detalle_validacion_salida()`; la conversión Shotgun legacy → contrato común se hace en lectura. Agrega `obtener_motor_salida_ronda(uuid)` y `_construir_contrato_salida_ronda(uuid)`. Las RPC operativas de preview, validación y emisión quedan intactas en esta fase. |
| 182 Fase 2 | `182_FASE2_SHOTGUN_SOBRE_CONTRATO_COMUN_V2.sql` | Migra internamente el motor Shotgun existente al contrato común `tee_central_round_start` v2 sin cambiar sus reglas operativas. Crea `_construir_contrato_salida_shotgun_v2(uuid)` como fuente directa; `_construir_contrato_salida_ronda(uuid)` pasa a despachar por motor; la antigua `_construir_fotografia_salida_ronda(uuid)` queda como adaptador de compatibilidad derivado desde el contrato común. `validar_salidas_ronda(uuid)` persiste nuevas validaciones con `start_contract_version=2`, `source_format_slot_id` y `source_format_metadata`, conservando a la vez `source_shotgun_hole_id` para compatibilidad. La previsualización y la emisión mantienen exactamente las restricciones actuales de Stroke Play individual + Shotgun. No se modifican validaciones históricas inmutables. |
| 182 Fase 3 | `182_FASE3_CAPACIDADES_MOTOR_EMISION_TARJETAS_CORREGIDA.sql` | Desacopla la emisión oficial de tarjetas de los hardcodes del motor Shotgun mediante capacidades explícitas (`supports_scorecard_emission`, `scorecard_unit_type`, `scorecard_emission_engine`). Sólo Shotgun individual Stroke queda habilitado. `_resolver_capacidad_emision_tarjetas_ronda(uuid)` usa la validación formal sellada; `_contar_unidades_invalidas_emision_tarjetas(uuid,text)` conserva las exigencias actuales de unidad individual y prepara contractualmente unidades team sin habilitarlas. `emitir_tarjetas_score_ronda(uuid)` se reconstruye explícitamente, sin SQL dinámico, preservando idempotencia, conteos, creación de emisión, creación de tarjetas, folios Rxx-Vxx-xxxx e inicialización automática de captura. No se habilita Tee Times ni se mutan históricos. |
| 182 Fase 4 | `182_FASE4_DISPATCH_VALIDADORES_SALIDA.sql` | Desacopla la API pública de previsualización de las reglas específicas de Shotgun. Agrega `supports_start_validation` y `start_validation_handler` al registro de motores; renombra el validador operativo existente como `_previsualizar_validacion_salidas_shotgun_v1(uuid)` sin reescribir su lógica; crea `_resolver_validador_salida_ronda(uuid)` y convierte `previsualizar_validacion_salidas_ronda(uuid)` en dispatcher genérico. La RPC pública ya no consulta tablas Shotgun ni contiene reglas A/B o decisiones directas por Stroke individual. `validar_salidas_ronda(uuid)` conserva su firma y automáticamente consume el dispatcher junto con el contrato común v2. Tee Times permanece fail-closed hasta implementar y registrar su handler. |
| 183 Fase 1 | `183_FASE1_CONFIGURACION_TEE_TIMES.sql` | Inicia el motor Tee Times creando únicamente su configuración. Reutiliza `tournament_round_shifts.hora_salida` como primera hora del turno; crea `tournament_tee_time_shift_configs` para intervalo entre grupos, `tournament_tee_time_shift_start_holes` para uno o dos streams de salida sin hardcodear hoyos 1/10 y `tournament_tee_time_category_configs` para tamaño normal/máximo y orden de categorías. Registra `tee_times_v1 / stroke_individual_tee_times_v1` en el registro central, pero deja `supports_start_validation=false` y `supports_scorecard_emission=false` para mantener fail-closed. No prepara grupos, no valida definitivamente y no emite tarjetas todavía. Shotgun permanece intacto. |
| 183 Fase 2 | `183_FASE2_PREPARACION_GRUPOS_TEE_TIMES.sql` | Implementa la preparación/materialización Tee Times sobre las tablas comunes `tournament_groups` y `tournament_group_players`, manteniendo nulos los campos Shotgun. Crea `tournament_tee_time_groups` para metadata específica (categoría, stream de inicio y secuencia), `hora_salida_tee_time()` para derivar horarios desde turno + offset + intervalo, y las RPC `obtener_conformacion_tee_times` / `materializar_conformacion_tee_times`. La materialización opera por turno completo para evitar colisiones entre categorías, impide jugadores duplicados en la ronda y respeta tamaño máximo. `_construir_contrato_salida_tee_times_v1` produce el contrato común v2 con `startPosition=NULL`, y el dispatcher común ya reconoce Tee Times. Validación definitiva y emisión permanecen fail-closed. |
| 183 Fase 3 | `183_FASE3_VALIDADOR_TEE_TIMES.sql` | Implementa el handler `tee_times_v1` para revisión y validación definitiva de Tee Times individual Stroke. Valida freeze/snapshots, estatus operativo, configuración por turno, uno o dos streams, configuración de categorías con elegibles, orden único de categorías, metadata Tee Times en todos los grupos, ausencia de campos Shotgun, slots stream+secuencia únicos, hora derivada exacta, grupo no vacío, máximo, orden interno, categoría correcta, elegibilidad, participante exactamente una vez, ausencia de equipos, orden de bloques por `sequence_order`, distancias congeladas y warnings de retirados/grupos incompletos. Habilita `supports_start_validation=true` con handler `tee_times_v1` y extiende el dispatcher público. `validar_salidas_ronda` reutiliza el mismo pipeline común; emisión de tarjetas sigue fail-closed. |
| 183 Fase 4 | `183_FASE4_EMISION_TARJETAS_TEE_TIMES_CORREGIDA.sql` | Habilita emisión oficial de tarjetas para Tee Times individual Stroke reutilizando el emisor genérico `official_scorecard_registration_v1`. Registra `supports_scorecard_emission=true` y unidad `registration` para `tee_times_v1 / stroke_individual_tee_times_v1`. Ajusta únicamente el orden genérico de folios: Shotgun conserva `shift/hole/A-B`, mientras Tee Times usa `start_at` cuando `start_position` es NULL. Se reutilizan sin duplicar `tournament_score_card_emissions`, `tournament_score_cards`, `inicializar_captura_scores_ronda`, sesiones de captura, scores por hoyo y asignación circular de marcadores. La secuencia de juego parte del `hole_number` común del grupo validado. Con esta fase el backend Tee Times individual Stroke queda conectado de preparación a captura; modalidades team permanecen no habilitadas. |
| 184 Fase 1 | `184_FASE1_NRQ_AUTOCIERRE_CONCILIACION.sql` | Introduce el estado operativo NRQ (No requiere conciliación) para tarjetas físicas sin captura digital real. Agrega `reconciliation_requirement` (`REQUIRED`/`NOT_REQUIRED`) a `tournament_scorecard_reconciliations`, reclasifica históricos `COMPLETED` physical-only como `NOT_REQUIRED`, y al finalizar la captura física dispara un trigger que, si no hubo digital real, crea/completa la conciliación técnica como `COMPLETED` en la misma transacción y registra `reconciliation_not_required`. Un guard impide capturar digital después de NRQ. La nueva RPC `obtener_estados_conciliacion_ronda(uuid)` expone `NRQ`, `CONCILIADA` y `PENDIENTE_CONCILIAR` junto con categoría, permitiendo filtros de UI sin alterar las reglas de resultados oficiales. |
| 184 Fase 1A | `184_FASE1A_CORRECCION_PRIVILEGIOS_HELPERS_NRQ.sql` | Corrección de seguridad posterior a la verificación de 184 Fase 1. Revoca `EXECUTE` directo de `PUBLIC`, `anon` y `authenticated` sobre los helpers trigger internos `_autocompletar_conciliacion_nrq_al_finalizar_fisica()` y `_proteger_captura_digital_despues_nrq()`, manteniendo su uso interno mediante triggers y `service_role`. No modifica lógica NRQ, datos, resultados ni conciliación. |

### Migración 148 — Rondas de score del jugador autenticado

- Agrega `obtener_mis_rondas_score()`.
- No recibe parámetros: la identidad se resuelve con `auth.uid() → players.auth_user_id`.
- Devuelve rondas activas de torneos activos donde el jugador tiene tarjeta `issued` y/o es marcador activo.
- Devuelve torneo, número/fecha de ronda, `hasOwnCard`, `marksCards`, `cardsIMarkCount` y `captureInitialized`.
- Permite que `/score` funcione sin QR y sin `?round=<uuid>` externo.
- No expone QR, no cambia RLS y no modifica scores.


### Migración 149 — Recepción y captura física de tarjetas de score

- Crea `tournament_scorecard_physical_receptions`, una recepción física 1:1 por `tournament_score_cards.id`.
- La ausencia de fila de recepción equivale a tarjeta física todavía no recibida; no se almacena un estado artificial `NOT_RECEIVED`.
- Estados físicos almacenados:
  - `RECEIVED`
  - `IN_CAPTURE`
  - `CAPTURED`
  - `VOIDED`
- Registra por separado:
  - `player_signature_present`
  - `marker_signature_present`
  - fecha/hora de recepción
  - usuario autenticado que recibe
  - inicio y fin de captura física
  - notas
- Crea `tournament_scorecard_physical_hole_scores`, una fila por tarjeta + hoyo congelado.
- La captura física guarda únicamente el valor leído de la tarjeta en papel (`physical_gross_score`), junto con snapshot de hoyo, número, secuencia, actor y timestamps.
- `UNIQUE(score_card_id, round_hole_snapshot_id)` garantiza un solo valor físico vigente por hoyo.
- La captura física puede corregirse mientras la recepción esté `RECEIVED` o `IN_CAPTURE`.
- Una vez la recepción está `CAPTURED`, las RPC de esta fase bloquean edición directa.
- Crea `tournament_scorecard_physical_events`, bitácora append-only del proceso físico.
- Eventos incluidos en esta fase:
  - `physical_card_received`
  - `physical_capture_started`
  - `physical_score_entered`
  - `physical_score_corrected`
  - `physical_capture_completed`
  - `physical_card_voided`
- La bitácora física está protegida contra `UPDATE` y `DELETE`.
- RLS está habilitado en las tres tablas físicas.
- `anon` y `authenticated` no tienen acceso directo a las tablas; el flujo se hace exclusivamente por RPC.
- No se crean todavía roles específicos `scorer` ni `committee`; las RPC usan la autorización administrativa de torneo ya existente mediante `puede_administrar_congelamiento_torneo(tournament_id)`.
- RPC creadas:
  - `recibir_tarjeta_fisica_score(uuid, boolean, boolean, text)`
  - `guardar_score_fisico_hoyo(uuid, uuid, integer)`
  - `finalizar_captura_fisica_tarjeta(uuid)`
  - `obtener_captura_fisica_tarjeta(uuid)`
- Helper interno cerrado al cliente:
  - `_obtener_score_card_para_captura_fisica(uuid)`
- La tarjeta física siempre debe estar vinculada a una tarjeta oficial existente en `tournament_score_cards`.
- La captura digital en `tournament_scorecard_hole_scores` permanece totalmente separada y no se sobreescribe.
- Que un jugador o marcador no utilice la PWA en uno, varios o todos los hoyos es un caso válido y esperado.
- La terminología funcional para ese caso será **`SIN CAPTURA DIGITAL`**, no “falta digital” ni error.
- `finalizar_captura_fisica_tarjeta(uuid)` exige que el número de hoyos físicos capturados coincida con `holes_expected` de la sesión de captura; si no estuviera disponible, usa como respaldo el número de snapshots de hoyo de la ronda.
- La existencia de scores digitales NO es requisito para finalizar la captura física.
- Esta migración NO implementa todavía:
  - comparación DIGITAL vs FÍSICO
  - `COINCIDE`
  - `DIFERENCIA`
  - `SIN CAPTURA DIGITAL` como estado derivado de comparación
  - resolución de discrepancias
  - `official_gross_score`
  - NETO
  - leaderboard
  - cortes
  - cierre oficial de resultados
- La siguiente fase prevista es la lectura/comparación lado a lado para la UI del capturista, sin resolución de diferencias todavía.

### Migración 150 — Listado operativo de captura física por ronda

- Agrega `obtener_tarjetas_captura_fisica_ronda(uuid)`.
- Objetivo: eliminar las llamadas N+1 de la pantalla administrativa `CAPTURA TARJETAS FÍSICAS`.
- La RPC recibe únicamente `tournament_round_id`.
- Requiere sesión autenticada y valida permiso administrativo del torneo mediante `puede_administrar_congelamiento_torneo(tournament_id)`.
- Devuelve en una sola respuesta todas las tarjetas oficiales `issued` de la ronda.
- Por tarjeta devuelve:
  - `scoreCardId`
  - `cardNumber`
  - `cardFolio`
  - jugador/unidad (`playerId`, `displayName`)
  - categoría (`tournamentCategoryId`, `name`)
  - marcador vigente (`playerId`, `displayName`)
  - recepción física
  - estado físico
  - presencia de ambas firmas
  - timestamps de recepción/inicio/finalización
  - `holesExpected`
  - `physicalHolesCaptured`
- `NOT_RECEIVED` sigue siendo un estado DERIVADO: se devuelve cuando no existe fila en `tournament_scorecard_physical_receptions`; no se almacena en base de datos.
- La RPC NO devuelve `gross_score` digital ni `physical_gross_score` por hoyo.
- Por tanto, la optimización del listado no rompe el principio de **captura física ciega**.
- La RPC es `STABLE`, `SECURITY DEFINER`, con `search_path=public, pg_temp`.
- `authenticated` puede ejecutarla; `anon` y `public` no.
- No modifica ninguna tabla.
- No utiliza QR.
- No implementa conciliación, resoluciones ni `official_gross_score`.
- El frontend deberá sustituir:
  - el listado previo de `useRoundScoreCards`
  - la lectura auxiliar de marcador para el listado
  - las N llamadas a `obtener_captura_fisica_tarjeta`
  por esta única RPC para cargar la pantalla inicial.
- Al abrir una tarjeta individual, las RPC detalladas de la Migración 149 siguen siendo las fuentes correctas.

### Migración 151 — Lectura consolidada para conciliación

- Agrega `obtener_conciliacion_tarjeta_score(uuid)`.
- La RPC sólo puede utilizarse con una tarjeta física cuya recepción esté `CAPTURED`; antes de eso rechaza la comparación para preservar la captura física ciega.
- Consolida tres evidencias por hoyo:
  - GROSS digital vigente del marcador.
  - Inconformidad del jugador.
  - GROSS físico transcrito.
- La inconformidad se obtiene de dos fuentes:
  - estado actual de `tournament_scorecard_hole_scores` para una disputa activa;
  - último evento `player_disputed` en `tournament_scorecard_events` para preservar historia aun cuando el marcador haya corregido y la fila actual haya limpiado `player_claimed_gross_score`.
- También lee el último `player_confirmed` para distinguir si una inconformidad histórica terminó reconfirmada por el jugador.
- `comparisonStatus`:
  - `COINCIDE`
  - `DIFERENCIA`
  - `SIN_CAPTURA_DIGITAL`
  - `PENDIENTE_CAPTURA_FISICA`
- `disputeStatus`:
  - `NONE`
  - `ACTIVE`
  - `HISTORICAL_PENDING`
  - `HISTORICAL_RESOLVED`
- `HISTORICAL_PENDING` significa que existió una inconformidad y no existe una confirmación posterior a esa inconformidad.
- `HISTORICAL_RESOLVED` significa que el jugador posteriormente confirmó después de la última inconformidad registrada.
- `needsReview=true` cuando:
  - DIGITAL difiere de FÍSICO;
  - existe inconformidad `ACTIVE`;
  - existe inconformidad `HISTORICAL_PENDING`;
  - falta captura física (caso defensivo).
- `SIN_CAPTURA_DIGITAL` por sí solo NO marca `needsReview`; es un caso válido y esperado.
- Una inconformidad histórica ya reconfirmada puede seguir mostrándose como antecedente, pero no obliga revisión si DIGITAL y FÍSICO coinciden.
- La RPC devuelve resumen por tarjeta con:
  - coincidencias
  - diferencias
  - hoyos sin captura digital
  - pendientes físicos
  - inconformidades activas
  - inconformidades históricas pendientes
  - inconformidades históricas resueltas
  - total de hoyos que requieren revisión
- Esta migración NO:
  - modifica captura digital;
  - modifica captura física;
  - crea tabla de resoluciones;
  - crea `official_gross_score`;
  - resuelve automáticamente diferencias;
  - implementa NETO/leaderboard/cortes.
- La siguiente fase debe ser la UI de revisión/conciliación informativa usando esta RPC; la resolución oficial debe diseñarse en una migración posterior.

### Migración 152 — Resolución auditable de conciliación

- Crea `tournament_scorecard_reconciliations` (1:1 por tarjeta).
- Estados: `PENDING`, `IN_REVIEW`, `COMPLETED`, `VOIDED`.
- Crea `tournament_scorecard_hole_resolutions`.
- Guarda únicamente EXCEPCIONES; los hoyos normales no generan fila de resolución.
- Snapshots de evidencia al resolver: digital, reclamo del jugador y físico.
- Fuentes: `DIGITAL`, `PHYSICAL`, `PLAYER_CLAIM`, `MANUAL`.
- `MANUAL` exige motivo.
- Guarda `resolved_gross_score`, fuente, motivo, administrador y timestamps.
- Las resoluciones pueden modificarse mientras la conciliación esté `IN_REVIEW`, quedando cada cambio auditado.
- Crea `tournament_scorecard_reconciliation_events`, append-only.
- RPC:
  - `iniciar_conciliacion_tarjeta_score(uuid)`
  - `resolver_hoyo_conciliacion_score(uuid, uuid, text, integer, text)`
  - `obtener_resoluciones_conciliacion_tarjeta_score(uuid)`
  - `finalizar_conciliacion_tarjeta_score(uuid, text)`
- `resolver_hoyo_conciliacion_score` recalcula server-side si el hoyo realmente requiere revisión.
- `SIN_CAPTURA_DIGITAL` por sí solo no genera resolución.
- `finalizar_conciliacion_tarjeta_score` recalcula server-side todos los casos pendientes y no permite finalizar si queda alguno sin resolver.
- No se crean todavía roles separados `scorer`/`committee`; queda auditado quién inicia, resuelve y finaliza.
- RLS activo y sin acceso directo a tablas desde `anon`/`authenticated`; consumo sólo por RPC.
- No modifica DIGITAL, FÍSICO ni historial de inconformidades.
- No crea todavía `official_gross_score`, NETO, leaderboard, cortes ni desempates.

### Migración 153 — Score oficial consolidado por tarjeta

- Agrega `obtener_score_oficial_tarjeta(uuid)`.
- Sólo funciona cuando:
  - la tarjeta física está `CAPTURED`;
  - la conciliación está `COMPLETED`;
  - están presentes todos los hoyos físicos esperados;
  - no queda ningún caso `needsReview` sin resolución.
- Regla oficial por hoyo:
  - si existe resolución explícita → `resolved_gross_score`;
  - si no existe resolución → `physical_gross_score`.
- El valor físico se usa como soporte inmutable para hoyos normales:
  - si DIGITAL = FÍSICO → `officialSource = MATCHED`;
  - si DIGITAL es NULL y existe FÍSICO → `officialSource = PHYSICAL_ONLY`.
- Para excepciones conciliadas, `officialSource` conserva la fuente registrada:
  - `DIGITAL`
  - `PHYSICAL`
  - `PLAYER_CLAIM`
  - `MANUAL`
- La RPC devuelve por hoyo:
  - evidencia digital;
  - evidencia física;
  - resolución si existe;
  - `officialGrossScore`;
  - `officialSource`.
- Devuelve también:
  - `totalOfficialGross`;
  - hoyos oficiales;
  - conteo por fuente de origen.
- Razón para usar FÍSICO como base de hoyos no conflictivos: la captura física `CAPTURED` ya está bloqueada y es inmutable; así una eventual modificación digital posterior no altera retroactivamente el score oficial.
- La RPC vuelve a validar server-side que no existan casos pendientes, aun cuando la conciliación figure `COMPLETED`.
- Esta migración es exclusivamente de lectura.
- No modifica:
  - `tournament_scorecard_hole_scores.gross_score`;
  - `tournament_scorecard_physical_hole_scores.physical_gross_score`;
  - resoluciones existentes.
- No crea todavía una columna `official_gross_score`; el dato oficial se deriva de forma determinística.
- No calcula todavía:
  - NETO;
  - leaderboard;
  - cortes;
  - desempates;
  - publicación de resultados.
- La siguiente fase debe validar esta lectura con una tarjeta conciliada real y después definir la fuente masiva por ronda para resultados, evitando N+1.

### Migración 154 — Motor NETO oficial por tarjeta

- Se reutiliza el número 154 porque la propuesta anterior GROSS/NET/BOTH no fue ejecutada.
- Calcula siempre GROSS y NETO para toda tarjeta oficial.
- Función pura: `calcular_golpes_handicap_hoyo(integer, integer, integer)`.
- RPC: `obtener_resultado_neto_oficial_tarjeta(uuid)`.
- El GROSS oficial proviene exclusivamente de `obtener_score_oficial_tarjeta(uuid)` de la Migración 153.
- El hándicap proviene exclusivamente de `tournament_round_handicap_snapshots.playing_handicap`, enlazado mediante `tournament_round_start_validation_units.round_handicap_snapshot_id`.
- No consulta ni recalcula el hándicap vivo del jugador.
- Fórmula por hoyo: `officialNetScore = officialGrossScore - handicapStrokes`.
- Playing Handicap positivo: asigna golpes empezando por SI 1 y soporta vueltas adicionales cuando PH > número de hoyos.
- Plus handicap: devuelve golpes negativos y los cede empezando por el SI más alto.
- Valida que el Stroke Index congelado forme una secuencia completa 1..N.
- Valida que la suma de golpes distribuidos sea exactamente igual al Playing Handicap.
- Devuelve por hoyo: hoyo, secuencia, par, SI, GROSS oficial, fuente GROSS, golpes de hándicap y NETO oficial.
- Devuelve snapshot de hándicap y totales GROSS/NETO.
- No depende de nombre/categoría para calcular.
- No materializa NETO en tablas.
- No implementa todavía leaderboard, premiación, cortes ni desempates.
- La elección GROSS/NETO para premiación por categoría se definirá después; no es requisito del motor.
- Siguiente paso: verificar esta migración con Supabase y probar la tarjeta conciliada real antes de construir la fuente masiva por ronda.

### Migración 155 — Fuente masiva de resultados oficiales por ronda

- Agrega:
  - `obtener_resultados_oficiales_ronda(uuid)`
- Objetivo:
  - obtener TODAS las tarjetas emitidas de una ronda en una sola RPC;
  - evitar N+1 desde frontend;
  - separar resultados oficiales de tarjetas todavía pendientes.
- Implementación set-based:
  - no invoca `obtener_score_oficial_tarjeta()` una vez por jugador;
  - no invoca `obtener_resultado_neto_oficial_tarjeta()` una vez por jugador.
- Para cada tarjeta devuelve:
  - `scoreCardId`
  - folio/número
  - jugador
  - categoría
  - tee
  - Handicap Index congelado
  - Course Rating
  - Slope Rating
  - allowance
  - Course Handicap
  - Playing Handicap
  - estado físico
  - estado de conciliación
  - `resultStatus`
  - `ready`
  - `issues`
- Estados principales:
  - `PHYSICAL_NOT_RECEIVED`
  - `PHYSICAL_RECEIVED`
  - `PHYSICAL_IN_CAPTURE`
  - `PHYSICAL_VOIDED`
  - `RECONCILIATION_NOT_STARTED`
  - `RECONCILIATION_PENDING`
  - `RECONCILIATION_IN_REVIEW`
  - `RECONCILIATION_VOIDED`
  - `HANDICAP_SNAPSHOT_MISSING`
  - `STROKE_INDEX_INVALID`
  - `OFFICIAL_DATA_INCOMPLETE`
  - `HANDICAP_DISTRIBUTION_INVALID`
  - `OFFICIAL_READY`
- Una tarjeta sólo es `OFFICIAL_READY` cuando:
  - físico = `CAPTURED`;
  - conciliación = `COMPLETED`;
  - existe snapshot de hándicap de ronda;
  - existen todos los hoyos esperados;
  - existen todos los scores físicos;
  - todos los hoyos producen GROSS oficial;
  - no quedan casos `needsReview` sin resolución;
  - Stroke Index forma secuencia completa 1..N;
  - la suma de golpes distribuidos coincide con Playing Handicap.
- Para tarjetas listas devuelve:
  - `officialGrossTotal`
  - `handicapStrokesTotal`
  - `officialNetTotal`
  - arreglo `holes` con GROSS oficial, fuente, SI, golpes y NETO.
- Para tarjetas no listas:
  - los totales oficiales se devuelven `NULL`;
  - `holes` se devuelve vacío;
  - el estado y `issues` explican por qué aún no es oficial.
- El GROSS oficial mantiene la regla 153:
  - resolución prevalece;
  - si no hay resolución, usa físico;
  - `MATCHED` y `PHYSICAL_ONLY` conservan trazabilidad.
- El NETO usa exclusivamente:
  - `playing_handicap` congelado;
  - `calcular_golpes_handicap_hoyo()` de 154.
- Calcula siempre GROSS y NETO; no consulta regla de premiación por categoría.
- La respuesta incluye resumen de ronda:
  - total de tarjetas;
  - listas;
  - pendientes;
  - no recibidas físicamente;
  - captura física pendiente;
  - conciliación pendiente;
  - oficiales listas.
- La Migración 155:
  - no materializa resultados;
  - no asigna posición;
  - no ordena por GROSS/NETO como leaderboard;
  - no decide premiación;
  - no implementa cortes ni desempates.
- El detalle por hoyo queda disponible para auditoría y para el futuro motor de desempates sin volver a consultar una tarjeta por vez.
- Siguiente paso recomendado:
  - verificar 155;
  - probar la RPC contra la ronda real de 8 tarjetas;
  - comprobar que actualmente sólo la tarjeta conciliada aparezca `OFFICIAL_READY` y las demás con su estado real;
  - después diseñar leaderboard sobre esta única fuente.

### Migración 156 — Estados competitivos terminales de ronda

- El diagnóstico previo confirmó que no existía un modelo formal para WD/DNF/DQ/DNS/NO_CARD.
- Se mantiene separado:
  - estado administrativo de `tournament_score_cards` (`issued/voided`);
  - pipeline físico/conciliación;
  - outcome competitivo del jugador.
- `OFFICIAL` no se almacena:
  - sigue siendo un resultado derivado por `obtener_resultados_oficiales_ronda()` de la 155;
  - una tarjeta `OFFICIAL_READY` representa el resultado normal completo.
- Excepciones terminales de ronda:
  - `WD` — Withdrawn / retirado;
  - `DNF` — Did Not Finish / inició pero no terminó;
  - `DQ` — Disqualified;
  - `DNS` — Did Not Start;
  - `NO_CARD` — no existe tarjeta válida entregada para resultado.
- Tabla:
  - `tournament_scorecard_round_outcomes`
- Bitácora append-only:
  - `tournament_scorecard_round_outcome_events`
- RPC:
  - `establecer_outcome_competitivo_tarjeta(uuid,text,text)`
  - `limpiar_outcome_competitivo_tarjeta(uuid,text)`
  - `obtener_outcomes_competitivos_ronda(uuid)`
- DNF:
  - no se convierte artificialmente en score oficial completo;
  - conserva scores digitales parciales ya capturados;
  - la consulta expone `holesWithDigitalScore`, `digitalGrossPartial` y hoyos parciales;
  - esto permite que una fase futura decida cómo usar esos parciales en competencias por equipo.
- Cierre de resultados:
  - RPC `validar_cierre_resultados_ronda(uuid)`;
  - una tarjeta cuenta como resuelta si:
    - está `OFFICIAL_READY`; o
    - tiene `WD`, `DNF`, `DQ`, `DNS` o `NO_CARD`;
  - devuelve `readyToCloseResults`, resumen y tarjetas todavía sin resolver.
- MC — Missed Cut:
  - NO es outcome de una tarjeta de ronda;
  - se modela aparte en `tournament_cut_player_statuses`;
  - valores: `MC`, `QUALIFIED`;
  - identifica la ronda después de la cual se aplicó el corte;
  - RPC de registro: `establecer_estado_corte_jugador(uuid,uuid,text,text)`.
- La 156 NO calcula automáticamente quién pasa el corte:
  - no aplica posiciones;
  - no aplica top N;
  - no aplica empates en línea de corte;
  - sólo deja el modelo correcto preparado.
- La 156 no:
  - modifica DIGITAL;
  - modifica FÍSICO;
  - modifica conciliación;
  - modifica GROSS/NETO oficial;
  - implementa leaderboard;
  - implementa premiación;
  - implementa desempates.
- Próximo paso recomendado:
  - verificar la migración;
  - probar uno o dos outcomes en el torneo de prueba (por ejemplo DNF/DNS);
  - verificar `validar_cierre_resultados_ronda`;
  - después construir leaderboard provisional/definitivo sobre resultados resueltos.

### Migración 157 — Fix de cierre de resultados con outcome NULL

- La prueba real posterior a la Migración 156 detectó un error de lógica SQL de tres valores.
- Cuando una tarjeta no estaba `OFFICIAL_READY` y tampoco tenía fila en `tournament_scorecard_round_outcomes`, la expresión `false OR NULL` producía `NULL`.
- El conteo original `FILTER (WHERE NOT resolved_for_round)` no contabilizaba esos `NULL`.
- Consecuencia observada:
  - tarjetas pendientes visibles;
  - `resolvedForRound = NULL`;
  - `unresolvedCards = 0`;
  - `readyToCloseResults = true` incorrectamente.
- La 157 corrige `validar_cierre_resultados_ronda(uuid)`:
  - `outcome_code NULL` equivale explícitamente a `false`;
  - pendientes se cuentan con `resolved_for_round IS NOT TRUE`;
  - la ronda sólo puede cerrar si `totalCards > 0` y `unresolvedCards = 0`.
- No crea tablas.
- No modifica datos.
- No cambia WD/DNF/DQ/DNS/NO_CARD.
- No cambia MC/QUALIFIED.
- No cambia GROSS/NETO.
- El diagnóstico real también aclaró el estado actual de la ronda:
  - 3 tarjetas tienen físico `CAPTURED`;
  - sólo 1 de esas 3 tiene conciliación `COMPLETED`;
  - las otras 2 tienen conciliación `NOT_STARTED`;
  - 5 tarjetas están `NOT_RECEIVED`.
- Por tanto, antes de outcomes excepcionales, el estado real esperado es:
  - 1 tarjeta resuelta;
  - 7 tarjetas sin resolver;
  - `readyToCloseResults = false`.

### Migración 158 — Leaderboard de ronda GROSS + NETO

- Agrega:
  - `obtener_leaderboard_ronda(uuid)`
- Consume exclusivamente:
  - `obtener_resultados_oficiales_ronda(uuid)` de la 155;
  - `validar_cierre_resultados_ronda(uuid)` corregida por la 157;
  - outcomes terminales de la 156.
- El leaderboard calcula y expone SIEMPRE dos clasificaciones:
  - GROSS;
  - NETO.
- Todavía NO decide cuál de ellas se utilizará para premiación por categoría.
- Elegibilidad:
  - sólo tarjetas `OFFICIAL_READY` reciben posición numérica;
  - WD, DNF, DQ, DNS y NO_CARD permanecen visibles con su estado competitivo y sin rank;
  - tarjetas todavía no resueltas también permanecen visibles como pendientes.
- Agrupa por categoría del torneo.
- Para cada jugador oficial expone:
  - GROSS total;
  - posición GROSS provisional;
  - NETO total;
  - posición NETO provisional;
  - tieSize;
  - tiebreakPending.
- Usa `RANK()` para posiciones provisionales:
  - jugadores empatados reciben la misma posición;
  - la siguiente posición conserva el salto estándar de ranking.
- Los empates se detectan por:
  - misma categoría;
  - mismo total GROSS o mismo total NETO.
- La 158 NO rompe empates.
- Estado global del leaderboard:
  - `PROVISIONAL`:
    - la ronda todavía tiene tarjetas sin resolver;
  - `READY_FOR_TIEBREAK`:
    - todas las tarjetas están resueltas;
    - existe al menos un empate GROSS o NETO;
  - `READY_FOR_PUBLICATION`:
    - todas las tarjetas están resueltas;
    - no existen empates.
- `roundResolved` proviene de la regla formal de cierre 156/157:
  - OFFICIAL_READY o outcome terminal.
- La respuesta incluye:
  - resumen global;
  - resumen por categoría;
  - jugadores de cada categoría;
  - estado competitivo;
  - GROSS/NETO/ranks;
  - flags de empate.
- No implementa todavía:
  - desempate por reglas configuradas;
  - elección GROSS/NETO para premiación;
  - tabla de ganadores;
  - cortes;
  - MC;
  - resultados acumulados multirronda.
- Próximo paso:
  - verificar la 158;
  - probarla contra la ronda actual, donde debe aparecer como `PROVISIONAL`;
  - después diseñar el motor de desempates usando las reglas ya existentes en `tournament_tiebreak_rules`.

### Migración 159 — Fix de tipo `bigint` en fuente masiva de resultados

- Error detectado en prueba física de la UI:
  - código PostgreSQL `42883`;
  - `function public.calcular_golpes_handicap_hoyo(integer, integer, bigint) does not exist`.
- Causa:
  - `shape.hole_rows` proviene de `count(*)`, cuyo tipo PostgreSQL es `bigint`;
  - `expected_holes = COALESCE(c.holes_expected, s.hole_rows)` queda promovido a `bigint`;
  - `calcular_golpes_handicap_hoyo` está correctamente definida con tercer parámetro `integer`.
- Corrección:
  - en `obtener_resultados_oficiales_ronda(uuid)`, la llamada usa `r.expected_holes::integer`.
- No se crea una sobrecarga bigint del motor:
  - se mantiene una sola firma canónica `(integer, integer, integer)`.
- La 159 no modifica:
  - tablas;
  - datos;
  - captura digital;
  - captura física;
  - conciliación;
  - GROSS oficial;
  - fórmula NETO;
  - outcomes;
  - leaderboard.
- `obtener_leaderboard_ronda(uuid)` de la 158 no requiere cambios:
  - consume automáticamente la fuente 155/159 ya corregida.
- Después de ejecutar 159:
  - volver a abrir `/rondas/<roundId>/resultados`;
  - la RPC ya debe cargar el leaderboard real.

### Migración 160 — Motor de desempates de ronda

- No crea un nuevo sistema de configuración:
  - reutiliza `tournament_tiebreak_rules`;
  - reutiliza `tiebreak_methods`;
  - respeta `tipo_resultado_desempate`;
  - respeta `alcance_desempate`.
- Agrega helper puro:
  - `calcular_clave_metodo_desempate(text,tipo_resultado_desempate,jsonb)`
- Agrega helper puro:
  - `evaluar_secuencia_desempate_tarjeta(jsonb,tipo_resultado_desempate,jsonb)`
- Agrega RPC:
  - `obtener_desempates_ronda(uuid)`
- Configuración efectiva por grupo empatado:
  1. categoría + alcance exacto;
  2. categoría + alcance `todos`;
  3. default torneo + alcance exacto;
  4. default torneo + alcance `todos`.
- Se selecciona una sola fuente:
  - no se mezclan pasos específicos y default.
- El motor evalúa por separado:
  - GROSS;
  - NETO.
- Alcance:
  - empate en rank 1 -> `primer_lugar`;
  - empate en cualquier otra posición -> `otros_lugares`.
- Métodos automáticos:
  - `TARJETA_ULTIMOS_9`;
  - `TARJETA_ULTIMOS_6`;
  - `TARJETA_ULTIMOS_3`;
  - `TARJETA_ULTIMO_HOYO`;
  - `TARJETA_18`;
  - `HOYO_POR_HOYO_HANDICAP`.
- Countback:
  - usa scores oficiales por hoyo;
  - GROSS usa `officialGrossScore`;
  - NETO usa `officialNetScore`.
- `HOYO_POR_HOYO_HANDICAP`:
  - compara lexicográficamente desde Stroke Index 1, después 2, 3, etc.;
  - no usa el número físico de hoyo como prioridad.
- Métodos no automáticos:
  - `MUERTE_SUBITA`;
  - `SORTEO`;
  - códigos no soportados.
- Si el empate llega a uno de ellos:
  - `MANUAL_PENDING`;
  - no inventa ganador.
- Si se agotan los pasos automáticos y persiste el empate:
  - `TIE_PERSISTS_AFTER_RULES`.
- Si no existe configuración efectiva para un grupo:
  - `CONFIG_MISSING`.
- Si se resuelve automáticamente:
  - `RESOLVED_AUTOMATIC`;
  - devuelve `resolvedAtStep`;
  - devuelve `resolvedByMethodCode`;
  - devuelve `resolvedByMethodName`;
  - devuelve `tiebreakOrder`;
  - devuelve `finalRank`.
- Evidencia:
  - cada jugador conserva por paso:
    - método;
    - clave del paso;
    - clave acumulada.
- Estado del motor:
  - `NO_TIES`;
  - `PROVISIONAL_RESOLVED`;
  - `RESOLVED`;
  - `PROVISIONAL_CONFIGURATION_REQUIRED`;
  - `CONFIGURATION_REQUIRED`;
  - `PROVISIONAL_ACTION_REQUIRED`;
  - `ACTION_REQUIRED`.
- La ronda puede estar incompleta:
  - el motor puede evaluar empates actuales;
  - el resultado se considera provisional mientras `roundResolved=false`.
- La 160 no:
  - modifica reglas;
  - materializa desempates;
  - modifica posiciones del leaderboard 158;
  - decide premiación GROSS/NETO por categoría;
  - calcula cortes;
  - aplica MC;
  - publica resultados.
- Próximo paso:
  - verificar la 160;
  - crear una prueba controlada de empate con rollback o utilizar un empate real;
  - después integrar el resultado del motor al leaderboard/UI.

### Migración 161 — Persistencia de resolución manual de desempates

- Agrega:
  - `tournament_tiebreak_resolutions`
  - `tournament_tiebreak_resolution_players`
  - `tournament_tiebreak_resolution_events`
- Todas las tablas tienen RLS habilitado y no exponen escritura directa a `authenticated`.
- RPC de lectura:
  - `obtener_resoluciones_desempate_ronda(uuid)`
- RPC de resolución:
  - `resolver_desempate_manual_ronda(uuid,uuid,tipo_resultado_desempate,integer,integer,uuid[],text)`
- RPC de anulación:
  - `anular_resolucion_desempate_manual(uuid,text)`
- La resolución se valida contra el grupo vigente que devuelve el motor 160.
- Identidad del grupo:
  - ronda;
  - categoría;
  - tipo de resultado GROSS/NETO;
  - posición base;
  - total empatado.
- `p_score_card_order` debe:
  - incluir exactamente todos los integrantes del grupo;
  - no repetir tarjetas;
  - representar el orden final.
- `final_rank`:
  - se deriva de `base_rank + order_in_tiebreak - 1`.
- `MANUAL_PENDING`:
  - usa obligatoriamente el `manualMethodCode/manualMethodName` devuelto por el motor;
  - no permite cambiarlo desde cliente.
- `TIE_PERSISTS_AFTER_RULES`:
  - se registra como `COMMITTEE_OVERRIDE`;
  - exige motivo de al menos 10 caracteres;
  - queda explícito que no fue un método configurado automático.
- `CONFIG_MISSING`:
  - no puede resolverse con esta RPC;
  - primero debe corregirse la configuración del torneo/categoría.
- Correcciones:
  - una resolución activa no se sobreescribe;
  - debe anularse con motivo;
  - después puede registrarse una nueva;
  - la bitácora conserva ambos eventos.
- No modifica:
  - captura digital;
  - captura física;
  - conciliación;
  - GROSS;
  - NETO;
  - outcomes;
  - motor 160;
  - leaderboard 158;
  - premiación;
  - cortes;
  - publicación.
- Próximo paso:
  - verificar Migración 161;
  - probar resolución/anulación con un empate manual controlado;
  - después integrar las resoluciones persistidas al leaderboard y UI.

### Migración 162 — Estado de cierre competitivo de ronda

- Agrega `public.obtener_estado_cierre_competitivo_ronda(uuid)`.
- Integra cierre de tarjetas/outcomes, motor automático 160 y resoluciones manuales activas 161.
- Formaliza `PROVISIONAL`, `TIEBREAKS_PENDING` y `FINAL`.
- `FINAL` exige tarjetas/resultados completos y cero desempates pendientes.
- Distingue `CONFIG_MISSING`, `MANUAL_PENDING` y `TIE_PERSISTS_AFTER_RULES`.
- Es de solo lectura: no materializa cierre ni modifica leaderboard, publicación, cortes o premiación.
- Verificación ejecutada: 12 verificaciones, 0 errores.

### Migración 163 — Base de provisionamiento de torneos

- Mantiene `public.tournaments` como entidad única del torneo.
- Agrega `public.estado_servicio_torneo`: `provisionado`, `activo`, `pausado`, `archivado`, `cancelado`.
- Agrega `tournaments.estado_servicio`, independiente de `tournaments.estatus` deportivo.
- Los torneos existentes quedan con `estado_servicio = activo`.
- Permite NULL durante provisionamiento en `club_id`, `cupo_maximo` y `tournament_format_id`.
- Mantiene obligatorios `nombre`, `fecha_inicio` y `fecha_fin`.
- Restringe el INSERT de nuevos torneos a Superadmin.
- Conserva la edición posterior del torneo asignado conforme a las policies existentes.
- Protege cambios de `estado_servicio` para que el Organizador no pueda cambiar por sí mismo el estado comercial del servicio.
- No crea todavía contrato, contratante, documentación fiscal, invitaciones de organizador, RPC transaccional, pausa/archivo automático ni UI.
- Diseño acordado: organizador existente se asignará mediante `admin_role_assignments`; organizador no registrado tendrá invitación pendiente y no un usuario falso.
- El contratante puede ser distinto del organizador y sus datos comerciales/fiscales vivirán fuera de `tournaments`.
- Los torneos ya jugados no se borrarán; se conservarán como histórico y posteriormente se definirá el archivado/periodo de gracia.

### Migración 164 — Perfil comercial/contratante

- Crea `tournament_commercial_profiles` (1:1 por torneo).
- Separa contratante y datos fiscales del organizador y de la configuración deportiva.
- Guarda monto de plataforma, moneda, pagado/no pagado, fecha/referencia/notas de pago y ruta de Constancia Fiscal.
- Crea bucket privado `tournament-contract-fiscal-documents`.
- Datos comerciales y documentos: sólo Superadmin.
- Pendiente: invitaciones de organizador no registrado y RPC transaccional de provisionamiento.

### Migración 165 — Invitación de organizador

- Si el organizador ya existe, se conserva `admin_role_assignments`.
- Si aún no existe, se guarda una invitación pendiente con nombre, email y teléfono.
- No crea `admin_user` provisional ni almacena contraseñas.
- La invitación no concede permisos hasta su aceptación y asignación real.
- Los torneos y organizadores actuales no se modifican.
- Pendiente: aceptación/registro y RPC transaccional de provisionamiento.

### Migración 166 — RPC de provisionamiento

- `provisionar_torneo(...)` es exclusiva de Superadmin y atómica.
- Crea torneo mínimo `provisionado`, `activo=false`, perfil comercial y organizador.
- Organizador existente: `admin_role_assignments`; no existente: invitación `pending`.
- No crea cuentas ni contraseñas.
- Pendiente: aceptación/registro del invitado, UI Superadmin y activación del torneo.

### Migración 167 — Aceptación de invitación

- Usuario autenticado y con email verificado acepta sólo la invitación pendiente de su propio correo.
- Crea/vincula `admin_users`, asigna `tournament_organizer` y marca la invitación `accepted`.
- No crea cuentas Auth ni contraseñas; eso permanece en Supabase Auth.
- Pendiente UI: envío manual de invitación, verificación/alta inicial y “Olvidé mi contraseña”.

### Migración 168 — Trazabilidad de invitación

- Agrega `last_sent_at`, `sent_count` y `last_sent_by` a las invitaciones de organizador.
- Permite saber si se envió, cuándo fue el último envío y cuántas veces se reenvió.
- No envía correo; el envío será manual desde Superadmin mediante Resend.

### Migración 169 — Invitaciones administrativas genéricas

- Generaliza la tabla existente; no crea un sistema paralelo.
- Unifica invitación/asignación/aceptación para `club_admin` y `tournament_organizer`.
- `provisionar_torneo` usa el motor genérico y la RPC 167 queda como wrapper compatible.
- Pendiente UI: correo genérico, `/activar-acceso`, reemplazar altas con contraseña temporal y retirar código legado tras pruebas.

### Migración 170 — Datos estructurados de invitación administrativa

- Agrega `nombres` y `apellidos` a `admin_user_invitations`.
- Las nuevas invitaciones podrán guardar esos datos desde Superadmin y la activación ya no tendrá que volver a pedirlos.
- Agrega `aceptar_invitacion_admin(uuid)` como firma canónica.
- Conserva temporalmente las firmas anteriores para no romper el frontend durante la transición.
- `provisionar_torneo` se conserva en esta migración y se adaptará junto con el frontend para evitar una ruptura entre UI y backend.

### Migración 171 — Provisionamiento con organizador estructurado

- Agrega una firma de `provisionar_torneo` con nombres y apellidos separados.
- El provisionamiento usa la firma canónica de `asignar_o_invitar_admin` creada en la 170.
- Mantiene creación transaccional de torneo, perfil comercial y asignación/invitación.
- La firma anterior permanece temporalmente hasta que el frontend migre por completo.

### Migración 172 — Fase 1: conciliación desde snapshots

- La conciliación parte de `tournament_round_hole_snapshots`.
- La captura digital deja de ser requisito estructural.
- La tarjeta física continúa siendo obligatoria.
- `SIN_CAPTURA_DIGITAL` es informativo; no bloquea revisión por sí solo.
- No modifica todavía resolución, finalización, resultados oficiales ni leaderboard.

### Migración 173 — Fase 2: finalización y resolución

- Finalización y resolución parten de los snapshots de la ronda.
- La tarjeta física debe estar completa para finalizar.
- La ausencia de digital no requiere resolución.
- Las diferencias y disputas pendientes sí requieren resolución.
- Resultados oficiales y leaderboard se mantienen sin cambios en esta fase.

### Migración 174 — Fase 3: resultados oficiales

- Los hoyos esperados salen de los snapshots de la ronda.
- La tarjeta física completa sigue siendo obligatoria.
- La captura digital es opcional y `PHYSICAL_ONLY` es fuente válida.
- El leaderboard no se modifica; consume el resultado oficial corregido.

### Migración 175 — Categorías elegibles en inscripción

- Centraliza la elegibilidad de categorías para inscripción individual.
- El jugador puede elegir su categoría natural por hándicap o cualquier categoría superior, entendida como una categoría con menor rango de hándicap.
- No puede elegir una categoría inferior ni una categoría de género incompatible.
- Las categorías Senior se validan por edad y permanecen como alternativa adicional a la categoría regular por hándicap.
- Las categorías abiertas (`genero IS NULL`) continúan disponibles para ambos sexos cuando corresponda.
- Los rangos efectivos respetan primero los overrides de `tournament_categories` y, si no existen, los valores del catálogo `categories`.
- Agrega la función interna `public._categorias_elegibles_jugador(uuid,uuid)`.
- Agrega la RPC `public.obtener_mis_categorias_elegibles_inscripcion(uuid)` para que el frontend muestre únicamente opciones válidas al jugador autenticado.
- Actualiza `public.resolver_categoria_y_marca()` para respetar una selección superior válida en lugar de reasignarla automáticamente a la categoría natural.
- La asignación de marca de salida continúa derivándose de la categoría finalmente aceptada.
- La lógica de equipos, torneos de categoría única con franjas e inscripciones históricas no se modifica.
- Verificación ejecutada: **14 verificaciones, 0 errores**.

### Migración 176 — Control administrativo y liberación del torneo

- El Organizador puede **finalizar la configuración** del torneo mediante RPC; esto no lo publica ni cambia su estado de servicio.
- La configuración puede reabrirse mientras el torneo siga `provisionado`.
- `tournaments` registra `configuracion_finalizada_at` y `configuracion_finalizada_por`.
- `tournament_commercial_profiles` agrega `paid_by`, `released_at` y `released_by` para trazabilidad.
- El Superadmin confirma el pago de plataforma mediante `confirmar_pago_plataforma_torneo(...)`.
- El Superadmin libera el torneo mediante `liberar_torneo(uuid)`.
- La liberación exige **configuración finalizada + pago confirmado**.
- Se protege la coherencia: `estado_servicio='activo'` implica `activo=true`, y viceversa.
- Agrega `obtener_control_administrativo_torneos()` como fuente para una futura pestaña administrativa separada de la configuración deportiva.
- No modifica automáticamente torneos históricos ni publica el torneo de prueba al ejecutar la migración.
- Verificación Supabase: **pendiente de ejecutar**.

### Migración 177 — Teléfono permanente de usuarios administrativos

- Agrega `admin_users.telefono` como dato permanente del perfil de cualquier usuario administrativo.
- Mantiene `admin_user_invitations.phone` como dato histórico del proceso de invitación.
- Recupera teléfonos existentes desde la invitación aceptada más reciente cuando el perfil todavía no tiene teléfono.
- `aceptar_invitacion_admin(uuid)` copia el teléfono de la invitación al crear o actualizar `admin_users`.
- Ambas firmas de `asignar_o_invitar_admin(...)` conservan compatibilidad y actualizan el teléfono permanente cuando se proporciona uno explícitamente.
- No se crea una tabla exclusiva para organizadores: nombres, apellidos, email y teléfono viven en `admin_users`; roles y torneos asignados permanecen en `admin_role_assignments`.
- No altera asignaciones ni permisos existentes.

### Migración 178 — Categorías elegibles para inscripción administrativa

- Agrega `obtener_categorias_elegibles_jugador_inscripcion(tournament_id, player_id)`.
- Está destinada a flujos donde Superadmin u Organizador seleccionan un jugador, como **Reserva telefónica**.
- Reutiliza `_categorias_elegibles_jugador(...)`; no duplica reglas de negocio.
- Respeta categoría natural, categorías superiores, género y categorías por edad/Senior.
- Devuelve `handicap_minimo`, `handicap_maximo`, `tipo_elegibilidad` y `es_categoria_natural`.
- Solo usuarios autenticados pueden ejecutarla y valida Superadmin u Organizador del torneo.
- No modifica el autoservicio del jugador ni datos existentes.

### Migración 178 Fase 2 — Corrección de tipo en RPC administrativa

- Corrige el error PostgreSQL `42804` en `obtener_categorias_elegibles_jugador_inscripcion(uuid,uuid)`.
- `_categorias_elegibles_jugador(...)` devuelve `categoria_estandar_marca` como enum `categoria_marca_salida`; la RPC pública lo convierte explícitamente a `text`.
- Conserva firma pública, permisos y reglas de elegibilidad.
- No modifica datos ni otros flujos de inscripción.

### Migración 179 — Cupo por categoría y contacto del organizador

- Refuerza `validar_cupo_categoria_cruzado()` sin crear un control paralelo.
- El cupo individual sigue contando inscripciones activas, pre-reservas activas no convertidas y reservas telefónicas activas.
- Agrega el trigger faltante en `phone_reservations`, por lo que una reserva telefónica tampoco puede sobrepasar el cupo.
- Bloquea temporalmente la fila de la categoría durante la validación para evitar sobrecupo por altas concurrentes.
- Cuando la categoría está llena devuelve `DETAIL = CATEGORY_FULL` y un mensaje con nombre/teléfono del organizador cuando estén disponibles.
- Agrega `obtener_cupos_categorias_torneo(uuid)` como fuente única para mostrar cupo máximo, ocupados, disponibles y si la categoría está llena.
- Evita doble conteo al convertir una reserva telefónica de un contacto nuevo en pre-reserva formal.
- `validar_configuracion_minima_torneo()` exige que todas las categorías tengan `cupo_maximo > 0` y que la suma sea igual a `tournaments.cupo_maximo`.
- No altera torneos históricos ni descongela configuraciones existentes.

### Migración 179 Fase 2 — Disponibilidad por categoría

- Agrega `obtener_cupos_categorias_torneo(tournament_id)`.
- Devuelve por categoría `cupo_maximo`, inscripciones activas, pre-reservas activas no convertidas, reservas telefónicas activas, `ocupados`, `disponibles` y `llena`.
- La UI debe consumir esta RPC en lugar de recalcular cupos por su cuenta.
- `disponibles` nunca baja de cero; en categorías históricas con `cupo_maximo = NULL`, devuelve `disponibles = NULL` y `llena = false`.
- No modifica el control de concurrencia, triggers ni mensajes `CATEGORY_FULL` de la Migración 179.

### Migración 180 — Bloqueo de cierre de salidas con inscripciones abiertas

- Corrige una precondición de `previsualizar_validacion_salidas_ronda(tournament_round_id)`.
- Antes, un estatus de torneo distinto de `inscripcion_cerrada` o `en_curso` generaba `estatus_torneo_no_operativo` como **warning**.
- Ahora genera `estatus_torneo_no_operativo` como **error bloqueante**.
- `REVISAR SALIDAS` sigue disponible para consultar errores y advertencias antes del cierre.
- Como `ready` depende de que `errors` esté vacío, `VALIDAR Y CERRAR SALIDAS` no puede continuar mientras las inscripciones estén abiertas.
- `validar_salidas_ronda()` reutiliza la previsualización y hereda automáticamente esta regla.
- No modifica la preparación de grupos, turnos, snapshots, congelamiento de condiciones, emisión de tarjetas, scorecards ni resultados.
- La migración es defensiva: solo sustituye el bloque esperado si lo encuentra exactamente una vez; si la definición cambió, se detiene sin modificar la función.

### Migración 181 Fase 1 — Ciclo de vida del torneo e inicialización de captura

- Mantiene el enum deportivo existente: `planificado`, `inscripciones_abiertas`, `inscripcion_cerrada`, `en_curso`, `finalizado`, `cancelado`.
- La etiqueta visible de `planificado` debe mostrarse en UI como **EN PLANIFICACIÓN**; no se cambia el valor del enum.
- Agrega `abrir_inscripciones_torneo(tournament_id)`:
  - transición `planificado → inscripciones_abiertas`;
  - exige configuración finalizada;
  - exige `estado_servicio = activo` y `activo = true`;
  - sólo Superadmin u organizador asignado.
- Agrega `cerrar_inscripciones_torneo(tournament_id)`:
  - transición manual `inscripciones_abiertas → inscripcion_cerrada`;
  - no depende automáticamente de la fecha límite.
- Agrega `reabrir_inscripciones_torneo(tournament_id)`:
  - transición `inscripcion_cerrada → inscripciones_abiertas`;
  - sólo antes de congelar condiciones y hándicaps;
  - también rechaza estados históricos inconsistentes con salidas validadas o tarjetas ya emitidas.
- Agrega `iniciar_torneo(tournament_id)`:
  - transición manual `inscripcion_cerrada → en_curso`;
  - usa la primera ronda activa por `numero_ronda`;
  - exige freeze, salidas validadas, tarjetas oficiales emitidas y una sesión digital por cada tarjeta emitida.
- Corrige la brecha de captura digital:
  - `emitir_tarjetas_score_ronda(round_id)` llama a `inicializar_captura_scores_ronda(round_id)` dentro de la misma transacción;
  - si la inicialización falla, se revierte también la emisión nueva;
  - si ya existía una emisión histórica, volver a invocar la RPC completa las sesiones digitales sin duplicar tarjetas.
- **No se crea todavía `finalizar_torneo()`**: primero debe definirse/diagnosticarse cuál es el cierre oficial de una ronda y qué condición hace definitiva a la última ronda.
- **No se bloquean todavía los `UPDATE` directos a `tournaments.estatus`**: primero se debe cablear Lovable a las nuevas RPCs; después se agregará la protección backend para impedir saltos manuales.

### Migración 181 Fase 2 — Protección del estatus y cancelación formal

- Agrega `proteger_cambio_estatus_torneo()` y el trigger `trg_proteger_cambio_estatus_torneo`.
- Todo `UPDATE` directo que intente cambiar `tournaments.estatus` queda rechazado salvo que la operación autorizada establezca el permiso transaccional interno `app.permitir_cambio_estatus_torneo=1`.
- Las RPCs de 181 Fase 1 quedan adaptadas para atravesar el guard:
  - `abrir_inscripciones_torneo()`
  - `cerrar_inscripciones_torneo()`
  - `reabrir_inscripciones_torneo()`
  - `iniciar_torneo()`
- Se agrega `cancelar_torneo(tournament_id, motivo)`:
  - acción manual;
  - sólo Superadmin u organizador asignado;
  - exige motivo de al menos 10 caracteres;
  - admite cancelación desde `planificado`, `inscripciones_abiertas`, `inscripcion_cerrada` y `en_curso`;
  - es idempotente si ya está `cancelado`;
  - un torneo `finalizado` no puede cancelarse.
- La cancelación cambia únicamente el **estatus deportivo**. No modifica `estado_servicio`, que sigue siendo el eje comercial/operativo independiente de Tee Central.
- El trigger general `trg_audit_tournaments` ya existente continúa registrando el cambio de fila en `audit_log`.
- `finalizar_torneo()` sigue deliberadamente pendiente hasta formalizar qué evento hace oficial el cierre de la última ronda.

### Migración 181 Fase 3 — Cierre formal y auditable de ronda

- Crea `tournament_round_competitive_closures`, una fila única por ronda.
- El cierre almacena:
  - torneo y ronda;
  - número y fecha de ronda;
  - `competitive_status = FINAL`;
  - fotografía JSON completa devuelta por `obtener_estado_cierre_competitivo_ronda`;
  - administrador que cerró;
  - fecha/hora y notas.
- Agrega `cerrar_ronda_competitiva(round_id, notas)`:
  - sólo Superadmin u organizador asignado;
  - exige torneo `en_curso`;
  - reevalúa server-side `obtener_estado_cierre_competitivo_ronda`;
  - sólo cierra cuando `status.competitiveStatus = FINAL`;
  - es idempotente si la ronda ya estaba cerrada.
- **Rondas sin empate:** no requieren tratamiento especial. Si las tarjetas están resueltas y `pendingGroups=0`, el motor 162 devuelve `FINAL` y la ronda puede cerrarse.
- **Rondas con empate:** sólo pueden cerrarse cuando los desempates automáticos/manuales necesarios estén resueltos y el motor devuelva `FINAL`.
- Agrega `obtener_cierre_formal_ronda(round_id)` para consultar el sello persistido.
- El cierre es histórico e inmutable: no admite `UPDATE` ni `DELETE`.
- Después del cierre se bloquean cambios en las tablas competitivas principales:
  - `tournament_score_cards`;
  - `tournament_scorecard_capture_sessions`;
  - `tournament_scorecard_hole_scores`;
  - `tournament_scorecard_physical_receptions`;
  - `tournament_scorecard_physical_hole_scores`;
  - `tournament_scorecard_reconciliations`;
  - `tournament_scorecard_hole_resolutions`;
  - `tournament_scorecard_round_outcomes`;
  - `tournament_tiebreak_resolutions`.
- Las bitácoras históricas append-only existentes no se reescriben.
- No se implementa reapertura de ronda; si alguna vez se requiere deberá ser una operación extraordinaria y auditada.
- `finalizar_torneo()` sigue pendiente para **181 Fase 4** y deberá exigir cierre formal en todas las rondas activas.

### Migración 181 Fase 4 — Finalización formal del torneo

- Completa la transición deportiva `en_curso → finalizado`.
- Agrega `previsualizar_finalizacion_torneo(tournament_id)`:
  - lista todas las rondas activas;
  - indica cuáles tienen cierre competitivo formal de Fase 3;
  - devuelve `readyToFinalize`;
  - exige al menos una ronda activa y cero rondas pendientes.
- Agrega `finalizar_torneo(tournament_id, notas)`:
  - acción manual;
  - sólo Superadmin u organizador asignado;
  - exige `estatus = en_curso`;
  - reevalúa el preview en backend;
  - sólo finaliza si **todas las rondas activas** están formalmente cerradas;
  - atraviesa el guard de estatus mediante `app.permitir_cambio_estatus_torneo`;
  - cambia `tournaments.estatus` a `finalizado`.
- Crea `tournament_competitive_finalizations`:
  - una fila única por torneo;
  - snapshot JSON de las rondas y sus cierres;
  - actor y fecha/hora de finalización;
  - notas opcionales;
  - sello histórico inmutable.
- La operación es idempotente si el torneo ya está `finalizado` y existe su sello.
- Si un dato histórico figura `finalizado` sin sello formal, la RPC falla de manera explícita y no reconstruye silenciosamente el cierre.
- **Arquitectura multimodal:** esta fase no inspecciona `scoring_engine`, `participation_type`, `start_format`, Stroke, Stableford, equipos, Shotgun ni tee time. Sólo exige que cada ronda haya llegado previamente a su cierre formal común.
- Con esto queda completo el ciclo deportivo formal:
  - `planificado → inscripciones_abiertas`
  - `inscripciones_abiertas → inscripcion_cerrada`
  - `inscripcion_cerrada → inscripciones_abiertas` (sólo antes del freeze)
  - `inscripcion_cerrada → en_curso`
  - `en_curso → finalizado`
  - cancelación controlada desde estados permitidos.

### Migración 182 Fase 1 — Contrato común del motor de salidas

- Mantiene `tournament_rounds.formato_salida` como dato propio de la ronda.
- Crea `tournament_start_engine_registry` para separar formalmente formato de salida, tipo de participación y motor de puntuación.
- Registra sin alterar el único motor operativo actual: `shotgun + individual + stroke` → `shotgun_v1 / stroke_individual_shotgun_v1`.
- Agrega `start_contract_version` a `tournament_round_start_validations`; el flujo legacy permanece en versión 1 y el contrato común nuevo queda definido como versión 2.
- Generaliza `tournament_round_start_validation_groups` para validaciones futuras con `source_format_slot_id` y `source_format_metadata`.
- `start_position` pasa a nullable: A/B es un concepto de Shotgun y no debe ser obligatorio para Tee Times.
- `source_shotgun_hole_id` se conserva por compatibilidad histórica.
- **Las validaciones históricas no se modifican.** No se realiza backfill ni `UPDATE` sobre `tournament_round_start_validation_groups` o `tournament_round_start_validation_units`, porque `_impedir_mutacion_detalle_validacion_salida()` protege esos datos como históricos e inmutables.
- La equivalencia de campos Shotgun legacy (`source_shotgun_hole_id`, A/B) hacia el contrato común se resuelve **en tiempo de lectura** dentro de `_construir_contrato_salida_ronda(uuid)`.
- Agrega `obtener_motor_salida_ronda(uuid)` para resolver el motor efectivo desde la ronda y su modalidad competitiva.
- Agrega `_construir_contrato_salida_ronda(uuid)` con contrato `tee_central_round_start`, `schemaVersion = 2`.
- En esta fase el contrato común sólo adapta la fotografía Shotgun existente; todavía no sustituye las RPC operativas.
- No se modifican `previsualizar_validacion_salidas_ronda`, `validar_salidas_ronda` ni `emitir_tarjetas_score_ronda`, para garantizar que Shotgun siga funcionando exactamente igual.
- Fase 2: hacer que Shotgun produzca y consuma el contrato común v2 con prueba de equivalencia antes de implementar Tee Times.

### Migración 182 Fase 2 — Shotgun sobre contrato común v2

- El motor Shotgun deja de producir primero una fotografía legacy.
- Se agrega `_construir_contrato_salida_shotgun_v2(round_id)`, que genera directamente el contrato común:
  - `contract = tee_central_round_start`
  - `schemaVersion = 2`
  - `contractVersion = 2`
  - `preparationEngine = shotgun_v1`
  - `validationEngine = stroke_individual_shotgun_v1`
- `_construir_contrato_salida_ronda(round_id)` se convierte en dispatcher por motor de preparación.
- La firma histórica `_construir_fotografia_salida_ronda(round_id)` se conserva, pero ahora se deriva mediante `_adaptar_contrato_salida_a_snapshot_legacy(contract)`.
- Se invierte así la dependencia:
  - antes: Shotgun legacy → contrato común;
  - desde esta fase: Shotgun → contrato común → adaptación legacy sólo si algún consumidor antiguo la necesita.
- `previsualizar_validacion_salidas_ronda` mantiene intactas todas sus reglas actuales; todavía sólo valida Stroke Play individual + Shotgun.
- `validar_salidas_ronda` ahora:
  - consume `_construir_contrato_salida_ronda`;
  - persiste `validation_snapshot` en contrato v2;
  - marca `start_contract_version = 2`;
  - persiste `source_format_slot_id`;
  - persiste `source_format_metadata`;
  - conserva `source_shotgun_hole_id` para compatibilidad del motor vigente;
  - admite contractualmente `teamId`, aunque el motor actual siga produciendo `unitType=registration`.
- `emitir_tarjetas_score_ronda` no se modifica todavía y conserva las restricciones:
  - `validator_engine = stroke_individual_shotgun_v1`;
  - `start_format = shotgun`;
  - `participation_type = individual`;
  - `scoring_engine = stroke`;
  - `unit_type = registration`.
- No se hace ningún UPDATE sobre validaciones históricas; el guard de inmutabilidad permanece intacto.
- Objetivo de la Fase 3: desacoplar la emisión de tarjetas del nombre `stroke_individual_shotgun_v1`, haciendo que consuma las unidades normalizadas validadas y una capacidad explícita del motor, sin implementar aún Tee Times.

### Migración 182 Fase 3 — Capacidades del motor para emisión de tarjetas (corregida)

- Se agregan capacidades explícitas al registro central:
  - `supports_scorecard_emission`;
  - `scorecard_unit_type`;
  - `scorecard_emission_engine`.
- La configuración es fail-closed: primero se deshabilitan capacidades y luego se habilita solamente el motor vigente:
  - Shotgun;
  - individual;
  - Stroke;
  - `shotgun_v1`;
  - `stroke_individual_shotgun_v1`;
  - unidad `registration`;
  - estrategia `official_scorecard_registration_v1`.
- `_resolver_capacidad_emision_tarjetas_ronda(round_id)` usa la validación formal sellada como autoridad y relaciona su metadata con `tournament_start_engine_registry`.
- `_contar_unidades_invalidas_emision_tarjetas(validation_id, expected_unit_type)` reemplaza el supuesto hardcoded del emisor:
  - para `registration` exige `tournament_registration_id` y `player_id`;
  - contractualmente contempla `team`, exigiendo `tournament_team_id`;
  - ningún motor team queda habilitado en esta fase.
- `emitir_tarjetas_score_ronda(round_id)` fue reconstruida explícitamente desde la definición instalada, sin `regexp_replace` ni SQL dinámico.
- Se preserva su lógica anterior:
  - autenticación/autorización;
  - lock de ronda;
  - idempotencia;
  - lookup de administrador;
  - validación formal requerida;
  - conteo de unidades;
  - `tournament_score_card_emissions`;
  - `tournament_score_cards`;
  - numeración y folio `Rxx-Vxx-xxxx`;
  - comprobación de número de tarjetas insertadas;
  - `inicializar_captura_scores_ronda` en la misma transacción.
- El emisor ya no decide mediante:
  - `validator_engine = stroke_individual_shotgun_v1`;
  - `start_format = shotgun`;
  - `participation_type = individual`;
  - `scoring_engine = stroke`;
  - `unit_type = registration`.
- Esas capacidades provienen ahora del motor registrado.
- `previsualizar_validacion_salidas_ronda` sigue deliberadamente limitado al motor Shotgun actual.
- Tee Times sigue pendiente y no queda habilitado accidentalmente.
- No se modifican validaciones históricas.

### Migración 182 Fase 4 — Dispatcher de validadores de salida

- Se agregan capacidades de validación a `tournament_start_engine_registry`:
  - `supports_start_validation`;
  - `start_validation_handler`.
- La configuración es fail-closed y sólo habilita el motor operativo actual:
  - Shotgun;
  - individual;
  - Stroke;
  - handler `shotgun_v1`.
- La función pública existente `previsualizar_validacion_salidas_ronda(uuid)` deja de contener las reglas específicas del formato.
- El validador actual se conserva íntegro mediante rename a:
  - `_previsualizar_validacion_salidas_shotgun_v1(uuid)`.
- Esto preserva exactamente los códigos, mensajes y reglas existentes:
  - configuración Shotgun por categoría/turno;
  - hoyos habilitados;
  - grupos ligados a configuración activa;
  - posiciones A/B;
  - salida doble;
  - consistencia de hoyo/turno/hora;
  - límites de grupo;
  - asignación individual;
  - warnings existentes.
- `_resolver_validador_salida_ronda(round_id)` determina si el motor de la ronda tiene un handler activo.
- `previsualizar_validacion_salidas_ronda(round_id)` pasa a ser un dispatcher genérico:
  - conserva la misma firma pública;
  - conserva autenticación/autorización;
  - para el motor actual despacha a `shotgun_v1`;
  - para motores no soportados devuelve `ready=false` con error estructurado, en vez de un fallo técnico;
  - no consulta directamente tablas `tournament_shotgun_*`;
  - no contiene reglas A/B;
  - no decide directamente por `Stroke Play individual + Shotgun`.
- `validar_salidas_ronda(round_id)` no necesita reescritura: ya llama la RPC pública de preview y construye el contrato común v2.
- `emitir_tarjetas_score_ronda(round_id)` continúa desacoplada mediante las capacidades introducidas en Fase 3.
- Esta fase separa **orquestación genérica** de **reglas específicas del motor** sin reescribir el validador Shotgun probado.
- Tee Times continúa pendiente y no queda habilitado accidentalmente.
- Próximo paso recomendado: implementar el motor de preparación/validación Tee Times contra estas interfaces comunes, antes de hacer cambios de UI generales en la pestaña SALIDAS.

### Migración 183 Fase 1 — Configuración del motor Tee Times

- `formato_salida` permanece en `tournament_rounds`; no se mueve al torneo.
- La primera hora de salida se reutiliza desde `tournament_round_shifts.hora_salida`. No se crea una segunda fuente de verdad.
- Se crea `tournament_tee_time_shift_configs`:
  - una configuración activa por turno;
  - intervalo entre grupos;
  - auditoría y baja lógica.
- Se crea `tournament_tee_time_shift_start_holes`:
  - uno o dos streams/tees de inicio;
  - `lane_order` 1/2;
  - `hoyo_id` genérico;
  - `offset_inicio_minutos`;
  - permite single tee o double tee sin asumir necesariamente hoyos 1 y 10.
- Se crea `tournament_tee_time_category_configs`:
  - una configuración activa por categoría-turno;
  - tamaño normal;
  - tamaño máximo;
  - `sequence_order` para definir el orden de bloques de categoría dentro del turno.
- Se agregan helpers/RLS para lectura y administración de configuración Tee Times.
- Se registra en `tournament_start_engine_registry`:
  - `start_format = tee_times`;
  - `participation_type = individual`;
  - `scoring_engine = stroke`;
  - `preparation_engine = tee_times_v1`;
  - `validation_engine = stroke_individual_tee_times_v1`;
  - `contract_version = 2`.
- El motor queda deliberadamente fail-closed:
  - `supports_start_validation = false`;
  - `start_validation_handler = NULL`;
  - `supports_scorecard_emission = false`;
  - `scorecard_unit_type = NULL`;
  - `scorecard_emission_engine = NULL`.
- Esta fase NO crea grupos ni secuencia horarios reales.
- Esta fase NO construye todavía el contrato común Tee Times.
- Esta fase NO habilita validación/cierre ni emisión.
- Shotgun permanece intacto.
- Fase 2 deberá construir la preparación Tee Times y materializar grupos/horarios sobre `tournament_groups`, reutilizando `hoyo_id`, `hora_salida` y la asignación existente de jugadores/grupos sin inventar campos Shotgun.

### Migración 183 Fase 2 — Preparación de grupos Tee Times

- Tee Times reutiliza las entidades comunes:
  - `tournament_groups`;
  - `tournament_group_players`.
- No se crean grupos paralelos ni se inventan campos Shotgun.
- En un grupo Tee Times:
  - `tournament_shotgun_category_hole_id = NULL`;
  - `posicion_salida = NULL`;
  - `hoyo_id` contiene el tee/hoyo real de inicio;
  - `hora_salida` contiene la hora real derivada.
- Se crea `tournament_tee_time_groups` como metadata específica:
  - grupo común;
  - configuración de categoría;
  - tee/hoyo de inicio;
  - `sequence_number`.
- `hora_salida_tee_time(start_hole_id, sequence)` calcula:
  - fecha de la ronda;
  - `tournament_round_shifts.hora_salida`;
  - `offset_inicio_minutos`;
  - `(sequence - 1) * intervalo_grupos_minutos`;
  - timezone del club.
- `materializar_conformacion_tee_times(shift_config_id, grupos)` trabaja por turno completo:
  - evita colisiones de stream/secuencia;
  - evita duplicar una inscripción;
  - exige pertenencia a la categoría;
  - aplica `tamano_grupo_maximo`;
  - crea el grupo común;
  - crea metadata Tee Times;
  - asigna jugadores con `tournament_group_players`.
- La conformación no se decide automáticamente en backend: el preparador/UI define quién integra cada grupo y la RPC valida/materializa esa decisión.
- `obtener_conformacion_tee_times(shift_config_id)` expone la conformación persistida.
- `_construir_contrato_salida_tee_times_v1(round_id)` construye `tee_central_round_start` v2:
  - `preparationEngine = tee_times_v1`;
  - `validationEngine = stroke_individual_tee_times_v1`;
  - `startPosition = NULL`;
  - metadata: `sequenceNumber` y `laneOrder`.
- `_construir_contrato_salida_ronda(round_id)` ya despacha también a Tee Times.
- Tee Times continúa deliberadamente:
  - `supports_start_validation = false`;
  - `supports_scorecard_emission = false`.
- Shotgun no se modifica.
- Fase 3 deberá implementar y habilitar el handler de validación Tee Times; sólo después podrá cerrarse formalmente la salida.

### Migración 183 Fase 3 — Validador Tee Times

- Se implementa `_previsualizar_validacion_salidas_tee_times_v1(round_id)`.
- El handler comparte las precondiciones competitivas ya consolidadas:
  - ronda activa;
  - torneo congelado;
  - snapshot de ronda;
  - formato congelado consistente;
  - torneo en `inscripcion_cerrada` o `en_curso`;
  - 18 hoyos congelados;
  - distancias congeladas completas;
  - participantes activos con snapshot de ronda.
- Reglas específicas Tee Times:
  - la ronda debe ser `tee_times`;
  - sólo Stroke Play individual en esta versión;
  - cada turno activo debe tener configuración Tee Times;
  - cada configuración de turno debe tener uno o dos streams/tees de inicio;
  - cada categoría-turno con participantes elegibles debe tener configuración;
  - `sequence_order` debe ser único dentro del turno;
  - todo grupo activo de la ronda debe tener metadata `tournament_tee_time_groups`;
  - los grupos Tee Times no pueden contener `tournament_shotgun_category_hole_id` ni `posicion_salida`;
  - grupo, categoría, turno y tee de inicio deben formar una cadena activa/consistente;
  - `startHoleId + sequenceNumber` no puede repetirse;
  - `tournament_groups.hora_salida` debe coincidir exactamente con `hora_salida_tee_time(...)`;
  - ningún grupo puede estar vacío;
  - ningún grupo puede superar `tamano_grupo_maximo`;
  - `orden_en_grupo` debe ser completo y único;
  - cada jugador debe pertenecer a la categoría del bloque;
  - cada asignación debe ser activa y tener snapshot;
  - cada participante elegible debe aparecer exactamente una vez;
  - no pueden existir unidades de equipo;
  - los bloques de categoría deben respetar `sequence_order` en cada stream.
- Warnings:
  - congelamiento con advertencias;
  - inscripciones congeladas posteriormente retiradas;
  - grupos por debajo de `tamano_grupo_normal`.
- Se agrega `validar_orden_categoria_tee_times()` como guard de `sequence_order` único por turno.
- `tournament_start_engine_registry` queda:
  - `supports_start_validation = true`;
  - `start_validation_handler = tee_times_v1`.
- `previsualizar_validacion_salidas_ronda(round_id)` despacha ahora tanto:
  - `shotgun_v1`;
  - `tee_times_v1`.
- `validar_salidas_ronda(round_id)` no se duplica ni se reescribe: usa el dispatcher público y el contrato común.
- Después de esta fase Tee Times puede:
  - REVISAR SALIDAS;
  - VALIDAR Y CERRAR SALIDAS.
- La emisión oficial de tarjetas permanece deshabilitada hasta 183 Fase 4.
- Shotgun permanece intacto.

### Migración 183 Fase 4 — Emisión de tarjetas Tee Times

**Corrección de construcción:** el primer archivo de 183 Fase 4 contenía un `IF NOT FOUND`
fuera de un bloque PL/pgSQL. La versión corregida encapsula la actualización del registro
del motor dentro de `DO $migration$ ... $migration$`, usa `GET DIAGNOSTICS ... ROW_COUNT`
y exige exactamente una fila actualizada. El intento anterior falló dentro de la transacción
y no dejó cambios aplicados.

- Se habilita en `tournament_start_engine_registry` para Tee Times individual Stroke:
  - `supports_scorecard_emission = true`;
  - `scorecard_unit_type = registration`;
  - `scorecard_emission_engine = official_scorecard_registration_v1`.
- No se crea una función `emitir_tarjetas_tee_times`: Tee Times reutiliza `emitir_tarjetas_score_ronda(round_id)`.
- El emisor sigue resolviendo la capacidad desde la validación formal sellada mediante `_resolver_capacidad_emision_tarjetas_ronda`.
- Se hace un único ajuste de orden de folios para soportar ambos formatos:
  - Shotgun conserva su orden histórico por `shift_number`, `hole_number`, `start_position`, jugador;
  - Tee Times, donde `start_position` es `NULL`, incorpora `start_at` para respetar el orden cronológico real antes de ordenar por hoyo/jugador.
- El folio oficial permanece `Rxx-Vxx-xxxx`.
- Tee Times reutiliza:
  - `tournament_score_card_emissions`;
  - `tournament_score_cards`;
  - `inicializar_captura_scores_ronda`;
  - `tournament_scorecard_capture_sessions`;
  - `tournament_scorecard_hole_scores`;
  - `tournament_scorecard_marker_assignments`.
- `inicializar_captura_scores_ronda` ya consume el grupo validado común:
  - exige unidades `registration` con jugador/inscripción;
  - usa `tournament_round_start_validation_groups.hole_number` como punto de inicio;
  - no depende de `source_shotgun_hole_id`.
- Por ello el `play_sequence` funciona también para Tee Times: comienza en el tee/hoyo inicial validado del grupo.
- La asignación circular de marcadores continúa siendo por grupo validado y es independiente del formato de salida.
- La emisión permanece idempotente.
- Shotgun continúa habilitado y usando el mismo emisor.
- No se habilitan unidades `team` ni modalidades por equipos.
- Con esta fase, el backend Tee Times individual Stroke queda enlazado de punta a punta:
  - configuración;
  - conformación/materialización;
  - contrato común;
  - revisión;
  - validación/cierre de salidas;
  - emisión de tarjetas;
  - inicialización de captura física/digital.
- El siguiente trabajo ya es principalmente frontend/UX: convertir la pestaña `SALIDAS SHOTGUN` en `SALIDAS` y mostrar el preparador correspondiente según `tournament_rounds.formato_salida`.

### Migración 184 Fase 1 — NRQ y autocierre de conciliación

- Se incorpora una distinción explícita entre el `status` técnico de conciliación y su requerimiento funcional:
  - `reconciliation_requirement = REQUIRED`: hubo captura digital real y la conciliación aplica.
  - `reconciliation_requirement = NOT_REQUIRED`: no hubo captura digital real; la UI debe mostrar **NRQ — No requiere conciliación**.
- La existencia de una sesión `ready` o de filas de hoyos inicializadas NO se considera captura digital real, porque `inicializar_captura_scores_ronda` crea esas estructuras para todas las tarjetas.
- Se considera captura digital real si existe al menos una de estas señales:
  - `capture_session.started_at IS NOT NULL`;
  - `capture_session.status IN ('in_progress','captured')`;
  - al menos un `tournament_scorecard_hole_scores.gross_score` no nulo.
- Al cambiar una recepción física a `CAPTURED`, `trg_autocompletar_conciliacion_nrq_al_finalizar_fisica` evalúa la tarjeta en la misma transacción:
  - si hubo digital real, no interviene y continúa el flujo normal;
  - si no hubo digital real, crea o completa `tournament_scorecard_reconciliations` con `status=COMPLETED` y `reconciliation_requirement=NOT_REQUIRED`.
- El evento `reconciliation_not_required` deja auditoría explícita de la decisión NRQ.
- Las conciliaciones `VOIDED` no son reactivadas automáticamente.
- Se protege la inmutabilidad funcional del NRQ: después de cerrar una tarjeta como `NOT_REQUIRED`, un trigger en `tournament_scorecard_hole_scores` impide introducir posteriormente un score digital.
- Se usa un advisory lock transaccional por `score_card_id` para serializar el cierre físico NRQ contra una captura digital concurrente.
- Se normalizan también tarjetas históricas cuya captura física ya está `CAPTURED` y nunca tuvieron digital real: si no existe conciliación se crea directamente `COMPLETED/NOT_REQUIRED`; si existe y no está anulada, se completa y marca `NOT_REQUIRED`. Así no hay que esperar a que el trigger vuelva a dispararse. No se alteran scores ni resultados históricos.
- Se crea `obtener_estados_conciliacion_ronda(uuid)` para frontend. Por tarjeta devuelve:
  - categoría;
  - `digitalUsed`;
  - `reconciliationRequirement`;
  - `technicalReconciliationStatus`;
  - `operationalStatus`: `NRQ`, `CONCILIADA`, `PENDIENTE_CONCILIAR` o `NO_APLICA_AUN` mientras la física aún no termina y todavía no puede decidirse si habrá digital. Una tarjeta sin digital nunca se etiqueta `PENDIENTE_CONCILIAR`.
- La RPC incluye resumen de cantidades `nrq`, `conciliadas` y `pendientesConciliar`, facilitando el botón global y los filtros por categoría/estado.
- No se modifica la autoridad de resultados oficiales: `obtener_resultados_oficiales_ronda` y `obtener_score_oficial_tarjeta` siguen requiriendo técnicamente conciliación `COMPLETED`; las tarjetas NRQ satisfacen ese requisito automáticamente al terminar la captura física.
- La tarjeta física continúa siendo obligatoria y la digital continúa siendo opcional.

### Migración 184 Fase 1A — Corrección de privilegios de helpers NRQ

- Esta migración es una corrección posterior a la ejecución y verificación de **184 Fase 1**.
- La verificación original de 184 Fase 1 reportó **25 verificaciones; 1 error**, únicamente en `25_HELPERS_PRIVADOS`.
- El diagnóstico confirmó que:
  - `_tarjeta_tiene_captura_digital_real(uuid)` ya estaba correctamente cerrado al frontend.
  - `_autocompletar_conciliacion_nrq_al_finalizar_fisica()` conservaba `EXECUTE` para `authenticated`.
  - `_proteger_captura_digital_despues_nrq()` conservaba `EXECUTE` para `authenticated`.
- La corrección revoca `ALL` para:
  - `PUBLIC`;
  - `anon`;
  - `authenticated`.
- Después concede `EXECUTE` únicamente a `service_role`.
- Los triggers continúan funcionando normalmente porque PostgreSQL puede ejecutar sus funciones trigger sin requerir que el usuario frontend tenga `EXECUTE` directo sobre ellas.
- No se modifica:
  - el estado operativo `NRQ`;
  - `reconciliation_requirement`;
  - el autocierre a `COMPLETED`;
  - el evento `reconciliation_not_required`;
  - el backfill histórico;
  - la protección contra captura digital posterior;
  - los resultados oficiales;
  - Gross/Neto;
  - la conciliación;
  - ninguna fila de datos.
- Después de aplicar esta corrección debe volver a ejecutarse la verificación de **184 Fase 1**, cuyo resultado esperado es **25 verificaciones; 0 errores**.

| 185 Fase 1 | `185_FASE1_PREFERENCIA_PUNTO_SALIDA_CATEGORIA_TEE_TIMES.sql` | Agrega `preferred_start_lane` a `tournament_tee_time_category_configs` con valores `LANE_1`, `LANE_2` o `BOTH`. El organizador puede definir el punto de salida por categoría, mientras que `tournament_tee_time_groups.tournament_tee_time_start_hole_id` continúa siendo el punto real de cada grupo, permitiendo excepciones manuales. Las configuraciones existentes se inicializan como `BOTH` para preservar el comportamiento anterior. |

### Migración 185 Fase 1 — Preferencia de punto de salida por categoría en Tee Times

- Se formaliza la regla operativa indicada por golf: **el organizador define por cuál punto/hoyo de inicio sale cada categoría**; la asignación no se deriva del orden de categoría.
- `tournament_tee_time_category_configs.preferred_start_lane` admite `LANE_1`, `LANE_2` y `BOTH`.
- `LANE_1` y `LANE_2` representan el primer y segundo punto de salida configurados para el turno. La UI posterior mostrará sus hoyos reales (por ejemplo Hoyo 1 / Hoyo 10), evitando hardcodearlos en el modelo.
- `BOTH` permite que los grupos de la categoría se distribuyan entre ambos puntos.
- La preferencia de categoría funciona como criterio **por defecto** para construir la propuesta, no como restricción absoluta.
- El punto real de cada grupo continúa persistido en `tournament_tee_time_groups.tournament_tee_time_start_hole_id`. Esto permite excepciones manuales, por ejemplo mover un grupo concreto al Hoyo 1 aunque su categoría normalmente salga por el Hoyo 10.
- Las configuraciones existentes reciben `BOTH`, por lo que la migración no altera silenciosamente la conformación histórica ni obliga a elegir un punto antes de actualizar el frontend.
- Esta fase no modifica `materializar_conformacion_tee_times`, validación, intervalos, offsets, horarios, grupos existentes, Shotgun ni emisión de tarjetas.
- La siguiente fase corresponde al frontend: selector Hoyo 1 / Hoyo 10 / Ambos por categoría y uso de esa preferencia al generar la propuesta automática.

| 185 Fase 1A | `185_FASE1A_CORRECCION_TIMEZONE_TEE_TIMES.sql` | Corrige `hora_salida_tee_time(uuid,integer)`: elimina la referencia inválida `clubs.timezone` y adopta la misma fuente autoritativa usada por Shotgun, `tournament_rounds.campo_golf_id → campos_golf.timezone_id → timezones.iana_id`. Conserva intervalo, offset, secuencia, materialización y Shotgun sin cambios. |\n
### Migración 185 Fase 1A — Corrección de zona horaria en Tee Times

- Se corrige un error detectado al confirmar la materialización Tee Times: `column c.timezone does not exist`.
- La cadena del error era `materializar_conformacion_tee_times` → `hora_salida_tee_time` → `clubs c` → `c.timezone`.
- `public.clubs` no tiene columna `timezone`; la relación disponible es `city_id`, pero esa ruta no se utiliza en esta corrección.
- Se adopta la misma fuente autoritativa ya utilizada por `hora_salida_shotgun`: `tournament_rounds.campo_golf_id → campos_golf.timezone_id`.
- El `timezone_id` se valida además contra `timezones.iana_id` activo.
- El cálculo mantiene exactamente la fórmula vigente: fecha de la ronda + hora inicial del turno + offset del punto de salida + `(sequence_number - 1) × intervalo_grupos_minutos`, interpretado en la zona horaria del campo.
- No se modifica `materializar_conformacion_tee_times`, `preferred_start_lane`, grupos existentes, Shotgun ni ninguna fila de datos.
- `hora_salida_tee_time` permanece como helper backend y no se expone directamente a `authenticated`.

| 185 Fase 1B | `185_FASE1B_ORDEN_MANUAL_GRUPOS_TEE_TIMES.sql` | Separa `sequence_order` de la secuencia real Tee Times. La propuesta automática sigue usando `sequence_order`, pero VALIDAR Y CERRAR deja de rechazar reordenamientos manuales entre categorías. El validador previo se conserva como core y un wrapper elimina únicamente `orden_categorias_inconsistente`, recalculando `counts.errors` y `ready`; las demás validaciones permanecen intactas. |

### Migración 185 Fase 1B — Orden manual de grupos Tee Times

- `sequence_order` queda formalizado como criterio de generación de la propuesta automática, no como restricción del orden real.
- El organizador puede usar SUBIR / BAJAR para cruzar grupos de categorías distintas dentro del mismo punto de salida.
- El orden real materializado queda definido por `tournament_tee_time_start_hole_id + sequence_number`.
- La implementación previa de `_previsualizar_validacion_salidas_tee_times_v1` se conserva como `_previsualizar_validacion_salidas_tee_times_v1_core_1851b`.
- La firma `_previsualizar_validacion_salidas_tee_times_v1(uuid)` permanece estable para el dispatcher y actúa como wrapper.
- El wrapper elimina únicamente el error `orden_categorias_inconsistente`, recalcula `counts.errors` y `ready`.
- No se convierte en warning porque el reordenamiento manual ya es una decisión válida del organizador.
- Continúan intactas las validaciones de slots duplicados, horarios, tamaño máximo, categoría del jugador, participante único, snapshots y warnings de grupos incompletos.
- No se modifica `materializar_conformacion_tee_times`, `sequence_order`, `preferred_start_lane`, Shotgun ni datos históricos.

| 185 Fase 1C | `185_FASE1C_SOPORTE_TEE_TIME_GROUPS_GUARD_SALIDAS.sql` | Agrega `tournament_tee_time_groups` al resolver genérico `_resolver_ronda_fila_salida(text,jsonb)`, permitiendo que el trigger de inmutabilidad Tee Times determine la ronda mediante `tournament_group_id → tournament_groups → tournament_round_shifts`. Corrige el error `Tabla de salida no soportada: tournament_tee_time_groups` sin modificar materialización, Shotgun ni datos. |

### Migración 185 Fase 1C — Soporte de `tournament_tee_time_groups` en guard de salidas

- Se corrige el error al confirmar la materialización Tee Times: `Tabla de salida no soportada: tournament_tee_time_groups`.
- La cadena detectada fue `materializar_conformacion_tee_times` → `INSERT tournament_tee_time_groups` → `trg_proteger_cierre_salidas_tee_times` → `_proteger_objeto_salida_ronda_validada()` → `_resolver_ronda_fila_salida(...)`.
- El resolver genérico no contemplaba `tournament_tee_time_groups`, aunque el trigger Tee Times ya estaba correctamente instalado.
- La nueva rama resuelve la ronda desde `tournament_group_id → tournament_groups.tournament_round_shift_id → tournament_round_shifts.tournament_round_id`.
- No se modifica el materializador ni el trigger; únicamente se amplía el resolver genérico para reconocer la tabla Tee Times.
- Se preservan todas las ramas existentes para Shotgun, grupos comunes, jugadores y equipos.
- El helper continúa cerrado a `authenticated`.

| 185 Fase 1D | `185_FASE1D_ENRIQUECER_CONFORMACION_TEE_TIMES.sql` | Enriquece `obtener_conformacion_tee_times(uuid)` para que la UI de salidas preparadas reciba categoría, lane real, preferencia, jugadores, folio y hándicap desde snapshots congelados, además de `horaSalidaLocal` (`HH:MM`) en la zona horaria del campo. Conserva el `timestamptz` oficial y todos los identificadores previos. |

### Migración 185 Fase 1D — Lectura completa de salidas preparadas Tee Times

- La materialización de Tee Times ya contenía correctamente grupos, jugadores y horas; el problema estaba en el contrato de lectura de `obtener_conformacion_tee_times`.
- La RPC ahora expone por grupo: `tournamentCategoryId`, `categoryId`, `categoryCode`, `categoryName`, `categoryDisplayOrder`, `categoryPreferredStartLane`, `actualLaneOrder` y `startLaneOverride`.
- `horaSalida` conserva el `timestamptz` oficial.
- Se agrega `horaSalidaLocal` en formato `HH:MM`, calculado con `campos_golf.timezone_id`.
- La respuesta superior incluye `timezone`.
- Cada unidad conserva `id` y `orden`, y agrega `registrationId`, `playerId`, `playerName`, `registrationFolio`, `handicapIndex`, `handicapSource`, `tournamentCategoryId` y `categoryName`.
- Los datos de jugador, folio y hándicap provienen de `tournament_round_handicap_snapshots → tournament_handicap_snapshots`, para respetar la fotografía congelada del torneo y no reconstruir la salida desde datos vivos.
- No se modifica materialización, validación, Shotgun ni datos existentes.

| 185 Fase 1E | `185_FASE1E_FAIL_CLOSED_MATERIALIZACION_TEE_TIMES.sql` | Hace fail-closed la materialización Tee Times: exige inscripciones cerradas/en curso, congelamiento, snapshot de condiciones de la ronda y snapshots de hándicap antes de crear grupos. Preserva el materializador anterior como core y agrega `descartar_conformacion_tee_times(uuid,text)` para limpiar conformaciones no validadas y sin tarjetas. |

### Migración 185 Fase 1E — Fail-closed y descarte seguro de conformación Tee Times

- Se corrige una brecha de flujo: Tee Times permitía materializar grupos con `inscripciones_abiertas`, antes del congelamiento y sin snapshots.
- `materializar_conformacion_tee_times(uuid,jsonb)` se conserva como firma pública estable y pasa a ser un wrapper de precondiciones.
- La implementación previa se preserva como `materializar_conformacion_tee_times_core_1851e(uuid,jsonb)`.
- Antes de delegar al core se exige: torneo en `inscripcion_cerrada` o `en_curso`, congelamiento existente, snapshot de condiciones de la ronda y al menos un snapshot de hándicap de ronda del mismo freeze.
- También se bloquea rematerialización si la ronda ya está validada o tiene tarjetas oficiales emitidas.
- Se agrega `descartar_conformacion_tee_times(uuid,text)` para eliminar de forma controlada una conformación persistida que todavía no es histórica/oficial.
- El descarte exige permiso administrativo, motivo, ronda no validada y ausencia de tarjetas; elimina primero `tournament_group_players`, después metadata `tournament_tee_time_groups` y finalmente los `tournament_groups` asociados.
- Se incluye un script separado de limpieza para conformaciones prematuras detectables (torneo aún abierto y sin freeze). No forma parte automática de la migración.
- No se modifica Shotgun, validación competitiva, emisión de tarjetas ni resultados.

| 185 Fase 1E-A | `185_FASE1EA_CORREGIR_DESCARTE_CONFORMACION_TEE_TIMES.sql` | Corrige `descartar_conformacion_tee_times(uuid,text)` para respetar `trg_validar_borrado_grupo_vacio`: tras eliminar jugadores y metadata Tee Times, desactiva y audita `tournament_groups` antes de su borrado físico. Mantiene intactas las defensas de ronda validada y tarjetas emitidas. |

### Migración 185 Fase 1E-A — Corrección del descarte de conformación Tee Times

- La RPC de descarte creada en 185 Fase 1E intentaba borrar `tournament_groups` todavía activos.
- `trg_validar_borrado_grupo_vacio` exige que el grupo esté inactivo y sin jugadores antes del `DELETE`.
- El orden corregido es: eliminar `tournament_group_players`, eliminar `tournament_tee_time_groups`, desactivar/auditar `tournament_groups` y finalmente eliminarlos.
- La desactivación registra `fecha_baja`, `dado_de_baja_por` y `motivo_baja`.
- Se mantienen todas las defensas previas: permisos administrativos, motivo obligatorio, lock de ronda, prohibición sobre ronda validada y prohibición si existen tarjetas emitidas.
- No se elimina ni deshabilita ningún trigger existente.
- Se incluye una versión V2 del script de mantenimiento para SQL Editor, que aplica el mismo orden sin depender de `auth.uid()`.

| 185 Fase 1F | `185_FASE1F_EDICION_PERSISTENTE_CONFORMACION_TEE_TIMES.sql` | Agrega edición transaccional real de una conformación Tee Times ya materializada mediante `actualizar_conformacion_tee_times(uuid,jsonb)`: conserva `groupId` existentes, permite reordenar slots, cambiar tee, mover jugadores, crear grupos y dar de baja grupos omitidos sin descartar toda la conformación. Corrige además `validar_grupo_individual()` para que Tee Times use su categoría y `tamano_grupo_maximo` nativos. La edición queda bloqueada después de validar o emitir tarjetas. |

### Migración 185 Fase 1F — Edición persistente de conformación Tee Times

- Se formaliza el estado **PREPARADA — EDITABLE** entre materialización y validación.
- La nueva RPC `actualizar_conformacion_tee_times(uuid,jsonb)` recibe el draft completo final de un turno Tee Times.
- Los grupos existentes enviados con `groupId` conservan su identidad; sólo se actualizan hoyo, hora, categoría, tee de inicio y secuencia.
- Los grupos con `groupId = null` se crean como grupos nuevos.
- Los grupos existentes omitidos del payload se dan de baja lógicamente; no se destruyen físicamente.
- Los jugadores se sincronizan de forma atómica dentro de la misma transacción para permitir movimientos entre grupos sin estados intermedios visibles.
- Antes de reubicar slots, la metadata `tournament_tee_time_groups` se neutraliza temporalmente (`activo=false`) dentro de la transacción. Esto permite swaps de secuencias y lanes sin chocar temporalmente con el índice único `(start_hole_id, sequence_number)`.
- El estado final exige slots únicos, jugadores únicos, ausencia de grupos vacíos, máximos por categoría y exactamente los participantes congelados asignados al turno.
- Categorías y participantes se validan contra snapshots congelados.
- Se mantienen las defensas: inscripciones cerradas/en curso, freeze vigente, ronda incluida en freeze, snapshots de hándicap, ronda no validada y ausencia de tarjetas oficiales.
- `validar_grupo_individual()` incorpora una rama específica Tee Times y obtiene `tamano_grupo_maximo` y categoría desde `tournament_tee_time_groups → tournament_tee_time_category_configs → tournament_round_shift_categories`.
- Los guards existentes continúan siendo la frontera definitiva: después de `VALIDAR Y CERRAR`, grupos, metadata Tee Times y jugadores no pueden modificarse.
- `materializar_conformacion_tee_times` sigue siendo la operación de creación inicial; `actualizar_conformacion_tee_times` es exclusivamente para edición posterior.
- No se modifica Shotgun.

| 185 Fase 1G | `185_FASE1G_CATEGORY_NAME_CONTRATO_TEE_TIMES.sql` | Corrige `_construir_contrato_salida_tee_times_v1(uuid)` para incluir `categoryName` en cada grupo usando `tournament_handicap_snapshots.category_name` congelado, permitiendo persistir `tournament_round_start_validation_groups.category_name NOT NULL`. |

### Migración 185 Fase 1G — `categoryName` en contrato Tee Times

- `VALIDAR Y CERRAR` fallaba porque el contrato Tee Times omitía `categoryName`.
- El nombre de categoría ahora sale del snapshot congelado del grupo.
- `validar_salidas_ronda(uuid)` permanece intacto.
- La restricción `category_name NOT NULL` permanece.
- Shotgun no se modifica.

| 185 Fase 1H | `185_FASE1H_PREVISUALIZACION_OFICIAL_TARJETAS.sql` | Agrega `previsualizar_tarjetas_score_ronda(uuid)`, una previsualización común para Shotgun y Tee Times basada exclusivamente en la validación formal y snapshots congelados. Replica la numeración/folio de `emitir_tarjetas_score_ronda` sin crear emisiones, tarjetas, QR ni captura digital. |
| 186 Fase 1A | `186_FASE1A_CLASIFICACIONES_COMPETITIVAS_STABLEFORD.sql` | Inicia la base configurable de Stableford sin tocar scoring: crea clasificaciones oficiales Gross/Net por categoría, preserva Gross+Net como default para categorías existentes no congeladas y nuevas, bloquea cambios tras el freeze y congela una fotografía estructurada por categoría dentro del mismo proceso de congelamiento. |
| 186 Fase 1B | `186_FASE1B_STABLEFORD_MOTORES_SALIDA_COMUNES.sql` | Habilita Stableford Individual para Shotgun y Tee Times reutilizando los motores de preparación, handlers de validación, contrato común V2 y emisión oficial por inscripción. Generaliza únicamente guards que restringían las salidas a Stroke Play; todavía no agrega Pickup ni calcula puntos Stableford. |
| 186 Fase 1C | `186_FASE1C_CONTRATO_RESULTADO_HOYO_SCORE_PICKUP.sql` | Introduce el contrato universal de resultado de hoyo en digital, físico y resolución: PENDING/SCORE/PICKUP. Hace backfill retrocompatible de datos históricos, permite Gross nulo únicamente cuando el resultado es PICKUP y extiende eventos para auditar el tipo de resultado. Todavía no habilita captura de PU desde las RPC. |
| 186 Fase 1D | `186_FASE1D_CAPTURA_DIGITAL_SCORE_PICKUP.sql` | Habilita captura digital SCORE/PICKUP, mantiene wrappers históricos de SCORE, permite confirmar y disputar PU, restringe PICKUP a Stableford y cambia completitud/conteos para usar result_type en lugar de gross no nulo. |

### Migración 185 Fase 1H — Previsualización oficial de tarjetas antes de emisión

- Agrega `previsualizar_tarjetas_score_ronda(uuid)` como preview común posterior a `VALIDAR Y CERRAR`.
- Funciona para motores registrados con `official_scorecard_registration_v1`, incluyendo Shotgun individual y Tee Times individual.
- Consume exclusivamente `tournament_round_start_validations`, sus grupos/unidades versionados y snapshots congelados de hándicap, tee, condiciones y hoyos.
- Replica exactamente el `ORDER BY` de `emitir_tarjetas_score_ronda(uuid)` para calcular `prospectiveCardNumber`.
- Calcula `prospectiveCardFolio` con el mismo formato oficial `Rxx-Vxx-xxxx`.
- No crea `tournament_score_card_emissions`, `tournament_score_cards`, QR, sesiones de captura ni scores.
- Cada tarjeta prevista incluye jugador, folio de inscripción, categoría, Handicap Index, Course Handicap, Playing Handicap, tee, salida, compañeros, hoyos, PAR, Stroke Index, distancias y totales.
- `officiallyIssued` permite distinguir si la ronda ya tiene una emisión activa.
- La emisión oficial y el payload posterior a emisión permanecen intactos.
- El preview legacy `obtener_preview_tarjetas_score_shotgun_individual(uuid)` permanece sin cambios porque pertenece a la etapa de preparación Shotgun, no a la preemisión oficial.

### Migración 186 Fase 1A — Clasificaciones competitivas por categoría y snapshot Stableford

- Crea `tournament_category_classifications` para definir por categoría las clasificaciones oficiales `gross`, `neto` o ambas.
- Preserva el comportamiento vigente: todas las categorías existentes de torneos no congelados reciben Gross + Neto y las categorías nuevas nacen con ambas por default; el organizador puede quitar una antes del freeze.
- Reutiliza `tipo_resultado_desempate` para mantener alineados ranking y reglas Gross/Net sin duplicar el dominio.
- Protege la configuración con el mismo candado de congelamiento usado por otras condiciones deportivas.
- Crea `tournament_category_classification_snapshots` como fotografía inmutable de categoría + clasificación.
- Extiende `previsualizar_congelamiento_torneo(uuid)` mediante wrapper para impedir el freeze si alguna categoría queda sin clasificación.
- Extiende `congelar_condiciones_y_handicaps_torneo(uuid)` mediante wrapper, preservando el core existente, para materializar los snapshots de clasificación en la misma transacción y agregar `categoryClassifications` al `conditions_snapshot`.
- Las clasificaciones se conservan en `tournament_category_classification_snapshots`; la fila principal de `tournament_condition_freezes` permanece inmutable y los freezes históricos no se modifican.
- No calcula puntos Stableford, no modifica tarjetas/captura/conciliación/resultados/leaderboard y no habilita aún Stableford en el registro de motores.

### Migración 186 Fase 1B — Stableford Individual en motores comunes de salida

- Registra `stableford + individual + shotgun` y `stableford + individual + tee_times` en `tournament_start_engine_registry`.
- Reutiliza `shotgun_v1`, `tee_times_v1`, los handlers comunes de validación y `official_scorecard_registration_v1`; no crea un pipeline paralelo.
- Generaliza los guards internos de Shotgun y Tee Times para aceptar `stroke` o `stableford` cuando la participación es individual.
- Los contratos de salida V2 reportan dinámicamente `stableford_individual_shotgun_v1` o `stableford_individual_tee_times_v1` según el snapshot congelado.
- Mantiene intactos los registros y comportamiento de Stroke Play.
- No modifica tarjetas, captura, conciliación, resultados, leaderboard, desempates ni cálculo de puntos.
- Pickup y el contrato universal de resultado de hoyo se implementan en una fase posterior.

### Migración 186 Fase 1C — Contrato universal de resultado de hoyo

- Agrega `result_type` (`PENDING`, `SCORE`, `PICKUP`) a la evidencia digital.
- Agrega `player_claimed_result_type` para que una disputa futura pueda reclamar SCORE o PICKUP.
- Agrega `physical_result_type` a la captura física y permite `physical_gross_score = NULL` sólo cuando el resultado es `PICKUP`.
- Agrega snapshots de tipo de resultado y `resolved_result_type` a la resolución de conciliación; `resolved_gross_score` puede ser `NULL` sólo para `PICKUP`.
- Extiende el esquema de eventos digitales, físicos y de conciliación para conservar el tipo de resultado además del Gross en eventos futuros; las bitácoras históricas permanecen intactas porque son append-only.
- Hace backfill retrocompatible únicamente sobre tablas de estado mutables: resultados históricos existentes permanecen `SCORE`; filas digitales pendientes quedan `PENDING`; no se inventa ningún PICKUP histórico ni se reescriben bitácoras.
- No habilita todavía captura de `PU` desde RPC/UI y no modifica cálculo de resultados ni leaderboard.

### Migración 186 Fase 1D — Captura digital SCORE/PICKUP

- Crea `registrar_resultado_hoyo(uuid, uuid, text, integer)` para registrar `SCORE` o `PICKUP`.
- `PICKUP` sólo puede registrarse si la validación congelada de la tarjeta tiene `scoring_engine = stableford`.
- Conserva `registrar_score_hoyo(...)` y `disputar_score_hoyo(...)` como wrappers compatibles con Stroke Play.
- `confirmar_score_hoyo(...)` confirma tanto `SCORE` como `PICKUP`.
- Crea `disputar_resultado_hoyo(...)` para reclamar un SCORE o PICKUP.
- La sesión queda `captured` cuando no quedan hoyos `PENDING`; PU cuenta como hoyo resuelto.
- Paneles y detalle de captura reconocen SCORE/PICKUP y los eventos nuevos registran tipos de resultado.
- No modifica todavía tarjeta física, conciliación ni cálculo de puntos Stableford.

### Migración 186 Fase 1E — Físico, conciliación y resolución SCORE/PICKUP

- Crea `guardar_resultado_fisico_hoyo(...)` para capturar `SCORE` o `PICKUP` desde tarjeta física.
- `PICKUP` físico sólo se admite en rondas Stableford; `guardar_score_fisico_hoyo(...)` se conserva como wrapper SCORE.
- La conciliación compara `result_type + gross`: `SCORE 5 ↔ SCORE 5` y `PICKUP ↔ PICKUP` coinciden; `SCORE ↔ PICKUP` requiere revisión.
- Crea `resolver_hoyo_conciliacion_resultado(...)` para resolver discrepancias a `SCORE` o `PICKUP`.
- `resolver_hoyo_conciliacion_score(...)` permanece como wrapper histórico.
- Los eventos físicos y de conciliación nuevos conservan tipos de resultado.
- La finalización de conciliación detecta falta física por ausencia de fila, no por Gross nulo, evitando confundir PICKUP con hoyo faltante.
- Las lecturas físicas y de resolución exponen los tipos de resultado.
- No calcula todavía puntos Stableford ni modifica resultados/leaderboard.

### Migración 186 Fase 1F — Corrección de inmutabilidad del freeze

- Corrige una incompatibilidad detectada en el wrapper creado en 186 Fase 1A: `tournament_condition_freezes` es inmutable y no puede recibir un `UPDATE` después de ser creado.
- Mantiene `tournament_category_classification_snapshots` como autoridad histórica estructurada de las clasificaciones Gross/Net congeladas.
- El wrapper de `congelar_condiciones_y_handicaps_torneo(uuid)` ya no modifica la fila principal del freeze después del core.
- Conserva la validación que revierte el congelamiento si el snapshot de clasificaciones queda incompleto.
- Agrega inmutabilidad a `tournament_category_classification_snapshots` mediante `impedir_mutacion_snapshot_torneo()`.
- No altera freezes históricos ni modifica scoring, tarjetas, conciliación o leaderboard.

### Migración 186 Fase 1G — Reglas especiales Stableford

- Crea `tournament_stableford_special_rules` para reglas especiales configurables por torneo.
- La primera regla soportada es `HOLE_IN_ONE_OVERRIDE`.
- La regla es opcional; si existe y está habilitada, sus puntos sustituyen el cálculo Stableford normal del hoyo.
- El valor de puntos es configurable por torneo; por ejemplo, el torneo puede declarar Hole in One = 5 puntos.
- Crea `tournament_stableford_special_rule_snapshots` y congela las reglas dentro de la misma transacción del freeze.
- Las reglas vivas quedan protegidas después del freeze y los snapshots son inmutables.
- No calcula todavía puntos Stableford; el motor consumirá exclusivamente el snapshot en la siguiente fase.

### Migración 186 Fase 1H — Motor Stableford Gross/Net por hoyo

- Crea `tournament_stableford_engine_snapshots` para congelar la versión `stableford_individual_v1`, la tabla `R21.1_STANDARD_V1`, target `PAR`, mínimo 0, máximo 6 y Pickup 0.
- Crea `calcular_puntos_stableford_estandar(score, target)` como función pura y topa la escala estándar en 6 puntos.
- Crea `obtener_resultado_oficial_universal_tarjeta(uuid)` como autoridad común de resultado oficial por hoyo: `SCORE` con Gross o `PICKUP` sin Gross.
- Stableford deja de depender de la RPC Stroke Play `obtener_score_oficial_tarjeta()`, que sigue intacta.
- Crea `obtener_resultado_stableford_oficial_tarjeta(uuid)` para calcular simultáneamente puntos Gross y Net por hoyo.
- En Net, primero distribuye el Playing Handicap congelado con `calcular_golpes_handicap_hoyo()` y después calcula los puntos.
- `PICKUP` siempre produce 0 puntos Gross y Net.
- Si el snapshot contiene `HOLE_IN_ONE_OVERRIDE`, un Gross oficial de 1 sustituye los puntos normales por el valor configurado, tanto Gross como Net.
- La respuesta incluye clasificaciones Gross/Net configuradas para la categoría, totales de puntos, detalle por hoyo y trazabilidad de la regla especial.
- No modifica todavía leaderboard, desempates, acumulación multirronda ni estados excepcionales DQ/WD/NS/DNF/NO CARD.

### Migración 186 Fase 1I — Resultados y leaderboard Stableford de ronda

- Crea `obtener_resultados_stableford_oficiales_ronda(uuid)` y reutiliza el motor oficial por tarjeta de 1H.
- Crea `obtener_leaderboard_stableford_ronda(uuid)` separado del leaderboard Stroke Play.
- Gross y Net se ordenan por puntos descendentes: más puntos = mejor posición.
- Cada categoría sólo participa en las clasificaciones Gross/Net congeladas que tenga habilitadas.
- `WD`, `DNF`, `DQ`, `DNS` y `NO_CARD` se conservan como outcomes terminales y no reciben ranking.
- Los empates se detectan y se marcan `READY_FOR_TIEBREAK`; esta fase no inventa ni aplica aún un criterio de desempate.
- No modifica las RPC históricas de resultados ni leaderboard Stroke Play.
- La acumulación multirronda y el desempate Stableford quedan para fases posteriores.

### Migración 186 Fase 1J — Desempates automáticos Stableford

- Reutiliza `tournament_tiebreak_rules`, `tiebreak_methods`, alcance y tipo de resultado; no crea un catálogo paralelo.
- Crea `calcular_clave_metodo_desempate_stableford(...)`, que trabaja con `grossPoints` o `netPoints`.
- En Stableford más puntos es mejor; las claves se normalizan para mantener comparación lexicográfica determinista.
- Para countback usa los hoyos del campo 10–18, 13–18, 16–18 y 18. Esto es consistente entre Tee Times y Shotgun y evita usar los últimos hoyos jugados por cada salida.
- `TARJETA_18` se conserva por compatibilidad de configuración, aunque normalmente no rompe un empate del total.
- `HOYO_POR_HOYO_HANDICAP` se conserva como método local configurable y compara puntos hoyo por hoyo según Stroke Index.
- `MUERTE_SUBITA` y `SORTEO` continúan siendo pasos manuales.
- Crea `evaluar_secuencia_desempate_stableford(...)` y `obtener_desempates_stableford_ronda(uuid)`.
- Sólo evalúa Gross/Net cuando esa clasificación está habilitada para la categoría.
- No modifica el motor de desempate Stroke Play.
- La persistencia de resoluciones manuales Stableford y su aplicación final al leaderboard quedan para la siguiente fase.

### Migración 186 Fase 1K — Resoluciones manuales y leaderboard final Stableford

- Crea `resolver_desempate_manual_stableford_ronda(...)`, validado contra `obtener_desempates_stableford_ronda()`.
- Reutiliza `tournament_tiebreak_resolutions`, `tournament_tiebreak_resolution_players` y `tournament_tiebreak_resolution_events`; no crea otra infraestructura de auditoría.
- Conserva los modos `CONFIGURED_MANUAL_METHOD` y `COMMITTEE_OVERRIDE`.
- La bitácora identifica la resolución como `scoringEngine = stableford` dentro del payload del evento.
- `anular_resolucion_desempate_manual(...)` y `obtener_resoluciones_desempate_ronda(...)` siguen siendo comunes para ambas modalidades.
- `obtener_leaderboard_stableford_ronda(...)` integra los desempates automáticos de 1J y las resoluciones manuales activas.
- Para cada clasificación devuelve `baseRank`, `finalRank`, estado del desempate, método aplicado y `resolutionId` cuando la resolución es manual.
- Un empate sin resolución mantiene el leaderboard en `READY_FOR_TIEBREAK`; sólo pasa a `READY_FOR_PUBLICATION` cuando no quedan jugadores pendientes ni empates pendientes.
- El resolver manual y el leaderboard Stroke Play permanecen intactos.
- La acumulación de varias rondas Stableford queda para una fase posterior.

### Migración 186 Fase 1L — Acumulación multirronda Stableford

- Crea `obtener_resultados_stableford_torneo(uuid)` y acumula por `tournament_registration_id`, que es la identidad estable entre rondas.
- Considera únicamente rondas congeladas con `scoring_engine = stableford` y `participation_type = individual`.
- Gross/Net se suman sólo cuando la inscripción tiene resultado oficial en todas las rondas Stableford requeridas.
- Los resultados parciales se conservan para diagnóstico, pero no generan un total oficial mientras falte una ronda.
- `WD`, `DNF`, `DQ`, `DNS` y `NO_CARD` permanecen como excepciones de la ronda; esta fase no les asigna automáticamente un efecto global de torneo.
- Crea `obtener_leaderboard_stableford_torneo(uuid)` con ranking por categoría y puntos descendentes.
- Detecta empates acumulados y deja el estado `READY_FOR_TIEBREAK`; no inventa todavía un criterio de desempate multirronda.
- Las RPC Stableford por ronda permanecen intactas.

### Migración 186 Fase 1M — Desempate automático multirronda Stableford

- Agrega `ULTIMA_RONDA` al catálogo común `tiebreak_methods`; no crea un catálogo paralelo.
- Crea `calcular_clave_metodo_desempate_stableford_multirronda(...)`.
- Para `ULTIMA_RONDA`, Gross compara puntos Gross de la última ronda y Net compara puntos Net de la última ronda; más puntos es mejor.
- Si la secuencia continúa con `TARJETA_ULTIMOS_9`, `TARJETA_ULTIMOS_6`, `TARJETA_ULTIMOS_3` o `TARJETA_ULTIMO_HOYO`, esos métodos se evalúan sobre los hoyos de la última ronda.
- Crea `evaluar_secuencia_desempate_stableford_multirronda(...)` y `obtener_desempates_stableford_torneo(uuid)`.
- Reutiliza `tournament_tiebreak_rules`, incluyendo precedencia por categoría/alcance y Gross/Net.
- `obtener_leaderboard_stableford_torneo(uuid)` aplica los desempates automáticos acumulados y devuelve `baseRank/finalRank`.
- Si la secuencia llega a un método manual o no rompe el empate, el leaderboard permanece `READY_FOR_TIEBREAK`.
- No implementa todavía persistencia de resolución manual multirronda.
- Los motores Stableford por ronda y Stroke Play permanecen intactos.

### Migración 186 Fase 1N — Resolución manual multirronda Stableford

- No reutiliza de forma forzada `tournament_tiebreak_resolutions`, porque esa infraestructura exige `tournament_round_id` y participantes por `score_card_id`.
- Crea infraestructura genérica de desempate acumulado de torneo: `tournament_aggregate_tiebreak_resolutions`, `tournament_aggregate_tiebreak_resolution_players` y `tournament_aggregate_tiebreak_resolution_events`.
- La identidad de participantes es `tournament_registration_id`, consistente con la acumulación multirronda de 1L.
- Las tablas nuevas tienen RLS; `anon` y `authenticated` no reciben acceso directo. La operación se realiza mediante RPC `SECURITY DEFINER`.
- La bitácora acumulada es append-only/inmutable.
- Crea `resolver_desempate_manual_stableford_torneo(...)`, validado contra `obtener_desempates_stableford_torneo(uuid)`.
- Conserva los modos `CONFIGURED_MANUAL_METHOD` y `COMMITTEE_OVERRIDE`.
- Crea `anular_resolucion_desempate_acumulado(...)` y `obtener_resoluciones_desempate_torneo(...)`.
- `obtener_leaderboard_stableford_torneo(uuid)` integra desempates automáticos de 1M y resoluciones manuales acumuladas activas, y devuelve `baseRank`, `finalRank`, método y `resolutionId`.
- El leaderboard sólo queda `READY_FOR_PUBLICATION` cuando no existen jugadores pendientes ni desempates acumulados pendientes.
- Las resoluciones manuales por ronda Stableford y toda la infraestructura Stroke Play permanecen intactas.
- La infraestructura acumulada es genérica mediante `scoring_engine`, por lo que puede reutilizarse posteriormente en otras modalidades multirronda.

### Migración 186 Fase 1O — Cierre competitivo de ronda agnóstico

- Corrige una dependencia circular potencial: `obtener_desempates_stableford_ronda()` ya no llama al leaderboard Stableford; el leaderboard puede consumir el motor de desempates sin recursión.
- `validar_cierre_resultados_ronda(uuid)` detecta `scoring_engine` y `participation_type` desde `tournament_round_condition_snapshots`.
- Para Stroke Play conserva `obtener_resultados_oficiales_ronda(uuid)`; para Stableford Individual usa `obtener_resultados_stableford_oficiales_ronda(uuid)`.
- `WD`, `DNF`, `DQ`, `DNS` y `NO_CARD` siguen resolviendo competitivamente una tarjeta para permitir el cierre de la ronda, sin alterar todavía su efecto global multirronda.
- `obtener_estado_cierre_competitivo_ronda(uuid)` selecciona también el motor de desempates correcto según scoring engine.
- La capa común normaliza `tiedTotal` de Stroke Play y `tiedPoints` de Stableford para reutilizar la misma infraestructura de cierre y resoluciones manuales.
- `cerrar_ronda_competitiva(uuid,text)` no se duplica: continúa consumiendo el estado competitivo común y sólo permite cerrar cuando tarjetas y desempates están resueltos.
- La finalización global del torneo todavía no cambia en esta fase; se abordará después de verificar 1O.

### Migración 186 Fase 1P — Finalización global Stableford

- Amplía `previsualizar_finalizacion_torneo(uuid)` a `schemaVersion = 2`.
- Conserva el requisito histórico de que todas las rondas activas estén cerradas competitivamente.
- Si todas las rondas activas congeladas son Stableford Individual, exige además que `obtener_leaderboard_stableford_torneo(uuid)` esté en `READY_FOR_PUBLICATION`.
- El preview incorpora `aggregateCompetition`, incluyendo el leaderboard acumulado que justificará la finalización; ese preview queda posteriormente dentro de `tournament_competitive_finalizations.finalization_snapshot`.
- `finalizar_torneo(uuid,text)` no se duplica ni reescribe: ya consume `readyToFinalize` del preview.
- Para torneos sin Stableford se conserva el comportamiento histórico: la finalización depende de los cierres competitivos de ronda.
- Si en el futuro existe una composición que mezcle Stableford con otro scoring engine o una participación Stableford no individual, el preview devuelve `UNSUPPORTED_TOURNAMENT_COMPOSITION` y no permite finalizar hasta diseñar explícitamente esa clasificación global.
- Los outcomes excepcionales de ronda todavía no reciben una política global automática. Si provocan que el acumulado sea provisional, Stableford no podrá finalizar hasta resolver esa política en una fase posterior.

## Cómo agregar una migración nueva

1. Diseñar el cambio (esquema, RLS, triggers).
2. Correrlo en el SQL Editor de Supabase (proyecto `GOLFING_FULL`), confirmar que no haya errores.
3. Subir el archivo `.sql` a este repositorio, dentro de `supabase/migrations/`, con el siguiente número consecutivo (ej. `007_clubs_y_tournaments.sql`).
4. Agregar una fila a la tabla de este README.

## Entidades pendientes (no construidas todavía)

- **PWA de captura de scores:** interfaz móvil que consuma las RPC de la Migración 146.
- **Notificación al dueño del score:** push/PWA/WhatsApp u otro canal para avisar que su marcador capturó un hoyo y solicitar confirmación.
- **Resultados oficiales:** físico 149-150, conciliación 151-152, GROSS 153, NETO 154, fuente masiva 155, outcomes/cierre 156-157, leaderboard 158, fix 159, motor automático de desempates 160 y persistencia de resolución manual 161. Pendiente: validar resolución/anulación manual e integrar el resultado final de desempates al leaderboard antes de premiación.
- **Motor de resultados:** Gross total, Net por hoyo/total, score vs PAR, clasificación, desempates y cortes.

- Inscripción por EQUIPOS — Fase 2: que el jugador cree su propio equipo y busque compañeros por apellido (necesita una función de búsqueda acotada por apellido, accesible para cualquier jugador, no solo administradores)
- Inscripción por EQUIPOS — Fase 3: que el jugador se una a un equipo incompleto ya existente (usa la vista `tournament_equipos_incompletos`, ya lista)
- Inscripción por EQUIPOS — Fase 4: pago de "equipo completo de una sola vez" con `tarifa_equipo_completo` — requiere que un solo pago genere varias inscripciones simultáneas, distinto al mecanismo actual de "un pago = una inscripción"
- Inscripción por EQUIPOS — Fase 5: correo de confirmación con el detalle completo del equipo
- Agregar el concepto `inscripcion_equipo` a `procesar_resultado_pago()` (relacionado con la Fase 4 de equipos)
- Recibo deducible — FASE 2: generación real de la factura fiscal, típicamente requiere integrarse con un PAC (Proveedor Autorizado de Certificación del SAT), y su envío automático al jugador. Hoy solo existe la solicitud + carga del PDF (Fase 1).
- Recordatorio para quien dijo "Sí" a recibo deducible pero no subió su constancia (`payment_attempts.solicito_recibo_deducible = true` sin fila correspondiente en `payment_fiscal_receipts`) — hoy solo existe el dato para detectarlo, no un correo/aviso automático.
- Corregir la pantalla "Mis Reservas Pendientes" (botón "Pagar ahora") para que también pregunte por recibo deducible cuando el torneo es de beneficencia — esa lógica parece que solo se construyó en la pantalla de inscripción individual directa
- Pantallas para configurar `categories.categoria_estandar_marca`, el override de hándicap por torneo (`tournament_categories`), y `tournament_franjas_handicap` (torneos de categoría única) — hoy solo existe la estructura y la lógica de asignación, falta la interfaz para capturarlos
- Pantalla para editar `tournaments.edad_senior_categoria_unica` por torneo — hoy la pantalla de "Franjas de hándicap (categoría única)" solo muestra el valor heredado del catálogo global (etiqueta "valor por defecto del catálogo"), sin control para que el organizador lo sobreescriba, a diferencia de las franjas de hándicap que sí son editables por torneo. Detectado durante las pruebas de asignación de marca de salida (prueba 3, agosto 2026).
- Propagar la asignación automática de marca de salida (091) también a `tournament_pre_reservations` — hoy solo se resolvió para `tournament_registrations`. **Confirmado con caso real (prueba 3f, agosto 2026):** una pre-reserva con hándicap fuera de rango de todas las franjas del torneo se crea sin problema; el rechazo ("no cae en ninguna franja definida para este torneo") solo aparece hasta el momento del pago, cuando `confirmar_pago_prereserva()` genera la inscripción real y ahí sí dispara `resolver_categoria_y_marca()`. Comportamiento esperado dado el diseño actual, no un bug — pero confirma que la validación llega tarde en el flujo de pre-reserva.
- Mostrarle al jugador, en pantalla, el aviso de "se te reasignó de categoría X a Y por tu hándicap" (`tournament_registrations.categoria_reasignada`) — hoy el dato ya se guarda, falta el aviso visual
- Validación proactiva de huecos en la configuración de categorías del torneo (pantalla de superadmin/organizador) — hoy solo se detecta el hueco hasta que un jugador con ese hándicap intenta inscribirse (migración 100); ayudaría avisar al organizador desde la propia pantalla de configuración, antes de que alguien lo descubra por error
- Decidir y construir si la tarifa de socios se extiende a TODO el equipo cuando un solo integrante es socio del club — no aplica en todos los torneos, depende del mecanismo de "pago de equipo completo" (Fase 4 de equipos, todavía no construida)
- Soporte de "clubes amigos" con tarifa recíproca de socios (más allá del propio club del jugador) — todavía no construido
- Integración real con la pasarela de pago (Edge Function que reciba la confirmación del banco y cree la fila en `tournament_registrations` vía service_role) — hoy la tabla existe, pero nada la conecta todavía con un banco real
- ⚠️ **CRÍTICO antes de producción:** eliminar (o inhabilitar por completo) la función `simular_resultado_pago()` (migración 052) — permite aprobar pagos sin banco real de por medio. Es intencional solo para pruebas.
- Pantalla/lógica de validación de QR (la página pública que escanea el club) — depende de `tournament_registrations.qr_token`, ya existe el dato pero no la pantalla
- Tarea programada que revise `tournament_registration_attempts` sin completar y dispare el correo de abandono
- Decidir si la marca de salida se asigna en el momento de la inscripción, o se resuelve después (hoy `tournament_registrations` no la captura)
- Notificación automática (SMS/WhatsApp) para avisarle a alguien pre-reservado por teléfono que debe entrar a confirmar — hoy no existe ninguna integración de mensajería, el aviso queda a criterio del organizador durante la misma llamada
- Integración real de WhatsApp para comunicación con jugadores — hoy solo existe el consentimiento (`players.acepta_whatsapp`), ninguna integración de mensajería construida todavía
- Decidir (con el asesor de golf) si conviene abrir la puerta a plantillas de desempate personalizadas por torneo, más allá de "R&A Oficial" y "Mexicano por Hándicap" — la estructura ya lo soportaría (`tournament_tiebreak_rules` permite armar una cadena a mano), falta decidir si construir la pantalla para eso
- Anulación automática de pre-reservas vencidas (`fecha_limite_pago` pasada sin pago) — hoy no existe ninguna tarea programada que lo haga; se decidirá si se construye junto con el correo de confirmación de pre-reserva
- Decidir qué pasa con una pre-reserva de transferencia que pasa su `fecha_limite_pago` sin confirmarse — ¿se cancela sola (tarea programada) o alguien la revisa manualmente?
- Selector de ciudades + listado de torneos por ciudad (pantalla de jugador, antes de inscribirse) — no construido todavía
- Sistema de QR de acceso al club/campo: respaldo de búsqueda manual por nombre para quien no tenga el QR a la mano — pendiente de decidir
- Evaluar si al EDITAR (no crear) una regla de corte conviene pedir un motivo del cambio, además de lo que ya registra `audit_log` automáticamente — sin urgencia, decidir más adelante
- Ciclo de vida deportivo — **Fase 1 construida en 181**: abrir/cerrar/reabrir inscripciones mediante RPCs controladas; la reapertura queda bloqueada después del freeze; `INICIAR TORNEO` cambia manualmente `inscripcion_cerrada → en_curso` sólo si la primera ronda está totalmente preparada. Pendiente: cablear Lovable a estas RPCs, bloquear luego los `UPDATE` directos a `tournaments.estatus`, y diseñar `FINALIZAR TORNEO` una vez definido el cierre oficial de la última ronda.
- Motor de cálculo de resultados (Course Handicap → Playing Handicap → score neto → aplicar cortes → aplicar desempates encadenados) — hoy solo existe la estructura de datos/reglas, no la lógica de cálculo
- Definir los "motores" (`scoring_engine`) de cada modalidad en `tournament_formats` — hoy solo existe la estructura
- Después de la migración 030, hay que volver a dar de alta el torneo de prueba (se borró) y reasignar a Pedro Pérez como organizador si se sigue necesitando
- Revisar si `tournaments.duracion_dias` (calculado de fecha_inicio/fecha_fin) sigue teniendo sentido ahora que `tournament_rounds` es la fuente real de cuántos días se juega — podría quedar como dato informativo nada más
- Tabla de contactos por área de cada campo de golf (Pro Shop, Starter, Renta de Carritos, Taller, Servicio en Campo/Alimentos y Bebidas) — fase futura, aparte de `campos_golf`
- Decidir si `tournaments.club_id` debe cambiar a `campo_golf_id` — RESUELTO por el diseño de rondas (migración 032): cada `tournament_rounds` ya tiene su propio `campo_golf_id`; `tournaments.club_id` se queda como el club anfitrión/responsable administrativo
- Soporte de "nueves combinables" (A/B/C) para campos de 27+ hoyos — hoy `hoyos` asume numeración simple 1..N
- Registro de jugadores por parte del organizador (Fase 2) y autoregistro del jugador (Fase 3) — la migración 020 ya deja lista la vinculación automática entre ambos flujos
- Frontend de licencias de módulos (`club_module_licenses`) — la estructura ya existe (migración 017), falta la pantalla
- Dashboard completo para el rol `club_admin` (login, layout, navegación) — hoy solo existe el de superadmin
- Regla de RLS adicional en `players` para exponer nombre/hándicap de jugadores inscritos en un torneo específico, de cara al público (se agregará junto con `tournament_registrations`)
- Migrar la sincronización de correo jugador↔auth (105) a un flujo con confirmación real antes de operar con jugadores reales — hoy actualiza `auth.users.email` directo por SQL cuando cambia `players.email`, sin pedir confirmación al nuevo correo (aceptable solo mientras el superadmin es quien edita el catálogo en pruebas). Evaluar Edge Function + Admin API de Supabase para el cambio de correo real, con confirmación al nuevo email antes de aplicarse.
- Motor de preparación de salidas **Shotgun** — desarrollo por fases. **Fase 1 construida en 129:** asignación de categorías completas a turnos de cada ronda; turno único = asignación automática de todas las categorías, varios turnos = distribución manual. **Fase 2 construida en 130:** configuración Shotgun por categoría dentro del turno (tamaño normal, máximo excepcional y desfase B) y selección manual de hoyos por categoría; cada hoyo puede aportar A o A/B según decisión del organizador y un mismo hoyo no puede mezclarse entre categorías dentro del turno. **Fase 3A construida en 131:** adaptación estructural de `tournament_groups` con vínculo al hoyo Shotgun configurado y posición A/B, más `tournament_group_teams` para uno o varios equipos completos por grupo, preservando campos legacy y haciendo backfill de equipos históricos. Pendientes: adaptar los triggers de negocio al nuevo modelo; retirar para Shotgun la restricción histórica de doble salida únicamente en Par 4/5; usar el máximo por categoría en grupos individuales; validar equipo único por ronda desde `tournament_group_teams`; cálculo/propuesta equilibrada de grupos; acomodos manuales y asignación aleatoria de pendientes; movimientos posteriores; validación integral antes de generar tarjetas. Regla acordada: individual mide capacidad del grupo en jugadores; equipos la mide en equipos y cada equipo es indivisible. La salida se prepara por turno y por categoría, no directamente por ronda.
- Eliminar la función huérfana `validar_cupo_categoria()` (sin `cruzado`) — no tiene ningún trigger enganchado (confirmado revisando `pg_trigger`), quedó reemplazada por `validar_cupo_categoria_cruzado()` (089) pero nunca se borró. No representa riesgo funcional, solo confusión para quien revise el catálogo de funciones. Detectado durante la prueba 4 (cupos), agosto 2026.
- Agregar más ciudades a `cities` conforme se registren clubes en localidades nuevas (vía dashboard de superadmin)
- Configurar SMTP personalizado en Supabase (Authentication → SMTP Settings) antes de lanzar con jugadores reales — el correo interno de Supabase tiene un límite de envíos muy bajo, solo sirve para pruebas
