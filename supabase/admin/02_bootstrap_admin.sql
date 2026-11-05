-- Только отдельное доверенное первоначальное назначение/восстановление при нуле администраторов.
-- Сначала проверить Dashboard, точный проект, UUID и существование профиля.
begin;
select orbita_mobile_private.admin_access(
  p_target => '<UUID_ПЕРВОГО_АДМИНИСТРАТОРА>'::uuid,
  p_action => 'bootstrap',
  p_role => 'admin',
  p_operator => null,
  p_reason => 'Первоначальное доверенное назначение администратора',
  p_confirm_loss => true -- Явное подтверждение именно bootstrap, обычный assign его не заменяет.
);
commit;
