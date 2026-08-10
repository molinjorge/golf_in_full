-- 126_precaptura_propia_para_registro.sql
--
-- Mejora detectada al probar el flujo de cortesías ligeras: cuando alguien con una
-- intención de cortesía pendiente (nombres/apellidos capturados por el organizador,
-- sin player_id todavía) completa su propio registro en la PWA, el formulario no
-- mostraba esos datos ya capturados — el jugador tenía que volver a escribirlos desde
-- cero, aunque ya existían en patrocinador_jugadores_cortesia.
--
-- Nueva función: el propio jugador autenticado (auth.uid()) puede consultar SUS
-- PROPIOS datos precapturados — resuelto internamente por su correo real de auth,
-- nunca por un parámetro que el cliente pudiera manipular para ver datos de otra
-- persona. Los campos deben quedar EDITABLES en el formulario (el jugador puede
-- corregirlos), solo se usan como valor inicial sugerido.

create or replace function obtener_precaptura_propia()
returns table(nombres text, apellidos text)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_email text;
begin
  select email into v_email from auth.users where id = auth.uid();

  if v_email is null then
    return;
  end if;

  return query
    select c.nombres, c.apellidos
      from patrocinador_jugadores_cortesia c
     where c.correo = v_email
       and c.player_id is null
       and c.activo = true
     limit 1;
end;
$$;
