# Подготовка доступа для актуального backup

Статус: только локальная подготовка. SQL ниже в Supabase не выполнялся. Коммит `22f37fe8530ae9dd228d231980495e265be1fcb4` с backup workflow не изменён и не опубликован. Workflows, Secrets и действующая БД не менялись.

## Вывод и границы подтверждения

Через read-only Management metadata подтверждены проект `orbita-mobile-test`, ref `fjqghohhohgvwlmefdmo`, регион `eu-north-1`, PostgreSQL `17.11.0.011`, статус `ACTIVE_HEALTHY`, direct host `db.fjqghohhohgvwlmefdmo.supabase.co`. Это не проверка SQL-привилегий. Наличие reader, реальные ACL, параметры Supavisor и цепочка TLS не проверялись подключением.

**Штатный hosted Supabase не предоставляет владельцу подтверждённого способа создать требуемую строго ограниченную роль только для четырёх схем без изменения глобальных прав.** Не объявлять workflow готовым к облачному запуску.

1. `postgres` в Supabase не superuser. Для новой роли нужны `CREATEROLE` и `BYPASSRLS` у создающей роли (либо superuser); PostgreSQL 17 допускает передачу BYPASSRLS обладателем этого атрибута, а не только superuser. Доступные атрибуты редактора нужно проверить, не пытаться повысить их.
2. Managed `auth` принадлежит `supabase_admin`, его таблицы — `supabase_auth_admin`. По текущей KB у `postgres` нет `USAGE WITH GRANT OPTION` на схему. `GRANT USAGE` может вывести только предупреждение и ничего не выдать. Один SELECT на таблицы не решает проблему.
3. Поддерживаемый Supabase backup-паттерн — отдельный логин с `BYPASSRLS` и членством `pg_read_all_data`. Это чтение **всех** схем, а не четырёх. Он нарушает требования нашего runtime: отсутствие memberships и SELECT вне scope. Роль не является `postgres`, но её credentials нельзя считать строго read-only.
4. PUBLIC даёт любому логину дополнительные права, включая TEMP, large objects, а при pg_net — HTTP queue/response. NOINHERIT и REVOKE от самой reader не отменяют PUBLIC; отрицательных GRANT в PostgreSQL нет. Отзыв таких системных grants способен нарушить службы Supabase.

Не подходят: `pg_write_all_data`, `service_role`, memberships managed Auth-ролей, superuser, отключение RLS, глобальные REVOKE, добавление SECURITY DEFINER API ради dump, ослабление runtime preflight. Обычная Read Replica также не решает доступ credentials к Primary: роли и пароль копируются. Для строгого требования нужен отдельно подтверждённый провайдером доступ с принудительным read-only и ограничением scope/доступа к Primary, либо другое отдельно согласованное решение. Существующий workflow с закреплённым host автоматически такой endpoint не использует.

## Подготовленные SQL

[`backup_access_readonly.proposed.sql`](backup_access_readonly.proposed.sql) — только системные каталоги, ACL и встроенные проверки привилегий в READ ONLY с ROLLBACK. Не читает строки Auth, пароли ролей, произвольные GUC или определения пользовательских функций. Показывает возможности редактора, наличие reader, владельцев/SELECT, PUBLIC grants, потенциально вызываемые функции и extensions. Это диагностика, а не исправление.

[`create_backup_reader.BLOCKED.proposed.sql`](create_backup_reader.BLOCKED.proposed.sql) — условная спецификация, **не готовая инструкция для запуска на текущем hosted проекте**. Перед CREATE проверяет полномочия, grant options managed-схем и опасные PUBLIC database/large-object grants. При несовместимости выдаёт фиксированную ошибку и вся транзакция откатывается. Не удалять эти проверки. В нормальной конфигурации hosted Supabase ожидается отказ по managed-схеме либо PUBLIC.

Если провайдер отдельно обеспечит допустимые условия, кандидат создаёт NOLOGIN/PASSWORD NULL, NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION, BYPASSRLS, connection limit 2; CONNECT, USAGE четырёх схем, SELECT текущих таблиц и sequences. USAGE/UPDATE на sequences не нужны: они позволяют nextval/изменения. Нет grant option, memberships, владения приложением, записи или default privileges. Два соединения нужны для held snapshot и pg_dump. Таймауты/default READ ONLY — только защита от ошибок, не неизменяемые ограничения.

