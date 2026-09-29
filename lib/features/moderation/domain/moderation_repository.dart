import 'moderator_note.dart';
import 'photo_review_item.dart';
import 'review_media.dart';

enum PhotoDecision { approve, reject, remove }

/// Categories a moderator can escalate to child-safety review.
enum ChildSafetyCategory {
  suspectedCsam('suspected_csam', 'Possible child sexual abuse material'),
  possibleMinor(
    'sexual_content_involving_possible_minor',
    'Sexual content that may involve a minor',
  ),
  underage('underage_user_concern', 'The member may be under 18');

  const ChildSafetyCategory(this.code, this.label);

  final String code;
  final String label;
}

/// Moderator review backend. Every call is checked by the database for the
/// moderator role and MFA; the app never decides access. All methods throw
/// `ModerationFailure` on error.
abstract interface class ModerationRepository {
  Future<List<PhotoReviewItem>> fetchQueue();

  /// Current state of one photo, or null if it is gone or no longer
  /// available to ordinary moderators.
  Future<PhotoReviewItem?> fetchItem(String photoId);

  /// Both photos for side-by-side review. Audited on the server.
  Future<ReviewMedia> loadReviewMedia(String photoId);

  Future<List<ModeratorNote>> fetchNotes(String photoId);

  Future<void> addNote(String photoId, String body);

  Future<void> decide(String photoId, PhotoDecision decision, {String? reason});

  Future<void> retryProcessing(String photoId);

  Future<void> requireReverification(String userId, {String? reason});

  Future<void> escalateToChildSafety(
    String photoId,
    ChildSafetyCategory category,
  );
}
