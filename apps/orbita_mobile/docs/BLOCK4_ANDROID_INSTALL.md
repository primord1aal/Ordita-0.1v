# Android: проверка сборки и установка блока 4

Историческое обследование исходного блока 4. Актуальные сведения об установленном SDK, Android-сборке 0.5.7+9 и установке приведены в [отчёте исправления](block4-correction/README.md).

Дата обследования: 12 ноября 2026 года. Исходный коммит: `1a44e55457e612dcea2832849489b8c7b95528cd`. Финальный SHA блока 4 и результаты его Flutter-проверок указываются в итоговом отчёте. Этот документ не подтверждает компиляцию APK или испытание Tecno.

## Что проверено локально

| Область | Фактический результат |
|---|---|
| Flutter / Dart | `flutter --version`: Flutter **3.47.9**, framework `c197ca5199e9ee5661e865596c9c07294dfab51c`, Dart **3.13.7**. Совпадают с закреплённым Flutter в CI. |
| Java | Доступна OpenJDK **21.0.13**; проект задаёт Java/Kotlin target **17**, а CI устанавливает Temurin **17**. Совместимость локальной Android-компиляции на Java 21 не проверена. |
| Android SDK | `adb` и `sdkmanager` не найдены в PATH; `ANDROID_HOME` и `ANDROID_SDK_ROOT` не указывают на существующий SDK. В проверенных стандартных каталогах SDK не найден. SDK не устанавливался. |
| Gradle / AGP | В исходниках закреплены Gradle **9.3.1** с SHA-256 дистрибутива, AGP **9.1.0**, Kotlin **2.4.0**. Gradle не исполнялся. Локальные wrapper launcher/JAR до Flutter-сборки отсутствуют; это не результат Gradle-компиляции. |
| Зависимости | `pubspec.lock` присутствует; ограничения SDK в нём — Dart `>=3.13.7 <4.0.0`, Flutter `>=3.47.9`. Успех `pub get --enforce-lockfile` и Flutter-проверок фиксируется отдельно итоговым прогоном. |
| XML / иконки | 12 XML-файлов `android/app/src/main/res` разобраны XML-парсером без ошибки. Launcher PNG присутствуют во всех пяти density: 48, 72, 96, 144, 192 px. Foreground adaptive icon: 108, 162, 216, 324, 432 px. Adaptive XML ссылается на имеющиеся foreground и цвет фона. Это проверка файлов, не Android resource linking. |
| Шрифты | Локальные Inter Regular/Medium/SemiBold/Bold и OFL присутствуют; четыре начертания объявлены в `pubspec.yaml`. Сетевые шрифты не нужны. |
| Идентичность | `applicationId` и namespace — **`ru.orbita.taxi.dev`**, minSdk **24**, версия в `pubspec.yaml` — **`0.5.6+8`**. Фактические versionName/versionCode внутри APK пока не измерены. У split APK возможна добавка ABI к versionCode. |
| Подпись | Пользовательская debug signingConfig и постоянный keystore в workflow не заданы. Используется обычная debug-подпись Android. Сертификат и совместимость с уже установленным APK не подтверждены. Новый CI runner может создать другой debug keystore. |

Источники: [Gradle приложения](../android/app/build.gradle.kts), [AGP/Kotlin](../android/settings.gradle.kts), [wrapper](../android/gradle/wrapper/gradle-wrapper.properties), [pubspec](../pubspec.yaml), [lockfile](../pubspec.lock), [манифест](../android/app/src/main/AndroidManifest.xml), [adaptive icon](../android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml).

Локальная Android-сборка, `testDebugUnitTest`, `lintDebug`, APK ABI и сертификат здесь не проверялись: доступного Android SDK нет. Flutter-тесты не заменяют эти проверки. Служба геолокации, Android-разрешения и protected storage этим обследованием не изменялись.

## Условия ровно одного CI verify

Существующий workflow [orbita-stage-3b.yml](../../../.github/workflows/orbita-stage-3b.yml) прочитан без изменений:

- `workflow_dispatch` позволяет выбрать `migration_operation=verify` (строки 15–21); `verify-and-build` допускает этот режим без ограничения веткой 3Б (строки 102–104).
- `sql` и `cli-safety` работают с локальными контейнерами и искусственными данными. Flutter-проверки выполняются в отдельном network namespace (строки 155–161).
- `migration_entry`, `migration-preview`, `migration-apply` требуют других режимов и ветку `codex/orbita-stage-3b-auth` (строки 199, 224, 299); при `verify` они не выполняются.
- Workflow имеет `contents: read` (строки 39–40); шагов изменения GitHub Variables, Secrets или Environment в `verify` нет.
- Сначала собирается APK без серверной конфигурации, затем выполняются Android unit/lint. Для второго APK `write_test_config.dart` проверяет тестовую конфигурацию и только после этого запускается компиляция (строки 162–175). Компиляция не запускает приложение и не выполняет клиентские операции заказов.

