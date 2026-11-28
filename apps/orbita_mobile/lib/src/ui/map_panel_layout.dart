import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'orbita_brand.dart';
import 'theme.dart';

/// The map never joins the sheet's scroll view. Only the sheet moves, and its
/// visible height also reserves space for map controls, attribution and camera.
class MapPanelLayout extends StatefulWidget {
  const MapPanelLayout({
    required this.mapBuilder,
    required this.panelBuilder,
    required this.compactHeight,
    this.expanded = false,
    this.preferredHeight,
    this.onCollapsed,
    this.overlay,
    this.scrollKey,
    super.key,
  });

  final Widget Function(BuildContext, double coveredHeight) mapBuilder;
  final Widget Function(BuildContext, ScrollController, double visibleMapHeight)
  panelBuilder;
  final double compactHeight;
  final double? preferredHeight;
  final bool expanded;
  final VoidCallback? onCollapsed;
  final Widget? overlay;
  final Key? scrollKey;

  @override
  State<MapPanelLayout> createState() => _MapPanelLayoutState();
}

class _MapPanelLayoutState extends State<MapPanelLayout> {
  final _sheet = DraggableScrollableController();
  final _bounds = GlobalKey();
  double? _extent, _lastTarget;
  double _spaceBelow = 0;
  bool _scheduled = false, _measuring = false, _wasAboveMinimum = false;
  (Size, EdgeInsets, double)? _lastMetrics;
  bool _animateNextTarget = false;

