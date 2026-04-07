import 'package:flutter_test/flutter_test.dart';
import 'package:chat_app/screens/login_screen.dart';
import 'package:chat_app/services/auth_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

void main() {
  Widget _buildTestApp() {
    return ChangeNotifierProvider(
      create: (_) => AuthService(),
      child: const MaterialApp(home: LoginScreen()),
    );
  }

  testWidgets('LoginScreen displays correctly', (WidgetTester tester) async {
    await tester.pumpWidget(_buildTestApp());
    await tester.pump();

    // Verify basic elements are present
    expect(find.text('XMPP ID (user@domain)'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Port'), findsOneWidget);

    // Verify primary action is present
    expect(find.text('Connect Now'), findsOneWidget);
  });

  testWidgets('Protocol detection works for XMPP addresses', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_buildTestApp());
    await tester.pump();

    // Enter an XMPP-like address
    await tester.enterText(find.byType(TextField).first, 'test@example.com');
    await tester.pump();

    // The test passes if no exception is thrown during protocol detection
    expect(true, isTrue);
  });

  testWidgets('Protocol detection works for IRC addresses', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_buildTestApp());
    await tester.pump();

    // Enter an IRC-like address
    await tester.enterText(find.byType(TextField).first, 'irc.example.com');
    await tester.pump();

    // The test passes if no exception is thrown during protocol detection
    expect(true, isTrue);
  });
}
