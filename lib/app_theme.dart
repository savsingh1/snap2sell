import 'package:flutter/material.dart';

/// Snap2Sell brand palette, taken from the investor pitch deck:
/// deep purple primary, teal/mint accent, white backgrounds, rounded cards.
class SnapColors {
  SnapColors._();

  static const Color primary = Color(0xFF5E00D6);
  static const Color primaryDark = Color(0xFF4600A8);
  static const Color primaryLight = Color(0xFFF1E8FF);

  /// Mint accent from the deck (#4ADE80-ish).
  static const Color accent = Color(0xFF4ADE80);
  static const Color accentDark = Color(0xFF22C55E);

  /// Teal secondary accent.
  static const Color teal = Color(0xFF2DD4BF);

  static const Color background = Color(0xFFF7F5FF);
  static const Color card = Colors.white;
  static const Color textDark = Color(0xFF1E1B2E);
  static const Color textMuted = Color(0xFF6B6580);
}

ThemeData buildSnapTheme() {
  const radius = BorderRadius.all(Radius.circular(20));
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
    appBarTheme: const AppBarTheme(
      backgroundColor: SnapColors.background,
      foregroundColor: SnapColors.textDark,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: SnapColors.textDark,
        fontSize: 22,
        fontWeight: FontWeight.w800,
      ),
    ),
    cardTheme: const CardThemeData(
      color: SnapColors.card,
      elevation: 2,
      shadowColor: Color(0x1A5E00D6),
      shape: RoundedRectangleBorder(borderRadius: radius),
      margin: EdgeInsets.zero,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: SnapColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(56),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        elevation: 3,
        shadowColor: const Color(0x665E00D6),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: SnapColors.primary,
        minimumSize: const Size.fromHeight(56),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        side: const BorderSide(color: SnapColors.primary, width: 1.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: SnapColors.primary,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFFE4E0F2)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFFE4E0F2)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: SnapColors.primary, width: 1.6),
      ),
      labelStyle: const TextStyle(color: SnapColors.textMuted),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
      elevation: 6,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
