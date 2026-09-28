import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';

import '../application/verification_camera.dart';
import '../domain/verification_failure.dart';

/// Front camera via the `camera` plugin. Audio is disabled, so the
/// microphone is never requested, and there is no gallery access.
class DeviceVerificationCamera implements VerificationCamera {
  CameraController? _controller;

  @override
  Future<void> initialize() async {
    final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } on CameraException catch (error) {
      throw _mapCameraException(error);
    }
    if (cameras.isEmpty) throw _unavailable;

    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await controller.initialize();
    } on CameraException catch (error) {
      await controller.dispose();
      throw _mapCameraException(error);
    }
    _controller = controller;
  }

  @override
  Widget buildPreview() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return CameraPreview(controller);
  }

  @override
  Future<Uint8List> takePicture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      throw _unavailable;
    }
    try {
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      // The plugin writes a temporary file; don't leave it on disk.
      try {
        await File(file.path).delete();
      } on FileSystemException {
        // Best effort; the OS clears the cache directory eventually.
      }
      return bytes;
    } on CameraException {
      throw const VerificationFailure(
        VerificationFailureType.captureFailed,
        "The photo couldn't be taken. Please try again.",
      );
    }
  }

  @override
  Future<void> dispose() async {
    final controller = _controller;
    _controller = null;
    await controller?.dispose();
  }

  static const _unavailable = VerificationFailure(
    VerificationFailureType.cameraUnavailable,
    "We couldn't access a camera on this device.",
  );

  static VerificationFailure _mapCameraException(CameraException error) {
    return switch (error.code) {
      'CameraAccessDenied' => const VerificationFailure(
        VerificationFailureType.permissionDenied,
        'Camera access is needed to take your verification photo.',
      ),
      'CameraAccessDeniedWithoutPrompt' => const VerificationFailure(
        VerificationFailureType.permissionPermanentlyDenied,
        'Camera access is turned off for Grave Chemistry. You can turn it on '
        'in Settings.',
      ),
      'CameraAccessRestricted' => const VerificationFailure(
        VerificationFailureType.permissionRestricted,
        'Camera access is restricted on this device.',
      ),
      _ => _unavailable,
    };
  }
}
