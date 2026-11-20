import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/orders/dispatch_controller.dart';

import 'dispatch_controller_test.dart' show FakeApi, passenger;

void main() {
  testWidgets(
    '20 idle seconds do not rebuild the page for clocks or identical polling',
    (tester) async {
      final api = FakeApi();
      final controller = DispatchController(
        api: api,
        userId: passenger,
        driver: false,
      );
      controller.setEnabled(true);
      await tester.pump();
      var notifications = 0;
      controller.addListener(() => notifications++);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      // This measures state invalidations, not Android frame timings.
      // ignore: avoid_print
      print(
        'PERF idle_20s page_notifications=$notifications requests=${api.calls.length}',
      );
      controller.dispose();
      expect(notifications, 0);
    },
  );
}