Перед единственным запуском ответственный должен подтвердить:

1. Финальный SHA опубликован в `codex/orbita-flutter-design-integration`, локальные обязательные Flutter-проверки успешны.
2. Четыре Repository/Organization Variables существуют и корректны: `SUPABASE_TEST_URL`, `SUPABASE_TEST_PUBLISHABLE_KEY`, `SUPABASE_TEST_PROJECT_REF`, `SUPABASE_FORBIDDEN_PROJECT_REF`. Их значения не публикуются в чате или логах и не заменяются фиктивными. Environment Variables для этого job не используются.
3. URL соответствует тестовому ref; publishable-ключ принадлежит именно этому тестовому проекту; forbidden ref соответствует действующему запрещённому проекту и отличается от тестового. Один формат ключа не доказывает принадлежность проекту.
4. Тестовый проект действительно изолирован от действующих клиентов и содержит только согласованные тестовые аккаунты/данные. Проверка формата конфигурации не доказывает этого организационного условия.

Автоматизированное подтверждение этих условий на момент обследования **не получено**. Доступный GitHub connector не предоставляет metadata-only проверки корректности Variables/Environment. REST-чтение Variables может вернуть значения; такой запрос не выполнялся. Наличие имён секретов само по себе также не подтверждает правильный проект. До подтверждения условий workflow не следует запускать вслепую.

## Инструкция владельцу, если автоматический запуск заблокирован

1. Приватно проверить перечисленные условия конфигурации в GitHub и подтвердить готовность тестового проекта без передачи значений ключей.
2. В **Actions → «Орбита 3Б — SQL, авторизация и тестовый APK» → Run workflow** выбрать ветку `codex/orbita-flutter-design-integration` с финальным SHA и только `migration_operation=verify`. Миграционные inputs оставить пустыми. Перед нажатием проверить выбранную ветку и режим.
3. Выполнить **один** запуск. Не выбирать `preview`, `apply`, `inspect`; не повторять неуспешный запуск автоматически. Зафиксировать URL запуска и SHA.
4. При ошибке сохранить точный job/step. Если нужны изменения `.github/`, серверной конфигурации, Secrets, Variables или Environment, остановить эту часть и согласовать конкретное действие. Не обходить guard и не добавлять фиктивную конфигурацию.
5. При успехе скачать APK-артефакт и отчёты. Workflow использует историческое имя `ORBITA-0.5.4-auth-preparation.apk`; **имя файла не доказывает версию**.

## Проверка полученного APK и установка на Tecno KL7

До передачи APK записать финальный SHA исходников, run URL, SHA-256 APK, application ID, versionName/versionCode, ABI и SHA-256 сертификата. Команды ниже выполняются только при наличии настоящего APK и Android build tools:

```sh
sha256sum ORBITA-0.5.4-auth-preparation.apk
apkanalyzer manifest application-id ORBITA-0.5.4-auth-preparation.apk
apkanalyzer manifest version-name ORBITA-0.5.4-auth-preparation.apk
apkanalyzer manifest version-code ORBITA-0.5.4-auth-preparation.apk
unzip -l ORBITA-0.5.4-auth-preparation.apk 'lib/*/libapp.so'
apksigner verify --verbose --print-certs ORBITA-0.5.4-auth-preparation.apk
```

Ожидается application ID `ru.orbita.taxi.dev`, versionName `0.5.6`, ARM64 `lib/arm64-v8a/`. versionCode проверяется по содержимому, с учётом split ABI. Наличие только имени `arm64` в названии файла недостаточно.

На Tecno KL7 сначала сохранить/получить APK уже установленного пакета (например, путь через `adb shell pm path ru.orbita.taxi.dev`, затем `adb pull` указанного `base.apk`) и сравнить его сертификат через `apksigner verify --print-certs` с сертификатом нового APK. Устройство должно быть явно выбрано и разрешено владельцем. Не копировать пользовательские базы, токены или защищённые данные в отчёт.

Только при совместимой подписи и подходящей версии можно установить поверх существующего пакета штатным Android-установщиком либо `adb install -r <проверенный-apk>`. При несовпадении подписи, отказе обновления или понижении версии остановиться и сохранить сообщение ошибки. **Не удалять приложение и не очищать его данные автоматически.** Для совместимого обновления потребуется APK, подписанный прежним ключом, либо отдельно согласованный владельцем план переноса.

После установки владелец проверяет фактическую версию, запуск, обе темы, настоящую карту, разрешения и безопасную диагностику. Это будущая физическая проверка; данный документ не объявляет её выполненной.