Кандидат не активирует логин, не задаёт пароль и не подменяет полную проверку эффективных прав. Новые Auth-таблицы не получат SELECT автоматически: preflight обязан обнаружить неполный scope. Положительный результат CREATE/GRANT без проверки фактических прав не является готовностью.

## Пошагово для владельца — пока только просмотр

1. Открыть https://supabase.com/dashboard/project/fjqghohhohgvwlmefdmo и убедиться, что выбран именно `orbita-mobile-test`. Не выбирать другой проект с похожим названием.
2. Открыть **SQL Editor → New query**. После отдельного разрешения на чтение сюда можно вставить **только** `backup_access_readonly.proposed.sql`, выбрать Database `Primary`/роль `postgres`, нажать **Run**. Сейчас команды не запускать. Ожидается несколько таблиц результатов; `reader_exists=false` допустимо. Для `auth` проверить `editor_can_grant_usage`: `false` означает блокер. Наличие TEMPORARY/LO EXECUTE или других опасных PUBLIC grants означает блокер. Ошибки и предупреждения не игнорировать.
3. Не запускать `create_backup_reader.BLOCKED.proposed.sql`, пока не подтверждено решение managed Auth и PUBLIC. Не копировать официальный широкий `pg_read_all_data` пример в этот проект как замену. В поддержку Supabase можно передать требование четырёх схем и принудительного read-only, без паролей и данных; обращение сейчас не отправлялось.
4. Для проверки подключения открыть **Connect → Method: Session pooler**. Ожидаются host `aws-0-eu-north-1.pooler.supabase.com`, port `5432`, database `postgres`. Имя будущего клиента `orbita_backup_reader.fjqghohhohgvwlmefdmo`; внутри БД current_user должен быть `orbita_backup_reader`. Если Dashboard показывает другой host, остановиться: не менять закреплённую цель молча. Transaction pooler на `6543` для held transaction/snapshot не использовать.
5. В **Database → Settings → SSL Configuration → Server root certificate → Download** скачать CA. Прямая страница: https://supabase.com/dashboard/project/fjqghohhohgvwlmefdmo/database/settings . Названия могут меняться; искать раздел SSL и Server root certificate. Не включать/менять Enforce SSL и не сбрасывать DB password ради скачивания сертификата. Файл содержит `BEGIN CERTIFICATE`, не PRIVATE KEY. Сохранить исходный файл из аутентифицированного Dashboard.
6. На доверенном компьютере просмотреть сертификат командой `openssl x509 -in prod-ca-2021.crt -noout -subject -issuer -dates -fingerprint -sha256` (подставить имя скачанного файла). Fingerprint здесь идентифицирует CA, а не сервер. Проверить срок и источник; произвольный сертификат из чата или недоверенного соединения не использовать как root.
7. Только после разрешения сетевой пробы можно проверить TLS без DB-логина: `openssl s_client -starttls postgres -connect aws-0-eu-north-1.pooler.supabase.com:5432 -servername aws-0-eu-north-1.pooler.supabase.com -verify_hostname aws-0-eu-north-1.pooler.supabase.com -verify_return_error -CAfile prod-ca-2021.crt </dev/null`. Ожидать `Verification: OK` / `Verify return code: 0 (ok)`. Некоторые версии OpenSSL не поддерживают этот STARTTLS; это не причина отключить проверку. Проба устанавливает TLS-соединение, поэтому сейчас она не выполнялась. При ошибке цепочки/имени остановиться и уточнить правильный CA у провайдера; не использовать sslmode=require или IP.
8. После решения блокеров и отдельного разрешения на настройку поместить **полное содержимое PEM**, включая BEGIN/END, в `GitHub → primord1aal/Ordita-0.1v → Settings → Environments → orbita-mobile-test-backups → Environment variables → ORBITA_BACKUP_CA_PEM`. Это сертификат, не пароль и не путь к файлу. Два новых Environment Secrets из основного runbook настраивать позднее. Пароли не отправлять в чат, Git или SQL Editor: его история хранит запросы. Для будущей установки пароля предпочтителен доверенный локальный psql и интерактивная `\password orbita_backup_reader`, после отдельного согласования активации. Административный пароль не передаётся в GitHub Actions.

