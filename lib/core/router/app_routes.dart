/// Central list of route paths so screens never hardcode path strings.
abstract final class AppRoutes {
  static const String home = '/';

  static const String auth = '/auth';
  static const String signUp = '/auth/sign-up';
  static const String forgotPassword = '/auth/forgot-password';
  static const String checkEmail = '/auth/check-email';

  /// Reachable only while recovering a password from an email link.
  static const String resetPassword = '/reset-password';

  static const String profileSetup = '/profile-setup';
  static const String discovery = '/discovery';
  static const String matches = '/matches';
  static const String messages = '/messages';
  static const String settings = '/settings';

  /// Screens for signed-out users.
  static bool isAuthRoute(String path) =>
      path == auth || path.startsWith('$auth/');
}
