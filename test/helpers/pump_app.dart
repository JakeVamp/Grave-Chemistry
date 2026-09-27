import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/app/app.dart';
import 'package:grave_chemistry/features/auth/application/auth_providers.dart';

import 'fake_auth_repository.dart';

/// Pumps the full app on a phone-sized screen with a fake auth backend.
Future<void> pumpApp(WidgetTester tester, FakeAuthRepository repository) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [authRepositoryProvider.overrideWithValue(repository)],
      child: const GraveChemistryApp(),
    ),
  );
  await tester.pumpAndSettle();
}

extension AppTester on WidgetTester {
  Future<void> tapAndSettle(Finder finder) async {
    await ensureVisible(finder);
    await tap(finder);
    await pumpAndSettle();
  }

  Future<void> enterField(String label, String text) async {
    await enterText(find.widgetWithText(TextFormField, label), text);
  }
}
