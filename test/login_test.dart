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

  testWidgets('LoginScreen displays all required UI elements', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildTestApp());
    await tester.pumpAndSettle();

    expect(find.text('Gibber'), findsOneWidget);
    expect(find.text('Secure Communication'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Keep me logged in'), findsOneWidget);
    expect(find.text("Don't have an account?"), findsOneWidget);
  });

  testWidgets('LoginScreen shows SnackBar error when submitting empty fields', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildTestApp());
    await tester.pumpAndSettle();

    final signInButton = find.byType(ElevatedButton);
    await tester.ensureVisible(signInButton);
    await tester.pumpAndSettle();
    await tester.tap(signInButton);
    await tester.pumpAndSettle();

    expect(find.text('Please enter your username.'), findsOneWidget);
  });

  testWidgets('LoginScreen shows SnackBar error when password is empty', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildTestApp());
    await tester.pumpAndSettle();

    final usernameField = find.widgetWithText(TextField, 'Username');
    await tester.enterText(usernameField, 'testuser');
    await tester.pumpAndSettle();

    final signInButton = find.byType(ElevatedButton);
    await tester.ensureVisible(signInButton);
    await tester.pumpAndSettle();
    await tester.tap(signInButton);
    await tester.pumpAndSettle();

    expect(find.text('Please enter your password.'), findsOneWidget);
  });

  testWidgets('LoginScreen shows SnackBar error for invalid username with spaces', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildTestApp());
    await tester.pumpAndSettle();

    final usernameField = find.widgetWithText(TextField, 'Username');
    await tester.enterText(usernameField, 'invalid user');
    await tester.pumpAndSettle();

    final signInButton = find.byType(ElevatedButton);
    await tester.ensureVisible(signInButton);
    await tester.pumpAndSettle();
    await tester.tap(signInButton);
    await tester.pumpAndSettle();

    expect(find.textContaining('invalid characters'), findsOneWidget);
  });

  testWidgets('LoginScreen accepts valid username input', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildTestApp());
    await tester.pumpAndSettle();

    final usernameField = find.widgetWithText(TextField, 'Username');
    expect(usernameField, findsOneWidget);

    await tester.enterText(usernameField, 'testuser');
    await tester.pumpAndSettle();

    final passwordField = find.widgetWithText(TextField, 'Password');
    expect(passwordField, findsOneWidget);

    await tester.enterText(passwordField, 'testpassword123');
    await tester.pumpAndSettle();

    expect(find.text('testuser'), findsOneWidget);
  });

  testWidgets('LoginScreen has Create Account link', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildTestApp());
    await tester.pumpAndSettle();

    expect(find.text('Create Account'), findsOneWidget);
  });

  testWidgets('LoginScreen keep-me-logged-in checkbox toggles', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildTestApp());
    await tester.pumpAndSettle();

    final checkbox = find.byType(Checkbox);
    expect(checkbox, findsOneWidget);

    Checkbox widget = tester.widget(checkbox);
    expect(widget.value, true);

    await tester.tap(checkbox);
    await tester.pumpAndSettle();

    widget = tester.widget(checkbox);
    expect(widget.value, false);
  });
}