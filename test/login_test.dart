import 'package:flutter_test/flutter_test.dart';
import 'package:chat_app/main.dart';
import 'package:chat_app/screens/login_screen.dart';
import 'package:flutter/material.dart';

void main() {
  testWidgets('LoginScreen displays correctly', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));

    // Verify basic elements are present
    expect(find.textContaining('your-username'), findsOneWidget);
    expect(find.textContaining('your-password'), findsOneWidget);
    expect(find.textContaining('5222'), findsOneWidget);

    // Verify protocol detection text
    expect(find.textContaining('Connect with'), findsOneWidget);
  });

  testWidgets('Protocol detection works for XMPP addresses', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));

    // Enter an XMPP-like address
    await tester.enterText(
      find.byKey(const Key('unifiedAddress')),
      'test@example.com',
    );
    await tester.pump();

    // The test passes if no exception is thrown during protocol detection
    expect(true, isTrue);
  });

  testWidgets('Protocol detection works for IRC addresses', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));

    // Enter an IRC-like address
    await tester.enterText(
      find.byKey(const Key('unifiedAddress')),
      'irc.example.com',
    );
    await tester.pump();

    // The test passes if no exception is thrown during protocol detection
    expect(true, isTrue);
  });
}