  void _measureBounds() {
    if (_measuring) return;
    _measuring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measuring = false;
      if (!mounted) return;
      final box = _bounds.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final below = math.max(
        0.0,
        MediaQuery.sizeOf(context).height -
            box.localToGlobal(Offset(0, box.size.height)).dy,
      );
      if ((below - _spaceBelow).abs() > .5) {
        setState(() => _spaceBelow = below);
      }
    });
  }

  void _sync(double target) {
    if (_lastTarget == target) return;
    _lastTarget = target;
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !_sheet.isAttached) return;
      if (_animateNextTarget) {
        _sheet.animateTo(
          _lastTarget!,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      } else {
        _sheet.jumpTo(_lastTarget!);
      }
      _animateNextTarget = false;
    });
  }

  @override
  void didUpdateWidget(covariant MapPanelLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    _animateNextTarget = oldWidget.expanded != widget.expanded;
  }

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, area) {
      final metrics = (
        MediaQuery.sizeOf(context),
        MediaQuery.viewInsetsOf(context),
        area.maxHeight,
      );
      if (_lastMetrics != metrics) {
        _lastMetrics = metrics;
        _measureBounds();
      }
      final keyboard = math
          .max(0.0, MediaQuery.viewInsetsOf(context).bottom - _spaceBelow)
          .clamp(0.0, math.max(0.0, area.maxHeight - 80.0))
          .toDouble();
      final available = math.max(80.0, area.maxHeight - keyboard);
      final minimum = (widget.compactHeight / available).clamp(.22, .86);
      const maximum = .94;
      final resting =
          ((widget.preferredHeight ?? widget.compactHeight) / available).clamp(
            minimum,
            maximum,
          );
      final target = widget.expanded ? maximum : resting;
      _sync(target);
      final extent = (_extent ?? target).clamp(minimum, maximum);
      return SizedBox.expand(
        key: _bounds,
        child: Stack(
          children: [
            Positioned.fill(
              child: widget.mapBuilder(context, extent * available + keyboard),
            ),
            if (widget.overlay != null) widget.overlay!,
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              bottom: keyboard,
              child: NotificationListener<DraggableScrollableNotification>(
                onNotification: (notification) {
                  if (((_extent ?? minimum) - notification.extent).abs() >
                      .001) {
                    setState(() => _extent = notification.extent);
                  }
                  if (notification.extent > minimum + .01) {
                    _wasAboveMinimum = true;
                  }
                  if (widget.expanded &&
                      _wasAboveMinimum &&
                      notification.extent <= minimum + .005 &&
                      notification.extent < maximum - .01) {
                    _wasAboveMinimum = false;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && widget.expanded) {
                        widget.onCollapsed?.call();
                      }
                    });
                  }
                  return false;
                },
                child: DraggableScrollableSheet(
                  controller: _sheet,
                  initialChildSize: target,
                  minChildSize: minimum,
                  maxChildSize: maximum,
                  snap: true,
                  snapSizes: resting > minimum && resting < maximum
                      ? [resting]
                      : null,
                  builder: (context, scroll) => Material(
                    key: widget.scrollKey,
                    color: Theme.of(context).colorScheme.surface,
                    elevation: 8,
                    shadowColor: Colors.black26,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(26),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: widget.panelBuilder(
                      context,
                      scroll,
                      area.maxHeight - (extent * available + keyboard),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Keeps the map mounted and gives it the space left by the actual panel.
class MapWorkLayout extends StatelessWidget {
  const MapWorkLayout({
    required this.map,
    required this.panel,
    required this.scrollKey,
    required this.phase,
    this.shift,
    this.searching = false,
    this.animatePanel = true,
    super.key,
  });

  final Widget Function(BuildContext, double height) map;
  final Widget panel;
  final Object phase;
  final Widget? shift;
  final Key scrollKey;
  final bool searching, animatePanel;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, area) {
      final largeText = MediaQuery.textScalerOf(context).scale(16) > 25;
      final mapReserve = math.min(
        searching
            ? 64.0
            : largeText
            ? 430.0
            : 230.0,
        area.maxHeight *
            (searching
                ? .18
                : largeText
                ? .65
                : .45),
      );
      final palette = OrbitaPalette.of(context);
      final motion = animatePanel
          ? OrbitaChrome.motion(context)
          : Duration.zero;
      final workPanel = DecoratedBox(
        decoration: OrbitaChrome.glass(
          context,
          radius: OrbitaChrome.panelShape,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: area.maxHeight - mapReserve),
          child: Material(
            color: Colors.transparent,
            borderRadius: OrbitaChrome.panelShape,
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              key: scrollKey,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: palette.outline.withValues(alpha: .62),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  AnimatedSwitcher(
                    duration: motion,
                    switchInCurve: Curves.easeOutCubic,
                    layoutBuilder: (current, _) =>
                        current ?? const SizedBox.shrink(),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: Tween(begin: .8, end: 1.0).animate(animation),
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0, .025),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: KeyedSubtree(key: ValueKey(phase), child: panel),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, viewport) => Stack(
                fit: StackFit.expand,
                children: [
                  map(context, viewport.maxHeight),
                  if (viewport.maxHeight >= 84)
                    Positioned(
                      top: OrbitaChrome.inset,
                      left: OrbitaChrome.inset,
                      right: OrbitaChrome.inset,
                      child: _MapTopBar(shift: shift),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(
            key: const Key('work-panel'),
            child: motion == Duration.zero
                ? workPanel
                : AnimatedSize(
                    duration: motion,
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.bottomCenter,
                    child: workPanel,
                  ),
          ),
        ],
      );
    },
  );
}

class _MapTopBar extends StatelessWidget {
  const _MapTopBar({this.shift});

  final Widget? shift;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, area) {
      const style = TextStyle(fontSize: 17, fontWeight: FontWeight.w700);
      final textFits =
          textWidth(context, 'орбита.', style) + 56 <=
          (shift == null ? area.maxWidth : area.maxWidth * .39);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DecoratedBox(
            key: const Key('map-brand'),
            decoration: OrbitaChrome.glass(context),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const OrbitaLogo(size: 32),
                  if (textFits) ...[
                    const SizedBox(width: 7),
                    const Text('орбита.', style: style),
                  ],
                ],
              ),
            ),
          ),
          if (shift != null) ...[
            const SizedBox(width: 8),
            Expanded(child: shift!),
          ],
        ],
      );
    },
  );
}
