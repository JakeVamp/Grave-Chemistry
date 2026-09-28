import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/app/app.dart';
import 'package:grave_chemistry/features/auth/application/auth_providers.dart';
import 'package:grave_chemistry/features/profile/application/profile_providers.dart';
import 'package:grave_chemistry/features/verification/application/verification_providers.dart';

import 'fake_auth_repository.dart';
import 'fake_profile_repository.dart';
import 'fake_verification.dart';

/// Pumps the full app with fake backends and a fake camera. Defaults to a
/// phone-sized screen and a user who is fully onboarded and verified.
Future<void> pumpApp(
  WidgetTester tester,
  FakeAuthRepository repository, {
  FakeProfileRepository? profiles,
  FakeVerificationRepository? verification,
  FakeCameraPermissionService? cameraPermission,
  FakeCameraFactory? cameras,
  Size logicalSize = const Size(390, 844),
  double textScale = 1,
  bool settle = true,
}) async {
  tester.view.physicalSize = logicalSize * 3;
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final profileRepository = profiles ?? FakeProfileRepository.completed();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authRepositoryProvider.overrideWithValue(repository),
        profileRepositoryProvider.overrideWithValue(profileRepository),
        verificationRepositoryProvider.overrideWithValue(
          verification ??
              FakeVerificationRepository(profiles: profileRepository),
        ),
        cameraPermissionServiceProvider.overrideWithValue(
          cameraPermission ?? FakeCameraPermissionService(),
        ),
        verificationCameraFactoryProvider.overrideWithValue(
          (cameras ?? FakeCameraFactory()).call,
        ),
        photoSanitizerProvider.overrideWithValue((bytes) async => bytes),
      ],
      child: const GraveChemistryApp(),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

extension AppTester on WidgetTester {
  Future<void> tapAndSettle(Finder finder) async {
    await ensureVisible(finder);
    // Scroll views ignore taps while still animating.
    await pumpAndSettle();
    await tap(finder);
    await pumpAndSettle();
  }

  Future<void> enterField(String label, String text) async {
    final field = find.widgetWithText(TextFormField, label);
    await ensureVisible(field);
    await pumpAndSettle();
    await enterText(field, text);
    await pumpAndSettle();
  }
}
