/// What the owner may know about a photo's review. Moderation reasons,
/// fingerprints and child-safety details are never sent to the app.
enum PhotoReviewStatus {
  /// Waiting for (or under) review. Not visible to anyone else.
  inReview('in_review'),

  /// Approved and visible to eligible people.
  live('live'),

  /// Not approved; only the owner sees it and can delete it.
  notApproved('not_approved');

  const PhotoReviewStatus(this.code);

  final String code;

  static PhotoReviewStatus fromCode(String? code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return inReview;
  }
}

/// One of the signed-in user's public profile photos.
class ProfilePhoto {
  const ProfilePhoto({
    required this.id,
    required this.position,
    required this.isPrimary,
    required this.status,
    this.objectPath,
  });

  final String id;

  /// Storage path for requesting a short-lived signed URL. Null when the
  /// photo is withheld (e.g. held for review).
  final String? objectPath;
  final int position;
  final bool isPrimary;
  final PhotoReviewStatus status;
}

/// Reserved slot for one upload, issued by the server.
class PhotoUploadSlot {
  const PhotoUploadSlot({required this.assetId, required this.objectPath});

  final String assetId;
  final String objectPath;
}

abstract final class ProfilePhotoLimits {
  /// Mirrors the server setting; the server enforces it.
  static const int maxPhotos = 6;
}
