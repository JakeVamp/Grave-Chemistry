import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/supabase/supabase_providers.dart';
import '../data/moderation_error_mapper.dart';
import '../data/review_media_loader.dart';
import '../data/screen_security.dart';
import '../data/supabase_moderation_repository.dart';
import '../data/supabase_moderator_mfa_repository.dart';
import '../domain/moderation_failure.dart';
import '../domain/moderation_repository.dart';
import '../domain/moderator_mfa.dart';
import '../domain/moderator_note.dart';
import '../domain/photo_review_item.dart';
import '../domain/review_media.dart';

final moderationRepositoryProvider = Provider<ModerationRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  final httpClient = http.Client();
  ref.onDispose(httpClient.close);
  return SupabaseModerationRepository(
    client,
    ReviewMediaLoader(
      (photoId) => requestReviewUrls(client, photoId),
      httpClient,
    ),
  );
});

final moderatorMfaRepositoryProvider = Provider<ModeratorMfaRepository>(
  (ref) =>
      SupabaseModeratorMfaRepository(ref.watch(supabaseClientProvider).auth),
);

final screenSecurityProvider = Provider<ScreenSecurity>(
  (ref) => PlatformScreenSecurity(),
);

// Failures are shown with a retry button; no automatic retries.
Duration? _noRetry(int retryCount, Object error) => null;

final moderatorMfaProvider =
    AsyncNotifierProvider.autoDispose<
      ModeratorMfaController,
      ModeratorMfaStatus
    >(ModeratorMfaController.new, retry: _noRetry);

final photoReviewQueueProvider =
    AsyncNotifierProvider.autoDispose<
      PhotoReviewQueueController,
      List<PhotoReviewItem>
    >(PhotoReviewQueueController.new, retry: _noRetry);

final photoReviewProvider = AsyncNotifierProvider.autoDispose
    .family<PhotoReviewController, PhotoReviewDetail, String>(
      PhotoReviewController.new,
      retry: _noRetry,
    );

/// The two photos for one review. Auto-disposed with the screen, so the
/// image bytes don't outlive it.
final reviewMediaProvider = FutureProvider.autoDispose
    .family<ReviewMedia, String>(
      (ref, photoId) =>
          ref.watch(moderationRepositoryProvider).loadReviewMedia(photoId),
      retry: _noRetry,
    );

class ModeratorMfaController extends AsyncNotifier<ModeratorMfaStatus> {
  ModeratorMfaRepository get _repository =>
      ref.read(moderatorMfaRepositoryProvider);

  @override
  Future<ModeratorMfaStatus> build() =>
      ref.watch(moderatorMfaRepositoryProvider).status();

  /// Throws `ModerationFailure`.
  Future<TotpEnrollment> enroll() => _repository.enrollTotp();

  /// Throws `ModerationFailure`.
  Future<void> verify({required String factorId, required String code}) async {
    await _repository.verifyCode(factorId: factorId, code: code);
    final status = await _repository.status();
    if (ref.mounted) state = AsyncData(status);
  }
}

class PhotoReviewQueueController extends AsyncNotifier<List<PhotoReviewItem>> {
  @override
  Future<List<PhotoReviewItem>> build() =>
      ref.watch(moderationRepositoryProvider).fetchQueue();

  Future<void> refresh() async {
    final items = await ref.read(moderationRepositoryProvider).fetchQueue();
    if (ref.mounted) state = AsyncData(items);
  }

  /// Drops a handled photo right away, before the server refresh.
  void removeItem(String photoId) {
    final items = state.value;
    if (items == null) return;
    state = AsyncData([
      for (final item in items)
        if (item.photoId != photoId) item,
    ]);
  }

  /// The photo to review after [current]: the next one in queue order,
  /// wrapping around to the oldest. Null when the queue is empty.
  String? nextAfter(PhotoReviewItem current) {
    final items = [
      for (final item in state.value ?? const <PhotoReviewItem>[])
        if (item.photoId != current.photoId) item,
    ];
    if (items.isEmpty) return null;
    for (final item in items) {
      if (!item.uploadedAt.isBefore(current.uploadedAt)) return item.photoId;
    }
    return items.first.photoId;
  }
}

class PhotoReviewDetail {
  const PhotoReviewDetail({required this.item, required this.notes});

  /// Null when the photo is gone or no longer available to moderators.
  final PhotoReviewItem? item;
  final List<ModeratorNote> notes;
}

