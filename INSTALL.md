# Орбита 0.5.7+9 — ARM64 debug APK

Файл: `ORBITA-0.5.7+9-arm64-debug.apk` (94 705 841 байт).
Исходный коммит: `fd404cd61b171f91d4bfc0576c8e93a1a3e2c369`.
https://github.com/primord1aal/Ordita-0.1v/commit/fd404cd61b171f91d4bfc0576c8e93a1a3e2c369
Ветка: `codex/orbita-flutter-design-integration`.
Application ID: `ru.orbita.taxi.dev`; versionName `0.5.7`; versionCode `2009`.
minSdk 24, targetSdk 36; только arm64-v8a.

SHA-256 APK: `119512e00021614ee00813e0afbfe0f7892be082f7c3fcfb80d1954905cd7e87`.
SHA-256 debug-сертификата: `36e06fba301fdca7928c8e20b120f24dcc49647b7997565597950feba2f6771f`.
Подпись APK v2 проверена apksigner, RSA 2048, один Android Debug signer.

APK неподключённый: конфигурация Supabase не вшита. Вход и водительские экраны на телефоне в этой сборке недоступны. Обхода ролей нет. Для их проверки нужна отдельно подтверждённая тестовая конфигурация при сборке. Ключ Geoapify не вшит; существующий ввод на устройстве сохранён.

Перед обновлением сравнить сертификат с уже установленным приложением. Debug-сертификат создан автоматически в новой среде, совпадение с прежним неизвестно. Если сертификаты совпали и Android разрешает версию, открыть APK штатным установщиком Tecno KL7; вариант для согласованного USB-устройства: `adb install -r ORBITA-0.5.7+9-arm64-debug.apk`.

Если Android отказал из-за подписи или версии — сохранить сообщение ошибки. Не удалять старое приложение, не очищать данные и не выполнять принудительное понижение версии. Нужна сборка с прежним согласованным ключом.

Проверки: Flutter 375/375, анализ без замечаний, формат 82 файла без изменений, build guard успешен; Android debug build и проверка метаданных/подписи успешны. Физический Tecno, TalkBack и настоящий Geoapify не проверялись.

Пять сравнений и отчёт:
https://github.com/primord1aal/Ordita-0.1v/blob/fd404cd61b171f91d4bfc0576c8e93a1a3e2c369/apps/orbita_mobile/docs/block4-correction/README.md
