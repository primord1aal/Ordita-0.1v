import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Запрашивает изменение, но подтверждённое состояние всегда получает снаружи.
/// В обычном рабочем режиме callback отсутствует до подключения сервера.
class ShiftControl extends StatefulWidget {
  const ShiftControl({
    this.confirmedOnline = false,
    this.available = false,
    this.requestChange,
    super.key,
  });

  final bool confirmedOnline, available;
  final Future<void> Function(bool online)? requestChange;

  @override
  State<ShiftControl> createState() => _ShiftControlState();
}

class _ShiftControlState extends State<ShiftControl> {
  final _focus = FocusNode();
  bool _focused = false, _dragging = false, _pending = false;
  double _offset = 0, _startX = 0, _startOffset = 0;
  int _generation = 0;
  String? _error;

  bool get _enabled => widget.available && widget.requestChange != null;
  bool get _interactive => _enabled && !_pending;

  @override
  void didUpdateWidget(covariant ShiftControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.available != widget.available ||
        oldWidget.confirmedOnline != widget.confirmedOnline ||
        (oldWidget.requestChange != null && widget.requestChange == null)) {
      ++_generation;
      _pending = false;
      _dragging = false;
      _error = null;
    }
  }

  @override
  void dispose() {
    ++_generation;
    _focus.dispose();
    super.dispose();
  }

  Future<void> _request() async {
    if (!_interactive) return;
    final generation = ++_generation;
    final request = widget.requestChange!;
    final target = !widget.confirmedOnline;
    setState(() {
      _dragging = false;
      _pending = true;
      _error = null;
    });
    try {
      await request(target);
      if (!mounted || generation != _generation || !_enabled) return;
      setState(() => _pending = false);
    } catch (_) {
      if (!mounted || generation != _generation || !_enabled) return;
      setState(() {
        _pending = false;
        _error = 'Не удалось изменить статус. Попробуй ещё раз.';
      });
    }
  }

  void _cancelDrag() {
    if (_dragging) setState(() => _dragging = false);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!_interactive || event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _cancelDrag();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        (!widget.confirmedOnline && key == LogicalKeyboardKey.arrowRight) ||
        (widget.confirmedOnline && key == LogicalKeyboardKey.arrowLeft)) {
      _request();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  double _height(
    BuildContext context,
    String label,
    String hint,
    double width,
  ) {
    double measure(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: math.max(1, width - 132));
      final height = painter.height;
      painter.dispose();
      return height;
    }

    return math.max(
      64,
      measure(label, _titleStyle) + measure(hint, _hintStyle) + 22,
    );
  }

  static const _titleStyle = TextStyle(
    fontSize: 14,
    height: 1.2,
    fontWeight: FontWeight.w700,
  );
  static const _hintStyle = TextStyle(fontSize: 11, height: 1.3);

  @override
  Widget build(BuildContext context) {
    final palette = OrbitaPalette.of(context);
    final label = _pending
        ? 'Подтверждаем…'
        : !_enabled
        ? 'Линия не подключена'
        : widget.confirmedOnline
        ? 'На линии'
        : 'Не на линии';
    final hint = _pending
        ? 'Дождись подтверждения'
        : !_enabled
        ? 'Изменение линии пока не подключено'
        : widget.confirmedOnline
        ? 'Проведи влево'
        : 'Проведи вправо';
    final action = widget.confirmedOnline
        ? 'Запросить выход с линии'
        : 'Запросить выход на линию';
    return Focus(
      focusNode: _focus,
      onFocusChange: (value) => setState(() => _focused = value),
      onKeyEvent: _key,
      child: Semantics(
        key: const Key('shift-control'),
        label: '$label. $hint',
        hint: _interactive ? '$action. Двойное нажатие заменяет жест.' : null,
        button: true,
        enabled: _interactive,
        focusable: true,
        focused: _focused,
        liveRegion: _pending || _error != null,
        onTap: _interactive ? _request : null,
        onIncrease: _interactive && !widget.confirmedOnline ? _request : null,
        onDecrease: _interactive && widget.confirmedOnline ? _request : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const thumbSize = 48.0;
                  final travel = math.max(
                    0.0,
                    constraints.maxWidth - thumbSize - 16,
                  );
                  final rest = widget.confirmedOnline ? travel : 0.0;
                  final position = _dragging
                      ? _offset.clamp(0.0, travel)
                      : _pending
                      ? (widget.confirmedOnline ? 0.0 : travel)
                      : rest;
                  return Container(
                    key: const Key('shift-track'),
                    height: _height(context, label, hint, constraints.maxWidth),
                    decoration: BoxDecoration(
                      color: widget.confirmedOnline
                          ? palette.accentSoft
                          : palette.surfaceVariant,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _error != null
                            ? palette.error
                            : _focused
                            ? palette.accent
                            : palette.outline,
                        width: _focused || _error != null ? 2 : 1,
                      ),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 64,
                            vertical: 8,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                label,
                                textAlign: TextAlign.center,
                                style: _titleStyle.copyWith(
                                  color: palette.text,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                hint,
                                textAlign: TextAlign.center,
                                style: _hintStyle.copyWith(
                                  color: palette.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Positioned(
                          left: 8 + position,
                          child: Listener(
                            onPointerCancel: (_) => _cancelDrag(),
                            child: GestureDetector(
                              key: const Key('shift-thumb'),
                              dragStartBehavior: DragStartBehavior.down,
                              behavior: HitTestBehavior.opaque,
                              onHorizontalDragStart: !_interactive
                                  ? null
                                  : (details) {
                                      _focus.requestFocus();
                                      setState(() {
                                        _dragging = true;
                                        _startX = details.globalPosition.dx;
                                        _startOffset = rest;
                                        _offset = rest;
                                        _error = null;
                                      });
                                    },
                              onHorizontalDragUpdate: !_interactive
                                  ? null
                                  : (details) {
                                      if (!_dragging) return;
                                      setState(
                                        () => _offset =
                                            (_startOffset +
                                                    details.globalPosition.dx -
                                                    _startX)
                                                .clamp(0.0, travel),
                                      );
                                    },
                              onHorizontalDragCancel: _cancelDrag,
                              onHorizontalDragEnd: !_interactive
                                  ? null
                                  : (_) {
                                      if (!_dragging) return;
                                      final passed =
                                          travel > 0 &&
                                          (widget.confirmedOnline
                                                      ? travel - _offset
                                                      : _offset) /
                                                  travel >=
                                              0.86;
                                      if (passed) {
                                        _request();
                                      } else {
                                        _cancelDrag();
                                      }
                                    },
                              child: Container(
                                width: thumbSize,
                                height: thumbSize,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: widget.confirmedOnline
                                      ? palette.accent
                                      : palette.surface,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: palette.outline),
                                ),
                                child: _pending
                                    ? SizedBox.square(
                                        dimension: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: palette.text,
                                        ),
                                      )
                                    : Icon(
                                        widget.confirmedOnline
                                            ? Icons.power_settings_new
                                            : Icons.arrow_forward,
                                        color: widget.confirmedOnline
                                            ? palette.onAccent
                                            : palette.text,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _error!,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: palette.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
