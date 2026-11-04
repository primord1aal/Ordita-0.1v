import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/app.dart';
import 'package:orbita_mobile/src/platform/device_gateway.dart';

import 'fake_device.dart';

DeviceState readyState({bool running = false, bool background = true}) =>
    DeviceState(
      sdk: 34,
      notifications: true,
      location: 'precise',
      backgroundLocation: background,
      locationEnabled: true,
      serviceRunning: running,
      fixCount: 64,
      startedAt: DateTime(2026, 1, 1, 10).millisecondsSinceEpoch,
      lastHeartbeat: DateTime(2026, 1, 1, 10, 20).millisecondsSinceEpoch,
      lastFix: DateTime(2026, 1, 1, 10, 19, 58).millisecondsSinceEpoch,
    );

Future<void> scrollTo(
  WidgetTester tester,
  Finder finder, {
  double delta = 180,
}) async {
  await tester.scrollUntilVisible(
    finder,
    delta,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 80,
  );
  await tester.pumpAndSettle();
}

Future<void> openPreview(
  WidgetTester tester,
  String role, {
  FakeDevice? device,
}) async {
  await tester.pumpWidget(
    OrbitaApp(key: UniqueKey(), device: device ?? FakeDevice()),
  );
  await tester.pumpAndSettle();
  await scrollTo(tester, find.text(role));
  await tester.tap(find.text(role));
  await tester.pumpAndSettle();
}

Future<void> openProfile(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('nav-2')));
  await tester.pumpAndSettle();
}

Future<void> openCheck(WidgetTester tester, String label) async {
  await openProfile(tester);
  await scrollTo(tester, find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void setViewport(WidgetTester tester, Size size, double scale) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}
