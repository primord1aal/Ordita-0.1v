# Орбита: продолжение работ над MVP

Контрольная точка 24 ноября 2026 года. Рабочая ветка `codex/orbita-e2e-test-060`, тестовый проект `orbita-mobile-test`, Ref `fjqghohhohgvwlmefdmo`. Актуальный ход работ хранится на листе «Работа над MVP» в [ревизии Excel](audits/Orbita_audit_2026-11-24.xlsx).

## Серверный допуск

Обе существующие точные ветки Environment сохранены. Dispatch и Maps дополнительно требуют `codex/orbita-e2e-test-060`, согласованный SHA, положительные флаги и одобрение `primord1aal` для конкретного запуска. `main` менять для ручного запуска через CLI не потребовалось.

В [первой попытке Preview](https://github.com/primord1aal/Ordita-0.1v/actions/runs/45268820186) прошёл Verify, а шаги `entry` и `guarded` были пропущены. Причина — отсутствовал положительный флаг `ORBITA_DISPATCH_REPO_ENABLED`. Следующая версия workflow сообщает об этом явно. API этой интеграции вернул HTTP 403 при чтении Repository и Environment Variables.

Для продолжения владелец включает Repository Variable `ORBITA_DISPATCH_REPO_ENABLED=true` и выставляет только в `orbita-mobile-test-orders-migrations` значения `ORBITA_DISPATCH_CLOUD_ENABLED=true`, `ORBITA_DISPATCH_ALLOWED_SHA` равным текущему SHA рабочей ветки и `ORBITA_DISPATCH_ALLOWED_OPERATION=preview`. После этого выполнить [защищённый Preview](orders/DISPATCH_060_ACCESS.md) и получить штатное одобрение Environment. Признаки завершения — успешный `guarded`, отчёт `preview.json` и зашифрованный архив с подтверждённым восстановлением. Для отдельно согласуемого Apply нужен Preview того же SHA, поэтому после запуска сохраните вершину ветки до решения по применению.

В тестовой базе две прежние миграции, Dispatch и квота Maps ещё не применены. `orbita-maps` не развёрнута. `pg_cron` 1.6.4 доступен и не установлен. SQL для панели и автономных сроков подготовлен локально под отдельные допуски после фиксированных миграций Dispatch и Maps.

## Проверки и среда

- [Тестовый Android 0.6.2+14](ORBITA_0.6.2.md), [шлюз карт и план запуска](orders/DISPATCH_060_ACCESS.md), [диспетчерская](orders/ADMIN_READ_TEST.md), [автономные сроки](orders/DISPATCH_AUTONOMY.md), [телефонный вход и пилот в РФ](OTP_RU_READINESS.md).
- В [GitHub CI для 0.6.2](https://github.com/primord1aal/Ordita-0.1v/actions/runs/45272297923) прошли 463 Flutter-теста, 43 SQL-сценария, 11 тестов шлюза и 4 проверки клиента панели. Android unit tests и lint завершены. [Тестовый ARM64 debug APK 0.6.2+14](https://github.com/primord1aal/Ordita-0.1v/actions/runs/45272297923/artifacts/14865153370) собран на `fedf60012ed0ff5f5e00b2486bf13b4ffa4050f2`. Архив хранится до 8 декабря 2026 года 04:51 по Новосибирску. Первый сквозной заказ на телефонах требует серверных допусков и отдельной физической проверки.
- Фактическая политика терминала при ревизии — `workspace-write`, запись в `/workspace` и `/tmp` разрешена. Обычный HTTPS из терминала вернул `000`, локальный bind для тестового сервера — `EPERM`. GitHub-интеграция читает и публикует код независимо от этого ограничения. Ошибку самого приложения, связь с которой объясняла бы запросы доступа, не подтвердили.
