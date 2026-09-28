enum VerificationFailureType {
  permissionDenied,
  permissionPermanentlyDenied,
  permissionRestricted,
  cameraUnavailable,
  captureFailed,
  uploadFailed,
  sessionExpired,
  alreadySubmitted,
  notEligible,
  rateLimited,
  tooManyAttempts,
  network,
  unknown,
}

/// A verification error with a message that is safe to show to the user.
/// Never contains image data, URLs, paths or tokens.
class VerificationFailure implements Exception {
  const VerificationFailure(this.type, this.message);

  final VerificationFailureType type;
  final String message;

  /// Failures fixed by starting over with a new session.
  bool get needsNewSession =>
      type == VerificationFailureType.sessionExpired ||
      type == VerificationFailureType.unknown;

  @override
  String toString() => 'VerificationFailure(${type.name})';
}
