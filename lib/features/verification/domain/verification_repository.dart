import 'dart:typed_data';

import 'verification_session.dart';

/// Server-side verification operations. All methods throw
/// `VerificationFailure` on error.
abstract interface class VerificationRepository {
  /// Asks the backend for a new session. The backend chooses the challenge.
  Future<VerificationSession> startSession();

  /// Uploads a JPEG to the private verification bucket and returns its
  /// storage path (never a URL).
  Future<String> uploadPhoto(VerificationSession session, Uint8List jpeg);

  /// Submits the uploaded photo for review. Success means the verification
  /// is pending review, not approved.
  Future<void> submit(VerificationSession session, String objectPath);
}
