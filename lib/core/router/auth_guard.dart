import '../../features/auth/domain/auth_status.dart';
import '../../features/profile/application/profile_providers.dart';
import 'app_routes.dart';

/// Decides where a user may be, given their auth status and, once signed in,
/// the state of their profile.
///
/// Returns the path to redirect to, or `null` to allow [path]. Every
/// redirect target is itself allowed for the same inputs, so applying the
/// guard twice always yields `null`, which makes redirect loops impossible.
/// `auth_guard_test.dart` checks this for every route and state.
String? authGuard(AuthStatus status, ProfileGate profile, String path) {
  final onAuthRoute = AppRoutes.isAuthRoute(path);

  switch (status) {
    case PasswordRecovery():
      return path == AppRoutes.resetPassword ? null : AppRoutes.resetPassword;
    case SignedOut():
      return onAuthRoute ? null : AppRoutes.auth;
    case SignedIn():
      final allowed = switch (profile) {
        ProfileGate.loading || ProfileGate.error => AppRoutes.profileLoading,
        ProfileGate.incomplete => AppRoutes.profileSetup,
        ProfileGate.complete => null,
      };
      if (allowed != null) return path == allowed ? null : allowed;

      // Profile complete: anywhere in the app except the gating screens.
      final isGatingRoute =
          onAuthRoute ||
          path == AppRoutes.resetPassword ||
          path == AppRoutes.profileLoading ||
          path == AppRoutes.profileSetup;
      return isGatingRoute ? AppRoutes.home : null;
  }
}
