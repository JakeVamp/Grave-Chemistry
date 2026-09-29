import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/utils/app_logger.dart';
import '../../profile/domain/verification_status.dart';
import '../domain/moderation_repository.dart';
import '../domain/moderator_note.dart';
import '../domain/photo_review_item.dart';
import '../domain/review_media.dart';
import 'moderation_error_mapper.dart';
import 'review_media_loader.dart';

/// Moderator RPCs. The database checks the moderator role and MFA on every
/// call; this class only moves data.
class SupabaseModerationRepository implements ModerationRepository {
  SupabaseModerationRepository(this._client, this._mediaLoader);

  static const reviewMediaFunction = 'moderator-review-media';
  static const _timeout = Duration(seconds: 30);

  final SupabaseClient _client;
  final ReviewMediaLoader _mediaLoader;

  @override
  Future<List<PhotoReviewItem>> fetchQueue() async {
    final rows = await _call(
      () => _client.rpc<dynamic>('moderator_photo_review_queue'),
    );
    return [
      for (final row in (rows as List).cast<Map<String, dynamic>>())
        photoReviewItemFromRow(row),
    ];
  }

  @override
  Future<PhotoReviewItem?> fetchItem(String photoId) async {
    final rows = await _call(
      () => _client.rpc<dynamic>(
        'moderator_photo_review_item',
        params: {'p_photo_id': photoId},
      ),
    );
    final list = (rows as List).cast<Map<String, dynamic>>();
    return list.isEmpty ? null : photoReviewItemFromRow(list.first);
  }

  @override
  Future<ReviewMedia> loadReviewMedia(String photoId) =>
      _call(() => _mediaLoader.load(photoId));

  @override
  Future<List<ModeratorNote>> fetchNotes(String photoId) async {
    final rows = await _call(
      () => _client.rpc<dynamic>(
        'moderator_photo_notes',
        params: {'p_photo_id': photoId},
      ),
    );
    return [
      for (final row in (rows as List).cast<Map<String, dynamic>>())
        ModeratorNote(
          id: (row['note_id'] as num).toInt(),
          body: row['body'] as String,
          moderatorId: row['moderator_id'] as String,
          createdAt: DateTime.parse(row['created_at'] as String),
        ),
    ];
  }

  @override
  Future<void> addNote(String photoId, String body) => _call(
    () => _client.rpc<dynamic>(
      'moderator_add_photo_note',
      params: {'p_photo_id': photoId, 'p_body': body},
    ),
  );

  @override
  Future<void> decide(
    String photoId,
    PhotoDecision decision, {
    String? reason,
  }) => _call(
    () => _client.rpc<dynamic>(
      'moderate_profile_photo',
      params: {
        'p_photo_id': photoId,
        'p_decision': decision.name,
        'p_reason': reason,
      },
    ),
  );

  @override
  Future<void> retryProcessing(String photoId) => _call(
    () => _client.rpc<dynamic>(
      'moderator_retry_photo_processing',
      params: {'p_photo_id': photoId},
    ),
  );

  @override
  Future<void> requireReverification(String userId, {String? reason}) => _call(
    () => _client.rpc<dynamic>(
      'moderate_user',
      params: {
        'p_user_id': userId,
        'p_action': 'require_reverification',
        'p_reason': reason ?? 'Photo review',
      },
    ),
  );

  @override
  Future<void> escalateToChildSafety(
    String photoId,
    ChildSafetyCategory category,
  ) => _call(
    () => _client.rpc<dynamic>(
      'flag_media_for_child_safety',
      params: {'p_media_asset_id': photoId, 'p_category': category.code},
    ),
  );

  Future<T> _call<T>(Future<T> Function() action) async {
    try {
      return await action().timeout(_timeout);
    } catch (error) {
      AppLogger.error('Moderation request failed (${error.runtimeType})');
      throw mapModerationError(error);
    }
  }
}

/// Signed URLs for review, via the Edge Function (as the moderator).
Future<Map<String, dynamic>> requestReviewUrls(
  SupabaseClient client,
  String photoId,
) async {
  final response = await client.functions.invoke(
    SupabaseModerationRepository.reviewMediaFunction,
    body: {'photo_id': photoId},
  );
  final data = response.data;
  if (response.status != 200 || data is! Map) {
    throw mediaUnavailableFailure;
  }
  return Map<String, dynamic>.from(data);
}

PhotoReviewItem photoReviewItemFromRow(Map<String, dynamic> row) {
  return PhotoReviewItem(
    photoId: row['photo_id'] as String,
    ownerId: row['owner_id'] as String,
    uploadedAt: DateTime.parse(row['uploaded_at'] as String),
    displayName: row['display_name'] as String?,
    age: (row['age'] as num?)?.toInt(),
    verificationStatus: VerificationStatus.fromCode(
      row['verification_status'] as String?,
    ),
    hasReviewSignals: row['has_review_signals'] as bool? ?? false,
    duplicateMatch: DuplicateMatch.fromCode(row['duplicate_match'] as String?),
    contentFlagged: row['content_flagged'] as bool? ?? false,
    automatedChecksIncomplete:
        row['automated_checks_incomplete'] as bool? ?? true,
    reviewState: ReviewState.fromCode(row['review_state'] as String?),
    // Missing hints mean "no" (fail closed).
    canApprove: row['can_approve'] as bool? ?? false,
    canRetry: row['can_retry'] as bool? ?? false,
  );
}
