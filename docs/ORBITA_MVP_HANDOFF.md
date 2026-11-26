# Орбита — передача состояния MVP

**27 ноября 2026 года, Новосибирск.** Разработка продолжается в `codex/orbita-night-mvp-20261126`. Защищённая ветка `codex/orbita-e2e-test-060` зафиксирована на `a648fb9dc51a3cd4d71d4c28cf708bd38f62cdc7`. [Ветка разработки](https://github.com/primord1aal/Ordita-0.1v/tree/codex/orbita-night-mvp-20261126) · [Коммит Maps Preview](https://github.com/primord1aal/Ordita-0.1v/commit/a648fb9dc51a3cd4d71d4c28cf708bd38f62cdc7)

## Maps Preview и Apply

В замороженном коммите шаг Maps runner получил обязательный `SUPABASE_TEST_PROJECT_REF` из GitHub Variables. Допуск, список миграций, ручное одобрение и SQL остались прежними. В изолированной PostgreSQL 17.11 прошли 9 проверок, включая шифрование и восстановление. Правильный Ref принят всеми тремя режимами, отсутствующий и неверный отклоняются до соединения с базой. SQL `supabase/proposals/20261120173504_managed_maps.sql` имеет SHA-256 `bf89215b12a25eea37cbb683fe234cfc1f7e217e286f962a6190ede91daa240b`. Зафиксированный SHA опубликован, автоматический GitHub Verify успешен. [Maps Verify](https://github.com/primord1aal/Ordita-0.1v/actions/runs/45722918438)

Защищённых Maps Preview и Apply ещё не было. Успешный Dispatch Apply подтвердил три записи на момент применения: `202611050001`, `20261112172442`, `20261120160748`. Отдельный серверный тест подтвердил вход пассажира и водителя и завершение реальной тестовой поездки. Текущее состояние БД снова сверит штатный Maps Preview. [Recovery Preview](https://github.com/primord1aal/Ordita-0.1v/actions/runs/45711472774) · [Dispatch Apply](https://github.com/primord1aal/Ordita-0.1v/actions/runs/45717039419) · [Серверный тест](https://github.com/primord1aal/Ordita-0.1v/actions/runs/45717039419/artifacts/15070059011)

### Действия владельца для Preview

1. Убедиться, что вершина `codex/orbita-e2e-test-060` соответствует `a648fb9dc51a3cd4d71d4c28cf708bd38f62cdc7`. Сохранить существующие правила веток, обязательное одобрение `primord1aal` и запрет обхода в `orbita-mobile-test-orders-migrations`.
2. Проверить Repository Variable `ORBITA_DISPATCH_REPO_ENABLED=true`. Только в Environment выставить `ORBITA_DISPATCH_CLOUD_ENABLED=true`, `ORBITA_DISPATCH_ALLOWED_OPERATION=preview` и `ORBITA_DISPATCH_ALLOWED_SHA=a648fb9dc51a3cd4d71d4c28cf708bd38f62cdc7`. Сверить `SUPABASE_TEST_PROJECT_REF=fjqghohhohgvwlmefdmo`, существующие `SUPABASE_FORBIDDEN_PROJECT_REF`, `ORBITA_TEST_DB_CA_PEM` и наличие закрытых `ORBITA_TEST_DB_PASSWORD`, `ORBITA_ORDERS_BACKUP_PASSPHRASE`.
3. Запустить новый `.github/workflows/orbita-maps-migration.yml` с указанной ветки и одобрить `guarded` для конкретного запуска. Пример запроса на запуск с пустыми `preview_run_id` и `backup_sha256`.

```sh
gh workflow run orbita-maps-migration.yml \
  --repo primord1aal/Ordita-0.1v \
  --ref codex/orbita-e2e-test-060 \
  -f operation=preview \
  -f approved_sha=a648fb9dc51a3cd4d71d4c28cf708bd38f62cdc7 \
  -f project_ref=fjqghohhohgvwlmefdmo
```

4. Сверить успех `guarded`, отчёт `ORBITA-maps-preview-<run>`, зашифрованный `ORBITA-maps-backup-<run>`, три исходные миграции, одну ожидающую Maps и успешное восстановление и репетицию. [Maps workflow](https://github.com/primord1aal/Ordita-0.1v/actions/workflows/orbita-maps-migration.yml)
5. Для отдельно согласованного Apply сохранить ветку и SHA. Изменить в Environment допустимую операцию на `apply`, передать `operation=apply`, тот же `approved_sha`, `project_ref`, `preview_run_id` и `backup_sha256` из успешного Preview. Требуется новое одобрение. При неясном результате потребуется отдельный Inspect. После завершения закрыть облачный флаг.

## Карты и Android

- Локальный шлюз различает отказ авторизации, временный сбой Auth или Geoapify, тайм-аут и исчерпание квоты. Клиент карты один раз повторяет временно упавшую загрузку, сохраняя камеру, и оставляет ручной повтор. Серверные лимиты, OSM и атрибуции сохранены. Прошли 14 тестов шлюза и 34 целевые Flutter-проверки.
- Для карт в тестовом облаке требуются Maps Apply и отдельное разрешение на публикацию `orbita-maps` и установку `GEOAPIFY_SERVER_KEY` в секретах сервера. Телефоны используют авторизованный шлюз.
- Последний подтверждённый APK — 0.6.2+14, исходный SHA `fedf60012ed0ff5f5e00b2486bf13b4ffa4050f2`. Исправления ветки разработки в него не входят. [Сборка 0.6.2+14](https://github.com/primord1aal/Ordita-0.1v/actions/runs/45272297923/artifacts/14865153370) · [Сценарии на телефонах](ORBITA_0.6.2.md)

## Восстановление поездки и GPS

- Пассажирская карта отображает реальную GPS-позицию отдельно от точки подачи. Поздний ответ GPS сохраняет выбранный за время запроса адрес. После возврата из настроек Android приложение перечитывает разрешение без повторного автоматического запроса.
- Водитель видит точки подачи и назначения из активной поездки. Камера один раз показывает обе точки и сохраняет выбранное положение при новых снимках той же поездки и возврате из фона. Кнопка GPS остаётся доступной без тайлов на рабочем экране.
- При возвращении приложения из фона контроллер дожидается завершения старого запроса и сразу сверяет серверное состояние. Поездка остаётся видимой, а команды ждут актуального ответа. Отмена, принятие, отказ и смена этапа отправляются только с ID заказа или предложения, показанного при нажатии. Статус «На линии» должен совпасть с подтверждением сервера.
- Локально прошли 46 проверок GPS и пассажирских сценариев, 40 водительских проверок, 14 проверок мобильной синхронизации и перерисовок и 6 сценариев в изолированной PostgreSQL. Проверены повтор создания, гонка принятия и отмены, смена водителя при отказе, восстановление поездки и общий срок поиска.

## Следующая контрольная точка

Проверить автономное расписание в изолированной PostgreSQL и подготовить недостающие части фоновых уведомлений. После карт на тестовом сервере выполнить поездку на двух телефонах с разрешённым и отклонённым GPS, проверить отказы и сроки. Фоновый Push, облачная диспетчерская, профильная плавность на Tecno и условия пилота в РФ требуют отдельных проверок. [Автономные сроки](orders/DISPATCH_AUTONOMY.md) · [Диспетчерская](orders/ADMIN_READ_TEST.md) · [Телефонный вход и размещение](OTP_RU_READINESS.md) · [Ревизия 24 ноября](audits/Orbita_audit_2026-11-24.xlsx)
