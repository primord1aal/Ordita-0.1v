import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

enum NavigationLayout { horizontal, vertical, compact }

/// Режим определяется измеренными строками и областью, доступной оболочке.
class AdaptiveNavigation extends StatefulWidget {
  const AdaptiveNavigation({
    required this.driver,
    required this.selected,
    required this.onSelected,
    this.availableHeight,
    super.key,
  });

  final bool driver;
  final int selected;
  final ValueChanged<int> onSelected;

  /// Высота LayoutBuilder оболочки за вычетом системных отступов и клавиатуры.
  /// Передаётся до распределения высоты между body и bottomNavigationBar.
  final double? availableHeight;

  @override
  State<AdaptiveNavigation> createState() => _AdaptiveNavigationState();
}

class _AdaptiveNavigationState extends State<AdaptiveNavigation> {
  bool _menuOpen = false;
  bool get driver => widget.driver;
  int get selected => widget.selected;
  ValueChanged<int> get onSelected => widget.onSelected;
  double? get availableHeight => widget.availableHeight;

  List<String> get _labels => [
    driver ? 'Линия' : 'Заказ',
    'Поездки',
    'Профиль',
  ];
  List<IconData> get _icons => [
    driver ? Icons.local_taxi_outlined : Icons.place_outlined,
    Icons.history,
    Icons.person_outline,
  ];

  TextStyle _style(BuildContext context, int i) => TextStyle(
    fontSize: 13,
    height: 1.2,
    fontWeight: selected == i ? FontWeight.w700 : FontWeight.w500,
    color: selected == i
        ? OrbitaPalette.of(context).text
        : OrbitaPalette.of(context).muted,
  );

  Size _measure(BuildContext context, String label, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final size = painter.size;
    painter.dispose();
    return size;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final media = MediaQuery.of(context);
      final safe = media.padding;
      final width = constraints.maxWidth - safe.horizontal;
      final height = math.max(
        0.0,
        availableHeight ??
            (media.size.height - safe.vertical - media.viewInsets.bottom),
      );
      final sizes = [
        for (var i = 0; i < _labels.length; i++)
          _measure(context, _labels[i], _style(context, i)),
      ];
      final horizontalTextWidth = (width - 16) / 3 - 14;
      final horizontalHeight =
          math.max(
            64.0,
            24 + 5 + sizes.map((s) => s.height).reduce(math.max) + 20,
          ) +
          14 +
          safe.bottom;
      final rowsHeight =
          sizes
              .map((s) => math.max(48.0, math.max(24.0, s.height) + 12))
              .reduce((a, b) => a + b) +
          14 +
          safe.bottom;
      final horizontalFits =
          sizes.every((s) => s.width <= horizontalTextWidth) &&
          horizontalHeight <= height;
      final verticalFits =
          sizes.every((s) => s.width <= width - 16 - 24 - 12 - 24) &&
          rowsHeight <= height * 0.20;
      final layout = horizontalFits
          ? NavigationLayout.horizontal
          : verticalFits
          ? NavigationLayout.vertical
          : NavigationLayout.compact;
      return DecoratedBox(
        key: Key('navigation-${layout.name}'),
        decoration: BoxDecoration(
          color: OrbitaPalette.of(context).surface,
          border: Border(
            top: BorderSide(color: OrbitaPalette.of(context).divider),
          ),
        ),
        child: SafeArea(
          top: false,
          child: switch (layout) {
            NavigationLayout.horizontal => _horizontal(context),
            NavigationLayout.vertical => _vertical(context),
            NavigationLayout.compact => _compact(context, width),
          },
        ),
      );
    },
  );

  Widget _semantics(int i, Widget child) => Semantics(
    key: Key('nav-$i'),
    label: _labels[i],
    button: true,
    selected: selected == i,
    enabled: true,
    onTap: () => onSelected(i),
    child: ExcludeSemantics(child: child),
  );

  // Компоновка ×1.0 сохранена из принятого компонента, включая отступы.
  Widget _horizontal(BuildContext context) {
    final palette = OrbitaPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < _labels.length; i++)
              Expanded(
                child: _semantics(
                  i,
                  Padding(
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
                                  _icons[i],
                                  size: 24,
                                  color: selected == i
                                      ? palette.accent
                                      : palette.muted,
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  _labels[i],
                                  textAlign: TextAlign.center,
                                  style: _style(context, i),
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
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int i, VoidCallback onTap) {
    final palette = OrbitaPalette.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(
                  _icons[i],
                  size: 24,
                  color: selected == i ? palette.accent : palette.muted,
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(_labels[i], style: _style(context, i))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _vertical(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _labels.length; i++)
          _semantics(i, _row(context, i, () => onSelected(i))),
      ],
    ),
  );

  Future<void> _openSections(BuildContext context) async {
    if (_menuOpen) return;
    _menuOpen = true;
    try {
      final choice = await showModalBottomSheet<int>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetContext) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    'Разделы',
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
                for (var i = 0; i < _labels.length; i++)
                  Semantics(
                    key: Key('nav-$i'),
                    button: true,
                    enabled: true,
                    selected: i == selected,
                    label: _labels[i],
                    onTap: () => Navigator.pop(sheetContext, i),
                    child: ExcludeSemantics(
                      child: _row(
                        sheetContext,
                        i,
                        () => Navigator.pop(sheetContext, i),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      if (context.mounted && choice != null && choice != selected) {
        onSelected(choice);
      }
    } finally {
      _menuOpen = false;
    }
  }

  Widget _compact(BuildContext context, double width) {
    final palette = OrbitaPalette.of(context);
    final style = TextStyle(
      fontSize: 14,
      height: 1.2,
      fontWeight: FontWeight.w600,
      color: palette.text,
    );
    final withLabel =
        _measure(context, 'Разделы', style).width <=
        width - 32 - 24 - 12 - 12 - 24;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Semantics(
        key: const Key('nav-sections'),
        label: 'Разделы. Текущий раздел: ${_labels[selected]}',
        button: true,
        enabled: true,
        onTap: () => _openSections(context),
        child: ExcludeSemantics(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _openSections(context),
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.menu, color: palette.muted),
                      const SizedBox(width: 12),
                      Expanded(
                        child: withLabel
                            ? Text('Разделы', style: style)
                            : const SizedBox.shrink(),
                      ),
                      const SizedBox(width: 12),
                      Tooltip(
                        message: 'Текущий раздел: ${_labels[selected]}',
                        child: Icon(_icons[selected], color: palette.accent),
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
}
