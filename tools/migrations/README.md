# Локальная проверка механизма миграции

Текущая подготовка — безопасный Preview через IPv4 Session pooler поверх `e081d7d23456c521861c20239d920644a210fab5`: SQL читается в явных READ ONLY-транзакциях с серверными таймаутами; CLI планирует только на восстановленном локальном снимке без внешней сети. Облачные команды без отдельного разрешения не запускать. [Понятный план](../../docs/STAGE_3B_MIGRATION_RUNBOOK.md), [результаты текущей подготовки](../../docs/STAGE_3B_PREVIEW_LOCAL_REPORT.md).

Файлы:

- `lock.json`, `install_cli.py` — CLI 3.0.0, официальный архив с проверкой SHA-256; фиксированные миграция, PostgreSQL и тестовый Supavisor 2.9.13.
- `policy.py` — чистые проверки события/ветки/SHA/Ref/URL/Environment/preview/истории попыток.
- `repository_gate.py` — предварительный job без Environment, секретов/API/БД; отдельный Repository-флаг, отсутствие дублей Environment-флага/SHA, output только `repo_enabled=true`.
- `github_gate.py` — будущая read-only проверка реальных защит GitHub; выполняется до выдачи процессу секрета БД.
- `dbtools.py` — фиксированные SQL-чтения с SET LOCAL-ограничениями, pg_dump и CLI без пароля в URL/argv; полная проверка TLS. Read-only клиенты не запускают облачный CLI даже с dry-run.
- `backup.py`, `local_plan.py` — зашифрованный экспорт, расшифровка и восстановление; CLI dry-run только на проверенной локальной копии с TLS, `--network none` и подтверждённым удалением собственного контейнера. Облачного restore нет.
- `cloud_run.py` — режимы preview/apply/inspect; требует файл допуска текущего запуска GitHub. Inspect №19 прошёл на исходном SHA; текущий Preview ещё не запускался в облаке.
- `request_run.py` — только генератор JSON API-запроса, без отправки и облачных подключений.
- `tests/` — негативные unit-проверки и модели последовательности runner; `supabase/tests/test_migration_cli.py` — настоящие интеграционные проверки CLI и копии; `test_preview_pooler.py` — Preview через настоящий Supavisor; `test_b1_*.py` — ограничения, таймауты и очистка на PostgreSQL.

Для разработчика с локальными Python 3.12, Docker, OpenSSL и GnuPG. Загрузка инструментов обращается только к их публичным дистрибутивам; сами SQL/CLI-тесты используют контейнеры без сети и порты не публикуют. Реальные Supabase Variables/Secrets не нужны:

```sh
python3 tools/migrations/install_cli.py /tmp/orbita-cli
docker pull postgres@sha256:839fbb5a4942a7758dd93e18b42ea5649807491a0545b5eeeb8f0b8bb11857a5
docker pull supabase/supavisor@sha256:07f1a6098ffc04b80263bca4eb5c3e7bd2e03dfd1fc465aa108d7329000a1a4e
python3 -m unittest discover -s tools/migrations/tests -v
ORBITA_SUPABASE_CLI=/tmp/orbita-cli/supabase python3 -m unittest discover -s supabase/tests -p test_migration_cli.py -v
ORBITA_SUPABASE_CLI=/tmp/orbita-cli/supabase python3 -m unittest discover -s supabase/tests -p test_preview_pooler.py -v
ORBITA_SUPABASE_CLI=/tmp/orbita-cli/supabase python3 -m unittest discover -s supabase/tests -p 'test_b1_*.py' -v
python3 -m unittest discover -s supabase/tests -p test_auth_sql.py -v
```

Проверенные в текущей подготовке наборы: 68 unit/model-проверок, 6 настоящих CLI/backup-проверок, 8 проверок Supavisor и 10 B1 — все прошли без пропусков. Отдельные 17 SQL-сценариев, Flutter и Android также входят в автоматический CI. Интеграционные Docker-наборы локально запускаются последовательно: их контроль очистки сравнивает исходный состав контейнеров. Владельцу телефона выполнять эти команды не требуется.

`build/migration-cli-results.json` и `build/preview-pooler-results.json` содержат только синтетические результаты одноразовых БД. Их допустимо хранить как артефакты. Из облачного runner никогда не публикуются raw stdout/stderr CLI, открытые дампы, manifest с содержимым проекта, пароли и секретная фраза. Разрешены только подготовленные JSON-отчёты и зашифрованный `snapshot.tar.gpg`.

Локальное повторное `db push` проверено как no-op благодаря записанной версии. Это не разрешение повтора в облаке: неизвестный результат расследуется отдельно, Re-run/любая предыдущая попытка apply блокируются. Автоматических repair/reset/повторов и пути обхода нет.
