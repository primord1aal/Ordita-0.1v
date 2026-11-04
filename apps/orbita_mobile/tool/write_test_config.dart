import 'dart:convert';
import 'dart:io';

import 'package:orbita_mobile/src/backend/test_backend_configuration.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('Укажите путь временного файла конфигурации.');
    exitCode = 1;
    return;
  }
  final destination = File(args.single);
  // Старая конфигурация не должна пережить неуспешную проверку новой.
  if (destination.existsSync()) destination.deleteSync();
  final env = Platform.environment;
  final config = TestBackendConfiguration(
    url: env['SUPABASE_TEST_URL'] ?? '',
    publishableKey: env['SUPABASE_TEST_PUBLISHABLE_KEY'] ?? '',
    projectRef: env['SUPABASE_TEST_PROJECT_REF'] ?? '',
  );
  final error = config.buildError(
    forbiddenProjectRef: env['SUPABASE_FORBIDDEN_PROJECT_REF'] ?? '',
  );
  if (error != null) {
    stderr.writeln('Сборка остановлена: $error');
    exitCode = 1;
    return;
  }
  destination.writeAsStringSync(jsonEncode(config.clientDefines));
  stdout.writeln(
    'Целевой тестовый проект проверен. Конфигурация подготовлена.',
  );
}
