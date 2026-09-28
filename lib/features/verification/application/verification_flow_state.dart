import 'dart:typed_data';

import '../domain/camera_permission.dart';
import '../domain/verification_failure.dart';
import '../domain/verification_session.dart';
import 'verification_camera.dart';

sealed class VerificationFlowState {
  const VerificationFlowState();
}

/// Explanation screen; nothing has been requested yet.
final class VerificationIntro extends VerificationFlowState {
  const VerificationIntro();
}

/// Waiting on permission, the server or the camera.
final class VerificationWorking extends VerificationFlowState {
  const VerificationWorking(this.message);

  final String message;
}

final class VerificationPermissionBlocked extends VerificationFlowState {
  const VerificationPermissionBlocked(this.status);

  final CameraPermissionStatus status;
}

/// Live camera preview for [session].
final class VerificationCapturing extends VerificationFlowState {
  const VerificationCapturing(
    this.session,
    this.camera, {
    this.takingPhoto = false,
  });

  final VerificationSession session;
  final VerificationCamera camera;
  final bool takingPhoto;
}

/// A freshly captured (and metadata-stripped) photo awaiting confirmation.
final class VerificationReviewing extends VerificationFlowState {
  const VerificationReviewing(this.session, this.photo);

  final VerificationSession session;
  final Uint8List photo;
}

final class VerificationSubmitting extends VerificationFlowState {
  const VerificationSubmitting(this.session, this.photo);

  final VerificationSession session;
  final Uint8List photo;
}

/// Something went wrong. With a [photo], the submission can be retried;
/// with only a [session], a new photo can be taken; with neither, the flow
/// starts over.
final class VerificationFailed extends VerificationFlowState {
  const VerificationFailed(this.failure, {this.session, this.photo});

  final VerificationFailure failure;
  final VerificationSession? session;
  final Uint8List? photo;
}

/// Submitted; the profile is now pending review.
final class VerificationSubmitted extends VerificationFlowState {
  const VerificationSubmitted();
}
