import 'dart:typed_data';

enum VerificationPhotoAvailability {
  available,

  /// No approved verification photo is on file (or it was deleted after
  /// its retention period).
  none,

  /// On file, but it couldn't be loaded securely this time.
  unavailable,
}

/// The two photos for side-by-side review, held in memory only while the
/// review screen is open. Signed URLs are used once to download them and
/// are never kept.
class ReviewMedia {
  const ReviewMedia({
    required this.profilePhoto,
    required this.verificationPhoto,
    required this.verification,
  });

  final Uint8List profilePhoto;
  final Uint8List? verificationPhoto;
  final VerificationPhotoAvailability verification;
}
