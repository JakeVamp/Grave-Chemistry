enum AuthFailureType {
  invalidCredentials,
  emailNotConfirmed,
  emailAlreadyRegistered,
  invalidEmail,
  weakPassword,
  samePassword,
  signUpDisabled,
  rateLimited,
  network,
  linkExpired,
  linkInvalid,
  sessionExpired,
  unknown,
}

/// An auth error with a message that is safe to show to the user.
class AuthFailure implements Exception {
  const AuthFailure(this.type, this.message);

  final AuthFailureType type;
  final String message;

  bool get isLinkFailure =>
      type == AuthFailureType.linkExpired ||
      type == AuthFailureType.linkInvalid;

  @override
  String toString() => 'AuthFailure(${type.name}): $message';
}
