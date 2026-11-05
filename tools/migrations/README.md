# Локальная проверка механизма миграции

Текущая граница разрешения — подготовка и локальные тесты. Ничего не опубликовано этой подготовкой. Облачные команды не запускать. [Понятный план, допуски и восстановление](../../docs/STAGE_3B_MIGRATION_RUNBOOK.md).

Файлы:

- `lock.json`, `install_cli.py` — CLI 3.0.0, официальный архив с проверкой SHA-256; фиксированная миграция и образ PostgreSQL.
- `policy.py` — чистые проверки события/ветки/SHA/Ref/URL/Environment/preview/истории попыток.
- `github_gate.py` — будущая read-only проверка реальных защит GitHub; выполняется до выдачи процессу секрета БД.
- `dbtools.py` — фиксированные SELECT, pg_dump и CLI без пароля в URL/argv; полная проверка TLS.
- `backup.py` — зашифрованный экспорт и проверка восстановления в локальной PostgreSQL без сети; облачного restore нет.
- `cloud_run.py` — подготовленные режимы preview/apply/inspect; требует файл допуска текущего запуска GitHub. Не запускался против облака.
- `request_run.py` — только генератор JSON API-запроса, без отправки и облачных подключений.
- `tests/` — негативные unit-проверки и модели последовательности runner; `supabase/tests/test_migration_cli.py` — настоящие интеграционные проверки CLI и копии.

Для разработчика с локальными Python 3.12, Docker, OpenSSL и GnuPG. Загрузка инструментов обращается только к их публичным дистрибутивам; сами SQL/CLI-тесты используют контейнеры без сети и порты не публикуют. Реальные Supabase Variables/Secrets не нужны:

```sh
python3 tools/migrations/install_cli.py /tmp/orbita-cli
docker pull postgres@sha256:839fbb5a4942a7758dd93e18b42ea5649807491a0545b5eeeb8f0b8bb11857a5
python3 -m unittest discover -s tools/migrations/tests -v
ORBITA_SUPABASE_CLI=/tmp/orbita-cli/supabase python3 -m unittest discover -s supabase/tests -p test_migration_cli.py -v
python3 -m unittest discover -s supabase/tests -p test_auth_sql.py -v
```

Все тесты должны завершиться без пропусков: 21 + 6 + 17 методов. Это команды для локальной автоматизации разработчика; владельцу телефона выполнять их не требуется.

`build/migration-cli-results.json` содержит только синтетические данные/CLI-вывод одноразовой БД. Его допустимо хранить как артефакт. Из облачного runner никогда не публикуются raw stdout/stderr CLI, открытые дампы, manifest с содержимым проекта, пароли и секретная фраза. Разрешены только подготовленные JSON-отчёты и зашифрованный `snapshot.tar.gpg`.

Локальное повторное `db push` проверено как no-op благодаря записанной версии. Это не разрешение повтора в облаке: неизвестный результат расследуется отдельно, Re-run/любая предыдущая попытка apply блокируются. Автоматических repair/reset/повторов и пути обхода нет.
