import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Геометрия утверждённого SVG: наклонённое кольцо и точка.
class OrbitaLogo extends StatelessWidget {
  const OrbitaLogo({this.loading = false, this.size = 88, super.key});
  final bool loading;
  final double size;
  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: 'Логотип Орбиты',
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _OrbitaLogoPainter(OrbitaPalette.of(context)),
      ),
    ),
  );
}

class _OrbitaLogoPainter extends CustomPainter {
  const _OrbitaLogoPainter(this.palette);
  final OrbitaPalette palette;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 64, size.height / 64);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, 64, 64),
        const Radius.circular(18),
      ),
      Paint()..color = palette.brandTile,
    );
    canvas.save();
    canvas.translate(32, 32);
    canvas.rotate(-43 * math.pi / 180);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 42, height: 28),
      Paint()
        ..color = palette.brandRing
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5,
    );
    canvas.restore();
    canvas.drawCircle(
      const Offset(47.4, 17.7),
      5.1,
      Paint()..color = palette.accent,
    );
  }

  @override
  bool shouldRepaint(covariant _OrbitaLogoPainter oldDelegate) =>
      oldDelegate.palette != palette;
}

class StartupSplash extends StatefulWidget {
  const StartupSplash({super.key});
  @override
  State<StartupSplash> createState() => _StartupSplashState();
}

class _StartupSplashState extends State<StartupSplash> {
  bool _slow = false;
  late final Timer _captionTimer;

  @override
  void initState() {
    super.initState();
    _captionTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _captionTimer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('startup-splash'),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const OrbitaLogo(loading: true, size: 96),
                    const SizedBox(height: 24),
                    const SizedBox(height: 2),
                    Text(
                      'орбита.',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Местное такси для своих',
                      style: Theme.of(context).textTheme.bodyLarge
                          ?.copyWith(color: OrbitaPalette.of(context).muted),
                    ),
                    const SizedBox(height: 28),
                    SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: OrbitaPalette.of(context).accent,
                      ),
                    ),
                    if (_slow) ...[
                      const SizedBox(height: 16),
                      const Text('Подключаемся…', textAlign: TextAlign.center),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class BrandedAccountPage extends StatelessWidget {
  const BrandedAccountPage({
    required this.child,
    this.loginLayout = false,
    super.key,
  });
  final Widget child;
  final bool loginLayout;
  @override
  Widget build(BuildContext context) => loginLayout
      ? Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 74),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Color.lerp(
                      OrbitaPalette.of(context).surface,
                      OrbitaPalette.of(context).mapLand,
                      0.1,
                    ),
                    border: Border(
                      bottom: BorderSide(
                        color: OrbitaPalette.of(context).divider,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      const OrbitaLogo(size: 42),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'орбита.',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: math.max(0, constraints.maxHeight - 48),
                        ),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 500),
                            child: child,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        )
      : Scaffold(
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: math.max(0, constraints.maxHeight - 48),
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Center(child: OrbitaLogo()),
                          const SizedBox(height: 16),
                          Text(
                            'орбита.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          const SizedBox(height: 28),
                          child,
                          const SizedBox(height: 20),
                          Text(
                            'Тестовая версия $appVersion',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: OrbitaPalette.of(context).muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
}
