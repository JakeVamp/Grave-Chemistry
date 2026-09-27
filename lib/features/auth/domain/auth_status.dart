import 'auth_user.dart';

sealed class AuthStatus {
  const AuthStatus();
}

final class SignedOut extends AuthStatus {
  const SignedOut();

  @override
  bool operator ==(Object other) => other is SignedOut;

  @override
  int get hashCode => (SignedOut).hashCode;
}

final class SignedIn extends AuthStatus {
  const SignedIn(this.user);

  final AuthUser user;

  @override
  bool operator ==(Object other) => other is SignedIn && other.user == user;

  @override
  int get hashCode => Object.hash(SignedIn, user);
}

/// The user opened a password-reset link. They hold a temporary session but
/// must set a new password before entering the app.
final class PasswordRecovery extends AuthStatus {
  const PasswordRecovery(this.user);

  final AuthUser user;

  @override
  bool operator ==(Object other) =>
      other is PasswordRecovery && other.user == user;

  @override
  int get hashCode => Object.hash(PasswordRecovery, user);
}
