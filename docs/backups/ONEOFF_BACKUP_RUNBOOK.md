# Разовый актуальный backup без административного пароля в Actions

Обновлено 17 ноября 2026. **Workflow опубликован, Environment настроен владельцем. Первый запуск `44069919749` завершился ошибкой `CLIENT_FAILED`, артефактов нет, восстановление не запускалось. Актуального подтверждённого backup ещё нет.**

Роль была создана с отдельно разрешёнными правами. После неуспешного запуска выполнен подготовленный cleanup: NOLOGIN, PASSWORD NULL, истёкший срок; активных соединений роли 0, Auth-пользователей 4, история содержит только первую миграцию. Сертификат и Secrets в GitHub не менялись. Следующий запуск требует отдельного допуска; не использовать Re-run.

Цель: только `orbita-mobile-test`, Project Ref `fjqghohhohgvwlmefdmo`, eu-north-1, PostgreSQL 17. Старые `22f37fe` / `a5f6fb5`, `tools/current_backup/` и `.github/workflows/orbita-current-backup.yml` не изменены. Это отдельный временный путь, а не ослабление строгого reader.

## Почему этот путь совместим и что ещё не доказано

Supabase рекомендует для полного `pg_dump` при RLS отдельную роль LOGIN+BYPASSRLS+`pg_read_all_data`. Обычный pg_dump не переключается в postgres, в отличие от Supabase CLI dump. Поэтому CLI здесь не используется.

Read-only metadata текущего проекта подтвердили: postgres имеет CREATEROLE/BYPASSRLS и ADMIN membership `pg_read_all_data`. Но hosted `auth` не даёт postgres необходимых grant options для старой узкой роли. Внутреннюю `supabase_read_only_user` не изменять и не использовать её пароль. Новый профиль соответствует официальной рекомендации; создание роли в hosted Supabase **не выполнялось**, локальное создание не является доказательством облачного DDL.

Новая `orbita_oneoff_backup_reader` — не admin: NOSUPERUSER, NOCREATEDB, NOCREATEROLE, NOREPLICATION, без владения/выдачи прав. Только pg_read_all_data (INHERIT=true, SET=false, ADMIN=false), BYPASSRLS, CONNECT, два соединения; срок LOGIN — один час. Исходный setup оставляет NOLOGIN/PASSWORD NULL/истёкший срок. Проверяются отсутствие записи таблиц/sequences во всех схемах, CREATE схем/БД, владения, grant option и дополнительных прямых EXECUTE-grants.

**Остаточный риск, который владелец должен отдельно принять:** pg_read_all_data даёт чтение и вне четырёх экспортируемых схем, включая чувствительные данные Auth. PUBLIC может сохранять TEMP, large-object функции и EXECUTE volatile/SECURITY DEFINER функций. Default READ ONLY можно изменить клиентом; это не неизменяемое ограничение PostgreSQL. Украденные credentials потенциально опаснее фиксированного workflow. Поэтому обязательны отдельное согласование `ACK_BROAD_READ_AND_PUBLIC_PRIVILEGES`, уникальный короткоживущий пароль, фиксированный код, минимальный срок и последующее NOLOGIN/PASSWORD NULL. Глобальные PUBLIC/managed ACL не отзываются.

## Что делает workflow

Имя: **Орбита — разовый зашифрованный backup с проверкой восстановления**.
Файл `.github/workflows/orbita-oneoff-backup.yml`, единственная ветка `codex/orbita-oneoff-backup-preparation-20261116`.

Только owner manual dispatch, первый attempt, полный отдельно согласованный SHA; нет push/PR/schedule. До credentials проверяются реальные Environment guards и история одобрения. HTTP 403 или отсутствие проверки — остановка, не bypass. Migration workflow и четыре миграционных флага не включаются.

