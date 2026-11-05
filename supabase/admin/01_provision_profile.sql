-- Шаблон для SQL Editor после отдельного разрешения. UUID-заглушки не выполняются.
-- Пользователь Auth уже создан владельцем; профиль создаётся БЕЗ роли.
begin;
select orbita_mobile_private.admin_access(
  p_target => '<UUID_ПОЛЬЗОВАТЕЛЯ_AUTH>'::uuid,
  p_action => 'provision',
  p_operator => null, -- Если указываете UUID, это сведения оператора, не подтверждённая личность.
  p_reason => 'Создание вымышленного тестового профиля',
  p_display_name => 'Тестовый пользователь'
);
commit;
