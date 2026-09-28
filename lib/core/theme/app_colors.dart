import 'package:flutter/material.dart';

/// Base palette for the dark gothic direction. Placeholder values until
/// final brand design is approved.
abstract final class AppColors {
  static const Color background = Color(0xFF0B0B0D);
  static const Color surface = Color(0xFF16161A);
  static const Color surfaceRaised = Color(0xFF212126);
  static const Color outline = Color(0xFF3A3A42);

  static const Color primary = Color(0xFF8B1E2D);
  static const Color primaryBright = Color(0xFFB3263A);
  static const Color secondary = Color(0xFF5C1320);

  /// Lighter burgundy for text links, icons and selected controls on dark
  /// surfaces. Meets WCAG AA contrast (4.5:1) on background, surface and
  /// surfaceRaised, which [primary] and [primaryBright] do not.
  static const Color accentText = Color(0xFFE35D70);

  static const Color textPrimary = Color(0xFFEDEAE6);
  static const Color textSecondary = Color(0xFFA9A4A0);

  static const Color error = Color(0xFFE5484D);
}
