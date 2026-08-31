// Smoke test for the Module 1 onboarding entry point: the app boots
// straight into role selection and both roles are presented.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ant_app/main.dart';

void main() {
  testWidgets('Onboarding starts on role selection', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: AntApp(firebaseReady: true)),
    );

    expect(find.text('Welcome to ANT'), findsOneWidget);
    expect(find.text('I need assistance'), findsOneWidget);
    expect(find.text('I am a Caretaker'), findsOneWidget);
  });
}
