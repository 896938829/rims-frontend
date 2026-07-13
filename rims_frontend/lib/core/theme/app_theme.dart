import 'package:flutter/material.dart';

import 'app_colors.dart';

abstract final class AppTheme {
  static ThemeData get light {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: AppColors.background,
      fontFamily: 'Roboto',
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      extensions: const [OfflineStatusBandTheme.light],
    );
  }

  static ThemeData get dark {
    const colorScheme = ColorScheme.dark(
      primary: Color(0xFF8AB4FF),
      secondary: Color(0xFF69D6B6),
      surface: Color(0xFF172033),
      error: Color(0xFFFFB4AB),
      onPrimary: Color(0xFF002E69),
      onSurface: Color(0xFFE6ECF7),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: const Color(0xFF0E1524),
      fontFamily: 'Roboto',
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0E1524),
        foregroundColor: Color(0xFFE6ECF7),
        elevation: 0,
        centerTitle: false,
      ),
      extensions: const [OfflineStatusBandTheme.dark],
    );
  }
}

@immutable
final class OfflineStatusBandTheme
    extends ThemeExtension<OfflineStatusBandTheme> {
  const OfflineStatusBandTheme({
    required this.background,
    required this.foreground,
    required this.successForeground,
    required this.warningForeground,
  });

  static const light = OfflineStatusBandTheme(
    background: Color(0xFFEAF3FF),
    foreground: Color(0xFF28466F),
    successForeground: Color(0xFF087A59),
    warningForeground: Color(0xFF9A5B00),
  );

  static const dark = OfflineStatusBandTheme(
    background: Color(0xFF1C2B42),
    foreground: Color(0xFFD5E3F8),
    successForeground: Color(0xFF71DDBB),
    warningForeground: Color(0xFFFFC46B),
  );

  final Color background;
  final Color foreground;
  final Color successForeground;
  final Color warningForeground;

  @override
  OfflineStatusBandTheme copyWith({
    Color? background,
    Color? foreground,
    Color? successForeground,
    Color? warningForeground,
  }) {
    return OfflineStatusBandTheme(
      background: background ?? this.background,
      foreground: foreground ?? this.foreground,
      successForeground: successForeground ?? this.successForeground,
      warningForeground: warningForeground ?? this.warningForeground,
    );
  }

  @override
  OfflineStatusBandTheme lerp(
    covariant ThemeExtension<OfflineStatusBandTheme>? other,
    double t,
  ) {
    if (other is! OfflineStatusBandTheme) return this;
    return OfflineStatusBandTheme(
      background: Color.lerp(background, other.background, t)!,
      foreground: Color.lerp(foreground, other.foreground, t)!,
      successForeground: Color.lerp(
        successForeground,
        other.successForeground,
        t,
      )!,
      warningForeground: Color.lerp(
        warningForeground,
        other.warningForeground,
        t,
      )!,
    );
  }
}
