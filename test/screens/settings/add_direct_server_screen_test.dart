import 'package:bask/focus/input_mode_tracker.dart';
import 'package:bask/screens/settings/add_direct_server_screen.dart';
import 'package:bask/theme/mono_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The form is the gate in front of the probe: anything it lets through
/// becomes a network call carrying the viewer's token, so what it refuses
/// matters as much as what it accepts.
void main() {
  Widget app() => MaterialApp(
    theme: monoTheme(MonoPalette.dark),
    home: const InputModeTracker(
      // No setupFactory: nothing below should reach a probe, and a test that
      // did would fail on the missing providers rather than pass quietly.
      child: AddDirectServerScreen(),
    ),
  );

  Future<void> submit(WidgetTester tester) async {
    await tester.tap(find.text('Connect'));
    await tester.pump();
  }

  testWidgets('asks for both an address and a token before going anywhere', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await submit(tester);

    expect(find.text('Required'), findsOneWidget);
    expect(find.text('Enter a token'), findsOneWidget);
  });

  testWidgets('refuses an address the client could not reach', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'the living room box');
    await tester.enterText(find.byType(TextFormField).last, 'a-token');
    await submit(tester);

    // The same parser the candidate list is built from, so a value this
    // accepts is one the client can actually try.
    expect(find.text("Enter the server's address"), findsOneWidget);
  });

  testWidgets('refuses an address with no scheme, rather than guessing one', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '192.168.1.10:32400');
    await tester.enterText(find.byType(TextFormField).last, 'a-token');
    await submit(tester);

    expect(find.text("Enter the server's address"), findsOneWidget);
  });

  testWidgets('accepts an address with a scheme and a port', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'http://192.168.1.10:32400');
    await tester.enterText(find.byType(TextFormField).last, 'a-token');
    await tester.pump();

    // Validation alone, without submitting: the address field is the only
    // thing under test here, and submitting would start a probe.
    final form = tester.state<FormState>(find.byType(Form));
    expect(form.validate(), isTrue);
  });

  testWidgets('hides the token as it is typed', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.first.obscureText, isFalse);
    expect(fields.last.obscureText, isTrue);
  });
}
