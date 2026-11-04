/// Публичная конфигурация тестовой сборки. Значения поступают только при сборке.
class TestBackendConfiguration {
  const TestBackendConfiguration({
    required this.url,
    required this.publishableKey,
    required this.projectRef,
  });

  const TestBackendConfiguration.fromEnvironment()
    : url = const String.fromEnvironment('SUPABASE_TEST_URL'),
      publishableKey = const String.fromEnvironment(
        'SUPABASE_TEST_PUBLISHABLE_KEY',
      ),
      projectRef = const String.fromEnvironment('SUPABASE_TEST_PROJECT_REF');

  final String url;
  final String publishableKey;
  final String projectRef;

  static final _refPattern = RegExp(r'^[a-z0-9]{20}$');
  static final _keyPattern = RegExp(r'^sb_publishable_[A-Za-z0-9_-]{10,}$');

  String? get error {
    if (url.isEmpty || publishableKey.isEmpty || projectRef.isEmpty) {
      return 'Не задана конфигурация тестового проекта.';
    }
    if (!_refPattern.hasMatch(projectRef)) {
      return 'Некорректный идентификатор тестового проекта.';
    }
    final expected = 'https://$projectRef.supabase.co';
    if (url != expected && url != '$expected/') {
      return 'URL не совпадает с разрешённым тестовым проектом.';
    }
    if (!_keyPattern.hasMatch(publishableKey)) {
      return 'Нужен публичный publishable-ключ тестового проекта.';
    }
    return null;
  }

  /// Дополнительная обязательная проверка CI. Запрещённый ref не входит в APK.
  String? buildError({required String forbiddenProjectRef}) {
    if (!_refPattern.hasMatch(forbiddenProjectRef)) {
      return 'Не задан корректный идентификатор запрещённого проекта.';
    }
    if (projectRef == forbiddenProjectRef) {
      return 'Запрещено собирать приложение для существующего проекта.';
    }
    return error;
  }

  bool get isValid => error == null;

  Uri get healthUri {
    if (!isValid) throw StateError('Тестовая конфигурация не подтверждена.');
    return Uri.https('$projectRef.supabase.co', '/auth/v1/health');
  }

  Map<String, String> get clientDefines => {
    'SUPABASE_TEST_URL': url,
    'SUPABASE_TEST_PUBLISHABLE_KEY': publishableKey,
    'SUPABASE_TEST_PROJECT_REF': projectRef,
  };
}
