import 'package:flutter/material.dart';

abstract final class OrbitaColors {
  static const background = Color(0xff101923);
  static const card = Color(0xff1e2b32);
  static const accent = Color(0xffb4e080);
  static const text = Color(0xffedf3f5);
  static const muted = Color(0xffa9bcc5);
  static const warning = Color(0xffedc58d);
}

const appVersion = '0.5.5 · сборка 7';

ThemeData orbitaTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: OrbitaColors.accent,
        brightness: Brightness.dark,
      ).copyWith(
        primary: OrbitaColors.accent,
        onPrimary: const Color(0xff16240e),
        surface: OrbitaColors.card,
        onSurface: OrbitaColors.text,
        onSurfaceVariant: OrbitaColors.muted,
      );
  final buttonStyle = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    textStyle: WidgetStatePropertyAll(
      ThemeData(brightness: Brightness.dark).textTheme.labelLarge!
          .copyWith(fontSize: 15, fontWeight: FontWeight.w700),
    ),
    shape: const WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
    ),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: OrbitaColors.background,
    textTheme: const TextTheme(
      bodyLarge: TextStyle(fontSize: 16, height: 1.4, color: OrbitaColors.text),
      bodyMedium: TextStyle(
        fontSize: 14,
        height: 1.4,
        color: OrbitaColors.muted,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        height: 1.25,
        fontWeight: FontWeight.w700,
        color: OrbitaColors.text,
      ),
      titleMedium: TextStyle(
        fontSize: 17,
        height: 1.3,
        fontWeight: FontWeight.w700,
        color: OrbitaColors.text,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: buttonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttonStyle),
    textButtonTheme: TextButtonThemeData(style: buttonStyle),
    cardTheme: const CardThemeData(
      color: OrbitaColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xff16232b),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: OrbitaColors.accent, width: 2),
      ),
    ),
    dividerTheme: const DividerThemeData(color: Color(0xff31434b), space: 24),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

double textWidth(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: DefaultTextStyle.of(context).style.merge(style),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}
