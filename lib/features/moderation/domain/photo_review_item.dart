import '../../profile/domain/verification_status.dart';

enum ReviewState {
  awaitingReview('awaiting_review'),
  processingFailed('processing_failed'),

  /// Being processed again (e.g. another moderator restarted it).
  processing('processing'),

  /// Already approved, rejected or removed.
  decided('decided');

  const ReviewState(this.code);

  final String code;

  static ReviewState fromCode(String? code) => values.firstWhere(
    (value) => value.code == code,
    // Unknown states can't be acted on (fail closed).
    orElse: () => decided,
  );
}

/// Whether the photo matches another account's photo. The fingerprints
/// themselves never reach the app.
enum DuplicateMatch {
  exact('exact'),
  similar('similar');

  const DuplicateMatch(this.code);

  final String code;

  static DuplicateMatch? fromCode(String? code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}

/// One photo in the moderator review queue: only what a moderator needs to
/// decide. No storage paths, hashes, provider data or child-safety details.
class PhotoReviewItem {
  const PhotoReviewItem({
    required this.photoId,
    required this.ownerId,
    required this.uploadedAt,
    required this.displayName,
    required this.age,
    required this.verificationStatus,
    required this.hasReviewSignals,
    required this.duplicateMatch,
    required this.contentFlagged,
    required this.automatedChecksIncomplete,
    required this.reviewState,
    required this.canApprove,
    required this.canRetry,
  });

  final String photoId;
  final String ownerId;
  final DateTime uploadedAt;
  final String? displayName;
  final int? age;
  final VerificationStatus? verificationStatus;

  /// The account has open trust & safety review signals.
  final bool hasReviewSignals;
  final DuplicateMatch? duplicateMatch;

  /// Automated moderation asked for a human decision.
  final bool contentFlagged;

  /// Some automated checks couldn't run, so this review is the only check.
  final bool automatedChecksIncomplete;
  final ReviewState reviewState;

  /// Server hints; the database enforces them again on every action.
  final bool canApprove;
  final bool canRetry;

  /// Whether a moderator can still act on this photo.
  bool get isOpen =>
      reviewState == ReviewState.awaitingReview ||
      reviewState == ReviewState.processingFailed;
}
