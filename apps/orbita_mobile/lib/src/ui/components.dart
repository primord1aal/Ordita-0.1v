import 'package:flutter/material.dart';

import 'theme.dart';
import 'orbita_brand.dart';
import 'shift_control.dart';

export 'adaptive_navigation.dart';
export 'shift_control.dart';

class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    super.key,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: padding, child: child),
  );
}

class PageHeader extends StatelessWidget {
  const PageHeader(this.title, {this.onRefresh, super.key});
  final String title;
  final VoidCallback? onRefresh;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 8, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (Navigator.canPop(context)) ...[
          const BackButton(),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        if (onRefresh != null)
          IconButton(
            tooltip: 'Обновить состояние',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
          ),
      ],
    ),
  );
}

class BrandHeader extends StatelessWidget {
  const BrandHeader({
    this.showShift = false,
    this.driverTypography = false,
    super.key,
  });
  final bool showShift;
  final bool driverTypography;
  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 74),
    padding: EdgeInsets.fromLTRB(18, driverTypography ? 10 : 12, 18, 12),
    decoration: BoxDecoration(
      color: Color.lerp(
        OrbitaPalette.of(context).surface,
        OrbitaPalette.of(context).mapLand,
        0.1,
      ),
      border: Border(
        bottom: BorderSide(color: OrbitaPalette.of(context).divider),
      ),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final style = TextStyle(
          fontSize: driverTypography ? 25 : 22,
          fontWeight: driverTypography ? FontWeight.w700 : FontWeight.w800,
          letterSpacing: driverTypography ? -1.375 : null,
          height: 1.2,
        );
        final title = Row(
          children: [
            const OrbitaLogo(size: 42),
            const SizedBox(width: 10),
            Expanded(child: Text('орбита.', style: style)),
          ],
        );
        if (!showShift) {
          return Align(alignment: Alignment.centerLeft, child: title);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            title,
            const SizedBox(height: 8),
            const Align(
              alignment: Alignment.centerRight,
              child: ShiftControl(),
            ),
          ],
        );
      },
    ),
  );
}

class MapPlaceholder extends StatelessWidget {
  const MapPlaceholder({this.minimumHeight = 180, super.key});
  final double minimumHeight;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Область карты. Карта не подключена',
    excludeSemantics: true,
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: minimumHeight),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: ColoredBox(
          color: const Color(0xff16252c),
          child: CustomPaint(
            painter: const _MapBackdrop(),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.map_outlined,
                      size: 28,
                      color: OrbitaColors.muted,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Карта не подключена',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: OrbitaColors.muted),
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

class _MapBackdrop extends CustomPainter {
  const _MapBackdrop();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xff20353d)
      ..strokeWidth = 1.5;
    for (double x = -size.height; x < size.width + size.height; x += 72) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height * 0.5, size.height),
        paint,
      );
    }
    for (double y = 34; y < size.height; y += 68) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y - 20), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MapBackdrop oldDelegate) => false;
}

class StateBadge extends StatelessWidget {
  const StateBadge(this.label, {required this.good, super.key});
  final String label;
  final bool good;
  @override
  Widget build(BuildContext context) {
    final palette = OrbitaPalette.of(context);
    final color = good ? palette.success : palette.muted;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Icon(
                good
                    ? Icons.check_circle_outline
                    : Icons.radio_button_unchecked,
                size: 16,
                color: color,
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label, style: TextStyle(fontSize: 13, color: color)),
            ),
          ],
        ),
      ),
    );
  }
}

class FullWidthAction extends StatelessWidget {
  const FullWidthAction(
    this.label, {
    required this.onPressed,
    this.secondary = false,
    super.key,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool secondary;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: secondary
        ? OutlinedButton(
            onPressed: onPressed,
            child: Text(label, textAlign: TextAlign.center),
          )
        : FilledButton(
            onPressed: onPressed,
            child: Text(label, textAlign: TextAlign.center),
          ),
  );
}
