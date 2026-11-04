// Проверка настоящего CLI отдельным Dart-процессом, без сетевых запросов.
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('orbita-guard-test-');
  final output = File('${dir.path}/defines.json');
  const ref = 'aaaaaaaaaaaaaaaaaaaa';
  const forbidden = 'bbbbbbbbbbbbbbbbbbbb';
  const key = 'sb_publishable_artificial_fixture_not_a_real_key';
  final env = {
    'SUPABASE_TEST_URL': 'https://$ref.supabase.co',
    'SUPABASE_TEST_PUBLISHABLE_KEY': key,
    'SUPABASE_TEST_PROJECT_REF': ref,
    'SUPABASE_FORBIDDEN_PROJECT_REF': forbidden,
  };
  void require(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  Future<ProcessResult> run(Map<String, String> values) => Process.run(
    Platform.resolvedExecutable,
    ['tool/write_test_config.dart', output.path],
    environment: values,
  );

  try {
    final valid = await run(env);
    require(
      valid.exitCode == 0,
      'Разрешённая искусственная конфигурация отклонена.',
    );
    final defines =
        jsonDecode(output.readAsStringSync()) as Map<String, dynamic>;
    require(
      defines.length == 3 &&
          !defines.containsKey('SUPABASE_FORBIDDEN_PROJECT_REF'),
      'В APK попал лишний параметр.',
    );
    require(
      !'${valid.stdout}${valid.stderr}'.contains(key),
      'Ключ попал в вывод.',
    );
    final invalid = await run({...env, 'SUPABASE_FORBIDDEN_PROJECT_REF': ref});
    require(
      invalid.exitCode != 0 && !output.existsSync(),
      'Запрещённая конфигурация не остановила сборку.',
    );
    require(
      !'${invalid.stdout}${invalid.stderr}'.contains(key),
      'Ключ попал в вывод ошибки.',
    );
    final missing = await run({for (final name in env.keys) name: ''});
    require(
      missing.exitCode != 0 && !output.existsSync(),
      'Отсутствие конфигурации не остановило сборку.',
    );
    stdout.writeln(
      'CLI: разрешение, запрет, отсутствие параметров и очистка — проверены.',
    );
  } finally {
    dir.deleteSync(recursive: true);
  }
}
