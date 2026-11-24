# Точный допуск исполнителя диспетчеризации 0.6.0

Разрешённый SQL остаётся неизменным: `supabase/proposals/20261120160748_taxi_dispatch.sql`, SHA-256 `3535ec29bac1827006e7d1803be5b72d408a72bb5623bbd24c9155a49813cafb`. Цель только `orbita-mobile-test`, Ref `fjqghohhohgvwlmefdmo`.

## Что уже проверено

Финальная read-only проверка проекта подтвердила: `transaction_read_only=on`, две записи истории `202611050001` / `20261112172442` с прежними SHA-256, исходные ограничения и права RPC, ноль заказов, отсутствие объектов диспетчеризации. Старый проект не запрашивался.

Новый отдельный исполнитель `tools/dispatch_migration/` не меняет старые миграции или исполнители. Workflow `.github/workflows/orbita-dispatch-migration.yml`: push запускает только изолированные проверки; облачные действия — только manual dispatch, первый attempt, точная ветка и SHA, защищённый Environment и фактическое одобрение владельца.

Preview создаёт ограниченный логический dump схем `auth`, `public`, `orbita_mobile_private`, `supabase_migrations`, шифрует AES-256 существующей защищённой парольной фразой, проверяет расшифровку/контрольные суммы, восстанавливает копию с ACL и служебным RLS-триггером в собственном Docker `--network none`. Проверяется совпадение каталога, строк/последовательностей/истории, затем репетируется только третья миграция. Это не полная копия файлов Storage или настроек всего Supabase.

Apply требует успешный Preview того же коммита и хеш сохранённого зашифрованного artifact. Повтор Apply блокируется. Ограниченная транзакция сверяет исходное состояние под блокировками, исполняет точные байты SQL, добавляет только третью запись истории и проверяет права/каталог, неизменность Auth и прежних строк заказов до COMMIT. При ошибке сохраняется только read-only диагностика; повторов/reset/repair нет.

После Apply исполнитель входит через обычный Auth в два заданных тестовых аккаунта, проверяет реальные серверные роли и HTTP 403 при чужой роли, создаёт и принимает вымышленный заказ, завершает его штатными переходами и выключает водителя с линии. Существующие аккаунты и роли не создаются и не изменяются. Остаётся завершённая тестовая поездка для проверки. Сырые ответы, адреса аккаунтов, пароли и токены в публичный отчёт не попадают.

## Изменения настройки, требующие отдельного согласования владельца

