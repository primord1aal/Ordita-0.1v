import 'package:flutter/material.dart';

import 'theme.dart';
import 'orbita_brand.dart';

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
  const BrandHeader({this.showShift = false, super.key});
  final bool showShift;
  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 74),
    padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
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
        const style = TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          height: 1.2,
        );
        const title = Row(
          children: [
            OrbitaLogo(size: 42),
            SizedBox(width: 10),
            Expanded(child: Text('орбита.', style: style)),
          ],
        );
        if (!showShift) {
          return const Align(alignment: Alignment.centerLeft, child: title);
        }
        return const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            title,
            SizedBox(height: 8),
            Align(alignment: Alignment.centerRight, child: ShiftControl()),
          ],
        );
      },
    ),
  );
}

/// Состояние управляется снаружи: нажатие никогда само не меняет статус линии.
class ShiftControl extends StatefulWidget {
  const ShiftControl({
    this.confirmedOnline = false,
    this.available = false,
    this.requestChange,
    super.key,
  });
  final bool confirmedOnline;
  final bool available;
  final Future<void> Function(bool online)? requestChange;
  @override
  State<ShiftControl> createState() => _ShiftControlState();
}

class _ShiftControlState extends State<ShiftControl> {
  bool _busy = false;
  Future<void> _change() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (widget.confirmedOnline) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            scrollable: true,
            title: const Text('Выйти с линии?'),
            content: const Text(
              'Новые предложения перестанут поступать после подтверждения сервера.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Остаться'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Выйти'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }
      await widget.requestChange?.call(!widget.confirmedOnline);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось изменить статус линии.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.available && widget.requestChange != null && !_busy;
    final label = widget.confirmedOnline ? 'На линии' : 'На линию';
    return Semantics(
      key: const Key('shift-control'),
      button: true,
      enabled: enabled,
      label: enabled ? label : '$label. Недоступно без подключения аккаунта',
      child: ExcludeSemantics(
        child: Tooltip(
          message: widget.available
              ? label
              : 'Доступно после входа и подключения сервера',
          child: FilledButton(
            onPressed: enabled ? _change : null,
            style: FilledButton.styleFrom(
              backgroundColor: widget.confirmedOnline
                  ? OrbitaColors.accent
                  : const Color(0xff2c4247),
              foregroundColor: widget.confirmedOnline
                  ? const Color(0xff16240e)
                  : OrbitaColors.text,
              disabledBackgroundColor: const Color(0xff25363e),
              disabledForegroundColor: OrbitaColors.muted,
              textStyle: Theme.of(context).textTheme.labelLarge!
                  .copyWith(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            child: Text(label, textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}

class AdaptiveNavigation extends StatelessWidget {
  const AdaptiveNavigation({
    required this.driver,
    required this.selected,
    required this.onSelected,
    super.key,
  });
  final bool driver;
  final int selected;
  final ValueChanged<int> onSelected;
  @override
  Widget build(BuildContext context) {
    final labels = [driver ? 'Работа' : 'Заказ', 'Поездки', 'Профиль'];
    final icons = [
      driver ? Icons.local_taxi_outlined : Icons.place_outlined,
      Icons.history,
      Icons.person_outline,
    ];
    final palette = OrbitaPalette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < labels.length; i++)
                  Expanded(
                    child: Semantics(
                      key: Key('nav-$i'),
                      label: labels[i],
                      button: true,
                      selected: selected == i,
                      enabled: true,
                      onTap: () => onSelected(i),
                      child: ExcludeSemantics(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: Material(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(16),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => onSelected(i),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: 64,
                                  minWidth: 48,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 10,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        icons[i],
                                        size: 24,
                                        color: selected == i
                                            ? palette.accent
                                            : palette.muted,
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        labels[i],
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 13,
                                          height: 1.2,
                                          fontWeight: selected == i
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          color: selected == i
                                              ? palette.text
                                              : palette.muted,
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
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: (good ? OrbitaColors.accent : OrbitaColors.muted).withValues(
        alpha: 0.10,
      ),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: Icon(
              good ? Icons.check_circle_outline : Icons.radio_button_unchecked,
              size: 16,
              color: good ? OrbitaColors.accent : OrbitaColors.muted,
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: good ? OrbitaColors.accent : OrbitaColors.muted,
              ),
            ),
          ),
        ],
      ),
    ),
  );
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
