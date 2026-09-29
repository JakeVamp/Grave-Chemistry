/// Central list of route paths so screens never hardcode path strings.
abstract final class AppRoutes {
  static const String home = '/';

  static const String auth = '/auth';
  static const String signUp = '/auth/sign-up';
  static const String forgotPassword = '/auth/forgot-password';
  static const String checkEmail = '/auth/check-email';

  /// Reachable only while recovering a password from an email link.
  static const String resetPassword = '/reset-password';

  /// First-time onboarding; reachable only until the profile is complete.
  static const String profileSetup = '/profile-setup';

  /// Shown while a signed-in user's profile loads, or if loading fails.
  static const String profileLoading = '/profile-loading';

  /// Live photo verification, part of onboarding.
  static const String verification = '/verification';
  static const String verificationRetry = '/verification/retry';
  static const String verificationPending = '/verification/pending';

  static const String discovery = '/discovery';
  static const String matches = '/matches';
  static const String messages = '/messages';
  static const String settings = '/settings';
  static const String profilePhotos = '/profile/photos';

  /// Moderator tools. Hidden from other users; every request is checked
  /// again by the database (moderator role + MFA).
  static const String moderation = '/moderation';
  static const String photoReview = '/moderation/photos';
  static String photoReviewItem(String photoId) => '$photoReview/$photoId';

  static bool isModeratorRoute(String path) =>
      path == moderation || path.startsWith('$moderation/');

  /// The screen Back leads to when there is no page to pop, or null for
  /// root screens. Back is only offered when the router would also allow
  /// the parent (see `back_navigation.dart`), so this map never has to
  /// encode access rules.
  static String? parentOf(String path) {
    if (path == home ||
        path == auth ||
        path == resetPassword ||
        path == profileLoading) {
      return null;
    }
    if (isAuthRoute(path)) return auth;
    // Member onboarding has no earlier step to return to. For moderators,
    // who may open it from Moderator Home, that is where Back goes; the
    // router allows that only for moderators.
    if (path == profileSetup ||
        path == verification ||
        path.startsWith('$verification/')) {
      return moderation;
    }
    if (path == moderation) return home;
    if (path == photoReview) return moderation;
    if (path.startsWith('$photoReview/')) return photoReview;
    return home;
  }

  /// Screens for signed-out users.
  static bool isAuthRoute(String path) =>
      path == auth || path.startsWith('$auth/');
}