Environment [orbita-mobile-test-orders-migrations](https://github.com/primord1aal/Ordita-0.1v/settings/environments) сохраняет два точных правила `branch`: для `codex/orbita-e2e-test-060` и исторической `codex/orbita-flutter-design-integration`. Новые исполнители сверяют весь этот список; запустить Dispatch или Maps из старой ветки нельзя, потому что вход дополнительно требует `refs/heads/codex/orbita-e2e-test-060` и согласованный SHA. Обязательный reviewer `primord1aal`, его фактическое одобрение конкретного запуска и `can_admins_bypass=false` обязательны.

Ручной запуск выполняется через `gh workflow run orbita-dispatch-migration.yml --ref codex/orbita-e2e-test-060`. GitHub принял `verify` с этой ветки как запуск [45262315707](https://github.com/primord1aal/Ordita-0.1v/actions/runs/45262315707). Этот режим запускает только изолированные проверки. Для Preview дополнительно передать `-f operation=preview -f approved_sha=<SHA> -f project_ref=fjqghohhohgvwlmefdmo` после настройки допуска ниже и дождаться штатного одобрения Environment.

Repository Variable:

- `ORBITA_DISPATCH_REPO_ENABLED=true`.

Variables только внутри указанного Environment:

- `ORBITA_DISPATCH_CLOUD_ENABLED=true`.
- `ORBITA_DISPATCH_ALLOWED_SHA=<полный SHA коммита этого исполнителя>`.
- `ORBITA_DISPATCH_ALLOWED_OPERATION=preview`, после успешного Preview — `apply`; по завершении `ORBITA_DISPATCH_CLOUD_ENABLED=false`. Для отдельно разрешённой диагностики — `inspect`.

Новые Environment Secrets для двух **существующих свободных тестовых аккаунтов**:

- `ORBITA_DISPATCH_PASSENGER_EMAIL`, `ORBITA_DISPATCH_PASSENGER_PASSWORD`.
- `ORBITA_DISPATCH_DRIVER_EMAIL`, `ORBITA_DISPATCH_DRIVER_PASSWORD`.

Ввод значений только через защищённые настройки GitHub, не в чат. Старые `ORBITA_TEST_DB_PASSWORD`, `ORBITA_ORDERS_BACKUP_PASSPHRASE`, `ORBITA_TEST_DB_CA_PEM`, тестовые URL/publishable key/Refs используются без смены значений. Значения старого допуска `ORBITA_ORDERS_*` не меняются.

API текущего рабочего окружения возвращает HTTP 403 для Repository/Environment Variables. В [первом ручном запуске Preview](https://github.com/primord1aal/Ordita-0.1v/actions/runs/45268820186) прошёл Verify, но отсутствовал положительный Repository-флаг: `entry` и `guarded` пропущены. В обновлённом workflow отсутствие флага приводит к явной ошибке в `entry`, до Environment и доступа к БД. Успешный Preview должен содержать успешный `guarded` и оба артефакта `ORBITA-dispatch-preview-<run>` и `ORBITA-dispatch-backup-<run>`.

APK **0.6.0+12 от `d0cf7645f9083f5b1ba428131515cd916d84d3d7` сохраняется**. Изменений клиента и новой сборки нет; новый исполнитель проверяет тот же `contract_version=2`.

## Восстановление после Apply 45287941746

[Запуск №45287941746](https://github.com/primord1aal/Ordita-0.1v/actions/runs/45287941746) остановился до записи SQL. Все четыре секрета тестовых аккаунтов дошли до шага пустыми. Проверка в транзакции только для чтения подтвердила две исходные миграции, ноль заказов и совпадение отпечатка состояния с [Preview №45277234994](https://github.com/primord1aal/Ordita-0.1v/actions/runs/45277234994).

Новый допуск использует `recovery_run_id=45287941746` в обоих ручных запусках. Он сверяет историю GitHub, одобрение владельца, задания, сохранённый журнал сбоя и отсутствие отчётов о записи, затем проверяет исходный отпечаток базы. Другая предыдущая попытка Apply закрывает допуск. Для восстановления нужен новый проверенный SHA, успешный Preview этого SHA и хеш нового зашифрованного бэкапа. Каждый облачный запуск требует отдельного одобрения прежнего Environment.

1. Для восстановления выставить в Environment точный новый SHA, `ORBITA_DISPATCH_ALLOWED_OPERATION=preview` и выполнить Dispatch Preview с `recovery_run_id=45287941746`. После подтверждения исходного состояния этот запуск проверяет реальный вход пассажира и водителя и закрывает только созданные им сессии. Успешный отчёт содержит `settings_preflight=passed`, результаты проверки входа, привязку к инциденту и хеш бэкапа.
2. После отдельного разрешения на Apply изменить разрешённую операцию на `apply`, передать тот же SHA и номер инцидента, новый `preview_run_id` и `backup_sha256`. Проверить `apply.json`, `server-test.json` и третью запись истории.
3. Для Maps повторить Preview и отдельный Apply квоты `20261120173504`. После отдельного разрешения опубликовать `orbita-maps` и проверить тайлы, поиск, обратное геокодирование, маршрут и квоту.

### Настройки перед Preview

| Где | Что проверяется |
| --- | --- |
| GitHub Repository Variable | `ORBITA_DISPATCH_REPO_ENABLED=true`. |
| GitHub Environment Variables | `ORBITA_DISPATCH_CLOUD_ENABLED=true`, `ORBITA_DISPATCH_ALLOWED_SHA` равен SHA запуска, `ORBITA_DISPATCH_ALLOWED_OPERATION` равен операции. |
| GitHub Variables, используемые защищёнными заданиями | `SUPABASE_TEST_PROJECT_REF=fjqghohhohgvwlmefdmo`, `SUPABASE_FORBIDDEN_PROJECT_REF=swrvjwlwxeaecdhnzkjv`, действительный PEM в `ORBITA_TEST_DB_CA_PEM`. Dispatch также проверяет формат `SUPABASE_TEST_PUBLISHABLE_KEY`. |
| GitHub Secrets, используемые защищёнными заданиями | `ORBITA_TEST_DB_PASSWORD` для подключения. Для обоих Preview также `ORBITA_ORDERS_BACKUP_PASSPHRASE` длиной от 24 символов, отличная от пароля БД. |
| GitHub Environment Secrets для Dispatch | `ORBITA_DISPATCH_PASSENGER_EMAIL`, `ORBITA_DISPATCH_PASSENGER_PASSWORD`, `ORBITA_DISPATCH_DRIVER_EMAIL`, `ORBITA_DISPATCH_DRIVER_PASSWORD`. Preview проверяет заполненность и разные адреса. В режиме восстановления Preview также проверяет реальный вход и роли. Apply проверяет серверную поездку. |
| Supabase Edge Functions для Maps | `GEOAPIFY_SERVER_KEY` в Edge Function Secrets тестового проекта и встроенный `SUPABASE_SERVICE_ROLE_KEY` в среде функции. До публикации нужны три точные записи Dispatch и успешно применённая квота Maps. Фактическая проверка Geoapify идёт через опубликованную функцию. |

Проверка настроек защищённых заданий выводит имена проблемных полей. В режиме восстановления Preview сверяет статус сессий, данные аккаунтов и состояние приложения после входа и выхода. Supabase может сохранить штатные метки последнего входа и аудит. Новый бэкап создаётся после этой проверки. При неопределённом результате входа, выхода или сверки требуется расследование состояния, прежде чем повторять проверку пароля.
