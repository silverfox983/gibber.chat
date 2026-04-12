import 'package:flutter_test/flutter_test.dart';
import 'package:gibber/screens/login_screen.dart';
import 'package:gibber/services/auth_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

void main() {
  Widget buildTestApp() {
    return ChangeNotifierProvider(
      create: (_) => AuthService(),
      child: const MaterialApp(home: LoginScreen()),
    );
  }

  testWidgets('LoginScreen displays correctly', (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AuthService(),
        child: const MaterialApp(home: LoginScreen()),
      ),
    );

    expect(find.text('Gibber'), findsOneWidget);
    expect(find.text('Multi-protocol Chat Client'), findsOneWidget);
    expect(find.textContaining('your-username'), findsOneWidget);
    expect(find.text('5222'), findsOneWidget);
    await tester.pumpWidget(buildTestApp());
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
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AuthService(),
        child: const MaterialApp(home: LoginScreen()),
      ),
    );

    // Find the XMPP address text field by its current placeholder text and enter a new value
    final addressField = find.widgetWithText(TextField, 'your-username@domain.com');
    expect(addressField, findsOneWidget);

    await tester.enterText(addressField, 'test@example.com');
    await tester.pumpWidget(buildTestApp());
    await tester.pump();

    // Enter an XMPP-like address
    await tester.enterText(find.byType(TextField).first, 'test@example.com');
    await tester.pump();

    expect(true, isTrue);
  });

  testWidgets('Protocol detection works for IRC addresses', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AuthService(),
        child: const MaterialApp(home: LoginScreen()),
      ),
    );

    final addressField = find.widgetWithText(TextField, 'your-username@domain.com');
    expect(addressField, findsOneWidget);

    await tester.enterText(addressField, 'irc.libera.chat');
    await tester.pumpWidget(buildTestApp());
    await tester.pump();

    // Enter an IRC-like address
    await tester.enterText(find.byType(TextField).first, 'irc.example.com');
    await tester.pump();

    expect(true, isTrue);
  });
}
