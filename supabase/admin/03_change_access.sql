-- Одна операция над одним точным UUID в одной транзакции, только доверенный SQL Editor.
-- p_action: assign / revoke / block / unblock.
-- p_role: passenger / driver / admin только для assign; иначе NULL.
-- p_confirm_loss: false по умолчанию; true только после проверки опасной операции.
-- Последнего действующего администратора нельзя отключить даже с true.
begin;
select orbita_mobile_private.admin_access(
  p_target => '<UUID_ЦЕЛЕВОГО_ПОЛЬЗОВАТЕЛЯ>'::uuid,
  p_action => 'assign',
  p_role => 'passenger',
  p_operator => '<UUID_ОПЕРАТОРА_УКАЗАН_ВРУЧНУЮ>'::uuid,
  p_reason => 'Назначение роли вымышленному тестовому аккаунту',
  p_confirm_loss => false
);
commit;
