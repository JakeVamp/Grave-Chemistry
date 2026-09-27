import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/app/app.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: GraveChemistryApp()));
    await tester.pumpAndSettle();
  }

  testWidgets('home screen lists every placeholder destination', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('Grave Chemistry'), findsOneWidget);
    for (final label in [
      'Authentication',
      'Profile setup',
      'Discovery',
      'Matches',
      'Messages',
      'Settings',
    ]) {
      await tester.scrollUntilVisible(find.text(label), 100);
      expect(find.text(label), findsOneWidget);
    }
  });

  const destinations = {
    'Authentication': 'Authentication is not built yet.',
    'Profile setup': 'Profile setup is not built yet.',
    'Discovery': 'Discovery is not built yet.',
    'Matches': 'Matches are not built yet.',
    'Messages': 'Messaging is not built yet.',
    'Settings': 'Settings are not built yet.',
  };

  for (final MapEntry(key: label, value: message) in destinations.entries) {
    testWidgets('navigates to $label and back', (tester) async {
      await pumpApp(tester);

      await tester.scrollUntilVisible(find.text(label), 100);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Foundation build'), findsOneWidget);
    });
  }
}
