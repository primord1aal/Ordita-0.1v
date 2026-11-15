# Текущая резервная копия orbita-mobile-test

Статус: локально подготавливаемый backup-only механизм. Облачный запуск, создание роли, изменение ACL, GitHub Environment и Secrets этим документом не разрешены. Работоспособность облачного экспорта пока не подтверждена.

## Назначение и допуск

Workflow: [orbita-current-backup.yml](../.github/workflows/orbita-current-backup.yml). Исполнитель из корня репозитория:

```sh
python3 -m tools.current_backup --check-source
```

`--check-source` проверяет исходники без подключения к БД. Рабочая команда `python3 -m tools.current_backup` предусмотрена только для допущенного backup job; произвольного SQL, режимов restore, preview, apply и миграций у неё нет.

Для будущего ручного запуска нужны три обязательных input:

| Input | Точное значение |
| --- | --- |
| `approved_sha` | Полный согласованный SHA текущего HEAD запускаемой ветки, совпадающий с checkout |
| `project_ref` | `fjqghohhohgvwlmefdmo` |
| `confirmation` | `BACKUP_ONLY` |

Разрешён только владелец `primord1aal`, только первая попытка запуска. Re-run и автоматические повторы запрещены. При ошибке остановиться и разобрать безопасную категорию ошибки; не подменять роль и не расширять экспорт.

Workflow ещё потребуется отдельно зарегистрировать в default branch `main`; данный пакет не разрешает перенос кода в `main`, push или dispatch. Регистрация не означает разрешение на запуск: до него владелец отдельно согласует конкретные SHA, проект и backup-only операцию.

## Будущая настройка владельцем

Отдельный Environment: `orbita-mobile-test-backups`. Сейчас его не создаём. Настройки существующих миграционных Environments не переиспользовать.

После отдельного разрешения: `primord1aal/Ordita-0.1v → Settings → Environments → New environment → orbita-mobile-test-backups`. В `Deployment branches and tags → Selected branches and tags` разрешить только `codex/orbita-flutter-design-integration`. В этом Environment использовать `Environment secrets → Add environment secret` для двух Secrets ниже и `Environment variables → Add environment variable` для CA. Не помещать их в общие repository Secrets. Доступность Environment-защит зависит от плана и видимости репозитория; если GitHub не даёт такую конфигурацию, запуск блокируется до отдельного решения. Наличие Required reviewers здесь не предполагается.

| Область нового Environment | Имя | Назначение |
| --- | --- | --- |
| Secret | `ORBITA_BACKUP_READER_PASSWORD` | Пароль только выделенной роли `orbita_backup_reader` |
| Secret | `ORBITA_CURRENT_BACKUP_PASSPHRASE` | Независимая случайная GPG-фраза из менеджера паролей длиной не менее 24 символов; отличается от DB-пароля |
| Variable | `ORBITA_BACKUP_CA_PEM` | Доверенный корневой CA-сертификат в PEM; сертификат не является секретом |

Пароли и фразы вводить через защищённые настройки GitHub, не через чат, Git, аргументы команд или журналы. Корневой CA брать из доверенного источника провайдера; проверку TLS не отключать.

Цель закреплена в коде: `orbita-mobile-test`, роль `orbita_backup_reader`, Session pooler `aws-0-eu-north-1.pooler.supabase.com:5432`, пользователь pooler `orbita_backup_reader.fjqghohhohgvwlmefdmo`. Используются TLS и проверка сертификата/имени сервера. Произвольный DSN или другой пользователь не допускаются; `postgres`, `service_role` и административные ключи не являются запасным вариантом.

## Текущий блокер: строгая read-only роль

Preflight требует одновременно:

- `current_user` и `session_user` равны `orbita_backup_reader`; `NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION`, а `BYPASSRLS` включён для полного чтения строк;
- нет memberships, владения объектами и grant options; нет эффективных `CREATE` или `TEMPORARY`;
- нет эффективных прав записи на таблицы, отдельные столбцы и sequences во всех несистемных схемах; нет SELECT данных вне `auth`, `public`, `orbita_mobile_private`, `supabase_migrations`;
- нет доступных функций SECURITY DEFINER, способных писать или повышать права; функции с trigger/event-trigger pseudotype не считаются обычным вызываемым API; нет доступных через PUBLIC функций записи large objects.
- консервативно запрещён EXECUTE всех вызываемых VOLATILE-функций вне `pg_catalog`, даже если конкретная функция безвредна; это закрывает не только SECURITY DEFINER, но и функции расширений с побочными эффектами.

