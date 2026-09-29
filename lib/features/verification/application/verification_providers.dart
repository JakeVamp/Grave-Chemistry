import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase/supabase_providers.dart';
import '../data/device_camera.dart';
import '../data/device_camera_permission.dart';
import '../../../shared/media/photo_sanitizer.dart';
import '../data/supabase_verification_repository.dart';
import '../domain/camera_permission.dart';
import '../domain/verification_repository.dart';
import 'verification_camera.dart';
import 'verification_flow_controller.dart';
import 'verification_flow_state.dart';

final verificationRepositoryProvider = Provider<VerificationRepository>(
  (ref) => SupabaseVerificationRepository(ref.watch(supabaseClientProvider)),
);

final cameraPermissionServiceProvider = Provider<CameraPermissionService>(
  (ref) => DeviceCameraPermissionService(),
);

/// Creates a new camera for each capture session.
final verificationCameraFactoryProvider =
    Provider<VerificationCamera Function()>(
      (ref) => DeviceVerificationCamera.new,
    );

/// Strips metadata off a captured photo, off the UI isolate.
final photoSanitizerProvider = Provider<Future<Uint8List> Function(Uint8List)>(
  (ref) =>
      (bytes) => compute(sanitizePhoto, bytes),
);

final verificationClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final verificationFlowProvider =
    NotifierProvider.autoDispose<
      VerificationFlowController,
      VerificationFlowState
    >(VerificationFlowController.new);
