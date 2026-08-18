# MIGRACIÓN 139 — VISIBILIDAD DE RONDAS INACTIVAS

## Estado

**Preparada para ejecución manual en Supabase.** No debe marcarse como aplicada hasta ejecutar también el verificador posterior y obtener `5 verificaciones; 0 error(es)`.

La Migración 138 ya fue aplicada y verificada correctamente en Supabase (`14 verificaciones; 0 error(es)`).

## Archivos

- `139_visibilidad_rondas_inactivas.sql`: migración con escritura de esquema; reemplaza una policy SELECT y agrega otra.
- `SUPABASE-VERIFICAR-VISIBILIDAD-RONDAS-INACTIVAS.sql`: diagnóstico posterior de sólo lectura; no modifica datos ni esquema.

## Problema que resuelve

La RPC `crear_o_reactivar_siguiente_ronda()` de la Migración 138 puede reactivar una ronda existente, pero la policy histórica de `tournament_rounds` sólo permitía a organizadores y administradores de club consultar rondas activas. Por ello Lovable no podía detectar ni presentar una ronda inactiva que debía reutilizarse.

## Cambio aplicado

La policy SELECT se divide en dos políticas permisivas:

| Sesión | Rondas activas | Rondas inactivas |
|---|---:|---:|
| Visitante anónimo | Sí | No |
| Usuario autenticado sin administración del torneo | Sí | No |
| Superadministrador | Sí | Sí |
| Organizador del torneo | Sí | Sí |
| Administrador del club anfitrión | Sí | Sí |

- `tournament_rounds_select` conserva la lectura pública, pero únicamente cuando `activo = true`.
- `tournament_rounds_select_inactive_admin` permite a usuarios `authenticated` autorizados consultar también las rondas inactivas.
- La autorización administrativa reutiliza `puede_administrar_congelamiento_torneo(tournament_id)`, helper `SECURITY DEFINER` creado y protegido en la Migración 136.

## Lo que no cambia

- No modifica ninguna fila de datos.
- No modifica `tournament_rounds_write`.
- No cambia la secuencia obligatoria `1..N` establecida por la Migración 138.
- No permite crear rondas por encima de `tournaments.numero_rondas`.
- No permite saltar una ronda inactiva para crear otra posterior.
- No permite modificar rondas ni condiciones deportivas después del congelamiento.
- No expone rondas inactivas a jugadores, visitantes ni usuarios autenticados ajenos a la administración del torneo.

## Orden de ejecución

1. Abrir el SQL Editor del proyecto correcto en Supabase.
2. Ejecutar completo `139_visibilidad_rondas_inactivas.sql`.
3. Confirmar que termina sin error.
4. Ejecutar completo `SUPABASE-VERIFICAR-VISIBILIDAD-RONDAS-INACTIVAS.sql`.
5. Compartir el resultado antes de adaptar Lovable.

## Resultado esperado del verificador

Debe devolver estas secciones en `OK`:

- `01_RLS`: RLS continúa habilitado en `tournament_rounds`.
- `02_POLITICA_PUBLICA`: la lectura pública sólo usa `activo = true`.
- `03_POLITICA_ADMINISTRATIVA`: la policy adicional pertenece a `authenticated` y usa el helper administrativo.
- `04_HELPER_SEGURIDAD`: el helper es `SECURITY DEFINER`, ejecutable por `authenticated` y no por `anon`.
- `05_ESCRITURA_EXISTENTE`: `tournament_rounds_write` sigue presente y sin sustitución.
- `99_RESUMEN`: `5 verificaciones; 0 error(es)`.

## Siguiente fase en Lovable

Después de validar la Migración 139, la pantalla de rondas deberá:

- consultar rondas activas e inactivas del torneo;
- determinar el primer número activo faltante;
- mostrar `REACTIVAR RONDA N` cuando ya exista la fila inactiva correspondiente;
- mostrar `NUEVA RONDA N` únicamente cuando esa fila todavía no exista;
- llamar siempre a `crear_o_reactivar_siguiente_ronda()` para ambos casos, sin hacer `INSERT` directo;
- deshabilitar la creación cuando todas las rondas declaradas estén activas o cuando el torneo esté congelado;
- mostrar íntegros los errores de Supabase y volver a consultar el estado real después de cada operación.

Lovable no deberá generar ni ejecutar migraciones para esta fase.