1. Libpq Session pooler `aws-0-eu-north-1.pooler.supabase.com:5432`, пользователь `orbita_oneoff_backup_reader.fjqghohhohgvwlmefdmo`, TLS **verify-full**, явный CA, фиксированные read-only параметры. Административного DB-пароля в job нет.
2. Held REPEATABLE READ READ ONLY snapshot; pg_dump импортирует именно этот snapshot. Каталог и все строки `auth`, `public`, `orbita_mobile_private`, `supabase_migrations` сверяются по count/hash; sequences проверяются по фактическому dump, поскольку они не MVCC. При large objects — отказ и отдельное рассмотрение.
3. Шифрование AES-256 через GPG/passphrase-fd, расшифрование и checksum; незашифрованные dump/manifest остаются только во временной среде.
4. Обязательное восстановление на PostgreSQL 17 в Docker **`--network none`**, Unix socket, без source DB credentials и GITHUB_TOKEN. Восстанавливаются owners/ACL через безопасные NOLOGIN role stubs, каталог/данные/история/sequences сверяются. Только после успеха публикуются ciphertext, SHA256SUMS и безопасная квитанция.

Экспорт и предварительная контейнерная проверка Git работают под числовым UID/GID владельца checkout, без root. Проверка исходников имеет `--network none` и не получает credentials. После шифрования только staging передаётся UID/GID 999 для изолированного восстановления; исходники остаются read-only.

Это scoped logical backup, **не полный disaster recovery Supabase**: не сохраняет Storage-файлы, другие схемы, кластерные пароли/членства, API/JWT/SMTP/Auth settings. Global event triggers записаны как metadata внутри шифрованного manifest, автоматически не устанавливаются. При зависимостях от отсутствующих extensions/внешних объектов или несовпадении restore — отказ без успешного artifact; не отключать проверки ради результата.

Auth users, encrypted_password, identities, sessions/refresh-token таблицы входят в экспорт, поскольку включена **вся** схема auth с BYPASSRLS. Сейчас реальное содержимое не читалось и backup не создан. Локальный PG restore доказывает сохранение таблиц, но не запуск GoTrue/HTTP-login: для такого восстановления нужны отдельно сохранённые конфигурация и совместимый Supabase-стенд.

## Действия владельца — только после отдельного согласования

### 1. Согласовать один backup-пакет

Разрешение должно охватывать публикацию именно проверенного backup-only коммита, безопасную регистрацию workflow, новый Environment/Secrets, создание/временную активацию и последующее отключение **только** новой роли, один backup run и проверку восстановления. Это не разрешение Preview/Apply или изменения действующих аккаунтов.

Основной репозиторий пока public: до push нужна отдельная проверка diff/полного SHA, обычный dry-run. Не публиковать dump/manifest/cloud diagnostics. Для обнаружения workflow на GitHub потребуется отдельная безопасная регистрационная версия в default branch с тремя inputs и одним пустым job, без Secrets/DB. Полный исполнитель остаётся в точной backup-only ветке. Сейчас main не изменялся.

### 2. Подготовить Environment в GitHub

Открыть `https://github.com/primord1aal/Ordita-0.1v/settings/environments` → **New environment** → `orbita-mobile-test-oneoff-backup` → Configure environment.

- Required reviewers: `primord1aal`; Prevent self-review выключено, поскольку запуск и одобрение выполняет единственный владелец. Admin bypass выключен.
- Deployment branches and tags: **Selected branches and tags** → Add deployment branch or tag rule → **Branch** → ровно `codex/orbita-oneoff-backup-preparation-20261116`. Без `*`, тегов и других веток.
- Environment secrets → Add environment secret: `ORBITA_ONEOFF_BACKUP_READER_PASSWORD` (только пароль временной роли), `ORBITA_ONEOFF_BACKUP_PASSPHRASE` (другая случайная фраза минимум 24 символа, предпочтительно менеджер паролей).
- Environment variables → Add environment variable: `ORBITA_ONEOFF_BACKUP_CA_PEM` — полное содержимое доверенного CA PEM, не путь к файлу и не private key.

Не помещать пароль postgres, service_role или management token. Не копировать/менять старые Secrets/Variables. Если план GitHub не даёт Required reviewers или API возвращает 403 — workflow не допущен. Сначала решить конкретное ограничение/отдельно согласовать альтернативу; не убирать gate.

### 3. Получить и проверить CA

