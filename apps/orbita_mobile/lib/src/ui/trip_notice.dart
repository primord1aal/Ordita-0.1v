import 'package:flutter/material.dart';

import 'theme.dart';

ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showTripNotice(
  BuildContext context,
  String title, {
  required IconData icon,
  String? subtitle,
  Duration duration = const Duration(seconds: 5),
  SnackBarAction? action,
}) {
  final palette = OrbitaPalette.of(context);
  final motion = OrbitaChrome.motion(context);
  return ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      duration: duration,
      behavior: SnackBarBehavior.floating,
      backgroundColor: palette.surface,
      elevation: 0,
      showCloseIcon: action == null,
      closeIconColor: palette.muted,
      action: action,
      shape: RoundedRectangleBorder(
        borderRadius: OrbitaChrome.controlShape,
        side: BorderSide(color: palette.divider),
      ),
      content: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: palette.accentSoft,
              borderRadius: OrbitaChrome.controlShape,
            ),
            child: Padding(
              padding: const EdgeInsets.all(9),
              child: Icon(icon, color: palette.accent, size: 22),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: palette.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null)
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    ),
    snackBarAnimationStyle: motion == Duration.zero
        ? AnimationStyle.noAnimation
        : AnimationStyle(duration: motion, reverseDuration: motion),
  );
}
