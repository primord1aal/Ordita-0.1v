import 'package:flutter/material.dart';

/// Цвета утверждённой редакции «Лён и бронза».
@immutable
class OrbitaPalette extends ThemeExtension<OrbitaPalette> {
  const OrbitaPalette({
    required this.background,
    required this.surface,
    required this.surfaceVariant,
    required this.text,
    required this.muted,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.outline,
    required this.divider,
    required this.success,
    required this.warning,
    required this.error,
    required this.brandTile,
    required this.brandRing,
    required this.mapLand,
  });

  final Color background, surface, surfaceVariant, text, muted;
  final Color accent, onAccent, accentSoft, outline, divider;
  final Color success, warning, error, brandTile, brandRing, mapLand;

  static const light = OrbitaPalette(
    background: Color(0xffF1F1E8),
    surface: Color(0xffFAFAF4),
    surfaceVariant: Color(0xffE6EADF),
    text: Color(0xff29382F),
    muted: Color(0xff5E6859),
    accent: Color(0xffA6533A),
    onAccent: Color(0xffFFFFFF),
    accentSoft: Color(0xffEEE5D9),
    outline: Color(0xff74806D),
    divider: Color(0xffD3D8CA),
    success: Color(0xff42664A),
    warning: Color(0xff865A24),
    error: Color(0xffA13D36),
    brandTile: Color(0xff29382F),
    brandRing: Color(0xffFAFAF4),
    mapLand: Color(0xffE3E8DC),
  );

  static const dark = OrbitaPalette(
    background: Color(0xff23241F),
    surface: Color(0xff2E3028),
    surfaceVariant: Color(0xff3C4034),
    text: Color(0xffF2F0E5),
    muted: Color(0xffBFC4B0),
    accent: Color(0xffE39272),
    onAccent: Color(0xff29251F),
    accentSoft: Color(0xff414034),
    outline: Color(0xffA0A88F),
    divider: Color(0xff4C5142),
    success: Color(0xffB0C8A4),
    warning: Color(0xffE4C58F),
    error: Color(0xffF0A197),
    brandTile: Color(0xffF2F0E5),
    brandRing: Color(0xff23241F),
    mapLand: Color(0xff30382D),
  );

  static OrbitaPalette of(BuildContext context) =>
      Theme.of(context).extension<OrbitaPalette>()!;

  @override
  OrbitaPalette copyWith({Color? accent}) => OrbitaPalette(
    background: background,
    surface: surface,
    surfaceVariant: surfaceVariant,
    text: text,
    muted: muted,
    accent: accent ?? this.accent,
    onAccent: onAccent,
    accentSoft: accentSoft,
    outline: outline,
    divider: divider,
    success: success,
    warning: warning,
    error: error,
    brandTile: brandTile,
    brandRing: brandRing,
    mapLand: mapLand,
  );

  @override
  OrbitaPalette lerp(ThemeExtension<OrbitaPalette>? other, double t) {
    if (other is! OrbitaPalette) return this;
    return OrbitaPalette(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceVariant: Color.lerp(surfaceVariant, other.surfaceVariant, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      error: Color.lerp(error, other.error, t)!,
      brandTile: Color.lerp(brandTile, other.brandTile, t)!,
      brandRing: Color.lerp(brandRing, other.brandRing, t)!,
      mapLand: Color.lerp(mapLand, other.mapLand, t)!,
    );
  }
}

// Совместимые имена для экранов, переносимых в следующих блоках.
abstract final class OrbitaColors {
  static const background = Color(0xff23241F);
  static const card = Color(0xff2E3028);
  static const accent = Color(0xffE39272);
  static const text = Color(0xffF2F0E5);
  static const muted = Color(0xffBFC4B0);
  static const warning = Color(0xffE4C58F);
}

const appVersion = '0.5.7 · сборка 9';

ThemeData orbitaTheme({Brightness brightness = Brightness.dark}) {
  final p = brightness == Brightness.dark
      ? OrbitaPalette.dark
      : OrbitaPalette.light;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: p.accent,
        brightness: brightness,
      ).copyWith(
        primary: p.accent,
        onPrimary: p.onAccent,
        surface: p.surface,
        onSurface: p.text,
        onSurfaceVariant: p.muted,
        outline: p.outline,
        error: p.error,
        onError: p.surface,
      );
  final buttonStyle = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(48, 52)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    shape: const WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(17)),
      ),
    ),
    textStyle: const WidgetStatePropertyAll(
      TextStyle(fontFamily: 'Inter', fontSize: 15, fontWeight: FontWeight.w600),
    ),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: 'Inter',
    colorScheme: scheme,
    extensions: [p],
    scaffoldBackgroundColor: p.background,
    textTheme: TextTheme(
      headlineMedium: TextStyle(
        fontSize: 26,
        height: 30 / 26,
        fontWeight: FontWeight.w600,
        color: p.text,
      ),
      titleLarge: TextStyle(
        fontSize: 22,
        height: 26 / 22,
        fontWeight: FontWeight.w600,
        color: p.text,
      ),
      titleMedium: TextStyle(
        fontSize: 20,
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: p.text,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.375, color: p.text),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: p.text),
      bodySmall: TextStyle(fontSize: 11, height: 14 / 11, color: p.muted),
      labelLarge: TextStyle(
        fontSize: 15,
        height: 20 / 15,
        fontWeight: FontWeight.w600,
        color: p.onAccent,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: buttonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttonStyle),
    textButtonTheme: TextButtonThemeData(style: buttonStyle),
    cardTheme: CardThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shadowColor: p.text.withValues(alpha: 0.08),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: Color.lerp(p.outline, p.surface, 0.52)!),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Color.lerp(p.surface, p.surfaceVariant, 0.22),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: p.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: p.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: p.accent, width: 2),
      ),
    ),
    dividerTheme: DividerThemeData(color: p.divider, space: 24),
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
