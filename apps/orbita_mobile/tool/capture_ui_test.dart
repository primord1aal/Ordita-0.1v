// Не часть обычного набора тестов: ручной снимок Flutter-модели с тестовыми данными.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/app.dart';
import 'package:orbita_mobile/src/auth/auth_repository.dart';
import 'package:orbita_mobile/src/domain/contracts.dart';

import '../test/fake_device.dart';
import '../test/fake_auth_repository.dart';
import '../test/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fontDir = Platform.environment['ORBITA_FLUTTER_FONT_DIR'];
  final output = Directory(
    Platform.environment['ORBITA_UI_CAPTURE_DIR'] ?? 'build/ui-captures',
  );
  final width = double.parse(
    Platform.environment['ORBITA_CAPTURE_WIDTH'] ?? '360',
  );
  final height = double.parse(
    Platform.environment['ORBITA_CAPTURE_HEIGHT'] ?? '800',
  );
  setUpAll(() async {
    if (fontDir == null) {
      throw StateError('Задайте ORBITA_FLUTTER_FONT_DIR для шрифтов SDK.');
    }
    for (final entry in {
      'Roboto': ['Roboto-Regular.ttf', 'Roboto-Bold.ttf'],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final file in entry.value) {
        loader.addFont(
          Future.value(
            ByteData.sublistView(File('$fontDir/$file').readAsBytesSync()),
          ),
        );
      }
      await loader.load();
    }
    output.createSync(recursive: true);
  });
  for (final section in [
    'startup',
    'login',
    'driver',
    'passenger',
    'profile',
    'checks',
  ]) {
    for (final scale in [1.0, 2.0, 3.2]) {
      testWidgets('Снимок $section, $scale', (tester) async {
        setViewport(tester, Size(width, height), scale);
        final boundaryKey = GlobalKey();
        final device = FakeDevice()..state = readyState();
        final repository = FakeAuthRepository();
        final restoring = section == 'startup'
            ? Completer<AuthSession?>()
            : null;
        repository.restorePending = restoring;
        if (section != 'login' && section != 'startup') {
          repository.saved = testSession();
          repository.access = testAccess(
            section == 'driver' ? UserRole.driver : UserRole.passenger,
          );
        }
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: OrbitaApp(device: device, authRepository: repository),
          ),
        );
        if (restoring != null) {
          await tester.pump(const Duration(milliseconds: 500));
        } else {
          await tester.pumpAndSettle();
        }
        if (section == 'profile') await openProfile(tester);
        if (section == 'checks') await openCheck(tester, 'Проверка устройства');
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            '${output.path}/${width.toInt()}x${height.toInt()}-$section-$scale.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
        if (restoring != null) {
          restoring.complete(null);
          await tester.pumpAndSettle();
        }
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      });
    }
  }
}
