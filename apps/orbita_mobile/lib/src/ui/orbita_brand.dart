import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Та же геометрия кольца и точки, что у Android drawable/ic_orbita.xml.
class OrbitaLogo extends StatefulWidget {
  const OrbitaLogo({this.loading = false, this.size = 88, super.key});
  final bool loading;
  final double size;
  @override
  State<OrbitaLogo> createState() => _OrbitaLogoState();
}

class _OrbitaLogoState extends State<OrbitaLogo>
    with SingleTickerProviderStateMixin {
  late final _rotation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  void _updateAnimation() {
    if (widget.loading && !MediaQuery.disableAnimationsOf(context)) {
      _rotation.repeat();
    } else {
      _rotation.stop();
      _rotation.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateAnimation();
  }

  @override
  void didUpdateWidget(covariant OrbitaLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loading != widget.loading) _updateAnimation();
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: 'Логотип Орбиты',
    child: SizedBox.square(
      dimension: widget.size,
      child: RotationTransition(
        turns: _rotation,
        child: const CustomPaint(painter: _OrbitaLogoPainter()),
      ),
    ),
  );
}

class _OrbitaLogoPainter extends CustomPainter {
  const _OrbitaLogoPainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 48, size.height / 48);
    final paint = Paint()
      ..color = const Color(0xffb9ef63)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    canvas.drawCircle(const Offset(24, 24), 16, paint);
    paint.style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(37, 11), 6, paint);
  }

  @override
  bool shouldRepaint(covariant _OrbitaLogoPainter oldDelegate) => false;
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
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const OrbitaLogo(loading: true, size: 96),
              const SizedBox(height: 24),
              Text('Орбита', style: Theme.of(context).textTheme.headlineMedium),
              if (_slow) ...[
                const SizedBox(height: 16),
                const Text('Подключаемся…', textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class BrandedAccountPage extends StatelessWidget {
  const BrandedAccountPage({required this.child, super.key});
  final Widget child;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                      'Орбита',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 28),
                    child,
                    const SizedBox(height: 20),
                    const Text(
                      'Тестовая версия $appVersion',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: OrbitaColors.muted),
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
