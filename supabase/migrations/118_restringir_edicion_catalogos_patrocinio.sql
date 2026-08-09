-- 118_restringir_edicion_catalogos_patrocinio.sql
--
-- Ajuste de permisos pedido por el usuario: cualquier admin activo puede seguir
-- AGREGANDO entradas nuevas a los catálogos compartidos (tipos_apoyo_patrocinio,
-- derechos_patrocinador) — así es como se pensó que crecieran, según lo que cada
-- organizador vaya necesitando. Pero EDITAR una entrada ya existente (que afecta a
-- todos los que la usan, por ser catálogo compartido) queda restringido solo a
-- superadmin, para tener control sobre cambios que podrían impactar a otros
-- organizadores.
--
-- La política anterior (115) usaba "for all" con el mismo criterio para
-- insert/update/delete — se reemplaza por políticas separadas por operación.

drop policy tipos_apoyo_patrocinio_write on tipos_apoyo_patrocinio;
drop policy derechos_patrocinador_write on derechos_patrocinador;

-- tipos_apoyo_patrocinio
create policy tipos_apoyo_patrocinio_insert on tipos_apoyo_patrocinio
  for insert with check (is_active_admin(auth.uid()));

create policy tipos_apoyo_patrocinio_update on tipos_apoyo_patrocinio
  for update using (is_superadmin(auth.uid())) with check (is_superadmin(auth.uid()));

create policy tipos_apoyo_patrocinio_delete on tipos_apoyo_patrocinio
  for delete using (is_superadmin(auth.uid()));

-- derechos_patrocinador
create policy derechos_patrocinador_insert on derechos_patrocinador
  for insert with check (is_active_admin(auth.uid()));

create policy derechos_patrocinador_update on derechos_patrocinador
  for update using (is_superadmin(auth.uid())) with check (is_superadmin(auth.uid()));

create policy derechos_patrocinador_delete on derechos_patrocinador
  for delete using (is_superadmin(auth.uid()));
