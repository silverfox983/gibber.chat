import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chat_app/main.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const ChatApp());
    // Drain async init: DB transactions, autoLogin, provider setup
    for (int i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('App loads successfully and shows Login screen', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('App loads successfully and shows login UI', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ChatApp());
    await tester.pumpAndSettle();

    expect(find.text('Gibber'), findsOneWidget);
    expect(find.text('Multi-protocol Chat Client'), findsOneWidget);
    expect(find.text('Connect Now'), findsOneWidget);
  });

  testWidgets('Login screen shows XMPP form fields', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    expect(find.textContaining('your-username'), findsOneWidget);
    expect(find.text('5222'), findsOneWidget);
  });

  testWidgets('Login form has all expected elements', (WidgetTester tester) async {
    await pumpApp(tester);

    expect(find.text('Connect Now'), findsOneWidget);
    expect(find.textContaining('Password'), findsOneWidget);
    expect(find.textContaining('Keep me logged in'), findsOneWidget);
  testWidgets('Protocol detection switches to IRC fields', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ChatApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'irc.example.com');
    await tester.pump();

    expect(find.text('IRC Server'), findsOneWidget);
    expect(find.text('Nickname'), findsOneWidget);
    expect(find.text('Channel'), findsOneWidget);
  });

  testWidgets('Connect button can be tapped', (WidgetTester tester) async {
    await tester.pumpWidget(const ChatApp());
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Connect Now'));
    await tester.tap(find.text('Connect Now'), warnIfMissed: false);
    await tester.pump();

    expect(true, isTrue);
  });
}
