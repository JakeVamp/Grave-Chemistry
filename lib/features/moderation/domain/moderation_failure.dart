enum ModerationFailureType {
  /// Not a moderator, or the session isn't MFA-verified.
  notAuthorized,

  /// The photo was already handled or changed, or is no longer available.
  unavailable,

  /// The database refused the action (a safety condition isn't met).
  refused,

  /// The photos couldn't be loaded securely (e.g. an expired link).
  mediaUnavailable,
  network,
  unknown,
}

/// A moderation error with a message that is safe to show. Database error
/// text is never shown.
class ModerationFailure implements Exception {
  const ModerationFailure(this.type, this.message);

  final ModerationFailureType type;
  final String message;

  @override
  String toString() => 'ModerationFailure(${type.name})';
}