Открыть `https://supabase.com/dashboard/project/fjqghohhohgvwlmefdmo/database/settings` → раздел SSL Configuration → **Server root certificate / Download**. Названия Dashboard могут меняться. Не менять Enforce SSL и не сбрасывать пароль. Сохранить PEM из аутентифицированного Dashboard, проверить отсутствие PRIVATE KEY, срок и SHA-256 fingerprint через `openssl x509 -in ca.pem -noout -subject -issuer -dates -fingerprint -sha256` в доверенном облачном терминале.

Верхняя кнопка **Connect** проекта → Session pooler должна показывать eu-north-1 host/5432, совпадающий с закреплённым выше. При отличии остановиться, не подставлять direct endpoint/IP.

Перед вводом credentials отдельно разрешённая TLS-проба:

```sh
openssl s_client -starttls postgres \
  -connect aws-0-eu-north-1.pooler.supabase.com:5432 \
  -servername aws-0-eu-north-1.pooler.supabase.com \
  -verify_hostname aws-0-eu-north-1.pooler.supabase.com \
  -verify_return_error -CAfile ca.pem </dev/null
```

Ожидать `Verify return code: 0 (ok)`. Проверяется имя pooler и цепочка доверия; pg_stat_ssl дополнительно проверяет backend TLS и сам по себе не доказывает TLS клиента. Неподходящий CA/hostname — блокер; не заменять verify-full на require.

### 4. Создать роль без пароля, затем безопасно активировать

Роль `orbita_oneoff_backup_reader` **уже существует**; создание повторно не выполнять. Перед следующим согласованным запуском проверить её точный профиль, использовать подготовленную активацию и заново установить пароль роли через защищённый интерфейс владельца. Срок активировать непосредственно перед готовностью владельца одобрить запуск. GitHub Secret может сохранить прежнее значение, если владелец повторно задаёт именно тот же сохранённый пароль; пароль шифрования архивов и CA менять не требуется.

Ниже сохранена первоначальная инструкция создания для проверки происхождения роли: `https://supabase.com/dashboard/project/fjqghohhohgvwlmefdmo/sql/new` → SQL Editor → New query → проверка проекта → точный `ONEOFF_BACKUP_ROLE.proposed.sql`. Сейчас этот шаг не выполнять: SQL содержит guard отказа при существующей роли.

Пароль **не вводить в SQL Editor, чат, Git или командную строку**. Для активации нужен защищённый интерактивный облачный терминал с psql 17 и CA. PostgreSQL/Docker/WSL на Windows-ПК владельца не требуются. Без такого защищённого ввода этот шаг остаётся блокером, не заменяется административным Secret в Actions.

В доверенном облачном терминале, без записи экрана/ввода и shell tracing:

```sh
psql "host=aws-0-eu-north-1.pooler.supabase.com port=5432 dbname=postgres user=postgres.fjqghohhohgvwlmefdmo sslmode=verify-full sslrootcert=/secure/ca.pem" -X -W
```

`/secure/ca.pem` — подготовленный приватный путь этого терминала, не интернет-адрес. `-W` запрашивает существующий пароль postgres без эха; его не отправляют агенту/в Actions. В psql:

```text
\password orbita_oneoff_backup_reader
```

Ввести и подтвердить новый случайный пароль временной роли, сохранить в менеджере и указанном новом Environment Secret. Затем выполнить **точный** `ONEOFF_BACKUP_ACTIVATE.proposed.sql` в той же доверенной сессии. LOGIN действует час; VALID UNTIL не завершает уже открытые соединения. Сессию закрыть `\q`. Административный пароль не сохранять в окружении/файлах терминала.

### 5. Запустить один backup

`https://github.com/primord1aal/Ordita-0.1v/actions` → **Орбита — разовый зашифрованный backup с проверкой восстановления** → **Run workflow**:

- Branch: `codex/orbita-oneoff-backup-preparation-20261116`.
- `approved_sha`: полный опубликованный и отдельно согласованный backup-коммит.
- `project_ref`: `fjqghohhohgvwlmefdmo`.
- `acknowledgement`: `ACK_BROAD_READ_AND_PUBLIC_PRIVILEGES`.

