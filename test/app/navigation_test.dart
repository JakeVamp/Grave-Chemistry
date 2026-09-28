import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_auth_repository.dart';
import '../helpers/pump_app.dart';

void main() {
  Future<void> pumpSignedIn(WidgetTester tester) =>
      pumpApp(tester, FakeAuthRepository(currentUser: testUser));

  const destinations = {
    'Discovery': 'Discovery is not built yet.',
    'Matches': 'Matches are not built yet.',
    'Messages': 'Messaging is not built yet.',
    'Settings': 'Settings are not built yet.',
  };

  testWidgets('home screen lists every placeholder destination', (
    tester,
  ) async {
    await pumpSignedIn(tester);

    expect(find.text('Grave Chemistry'), findsOneWidget);
    for (final label in destinations.keys) {
      expect(find.text(label), findsOneWidget);
    }
  });

  for (final MapEntry(key: label, value: message) in destinations.entries) {
    testWidgets('navigates to $label and back', (tester) async {
      await pumpSignedIn(tester);

      await tester.tapAndSettle(find.text(label));
      expect(find.text(message), findsOneWidget);

      await tester.tapAndSettle(find.byType(BackButton));
      expect(find.text('Foundation build'), findsOneWidget);
    });
  }
}
