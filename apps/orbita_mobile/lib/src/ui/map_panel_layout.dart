import 'dart:math' as math;

import 'package:flutter/material.dart';

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
      _sheet.animateTo(
        _lastTarget!,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, area) {
      _measureBounds();
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
      final extent = (_extent ?? minimum).clamp(minimum, maximum);
      return SizedBox.expand(
        key: _bounds,
        child: Stack(
          children: [
            Positioned.fill(
              child: widget.mapBuilder(context, extent * available + keyboard),
            ),
            if (widget.overlay != null) widget.overlay!,
            AnimatedPositioned(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
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
