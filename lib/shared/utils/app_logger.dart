import 'dart:developer' as developer;

/// Thin logging wrapper so the backing implementation can be swapped later
/// without touching call sites. Never log secrets or personal data.
abstract final class AppLogger {
  static void info(String message) {
    developer.log(message, name: 'GraveChemistry');
  }

  static void error(String message, {Object? error, StackTrace? stackTrace}) {
    developer.log(
      message,
      name: 'GraveChemistry',
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
  }
}
