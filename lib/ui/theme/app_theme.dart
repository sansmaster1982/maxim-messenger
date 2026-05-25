import 'package:flutter/material.dart';

/// Цвета и тема под фирменный стиль MAX (oneme.ru).
class MaxColors {
  static const primary = Color(0xFF0066FF);
  static const primaryDark = Color(0xFF0052CC);
  static const accent = Color(0xFF00C2FF);
  static const success = Color(0xFF34C759);
  static const danger = Color(0xFFFF3B30);
  static const bgLight = Color(0xFFFFFFFF);
  static const bgLightSecondary = Color(0xFFF6F7FB);
  static const bgDark = Color(0xFF0E1117);
  static const bgDarkSecondary = Color(0xFF1A1F2A);
  static const dividerLight = Color(0xFFE7E9F0);
  static const dividerDark = Color(0xFF22293A);
  static const textSecondaryLight = Color(0xFF8A8F99);
  static const textSecondaryDark = Color(0xFFA1A8B5);
}

class AppTheme {
  static ThemeData light() {
    final base = ThemeData(useMaterial3: true, brightness: Brightness.light);
    final scheme = ColorScheme.fromSeed(
      seedColor: MaxColors.primary,
      brightness: Brightness.light,
    ).copyWith(
      primary: MaxColors.primary,
      surface: MaxColors.bgLight,
      surfaceContainerHighest: MaxColors.bgLightSecondary,
      error: MaxColors.danger,
      outlineVariant: MaxColors.dividerLight,
    );
    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      dividerColor: MaxColors.dividerLight,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        elevation: 0,
        height: 64,
        indicatorColor: scheme.primary.withValues(alpha: 0.12),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : MaxColors.textSecondaryLight,
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: Colors.white,
        elevation: 2,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: MaxColors.bgLightSecondary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        isDense: true,
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      ),
    );
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: MaxColors.primary,
      brightness: Brightness.dark,
    ).copyWith(
      primary: MaxColors.primary,
      surface: MaxColors.bgDark,
      surfaceContainerHighest: MaxColors.bgDarkSecondary,
      error: MaxColors.danger,
      outlineVariant: MaxColors.dividerDark,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      dividerColor: MaxColors.dividerDark,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        elevation: 0,
        height: 64,
        indicatorColor: scheme.primary.withValues(alpha: 0.18),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : MaxColors.textSecondaryDark,
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: Colors.white,
        elevation: 2,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: MaxColors.bgDarkSecondary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        isDense: true,
      ),
    );
  }
}
