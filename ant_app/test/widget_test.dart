// Smoke test for the Module 2 root router: a signed-out launch (no cached
// Firebase Auth session) boots into language selection first, then role
// selection with both roles presented.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ant_app/main.dart';
import 'package:ant_app/features/onboarding/providers/onboarding_providers.dart';

void main() {
  testWidgets('Onboarding starts on language selection, then role selection', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Real Firebase isn't initialized in the widget-test environment;
          // stand in a signed-out auth stream so AppRoot renders the
          // onboarding flow instead of erroring out.
          authStateProvider.overrideWith((ref) => Stream<User?>.value(null)),
        ],
        child: const AntApp(firebaseReady: true),
      ),
    );
    await tester.pump();

    expect(find.text('English'), findsOneWidget);
    expect(find.text('বাংলা'), findsOneWidget);

    await tester.tap(find.text('English'));
    await tester.pump();

    expect(find.text('Welcome to ANT'), findsOneWidget);
    expect(find.text('I need assistance'), findsOneWidget);
    expect(find.text('I am a Caretaker'), findsOneWidget);
  });

  testWidgets('Picking Bangla renders role selection in Bangla', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authStateProvider.overrideWith((ref) => Stream<User?>.value(null)),
        ],
        child: const AntApp(firebaseReady: true),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('বাংলা'));
    await tester.pump();

    expect(find.text('অ্যান্টে স্বাগতম'), findsOneWidget);
    expect(find.text('আমার সহায়তা প্রয়োজন'), findsOneWidget);
    expect(find.text('আমি একজন দেখাশোনাকারী'), findsOneWidget);
  });
}
