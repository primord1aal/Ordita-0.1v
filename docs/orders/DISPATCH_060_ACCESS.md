# Точный допуск исполнителя диспетчеризации 0.6.0

Разрешённый SQL остаётся неизменным: `supabase/proposals/20261120160748_taxi_dispatch.sql`, SHA-256 `3535ec29bac1827006e7d1803be5b72d408a72bb5623bbd24c9155a49813cafb`. Цель только `orbita-mobile-test`, Ref `fjqghohhohgvwlmefdmo`.

## Что уже проверено

Финальная read-only проверка проекта подтвердила: `transaction_read_only=on`, две записи истории `202611050001` / `20261112172442` с прежними SHA-256, исходные ограничения и права RPC, ноль заказов, отсутствие объектов диспетчеризации. Старый проект не запрашивался.

Новый отдельный исполнитель `tools/dispatch_migration/` не меняет старые миграции или исполнители. Workflow `.github/workflows/orbita-dispatch-migration.yml`: push запускает только изолированные проверки; облачные действия — только manual dispatch, первый attempt, точная ветка и SHA, защищённый Environment и фактическое одобрение владельца.

Preview создаёт ограниченный логический dump схем `auth`, `public`, `orbita_mobile_private`, `supabase_migrations`, шифрует AES-256 существующей защищённой парольной фразой, проверяет расшифровку/контрольные суммы, восстанавливает копию с ACL и служебным RLS-триггером в собственном Docker `--network none`. Проверяется совпадение каталога, строк/последовательностей/истории, затем репетируется только третья миграция. Это не полная копия файлов Storage или настроек всего Supabase.

Apply требует успешный Preview того же коммита и хеш сохранённого зашифрованного artifact. Повтор Apply блокируется. Ограниченная транзакция сверяет исходное состояние под блокировками, исполняет точные байты SQL, добавляет только третью запись истории и проверяет права/каталог, неизменность Auth и прежних строк заказов до COMMIT. При ошибке сохраняется только read-only диагностика; повторов/reset/repair нет.

После Apply исполнитель входит через обычный Auth в два заданных тестовых аккаунта, проверяет реальные серверные роли и HTTP 403 при чужой роли, создаёт и принимает вымышленный заказ, завершает его штатными переходами и выключает водителя с линии. Существующие аккаунты и роли не создаются и не изменяются. Остаётся завершённая тестовая поездка для проверки. Сырые ответы, адреса аккаунтов, пароли и токены в публичный отчёт не попадают.

## Изменения настройки, требующие отдельного согласования владельца

Текущий Environment [orbita-mobile-test-orders-migrations](https://github.com/primord1aal/Ordita-0.1v/settings/environments) разрешает ровно `codex/orbita-flutter-design-integration`. Для нового исполнителя требуется **заменить** единственную разрешённую ветку на `codex/orbita-e2e-test-060`, сохранив обязательного reviewer `primord1aal` и `can_admins_bypass=false`. Wildcard, разрешение всех веток и обход reviewer не нужны.

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

API текущего рабочего окружения позволяет прочитать защиты Environment, но возвращает HTTP 403 при чтении Secrets/Variables. Их наличие/значения не объявляются подтверждёнными. До согласования и настройки нового допуска Preview/backup/Apply не запускались. Никаких попыток обхода через прямой SQL или Supabase Editor не было.

APK **0.6.0+12 от `d0cf7645f9083f5b1ba428131515cd916d84d3d7` сохраняется**. Изменений клиента и новой сборки нет; новый исполнитель проверяет тот же `contract_version=2`.
