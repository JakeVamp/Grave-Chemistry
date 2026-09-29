/// Where the current session stands on the MFA that moderator tools need.
sealed class ModeratorMfaStatus {
  const ModeratorMfaStatus();
}

/// The session is MFA-verified (aal2).
final class MfaVerified extends ModeratorMfaStatus {
  const MfaVerified();
}

/// A verified authenticator exists; enter a code to continue.
final class MfaCodeRequired extends ModeratorMfaStatus {
  const MfaCodeRequired(this.factorId);

  final String factorId;
}

/// No authenticator is set up yet.
final class MfaEnrollmentRequired extends ModeratorMfaStatus {
  const MfaEnrollmentRequired();
}

/// A new authenticator waiting for its first code. The secret is shown
/// once so it can be added to an authenticator app; it is never logged.
class TotpEnrollment {
  const TotpEnrollment({required this.factorId, required this.secret});

  final String factorId;
  final String secret;
}

/// All methods throw `ModerationFailure` on error.
abstract interface class ModeratorMfaRepository {
  Future<ModeratorMfaStatus> status();

  Future<TotpEnrollment> enrollTotp();

  /// Verifies a 6-digit code; on success the session becomes aal2.
  Future<void> verifyCode({required String factorId, required String code});
}