enum ReviewAction {
  approve,
  reject,
  remove,
  retry,
  requireReverification,
  escalate,
}

sealed class ReviewActionResult {
  const ReviewActionResult();
}

/// The photo is finished; review [nextPhotoId] next, or show the empty
/// queue when it is null.
final class ReviewAdvanced extends ReviewActionResult {
  const ReviewAdvanced(this.nextPhotoId);

  final String? nextPhotoId;
}

/// Stay on this photo and show [message].
final class ReviewStayed extends ReviewActionResult {
  const ReviewStayed(this.message, {this.isError = true});

  final String message;
  final bool isError;
}

class PhotoReviewController extends AsyncNotifier<PhotoReviewDetail> {
  PhotoReviewController(this.photoId);

  final String photoId;

  ModerationRepository get _repository =>
      ref.read(moderationRepositoryProvider);

  @override
  Future<PhotoReviewDetail> build() {
    // Keeps the queue alive while reviewing, to find the next photo.
    ref.listen(photoReviewQueueProvider, (_, _) {});
    return _load(ref.watch(moderationRepositoryProvider));
  }

  Future<PhotoReviewDetail> _load(ModerationRepository repository) async {
    final item = await repository.fetchItem(photoId);
    final notes = item == null
        ? const <ModeratorNote>[]
        : await repository.fetchNotes(photoId);
    return PhotoReviewDetail(item: item, notes: notes);
  }

  Future<void> refresh() async {
    final detail = await _load(_repository);
    if (!ref.mounted) return;
    state = AsyncData(detail);
    // Handled elsewhere or no longer available: drop it from the queue.
    if (!(detail.item?.isOpen ?? false)) {
      ref.read(photoReviewQueueProvider.notifier).removeItem(photoId);
    }
  }

  /// Runs a moderator action. The database decides whether it is allowed;
  /// on any failure the item and queue are refreshed so the screen shows
  /// the real state (fail closed).
  Future<ReviewActionResult> perform(
    ReviewAction action, {
    String? reason,
    ChildSafetyCategory? category,
  }) async {
    final item = state.value?.item;
    if (item == null) {
      return const ReviewStayed('This photo is no longer available.');
    }
    final queue = ref.read(photoReviewQueueProvider.notifier);
    final trimmed = reason?.trim();
    final note = trimmed == null || trimmed.isEmpty ? null : trimmed;

    try {
      switch (action) {
        case ReviewAction.approve:
          await _repository.decide(
            photoId,
            PhotoDecision.approve,
            reason: note,
          );
        case ReviewAction.reject:
          await _repository.decide(photoId, PhotoDecision.reject, reason: note);
        case ReviewAction.remove:
          await _repository.decide(photoId, PhotoDecision.remove, reason: note);
        case ReviewAction.retry:
          await _repository.retryProcessing(photoId);
        case ReviewAction.escalate:
          await _repository.escalateToChildSafety(
            photoId,
            category ?? ChildSafetyCategory.suspectedCsam,
          );
        case ReviewAction.requireReverification:
          await _repository.requireReverification(item.ownerId, reason: note);
          await _refreshQuietly();
          return const ReviewStayed(
            'Re-verification required. The member will be asked to verify '
            'again. You can still decide on this photo.',
            isError: false,
          );
      }
    } on ModerationFailure catch (failure) {
      if (failure.type == ModerationFailureType.notAuthorized) {
        ref.invalidate(moderatorMfaProvider);
      }
      await _refreshQueueQuietly(queue);
      await _refreshQuietly();
      return ReviewStayed(failure.message);
    }

    // Every other action finishes this photo for the queue.
    queue.removeItem(photoId);
    await _refreshQueueQuietly(queue);
    return ReviewAdvanced(queue.nextAfter(item));
  }

  /// Throws `ModerationFailure`.
  Future<void> addNote(String body) async {
    await _repository.addNote(photoId, body.trim());
    await refresh();
  }

  Future<void> _refreshQuietly() async {
    try {
      await refresh();
    } on ModerationFailure {
      // Keep the current view; the error message is already shown.
    }
  }

  Future<void> _refreshQueueQuietly(PhotoReviewQueueController queue) async {
    try {
      await queue.refresh();
    } on ModerationFailure {
      // The item was already removed locally.
    }
  }
}

/// Safe message for any error, for screens.
String moderationMessage(Object error) => mapModerationError(error).message;
