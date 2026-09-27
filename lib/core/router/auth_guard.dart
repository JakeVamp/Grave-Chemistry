import '../../features/auth/domain/auth_status.dart';
import 'app_routes.dart';

/// Decides where a user may be, given their auth status.
///
/// Returns the path to redirect to, or `null` to allow [path]. Every
/// redirect target is itself allowed for the same status, so applying the
/// guard twice always yields `null` — redirect loops are impossible.
String? authGuard(AuthStatus status, String path) {
  final onAuthRoute = AppRoutes.isAuthRoute(path);
  final onResetPassword = path == AppRoutes.resetPassword;

  return switch (status) {
    PasswordRecovery() => onResetPassword ? null : AppRoutes.resetPassword,
    SignedOut() => onAuthRoute ? null : AppRoutes.auth,
    SignedIn() => onAuthRoute || onResetPassword ? AppRoutes.home : null,
  };
}