## TLS и Auth

Текущий код libpq использует Session pooler, verify-full и supplied CA. Verify-full проверяет цепочку и имя **pooler**, а не API-домен и не direct host. Официальный PSQL guide показывает именно скачанный Database Settings certificate вместе с Session pooler/verify-full. Он не закрепляет fingerprint конкретного регионального endpoint; фактическое соответствие PEM пока не проверено. pg_stat_ssl за pooler описывает backend-соединение; сам по себе этот SELECT не подтверждает TLS клиента до pooler. Клиентскую проверку выполняет libpq. Наш preflight дополнительно требует backend SSL и при его отсутствии остановится.

Raw pg_dump --schema=auth без исключений, при полном SELECT и BYPASSRLS, включает существующие Auth tables: users (включая encrypted_password/хеши паролей пользователей), identities, sessions, refresh_tokens, MFA/прочее состояние и внутреннюю Auth schema_migrations. Четвёртая схема supabase_migrations — отдельная история миграций проекта. Пароли PostgreSQL-ролей не входят. Открытых пользовательских паролей в auth.users нет; другие Auth-токены/PII чувствительны и должны оставаться в зашифрованном пакете.

Исторический локальный тест экспортировал synthetic users/refresh_tokens с FORCE RLS и восстановил их с совпадением хешей. Это не проверка текущих аккаунтов. Новый snapshot с действующим Auth ещё не создан. При будущем допущенном backup manifest должен перечислять все текущие Auth tables и хеши/количества; отсутствие SELECT или неполный RLS-доступ должно завершать экспорт ошибкой, без --enable-row-security и без фильтрации данных.

Новые SQL отдельно проверены на одноразовом PostgreSQL 17 через Unix socket без TCP: каталог читается при наличии/отсутствии reader и не выводит искусственные Auth-строки; очищенный локальный fixture допускает только NOLOGIN-кандидата; PUBLIC TEMP, PUBLIC LO и отсутствие schema grant option вызывают отказ без оставшейся роли. Искусственные Auth-аккаунты и история остались прежними. Это проверка синтаксиса PostgreSQL и предохранителей, не исполнения Supabase-specific grants. Прежние 9 backup-тестов повторно не запускались: runtime/workflow не менялись.

Восстановимость фактического снимка подтверждается только после его расшифрования и restore в одноразовом совместимом PostgreSQL 17 без сети и cloud credentials. Проверить владельцев/ACL, зависимости/extensions, все table hashes/counts и историю; не достаточно pg_restore --list. Не применять dump поверх hosted auth: в целевом Supabase уже есть managed-объекты, raw dump может конфликтовать. JWT signing keys, SMTP/OAuth/MFA external secrets, настройки Auth, Storage blobs и версии Auth runtime не входят в этот логический scope. Старые access/refresh tokens могут истечь или стать недействительными после смены ключей. Проверка логического restore не доказывает работу входа HTTP; для этого позднее потребуется отдельный изолированный совместимый Supabase-стенд.

## Официальные источники

- [Auth schema grant restrictions](https://supabase.com/kb/troubleshooting/permission-errors-when-granting-custom-roles-access-to-the-auth-schema-9e32e7)
- [Supported backup role and remaining writes](https://supabase.com/kb/troubleshooting/pg_dump-fails-with-query-would-be-affected-by-row-level-security-policy)
- [PUBLIC privileges and limits of revokes](https://supabase.com/kb/troubleshooting/custom-role-inherits-privileges-that-were-not-explicitly-granted-ddaa1c)
- [PostgreSQL 17 CREATE ROLE](https://www.postgresql.org/docs/17/sql-createrole.html)
- [Supabase PSQL and SSL certificate](https://supabase.com/docs/guides/database/psql)
- [PostgreSQL 17 libpq SSL](https://www.postgresql.org/docs/17/libpq-ssl.html)
- [Auth users and password hashes](https://supabase.com/kb/troubleshooting/migrating-auth-users-between-projects)
- [Limits of raw dump restore](https://supabase.com/docs/guides/self-hosting/restore-from-platform)