Проверяются эффективные права, включая PUBLIC, а не только явно выданные GRANT. `NOINHERIT`, изменяемый `default_transaction_read_only` и обычный `pg_dump` не доказывают безопасность credentials.

**На нынешнем hosted Supabase этот профиль может быть недостижим без отдельного решения провайдера.** PUBLIC даёт TEMP и возможности large objects; расширения могут добавлять права. Supabase предупреждает, что отзыв системных PUBLIC grants может нарушить Auth и другие службы: [официальное объяснение](https://supabase.com/kb/troubleshooting/custom-role-inherits-privileges-that-were-not-explicitly-granted-ddaa1c).

Если preflight отвергнет эти права, экспорт блокируется. Не выполнять автоматический REVOKE PUBLIC, не ослаблять проверку и не использовать `postgres`. Создание роли, выдача/пересмотр ACL или provider-enforced read-only endpoint требуют отдельного разрешения владельца и оценки влияния. Пока такого решения нет, облачную готовность не объявлять.

## Что создаёт успешный запуск

Четыре схемы экспортируются из одного согласованного snapshot в READ ONLY: `auth`, `public`, `orbita_mobile_private`, `supabase_migrations`. Dump в формате PostgreSQL custom (`-Fc`) сохраняет данные, определения, владельцев и ACL. Зашифрованный manifest содержит состав, количества строк и их хеши, состояния sequences, имена ролей, сведения о расширениях и event triggers.

Табличные данные согласованы по MVCC snapshot. Состояния sequences не версионируются MVCC: при параллельных обращениях они могут отличаться от manifest; такой снимок требует отдельной проверки sequences при восстановлении, а не автоматического изменения действующей БД. Лимит dump и несжатого пакета — 64 MiB, чтобы неожиданный объём завершался отказом.

Это ограниченный логический снимок, а не полная копия Supabase: пароли и конфигурация кластера, настройки Auth/JWT/OAuth/SMTP, Storage-файлы и прочая инфраструктура в него не входят. Сведения о global event triggers в manifest не означают, что schema-filtered dump восстановит их автоматически. Зависимости вне четырёх схем также требуют отдельного рассмотрения.

Dump и manifest упаковываются в архив, шифруются GPG AES-256 symmetric. Исполнитель проверяет SHA-256, расшифрование с совпадением исходного содержимого и читаемость dump через `pg_restore --list`. Это не проверка фактического восстановления.

Загружается ровно один artifact `ORBITA-current-backup-<run_id>` со сроком хранения **3 дня**, содержащий только:

- `snapshot.tar.gpg`;
- `SHA256SUMS`;
- `receipt.json` — служебный результат и контрольные суммы без данных БД, паролей или фраз.

Открытый dump, manifest и PostgreSQL stdout/stderr не публикуются. Фактического restore в workflow нет.

## Действия владельца после отдельно разрешённого запуска

Только после регистрации, подготовки безопасного доступа и нового разрешения: `Actions → Орбита — актуальная резервная копия (только чтение) → Run workflow`. Выбрать ветку `codex/orbita-flutter-design-integration` и три input из таблицы выше. Все четыре миграционных флага оставить `false`. Не использовать Re-run. Сначала `verify` выполняет тесты без credentials; затем `backup` повторно проверяет source, делает read-only preflight, экспорт и шифрование. В успешном run открыть `Summary → Artifacts → ORBITA-current-backup-<run_id>`. Ошибка preflight означает отсутствие готовой копии.

1. Скачать artifact через GitHub Actions под учётной записью владельца до истечения трёх дней. Сохранить зашифрованный архив, checksum и receipt в личном резервном хранилище. Истёкший artifact не восстановится автоматически.
2. На доверенном компьютере работать в закрытом каталоге с `umask 077`. Выполнить `sha256sum -c SHA256SUMS`, затем `gpg --output snapshot.tar --decrypt snapshot.tar.gpg`. Фразу вводить через интерактивный запрос GPG. Проверить список `tar -tf snapshot.tar`; распаковывать только ожидаемые обычные файлы dump и manifest без абсолютных путей, ссылок и выхода из каталога.
3. Для фактического восстановления создать одноразовую совместимую PostgreSQL 17 в Docker с **`--network none`**, без опубликованных портов, облачных DSN, DB-паролей и GitHub-токенов. Использовать заранее полученный доверенный образ; исходный dump монтировать read-only. Не восстанавливать в работающую локальную или облачную базу.
4. Просмотреть `pg_restore --list` и manifest. Подготовить только локальные роли с указанными именами, `NOLOGIN`, без опасных атрибутов и memberships. Отдельно рассмотреть необходимые расширения, зависимости и event triggers; не исполнять неизвестные определения автоматически. Недоступная зависимость — ограничение проверки, а не повод молча пропустить её.
5. Восстановить dump только в этом контейнере с остановкой при первой ошибке. Для проверки сохранённых владельцев и ACL не заменять её восстановлением с `--no-owner` или `--no-acl`. Не применять Auth/Orders SQL заново. Сверить состав, владельцев/ACL с каталогом и schema-only представлением dump; количества и хеши строк — с manifest. Проверить состояния sequences отдельно с учётом ограничения MVCC выше. Не публиковать строки, хеши и определения из manifest в открытые отчёты.
6. Записать checksum принятого архива, результат и ограничения восстановления. Успех этой проверки подтверждает только обозначенный логический объём, а не работоспособность полного Supabase/Auth HTTP. Удалить одноразовый контейнер и незашифрованные временные файлы после проверки.

Если восстановление не завершилось или сравнение расходится, копия не принята; остановиться без повторного облачного запуска и без изменений действующей БД.

Пример команд только для будущего локального стенда, после ручного просмотра архива и зависимостей. Каталог `recovery` содержит только расшифрованные `database.dump` и `manifest.json`; никакие облачные credentials туда не копируются. Имя контейнера должно быть свободным. Этот пример сейчас не запускался и не является разрешением на запуск:

```sh
docker run -d --name orbita-backup-restore --network none \
  --tmpfs /var/lib/postgresql/data:rw,nosuid,nodev,size=512m \
  --mount type=bind,src="$PWD/recovery",dst=/backup,readonly \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  postgres@sha256:839fbb5a4942a7758dd93e18b42ea5649807491a0545b5eeeb8f0b8bb11857a5
docker exec orbita-backup-restore pg_isready -U postgres
docker exec orbita-backup-restore pg_restore --list /backup/database.dump
```

После подготовки только локальных NOLOGIN-ролей и совместимых зависимостей создать внутри этого контейнера пустую БД `recovery` без уже существующей схемы `public`. Это допустимые изменения только одноразового стенда. Затем:

```sh
docker exec orbita-backup-restore pg_restore --exit-on-error \
  -U postgres --dbname=recovery /backup/database.dump
```

Для сверки каждой обычной таблицы использовать те же UTC/ISO/UTF8 настройки и формулу manifest; заменить `auth.users` нужной таблицей. Вывод хранить локально:

```sql
SET TimeZone='UTC'; SET datestyle='ISO, YMD'; SET bytea_output='hex';
SELECT count(*), encode(sha256(convert_to(coalesce(string_agg(
  row_to_json(t)::text, chr(10) ORDER BY row_to_json(t)::text COLLATE "C"
),''),'UTF8')),'hex') FROM ONLY auth.users t;
```

Формула и manifest создаются кодом `table_fingerprint()`; schema-only просмотр (`pg_restore --schema-only --file=...`) не должен подключаться к БД. Проверка всех таблиц и зависимостей обязательна перед признанием копии пригодной для восстановления.

## Закрытие временного доступа и сохранность старых копий

Старые workflows `orbita-stage-3b.yml` и `orbita-orders-migration.yml` остаются с выключенными cloud jobs. Четыре прежних флага сохраняются `false`: repository `ORBITA_REPO_MIGRATIONS_ENABLED`, `ORBITA_ORDERS_REPO_ENABLED`; соответствующие Environment `ORBITA_CLOUD_MIGRATIONS_ENABLED`, `ORBITA_ORDERS_CLOUD_ENABLED`. Новый backup не разрешает миграции.

Новые Secrets — только временный доступ до закрытия исходников. После скачивания, расшифрования и принятого локального восстановления требуется отдельное разрешение на cleanup: удалить обе новые GitHub Secrets, отозвать/отключить reader и ротировать его credentials, если он сохраняется. Проверить завершение активного job: удаление Secret не отзывает уже выданный пароль. Не включать старые workflows и не возвращать административные Secrets автоматически.

Все прежние GPG-фразы сохранить в менеджере паролей с привязкой к checksum/дате/формату исторических архивов. Ротация DB-пароля не меняет ключ расшифрования. При замене GPG-фразы создавать и проверять новую зашифрованную копию, не перезаписывая единственный оригинал до приёмки. Закрытие репозитория не заменяет отзыв доступа и не отзывает уже скачанные копии.
