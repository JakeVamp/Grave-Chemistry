import 'verification_challenge.dart';

/// A short-lived, server-issued session. Photos can only be uploaded into
/// and submitted for an open session owned by the signed-in user.
class VerificationSession {
  const VerificationSession({
    required this.id,
    required this.challengeCode,
    required this.expiresAt,
    required this.attemptNumber,
  });

  final String id;

  /// Raw code from the server, kept even if this app version doesn't know it.
  final String challengeCode;
  final DateTime expiresAt;
  final int attemptNumber;

  VerificationChallenge? get challenge =>
      VerificationChallenge.fromCode(challengeCode);

  /// Instruction to show; falls back for challenges added after this release.
  String get instruction =>
      challenge?.instruction ?? 'Look at the camera and follow the prompt';

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);
}