Проверить SHA → Run workflow → Review deployments → указанный Environment → Approve and deploy. Один запуск, не Re-run jobs. При ошибке — фиксированная безопасная категория, остановка и разбор без сырых логов/секретов.

### 6. Принять результат и сохранить отдельно

Ожидать success обоих jobs и artifact **`ORBITA-oneoff-backup-<run_id>`**, retention **3 дня**. Скачать сразу со страницы run → Artifacts. В ZIP ровно `snapshot.tar.gpg`, `SHA256SUMS`, `receipt.json`.

Проверить source_sha/run_id/project_ref квитанции, `status=logical_restore_verified`, `decryption_checked=true`, `isolated_restore_checked=true`, network isolation Docker --network none и `full_project_restore_proven=false`. Сверить ciphertext SHA-256 с квитанцией и SHA256SUMS. SHA без доверенной квитанции/шифрования не обеспечивает подлинность. Хранить две копии ciphertext в закрытых местах, passphrase отдельно в менеджере. Старые passphrase не удалять, пока нужны старые архивы.

Повторная проверка восстановления выполняется существующей командой `python3 -m tools.oneoff_backup restore` в закреплённом Docker-образе с `--network none`, входным ZIP после локального распаковывания только трёх файлов, приватным `/input`, пустым `/output` и passphrase через защищённое окружение. Облачные credentials в restore не передавать. Код сам расшифрует и проверит manifest, восстановит в свежий PG17, сравнит каталог/все строки/sequences и выдаст accepted-квитанцию. Никогда не направлять pg_restore в действующий Supabase.

После принятия и в рамках согласованного cleanup выполнить только `ONEOFF_BACKUP_DISABLE.proposed.sql`: NOLOGIN/PASSWORD NULL/истёкший срок. Не удалять архивы, Secrets/роль или старые пароли автоматически. Оставшиеся соединения требуют отдельного решения; expiration/NOLOGIN не убивает существующие сессии.

## Выполненные проверки

14 локальных тестов: прежние 8 unit и один интеграционный PostgreSQL 17.11, плюс 5 регрессий Git/границы пользователей контейнера. Синтетические users/password hashes/refresh tokens, профили/роли, RLS deny, история, sequences восстановлены; concurrent новая Auth-строка не попала в удерживаемый snapshot, исходная база не изменилась. Проверены tamper-отказ, отсутствие accepted artifact при ошибке restore, exact SHA/branch/Environment/approval, отказ 403 и admin bypass. Строгий reader продолжает отвергать расширенный профиль.

Дефект прав Git воспроизведён также на настоящем локальном Docker с Git 2.39.5, read-only mount и отключённой сетью: Git status под umask 077 может заменить чистый index на файл 0600; другой UID 999 получает Permission denied, а UID владельца checkout проходит HEAD/status. Исходный запуск не различал HEAD и STATUS, поэтому точная падающая команда в его логе отсутствует. Теперь ошибки получают фиксированные отдельные категории без вывода сырого stderr. Права исходников не расширяются, проверки SHA/чистоты и допуска остаются обязательными.

В неуспешном запуске backup-job начал работу после истечения согласованного часа доступа. Это отдельное ограничение перед следующим запуском: свежий ограниченный срок должен покрывать одобрение и экспорт. Никакого автоматического продления в GitHub Actions или автоматического повторения backup нет.

Проверены в облаке только профиль роли, защита Environment и actual approval первого запуска. Непроверены: успешное подключение с CA/паролем временной роли, фактический backup/restore нынешних аккаунтов и исправленный путь в GitHub runner. Локальное исправление до отдельного допуска не публикуется и повторный workflow не запускается.

## Официальные источники

- [Supabase: pg_dump and row-level security, updated 4 Nov 2026](https://supabase.com/kb/troubleshooting/pg_dump-fails-with-query-would-be-affected-by-row-level-security-policy)
- [Supabase backup and restore](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore)
- [Supabase psql / TLS](https://supabase.com/docs/guides/database/psql)
- [PostgreSQL 17 pg_dump](https://www.postgresql.org/docs/17/app-pgdump.html)
- [PostgreSQL 17 TLS verify-full](https://www.postgresql.org/docs/17/libpq-ssl.html)
