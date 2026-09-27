import 'auth_user.dart';

enum AuthEventType {
  signedIn,
  signedOut,
  passwordRecovery,
  userUpdated,

  /// Session restored from storage or token refreshed.
  sessionRefreshed,
}

class AuthEvent {
  const AuthEvent(this.type, this.user);

  final AuthEventType type;
  final AuthUser? user;
}
