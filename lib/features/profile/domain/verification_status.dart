/// Public verification state stored on the profile. Only the backend changes
/// it; the app reads it.
enum VerificationStatus {
  notStarted('not_started'),

  /// Photo submitted, awaiting review. Not the same as verified.
  pending('pending'),
  verified('verified'),
  rejected('rejected'),
  expired('expired'),
  reverificationRequired('reverification_required');

  const VerificationStatus(this.code);

  final String code;

  /// The verified badge is shown only for an approved verification.
  bool get showsVerifiedBadge => this == verified;

  /// Whether the user may start a (new) verification session.
  bool get canStartVerification => switch (this) {
    notStarted || rejected || expired || reverificationRequired => true,
    pending || verified => false,
  };

  static VerificationStatus? fromCode(String? code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}
