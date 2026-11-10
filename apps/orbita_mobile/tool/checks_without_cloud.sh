#!/usr/bin/env bash
set -euo pipefail

# Вызывается CI внутри отдельного network namespace с одним loopback.
# SDK/зависимости уже загружены; проектные Variables в этот процесс не передаются.
sdk_bin="$(dirname "$1")"
test -z "$(ip -4 route show default)"
test -z "$(ip -6 route show default)"
for parameter in SUPABASE_TEST_URL SUPABASE_TEST_PUBLISHABLE_KEY SUPABASE_TEST_PROJECT_REF SUPABASE_FORBIDDEN_PROJECT_REF SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY SUPABASE_SECRET_KEY GEOAPIFY_API_KEY; do
  if [ -n "${!parameter-}" ]; then
    echo 'В изолированные тесты передана облачная конфигурация. Проверка остановлена.' >&2
    exit 1
  fi
done
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true
"$sdk_bin/dart" tool/test_build_guard.dart
"$sdk_bin/flutter" test --no-pub --reporter expanded
