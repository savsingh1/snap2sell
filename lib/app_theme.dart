import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Typeface named by component text styles (buttons, app bar, chips,
/// fields, snackbars). Body text already resolves to Roboto on Android
/// through the platform typography; naming the family here puts the
/// component styles on the same face instead of an unspecified platform
/// default, so type renders consistently on every platform (and in
/// rendered previews, where an unnamed family falls back to a placeholder
/// test font). On platforms without Roboto the engine falls back to the
/// system face, exactly as an unnamed family would.
const String kSnapFontFamily = 'Roboto';

/// Snap2Sell brand palette, sampled from the rebuilt logo artwork:
/// primary purple #5623E2, teal accent #00C9C1, cream #F2ECDE, ink text.
/// Supporting shades are derived from those four, never new hues.
class SnapColors {
  SnapColors._();

  /// Logo purple.
  static const Color primary = Color(0xFF5623E2);

  /// Deepened logo purple, for gradient floors and pressed states.
  static const Color primaryDark = Color(0xFF3D14A8);

  /// Darkest gradient stop (hero surfaces only).
  static const Color primaryDeep = Color(0xFF2A0E73);

  /// Soft lavender tint for chips, icon tiles and placeholders.
  static const Color primaryLight = Color(0xFFEFE9FF);

  /// Logo teal.
  static const Color accent = Color(0xFF00C9C1);

  /// Deep teal: the accent at text/icon size, where the bright logo
  /// teal is too light to read on white. Also the "done/success" colour.
  static const Color accentDark = Color(0xFF007A75);

  /// Teal secondary accent (same logo teal; kept for existing callers).
  static const Color teal = Color(0xFF00C9C1);

  /// Logo cream, for warm hero highlights.
  static const Color cream = Color(0xFFF2ECDE);

  static const Color background = Color(0xFFFAF7FF);
  static const Color card = Colors.white;

  /// Ink near-black.
  static const Color textDark = Color(0xFF17131F);
  static const Color textMuted = Color(0xFF6E6880);

  /// Hairline for cards and fields — definition without shadow weight.
  static const Color border = Color(0xFFE9E3F8);
}

/// Corner-radius scale, shared by the theme and hand-built surfaces so
/// every card, field and sheet rounds by the same amounts.
class SnapRadius {
  SnapRadius._();

  static const double card = 24;
  static const double button = 18;
  static const double input = 16;
  static const double sheet = 28;
  static const double chip = 12;
  static const double thumb = 14;
}

/// Soft, low, purple-tinted shadows. Depth comes from these plus the
/// hairline border, never from heavy grey elevation.
class SnapShadows {
  SnapShadows._();

  static const List<BoxShadow> card = [
    BoxShadow(
      color: Color(0x0F5623E2),
      blurRadius: 16,
      offset: Offset(0, 6),
    ),
  ];

  static const List<BoxShadow> raised = [
    BoxShadow(
      color: Color(0x295623E2),
      blurRadius: 20,
      offset: Offset(0, 8),
    ),
  ];
}

ThemeData buildSnapTheme() {
  const radius = BorderRadius.all(Radius.circular(SnapRadius.card));
  final colorScheme = ColorScheme.fromSeed(
    seedColor: SnapColors.primary,
    primary: SnapColors.primary,
    secondary: SnapColors.accentDark,
    surface: SnapColors.card,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: SnapColors.background,
    splashFactory: InkSparkle.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: ZoomPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      },
    ),
    textTheme: const TextTheme(
      headlineMedium: TextStyle(
        fontFamily: kSnapFontFamily,
        fontSize: 26,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.3,
        height: 1.15,
        color: SnapColors.textDark,
      ),
      titleLarge: TextStyle(
        fontFamily: kSnapFontFamily,
        fontSize: 21,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.2,
        color: SnapColors.textDark,
      ),
      titleMedium: TextStyle(
        fontFamily: kSnapFontFamily,
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: SnapColors.textDark,
      ),
      bodyLarge: TextStyle(
        fontFamily: kSnapFontFamily,
        fontSize: 16,
        height: 1.5,
        color: SnapColors.textDark,
      ),
      bodyMedium: TextStyle(
        fontFamily: kSnapFontFamily,
        fontSize: 14,
        height: 1.45,
        color: SnapColors.textDark,
      ),
      bodySmall: TextStyle(
        fontFamily: kSnapFontFamily,
        fontSize: 12.5,
        height: 1.4,
        color: SnapColors.textMuted,
      ),
      labelLarge: TextStyle(
        fontFamily: kSnapFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: SnapColors.textDark,
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: SnapColors.background,
      foregroundColor: SnapColors.textDark,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: kSnapFontFamily,
        color: SnapColors.textDark,
        fontSize: 22,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.2,
      ),
    ),
    cardTheme: const CardThemeData(
      color: SnapColors.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: SnapColors.border),
      ),
      margin: EdgeInsets.zero,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: SnapColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(56),
        textStyle: const TextStyle(
          fontFamily: kSnapFontFamily,
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SnapRadius.button),
        ),
        elevation: 2,
        shadowColor: const Color(0x335623E2),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: SnapColors.primary,
        minimumSize: const Size.fromHeight(56),
        textStyle: const TextStyle(
          fontFamily: kSnapFontFamily,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
        side: const BorderSide(color: SnapColors.primary, width: 1.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SnapRadius.button),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: SnapColors.primary,
        textStyle: const TextStyle(
          fontFamily: kSnapFontFamily,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(SnapRadius.input),
        borderSide: const BorderSide(color: SnapColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(SnapRadius.input),
        borderSide: const BorderSide(color: SnapColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(SnapRadius.input),
        borderSide: const BorderSide(color: SnapColors.primary, width: 1.6),
      ),
      labelStyle: const TextStyle(
        fontFamily: kSnapFontFamily,
        color: SnapColors.textMuted,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.white,
      selectedColor: SnapColors.primaryLight,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SnapRadius.chip),
      ),
      side: const BorderSide(color: SnapColors.border),
      labelStyle: const TextStyle(fontFamily: kSnapFontFamily),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFFECE7F7),
      thickness: 1,
      space: 1,
    ),
    dialogTheme: const DialogThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(SnapRadius.card)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SnapRadius.input),
      ),
      elevation: 6,
      shadowColor: const Color(0x295623E2),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.white,
      showDragHandle: true,
      dragHandleColor: Color(0xFFD9D2EE),
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(SnapRadius.sheet)),
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Colors.white,
      selectedItemColor: SnapColors.primary,
      unselectedItemColor: SnapColors.textMuted,
      showUnselectedLabels: true,
      type: BottomNavigationBarType.fixed,
      elevation: 12,
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: SnapColors.primary,
      foregroundColor: Colors.white,
      elevation: 4,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: SnapColors.textDark,
      behavior: SnackBarBehavior.floating,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SnapRadius.thumb),
      ),
      contentTextStyle: const TextStyle(
        fontFamily: kSnapFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: Colors.white,
      ),
    ),
  );
}

/// Small logo mark: the official Snap2Sell logo in a white circle.
class SnapLogo extends StatelessWidget {
  const SnapLogo({super.key, this.size = 84});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: SnapColors.primary.withValues(alpha: 0.25),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipOval(
        child: Image.asset(
          'assets/logo.png',
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}
