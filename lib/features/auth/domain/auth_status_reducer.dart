import 'auth_event.dart';
import 'auth_status.dart';

/// Pure state transition for auth events.
///
/// While in [PasswordRecovery], session events keep the user in recovery
/// until the password is updated (`userUpdated`) or they sign out.
AuthStatus reduceAuthStatus(AuthStatus current, AuthEvent event) {
  final user = event.user;
  if (event.type == AuthEventType.signedOut || user == null) {
    return const SignedOut();
  }

  return switch (event.type) {
    AuthEventType.passwordRecovery => PasswordRecovery(user),
    AuthEventType.userUpdated => SignedIn(user),
    AuthEventType.signedIn || AuthEventType.sessionRefreshed =>
      current is PasswordRecovery ? PasswordRecovery(user) : SignedIn(user),
    AuthEventType.signedOut => const SignedOut(),
  };
}
