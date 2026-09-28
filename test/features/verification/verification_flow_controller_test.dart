import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/auth/application/auth_providers.dart';
import 'package:grave_chemistry/features/profile/application/profile_providers.dart';
import 'package:grave_chemistry/features/profile/domain/verification_status.dart';
import 'package:grave_chemistry/features/verification/application/verification_flow_state.dart';
import 'package:grave_chemistry/features/verification/application/verification_providers.dart';
import 'package:grave_chemistry/features/verification/domain/camera_permission.dart';
import 'package:grave_chemistry/features/verification/domain/verification_failure.dart';

import '../../helpers/fake_auth_repository.dart';
import '../../helpers/fake_profile_repository.dart';
import '../../helpers/fake_verification.dart';

void main() {
  late FakeProfileRepository profiles;
  late FakeVerificationRepository backend;
  late FakeCameraPermissionService permission;
  late FakeCameraFactory cameras;
  late DateTime now;

  ProviderContainer createContainer() {
    final container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(currentUser: testUser),
        ),
        profileRepositoryProvider.overrideWithValue(profiles),
        verificationRepositoryProvider.overrideWithValue(backend),
        cameraPermissionServiceProvider.overrideWithValue(permission),
        verificationCameraFactoryProvider.overrideWithValue(cameras.call),
        photoSanitizerProvider.overrideWithValue((bytes) async => bytes),
        verificationClockProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(container.dispose);
    // Keep the auto-dispose flow alive for the test.
    container.listen(verificationFlowProvider, (_, _) {});
    container.listen(onboardingGateProvider, (_, _) {});
    return container;
  }

  setUp(() {
    now = DateTime.utc(2026, 9, 29, 12);
    profiles = FakeProfileRepository(
      profile: completedProfileWith(VerificationStatus.notStarted),
    );
    backend = FakeVerificationRepository(profiles: profiles, now: () => now);
    permission = FakeCameraPermissionService();
    cameras = FakeCameraFactory();
  });

  VerificationFlowState stateOf(ProviderContainer c) =>
      c.read(verificationFlowProvider);

  test('starts on the explanation without asking for anything', () {
    final c = createContainer();
    expect(stateOf(c), isA<VerificationIntro>());
    expect(permission.requests, 0);
    expect(cameras.created, isEmpty);
  });

  test('happy path: permission, session, capture, submit -> pending', () async {
    final c = createContainer();
    await c.read(profileControllerProvider.future);
    final flow = c.read(verificationFlowProvider.notifier);

    await flow.begin();
    final capturing = stateOf(c) as VerificationCapturing;
    expect(permission.requests, 1);
    expect(
      capturing.session.instruction,
      'Turn your head slightly to the left',
    );
    expect(cameras.created.single.initialized, isTrue);

    await flow.capture();
    expect(stateOf(c), isA<VerificationReviewing>());
    expect(
      cameras.created.single.disposed,
      isTrue,
      reason: 'camera off in review',
    );

    await flow.submit();
    expect(stateOf(c), isA<VerificationSubmitted>());
    expect(backend.calls, ['start', 'upload:session-1', 'submit:session-1']);

    final status = c.read(profileControllerProvider).value!.verificationStatus;
    expect(status, VerificationStatus.pending);
    expect(status!.showsVerifiedBadge, isFalse);
    expect(c.read(onboardingGateProvider), OnboardingGate.verificationPending);
  });

  test('permission denied', () async {
    permission.result = CameraPermissionStatus.denied;
    final c = createContainer();
    await c.read(verificationFlowProvider.notifier).begin();

    expect(
      (stateOf(c) as VerificationPermissionBlocked).status,
      CameraPermissionStatus.denied,
    );
    expect(backend.calls, isEmpty, reason: 'no session without permission');
    expect(cameras.created, isEmpty);
  });

  test('permission permanently denied offers settings', () async {
    permission.result = CameraPermissionStatus.permanentlyDenied;
    final c = createContainer();
    final flow = c.read(verificationFlowProvider.notifier);
    await flow.begin();

    expect(
      (stateOf(c) as VerificationPermissionBlocked).status,
      CameraPermissionStatus.permanentlyDenied,
    );
    await flow.openSettings();
    expect(permission.settingsOpened, 1);

    permission.result = CameraPermissionStatus.granted;
    await flow.begin();
    expect(stateOf(c), isA<VerificationCapturing>());
  });

  test('camera unavailable', () async {
    cameras.initializeFailure = const VerificationFailure(
      VerificationFailureType.cameraUnavailable,
      'no camera',
    );
    final c = createContainer();
    await c.read(verificationFlowProvider.notifier).begin();

    final failed = stateOf(c) as VerificationFailed;
    expect(failed.failure.type, VerificationFailureType.cameraUnavailable);
    expect(cameras.created.single.disposed, isTrue);
  });

  test('camera reports denied access after the prompt', () async {
    cameras.initializeFailure = const VerificationFailure(
      VerificationFailureType.permissionPermanentlyDenied,
      'off',
    );
    final c = createContainer();
    await c.read(verificationFlowProvider.notifier).begin();

    expect(
      (stateOf(c) as VerificationPermissionBlocked).status,
      CameraPermissionStatus.permanentlyDenied,
    );
  });

  test('capture failure keeps the session and allows another try', () async {
    cameras.captureFailure = const VerificationFailure(
      VerificationFailureType.captureFailed,
      'nope',
    );
    final c = createContainer();
    final flow = c.read(verificationFlowProvider.notifier);
    await flow.begin();
    await flow.capture();

    final failed = stateOf(c) as VerificationFailed;
    expect(failed.failure.type, VerificationFailureType.captureFailed);
    expect(failed.session, isNotNull);
    expect(failed.photo, isNull);

    await flow.retake();
    expect(stateOf(c), isA<VerificationCapturing>());
    expect(backend.calls.where((c) => c == 'start'), hasLength(1));
  });

  test('cancelling the camera returns to the explanation', () async {
    final c = createContainer();
    final flow = c.read(verificationFlowProvider.notifier);
    await flow.begin();
    await flow.cancel();

    expect(stateOf(c), isA<VerificationIntro>());
    expect(cameras.created.single.disposed, isTrue);
  });

  test('retake discards the photo and reopens the camera', () async {
    final c = createContainer();
    final flow = c.read(verificationFlowProvider.notifier);
    await flow.begin();
    await flow.capture();
    await flow.retake();

    expect(stateOf(c), isA<VerificationCapturing>());
    expect(cameras.created, hasLength(2));
    expect(backend.calls, ['start'], reason: 'nothing uploaded on retake');
  });

  test('upload failure keeps the photo; retry uploads again', () async {
    backend.nextUploadFailure = const VerificationFailure(
      VerificationFailureType.uploadFailed,
      'upload failed',
    );
    final c = createContainer();
    final flow = c.read(verificationFlowProvider.notifier);
    await flow.begin();
    await flow.capture();
    await flow.submit();

    final failed = stateOf(c) as VerificationFailed;
    expect(failed.failure.type, VerificationFailureType.uploadFailed);
    expect(failed.photo, isNotNull);
    expect(
      c.read(profileControllerProvider).value!.verificationStatus,
      VerificationStatus.notStarted,
    );

    await flow.submit();
    expect(stateOf(c), isA<VerificationSubmitted>());
    expect(backend.calls.where((c) => c.startsWith('upload')), hasLength(2));
  });

  test('a failed submit after upload retries without re-uploading', () async {
    backend.nextSubmitFailure = const VerificationFailure(
      VerificationFailureType.network,
      'offline',
    );
    final c = createContainer();
    final flow = c.read(verificationFlowProvider.notifier);
    await flow.begin();
    await flow.capture();
    await flow.submit();
    expect(stateOf(c), isA<VerificationFailed>());

    await flow.submit();
    expect(stateOf(c), isA<VerificationSubmitted>());
    expect(backend.calls.where((c) => c.startsWith('upload')), hasLength(1));
  });

  test('an expired session needs a new session and a new photo', () async {
    final c = createContainer();
    final flow = c.read(verificationFlowProvider.notifier);
    await flow.begin();
    await flow.capture();

    now = now.add(const Duration(minutes: 11));
    await flow.submit();
    final failed = stateOf(c) as VerificationFailed;
    expect(failed.failure.type, VerificationFailureType.sessionExpired);
    expect(failed.photo, isNull, reason: 'old photo cannot be reused');
    expect(backend.calls.where((c) => c.startsWith('upload')), isEmpty);

    await flow.begin();
    expect((stateOf(c) as VerificationCapturing).session.id, 'session-2');
  });

  test('server-side expiry is handled the same way', () async {
    backend.nextSubmitFailure = const VerificationFailure(
      VerificationFailureType.sessionExpired,
      'expired',
    );
    final c = createContainer();
    final flow = c.read(verificationFlowProvider.notifier);
    await flow.begin();
    await flow.capture();
    await flow.submit();

    final failed = stateOf(c) as VerificationFailed;
    expect(failed.session, isNull);
    expect(failed.photo, isNull);
  });

  test('server refusal to start (rate limited) is shown', () async {
    backend.nextStartFailure = const VerificationFailure(
      VerificationFailureType.rateLimited,
      'slow down',
    );
    final c = createContainer();
    await c.read(verificationFlowProvider.notifier).begin();

    expect(
      (stateOf(c) as VerificationFailed).failure.type,
      VerificationFailureType.rateLimited,
    );
    expect(cameras.created, isEmpty);
  });

  test('backgrounding releases the camera and resumes the session', () async {
    final c = createContainer();
    final flow = c.read(verificationFlowProvider.notifier);
    await flow.begin();
    await flow.onAppPaused();
    expect(cameras.created.single.disposed, isTrue);

    await flow.onAppResumed();
    final resumed = stateOf(c) as VerificationCapturing;
    expect(resumed.session.id, 'session-1');
    expect(cameras.created, hasLength(2));
  });

  test('leaving the screen disposes the camera', () async {
    final c = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(currentUser: testUser),
        ),
        profileRepositoryProvider.overrideWithValue(profiles),
        verificationRepositoryProvider.overrideWithValue(backend),
        cameraPermissionServiceProvider.overrideWithValue(permission),
        verificationCameraFactoryProvider.overrideWithValue(cameras.call),
      ],
    );
    final sub = c.listen(verificationFlowProvider, (_, _) {});
    await c.read(verificationFlowProvider.notifier).begin();
    sub.close();
    await Future<void>.delayed(Duration.zero);
    c.dispose();
    expect(cameras.created.single.disposed, isTrue);
  });
}
