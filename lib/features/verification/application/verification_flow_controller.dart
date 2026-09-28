import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../profile/application/profile_providers.dart';
import '../domain/camera_permission.dart';
import '../domain/verification_failure.dart';
import '../domain/verification_session.dart';
import 'verification_camera.dart';
import 'verification_flow_state.dart';
import 'verification_providers.dart';

/// Drives live photo verification:
/// permission → server session → live capture → review/retake → upload →
/// submit. Photos exist only in memory and only come from the live camera.
class VerificationFlowController extends Notifier<VerificationFlowState> {
  VerificationCamera? _camera;

  /// Storage path of the photo currently under review, once uploaded, so a
  /// failed submit can be retried without uploading again.
  String? _uploadedPath;

  /// Session to reopen the camera for when the app returns to foreground.
  VerificationSession? _pausedSession;

  @override
  VerificationFlowState build() {
    ref.onDispose(() => _camera?.dispose());
    return const VerificationIntro();
  }

  DateTime _now() => ref.read(verificationClockProvider)();

  /// Starts (or restarts) verification. Camera permission is requested here,
  /// never earlier.
  Future<void> begin() async {
    state = const VerificationWorking('Waiting for camera permission…');
    final permission = await ref
        .read(cameraPermissionServiceProvider)
        .request();
    if (!ref.mounted) return;
    if (permission != CameraPermissionStatus.granted) {
      state = VerificationPermissionBlocked(permission);
      return;
    }
    await _startSession();
  }

  Future<void> openSettings() =>
      ref.read(cameraPermissionServiceProvider).openSettings();

  Future<void> capture() async {
    final current = state;
    if (current is! VerificationCapturing || current.takingPhoto) return;
    state = VerificationCapturing(
      current.session,
      current.camera,
      takingPhoto: true,
    );

    final Uint8List photo;
    try {
      final raw = await current.camera.takePicture();
      photo = await ref.read(photoSanitizerProvider)(raw);
    } on VerificationFailure catch (failure) {
      if (!ref.mounted) return;
      state = VerificationFailed(failure, session: current.session);
      return;
    } on FormatException {
      if (!ref.mounted) return;
      state = VerificationFailed(
        const VerificationFailure(
          VerificationFailureType.captureFailed,
          "The photo couldn't be processed. Please try again.",
        ),
        session: current.session,
      );
      return;
    }
    if (!ref.mounted) return;

    // Keep the camera off while the user reviews.
    await _closeCamera();
    _uploadedPath = null;
    state = VerificationReviewing(current.session, photo);
  }

  /// Discards the photo and returns to the camera, with a fresh session if
  /// the current one has expired.
  Future<void> retake() async {
    final session = switch (state) {
      VerificationReviewing(:final session) => session,
      VerificationFailed(:final session?) => session,
      _ => null,
    };
    _uploadedPath = null;
    if (session == null || session.isExpiredAt(_now())) {
      await _startSession();
    } else {
      await _openCamera(session);
    }
  }

  Future<void> submit() async {
    final (session, photo) = switch (state) {
      VerificationReviewing(:final session, :final photo) => (session, photo),
      VerificationFailed(:final session?, :final photo?) => (session, photo),
      _ => (null, null),
    };
    if (session == null || photo == null) return;

    if (session.isExpiredAt(_now())) {
      state = const VerificationFailed(
        VerificationFailure(
          VerificationFailureType.sessionExpired,
          'Your verification session timed out. Please take a new photo.',
        ),
      );
      return;
    }

    state = VerificationSubmitting(session, photo);
    final repository = ref.read(verificationRepositoryProvider);
    try {
      final path = _uploadedPath ??= await repository.uploadPhoto(
        session,
        photo,
      );
      await repository.submit(session, path);
    } on VerificationFailure catch (failure) {
      if (!ref.mounted) return;
      if (failure.type == VerificationFailureType.uploadFailed) {
        _uploadedPath = null;
      }
      final canRetrySubmit = switch (failure.type) {
        VerificationFailureType.network ||
        VerificationFailureType.uploadFailed ||
        VerificationFailureType.rateLimited => true,
        _ => false,
      };
      state = canRetrySubmit
          ? VerificationFailed(failure, session: session, photo: photo)
          : VerificationFailed(failure);
      if (failure.type == VerificationFailureType.alreadySubmitted) {
        await ref.read(profileControllerProvider.notifier).refresh();
      }
      return;
    }
    if (!ref.mounted) return;

    _uploadedPath = null;
    state = const VerificationSubmitted();
    // The router moves the user on once the profile shows `pending`.
    await ref.read(profileControllerProvider.notifier).refresh();
  }

  /// Leaves the camera and returns to the explanation.
  Future<void> cancel() async {
    await _closeCamera();
    _uploadedPath = null;
    state = const VerificationIntro();
  }

  /// Releases the camera while the app is in the background.
  Future<void> onAppPaused() async {
    final current = state;
    if (current is VerificationCapturing) {
      _pausedSession = current.session;
      await _closeCamera();
      state = const VerificationWorking('Camera paused');
    }
  }

  Future<void> onAppResumed() async {
    final session = _pausedSession;
    _pausedSession = null;
    if (session == null) return;
    if (session.isExpiredAt(_now())) {
      await _startSession();
    } else {
      await _openCamera(session);
    }
  }

  Future<void> _startSession() async {
    state = const VerificationWorking('Preparing verification…');
    final VerificationSession session;
    try {
      session = await ref.read(verificationRepositoryProvider).startSession();
    } on VerificationFailure catch (failure) {
      if (!ref.mounted) return;
      state = VerificationFailed(failure);
      if (failure.type == VerificationFailureType.alreadySubmitted) {
        await ref.read(profileControllerProvider.notifier).refresh();
      }
      return;
    }
    if (!ref.mounted) return;
    await _openCamera(session);
  }

  Future<void> _openCamera(VerificationSession session) async {
    state = const VerificationWorking('Opening camera…');
    await _closeCamera();
    final camera = ref.read(verificationCameraFactoryProvider)();
    try {
      await camera.initialize();
    } on VerificationFailure catch (failure) {
      await camera.dispose();
      if (!ref.mounted) return;
      state = switch (failure.type) {
        VerificationFailureType.permissionDenied =>
          const VerificationPermissionBlocked(CameraPermissionStatus.denied),
        VerificationFailureType.permissionPermanentlyDenied =>
          const VerificationPermissionBlocked(
            CameraPermissionStatus.permanentlyDenied,
          ),
        VerificationFailureType.permissionRestricted =>
          const VerificationPermissionBlocked(
            CameraPermissionStatus.restricted,
          ),
        _ => VerificationFailed(failure),
      };
      return;
    }
    if (!ref.mounted) {
      await camera.dispose();
      return;
    }
    _camera = camera;
    state = VerificationCapturing(session, camera);
  }

  Future<void> _closeCamera() async {
    final camera = _camera;
    _camera = null;
    await camera?.dispose();
  }
}
