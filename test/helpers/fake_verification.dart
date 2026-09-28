import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:grave_chemistry/features/profile/domain/verification_status.dart';
import 'package:grave_chemistry/features/verification/application/verification_camera.dart';
import 'package:grave_chemistry/features/verification/domain/camera_permission.dart';
import 'package:grave_chemistry/features/verification/domain/verification_failure.dart';
import 'package:grave_chemistry/features/verification/domain/verification_repository.dart';
import 'package:grave_chemistry/features/verification/domain/verification_session.dart';

import 'fake_profile_repository.dart';

/// A real (tiny) JPEG so image widgets can decode it.
final testPhoto = img.encodeJpg(img.Image(width: 4, height: 4));

/// In-memory backend. Like the real one, a successful submission only ever
/// moves the profile to `pending`.
class FakeVerificationRepository implements VerificationRepository {
  FakeVerificationRepository({this.profiles, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final FakeProfileRepository? profiles;
  final DateTime Function() _now;

  Duration sessionTtl = const Duration(minutes: 10);
  VerificationFailure? nextStartFailure;
  VerificationFailure? nextUploadFailure;
  VerificationFailure? nextSubmitFailure;

  final List<String> calls = [];
  int _sessions = 0;

  @override
  Future<VerificationSession> startSession() async {
    calls.add('start');
    final failure = nextStartFailure;
    if (failure != null) {
      nextStartFailure = null;
      throw failure;
    }
    _sessions++;
    return VerificationSession(
      id: 'session-$_sessions',
      challengeCode: 'turn_head_left',
      expiresAt: _now().add(sessionTtl),
      attemptNumber: _sessions,
    );
  }

  @override
  Future<String> uploadPhoto(
    VerificationSession session,
    Uint8List jpeg,
  ) async {
    calls.add('upload:${session.id}');
    final failure = nextUploadFailure;
    if (failure != null) {
      nextUploadFailure = null;
      throw failure;
    }
    return '${session.id}/photo.jpg';
  }

  @override
  Future<void> submit(VerificationSession session, String objectPath) async {
    calls.add('submit:${session.id}');
    final failure = nextSubmitFailure;
    if (failure != null) {
      nextSubmitFailure = null;
      throw failure;
    }
    final repo = profiles;
    if (repo != null) {
      repo.profile = completedProfileWith(VerificationStatus.pending);
    }
  }
}

class FakeCameraPermissionService implements CameraPermissionService {
  FakeCameraPermissionService([this.result = CameraPermissionStatus.granted]);

  CameraPermissionStatus result;
  int requests = 0;
  int settingsOpened = 0;

  @override
  Future<CameraPermissionStatus> request() async {
    requests++;
    return result;
  }

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return true;
  }
}

class FakeVerificationCamera implements VerificationCamera {
  FakeVerificationCamera({this.initializeFailure, this.captureFailure});

  VerificationFailure? initializeFailure;
  VerificationFailure? captureFailure;
  bool initialized = false;
  bool disposed = false;

  @override
  Future<void> initialize() async {
    final failure = initializeFailure;
    if (failure != null) throw failure;
    initialized = true;
  }

  @override
  Widget buildPreview() => const ColoredBox(
    color: Color(0xFF333333),
    child: SizedBox(width: 200, height: 300),
  );

  @override
  Future<Uint8List> takePicture() async {
    final failure = captureFailure;
    if (failure != null) {
      captureFailure = null;
      throw failure;
    }
    return testPhoto;
  }

  @override
  Future<void> dispose() async => disposed = true;
}

/// Hands out cameras and remembers them for assertions.
class FakeCameraFactory {
  FakeCameraFactory({this.initializeFailure, this.captureFailure});

  VerificationFailure? initializeFailure;
  VerificationFailure? captureFailure;
  final List<FakeVerificationCamera> created = [];

  VerificationCamera call() {
    final camera = FakeVerificationCamera(
      initializeFailure: initializeFailure,
      captureFailure: captureFailure,
    );
    captureFailure = null;
    created.add(camera);
    return camera;
  }
}
