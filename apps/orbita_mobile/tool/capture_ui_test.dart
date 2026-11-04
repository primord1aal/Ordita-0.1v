// Не часть обычного набора тестов: ручной снимок Flutter-модели с тестовыми данными.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/app.dart';

import '../test/fake_device.dart';
import '../test/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fontDir = Platform.environment['ORBITA_FLUTTER_FONT_DIR'];
  final output = Directory(
    Platform.environment['ORBITA_UI_CAPTURE_DIR'] ?? 'build/ui-captures',
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
  for (final section in ['driver', 'passenger', 'checks']) {
    for (final scale in [1.0, 2.0, 3.2]) {
      testWidgets('Снимок $section, $scale', (tester) async {
        setViewport(tester, const Size(360, 800), scale);
        final boundaryKey = GlobalKey();
        final device = FakeDevice()..state = readyState();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: OrbitaApp(device: device),
          ),
        );
        await tester.pumpAndSettle();
        final role = section == 'passenger' ? 'Пассажир' : 'Водитель';
        await scrollTo(tester, find.text(role));
        await tester.tap(find.text(role));
        await tester.pumpAndSettle();
        if (section == 'checks') await openCheck(tester, 'Проверка телефона');
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          File('${output.path}/$section-$scale.png')
              .writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      });
    }
  }
}
