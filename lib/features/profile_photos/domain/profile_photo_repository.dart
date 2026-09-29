import 'dart:typed_data';

import 'profile_photo.dart';

/// The signed-in user's public profile photos. All methods throw
/// `ProfilePhotoFailure` on error. Visibility to others is decided by the
/// server, never by the app.
abstract interface class ProfilePhotoRepository {
  Future<List<ProfilePhoto>> fetchMine();

  /// Asks the server for an upload slot (enforces the photo limit).
  Future<PhotoUploadSlot> reserveUpload();

  /// Uploads a JPEG into the reserved slot.
  Future<void> uploadFile(PhotoUploadSlot slot, Uint8List jpeg);

  /// Tells the server the file arrived; the photo is then pending review.
  Future<void> completeUpload(PhotoUploadSlot slot);

  Future<void> delete(String photoId);

  /// `photoIds` must list all current photos in the new order.
  Future<void> reorder(List<String> photoIds);

  Future<void> setPrimary(String photoId);

  /// Short-lived signed URL, or null if the server won't allow access.
  Future<String?> signedUrl(String objectPath);
}
