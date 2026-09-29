import 'dart:convert';
import 'dart:typed_data';

import 'package:grave_chemistry/features/auth/domain/auth_user.dart';
import 'package:grave_chemistry/features/moderation/data/moderation_error_mapper.dart';
import 'package:grave_chemistry/features/moderation/data/screen_security.dart';
import 'package:grave_chemistry/features/moderation/domain/moderation_failure.dart';
import 'package:grave_chemistry/features/moderation/domain/moderation_repository.dart';
import 'package:grave_chemistry/features/moderation/domain/moderator_mfa.dart';
import 'package:grave_chemistry/features/moderation/domain/moderator_note.dart';
import 'package:grave_chemistry/features/moderation/domain/photo_review_item.dart';
import 'package:grave_chemistry/features/moderation/domain/review_media.dart';
import 'package:grave_chemistry/features/profile/domain/verification_status.dart';

const moderatorUser = AuthUser(
  id: 'mod-1',
  email: 'mod@example.com',
  role: 'moderator',
);

/// A valid 1×1 PNG, so Image widgets have something decodable.
final reviewImageBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

PhotoReviewItem reviewItem(
  String id, {
  String name = 'Morticia',
  int minute = 0,
  ReviewState state = ReviewState.awaitingReview,
  DuplicateMatch? duplicate,
  bool signals = false,
  bool? canApprove,
}) => PhotoReviewItem(
  photoId: id,
  ownerId: 'owner-$id',
  uploadedAt: DateTime.utc(2026, 9, 29, 12, minute),
  displayName: name,
  age: 34,
  verificationStatus: VerificationStatus.verified,
  hasReviewSignals: signals,
  duplicateMatch: duplicate,
  contentFlagged: false,
  automatedChecksIncomplete: true,
  reviewState: state,
  canApprove: canApprove ?? state == ReviewState.awaitingReview,
  canRetry: state == ReviewState.processingFailed,
);

/// In-memory moderator backend that mirrors the server rules: only open
/// photos can be decided, approval needs the approve hint, decided photos
/// leave the queue.
class FakeModerationRepository implements ModerationRepository {
  FakeModerationRepository({List<PhotoReviewItem>? items})
    : items = {
        for (final item in items ?? const <PhotoReviewItem>[])
          item.photoId: item,
      };

  final Map<String, PhotoReviewItem> items;
  final Map<String, List<ModeratorNote>> notes = {};
  final List<String> calls = [];

  /// Thrown (once) by the next action.
  ModerationFailure? nextActionFailure;

  /// Thrown by media loads while set.
  ModerationFailure? mediaFailure;
  VerificationPhotoAvailability verification =
      VerificationPhotoAvailability.available;
  int mediaLoads = 0;

  /// Simulates another moderator deciding the photo before this one acts.
  void decideElsewhere(String photoId) {
    final item = items[photoId]!;
    items[photoId] = _withState(item, ReviewState.decided);
  }

  @override
  Future<List<PhotoReviewItem>> fetchQueue() async {
    calls.add('queue');
    final open = items.values.where((i) => i.isOpen).toList()
      ..sort((a, b) => a.uploadedAt.compareTo(b.uploadedAt));
    return open;
  }

  @override
  Future<PhotoReviewItem?> fetchItem(String photoId) async => items[photoId];

  @override
  Future<ReviewMedia> loadReviewMedia(String photoId) async {
    mediaLoads++;
    calls.add('media:$photoId');
    if (mediaFailure != null) throw mediaFailure!;
    return ReviewMedia(
      profilePhoto: reviewImageBytes,
      verificationPhoto: verification == VerificationPhotoAvailability.available
          ? reviewImageBytes
          : null,
      verification: verification,
    );
  }

  @override
  Future<List<ModeratorNote>> fetchNotes(String photoId) async => [
    ...?notes[photoId],
  ];

  @override
  Future<void> addNote(String photoId, String body) async {
    calls.add('note:$photoId:$body');
    (notes[photoId] ??= []).add(
      ModeratorNote(
        id: (notes[photoId]?.length ?? 0) + 1,
        body: body,
        moderatorId: moderatorUser.id,
        createdAt: DateTime.utc(2026, 9, 29, 13),
      ),
    );
  }

  void _act(String call, String photoId, {bool approve = false}) {
    calls.add(call);
    final failure = nextActionFailure;
    if (failure != null) {
      nextActionFailure = null;
      throw failure;
    }
    final item = items[photoId];
    if (item == null || !item.isOpen) throw unavailableFailure;
    if (approve && !item.canApprove) throw refusedFailure;
  }

  @override
  Future<void> decide(
    String photoId,
    PhotoDecision decision, {
    String? reason,
  }) async {
    _act(
      '${decision.name}:$photoId:${reason ?? ''}',
      photoId,
      approve: decision == PhotoDecision.approve,
    );
    items[photoId] = _withState(items[photoId]!, ReviewState.decided);
  }

  @override
  Future<void> retryProcessing(String photoId) async {
    _act('retry:$photoId', photoId);
    if (!items[photoId]!.canRetry) throw unavailableFailure;
    items[photoId] = _withState(items[photoId]!, ReviewState.processing);
  }

  @override
  Future<void> requireReverification(String userId, {String? reason}) async {
    calls.add('reverify:$userId:${reason ?? ''}');
    final failure = nextActionFailure;
    if (failure != null) {
      nextActionFailure = null;
      throw failure;
    }
  }

  @override
  Future<void> escalateToChildSafety(
    String photoId,
    ChildSafetyCategory category,
  ) async {
    _act('escalate:$photoId:${category.code}', photoId);
    // Gone for ordinary moderators.
    items.remove(photoId);
  }

  static PhotoReviewItem _withState(PhotoReviewItem i, ReviewState state) =>
      PhotoReviewItem(
        photoId: i.photoId,
        ownerId: i.ownerId,
        uploadedAt: i.uploadedAt,
        displayName: i.displayName,
        age: i.age,
        verificationStatus: i.verificationStatus,
        hasReviewSignals: i.hasReviewSignals,
        duplicateMatch: i.duplicateMatch,
        contentFlagged: i.contentFlagged,
        automatedChecksIncomplete: i.automatedChecksIncomplete,
        reviewState: state,
        canApprove: false,
        canRetry: false,
      );
}

class FakeModeratorMfaRepository implements ModeratorMfaRepository {
  FakeModeratorMfaRepository({this.current = const MfaVerified()});

  ModeratorMfaStatus current;
  static const validCode = '123456';
  final List<String> calls = [];

  @override
  Future<ModeratorMfaStatus> status() async => current;

  @override
  Future<TotpEnrollment> enrollTotp() async {
    calls.add('enroll');
    return const TotpEnrollment(
      factorId: 'factor-new',
      secret: 'JBSWY3DPEHPK3PXP',
    );
  }

  @override
  Future<void> verifyCode({
    required String factorId,
    required String code,
  }) async {
    calls.add('verify:$factorId');
    if (code != validCode) {
      throw const ModerationFailure(
        ModerationFailureType.notAuthorized,
        "That code didn't work. Check your authenticator app and try again.",
      );
    }
    current = const MfaVerified();
  }
}

class FakeScreenSecurity implements ScreenSecurity {
  final List<String> calls = [];
  bool get isSecure => calls.isNotEmpty && calls.last == 'enable';

  @override
  Future<void> enable() async => calls.add('enable');

  @override
  Future<void> disable() async => calls.add('disable');
}

Uint8List jpegBytes([int length = 16]) =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List.filled(length - 3, 0)]);
